#include <stdint.h>
#include "bignum.h"
#include "noun.h"
#include "nock.h"   /* nock_crash (noreturn) */

/* ── Internal helpers ────────────────────────────────────────────────────── */

/* Convenience: atom_t* from an indirect noun (unchecked). */
static inline atom_t *atom_of(noun n) {
    return (atom_t *)(uintptr_t)indirect_ptr(n);
}

/* ── bn_normalize ────────────────────────────────────────────────────────── */

noun bn_normalize(uint64_t *limbs, uint64_t size) {
    /* Strip trailing zero limbs (maintain: limbs[size-1] != 0 for size > 1) */
    while (size > 1 && limbs[size - 1] == 0)
        size--;

    /* Promote to direct atom if value fits in 62 bits */
    if (size == 1 && limbs[0] < (1ULL << 62))
        return direct(limbs[0]);

    /* Allocate a fresh indirect atom, copy limbs, and hash immediately. */
    noun r = alloc_indirect(size);
    atom_t *a = atom_of(r);
    for (uint64_t i = 0; i < size; i++)
        a->limbs[i] = limbs[i];
    return hash_atom(r);
}

/* ── bn_inc ──────────────────────────────────────────────────────────────── */

/*
 * Increment an atom by 1.
 *
 * Direct atom:
 *   value < 2^62-1  →  direct(value+1)                   (no allocation)
 *   value = 2^62-1  →  indirect, size=1, limbs[0]=2^62   (boundary case)
 *
 * Indirect atom — carry propagation:
 *   Walk limbs from LSL to find first limb that is not UINT64_MAX.
 *   Everything below it wraps to 0.  That limb gets +1.  If all limbs
 *   saturate, extend by one new limb (= 1) at the top.
 *   Result value is always ≥ 2^62+1, so it stays indirect.
 */
noun bn_inc(noun a) {
    /* ── Direct atom ── */
    if (noun_is_direct(a)) {
        uint64_t v = direct_val(a);
        if (v < (1ULL << 62) - 1)
            return direct(v + 1);

        /* Boundary: v == 2^62-1, next value is 2^62 which needs indirect */
        noun r = alloc_indirect(1);
        atom_of(r)->limbs[0] = 1ULL << 62;
        return hash_atom(r);
    }

    /* ── Indirect atom ── */
    if (!noun_is_indirect(a))
        nock_crash("bn_inc: unsupported atom type");

    atom_t *src  = atom_of(a);
    uint64_t size = src->size;

    /* Find first limb that will not carry through */
    uint64_t i = 0;
    while (i < size && src->limbs[i] == UINT64_MAX)
        i++;
    /* i == size means all limbs saturated: result needs one more limb */

    uint64_t new_size = (i == size) ? size + 1 : size;
    noun r     = alloc_indirect(new_size);
    atom_t *dst = atom_of(r);

    /* Limbs [0..i-1] wrapped to 0 */
    for (uint64_t j = 0; j < i; j++)
        dst->limbs[j] = 0;

    /* Limb i: incremented, or new MSL from carry-out */
    dst->limbs[i] = (i < size) ? src->limbs[i] + 1 : 1;

    /* Limbs [i+1..size-1] unchanged */
    for (uint64_t j = i + 1; j < size; j++)
        dst->limbs[j] = src->limbs[j];

    /* Result is always ≥ 2^62 (input was indirect, we only added 1),
       so no promotion to direct needed.  MSL is non-zero by construction. */
    return hash_atom(r);
}

/* ── Stubs for future phases ─────────────────────────────────────────────── */

int bn_to_decimal(noun a, char *buf, int buflen) {
    (void)a; (void)buf; (void)buflen;
    nock_crash("bn_to_decimal: NYI (Phase 4c)");
}

noun bn_from_decimal(const char *buf, int len) {
    (void)buf; (void)len;
    nock_crash("bn_from_decimal: NYI (Phase 4c)");
}

noun bn_add(noun a, noun b) {
    (void)a; (void)b;
    nock_crash("bn_add: NYI (Phase 11d)");
}

noun bn_dec(noun a) {
    (void)a;
    nock_crash("bn_dec: NYI (Phase 11d)");
}
