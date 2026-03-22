#include <stdint.h>
#include <stddef.h>
#include "noun.h"
#include "memory.h"
#include "blake3.h"

/*
 * Noun heap allocator — bump allocator within HEAP_BASE..HEAP_TOP.
 * Used exclusively for cells (atoms now live in the atom store).
 */

static uint8_t *heap_ptr;

void noun_heap_init(void);   /* forward — also inits atom store */

static void *heap_alloc(size_t bytes) {
    bytes = (bytes + 7) & ~(size_t)7;
    uint8_t *p = heap_ptr;
    heap_ptr += bytes;
    /* TODO: check heap_ptr < HEAP_TOP */
    return p;
}

/* ── Cells ──────────────────────────────────────────────────────────────────── */

noun alloc_cell(noun head, noun tail) {
    cell_t *c = heap_alloc(sizeof(cell_t));
    c->refcount = 1;
    c->_pad     = 0;
    c->head     = head;
    c->tail     = tail;
    if (noun_is_cell(head)) cell_inc(head);
    if (noun_is_cell(tail)) cell_inc(tail);
    return cell_noun((uint32_t)(uintptr_t)c);
}

void cell_inc(noun n) {
    if (!noun_is_cell(n)) return;
    cell_t *c = (cell_t *)(uintptr_t)cell_ptr(n);
    c->refcount++;
}

void cell_dec(noun n) {
    if (!noun_is_cell(n)) return;
    cell_t *c = (cell_t *)(uintptr_t)cell_ptr(n);
    if (--c->refcount == 0) {
        cell_dec(c->head);
        cell_dec(c->tail);
    }
}

/* ── Atom store ──────────────────────────────────────────────────────────────
 *
 * Index: open-addressed hash table at ATOM_INDEX_BASE.
 *   Each slot: { uint64_t hash62; atom_t *ptr } (16 bytes)
 *   65536 slots × 16 bytes = 1 MB (fits in ATOM_INDEX_SIZE).
 *
 * Data: bump allocator starting at ATOM_DATA_BASE.
 *   Each atom_t: 40 bytes header + size × 8 bytes for limbs.
 */

#define ATOM_INDEX_SLOTS  65536U
#define ATOM_INDEX_MASK   (ATOM_INDEX_SLOTS - 1U)

typedef struct {
    uint64_t  hash62;
    atom_t   *ptr;
} atom_index_entry_t;

static uint8_t *atom_data_ptr;

static void atom_store_init(void) {
    /* QEMU zeroes RAM at startup, so the index is already zeroed.
       Re-zero here anyway for robustness (e.g. after a warm reset). */
    atom_index_entry_t *idx = (atom_index_entry_t *)ATOM_INDEX_BASE;
    for (uint32_t i = 0; i < ATOM_INDEX_SLOTS; i++) {
        idx[i].hash62 = 0;
        idx[i].ptr    = 0;
    }
    atom_data_ptr = (uint8_t *)ATOM_DATA_BASE;
}

atom_t *atom_store_get(uint64_t hash62) {
    atom_index_entry_t *idx = (atom_index_entry_t *)ATOM_INDEX_BASE;
    uint32_t slot = (uint32_t)(hash62 & ATOM_INDEX_MASK);
    for (uint32_t i = 0; i < ATOM_INDEX_SLOTS; i++) {
        uint32_t s = (slot + i) & ATOM_INDEX_MASK;
        if (idx[s].ptr == 0)    return 0;  /* not found (empty slot) */
        if (idx[s].hash62 == hash62) return idx[s].ptr;
    }
    return 0;  /* table full or not found */
}

static atom_t *atom_store_alloc(uint64_t size_limbs) {
    size_t bytes = ((sizeof(atom_t) + size_limbs * sizeof(uint64_t)) + 7) & ~(size_t)7;
    uint8_t *p = atom_data_ptr;
    atom_data_ptr += bytes;
    /* TODO: check atom_data_ptr < ATOM_DATA_TOP */
    return (atom_t *)p;
}

static void atom_store_insert(uint64_t hash62, atom_t *ptr) {
    atom_index_entry_t *idx = (atom_index_entry_t *)ATOM_INDEX_BASE;
    uint32_t slot = (uint32_t)(hash62 & ATOM_INDEX_MASK);
    for (uint32_t i = 0; i < ATOM_INDEX_SLOTS; i++) {
        uint32_t s = (slot + i) & ATOM_INDEX_MASK;
        if (idx[s].ptr == 0) {
            idx[s].hash62 = hash62;
            idx[s].ptr    = ptr;
            return;
        }
        if (idx[s].hash62 == hash62) return;  /* already present */
    }
    /* Table full — silently drop (extremely unlikely in practice). */
}

/* ── make_atom ───────────────────────────────────────────────────────────────
 *
 * Canonical atom constructor.
 *   1. Strip trailing zero limbs.
 *   2. If size==1 and value < 2^63: return direct atom (no allocation).
 *   3. Compute BLAKE3 of the canonical byte representation.
 *   4. Look up hash in atom store; if found, return existing noun.
 *   5. Otherwise allocate a new atom_t, copy limbs, insert, return noun.
 */

/* Number of significant bytes in the last (most-significant) limb (1–8). */
static size_t last_limb_bytes(uint64_t w) {
    int sig = 8;
    while (sig > 1 && ((w >> ((sig - 1) * 8)) & 0xff) == 0)
        sig--;
    return (size_t)sig;
}

noun make_atom(const uint64_t *limbs, uint64_t size) {
    /* Strip trailing zero limbs */
    while (size > 1 && limbs[size - 1] == 0)
        size--;

    /* Promote to direct if value fits in 63 bits */
    if (size == 1 && limbs[0] < (1ULL << 63))
        return (noun)limbs[0];   /* direct(v) == v */

    /* Compute canonical byte length (trim trailing zero bytes of last limb) */
    size_t byte_len = (size - 1) * 8 + last_limb_bytes(limbs[size - 1]);

    /* Compute 256-bit BLAKE3 hash */
    uint8_t h[32];
    blake3_hash((const uint8_t *)limbs, byte_len, h);

    /* Extract 62-bit hash from first 8 bytes of output (little-endian) */
    uint64_t hash62 = 0;
    for (int i = 0; i < 8; i++)
        hash62 |= (uint64_t)h[i] << (i * 8);
    hash62 &= 0x3FFFFFFFFFFFFFFFULL;
    if (hash62 == 0) hash62 = 1;  /* 0 is the "empty" sentinel in the index */

    /* Check atom store: if already present, reuse */
    atom_t *existing = atom_store_get(hash62);
    if (existing != 0)
        return indirect(hash62);

    /* Allocate new atom_t in the data area */
    atom_t *a = atom_store_alloc(size);
    a->size = size;

    /* Store full 256-bit hash */
    for (int i = 0; i < 8; i++) {
        a->blake3[i] = (uint32_t)h[i*4]
                     | ((uint32_t)h[i*4+1] <<  8)
                     | ((uint32_t)h[i*4+2] << 16)
                     | ((uint32_t)h[i*4+3] << 24);
    }

    /* Copy limbs */
    for (uint64_t i = 0; i < size; i++)
        a->limbs[i] = limbs[i];

    atom_store_insert(hash62, a);
    return indirect(hash62);
}

/* ── cord_from_bytes ─────────────────────────────────────────────────────────
 * Create a cord (atom) from a C byte string.
 * Strings ≤ 7 bytes → direct atom (no allocation).
 * Longer strings → indirect atom via make_atom + BLAKE3.
 */
noun cord_from_bytes(const char *str, size_t len)
{
    /* Trim trailing null bytes — cords don't include them in the value */
    while (len > 0 && str[len - 1] == '\0')
        len--;
    if (len == 0)
        return direct(0);

    if (len <= 7) {
        uint64_t v = 0;
        for (size_t i = 0; i < len; i++)
            v |= (uint64_t)(uint8_t)str[i] << (8 * i);
        return direct(v);
    }

    /* Pack bytes into 64-bit limbs (LE), cap at 256 bytes */
    size_t nlimbs = (len + 7) / 8;
    if (nlimbs > 32) nlimbs = 32;
    uint64_t limbs[32];
    for (size_t i = 0; i < 32; i++) limbs[i] = 0;
    for (size_t i = 0; i < len && i < nlimbs * 8; i++)
        ((uint8_t *)limbs)[i] = (uint8_t)str[i];
    return make_atom(limbs, nlimbs);
}

/* ── cord_to_cstr ────────────────────────────────────────────────────────────
 * Decode a cord atom to a null-terminated C string.
 * Writes at most bufsz-1 bytes.  Returns the string length.
 */
size_t cord_to_cstr(noun n, char *buf, size_t bufsz)
{
    if (!bufsz) return 0;
    if (noun_is_direct(n)) {
        uint64_t v = direct_val(n);
        size_t len = 0;
        while (v && len < bufsz - 1) {
            buf[len++] = (char)(v & 0xFF);
            v >>= 8;
        }
        buf[len] = '\0';
        return len;
    }
    if (noun_is_indirect(n)) {
        uint64_t hash62 = n & 0x3FFFFFFFFFFFFFFFULL;
        atom_t *a = atom_store_get(hash62);
        if (!a) { buf[0] = '\0'; return 0; }
        size_t bytes = a->size * 8;
        /* strip trailing zero bytes of the last limb */
        while (bytes > 0 && ((uint8_t *)a->limbs)[bytes - 1] == 0)
            bytes--;
        if (bytes >= bufsz) bytes = bufsz - 1;
        for (size_t i = 0; i < bytes; i++)
            buf[i] = ((const char *)a->limbs)[i];
        buf[bytes] = '\0';
        return bytes;
    }
    buf[0] = '\0';
    return 0;
}

void noun_heap_init(void) {
    heap_ptr = (uint8_t *)HEAP_BASE;
    atom_store_init();
}

/* ── Equality ───────────────────────────────────────────────────────────────── */

int noun_eq(noun a, noun b) {
    /* Identical words → equal (direct atoms, same-hash indirect, same-ptr cells) */
    if (a == b) return 1;

    /* For atoms: word equality is exact (direct: same value; indirect: same hash) */
    if (noun_is_atom(a) && noun_is_atom(b))
        return 0;

    /* Both cells: structural equality */
    if (noun_is_cell(a) && noun_is_cell(b)) {
        cell_t *ca = (cell_t *)(uintptr_t)cell_ptr(a);
        cell_t *cb = (cell_t *)(uintptr_t)cell_ptr(b);
        return noun_eq(ca->head, cb->head) && noun_eq(ca->tail, cb->tail);
    }

    return 0;
}

/* ── pill_load ───────────────────────────────────────────────────────────── */

/*
 * PILL format v2:
 *   bytes  0-7:   uint64_t (LE) = byte count of jam data
 *   byte   8:     kernel shape  (0=Arvo, 1=Shrine)
 *   bytes  9-15:  reserved/padding
 *   bytes  16+:   raw jam bytes (16-byte aligned)
 *
 * Static scratch avoids stack overflow for large pills (~1MB limit).
 */
#define PILL_MAX_BYTES  (1024U * 1024U)
#define PILL_MAX_LIMBS  (PILL_MAX_BYTES / 8U)

int noun_pill_shape = 0;   /* 0=Arvo, 1=Shrine; set by pill_load */

static uint64_t pill_scratch[PILL_MAX_LIMBS];

/* Embedded pill: linked into .rodata via src/pill_embed.s (.incbin pill.bin). */
extern uint8_t _pill_embed_start[];
extern uint8_t _pill_embed_end[];

noun pill_load(void) {
    const uint8_t *base;
    uint64_t nbytes = 0;

    /*
     * Priority 1: QEMU -device loader places pill at PILL_BASE.
     *   QEMU raspi4b requires -m 2G; with that, 0x10000000 is accessible RAM.
     *   Read nbytes; if non-zero, the loader placed a pill there.
     * Priority 2: pill embedded in the binary via .incbin (real hardware).
     *   On bare metal the GPU firmware zeroes RAM, so PILL_BASE has nbytes=0.
     */
    const uint8_t *qbase = (const uint8_t *)PILL_BASE;
    uint64_t qnbytes = 0;
    for (int i = 0; i < 8; i++)
        qnbytes |= (uint64_t)qbase[i] << (i * 8);

    if (qnbytes > 0) {
        base   = qbase;
        nbytes = qnbytes;
    } else {
        base = _pill_embed_start;
        if (base >= _pill_embed_end)
            return 0;           /* no embedded pill */
        for (int i = 0; i < 8; i++)
            nbytes |= (uint64_t)base[i] << (i * 8);
    }

    if (nbytes == 0)
        return 0;   /* C null — sentinel for "no pill"; KERNEL checks cbz x0 */

    /* Read shape byte and store in global */
    noun_pill_shape = (int)base[8];

    /* Jam data starts at offset 16 (16-byte aligned) */
    uint64_t nlimbs = (nbytes + 7) / 8;
    if (nlimbs > PILL_MAX_LIMBS) nlimbs = PILL_MAX_LIMBS;

    uint8_t *dst = (uint8_t *)pill_scratch;
    volatile uint8_t *src = (volatile uint8_t *)(base + 16);
    for (uint64_t i = 0; i < nlimbs * 8; i++)
        dst[i] = (i < nbytes) ? src[i] : 0;

    /* Strip trailing zero limbs */
    uint64_t sig = nlimbs;
    while (sig > 1 && pill_scratch[sig - 1] == 0)
        sig--;

    return make_atom(pill_scratch, sig);
}
