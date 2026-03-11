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

---

## Remaining Phases

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

### Phase 7 — SKA (Subject Knowledge Analysis)
Implement the partial Nock interpreter described in Afonin ~dozreg-toplud, UTJ v3i1.

SKA runs symbolically on `(subject, formula)` where the subject is represented as
`$sock = (cape: mask, data: partial_noun)` with unknown axes stubbed out.

Outputs:
1. Annotated call graph: each Nock 2/9 site tagged direct (statically-known callee) or indirect.
2. `$cape` subject mask: which axes are used as code (needed for correct cache keying).

Key implementation notes:
- **Direct calls**: annotate Nock 2 sites with a pointer to the callee's compiled form; skip
  `nock_eval` entirely (~1.7× speedup per paper).
- **Compile-time jet matching**: walk call graph once, match battery hashes against jet table;
  record pointer in call annotation. Eliminates per-call hash lookup.
- **Subject mask as cache key**: cache on `(masked_subject, formula)`, not
  `(full_subject, formula)`. Without the mask, subjects with changing counters cause cache
  misses on every call.
- **Tarjan SCC for loops**: naive partial evaluation loops forever on `dec` (and any
  tail-recursive gate). Detect back-edges; defer fixpoint until SCC entry is finalized.
- **Nomm representation**: SKA output is annotated Nock where Nock 2 carries an `info` field
  (`~`=indirect, `[sock fol]`=direct). Our equivalent is a compiled Forth word that uses
  direct `bl` for known call sites.

### Phase 8 — Forth as Jet Dashboard
Move Nock evaluator dispatch into the Forth dictionary.

Each jet is a named Forth word. The hot-state table becomes a Forth vocabulary.
SKA-annotated call sites `bl` directly into Forth words, bypassing `nock_eval`.
The REPL becomes a live jet-registration and debugging interface:
- Define a new jet word at the REPL → immediately available for SKA to wire up.
- Inspect the annotated call graph interactively.
