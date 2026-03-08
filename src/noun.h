#pragma once
#include <stdint.h>
#include <stddef.h>
#include "memory.h"

/*
 * Noun representation — every noun is a 64-bit word.
 *
 * Bits 63:62  tag
 *   0x  direct atom    bit 63 = 0; value = noun word (bits 62:0), range 0..2^63-1
 *   10  indirect atom  bits 63:62 = 10; bits 61:0 = 62-bit BLAKE3 hash of limb data
 *   11  cell           bits 63:62 = 11; bits 31:0 = 32-bit heap pointer to {head,tail}
 *
 * Direct atoms: the noun word IS the value.  direct(42) == 42.
 * Indirect atoms: content-addressed; identity is the 62-bit BLAKE3 hash.
 *   Limb data lives in the atom store (ATOM_INDEX_BASE / ATOM_DATA_BASE).
 * Cells: heap pointer to cell_t; allocated from HEAP_BASE.
 */

typedef uint64_t noun;

#define TAG_INDIRECT    (2ULL << 62)   /* bits 63:62 = 10 */
#define TAG_CELL        (3ULL << 62)   /* bits 63:62 = 11 */

/* ── Tag tests ─────────────────────────────────────────────────────────────── */

static inline int noun_is_direct(noun n)   { return !(n >> 63); }
static inline int noun_is_indirect(noun n) { return (n >> 62) == 2; }
static inline int noun_is_cell(noun n)     { return (n >> 62) == 3; }
static inline int noun_is_atom(noun n)     { return (n >> 62) != 3; }

/* ── Direct atom pack/unpack ────────────────────────────────────────────────── */

/* direct(v): v must have bit 63 = 0 (values 0..2^63-1). */
static inline noun     direct(uint64_t val)   { return val & 0x7FFFFFFFFFFFFFFFULL; }
static inline uint64_t direct_val(noun n)     { return n & 0x7FFFFFFFFFFFFFFFULL; }

/* ── Cell pack/unpack ───────────────────────────────────────────────────────── */

static inline noun     cell_noun(uint32_t ptr) { return TAG_CELL | (noun)ptr; }
static inline uint32_t cell_ptr(noun n)        { return (uint32_t)(n & 0xFFFFFFFF); }

/* ── Indirect atom pack/unpack ──────────────────────────────────────────────── */

/* Indirect noun: bits 61:0 hold the 62-bit BLAKE3 hash (identity of the atom). */
static inline noun     indirect(uint64_t hash62)  { return TAG_INDIRECT | (hash62 & 0x3FFFFFFFFFFFFFFFULL); }
static inline uint64_t indirect_hash(noun n)       { return n & 0x3FFFFFFFFFFFFFFFULL; }

/* ── Heap struct for indirect (type-10) atoms ───────────────────────────────── */

typedef struct atom {
    uint64_t  size;      /* number of 64-bit limbs                        */
    uint32_t  blake3[8]; /* full 256-bit BLAKE3 hash                      */
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

#define NOUN_ZERO   direct(0)   /* = 0 */
#define NOUN_ONE    direct(1)   /* = 1 */
#define NOUN_YES    direct(0)   /* Nock yes = 0 */
#define NOUN_NO     direct(1)   /* Nock no  = 1 */

/* ── Allocator interface (implemented in noun.c) ────────────────────────────── */

void  noun_heap_init(void);

noun  alloc_cell(noun head, noun tail);
void  cell_inc(noun n);   /* increment refcount */
void  cell_dec(noun n);   /* decrement; frees cell (and recursively children) when 0 */

/* Nock equality: structural, O(1) for atoms via word compare */
int   noun_eq(noun a, noun b);

/*
 * make_atom: given limb array limbs[0..size-1], produce a canonical noun.
 * Strips trailing zero limbs, promotes to direct if value < 2^63,
 * otherwise hashes with BLAKE3 and inserts into the atom store.
 * Returns a properly tagged noun (direct or indirect).
 */
noun  make_atom(const uint64_t *limbs, uint64_t size);

/*
 * atom_store_get: look up a 62-bit BLAKE3 hash in the atom store.
 * Returns a pointer to the atom_t, or NULL if not found.
 */
atom_t *atom_store_get(uint64_t hash62);

/* Load a jammed atom from PILL_BASE (placed by QEMU's -device loader).
   Returns NOUN_ZERO if no pill is present. CUE the result to decode. */
noun  pill_load(void);
