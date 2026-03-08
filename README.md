# nock-on-metal

![](./img/hero.jpg)

an experiment in raspberry pi arm64-native nock virtual machine code

![](./img/icon-64.png)

(c) 2026 sigilante, made available under the mit license

---

## Building

```
make
```

Cross-compile for CI (Ubuntu):

```
make CC=aarch64-linux-gnu-gcc LD=aarch64-linux-gnu-ld \
     OBJCOPY=aarch64-linux-gnu-objcopy
```

## Running

```
make run          # boots into the Forth REPL
make debug        # boots under GDB
make test         # run regression suite (141 tests)
```

## REPL basics

The kernel boots into a bare-metal Forth REPL. Nouns are 64-bit tagged words;
the key words for working with them:

| Word | Stack effect | Description |
|------|-------------|-------------|
| `N>N` | `( n -- noun )` | wrap raw integer as a direct atom |
| `NOUN>` | `( noun -- n )` | extract raw integer from a direct atom |
| `CONS` | `( head tail -- cell )` | allocate a cell |
| `CAR` | `( cell -- head )` | head of a cell |
| `CDR` | `( cell -- tail )` | tail of a cell |
| `ATOM?` | `( noun -- flag )` | `-1` if atom, `0` if cell |
| `NOCK` | `( subject formula -- result )` | evaluate Nock |
| `JAM` | `( noun -- atom )` | serialize noun to atom |
| `CUE` | `( atom -- noun )` | deserialize atom to noun |
| `PILL` | `( -- atom )` | load jammed atom from QEMU file loader |
| `.` | `( n -- )` | print top of stack as 16-digit hex |
| `N.` | `( noun -- )` | print atom as decimal |

## Running arbitrary Nock subject/formula pairs

### 1. Build inline at the REPL

`NOCK` consumes `( subject formula -- result )`. Build nouns with `N>N` and
`CONS`. Nock cells are right-associative: `[a b c]` = `[a [b c]]`, so push
`a`, push `b`, push `c`, then `CONS CONS`.

```forth
\ *[42 [0 1]] = 42  (slot 1 of atom)
42 N>N   0 N>N 1 N>N CONS   NOCK NOUN> .

\ *[42 [4 [0 1]]] = 43  (increment)
42 N>N   4 N>N 0 N>N 1 N>N CONS CONS   NOCK NOUN> .

\ *[0 [1 [1 2]]] = [1 2]  (quote a cell), print head
0 N>N   1 N>N   1 N>N 2 N>N CONS CONS   NOCK CAR NOUN> .
```

General rule: work **right-to-left** — innermost subterms first, then `CONS`
outward.

### 2. Load a pre-jammed pair via PILL

For formulas too large to type, jam `[subject formula]` externally and load it
via QEMU's file-loader device.

**Pill file format** (little-endian):
- bytes 0–7: `uint64_t` = byte count of jam data that follows
- bytes 8+: raw jam bytes (little-endian bignum)

**Create a pill** from a raw jam file:

```python
import sys, struct
d = open('formula.jam', 'rb').read()
open('pill.bin', 'wb').write(struct.pack('<Q', len(d)) + d)
```

**Run with the pill loaded** (loads at physical address `0x10000000`):

```
make run-pill PILL=pill.bin
```

**Decode and evaluate in the REPL:**

```forth
PILL CUE           \ decode the [subject formula] pair noun
DUP CAR SWAP CDR   \ split: subject below, formula on top
NOCK               \ evaluate
```

Or define a helper word once per session:

```forth
: NOCK-PAIR  DUP CAR SWAP CDR NOCK ;
PILL CUE NOCK-PAIR NOUN> .
```

`PILL` returns atom `0` if no pill was loaded (QEMU zeroes RAM at startup).

