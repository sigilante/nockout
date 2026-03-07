#include <stdint.h>
#include <stddef.h>
#include "blake3.h"

/* ── Constants ───────────────────────────────────────────────────────────── */

/* SHA-256 initial hash values (sqrt of first 8 primes, fractional parts) */
static const uint32_t IV[8] = {
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
};

/* Message word permutation (from BLAKE3 spec, Table 1) */
static const uint8_t MSG_PERM[16] = {
    2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8,
};

#define BLOCK_LEN   64u
#define CHUNK_LEN   1024u

#define CHUNK_START 1u
#define CHUNK_END   2u
#define PARENT      4u
#define ROOT        8u

/* ── G mixing function ───────────────────────────────────────────────────── */

static inline uint32_t ror32(uint32_t x, int n) {
    return (x >> n) | (x << (32 - n));
}

static inline void g(uint32_t s[16], int a, int b, int c, int d,
                     uint32_t mx, uint32_t my) {
    s[a] = s[a] + s[b] + mx;  s[d] = ror32(s[d] ^ s[a], 16);
    s[c] = s[c] + s[d];       s[b] = ror32(s[b] ^ s[c], 12);
    s[a] = s[a] + s[b] + my;  s[d] = ror32(s[d] ^ s[a],  8);
    s[c] = s[c] + s[d];       s[b] = ror32(s[b] ^ s[c],  7);
}

/* ── One round (8 G calls: 4 column + 4 diagonal) ────────────────────────── */

static void blake3_round(uint32_t s[16], const uint32_t m[16]) {
    g(s, 0, 4,  8, 12, m[ 0], m[ 1]);
    g(s, 1, 5,  9, 13, m[ 2], m[ 3]);
    g(s, 2, 6, 10, 14, m[ 4], m[ 5]);
    g(s, 3, 7, 11, 15, m[ 6], m[ 7]);
    g(s, 0, 5, 10, 15, m[ 8], m[ 9]);
    g(s, 1, 6, 11, 12, m[10], m[11]);
    g(s, 2, 7,  8, 13, m[12], m[13]);
    g(s, 3, 4,  9, 14, m[14], m[15]);
}

/* ── Compress one 64-byte block ──────────────────────────────────────────── */
/*
 * Inputs:
 *   cv[8]      — chaining value (IV for the first block of each chunk)
 *   block[64]  — raw bytes (zero-padded by caller if shorter than 64)
 *   block_len  — actual byte count in this block (1–64)
 *   counter    — chunk index (same for every block in a chunk; 0 for parents)
 *   flags      — CHUNK_START | CHUNK_END | PARENT | ROOT as appropriate
 *
 * Output (out[16]):
 *   out[0..7]  = s[0..7] ^ s[8..15]   (new chaining value)
 *   out[8..15] = s[8..15] ^ cv[0..7]  (for XOF; used by ROOT output)
 */
static void compress(const uint32_t cv[8], const uint8_t block[BLOCK_LEN],
                     uint8_t block_len, uint64_t counter, uint32_t flags,
                     uint32_t out[16]) {
    /* Load message words little-endian */
    uint32_t m[16];
    for (int i = 0; i < 16; i++) {
        const uint8_t *p = block + i * 4;
        m[i] = (uint32_t)p[0] | ((uint32_t)p[1] << 8)
             | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    }

    uint32_t s[16] = {
        cv[0], cv[1], cv[2], cv[3], cv[4], cv[5], cv[6], cv[7],
        IV[0], IV[1], IV[2], IV[3],
        (uint32_t)counter, (uint32_t)(counter >> 32),
        (uint32_t)block_len, flags,
    };

    /* 7 rounds, permuting message words between rounds */
    for (int r = 0; r < 7; r++) {
        blake3_round(s, m);
        uint32_t tmp[16];
        for (int i = 0; i < 16; i++) tmp[i] = m[MSG_PERM[i]];
        for (int i = 0; i < 16; i++) m[i] = tmp[i];
    }

    for (int i = 0; i < 8; i++) {
        out[i]   = s[i]   ^ s[i + 8];
        out[i+8] = s[i+8] ^ cv[i];
    }
}

/* ── Serialize a 32-bit word to 4 LE bytes ───────────────────────────────── */

static inline void store_le32(uint8_t *p, uint32_t w) {
    p[0] = (uint8_t)(w);       p[1] = (uint8_t)(w >>  8);
    p[2] = (uint8_t)(w >> 16); p[3] = (uint8_t)(w >> 24);
}

/* ── Write first 8 compress-output words as 32 LE bytes ─────────────────── */

static void cv_to_out(const uint32_t cv[8], uint8_t out[32]) {
    for (int i = 0; i < 8; i++) store_le32(out + i * 4, cv[i]);
}

/* ── Hash one chunk (up to 1024 bytes) → chaining value in cv[8] ─────────── */
/*
 * extra_flags is OR'd into every block's flags word (pass ROOT for a
 * single-chunk message so the last block gets ROOT|CHUNK_START|CHUNK_END).
 */
/*
 * Hash one chunk (up to CHUNK_LEN bytes) into a chaining value.
 *
 * final_flags is OR'd into the LAST block's flags only.  For a single-chunk
 * message this carries ROOT; for non-root chunks it is 0.  Intermediate
 * blocks within the chunk must NOT carry ROOT — only the final compress call
 * of the entire computation does.
 */
static void hash_chunk(const uint8_t *data, size_t len,
                       uint64_t chunk_idx, uint32_t final_flags,
                       uint32_t cv[8]) {
    for (int i = 0; i < 8; i++) cv[i] = IV[i];

    size_t pos = 0;
    int first  = 1;

    /* Process at least one block even for zero-length chunks */
    do {
        size_t blen = len - pos;
        if (blen > BLOCK_LEN) blen = BLOCK_LEN;

        /* Zero-pad block */
        uint8_t block[BLOCK_LEN];
        for (int i = 0; i < (int)BLOCK_LEN; i++) block[i] = 0;
        for (size_t i = 0; i < blen; i++) block[i] = data[pos + i];

        uint32_t flags = 0;
        if (first) { flags |= CHUNK_START; first = 0; }
        pos += blen;
        if (pos >= len) { flags |= CHUNK_END; flags |= final_flags; }

        uint32_t out[16];
        compress(cv, block, (uint8_t)blen, chunk_idx, flags, out);
        for (int i = 0; i < 8; i++) cv[i] = out[i];
    } while (pos < len);
}

/* ── Merge two chaining values as a parent node ──────────────────────────── */

static void merge_parent(const uint32_t left[8], const uint32_t right[8],
                         uint32_t extra_flags, uint32_t cv[8]) {
    uint8_t block[BLOCK_LEN];
    for (int i = 0; i < 8; i++) {
        store_le32(block +      i * 4, left[i]);
        store_le32(block + 32 + i * 4, right[i]);
    }
    uint32_t out[16];
    compress(IV, block, BLOCK_LEN, 0, PARENT | extra_flags, out);
    for (int i = 0; i < 8; i++) cv[i] = out[i];
}

/* ── Public API ───────────────────────────────────────────────────────────── */

void blake3_hash(const uint8_t *input, size_t inlen, uint8_t out[32]) {
    /*
     * Subtree stack.  Invariant after processing k chunks: the heights of
     * occupied stack entries are the set bits of k, from high (bottom) to
     * low (top).  Maximum depth = 54 covers 2^54 × 1024 = 18 exabytes.
     */
    uint32_t stack[54][8];
    int top = 0;

    const uint8_t *p = input;
    size_t rem       = inlen;
    uint64_t chunk_idx = 0;

    /* Process chunks */
    do {
        size_t clen = (rem < CHUNK_LEN) ? rem : CHUNK_LEN;
        rem -= clen;

        int only = (chunk_idx == 0 && rem == 0);

        uint32_t cv[8];
        hash_chunk(p, clen, chunk_idx, only ? ROOT : 0, cv);
        p += clen;
        chunk_idx++;

        if (only) {
            /* Single chunk: output is already the root */
            cv_to_out(cv, out);
            return;
        }

        /* Push chunk CV onto stack */
        for (int i = 0; i < 8; i++) stack[top][i] = cv[i];
        top++;

        /*
         * Merge while the chunk count has trailing zeros AND there are more
         * chunks still to process.  The rem > 0 guard ensures we never apply
         * ROOT here — that happens in the finalization loop below.
         */
        uint64_t tz = chunk_idx;
        while ((tz & 1) == 0 && top > 1 && rem > 0) {
            top--;
            uint32_t merged[8];
            merge_parent(stack[top - 1], stack[top], 0, merged);
            for (int i = 0; i < 8; i++) stack[top - 1][i] = merged[i];
            tz >>= 1;
        }
    } while (rem > 0);

    /* Finalize: merge remaining stack entries right-to-left.
       ROOT goes on the very last merge. */
    while (top > 1) {
        top--;
        uint32_t flags = (top == 1) ? ROOT : 0;
        uint32_t merged[8];
        merge_parent(stack[top - 1], stack[top], flags, merged);
        for (int i = 0; i < 8; i++) stack[top - 1][i] = merged[i];
    }

    cv_to_out(stack[0], out);
}

/* ── Official test vectors ───────────────────────────────────────────────── */
/*
 * Input pattern: input[i] = i % 251  (from BLAKE3 test_vectors.json).
 * Vectors chosen to cover: empty, sub-block, full block, block boundary,
 * full chunk (1024 B), and first multi-chunk Merkle merge (1025 B).
 */

typedef struct { size_t len; uint8_t h[32]; } b3vec_t;

static const b3vec_t BLAKE3_VECS[] = {
    /* len=0 */
    { 0, { 0xaf,0x13,0x49,0xb9, 0xf5,0xf9,0xa1,0xa6,
           0xa0,0x40,0x4d,0xea, 0x36,0xdc,0xc9,0x49,
           0x9b,0xcb,0x25,0xc9, 0xad,0xc1,0x12,0xb7,
           0xcc,0x9a,0x93,0xca, 0xe4,0x1f,0x32,0x62 } },
    /* len=1 */
    { 1, { 0x2d,0x3a,0xde,0xdf, 0xf1,0x1b,0x61,0xf1,
           0x4c,0x88,0x6e,0x35, 0xaf,0xa0,0x36,0x73,
           0x6d,0xcd,0x87,0xa7, 0x4d,0x27,0xb5,0xc1,
           0x51,0x02,0x25,0xd0, 0xf5,0x92,0xe2,0x13 } },
    /* len=63 */
    { 63, { 0xe9,0xbc,0x37,0xa5, 0x94,0xda,0xad,0x83,
            0xbe,0x94,0x70,0xdf, 0x7f,0x7b,0x37,0x98,
            0x29,0x7c,0x3d,0x83, 0x4c,0xe8,0x0b,0xa8,
            0x5d,0x6e,0x20,0x76, 0x27,0xb7,0xdb,0x7b } },
    /* len=64  (exactly one block) */
    { 64, { 0x4e,0xed,0x71,0x41, 0xea,0x4a,0x5c,0xd4,
            0xb7,0x88,0x60,0x6b, 0xd2,0x3f,0x46,0xe2,
            0x12,0xaf,0x9c,0xac, 0xeb,0xac,0xdc,0x7d,
            0x1f,0x4c,0x6d,0xc7, 0xf2,0x51,0x1b,0x98 } },
    /* len=65  (two blocks) */
    { 65, { 0xde,0x1e,0x5f,0xa0, 0xbe,0x70,0xdf,0x6d,
            0x2b,0xe8,0xff,0xfd, 0x0e,0x99,0xce,0xaa,
            0x8e,0xb6,0xe8,0xc9, 0x3a,0x63,0xf2,0xd8,
            0xd1,0xc3,0x0e,0xcb, 0x6b,0x26,0x3d,0xee } },
    /* len=1024 (exactly one chunk) */
    { 1024, { 0x42,0x21,0x47,0x39, 0xf0,0x95,0xa4,0x06,
              0xf3,0xfc,0x83,0xde, 0xb8,0x89,0x74,0x4a,
              0xc0,0x0d,0xf8,0x31, 0xc1,0x0d,0xaa,0x55,
              0x18,0x9b,0x5d,0x12, 0x1c,0x85,0x5a,0xf7 } },
    /* len=1025 (two chunks → first Merkle parent merge) */
    { 1025, { 0xd0,0x02,0x78,0xae, 0x47,0xeb,0x27,0xb3,
              0x4f,0xae,0xcf,0x67, 0xb4,0xfe,0x26,0x3f,
              0x82,0xd5,0x41,0x29, 0x16,0xc1,0xff,0xd9,
              0x7c,0x8c,0xb7,0xfb, 0x81,0x4b,0x84,0x44 } },
};

#define N_VECS ((int)(sizeof(BLAKE3_VECS) / sizeof(BLAKE3_VECS[0])))

int blake3_selftest(void) {
    /* Test input buffer in BSS (zeroed at boot); filled once on first call. */
    static uint8_t inp[1025];
    static int     inp_ready;   /* zero-initialised = not ready */

    if (!inp_ready) {
        for (int i = 0; i < 1025; i++)
            inp[i] = (uint8_t)(i % 251);
        inp_ready = 1;
    }

    uint8_t got[32];
    for (int v = 0; v < N_VECS; v++) {
        blake3_hash(inp, BLAKE3_VECS[v].len, got);
        for (int i = 0; i < 32; i++)
            if (got[i] != BLAKE3_VECS[v].h[i])
                return 0;
    }
    return 1;
}
