# Forth Word Reference

This document lists every word currently defined in `src/forth.s`, organized by category.
All names are the actual dictionary names (max 7 chars).

Stack notation: `( before -- after )`, `R( return-stack-before -- after )`.
Flags: **true** = -1 (all ones), **false** = 0.

---

## Stack Primitives

| Word   | Stack effect            | Notes                          |
|--------|-------------------------|--------------------------------|
| `DROP` | `( a -- )`              |                                |
| `DUP`  | `( a -- a a )`          |                                |
| `SWAP` | `( a b -- b a )`        |                                |
| `OVER` | `( a b -- a b a )`      |                                |
| `ROT`  | `( a b c -- b c a )`    |                                |
| `-ROT` | `( a b c -- c a b )`    |                                |
| `NIP`  | `( a b -- b )`          |                                |
| `2DUP` | `( a b -- a b a b )`    |                                |
| `2DRP` | `( a b -- )`            | Drop two items                 |
| `?DUP` | `( a -- a a \| 0 )`     | Dup only if non-zero           |
| `DPTH` | `( -- n )`              | Number of items on stack       |

---

## Arithmetic

| Word   | Stack effect            | Notes                          |
|--------|-------------------------|--------------------------------|
| `+`    | `( a b -- a+b )`        |                                |
| `-`    | `( a b -- a-b )`        |                                |
| `*`    | `( a b -- a*b )`        |                                |
| `/MOD` | `( a b -- rem quot )`   | Remainder on top, quotient below (non-ANS order) |
| `/`    | `( a b -- a/b )`        | Truncated quotient                               |
| `MOD`  | `( a b -- a mod b )`    | Truncated remainder                              |
| `NEG`  | `( a -- -a )`           |                                |
| `ABS`  | `( a -- \|a\| )`        |                                |
| `1+`   | `( a -- a+1 )`          |                                |
| `1-`   | `( a -- a-1 )`          |                                |
| `2*`   | `( a -- a*2 )`          | Arithmetic left shift by 1     |
| `2/`   | `( a -- a/2 )`          | Arithmetic right shift by 1    |

---

## Comparisons

All comparisons produce **true** (-1) or **false** (0).

| Word  | Stack effect       | Notes              |
|-------|--------------------|--------------------|
| `=`   | `( a b -- flag )`  |                    |
| `<>`  | `( a b -- flag )`  | Not equal          |
| `<`   | `( a b -- flag )`  | Signed             |
| `>`   | `( a b -- flag )`  | Signed             |
| `<=`  | `( a b -- flag )`  | Signed             |
| `>=`  | `( a b -- flag )`  | Signed             |
| `U<`  | `( a b -- flag )`  | Unsigned less-than |
| `0=`  | `( a -- flag )`    |                    |
| `0<`  | `( a -- flag )`    |                    |
| `0>`  | `( a -- flag )`    |                    |

---

## Bitwise / Logic

| Word  | Stack effect         | Notes                    |
|-------|----------------------|--------------------------|
| `AND` | `( a b -- a&b )`     |                          |
| `OR`  | `( a b -- a\|b )`    |                          |
| `XOR` | `( a b -- a^b )`     |                          |
| `INV` | `( a -- ~a )`        | Bitwise invert (INVERT)  |
| `LSH` | `( a n -- a<<n )`    | Logical left shift       |
| `RSH` | `( a n -- a>>n )`    | Logical right shift      |

---

## Memory

Cell size is 8 bytes (64-bit).

| Word   | Stack effect           | Notes                           |
|--------|------------------------|---------------------------------|
| `@`    | `( addr -- val )`      | Fetch 64-bit cell               |
| `!`    | `( val addr -- )`      | Store 64-bit cell               |
| `+!`   | `( n addr -- )`        | Add n to cell at addr           |
| `C@`   | `( addr -- char )`     | Fetch byte                      |
| `C!`   | `( char addr -- )`     | Store byte                      |
| `CEL+` | `( addr -- addr+8 )`   | Advance address by one cell     |
| `CELL` | `( n -- n*8 )`         | Convert cells to bytes (CELLS)  |

---

## Return Stack

| Word  | Stack effect                           | Notes           |
|-------|----------------------------------------|-----------------|
| `>R`  | `( a -- )` `R( -- a )`                | Push to rstack  |
| `R>`  | `( -- a )` `R( a -- )`                | Pop from rstack |
| `R@`  | `( -- a )` `R( a -- a )`              | Copy top rstack |
| `RDP` | `( -- )` `R( a -- )`                  | Drop top rstack (RDROP) |

---

## I/O

| Word   | Stack effect        | Notes                                          |
|--------|---------------------|------------------------------------------------|
| `KEY`  | `( -- char )`       | Blocking read one byte from UART               |
| `EMIT` | `( char -- )`       | Write one byte to UART                         |
| `CR`   | `( -- )`            | Emit CR+LF                                     |
| `SPC`  | `( -- )`            | Emit space (SPACE)                             |
| `TYPE` | `( addr len -- )`   | Write byte string to UART                      |
| `.`    | `( n -- )`          | Print TOS as 16-digit hex + space              |
| `.S`   | `( -- )`            | Print entire stack non-destructively (hex)     |

> Note: `.` prints hexadecimal. Decimal output requires bignum division (Phase 4).

---

## Variables

Variables are accessed with `@` and `!`. Each variable name pushes its address.

| Word   | Initial value     | Notes                               |
|--------|-------------------|-------------------------------------|
| `HERE` | `DICT_BASE`       | Next free dictionary address        |
| `LTST` | *(set at boot)*   | Most recent dictionary entry (LATEST) |
| `STAT` | `0`               | Interpreter state: 0=interpret, 1=compile (STATE) |
| `BASE` | `10`              | Number base for input parsing       |
| `>IN`  | `0`               | Byte offset into TIB                |
| `#TIB` | `0`               | Number of valid bytes in TIB        |

---

## Constants

Constants push their value directly.

| Word  | Value          | Notes                  |
|-------|----------------|------------------------|
| `TIB` | `TIB_BASE`     | Address of input buffer |
| `CEL` | `8`            | Cell size in bytes      |

---

## Compiler Words

| Word      | Stack effect          | Flags     | Notes                                       |
|-----------|-----------------------|-----------|---------------------------------------------|
| `:`       | `( -- )`              |           | Begin colon definition; parses name, enters compile mode |
| `;`       | `( -- )`              | IMMEDIATE | End colon definition; compiles EXIT, unhides word |
| `[`       | `( -- )`              | IMMEDIATE | Enter interpret mode                        |
| `]`       | `( -- )`              |           | Enter compile mode                          |
| `'`       | `( <name> -- xt )`    |           | Push execution token of next parsed word    |
| `IMM`     | `( -- )`              |           | Mark most-recent definition as immediate (IMMEDIATE) |
| `HID`     | `( entry -- )`        |           | Toggle hidden flag on a dictionary entry    |
| `EXEC`    | `( xt -- )`           |           | Execute word by execution token             |

---

## Control Flow  *(compile-time, IMMEDIATE)*

These words run at compile time and emit branch instructions into the current definition.

| Word      | Compile-time stack              | Notes                                        |
|-----------|---------------------------------|----------------------------------------------|
| `IF`      | `( -- fixup )`                  | Compile conditional forward branch           |
| `THEN`    | `( fixup -- )`                  | Patch forward branch to here                 |
| `ELSE`    | `( fixup_if -- fixup_else )`    | Compile unconditional skip; patch IF branch  |
| `BEGIN`   | `( -- loop_addr )`              | Mark loop-back target                        |
| `UNTIL`   | `( loop_addr -- )`              | Branch back if false (0); exit when true     |
| `AGAIN`   | `( loop_addr -- )`              | Unconditional branch back (infinite loop)    |
| `WHILE`   | `( loop_addr -- loop_addr fixup )` | Conditional exit from `BEGIN...REPEAT` loop |
| `REPEAT`  | `( loop_addr fixup -- )`        | Close `BEGIN...WHILE...REPEAT` loop          |
| `RECURSE` | `( -- )`                        | Compile a call to the word currently being defined |

**Patterns:**
```
IF ... THEN
IF ... ELSE ... THEN
BEGIN ... UNTIL       ( loops while condition is false )
BEGIN ... AGAIN       ( infinite loop )
BEGIN ... WHILE ... REPEAT
```

---

## Dictionary / Compilation Utilities

| Word   | Stack effect       | Notes                                         |
|--------|--------------------|-----------------------------------------------|
| `,`    | `( val -- )`       | Append 64-bit cell to HERE; advance HERE      |
| `C,`   | `( char -- )`      | Append byte to HERE; advance HERE by 1        |
| `ALT`  | `( n -- )`         | Advance HERE by n bytes (ALLOT)               |
| `ALN`  | `( -- )`           | Align HERE to next 8-byte boundary (ALIGN)    |
| `WORD` | `( delim -- addr len )` | Parse next delim-delimited token from TIB into HERE (non-destructively) |
| `FIND` | `( addr len -- entry \| 0 )` | Search dictionary; returns entry address or 0 |
| `NUM`  | `( addr len -- n true \| false )` | Parse string as integer in BASE; supports leading `-` and hex digits A-F |
| `RFL`  | `( -- )`           | Read one line from UART into TIB (REFILL)     |

---

## Debug / Introspection

| Word   | Stack effect  | Notes                                      |
|--------|---------------|--------------------------------------------|
| `.S`   | `( -- )`      | Print all stack items as hex (non-destructive) |
| `WRDS` | `( -- )`      | Print names of all visible dictionary entries (WORDS) |

---

## Noun Primitives  *(Phase 2 — Nock noun heap)*

Nouns are 64-bit tagged values. Tag bits 63:62: `00`=cell, `01`=direct atom, `10`=indirect atom, `11`=content hash.

| Word    | Stack effect               | Notes                                                   |
|---------|----------------------------|---------------------------------------------------------|
| `>NOUN` | `( n -- noun )`            | Wrap raw integer as a direct atom (tag=01)              |
| `NOUN>` | `( noun -- n )`            | Extract raw integer from a direct atom                  |
| `ATOM?` | `( noun -- flag )`         | True (-1) if atom; false (0) if cell                    |
| `CELL?` | `( noun -- flag )`         | True (-1) if cell; false (0) if atom                    |
| `=NOUN` | `( n1 n2 -- flag )`        | Structural equality (deep comparison)                   |
| `CONS`  | `( head tail -- cell )`    | Allocate a cell noun                                    |
| `CAR`   | `( cell -- head )`         | Head of a cell noun                                     |
| `CDR`   | `( cell -- tail )`         | Tail of a cell noun                                     |
| `HATOM` | `( noun -- noun' )`        | Compute BLAKE3 hash of an indirect atom; fills `atom->blake3[]`; passthrough for direct atoms and cells |
| `B3OK`  | `( -- flag )`              | Run official BLAKE3 test vectors; 1=pass, 0=fail        |

---

## Bignum Primitives  *(Phase 4 — arbitrary-precision atoms)*

Atoms larger than 2^62-1 are stored as indirect `atom_t` structs on the heap.
All arithmetic operates on atom nouns; see `BIGNUM.md` for the full implementation reference.

| Word    | Stack effect          | Notes                                                          |
|---------|-----------------------|----------------------------------------------------------------|
| `N.`    | `( noun -- )`         | Print atom as decimal digits + space                          |
| `BN+`   | `( n1 n2 -- n )`      | Add two atom nouns                                            |
| `BNDEC` | `( noun -- noun )`    | Decrement atom; crashes on zero                               |
| `BNMET` | `( noun -- n )`       | Significant bit length (raw integer); 0 for atom 0           |
| `BNBEX` | `( n -- noun )`       | 2^n as atom noun; n is raw integer                            |
| `BNLSH` | `( noun n -- noun )`  | Left-shift atom by n bits; n is raw integer                   |
| `BNRSH` | `( noun n -- noun )`  | Right-shift atom by n bits; n is raw integer                  |
| `BNOR`  | `( n1 n2 -- n )`      | Bitwise OR                                                    |
| `BNAND` | `( n1 n2 -- n )`      | Bitwise AND                                                   |
| `BNXOR` | `( n1 n2 -- n )`      | Bitwise XOR                                                   |
| `BNMUL` | `( n1 n2 -- n )`      | Multiply two atom nouns                                       |

> Note: the REPL number parser is 64-bit native. Atoms larger than 2^62-1 must be constructed via Nock (repeated `op 4`) or `BN+`, not by typing large decimal literals.

---

## Nock Primitives  *(Phase 3 — Nock 4K evaluator)*

| Word   | Stack effect                      | Notes                                            |
|--------|-----------------------------------|--------------------------------------------------|
| `SLOT` | `( axis noun -- result )`         | Nock `/` operator: tree address lookup           |
| `NOCK` | `( subject formula -- product )`  | Nock 4K evaluator (ops 0–11, TCO, hints, jets)   |

**Test formula pattern** (assembling formulas on the stack):
```
subj N>N   OP N>N   arg1 N>N   CONS   CONS   NOCK
```
Each opcode digit must be the head of the formula cell.

---

## Internal / Runtime Words

These words exist in the dictionary but are not normally typed at the prompt.

| Word      | Notes                                                             |
|-----------|-------------------------------------------------------------------|
| `LIT`     | Pushes the next cell in the instruction stream as a literal       |
| `BRN`     | Unconditional relative branch (runtime for `AGAIN`/`ELSE`/`REPEAT`) |
| `0BRN`    | Branch if TOS = 0 (runtime for `IF`/`UNTIL`/`WHILE`)             |
| `QUIT`    | Top-level interpreter loop; never returns; resets stacks on error |
| `EXIT`    | Return from a colon definition (compiled by `;`)                  |

---

## Notes

- **Number input**: `BASE` defaults to 10. Hex digits A–F are accepted in `NUM`. Hex `0x` prefix is **not** supported; use decimal or set `BASE` to 16 first.
- **Output**: `.` prints 64-bit hex. Decimal printing requires bignum (Phase 4).
- **Name length**: Dictionary names are capped at 7 characters (8-byte field, null-padded).
- **Forth true/false**: true = -1 (all bits set), false = 0.
- **Cell size**: 64-bit (8 bytes) throughout.
