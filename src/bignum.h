#pragma once
#include <stdint.h>
#include "noun.h"

/*
 * Bignum arithmetic for indirect (tag=10) atoms.
 *
 * Representation (maintained as invariants by every function here):
 *   - Limbs are little-endian uint64_t: limbs[0] = least significant 64 bits.
 *   - No trailing zero limbs: limbs[size-1] != 0 when size > 1.
 *   - Canonical form: any value < 2^62 is ALWAYS a direct atom.
 *     alloc_indirect is never called when the value fits in 62 bits.
 *
 * The boundary is exactly 2^62 = 0x4000_0000_0000_0000.
 * Incrementing a direct atom with value 2^62-1 produces an indirect atom
 * with size=1, limbs[0]=2^62.
 *
 * All functions return a properly tagged, canonical noun.
 */

/* ── Core ────────────────────────────────────────────────────────────────── */

/*
 * bn_normalize: given a scratch limb array `limbs[0..size-1]`, produce a
 * canonical noun.  Strips trailing zero limbs, then promotes to direct if
 * the value fits in 62 bits, otherwise allocates a fresh indirect atom.
 *
 * The scratch array is read-only; a new atom_t is always allocated when
 * the result must be indirect.
 */
noun bn_normalize(uint64_t *limbs, uint64_t size);

/*
 * bn_inc: Nock op 4 — increment an atom by 1.
 * Handles direct→direct, direct→indirect boundary, and multi-limb carry.
 * Crashes (via nock_crash) if `a` is a cell or unsupported atom type.
 */
noun bn_inc(noun a);

/* Maximum limbs for stack-allocated scratch buffers (64 × 64-bit = 4096 bits,
   handles decimal strings up to ~1232 digits — well beyond BN_DECIMAL_MAX). */
#define BN_MAX_LIMBS 64

/* ── Decimal I/O ──────────────────────────────────────────────────────────── */

/* Maximum decimal digits bn_to_decimal will ever produce. */
#define BN_DECIMAL_MAX 512

/*
 * bn_to_decimal: write decimal representation of atom `a` into `buf`.
 * Returns number of bytes written (no NUL terminator), or 0 on error.
 * `buf` must be at least BN_DECIMAL_MAX bytes.
 */
int  bn_to_decimal(noun a, char *buf, int buflen);

/*
 * bn_to_decimal_fill: write decimal digits into the global bn_decimal_buf[].
 * Returns length.  Convenience wrapper for Forth N. word.
 */
extern char bn_decimal_buf[BN_DECIMAL_MAX];
int  bn_to_decimal_fill(noun a);

/*
 * bn_from_decimal: parse `len` ASCII decimal digits into a noun atom.
 * No sign, no prefix, no whitespace.  Returns NOUN_ZERO on empty input.
 */
noun bn_from_decimal(const char *buf, int len);

/* ── Arithmetic ───────────────────────────────────────────────────────────── */

noun bn_add(noun a, noun b);   /* addition                              */
noun bn_dec(noun a);           /* decrement; crashes on zero            */
noun bn_sub(noun a, noun b);   /* subtraction a-b; crashes if a < b    */

/* Compare two atoms.  Returns -1 / 0 / +1  (a < b / a == b / a > b). */
int  bn_cmp(noun a, noun b);
