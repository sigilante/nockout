# Bignum Implementation

Arbitrary-precision integer (atom) arithmetic for the Fock bare-metal Nock kernel.
Source: `src/bignum.h`, `src/bignum.c`.

---

## Representation

Every Nock atom is a 64-bit `noun` word. Bits 63:62 encode the tag:

| Tag | Name       | Meaning                                                         |
|-----|------------|-----------------------------------------------------------------|
| 01  | direct     | Value in bits 61:0. Range: 0 … 2^62-1.                        |
| 10  | indirect   | Bits 61:32 = 30-bit BLAKE3 prefix; bits 31:0 = heap pointer to `atom_t`. |

**Canonical invariant:** any value that fits in 62 bits is *always* a direct atom. `alloc_indirect` is never called when the value is < 2^62. Every bignum function upholds this through `bn_normalize`.

### `atom_t` heap struct

```c
typedef struct atom {
    uint64_t  size;       /* number of 64-bit limbs                       */
    uint32_t  blake3[8];  /* 256-bit BLAKE3 hash; all-zero = not computed */
    uint64_t  limbs[];    /* little-endian: limbs[0] = least significant  */
} atom_t;
```

Limbs are **little-endian**: `limbs[0]` holds the least significant 64 bits. The MSL invariant: `limbs[size-1] != 0` when `size > 1` (no trailing zero limbs). Both invariants are established by `bn_normalize`.

The canonical boundary:
```
2^62     = 0x4000_0000_0000_0000  — smallest indirect atom (size=1, limbs[0]=2^62)
2^62 - 1 = 0x3FFF_FFFF_FFFF_FFFF — largest direct atom
```

---

## Public API

### Core normalizer

```c
noun bn_normalize(uint64_t *limbs, uint64_t size);
```

Given a scratch limb array, produce a canonical noun. Strips trailing zero limbs, then either promotes to `direct(limbs[0])` (if value < 2^62) or allocates a fresh `atom_t` via `alloc_indirect` and calls `hash_atom`. This is the **only** place a new indirect atom is created by bignum code.

### Increment / Decrement

```c
noun bn_inc(noun a);   /* Nock op 4 — never crashes */
noun bn_dec(noun a);   /* crashes via nock_crash() on zero */
```

`bn_inc` handles the direct→indirect boundary: when the direct value is 2^62-1, the result is an indirect atom with `size=1, limbs[0]=2^62`.

`bn_dec` is the inverse: borrow propagation walks forward to the first non-zero limb, wraps all preceding limbs to `UINT64_MAX`, decrements that limb, then calls `bn_normalize` (which may promote back to direct if the result is < 2^62).

### Addition / Subtraction

```c
noun bn_add(noun a, noun b);         /* a + b */
noun bn_sub(noun a, noun b);         /* a - b; crashes if a < b */
int  bn_cmp(noun a, noun b);         /* -1 / 0 / +1 */
```

`bn_add` extracts limbs from both operands into stack scratch arrays, then performs standard multi-limb carry propagation using `__uint128_t` for the per-limb accumulator. The result array is one limb larger than the larger operand to accommodate carry-out; `bn_normalize` strips the extra zero if there is no carry.

`bn_sub` calls `bn_cmp` first; crashes with `nock_crash("bn_sub: underflow")` if `a < b`. Otherwise performs borrow propagation symmetrically to addition.

`bn_cmp` compares sizes first (more limbs = larger), then walks from MSL to LSL on equal-size operands.

### Decimal I/O

```c
int  bn_to_decimal(noun a, char *buf, int buflen);   /* returns length */
int  bn_to_decimal_fill(noun a);                     /* fills bn_decimal_buf[] */
noun bn_from_decimal(const char *buf, int len);
extern char bn_decimal_buf[BN_DECIMAL_MAX];          /* 512 bytes, not reentrant */
```

**`bn_to_decimal`** — repeated in-place division:

1. Copy limbs into a stack scratch array.
2. Repeatedly call `bn_div10_inplace`: divide the entire scratch array by 10 using `__uint128_t` to handle the 128-bit step `(remainder << 64 | limbs[i]) / 10` at each limb. Collect the remainder (0–9) as the next digit (least significant first).
3. Trim trailing zero limbs in the scratch quotient after each step.
4. Reverse the digit buffer into `buf`.

Worst case: 512 decimal digits (BN_DECIMAL_MAX) for a 27-limb (1728-bit) atom. Stack usage for scratch: 64 limbs × 8 bytes = 512 bytes.

**`bn_from_decimal`** — left-to-right scalar multiply:

For each digit `d` in order (most significant first):
```
scratch = scratch * 10 + d
```
Implemented as `do_mul10_add`: walks the limb array low-to-high, computing `limbs[i] * 10 + carry` with `__uint128_t`, updating carry. A new MSL is appended if the final carry is non-zero.

---

## Algorithms in Detail

### Why `__uint128_t`

AArch64 has no 128-bit multiply or divide instruction, but GCC emits correct multi-word sequences for `__uint128_t` arithmetic (e.g. `mul`/`umulh` for 64×64→128 multiply, `udiv` sequences for 128÷64). No libc is needed — `__uint128_t` is a compiler built-in. This keeps the code portable across toolchains while staying freestanding.

### Carry addition (bn_add inner loop)

```c
__uint128_t sum = (__uint128_t)x + y + carry;
lr[i]  = (uint64_t)sum;
carry  = (uint64_t)(sum >> 64);
```

Equivalent to AArch64 `adds`/`adcs` sequence. GCC -O2 emits exactly that.

### Division by 10 (bn_div10_inplace, MSL to LSL)

```c
uint64_t rem = 0;
for (int64_t i = sz - 1; i >= 0; i--) {
    __uint128_t cur = ((__uint128_t)rem << 64) | limbs[i];
    limbs[i] = (uint64_t)(cur / 10);
    rem      = (uint64_t)(cur % 10);
}
return rem;
```

At each step, `rem` is the remainder from the higher limb (≤ 9 after the first step), so `cur < 10 * 2^64` which fits in 128 bits. GCC lowers `cur / 10` to a reciprocal multiply.

### Scalar multiply-add (do_mul10_add, LSL to MSL)

```c
uint64_t carry = d;
for (uint64_t i = 0; i < sz; i++) {
    __uint128_t prod = (__uint128_t)limbs[i] * 10 + carry;
    out[i] = (uint64_t)prod;
    carry  = (uint64_t)(prod >> 64);
}
if (carry) { out[sz] = carry; return sz + 1; }
return sz;
```

---

## Limits and Stack Budget

| Constant        | Value | Meaning                               |
|-----------------|-------|---------------------------------------|
| `BN_MAX_LIMBS`  | 64    | Max limbs in any scratch buffer (4096-bit atoms) |
| `BN_DECIMAL_MAX`| 512   | Max decimal digits in output          |

Stack usage per call:

| Function           | Stack (approx)        |
|--------------------|-----------------------|
| `bn_add`           | 3 × 512 B = 1.5 KB    |
| `bn_sub`           | 3 × 512 B = 1.5 KB    |
| `bn_to_decimal`    | 2 × 512 B = 1 KB      |
| `bn_from_decimal`  | 2 × 512 B = 1 KB      |

All scratch is on the C stack. No heap allocation occurs during arithmetic — only at `bn_normalize` output.

---

## Forth Interface

| Word    | Stack               | Notes                                              |
|---------|---------------------|----------------------------------------------------|
| `N.`    | `( noun -- )`       | Print atom as decimal + space via `bn_to_decimal_fill` |
| `BN+`   | `( n1 n2 -- n )`    | Calls `bn_add`; both operands must be atom nouns   |
| `BNDEC` | `( noun -- noun )`  | Calls `bn_dec`; crashes if noun is zero atom       |

`N.` uses the global `bn_decimal_buf[512]` static buffer — it is not reentrant. For all practical REPL use this is irrelevant.

Note: the REPL number parser (`NUM` / the QUIT inline parser) is 64-bit native and silently overflows for decimal literals larger than 2^63. To work with atoms larger than 2^62-1 from the REPL, produce them via Nock (repeated `op 4`) or via `BN+`.

---

## What Is Not Yet Implemented

| Function  | Notes                                                            |
|-----------|------------------------------------------------------------------|
| `bn_mul`  | Needed for jam/cue encoding and arbitrary-precision arithmetic   |
| `bn_div`  | Full division (not just by 10); needed for decimal input in REPL |
| Large decimal REPL input | REPL parser is 64-bit; `bn_from_decimal` exists but is not wired into the QUIT number-parse path |

---

## Invariant Summary

1. **Canonical form**: value < 2^62 → always direct atom. No exceptions.
2. **No trailing zeros**: `limbs[size-1] != 0` for `size > 1`. Enforced by `bn_normalize`.
3. **BLAKE3 hash**: `atom->blake3[]` is all-zero until `hash_atom()` is called. After that, `blake3[0] & 0x3FFFFFFF != 0` (clamped to 1 if needed). The 30-bit prefix is embedded in the indirect noun word for O(1) inequality fast-path in `noun_eq`.
4. **Scratch isolation**: arithmetic functions never mutate input atoms. All intermediate work uses C stack arrays; a single `bn_normalize` call at the end produces the output noun.
