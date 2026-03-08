#include <stdint.h>
#include "jam.h"
#include "bignum.h"
#include "nock.h"    /* nock_crash */

/* ── Bitstream writer ─────────────────────────────────────────────────────── */

#define JAM_MAX_LIMBS 128   /* 8192 bits max jam output */

typedef struct {
    uint64_t buf[JAM_MAX_LIMBS];
    uint64_t cur;               /* next bit position to write */
} jambuf_t;

static void jb_init(jambuf_t *b) {
    for (int i = 0; i < JAM_MAX_LIMBS; i++) b->buf[i] = 0;
    b->cur = 0;
}

static void jb_write(jambuf_t *b, int bit) {
    if (b->cur >= (uint64_t)(JAM_MAX_LIMBS * 64))
        nock_crash("jam: output too large");
    uint64_t w = b->cur >> 6, o = b->cur & 63;
    if (bit) b->buf[w] |= 1ULL << o;
    b->cur++;
}

static void jb_write_n(jambuf_t *b, uint64_t val, uint64_t n) {
    for (uint64_t i = 0; i < n; i++)
        jb_write(b, (val >> i) & 1);
}

/* Write n bits of atom a, starting from bit 0 (LSB first). */
static void jb_write_atom(jambuf_t *b, noun a, uint64_t n) {
    if (noun_is_direct(a)) {
        jb_write_n(b, direct_val(a), n);
        return;
    }
    atom_t *at = (atom_t *)(uintptr_t)indirect_ptr(a);
    for (uint64_t i = 0; i < n; i++) {
        uint64_t limb = i >> 6, off = i & 63;
        int bit = (limb < at->size) ? (int)((at->limbs[limb] >> off) & 1) : 0;
        jb_write(b, bit);
    }
}

/* ── mat: self-describing integer encoding ────────────────────────────────── */

/* Bit length of a raw uint64_t (0 → 0, 1 → 1, 2–3 → 2, …). */
static uint64_t u64_bits(uint64_t v) {
    uint64_t c = 0;
    while (v) { c++; v >>= 1; }
    return c;
}

/* Length in bits that mat(k) will emit. */
static uint64_t mat_len(noun k) {
    uint64_t a = bn_met(k);
    if (a == 0) return 1;           /* k == 0: single 1 bit */
    uint64_t b = u64_bits(a);
    return 2 * b + a;
}

/* Emit mat(k) into the bitstream. */
static void do_mat(jambuf_t *jb, noun k) {
    uint64_t a = bn_met(k);
    if (a == 0) { jb_write(jb, 1); return; }
    uint64_t b = u64_bits(a);
    /* b zeros */
    for (uint64_t i = 0; i < b; i++) jb_write(jb, 0);
    /* 1 delimiter */
    jb_write(jb, 1);
    /* b-1 low bits of a */
    jb_write_n(jb, a, b - 1);
    /* a bits of k */
    jb_write_atom(jb, k, a);
}

/* ── jam cache: noun → bit position ──────────────────────────────────────── */

#define JAM_CACHE_SZ 128

typedef struct { noun key; uint64_t pos; int used; } jcent_t;

static jcent_t g_jcache[JAM_CACHE_SZ];

static void jcache_init(void) {
    for (int i = 0; i < JAM_CACHE_SZ; i++) g_jcache[i].used = 0;
}

static uint32_t jcache_hash(noun n) {
    return (uint32_t)((n ^ (n >> 23)) * 2654435761ULL) & (JAM_CACHE_SZ - 1);
}

static int jcache_get(noun n, uint64_t *pos) {
    uint32_t h = jcache_hash(n);
    for (uint32_t i = 0; i < JAM_CACHE_SZ; i++) {
        uint32_t idx = (h + i) & (JAM_CACHE_SZ - 1);
        if (!g_jcache[idx].used) return 0;
        if (noun_eq(g_jcache[idx].key, n)) { *pos = g_jcache[idx].pos; return 1; }
    }
    return 0;
}

static void jcache_put(noun n, uint64_t pos) {
    uint32_t h = jcache_hash(n);
    for (uint32_t i = 0; i < JAM_CACHE_SZ; i++) {
        uint32_t idx = (h + i) & (JAM_CACHE_SZ - 1);
        if (!g_jcache[idx].used) {
            g_jcache[idx].key = n; g_jcache[idx].pos = pos; g_jcache[idx].used = 1;
            return;
        }
    }
    /* cache full — skip (correctness preserved; dedup opportunity lost) */
}

/* ── jam recursive core ───────────────────────────────────────────────────── */

static jambuf_t g_jambuf;

static void do_jam(noun n) {
    uint64_t cached_pos;
    int found = jcache_get(n, &cached_pos);

    if (noun_is_cell(n)) {
        if (found) {
            /* back-reference to this cell */
            jb_write(&g_jambuf, 1); jb_write(&g_jambuf, 1);
            do_mat(&g_jambuf, direct(cached_pos));
        } else {
            jcache_put(n, g_jambuf.cur);
            jb_write(&g_jambuf, 1); jb_write(&g_jambuf, 0);  /* tag 01 */
            cell_t *c = (cell_t *)(uintptr_t)cell_ptr(n);
            do_jam(c->head);
            do_jam(c->tail);
        }
    } else {
        /* atom */
        if (!found) {
            jcache_put(n, g_jambuf.cur);
            jb_write(&g_jambuf, 0);     /* atom tag */
            do_mat(&g_jambuf, n);
        } else {
            /* choose shorter: direct atom encoding vs back-reference */
            uint64_t atom_bits = 1 + mat_len(n);
            uint64_t ref_bits  = 2 + mat_len(direct(cached_pos));
            if (atom_bits <= ref_bits) {
                jb_write(&g_jambuf, 0);
                do_mat(&g_jambuf, n);
            } else {
                jb_write(&g_jambuf, 1); jb_write(&g_jambuf, 1);
                do_mat(&g_jambuf, direct(cached_pos));
            }
        }
    }
}

noun jam(noun n) {
    jb_init(&g_jambuf);
    jcache_init();
    do_jam(n);
    uint64_t bits  = g_jambuf.cur;
    uint64_t limbs = (bits + 63) / 64;
    if (limbs == 0) limbs = 1;
    return bn_normalize(g_jambuf.buf, limbs);
}

/* ── cue: atom → noun ─────────────────────────────────────────────────────── */

/* Read a single bit from atom a at bit position pos. */
static int atom_bit_at(noun a, uint64_t pos) {
    if (noun_is_direct(a)) {
        if (pos >= 62) return 0;
        return (int)((direct_val(a) >> pos) & 1);
    }
    atom_t *at = (atom_t *)(uintptr_t)indirect_ptr(a);
    uint64_t limb = pos >> 6, off = pos & 63;
    if (limb >= at->size) return 0;
    return (int)((at->limbs[limb] >> off) & 1);
}

/* rub: decode a mat-encoded atom from atom a starting at *cur; advance *cur. */
static noun do_rub(noun a, uint64_t *cur) {
    /* count leading zero bits */
    uint64_t z = 0;
    while (atom_bit_at(a, *cur) == 0) {
        z++; (*cur)++;
        if (z > 64) nock_crash("cue: malformed mat encoding");
    }
    (*cur)++;  /* skip the 1 delimiter */

    if (z == 0) return NOUN_ZERO;

    uint64_t below = z - 1;
    /* read below bits: low bits of the encoded length */
    uint64_t lbits = 0;
    for (uint64_t i = 0; i < below; i++)
        lbits |= (uint64_t)atom_bit_at(a, (*cur)++) << i;

    uint64_t len = (1ULL << below) | lbits;

    /* read len bits as the atom value */
    uint64_t limb_count = (len + 63) / 64;
    if (limb_count > (uint64_t)BN_MAX_LIMBS) nock_crash("cue: atom too large");
    uint64_t scratch[BN_MAX_LIMBS];
    for (uint64_t i = 0; i < limb_count; i++) scratch[i] = 0;
    for (uint64_t i = 0; i < len; i++)
        scratch[i >> 6] |= (uint64_t)atom_bit_at(a, (*cur)++) << (i & 63);

    return bn_normalize(scratch, limb_count);
}

/* ── cue cache: bit position → noun ──────────────────────────────────────── */

#define CUE_CACHE_SZ 128

typedef struct { uint64_t pos; noun val; int used; } ccent_t;

static ccent_t g_ccache[CUE_CACHE_SZ];

static void ccache_init(void) {
    for (int i = 0; i < CUE_CACHE_SZ; i++) g_ccache[i].used = 0;
}

static void ccache_put(uint64_t pos, noun val) {
    uint32_t h = (uint32_t)(pos * 2654435761ULL) & (CUE_CACHE_SZ - 1);
    for (uint32_t i = 0; i < CUE_CACHE_SZ; i++) {
        uint32_t idx = (h + i) & (CUE_CACHE_SZ - 1);
        if (!g_ccache[idx].used || g_ccache[idx].pos == pos) {
            g_ccache[idx].pos = pos; g_ccache[idx].val = val; g_ccache[idx].used = 1;
            return;
        }
    }
}

static noun ccache_get(uint64_t pos) {
    uint32_t h = (uint32_t)(pos * 2654435761ULL) & (CUE_CACHE_SZ - 1);
    for (uint32_t i = 0; i < CUE_CACHE_SZ; i++) {
        uint32_t idx = (h + i) & (CUE_CACHE_SZ - 1);
        if (!g_ccache[idx].used) break;
        if (g_ccache[idx].pos == pos) return g_ccache[idx].val;
    }
    nock_crash("cue: invalid back-reference");
    return NOUN_ZERO;  /* unreachable */
}

/* ── cue recursive core ───────────────────────────────────────────────────── */

static noun do_cue(noun a, uint64_t *cur) {
    uint64_t start = *cur;
    noun result;

    int tag0 = atom_bit_at(a, (*cur)++);
    if (tag0 == 0) {
        /* atom */
        result = do_rub(a, cur);
    } else {
        int tag1 = atom_bit_at(a, (*cur)++);
        if (tag1 == 0) {
            /* cell: decode head then tail */
            noun head = do_cue(a, cur);
            noun tail = do_cue(a, cur);
            result = alloc_cell(head, tail);
        } else {
            /* back-reference: decode position then look up */
            noun ref_pos = do_rub(a, cur);
            if (!noun_is_direct(ref_pos))
                nock_crash("cue: back-ref position too large");
            result = ccache_get(direct_val(ref_pos));
        }
    }

    ccache_put(start, result);
    return result;
}

noun cue(noun a) {
    if (!noun_is_atom(a)) nock_crash("cue: expected atom");
    ccache_init();
    uint64_t cur = 0;
    return do_cue(a, &cur);
}
