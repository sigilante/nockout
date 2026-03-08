# Nockout Roadmap

Bare-metal Forth OS on AArch64 (RPi3/QEMU) hosting a Nock 4K evaluator.

## Testing

All tests live in `tests/run_tests.sh`. Run with `make test`.

### How it works

All tests run in a **single QEMU session** for speed. The harness builds one long Forth input
string (preamble + all test expressions concatenated), pipes it into QEMU, then parses the
output line by line.

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

Two helper words are defined before any test expression runs:
```forth
: N>N >NOUN ;       \ push a Forth integer as a noun
: C>N N>N SWAP N>N SWAP CONS ;   \ ( a b -- [a b] noun cell )
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
- **15-second timeout**: the entire suite must finish within 15 seconds of QEMU start.

---

## Completed Phases

### Phase 0 — Boot
QEMU boots, UART works.

### Phase 1 — Forth REPL
REPL, `:` `;`, `IF`/`ELSE`/`THEN`, `BEGIN`/`UNTIL`/`AGAIN`/`WHILE`/`REPEAT`, `RECURSE`.
Not implemented (not needed for Nock): `."`, `S"`, `DOES>`, `DO`/`LOOP`.

### Phase 2 — Noun Primitives
`noun.h`/`noun.c`/`nock.c`; Forth words: `>NOUN` `NOUN>` `CONS` `CAR` `CDR` `ATOM?` `CELL?` `=NOUN` `SLOT` `NOCK`.
Noun representation: direct atoms (< 2^62, tag=01), indirect atoms (heap ptr + BLAKE3 prefix, tag=10), cells (heap ptr, tag=00).

### Phase 3 — Nock Evaluator
Opcodes 0–10, tail-call optimization (goto loop), `hax()` tree edit.

### Phase 3b — Op 11 + Hints + Jets
Op 11 hint dispatch, `%wild` jet registration (UIP-0122), `%slog`/`%xray` debug hints.
Jet architecture: no `%fast`; `%wild` is sole registration mechanism; hot state is a static C table.
Evaluator signature: `noun nock(subject, formula, const wilt_t *jets, sky_fn_t sky)`.

### Phase 3c — setjmp/longjmp
Bare-metal AArch64 `setjmp`/`longjmp` (`src/setjmp.s`). `nock_crash()` longjmps to QUIT restart point.

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
126 tests passing.

---

## Remaining Phases

### Phase 5b — Hot Jets ✓ COMPLETE
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
`%wild` cord = 1684826487 = 0x646C6977. (Note: 1684956535 = "wend" — wrong.)

Gate convention: sample = `slot(6, core)`; binary args at `slot(12, core)` / `slot(13, core)`.

Test helpers added to preamble: `JCORE1`, `JCORE2`, `JD`, `JWRAP` — build synthetic gate
cores and wrap them with a `%wild` op11 hint so jets fire via op9 dispatch.
141 tests passing.

### Phase 6 — Kernel Loop
Replace the Forth REPL as the top-level driver with a proper Nock kernel loop:
- Accept an event noun over UART (cue-encoded).
- Run `nock(subject, event)` to produce `[effects new-subject]`.
- Emit effects (jam-encoded) over UART.
- Update subject and repeat.

This is the minimal "Arvo-shaped" event loop.

### Phase 7 — SKA (Subject Knowledge Analysis)
Implement the partial Nock interpreter described in Afonin ~dozreg-toplud, UTJ v3i1.

SKA runs symbolically on `(subject, formula)` where the subject is represented as
`$sock = (cape: mask, data: partial_noun)` with unknown axes stubbed out.

Outputs:
1. Annotated call graph: each Nock 2/9 site tagged direct (statically-known callee) or indirect.
2. `$cape` subject mask: which axes are used as code (needed for correct cache keying).

Key implementation notes:
- **Direct calls**: annotate Nock 2 sites with a pointer to the callee's compiled form; skip `nock_eval` entirely (~1.7× speedup per paper).
- **Compile-time jet matching**: walk call graph once, match battery hashes against jet table; record pointer in call annotation. Eliminates per-call hash lookup.
- **Subject mask as cache key**: cache on `(masked_subject, formula)`, not `(full_subject, formula)`. Without the mask, subjects with changing counters cause cache misses on every call.
- **Tarjan SCC for loops**: naive partial evaluation loops forever on `dec` (and any tail-recursive gate). Detect back-edges; defer fixpoint until SCC entry is finalized.
- **Nomm representation**: SKA output is annotated Nock where Nock 2 carries an `info` field (`~`=indirect, `[sock fol]`=direct). Our equivalent is a compiled Forth word that uses direct `bl` for known call sites.

### Phase 8 — Forth as Jet Dashboard
Move Nock evaluator dispatch into the Forth dictionary.

Each jet is a named Forth word. The hot-state table becomes a Forth vocabulary.
SKA-annotated call sites `bl` directly into Forth words, bypassing `nock_eval`.
The REPL becomes a live jet-registration and debugging interface:
- Define a new jet word at the REPL → immediately available for SKA to wire up.
- Inspect the annotated call graph interactively.
