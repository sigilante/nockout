# Nockout Forth — User Guide

Nockout is a bare-metal Forth OS targeting AArch64 (Raspberry Pi 3B / QEMU) that
hosts a Nock 4K evaluator with bignum arithmetic, jet dispatch, and noun
serialization.

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [The REPL](#2-the-repl)
3. [Core Forth Words](#3-core-forth-words)
4. [Defining Words and Control Flow](#4-defining-words-and-control-flow)
5. [Noun Representation](#5-noun-representation)
6. [Noun Primitives](#6-noun-primitives)
7. [Nock Evaluation](#7-nock-evaluation)
8. [Bignum Arithmetic](#8-bignum-arithmetic)
9. [Noun Serialization — Jam / Cue](#9-noun-serialization--jam--cue)
10. [Jet Dispatch](#10-jet-dispatch)
11. [PILL Loading](#11-pill-loading)
12. [Memory Layout](#12-memory-layout)
13. [Register Architecture](#13-register-architecture)
14. [Worked Nock Examples](#14-worked-nock-examples)
15. [Appendix A: Cord Value Reference](#appendix-a-cord-value-reference)
16. [Appendix B: Nock Quick Reference](#appendix-b-nock-quick-reference)

---

## 1. Quick Start

```bash
make          # build kernel8.img
make run      # boot in QEMU (UART on stdout)
make test     # run 157-test regression suite
make debug    # QEMU with GDB stub (-s -S); starts aarch64-elf-gdb
make run-pill PILL=myformula.bin   # boot and pre-load a noun pill
```

The REPL appears over UART (stdout in QEMU `-nographic`).
Type Forth expressions and press Enter. Backspace and DEL both erase one character.

---

## 2. The REPL

The system boots into an infinite QUIT loop.  Each line is read from UART, tokenized,
and executed.

### Number literals

`BASE` defaults to **10**.  Numbers are parsed in the current base.

```forth
42            \ decimal 42
BASE 16 !     \ switch to hexadecimal
FF            \ hex 255 (only after BASE 16)
BASE 10 !     \ restore
```

> **No `0x` prefix.**  Hex digits only work after `BASE 16 !`.  Urbit cord values and
> hint tags must be entered as plain decimal integers.

### Output

| Expression | Output | Notes |
|-----------|--------|-------|
| `42 .` | `000000000000002A ` | `.` prints raw 64-bit Forth integer as 16-digit uppercase hex + space |
| `42 >NOUN N.` | `42` | `N.` prints a noun atom in decimal |

### Error recovery

`nock_crash(msg)` prints an error line and `longjmp`s to the QUIT restart point.
Both data and return stacks are reset.  The session continues; you can keep typing.

---

## 3. Core Forth Words

### Stack manipulation

| Word    | Stack effect             | Description |
|---------|--------------------------|-------------|
| `DUP`   | `( a -- a a )`           | Duplicate top |
| `DROP`  | `( a -- )`               | Discard top |
| `SWAP`  | `( a b -- b a )`         | Swap top two |
| `OVER`  | `( a b -- a b a )`       | Copy second to top |
| `ROT`   | `( a b c -- b c a )`     | Rotate three leftward |
| `-ROT`  | `( a b c -- c a b )`     | Rotate three rightward |
| `NIP`   | `( a b -- b )`           | Drop second item |
| `2DUP`  | `( a b -- a b a b )`     | Duplicate top pair |
| `2DRP`  | `( a b -- )`             | Drop top pair |
| `?DUP`  | `( a -- a a \| 0 )`      | Dup only if non-zero; leaves `0` otherwise |
| `DPTH`  | `( -- n )`               | Number of items currently on stack |

### Arithmetic (raw 64-bit integers, not nouns)

| Word   | Stack effect           | Description |
|--------|------------------------|-------------|
| `+`    | `( a b -- a+b )`       | Add |
| `-`    | `( a b -- a-b )`       | Subtract |
| `*`    | `( a b -- a*b )`       | Multiply |
| `/`    | `( a b -- a/b )`       | Truncated quotient |
| `MOD`  | `( a b -- a mod b )`   | Truncated remainder |
| `/MOD` | `( a b -- rem quot )`  | Both; **remainder on top**, quotient below (non-ANS order) |
| `NEG`  | `( a -- -a )`          | Negate |
| `ABS`  | `( a -- \|a\| )`       | Absolute value |
| `1+`   | `( a -- a+1 )`         | Increment |
| `1-`   | `( a -- a-1 )`         | Decrement |
| `2*`   | `( a -- a<<1 )`        | Arithmetic left shift by 1 |
| `2/`   | `( a -- a>>1 )`        | Arithmetic right shift by 1 |

### Bitwise / logic

| Word  | Stack effect         | Description |
|-------|----------------------|-------------|
| `AND` | `( a b -- a&b )`     | Bitwise AND |
| `OR`  | `( a b -- a\|b )`    | Bitwise OR |
| `XOR` | `( a b -- a^b )`     | Bitwise XOR |
| `INV` | `( a -- ~a )`        | Bitwise invert (all bits) |
| `LSH` | `( a n -- a<<n )`    | Logical left shift |
| `RSH` | `( a n -- a>>n )`    | Logical right shift |

### Comparison

All comparisons return **`-1`** (true) or **`0`** (false) as raw integers.

| Word | Stack effect      | Description |
|------|-------------------|-------------|
| `=`  | `( a b -- f )`    | Equal |
| `<>` | `( a b -- f )`    | Not equal |
| `<`  | `( a b -- f )`    | Signed less-than |
| `>`  | `( a b -- f )`    | Signed greater-than |
| `<=` | `( a b -- f )`    | Signed ≤ |
| `>=` | `( a b -- f )`    | Signed ≥ |
| `U<` | `( a b -- f )`    | Unsigned less-than |
| `0=` | `( a -- f )`      | Equal to zero |
| `0<` | `( a -- f )`      | Negative |
| `0>` | `( a -- f )`      | Positive |

### Memory (8-byte cells)

| Word   | Stack effect           | Description |
|--------|------------------------|-------------|
| `@`    | `( addr -- val )`      | Fetch 64-bit cell |
| `!`    | `( val addr -- )`      | Store 64-bit cell |
| `+!`   | `( n addr -- )`        | Add `n` to cell at `addr` |
| `C@`   | `( addr -- byte )`     | Fetch byte |
| `C!`   | `( byte addr -- )`     | Store byte |
| `CEL+` | `( addr -- addr+8 )`   | Advance address by one cell |
| `CELL` | `( n -- n*8 )`         | Convert cell count to byte count |

### Return stack

| Word  | Data stack   | Return stack | Description |
|-------|--------------|--------------|-------------|
| `>R`  | `( a -- )`   | `( -- a )`   | Move to return stack |
| `R>`  | `( -- a )`   | `( a -- )`   | Move from return stack |
| `R@`  | `( -- a )`   | `( a -- a )` | Copy top of return stack |
| `RDP` | `( -- )`     | `( a -- )`   | Drop top of return stack |

### I/O

| Word   | Stack effect        | Description |
|--------|---------------------|-------------|
| `KEY`  | `( -- char )`       | Blocking read one byte from UART |
| `EMIT` | `( char -- )`       | Write one byte to UART |
| `CR`   | `( -- )`            | Emit CR+LF |
| `SPC`  | `( -- )`            | Emit space |
| `TYPE` | `( addr len -- )`   | Write byte string to UART |
| `.`    | `( n -- )`          | Print 16-digit hex + space (raw integer) |
| `.S`   | `( -- )`            | Print whole stack non-destructively (hex) |
| `WRDS` | `( -- )`            | List all visible dictionary entries |

### Variables and constants

Variable names push their **address**; use `@` / `!` to read / write.

| Word   | Kind     | Default   | Description |
|--------|----------|-----------|-------------|
| `HERE` | Variable | `DICT_BASE` | Next free dictionary address |
| `LTST` | Variable | *(boot)*  | Pointer to most-recent dictionary entry |
| `STAT` | Variable | `0`       | Interpreter state: `0`=interpret, `1`=compile |
| `BASE` | Variable | `10`      | Number base for literal parsing |
| `>IN`  | Variable | `0`       | Byte offset into TIB |
| `#TIB` | Variable | `0`       | Number of valid bytes in TIB |
| `TIB`  | Constant | `TIB_BASE`| Address of the terminal input buffer |
| `CEL`  | Constant | `8`       | Cell size in bytes |

### Compiler and dictionary words

| Word   | Stack effect                   | Description |
|--------|--------------------------------|-------------|
| `'`    | `( <name> -- xt )`             | Parse next word; push its execution token |
| `EXEC` | `( xt -- )`                    | Execute word by execution token |
| `FIND` | `( addr len -- entry \| 0 )`   | Dictionary lookup; 0 if not found |
| `NUM`  | `( addr len -- n true \| false )` | Try to parse string as integer in `BASE` |
| `WORD` | `( delim -- addr len )`        | Parse next delimited token from TIB |
| `IMM`  | `( -- )`                       | Mark most-recent definition as immediate |
| `HID`  | `( entry -- )`                 | Toggle hidden flag on a dictionary entry |
| `,`    | `( val -- )`                   | Append 64-bit cell to `HERE`; advance `HERE` |
| `C,`   | `( char -- )`                  | Append byte to `HERE` |
| `ALT`  | `( n -- )`                     | Advance `HERE` by `n` bytes |
| `ALN`  | `( -- )`                       | Align `HERE` to 8-byte boundary |
| `RFL`  | `( -- )`                       | Read one line from UART into TIB |

---

## 4. Defining Words and Control Flow

### Colon definitions

```forth
: SQUARE ( n -- n^2 )  DUP * ;
: CUBE   ( n -- n^3 )  DUP SQUARE * ;

5 SQUARE .   \ 0000000000000019  (= 25)
3 CUBE .     \ 000000000000001B  (= 27)
```

Stack comments `( before -- after )` are conventional; the parser ignores them
(no parenthesis comment word is defined — just don't try to use `(`).

### RECURSE

Self-call within a definition; works because the current word's entry address is
known at compile time.

```forth
: FACT ( n -- n! )
    DUP 1 > IF
        DUP 1- RECURSE *
    ELSE
        DROP 1
    THEN ;

5 FACT .   \ 0000000000000078  (= 120)
```

### IF / ELSE / THEN

```forth
: SIGN ( n -- -1|0|1 )
    DUP 0= IF  DROP 0  EXIT  THEN
    0< IF  -1  ELSE  1  THEN ;
```

Condition is Forth-boolean: `0` = false, any non-zero = true.

### BEGIN / UNTIL — post-test loop

Repeats until condition is **true** (non-zero):

```forth
: COUNTDOWN ( n -- )
    BEGIN
        DUP .  1-
    DUP 0= UNTIL
    DROP ;

5 COUNTDOWN   \ 0000000000000005 0000000000000004 ... 0000000000000001
```

### BEGIN / AGAIN — infinite loop

```forth
: ECHO  BEGIN  KEY EMIT  AGAIN ;
```

### BEGIN / WHILE / REPEAT — pre-test loop

Exits when condition is **false** (zero) at WHILE:

```forth
: SUM-TO ( n -- sum )
    0 SWAP              \ ( sum n )
    BEGIN DUP 0> WHILE
        OVER + SWAP 1-  \ add n to sum; decrement n
    REPEAT
    DROP ;

10 SUM-TO .   \ 0000000000000037  (= 55)
```

---

## 5. Noun Representation

Every Nock noun is a 64-bit tagged word.  The tag occupies the top two bits:

| Bits 63:62 | Type | Meaning |
|---|---|---|
| `0x` — bit 63 = 0 | **Direct atom** | Value = bits 62:0, range 0 … 2^63−1 |
| `10` | **Indirect atom** | Bits 61:0 = 62-bit BLAKE3 content hash into the atom store |
| `11` | **Cell** | Bits 31:0 = 32-bit heap pointer to `{head, tail}` |

**Direct atoms are their values.**  `direct(42) == 42`.  The noun word for the
integer 42 is the integer 42.  No encoding needed for small values.

`42 >NOUN .` prints `000000000000002A` — the noun word IS the value.

**Indirect atoms** arise when a value ≥ 2^63.  Their identity is the 62-bit prefix of
their BLAKE3 content hash, stored in an open-addressed hash table.  Two atoms with
the same bit pattern share the same noun word, so equality is `==`.

**Cells** are heap-allocated `(head, tail)` pairs.  `CONS` allocates one.

**Well-known values:**
- `0` — Nock YES (loob 0), `NOUN_ZERO`
- `1` — Nock NO (loob 1), `NOUN_ONE`

---

## 6. Noun Primitives

### Type conversion

| Word    | Stack effect      | Description |
|---------|-------------------|-------------|
| `>NOUN` | `( n -- noun )`   | Clear bit 63; wrap integer as direct atom |
| `NOUN>` | `( noun -- n )`   | Clear bit 63; extract integer from direct atom |

For atoms that fit in 63 bits, these are effectively identity operations.
`NOUN>` on a cell or indirect atom returns the raw 64-bit noun word unchanged
(useful for inspecting tags or passing to C).

```forth
42 >NOUN .         \ 000000000000002A  (noun = integer 42)
42 >NOUN NOUN> .   \ 000000000000002A  (same)
```

### Type tests

| Word    | Stack effect        | Returns |
|---------|---------------------|---------|
| `ATOM?` | `( noun -- flag )`  | `-1` if atom (direct or indirect), `0` if cell |
| `CELL?` | `( noun -- flag )`  | `-1` if cell, `0` if atom |
| `=NOUN` | `( n1 n2 -- flag )` | `-1` if structurally equal (deep compare), `0` otherwise |

```forth
42 >NOUN   ATOM? .       \ FFFFFFFFFFFFFFFF  (true)
1 >NOUN 2 >NOUN CONS  CELL? .  \ FFFFFFFFFFFFFFFF  (true)
1 >NOUN 1 >NOUN  =NOUN .       \ FFFFFFFFFFFFFFFF  (equal)
1 >NOUN 2 >NOUN  =NOUN .       \ 0000000000000000  (not equal)
```

### Cell operations

| Word   | Stack effect             | Description |
|--------|--------------------------|-------------|
| `CONS` | `( head tail -- cell )`  | Allocate and return a new cell |
| `CAR`  | `( cell -- head )`       | Left element (head) |
| `CDR`  | `( cell -- tail )`       | Right element (tail) |

```forth
1 >NOUN 2 >NOUN CONS    \ noun [1 2]
DUP CAR NOUN> .         \ 0000000000000001
CDR NOUN> .             \ 0000000000000002

\ Nested cell [1 [2 3]]
1 >NOUN
2 >NOUN 3 >NOUN CONS    \ [2 3]
CONS                    \ [1 [2 3]]
DUP CDR CAR NOUN> .     \ 0000000000000002  (head of tail)
CDR CDR NOUN> .         \ 0000000000000003  (tail of tail)
```

### BLAKE3 and HATOM

| Word    | Stack effect   | Description |
|---------|----------------|-------------|
| `HATOM` | `( n -- n )`   | No-op.  Atoms are always content-addressed by construction. |
| `B3OK`  | `( -- flag )`  | Run BLAKE3 official test vectors; `-1`=pass, `0`=fail |

```forth
B3OK .   \ FFFFFFFFFFFFFFFF  (pass)
```

### PILL

| Word   | Stack effect | Description |
|--------|--------------|-------------|
| `PILL` | `( -- atom )` | Load jammed atom from physical address `0x10000000`; returns `0` if no pill was loaded |

See §11 for the full pill workflow.

---

## 7. Nock Evaluation

### SLOT — tree addressing

```forth
SLOT  ( axis noun -- result )
```

Implements `/[axis subject]`.  Axis encodes a path in the binary tree using a
leading-1 sentinel bit; subsequent bits give head (`0`) / tail (`1`) steps:

| Axis | Path | Result |
|------|------|--------|
| 1 | — | Root (whole noun) |
| 2 | 0 | Head |
| 3 | 1 | Tail |
| 4 | 00 | Head of head |
| 5 | 01 | Tail of head |
| 6 | 10 | Head of tail |
| 7 | 11 | Tail of tail |
| 12 | 100 | Head of head of tail |
| 13 | 101 | Tail of head of tail |

```forth
1 >NOUN 2 >NOUN CONS   \ subject = [1 2]
DUP  2 >NOUN SWAP SLOT NOUN> .   \ 0000000000000001  (head)
     3 >NOUN SWAP SLOT NOUN> .   \ 0000000000000002  (tail)
```

### NOCK — the evaluator

```forth
NOCK  ( subject formula -- product )
```

Evaluates `*[subject formula]`.  The formula must be a noun (cell or atom).
Tail calls (ops 2, 6, 7, 8, 9, 10 static, 11) use `goto loop` — no C stack growth.

**Supported opcodes:**

| Op | Formula shape | Semantics |
|----|--------------|-----------|
| 0  | `[0 axis]` | Slot: `/[axis subject]` |
| 1  | `[1 val]` | Quote: return `val` unchanged |
| 2  | `[2 f g]` | Eval: `*[*[s f]  *[s g]]` |
| 3  | `[3 f]` | Wut: `0` if `*[s f]` is cell, `1` if atom |
| 4  | `[4 f]` | Lus: increment `*[s f]` |
| 5  | `[5 f g]` | Tis: `0` if `*[s f]` = `*[s g]`, else `1` |
| 6  | `[6 b c d]` | Branch: `*[s c]` if `*[s b]`=0, else `*[s d]` |
| 7  | `[7 f g]` | Compose: `*[*[s f]  g]` |
| 8  | `[8 f g]` | Pin: `*[[*[s f] s]  g]` |
| 9  | `[9 axis f]` | Invoke: `*[*[s f]  0  axis]` (arm call; checks jets) |
| 10 | `[10 [ax v] f]` | Edit: `#[ax *[s v]  *[s f]]` |
| 11 | `[11 [tag clue] f]` | Dynamic hint: evaluate `*[s clue]`, fire hint, eval `f` |
| 11 | `[11 atom f]` | Static hint (no-op; evaluate `f`) |

**Distribution rule** (formula head is a cell, not an opcode):

```
*[a [b c] d] = [*[a b c]  *[a d]]
```

### Building formulas on the stack

Formulas are cells, so construct them with `>NOUN` and `CONS`.

For a two-argument opcode `[op arg1 arg2]`:

```forth
op   >NOUN
arg1 >NOUN
arg2 >NOUN
CONS         \ [arg1 arg2]
CONS         \ [op [arg1 arg2]]
```

For a one-argument opcode `[op arg]`:

```forth
op  >NOUN
arg >NOUN
CONS
```

For the distribution rule, build each branch separately then combine:

```forth
\ [f g] (two sub-formulas f and g)
<build f>
<build g>
CONS
```

---

## 8. Bignum Arithmetic

Bignum words operate on **noun atoms** (not raw integers).  Inputs and outputs
are always nouns.

### Printing

| Word | Stack effect  | Description |
|------|---------------|-------------|
| `.`  | `( n -- )`    | Print raw 64-bit Forth integer as 16-digit hex |
| `N.` | `( noun -- )` | Print atom noun in decimal |

```forth
1000000000000 >NOUN N.    \ 1000000000000
```

> The REPL number parser only handles 64-bit integers.  To build large atoms
> (≥ 2^63) use `BNMUL`, `BN+`, or `BNLSH` on smaller atoms.

### Arithmetic words

| Word    | Stack effect          | Description |
|---------|-----------------------|-------------|
| `BN+`   | `( n1 n2 -- n )`      | Addition |
| `BNDEC` | `( n -- n )`          | Decrement; crashes on zero |
| `BNMUL` | `( n1 n2 -- n )`      | Multiplication (schoolbook O(n²)) |
| `BNDIV` | `( n1 n2 -- quot )`   | Integer quotient `floor(n1/n2)`; crashes if n2=0 |
| `BNMOD` | `( n1 n2 -- rem )`    | Euclidean remainder `n1 mod n2`; crashes if n2=0 |

```forth
\ 2^64 = 18446744073709551616
1 >NOUN 64 BNLSH  N.

\ 10^22 = 10000000000000000000000
10000000000 >NOUN
10000000000 >NOUN
BNMUL  N.

\ Integer division
17 >NOUN  5 >NOUN  BNDIV NOUN> .   \ 0000000000000003
17 >NOUN  5 >NOUN  BNMOD NOUN> .   \ 0000000000000002

\ Verify: (a/b)*b + a%b = a
100 >NOUN  7 >NOUN  2DUP
BNDIV  ROT BNMUL   \ 100/7 * 7 = 98
SWAP  100 >NOUN  ROT BNMOD   \ 100 mod 7 = 2
BN+  N.            \ 100
```

### Bit operations

| Word    | Stack effect          | Description |
|---------|-----------------------|-------------|
| `BNMET` | `( n -- k )`          | Significant bit count; `bn_met(0)=0`, `bn_met(1)=1`; **returns raw integer** |
| `BNBEX` | `( k -- n )`          | 2^k as noun atom; `k` is raw integer |
| `BNLSH` | `( n k -- n' )`       | Left-shift atom by k bits; `k` is raw integer |
| `BNRSH` | `( n k -- n' )`       | Right-shift atom by k bits; `k` is raw integer |
| `BNOR`  | `( n1 n2 -- n )`      | Bitwise OR |
| `BNAND` | `( n1 n2 -- n )`      | Bitwise AND |
| `BNXOR` | `( n1 n2 -- n )`      | Bitwise XOR |

```forth
\ 2^100
1 >NOUN 100 BNLSH  N.
\ 1267650600228229401496703205376

\ Bit length of 2^100
1 >NOUN 100 BNLSH  BNMET  .
\ 0000000000000065  (= 101)

\ 2^63 — the first indirect atom
1 >NOUN 63 BNLSH  N.    \ 9223372036854775808

\ XOR of two atoms
255 >NOUN  170 >NOUN  BNXOR NOUN> .
\ 0000000000000055  (= 85)
```

### Limits

`BN_MAX_LIMBS = 64` (4096 bits, ~1232 decimal digits).  Operations exceeding this
call `nock_crash`.

---

## 9. Noun Serialization — Jam / Cue

Nouns can be serialized to atoms (and back) using the standard Urbit jam/cue encoding.

| Word  | Stack effect        | Description |
|-------|---------------------|-------------|
| `JAM` | `( noun -- atom )`  | Serialize noun to an atom |
| `CUE` | `( atom -- noun )`  | Deserialize atom to noun |

```forth
\ Round-trip a small atom
42 >NOUN  JAM  CUE  NOUN> .
\ 000000000000002A  (= 42)

\ Round-trip a cell
1 >NOUN 2 >NOUN CONS   \ [1 2]
DUP JAM CUE            \ serialize then deserialize
=NOUN .                \ FFFFFFFFFFFFFFFF  (identical)

\ Inspect the jam of 0
0 >NOUN JAM  NOUN> .   \ 0000000000000001  (jam(0) = atom 1)

\ Inspect the jam of [0 0]
0 >NOUN DUP CONS  JAM  NOUN> .   \ 0000000000000031  (= 49)
```

**Encoding summary** (bits written LSB-first):

| Value | Bit pattern |
|-------|-------------|
| Atom `k` | `0` + `mat(k)` |
| Cell `[h t]` | `01` + `jam(h)` + `jam(t)` |
| Back-reference to bit pos `p` | `11` + `mat(p)` |

`mat(k)` is a self-describing integer encoding:
- `mat(0)` = single bit `1`
- `mat(k)` where `a = bn_met(k)`, `b = bit_length(a)`:
  `b` zero bits + `1` + `b-1` low bits of `a` + `a` bits of `k`

When an atom or cell appears more than once, `jam` may emit a back-reference
to its first occurrence if that is shorter.

The jam and cue caches are 128-slot open-addressed hash tables allocated on the C
stack; they are not persistent between calls.

---

## 10. Jet Dispatch

Jets are C functions that implement the semantics of specific Nock gates, registered
via `%wild` op-11 hints and dispatched from op-9 (`NOCK` call sites).

### Architecture

1. An op-11 `%wild` hint wraps a hinted sub-expression with a `$wilt` — a list of
   `[label [cape data]]` pairs where `cape`/`data` describe the matching subject
   pattern (a "sock").
2. When op-9 fires, before tail-calling the Nock arm, the evaluator iterates the
   active wilt list and calls `sock_match(cape, data, core)`.
3. On a match, `hot_lookup(label)` finds the C function in the statically compiled
   `hot_state[]` table.  The jet is called with the full core; it extracts its
   arguments via `slot(6, core)` (unary) or `slot(12, core)` / `slot(13, core)` (binary).
4. If no jet fires, the Nock arm executes normally.

Jets are **scoped**: a `%wild` registration lives only for the dynamic extent of the
hinted sub-expression.  There is no global mutable jet state.

### Active jets

| Label | Cord | Arguments at | Operation |
|-------|------|-------------|-----------|
| `%dec` | `6514020` | slot(6) | Decrement atom |
| `%add` | `6579297` | slot(12), slot(13) | Add |
| `%sub` | `6452595` | slot(12), slot(13) | Subtract; crashes if a < b |
| `%mul` | `7107949` | slot(12), slot(13) | Multiply |
| `%lth` | `6845548` | slot(12), slot(13) | `0` (YES) if a < b, else `1` (NO) |
| `%gth` | `6845543` | slot(12), slot(13) | `0` (YES) if a > b, else `1` (NO) |
| `%lte` | `6648940` | slot(12), slot(13) | `0` (YES) if a ≤ b, else `1` (NO) |
| `%gte` | `6648935` | slot(12), slot(13) | `0` (YES) if a ≥ b, else `1` (NO) |
| `%div` | `7760228` | slot(12), slot(13) | Integer quotient `floor(a/b)` |
| `%mod` | `6582125` | slot(12), slot(13) | Euclidean remainder `a mod b` |

Cord encoding: LSB = first ASCII character.
`%add` = `'a' + 'd'<<8 + 'd'<<16 = 97 + 25600 + 6553600 = 6579297`.

### Hint tag cords

| Tag | Decimal | Behavior |
|-----|---------|----------|
| `%wild` | `1684826487` | Parse `$wilt` clue; scope jet registrations |
| `%slog` | `1735355507` | Print clue noun to UART (`slog: ...`) |
| `%xray` | `2036429432` | Dump clue noun tree to UART (`xray: ...`) |
| `%mean` | `1684956509` | Stub (stack trace; Phase 7) |
| `%memo` | `1684826989` | Stub (memoization) |
| `%bout` | `1684956265` | Stub (timing) |

Unknown tags are silently ignored.

### Test preamble helpers

These words automate the construction of synthetic gate cores for jet testing.
They are defined in the test preamble but can be entered in any session:

```forth
: N>N  >NOUN ;

\ Build a unary gate core: ( sample -- core )
\ core = [battery=0  [sample  context=0]]
: JCORE1  0 N>N CONS  0 N>N SWAP CONS ;

\ Build a binary gate core: ( arg1 arg2 -- core )
\ core = [0  [[arg1 arg2]  0]]
\ slot(6,core) = [arg1 arg2];  slot(12,core) = arg1;  slot(13,core) = arg2
: JCORE2  CONS  0 N>N CONS  0 N>N SWAP CONS ;

\ Wrap core in an op-9 call formula: ( cord core -- subject formula )
\ formula = [9 [2 [1 core]]]  — calls slot 2 (battery) of the constant core
: JD  1 N>N SWAP CONS  2 N>N SWAP CONS  9 N>N SWAP CONS ;

\ Wrap in op-11 %wild hint so jets fire: ( subject formula -- subject formula' )
: JWRAP
    SWAP                            \ ( formula subject )
    1 N>N 0 N>N CONS CONS           \ sock = [label [1 0]]  (cape=1=wildcard)
    0 N>N CONS                      \ [[label sock] 0]  (singleton wilt list)
    1 N>N SWAP CONS                 \ [[label sock] 0] with tail
    1684826487 N>N SWAP CONS        \ [%wild wilt]
    SWAP CONS                       \ [[%wild wilt] formula]
    11 N>N SWAP CONS ;              \ [11 [[%wild wilt] formula]]
```

**Using the helpers:**

```forth
\ Pattern for a unary jet:
\ 0 N>N  <cord> N>N  <arg> N>N  JCORE1 JD JWRAP  NOCK  NOUN> .

\ Pattern for a binary jet:
\ 0 N>N  <cord> N>N  <a> N>N  <b> N>N  JCORE2 JD JWRAP  NOCK  NOUN> .

\ dec(5) = 4
0 N>N  6514020 N>N  5 N>N  JCORE1 JD JWRAP  NOCK  NOUN> .
\ 0000000000000004

\ add(100, 200) = 300
0 N>N  6579297 N>N  100 N>N  200 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .
\ 000000000000012C

\ div(17, 5) = 3
0 N>N  7760228 N>N  17 N>N  5 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .
\ 0000000000000003

\ mod(17, 5) = 2
0 N>N  6582125 N>N  17 N>N  5 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .
\ 0000000000000002

\ lth(3, 4) = YES (0)
0 N>N  6845548 N>N  3 N>N  4 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .
\ 0000000000000000
```

---

## 11. PILL Loading

A pill is a file containing a jammed noun, loaded into physical RAM by QEMU's device
loader before the kernel starts.  It provides a way to run pre-compiled Nock
formulas without manual REPL construction.

### File format (little-endian)

```
Offset 0 : uint64_t  — byte count of jam data (N)
Offset 8 : N bytes   — raw jam data
```

### Creating a pill from Python

```python
import struct

def write_pill(path, jam_bytes):
    with open(path, 'wb') as f:
        f.write(struct.pack('<Q', len(jam_bytes)))
        f.write(jam_bytes)

# Example: pill containing a literal noun (you need to produce the jam bytes)
write_pill('mypill.bin', my_jam_bytes)
```

The pill conventionally encodes `[subject formula]` so the REPL can
`PILL CUE DUP CAR SWAP CDR NOCK` to evaluate it.

### Running with a pill

```bash
make run-pill PILL=mypill.bin
```

This adds `-device loader,file=mypill.bin,addr=0x10000000,force-raw=on` to QEMU.

### Using PILL in the REPL

```forth
PILL           \ loads atom from 0x10000000; returns noun 0 if nothing loaded
PILL 0 >NOUN =NOUN IF  ." no pill"  ELSE
    CUE                \ decode jammed [subject formula] pair
    DUP CAR SWAP CDR   \ ( subject formula )
    NOCK               \ evaluate
THEN
```

If QEMU zeroed the region before loading (which it does by default), PILL returns
atom `0`.  Check before cueing.

---

## 12. Memory Layout

```
Address       Region                 Size     Notes
─────────────────────────────────────────────────────────────────
0x0008F000    TIB                    256 B    Terminal input buffer
0x00090000    Dictionary             ~3.5 MB  Grows upward from DICT_BASE
0x00470000    Data stack top         64 KB    Grows downward (DSTACK_SIZE)
0x00480000    Data stack / R-stack   64 KB    Return stack grows downward
0x00490000    Cell heap              32 MB    Bump allocator (alloc_cell)
0x06490000    Atom index             1 MB     65536 × 16-byte hash table
0x06590000    Atom data              4 MB     atom_t + limbs bump allocator
0x10000000    PILL load address      varies   QEMU -device loader target
0x3F000000    BCM2835 MMIO           —        UART, GPIO (memory-mapped)
```

**Stack canary:** `0xDEADF0C4` is written at the data stack guard address on boot.
Overflow is not automatically detected at runtime; use `.S` to check.

**Cell heap:** No garbage collector.  All `CONS` allocations live for the session.

**Atom store:** The 65536-slot index uses open addressing (linear probe) keyed on
the 62-bit BLAKE3 hash.  The bump allocator for atom bodies never frees.

---

## 13. Register Architecture

Four AArch64 registers are dedicated to the Forth VM:

| Register | Alias | Role |
|----------|-------|------|
| `x27` | `IP` | Instruction Pointer — next code cell to execute |
| `x26` | `DSP` | Data Stack Pointer — points TO top; grows downward |
| `x25` | `RSP` | Return Stack Pointer — points TO top; grows downward |
| `x24` | `W` | Working register — current dictionary entry |

These are AAPCS callee-saved (`x19`–`x28`), so C functions called from Forth words
preserve them automatically.  No explicit save/restore is needed around `bl` calls.

**NEXT macro** — central dispatch at end of every code word:

```asm
ldr W, [IP], #8    \ fetch next cell address into W; advance IP by 8
ldr x0, [W]        \ load the codeword pointer from that entry
br  x0             \ jump to the machine code
```

**Stack push / pop:**

```asm
str x0, [DSP, #-8]!   \ push x0  (pre-decrement, then store)
ldr x0, [DSP], #8     \ pop into x0  (load, then post-increment)
```

**Dictionary entry layout (32-byte header):**

```
+0   link     (8 B)  — pointer to previous entry (0 = start of chain)
+8   flags    (8 B)  — byte 0: name length (max 7)
                       byte 1: F_IMMEDIATE=0x80, F_HIDDEN=0x40
+16  name     (8 B)  — ASCII, zero-padded (max 7 characters)
+24  codeword (8 B)  — pointer to machine code (DOCOL / DOCON / DOVAR / native)
+32  body     (var)  — colon def: list of xt addresses; variable: cell; constant: value
```

---

## 14. Worked Nock Examples

The following examples build Nock formulas entirely in Forth using `>NOUN` and `CONS`,
then evaluate them with `NOCK`.

For convenience, define the preamble helpers first:

```forth
: N>N  >NOUN ;
: C>N  N>N SWAP N>N SWAP CONS ;
```

---

### Op 0 — Slot (tree address lookup)

```
*[a  [0 axis]]  =  /[axis a]
```

```forth
\ *[42 [0 1]] = /[1 42] = 42  (whole subject)
42 N>N
0 N>N  1 N>N CONS        \ formula = [0 1]
NOCK NOUN> .             \ 000000000000002A

\ *[[1 2] [0 2]] = head = 1
1 2 C>N                  \ subject = [1 2]
0 N>N  2 N>N CONS
NOCK NOUN> .             \ 0000000000000001

\ *[[1 2] [0 3]] = tail = 2
1 2 C>N
0 N>N  3 N>N CONS
NOCK NOUN> .             \ 0000000000000002

\ *[[[1 2] [3 4]] [0 5]] = tail of head = 2
1 N>N 2 N>N CONS  3 N>N 4 N>N CONS  CONS   \ [[1 2] [3 4]]
0 N>N  5 N>N CONS
NOCK NOUN> .             \ 0000000000000002
```

---

### Op 1 — Quote (constant)

```
*[a  [1 val]]  =  val
```

```forth
\ *[_ [1 99]] = 99
0 N>N
1 N>N  99 N>N CONS
NOCK NOUN> .             \ 0000000000000063

\ Constant cell: *[_ [1 [1 2]]] = [1 2]
0 N>N
1 N>N  1 2 C>N CONS
NOCK                     \ product is cell [1 2]
DUP CAR NOUN> .          \ 0000000000000001
    CDR NOUN> .          \ 0000000000000002
```

---

### Op 3 — Wut (type test)

```
*[a  [3 f]]  =  0  if  *[a f]  is a cell
             =  1  if  *[a f]  is an atom
```

```forth
\ Is 42 a cell? No → 1
42 N>N
3 N>N  0 N>N  1 N>N CONS CONS   \ formula = [3 [0 1]]
NOCK NOUN> .                     \ 0000000000000001  (atom → NO)

\ Is [1 2] a cell? Yes → 0
1 2 C>N
3 N>N  0 N>N  1 N>N CONS CONS
NOCK NOUN> .                     \ 0000000000000000  (cell → YES)
```

---

### Op 4 — Lus (increment atom)

```
*[a  [4 f]]  =  +(*[a f])
```

```forth
\ *[41 [4 [0 1]]] = +41 = 42
41 N>N
4 N>N  0 N>N  1 N>N CONS CONS
NOCK NOUN> .             \ 000000000000002A

\ Chain two increments: *[0 [4 [4 [0 1]]]]
0 N>N
4 N>N
    4 N>N  0 N>N  1 N>N CONS CONS   \ inner [4 [0 1]]
CONS
NOCK NOUN> .             \ 0000000000000002
```

---

### Op 5 — Tis (equality)

```
*[a  [5 f g]]  =  0  if  *[a f] = *[a g]
               =  1  otherwise
```

```forth
\ Same constant: *[_ [5 [1 42] [1 42]]] = 0 (YES)
0 N>N
5 N>N
    1 N>N  42 N>N CONS        \ [1 42]
    1 N>N  42 N>N CONS        \ [1 42]
    CONS                      \ [[1 42] [1 42]]
CONS
NOCK NOUN> .             \ 0000000000000000

\ Different: *[_ [5 [1 1] [1 2]]] = 1 (NO)
0 N>N
5 N>N  1 N>N 1 N>N CONS  1 N>N 2 N>N CONS  CONS  CONS
NOCK NOUN> .             \ 0000000000000001
```

---

### Op 6 — Branch (if-then-else)

```
*[a  [6 cond then else]]  =  *[a then]  if  *[a cond] = 0
                           =  *[a else]  if  *[a cond] = 1
```

```forth
\ Condition YES (0) → take then-branch (42)
0 N>N
6 N>N
    1 N>N  0 N>N CONS        \ cond = [1 0]  (always YES)
    1 N>N  42 N>N CONS       \ then = [1 42]
    1 N>N  99 N>N CONS       \ else = [1 99]
    CONS CONS
CONS
NOCK NOUN> .             \ 000000000000002A  (42)

\ Condition NO (1) → take else-branch (99)
0 N>N
6 N>N
    1 N>N  1 N>N CONS        \ cond = [1 1]  (always NO)
    1 N>N  42 N>N CONS
    1 N>N  99 N>N CONS
    CONS CONS
CONS
NOCK NOUN> .             \ 0000000000000063  (99)

\ Dynamic condition: branch on whether subject is 0
\ *[0 [6 [3 [0 1]] [1 99] [1 42]]]
\ = wut(0) = 1 (atom) → else branch = 42
0 N>N
6 N>N
    3 N>N  0 N>N  1 N>N CONS CONS   \ cond: wut(subject)
    1 N>N  99 N>N CONS
    1 N>N  42 N>N CONS
    CONS CONS
CONS
NOCK NOUN> .             \ 000000000000002A  (42, subject is atom)
```

---

### Op 7 — Compose (sequence two formulas)

```
*[a  [7 f g]]  =  *[*[a f]  g]
```

```forth
\ *[5 [7 [4 [0 1]] [4 [0 1]]]] = (5+1)+1 = 7
5 N>N
7 N>N
    4 N>N  0 N>N  1 N>N CONS CONS   \ f = increment subject
    4 N>N  0 N>N  1 N>N CONS CONS   \ g = increment result
    CONS
CONS
NOCK NOUN> .             \ 0000000000000007
```

---

### Op 8 — Pin (extend subject)

```
*[a  [8 f g]]  =  *[[*[a f]  a]  g]
```

```forth
\ Pin 99 onto subject 42; then take head of new subject
\ *[42 [8 [1 99] [0 2]]] = head of [99 42] = 99
42 N>N
8 N>N
    1 N>N  99 N>N CONS      \ pin formula: constant 99
    0 N>N  2 N>N CONS       \ body formula: take head (axis 2)
    CONS
CONS
NOCK NOUN> .             \ 0000000000000063  (99)

\ Pin 99 and then increment it: *[0 [8 [1 99] [4 [0 2]]]]
0 N>N
8 N>N
    1 N>N  99 N>N CONS
    4 N>N  0 N>N  2 N>N CONS CONS   \ body: lus(head of extended subject)
    CONS
CONS
NOCK NOUN> .             \ 0000000000000064  (100)
```

---

### Op 10 — Hax (tree edit)

Op 10 is the axiomatic `#` hax operator.  It takes an axis `b`, evaluates
replacement formula `c` and target formula `d` against the same subject, then
returns `d`'s result with address `b` replaced by `c`'s result.  The `[b c]`
pair **must** be a cell; an atom in that position is a Nock crash.

```
*[a  10  [axis val-f]  target-f]  =  #[axis  *[a val-f]  *[a target-f]]
```

```forth
\ Replace head of [1 2] with 99:
\ #[2 99 [1 2]] = [99 2]
0 N>N
10 N>N
    2 N>N  1 N>N  99 N>N CONS CONS   \ [2 [1 99]]  (axis=2, new-val=const 99)
    1 N>N  1 2 C>N CONS              \ [1 [1 2]]   (target = constant [1 2])
    CONS
CONS
NOCK                     \ product = [99 2]
DUP CAR NOUN> .          \ 0000000000000063  (99)
    CDR NOUN> .          \ 0000000000000002  (2)

\ Replace tail of subject [10 20] with 99:
\ *[[10 20] [10 [3 [1 99]] [0 1]]]
10 N>N 20 N>N CONS
10 N>N
    3 N>N  1 N>N  99 N>N CONS CONS   \ [3 [1 99]]  (axis=3, val=const 99)
    0 N>N  1 N>N CONS               \ [0 1]  (target = whole subject)
    CONS
CONS
NOCK                     \ [10 99]
DUP CAR NOUN> .          \ 000000000000000A  (10)
    CDR NOUN> .          \ 0000000000000063  (99)
```

---

### Op 11 — Hints

**Static hint** (atom tag, no clue — pure no-op):

```forth
\ *[42 [11 99 [4 [0 1]]]] = +42 = 43  (hint tag 99 is ignored)
42 N>N
11 N>N
    99 N>N                           \ static hint tag (any atom)
    4 N>N  0 N>N  1 N>N CONS CONS   \ body: increment
    CONS
CONS
NOCK NOUN> .             \ 000000000000002B  (43)
```

**Dynamic hint with %slog** (prints clue to UART):

```forth
\ %slog prints clue, then evaluates body
42 N>N
11 N>N
    1735355507 N>N               \ %slog cord
    0 N>N  1 N>N CONS           \ clue formula = [0 1] = subject
    CONS                         \ [%slog [0 1]]
    4 N>N  0 N>N  1 N>N CONS CONS   \ body: increment
    CONS                         \ [[%slog clue] body]
CONS
NOCK NOUN> .
\ UART output: slog: 2a
\ Stack result: 000000000000002B  (43)
```

---

### Op 9 — Invoke (arm call with jet)

Op 9 evaluates a sub-formula to get a core, extracts an arm at an axis, and
tail-calls it.  The jet hooks at this point.

The JCORE2/JD/JWRAP helpers build a synthetic core for testing:

```forth
\ add(3, 4) via jet %add
\ JCORE2 builds core = [0 [[3 4] 0]]
\ JD wraps: formula = [9 [2 [1 core]]]
\ JWRAP adds: [11 [[%wild [[%add [1 0]] 0]] formula]]
0 N>N  6579297 N>N  3 N>N  4 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .
\ 0000000000000007

\ sub(10, 3)
0 N>N  6452595 N>N  10 N>N  3 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .
\ 0000000000000007

\ mul(6, 7)
0 N>N  7107949 N>N  6 N>N  7 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .
\ 000000000000002A  (42)

\ lth(3, 4) → YES (0)
0 N>N  6845548 N>N  3 N>N  4 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .
\ 0000000000000000

\ div(100, 7) = 14
0 N>N  7760228 N>N  100 N>N  7 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .
\ 000000000000000E  (14)

\ mod(100, 7) = 2
0 N>N  6582125 N>N  100 N>N  7 N>N  JCORE2 JD JWRAP  NOCK  NOUN> .
\ 0000000000000002

\ Large bignum: mul(10^11, 10^11) via jet
0 N>N  7107949 N>N
100000000000 N>N  100000000000 N>N
JCORE2 JD JWRAP  NOCK  N.
\ 10000000000000000000000  (= 10^22)
```

---

### Op 2 — Eval (apply computed formula)

```
*[a  [2 subject-f formula-f]]  =  *[*[a subject-f]  *[a formula-f]]
```

```forth
\ *[0 [2 [1 42] [1 [4 [0 1]]]]] = *[42 [4 [0 1]]] = 43
0 N>N
2 N>N
    1 N>N  42 N>N CONS              \ subject formula: constant 42
    1 N>N
        4 N>N  0 N>N  1 N>N CONS CONS   \ formula formula: constant [4 [0 1]]
    CONS
    CONS
CONS
NOCK NOUN> .             \ 000000000000002B  (43)
```

---

### Jam / Cue round-trip

```forth
\ Build a noun, serialize, deserialize, verify
1 N>N 2 N>N CONS   3 N>N 4 N>N CONS   CONS   \ [[1 2] [3 4]]
DUP                                            \ save for comparison
JAM                                            \ serialize
CUE                                            \ deserialize
=NOUN .                                        \ FFFFFFFFFFFFFFFF (equal)

\ Inspect jam of small atoms
0 >NOUN JAM NOUN> .   \ 0000000000000001  (jam(0) = 1)
1 >NOUN JAM NOUN> .   \ 000000000000000C  (jam(1) = 12)
2 >NOUN JAM NOUN> .   \ 0000000000000048  (jam(2) = 72)
```

---

### Iterative computation with Forth wrapping Nock

Use Forth loops around NOCK to iterate a Nock step-function:

```forth
\ Apply *[subj [4 [0 1]]] ten times: increment subject 10 times
0 N>N           \ initial subject (atom 0)
4 N>N  0 N>N  1 N>N CONS CONS   \ formula: increment

10 0 DO
    OVER OVER SWAP NOCK SWAP DROP   \ ( formula result ) then drop old subj
    \ actually need to rotate carefully:
LOOP
```

A cleaner pattern keeps the formula on the return stack:

```forth
: ITERATE-INC ( n -- result )
    \ Apply [4 [0 1]] n times to 0
    0 N>N           \ starting subject
    SWAP 0 DO
        4 N>N  0 N>N  1 N>N CONS CONS SWAP NOCK
    LOOP ;
\ Note: DO/LOOP is not implemented; use BEGIN/UNTIL instead:

: ITER-INC-BU ( start-noun n -- result )
    BEGIN
        DUP 0 >
    WHILE
        SWAP
        4 N>N  0 N>N  1 N>N CONS CONS   \ formula = [4 [0 1]]
        SWAP NOCK                        \ *[current formula]
        SWAP 1-                          \ decrement counter
    REPEAT
    DROP ;

0 N>N  10  ITER-INC-BU  NOUN> .   \ 000000000000000A  (10)
```

---

## Appendix A: Cord Value Reference

Urbit cords encode ASCII strings little-endian (LSB = first character).
`"ab"` = `'a' + 'b'*256` = `97 + 25600` = `25697`.

| String | Decimal | Calculation |
|--------|---------|-------------|
| `%dec` | `6514020` | `'d'+'e'×256+'c'×65536` |
| `%add` | `6579297` | `'a'+'d'×256+'d'×65536` |
| `%sub` | `6452595` | `'s'+'u'×256+'b'×65536` |
| `%mul` | `7107949` | `'m'+'u'×256+'l'×65536` |
| `%lth` | `6845548` | `'l'+'t'×256+'h'×65536` |
| `%gth` | `6845543` | `'g'+'t'×256+'h'×65536` |
| `%lte` | `6648940` | `'l'+'t'×256+'e'×65536` |
| `%gte` | `6648935` | `'g'+'t'×256+'e'×65536` |
| `%div` | `7760228` | `'d'+'i'×256+'v'×65536` |
| `%mod` | `6582125` | `'m'+'o'×256+'d'×65536` |
| `%wild` | `1684826487` | `'w'+'i'×256+'l'×65536+'d'×16777216` |
| `%slog` | `1735355507` | `'s'+'l'×256+'o'×65536+'g'×16777216` |
| `%xray` | `2036429432` | `'x'+'r'×256+'a'×65536+'y'×16777216` |

**Quick check:** `BASE 16 ! 646C6977 .` prints `646C6977` = `'d'|'l'<<8|'i'<<16|'w'<<24`
= `"wild"` in memory — that is `%wild` = `1684826487` decimal.

---

## Appendix B: Nock Quick Reference

```
Reduction rules:

  *[a 0 b]           /[b a]
  *[a 1 b]           b
  *[a 2 b c]         *[*[a b] *[a c]]
  *[a 3 b]           ?(*[a b])        0=cell, 1=atom
  *[a 4 b]           +(*[a b])        increment
  *[a 5 b c]         =(*[a b] *[a c]) 0=same, 1=differ
  *[a 6 b c d]       *[a c] if *[a b]=0, else *[a d]
  *[a 7 b c]         *[*[a b] c]
  *[a 8 b c]         *[[*[a b] a] c]
  *[a 9 b c]         let core=*[a c] in *[core 0 b]   (arm call)
  *[a 10 [b c] d]    #[b *[a c] *[a d]]               (tree edit; [b c] must be a cell)
  *[a 11 [b c] d]    *[a d] (after evaluating *[a c])  (dynamic hint)
  *[a 11 b c]        *[a c]                            (static hint)
  *[a [b c] d]       [*[a b c] *[a d]]                (distribution)

Slot rules:

  /[1 a]             a
  /[2 [h t]]         h
  /[3 [h t]]         t
  /[(2*k) a]         /[k /[2 a]]
  /[(2*k+1) a]       /[k /[3 a]]

Edit rules:

  #[1 v t]           v
  #[2 v [h t]]       [v t]
  #[3 v [h t]]       [h v]
  #[(2*k) v t]       edit head of sub-tree at k
  #[(2*k+1) v t]     edit tail of sub-tree at k

Nock booleans:  0 = YES (true), 1 = NO (false)

Loob (loobean):  same convention;  NOUN_YES = 0,  NOUN_NO = 1
```

---

*Document reflects Phases 0–5e; 157 tests passing.*
