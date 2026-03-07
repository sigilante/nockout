#pragma once
#include <stdint.h>
#include <stddef.h>
#include "memory.h"

/*
 * Noun representation — every noun is a 64-bit word.
 *
 * Bits 63:62  tag
 *   00  cell          bits 61:0 = 32-bit heap pointer to {head, tail}
 *   01  direct atom   bits 61:0 = value (0 .. 2^62-1)
 *   10  indirect atom bits 61:32 = low 30 bits of BLAKE3 hash (fast equality)
 *                     bits 31:0  = 32-bit pointer to struct atom in heap
 *   11  content atom  bits 61:0  = 62-bit BLAKE3 prefix (identity IS hash)
 *                     actual limb data in atom store (Phase 4b+)
 */

typedef uint64_t noun;

#define TAG_CELL        (0ULL << 62)
#define TAG_DIRECT      (1ULL << 62)
#define TAG_INDIRECT    (2ULL << 62)
#define TAG_CONTENT     (3ULL << 62)
#define TAG_MASK        (3ULL << 62)

/* ── Tag tests ─────────────────────────────────────────────────────────────── */

static inline int noun_is_cell(noun n)     { return (n >> 62) == 0; }
static inline int noun_is_atom(noun n)     { return (n >> 62) != 0; }
static inline int noun_is_direct(noun n)   { return (n >> 62) == 1; }
static inline int noun_is_indirect(noun n) { return (n >> 62) == 2; }
static inline int noun_is_content(noun n)  { return (n >> 62) == 3; }

/* ── Direct atom pack/unpack ────────────────────────────────────────────────── */

static inline noun  direct(uint64_t val)   { return TAG_DIRECT | (val & ~TAG_MASK); }
static inline uint64_t direct_val(noun n)  { return n & ~TAG_MASK; }

/* ── Cell pack/unpack ───────────────────────────────────────────────────────── */

static inline noun  cell_noun(uint32_t ptr) { return TAG_CELL | (noun)ptr; }
static inline uint32_t cell_ptr(noun n)     { return (uint32_t)(n & 0xFFFFFFFF); }

/* ── Indirect atom pack/unpack ──────────────────────────────────────────────── */

/* Pack a heap pointer + low 30 bits of BLAKE3 hash into a type-10 noun.
   Pass hash_prefix=0 when hash has not yet been computed. */
static inline noun indirect(uint32_t ptr, uint32_t hash_prefix) {
    return TAG_INDIRECT
         | ((noun)(hash_prefix & 0x3FFFFFFF) << 32)
         | (noun)ptr;
}
static inline uint32_t indirect_ptr(noun n)         { return (uint32_t)(n & 0xFFFFFFFF); }
static inline uint32_t indirect_hash_prefix(noun n) { return (uint32_t)((n >> 32) & 0x3FFFFFFF); }

/* ── Content atom pack/unpack ───────────────────────────────────────────────── */

static inline noun   content(uint64_t hash62) { return TAG_CONTENT | (hash62 & ~TAG_MASK); }
static inline uint64_t content_hash(noun n)   { return n & ~TAG_MASK; }

/* ── Heap struct for indirect (type-10) atoms ───────────────────────────────── */

typedef struct atom {
    uint64_t  size;      /* number of 64-bit limbs                        */
    uint32_t  blake3[8]; /* full 256-bit BLAKE3 hash; all-zero = not yet  */
    uint64_t  limbs[];   /* little-endian limb data (size elements)        */
} atom_t;

/* ── Heap struct for cells ──────────────────────────────────────────────────── */

typedef struct cell {
    uint32_t  refcount;
    uint32_t  _pad;
    noun      head;
    noun      tail;
} cell_t;

/* ── Well-known atoms ───────────────────────────────────────────────────────── */

#define NOUN_ZERO   direct(0)
#define NOUN_ONE    direct(1)
#define NOUN_YES    direct(0)   /* Nock yes = 0 */
#define NOUN_NO     direct(1)   /* Nock no  = 1 */

/* ── Allocator interface (implemented in noun.c) ────────────────────────────── */

void  noun_heap_init(void);

noun  alloc_cell(noun head, noun tail);
void  cell_inc(noun n);   /* increment refcount */
void  cell_dec(noun n);   /* decrement; frees cell (and recursively children) when 0 */

noun  alloc_direct(uint64_t val);            /* returns direct atom (no alloc needed) */
noun  alloc_indirect(uint64_t size_limbs);   /* allocate indirect atom; caller fills limbs[] */

/* Nock equality: structural, O(1) for atoms via direct compare or hash prefix */
int   noun_eq(noun a, noun b);

/* Compute BLAKE3 hash of an indirect atom's limbs (if not already hashed).
   Stores the full 256-bit hash in atom->blake3[].
   Returns a new noun word with the 30-bit hash prefix embedded in bits 61:32.
   Non-indirect nouns are returned unchanged. */
noun  hash_atom(noun n);
