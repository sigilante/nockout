# Nockout Roadmap

Bare-metal Forth OS on AArch64 (RPi3/QEMU) hosting a Nock 4K evaluator.

## Testing

All tests live in `tests/run_tests.sh`. Run with `make test`.

### How it works

All tests run in a **single QEMU session** for speed. The harness builds one long Forth input
string (preamble + all test expressions concatenated), pipes it into QEMU, then parses the
output line by line. After sending all input the harness sends the QEMU monitor quit sequence
(`Ctrl-A X`) so QEMU exits cleanly rather than waiting for a timeout.

Each test expression must leave exactly one value on the stack and then print it. The harness
recognizes two output formats:

- **Hex** (`T`): the expression ends with `.` — the Forth dot word prints a 16-digit uppercase
  hex value followed by `ok`. Matched by regex `^([0-9A-Fa-f]{16})\s+ok`.
- **Decimal** (`TD`): the expression ends with `N.` — the bignum decimal printer outputs a
  plain decimal string followed by `ok`. Matched by regex `^([0-9]+)\s+ok`.

Results are collected into an array in order and compared against expected values positionally.

### Test macros

```bash
T  "description"  "HEXVALUE16"      "forth expression ending with ."
TD "description"  "decimal-string"  "forth expression ending with N."
```

`T` expects a 16-digit uppercase hex string (zero-padded). Common patterns:
- `FFFFFFFFFFFFFFFF` — Forth true (-1), also used to assert `ATOM?` or `=NOUN` success
- `0000000000000000` — Forth false (0), also used for Nock YES (loob 0)
- `0000000000000001` — Nock NO (loob 1), or small integer

### Preamble

Several helper words are defined before any test expression runs:

```forth
: N>N >NOUN ;
: C>N N>N SWAP N>N SWAP CONS ;
: JCORE1 0 N>N CONS 0 N>N SWAP CONS ;
: JCORE2 CONS 0 N>N CONS 0 N>N SWAP CONS ;
: JD 1 N>N SWAP CONS 2 N>N SWAP CONS 9 N>N SWAP CONS ;
: JWRAP ... ;   \ wraps a core in a %wild op11 hint for jet dispatch
```

### Nock formula construction pattern

Nock formulas are built on the stack right-to-left using `CONS`. The opcode digit goes at
the head of the outermost cell:

```
subj N>N  OP N>N  arg1 N>N  arg2 N>N  CONS  CONS  NOCK
          ─────   ────────────────────────────────
          head    tail (formula body)
```

For opcodes with nested sub-formulas, the pattern repeats recursively with more `CONS` calls.
See the existing tests for worked examples of each opcode.

### Adding tests

Append `T` or `TD` calls to `run_tests.sh` before the `# ── Build input and run ──` comment.
Test count in the pass/fail summary updates automatically.

### Constraints

- **No hex literals in Forth**: `BASE` is 10; use decimal. Cord/hint values must be decimal
  (e.g. `%slog` = `1735355507`).
- **One output per test**: each expression must print exactly one token followed by `ok`.
  Extra prints (e.g. from `%slog`) appear in QEMU output but are not matched by the parser.
- **30-second timeout**: safety net; in practice the suite exits in ~3 seconds via the
  Ctrl-A X quit sequence after all tests complete.

---

## Completed Phases

### Phase 0 — Boot
QEMU boots, UART works.

### Phase 1 — Forth REPL
REPL, `:` `;`, `IF`/`ELSE`/`THEN`, `BEGIN`/`UNTIL`/`AGAIN`/`WHILE`/`REPEAT`, `RECURSE`.
Not implemented (not needed for Nock): `."`, `S"`, `DOES>`, `DO`/`LOOP`.

### Phase 2 — Noun Primitives
`noun.h`/`noun.c`/`nock.c`; Forth words: `>NOUN` `NOUN>` `CONS` `CAR` `CDR` `ATOM?` `CELL?`
`=NOUN` `SLOT` `NOCK`.
Noun representation: direct atoms (< 2^62, tag=01), indirect atoms (heap ptr + BLAKE3 prefix,
tag=10), cells (heap ptr, tag=00).

### Phase 3 — Nock Evaluator
Opcodes 0–10, tail-call optimization (goto loop), `hax()` tree edit.

### Phase 3b — Op 11 + Hints + Jets
Op 11 hint dispatch, `%wild` jet registration (UIP-0122), `%slog`/`%xray` debug hints.
Jet architecture: no `%fast`; `%wild` is sole registration mechanism; hot state is a static C table.
Evaluator signature: `noun nock(subject, formula, const wilt_t *jets, sky_fn_t sky)`.

### Phase 3c — setjmp/longjmp
Bare-metal AArch64 `setjmp`/`longjmp` (`src/setjmp.s`). `nock_crash()` longjmps to QUIT
restart point on any fatal error.

### Phase 4b — BLAKE3
`src/blake3.c`; Forth words: `HATOM`, `B3OK`; 7 official test vectors pass.

### Phase 4c — Bignum Arithmetic
`src/bignum.c`: `bn_dec`, `bn_add`, `bn_sub`, `bn_cmp`, `bn_to_decimal`, `bn_from_decimal`.
`BN_MAX_LIMBS=64`; uses `__uint128_t` for carry/division.
Forth words: `N.`, `BN+`, `BNDEC`.

### Phase 4d — Bignum Bit Ops + Multiply
`bn_met`, `bn_bex`, `bn_lsh`, `bn_rsh`, `bn_or`, `bn_and`, `bn_xor`, `bn_mul`.
Forth words: `BNMET`, `BNBEX`, `BNLSH`, `BNRSH`, `BNOR`, `BNAND`, `BNXOR`, `BNMUL`.

### Phase 5a — Jam/Cue (Noun Serialization)
`src/jam.c`/`src/jam.h`: `noun jam(noun n)` and `noun cue(noun a)`.
Forth words: `JAM` `( noun -- atom )`, `CUE` `( atom -- noun )`.
Encoding: tag 0=atom, 01=cell, 11=back-reference; `mat`/`rub` self-describing integer encoding.

### Phase 5b — Hot Jets
`hot_state[]` in `nock.c` populated with 8 jets, all backed by existing bignum functions:

| Jet   | C function | Label cord |
|-------|------------|------------|
| `dec` | `bn_dec`   | 6514020    |
| `add` | `bn_add`   | 6579297    |
| `sub` | `bn_sub`   | 6452595    |
| `mul` | `bn_mul`   | 7107949    |
| `lth` | `bn_cmp`   | 6845548    |
| `gth` | `bn_cmp`   | 6845543    |
| `lte` | `bn_cmp`   | 6648940    |
| `gte` | `bn_cmp`   | 6648935    |

Jets are keyed on **label cord atoms** (not battery hashes) and registered via `%wild` hints.
`%wild` cord = 1684826487. Gate convention: sample = `slot(6, core)`; binary args at
`slot(12, core)` / `slot(13, core)`.

**141 tests passing.**

### Phase 5d — Noun Tag Redesign

New tagging scheme making direct atoms natural integers:

| Bits 63:62 | Type | Representation |
|------------|------|----------------|
| `0x` (bit 63 = 0) | direct atom | value = noun word (0..2^63-1) |
| `10` | indirect atom | 62-bit BLAKE3 hash of limb data |
| `11` | cell | 32-bit heap pointer in bits 31:0 |

Key change: `direct(42) == 42` — the raw integer is the noun. `42 >NOUN .` now prints
`000000000000002A` instead of `400000000000002A`.

Atom store (ATOM_INDEX_BASE / ATOM_DATA_BASE) is now load-bearing:
- 65536-slot open-addressed hash table (hash62 → atom_t*)
- 4MB bump allocator for atom_t + limbs
- `make_atom(limbs, size)`: normalize → BLAKE3 → store → return noun
- Equality for atoms: word compare only (hash62 IS the identity)

`HATOM` Forth word is now a no-op (atoms always content-addressed).
Direct atom boundary raised from 2^62-1 to 2^63-1.

**141 tests passing.**

### Phase 5e — Bignum Division and Modulo

`bn_div(a, b)` = floor(a/b) and `bn_mod(a, b)` = a mod b in `src/bignum.c`.
Forth words: `BNDIV` `( n1 n2 -- quot )`, `BNMOD` `( n1 n2 -- rem )`.
Jets: `%div` (cord 7760228), `%mod` (cord 6582125) added to `hot_state[]`.

Implementation:
- Single-limb divisor: `div1()` fast path using `divlu64()`.
- Multi-limb: Knuth Algorithm D (TAOCP §4.3.1); `__int128_t` borrow tracking in D4/D5.
- `divlu64(u1, u0, v, rem)`: restoring binary long division in 64 iterations,
  using only 64-bit ops. Avoids `__udivti3` (not available in freestanding libgcc).

**157 tests passing.**

### Phase 5c — PILL: QEMU File Loader
`PILL` Forth word loads a jammed atom from physical address `0x10000000`, placed there by
QEMU's `-device loader` at startup. Enables loading arbitrary nouns (formulas, cores, pills)
without typing them at the REPL.

Pill file format (little-endian):
- bytes 0–7: `uint64_t` = byte count of jam data
- bytes 8+: raw jam bytes

```
make run-pill PILL=pill.bin
```

In the REPL:
```forth
PILL CUE           \ decode jammed noun
DUP CAR SWAP CDR   \ split [subject formula]
NOCK               \ evaluate
```

`PILL` returns atom `0` if no pill was loaded (QEMU zeroes RAM at startup).

### Phase 6 — Kernel Loop

Replace the Forth REPL as the top-level driver with a Nock event loop.
Two kernel shapes are supported, selected by a flag byte in the PILL header:

**Arvo** (shape = 0):
```
nock([kernel event], slam-formula) → [effects new-kernel]
```

**Shrine** (shape = 1):  same as Arvo but result includes deferred causes:
```
nock([kernel event], slam-formula) → [effects new-kernel causes]
```
Causes are a Nock list of events re-injected into the loop without waiting on UART.

The calling formula is the standard Hoon gate slam hardcoded as a constant:
`[9 2 [10 [6 [0 3]] [0 2]]]`

The kernel gate is a normal Hoon gate built in the Dojo and loaded via PILL.
No custom compiler needed.

#### PILL Format v2

```
bytes  0-7:   uint64_t (LE) = byte count of jam data
byte   8:     kernel shape  (0 = Arvo, 1 = Shrine)
bytes  9-15:  reserved/padding (zeros)
bytes  16+:   raw jam bytes (little-endian bignum, 16-byte aligned)
```

`tools/mkpill.py` wraps a raw Dojo jam file into this format.

#### UART Framing

Events in / effects out: `[8-byte LE length][raw jam bytes]`.

#### Effect Dispatch (Phase 6)

Effects are a Nock list `[[tag data] rest]` terminated by `0`.

| Tag | Cord | Action |
|-----|------|--------|
| `%out` | 7632239 | `uart_puts(data)` |
| `%blit` | 1952605026 | `uart_puts(data)` |
| unknown | — | silent ignore |

#### Forth Words Added

| Word | Stack | Description |
|------|-------|-------------|
| `KSHAPE` | `( -- addr )` | variable: 0=Arvo 1=Shrine, loaded from PILL header |
| `RECV-NOUN` | `( -- noun )` | read length-framed jam noun from UART |
| `SEND-NOUN` | `( noun -- )` | jam noun, write length-framed to UART |
| `DISPATCH-FX` | `( effects -- )` | walk effects list, dispatch known tags |
| `ARVO-LOOP` | `( kernel -- )` | Arvo event loop, never returns |
| `SHRINE-LOOP` | `( kernel -- )` | Shrine event loop, never returns |
| `KERNEL` | `( -- )` | PILL → CUE → dispatch by KSHAPE; falls back to REPL if no pill |

#### Design Decisions

- **Forth REPL preserved**: no pill → `KERNEL` falls through to `QUIT`. The REPL
  remains the debug escape hatch throughout Phase 6+.
- **No custom compiler**: kernel is a standard Hoon gate from the Dojo.
  `%wild` hints can be hand-annotated in the jam or added later via Phase 7 SKA.
- **UART receive buffer**: 28KB static window at `UART_RXBUF_BASE` (between TIB
  and dictionary). Sufficient for Phase 6 test events; extend for Phase 7+.

**Prerequisites**: all complete — bignum ✓, JAM/CUE ✓, PILL loader ✓, jets ✓.

**STATUS: COMPLETE** — Kernel loop boots from PILL, dispatches effects, supports both
Arvo and Shrine shapes. CI: 158 REPL tests + 5 kernel boot integration tests all passing.

---

## Remaining Phases

### Phase 7 — SKA (Subject Knowledge Analysis)

**STATUS: COMPLETE** — All stages 7a–7h done. 182 tests passing.

Reference implementation: [`dozreg-toplud/ska`](https://github.com/dozreg-toplud/ska) (Hoon).
Paper: Afonin ~dozreg-toplud, UTJ vol. 3 issue 1.

#### What SKA Does

SKA is a static analysis pass that takes a `(subject-sock, formula)` pair and produces
an **annotated Nock AST** (`$nomm`) where every Nock 2/9 call site is classified:

| SKA tag  | Meaning |
|----------|---------|
| `%i2`    | Indirect — formula not statically known; fall back to `nock_eval` |
| `%ds2`   | Direct safe — formula is `%0` or `%1`; no formula eval needed |
| `%dus2`  | Direct unsafe — formula known but complex; verify at runtime |

This makes jet matching a **one-time analysis cost** rather than a per-call `sock_match`
scan. It also enables **correct cache keying**: the `$cape` subject mask identifies
exactly which axes of the subject matter for a given call, so cache keys exclude
irrelevant parts (e.g. a counter that increments but doesn't affect code paths).

#### Layer Relationship

```
┌──────────────────────────────────────────┐
│  Forth layer  (src/forth.s)              │
│  KERNEL word → NOCK word → nock_eval()   │
│  New words: SKA, .SKA                    │
└──────────────────┬───────────────────────┘
                   │ noun subject, formula
┌──────────────────▼───────────────────────┐
│  Nock layer  (src/nock.c)                │
│  nock_eval() checks SKA cache first      │
│    hit  → run_nomm1()                    │
│    miss → full eval as before            │
└──────────────────┬───────────────────────┘
                   │ one-time analysis at load
┌──────────────────▼───────────────────────┐
│  SKA layer  (src/ska.c / src/ska.h)      │
│  ska_analyze(s, f) → nomm1_t*           │
│  scan pass  →  cook pass  →  cache       │
│  %ds2 sites wired to hot_state[] jets    │
└──────────────────────────────────────────┘
```

The Forth layer does not change structurally — only two new Forth words are added
(`SKA` to trigger analysis, `.SKA` to print the call-site dashboard).

#### Key Types (ported from `noir.hoon` / `sock.hoon`)

```c
// $cape: boolean tree — & = axis known, | = wildcard
// atom: is_atom=true, known=true/false
// cell: is_atom=false, head/tail are sub-capes
typedef struct cape_s cape_t;
struct cape_s { bool is_atom; union { bool known; struct { cape_t *h, *t; }; }; };

// $sock: partial knowledge of a noun
typedef struct { cape_t *cape; noun data; } sock_t;

// $bell: call site identity = (subject template, formula)
typedef struct { sock_t bus; noun fol; } bell_t;

// $nomm: annotated Nock AST (Nock 2 split into three variants)
typedef enum {
    NOMM_0, NOMM_1, NOMM_I2, NOMM_DS2, NOMM_DUS2,
    NOMM_3, NOMM_4, NOMM_5, NOMM_6, NOMM_7,
    NOMM_10, NOMM_S11, NOMM_D11, NOMM_12
} nomm_tag_t;

// $nomm-1: final AST — %2 carries resolved call info
typedef struct { sock_t less; noun fol; } call_info_t;   // resolved bell
```

#### Algorithm (from `skan.hoon`, 2300 lines)

**Pass 1 — `scan`** (~850 lines): Symbolic partial evaluator over `(sock, formula)`.
For each opcode, propagates `sock` (partial subject knowledge):

- `%0 ax` → `sock_pull(sub, ax)` — extract sub-sock at axis
- `%1 val` → known constant `[& val]`
- `%3/%4/%5` → `dunno` (result always unknown)
- `%6 c y n` → `sock_purr(prod_y, prod_n)` — intersection of both branches
- `%7 p q` → compose — `prod_p` becomes subject for `q`
- `%9 ax f` → desugar to `[%7 f %2 [%0 1] %0 ax]`

**Nock 2 — five sub-cases**:
1. `cape(formula-prod) ≠ &` → **indirect** `%i2`
2. Formula known + `try_inline` succeeds → inline as `%7`
3. Formula known + memo cache hit → emit `%ds2`/`%dus2` with memo index
4. Formula known + loop heuristic fires → emit `%ds2`/`%dus2` with loop site
5. Formula known + melo (within-cycle) cache hit → reuse
6. Otherwise → allocate evalsite, recurse, emit `%ds2`/`%dus2`

**Loop detection heuristic** (`++close`): When analysing a Nock-2 call, scan
the call stack for the same formula at a site `par` whose masked subject
subsumes the current subject. If found, guess it's a loop — emit a backedge
site reference, record `[par, kid, par-sub, kid-sub]` in `cycles`.

**Cycle validation** (when exiting cycle entry point): For each `[par, kid]`
frond, iteratively compute `par_final` by expanding `want` through the kid's
provenance. Check `par_final ⊇ kid_sub`. If this fails, add `[par, kid]` to
the blocklist and **redo the entire scan** (the `redo-loop`). This is why `dec`
and other tail-recursive gates are handled correctly without hard-coding.

**Pass 2 — `cook`** (~200 lines): Converts `nomm` → `nomm-1`.
Walks the annotated AST; resolves `%ds2`/`%dus2` site references to concrete
`[less-sock, formula]` pairs from `long.arms.sites` / `long.memo`. Matches
resolved formulas against `hot_state[]` labels → stores `jet_fn_t` pointer.

#### Integration with `%wild`

`%wild` and SKA are complementary, not competing:
- **`%wild`** (runtime): supplies the initial `$wilt` registration — which
  batteries are present and what labels they have. This is the *subject mask*.
- **SKA** (analysis-time): given that subject mask, analyses the full call graph
  to classify every call site as direct or indirect.

The `%wild` clue is consumed first; SKA uses the resulting `wilt_t` as its
initial sock. After SKA, op-9 dispatch skips `sock_match` entirely at
`%ds2` sites.

#### Stage Plan

| Stage | File(s) | Content |
|-------|---------|---------|
| **7a** Types           | `src/ska.h`  | ✅ `cape_t`, `sock_t`, `nomm_t`, `nomm1_t`, `bell_t`, `site_t`, `short_t`, `long_t`, `cycle_t` |
| **7b** Sock ops        | `src/ska.c`  | ✅ `cape_and/or`, `cape_app`, `sock_pull`, `sock_huge`, `sock_knit`, `sock_purr`, `sock_pack`, `sock_darn`, `dunno` |
| **7c** Scan (linear)   | `src/ska.c`  | ✅ All opcodes; `%9` → `NOMM_DS2` or `NOMM_9` fallback; `SKNOCK` Forth word |
| **7d** Memo cache      | `src/ska.c`  | ✅ Cross-arm cache keyed by `(formula, sub-sock)`; per-pass reset |
| **7e** Loop detection  | `src/ska.c`  | ✅ `close()` heuristic, fols_stack, frond validation, redo-loop |
| **7f** Cook pass       | `src/ska.c`  | ✅ `nomm → nomm-1`; `cook_nomm()`, `run_nomm1()`; static jet pre-wiring at DS2 sites |
| **7g** Integration     | `src/forth.s` | ✅ `SKA-EN` variable, `NOCK` routes through SKA when set, `.SKA` stats word |
| **7h** Tests           | `tests/run_tests.sh` | ✅ SKA-EN, .SKA no-crash, 182 tests total |

Stage 7c alone gives partial benefit (non-looping direct calls annotated).
Stage 7e is required for all tail-recursive Hoon gates (`dec`, `add`, etc.).

**What we are NOT porting from `skan.hoon`**:
- `%fast` hint processing — we use `%wild` only, `%fast` is intentionally ignored
- `$source` provenance tracking — deferred; use conservative `cape = &` initially
- `++find-args` argument minimization — an optimization on top of SKA, not needed for correctness
- Tarjan SCC (`++find-sccs`) — only used by `find-args`, not the main scan/cook flow
- `++ka.rout` queue management — driven by `%fast` cold state; not needed

### Phase 8 — Forth as Jet Dashboard

Move Nock evaluator dispatch into the Forth dictionary.

Each jet is a named Forth word. The `hot_state[]` C table becomes a Forth vocabulary.
SKA-annotated `%ds2` call sites dispatch to Forth words by label, bypassing `nock_eval`.
The REPL becomes a live jet-registration and debugging interface:

- Define a new jet at the REPL: `': dec  ...impl...  ;'` → immediately wirable by SKA.
- Inspect the annotated call graph: `.SKA` prints every `%ds2` site and its wired word.
- Replace a running jet without reflash: redefine the word, call `SKA` again.

This is the core architectural thesis: **the Forth dictionary IS the jet dashboard**.
