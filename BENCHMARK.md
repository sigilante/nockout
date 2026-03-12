# Fock Benchmark Results

Benchmarks are produced by `tests/run_bench.sh`, which boots the kernel in QEMU
(raspi4b) and runs each target word 1000 times via the `BENCH` word.  Ticks are
`CNTVCT_EL0` virtual counter reads — not wall-clock time, but consistent within
a run and suitable for tracking relative regressions.

`BENCH ( xt n -- ticks )` executes the xt n times in a tight loop and returns
elapsed ticks.  All target words are stack-neutral.

## Target Descriptions

| Word | What it exercises |
|------|-------------------|
| `NOOP` | Loop baseline — just the `BENCH` dispatch overhead |
| `BCONS` | Noun allocation: `1 >NOUN 2 >NOUN CONS DROP` |
| `BNOCK` | Plain `nock()` evaluator, op1 (quote 42), no SKA |
| `BSKNK` | `ska_nock()` evaluator, op1, SKA scan+cook+cache |
| `BDEC` | C jet `dec` via `NOCK`+`%wild` hot-state dispatch |
| `BSDEC` | Forth jet `dec` via `SKNOCK` `find_by_cord` dispatch |
| `BADD` | C jet `add` via `NOCK`+`%wild` hot-state dispatch |
| `BSADD` | Forth jet `add` via `SKNOCK` `find_by_cord` dispatch |

## Results

### `e28a224` — 2026-03-12 (Phase 9 complete)

QEMU raspi4b, CNTVCT_EL0, 1000 iterations each.

| Benchmark | Ticks (hex) | Ticks/iter (dec) | Ratio vs NOOP |
|-----------|-------------|------------------|---------------|
| `NOOP`  (loop baseline)  | `0000000000001E07` |     7.7 | 1.0× |
| `BCONS` (noun alloc)     | `000000000000278D` |    10.1 | 1.3× |
| `BNOCK` (plain nock/op1) | `0000000000004E5E` |    20.1 | 2.6× |
| `BSKNK` (ska_nock/op1)   | `0000000000017BE2` |    97.3 | 12.6× |
| `BDEC`  (C jet dec)      | `0000000000015E19` |    90.2 | 11.7× |
| `BSDEC` (Forth jet dec)  | `000000000012D8B5` |  1235.1 | 160.5× |
| `BADD`  (C jet add)      | `0000000000017932` |    96.6 | 12.5× |
| `BSADD` (Forth jet add)  | `000000000015E019` |  1433.6 | 186.3× |

**Observations:**
- SKA scan+cook adds ~10× overhead vs plain `nock()` for a trivial formula.
  The formula cache amortises this across repeated calls to the same formula;
  the first-call cost is dominated by the analysis pass.
- C jets (via `%wild` hot-state) are roughly comparable to raw `ska_nock()` on
  a trivial formula — the jet saves eval work but pays SKA overhead to get there.
- Forth jets are ~13–15× slower than C jets at this grain, consistent with
  Forth inner-interpreter dispatch overhead vs a direct C call.
- Noun allocation (`BCONS`) is cheap: only ~1.3× baseline, confirming the bump
  allocator is fast.

## Updating This File

After a significant change, re-run the benchmarks and append a new section:

```bash
make
bash tests/run_bench.sh
```

Add a new `### <commit> — <date> (<description>)` subsection under **Results**
with the fresh output table.
