/*
 * ska.c — Subject Knowledge Analysis implementation (Phase 7)
 *
 * Stages:
 *   7b (this file, initial): cape/sock operations
 *   7c: scan pass — linear opcodes
 *   7d: memo cache
 *   7e: loop detection (close + cycles + frond validation)
 *   7f: cook pass (nomm → nomm1)
 *   7g: run_nomm1 + ska_analyze public entry point
 *
 * Reference: skan.hoon (dozreg-toplud/ska), arms ++so (sock ops) and ++ca (cape ops)
 */

#include "ska.h"
#include "noun.h"
#include "uart.h"
#include <stdint.h>
#include <stdbool.h>

/* ═══════════════════════════════════════════════════════════════════════════
 * Bump arena for nomm_t / nomm1_t / boil_t allocations.
 * Lives in BSS; reset after each top-level ska_analyze() call (or on demand).
 * ═══════════════════════════════════════════════════════════════════════════ */

#define SKA_ARENA_SIZE (256 * 1024)   /* 256 KB — sufficient for typical formulas */
static uint8_t  ska_arena[SKA_ARENA_SIZE];
static uint32_t ska_arena_off = 0;

static void *ska_alloc(uint32_t size)
{
    size = (size + 7) & ~7u;   /* 8-byte align */
    if (ska_arena_off + size > SKA_ARENA_SIZE) {
        uart_puts("ska: arena exhausted\n");
        return (void *)0;
    }
    void *p = &ska_arena[ska_arena_off];
    ska_arena_off += size;
    /* zero-init (BSS is already zero at boot; resets are explicit) */
    for (uint32_t i = 0; i < size; i++)
        ((uint8_t *)p)[i] = 0;
    return p;
}

void ska_arena_reset(void)
{
    ska_arena_off = 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Stage 7b — Cape operations  (mirrors Hoon ++ca in skan.hoon)
 *
 *   cape_known()          → & (CAPE_KNOWN, atom 0)
 *   cape_wild()           → | (CAPE_WILD,  atom 1)
 *   cape_is_known(c)      → true iff c == &
 *   cape_is_wild(c)       → true iff c == |
 *   cape_and(a, b)        → intersection: a & b (more restrictive)
 *   cape_or(a, b)         → union:        a | b (more permissive)
 *   cape_head(c)          → head cape (| if c is atom)
 *   cape_tail(c)          → tail cape (| if c is atom)
 *   cape_cons(h, t)       → [h t] cape — allocates cell if non-trivial
 *   cape_pull(c, ax)      → sub-cape at axis ax (Nock slot)
 * ═══════════════════════════════════════════════════════════════════════════ */

static inline cape_t cape_known(void) { return CAPE_KNOWN; }
static inline cape_t cape_wild(void)  { return CAPE_WILD;  }

static inline bool cape_is_known(cape_t c) { return noun_eq(c, CAPE_KNOWN); }
static inline bool cape_is_wild(cape_t c)  { return noun_eq(c, CAPE_WILD);  }

/*
 * cape_and: intersection — result is KNOWN only where both inputs are KNOWN.
 * Mirrors ++and:ca in skan.hoon:
 *   &  & = &
 *   &  | = |   (or vice versa)
 *   |  | = |
 *   [h1 t1] [h2 t2] = [and(h1,h2) and(t1,t2)]
 *   [.] &  = [and(h,&) and(t,&)] = [.]  (& absorbs into cell)
 *   [.] |  = |
 */
cape_t cape_and(cape_t a, cape_t b)
{
    if (cape_is_wild(a) || cape_is_wild(b)) return cape_wild();
    if (cape_is_known(a)) return b;
    if (cape_is_known(b)) return a;
    /* both are cells */
    noun ah = ((cell_t *)(uintptr_t)cell_ptr(a))->head;
    noun at = ((cell_t *)(uintptr_t)cell_ptr(a))->tail;
    noun bh = ((cell_t *)(uintptr_t)cell_ptr(b))->head;
    noun bt = ((cell_t *)(uintptr_t)cell_ptr(b))->tail;
    cape_t rh = cape_and(ah, bh);
    cape_t rt = cape_and(at, bt);
    if (cape_is_wild(rh) && cape_is_wild(rt)) return cape_wild();
    return alloc_cell(rh, rt);
}

/*
 * cape_or: union — result is KNOWN where either input is KNOWN.
 * Mirrors ++or:ca in skan.hoon.
 */
cape_t cape_or(cape_t a, cape_t b)
{
    if (cape_is_known(a) || cape_is_known(b)) return cape_known();
    if (cape_is_wild(a)) return b;
    if (cape_is_wild(b)) return a;
    /* both are cells */
    noun ah = ((cell_t *)(uintptr_t)cell_ptr(a))->head;
    noun at = ((cell_t *)(uintptr_t)cell_ptr(a))->tail;
    noun bh = ((cell_t *)(uintptr_t)cell_ptr(b))->head;
    noun bt = ((cell_t *)(uintptr_t)cell_ptr(b))->tail;
    cape_t rh = cape_or(ah, bh);
    cape_t rt = cape_or(at, bt);
    if (cape_is_known(rh) && cape_is_known(rt)) return cape_known();
    return alloc_cell(rh, rt);
}

/* cape_head / cape_tail: descend into a cape tree.
 * If the cape is an atom (KNOWN or WILD), treat as if both children are the same.
 * Mirrors ++heb / ++teb arms in skan.hoon's ++ca. */
static cape_t cape_head(cape_t c)
{
    if (noun_is_atom(c)) return c;
    return ((cell_t *)(uintptr_t)cell_ptr(c))->head;
}

static cape_t cape_tail(cape_t c)
{
    if (noun_is_atom(c)) return c;
    return ((cell_t *)(uintptr_t)cell_ptr(c))->tail;
}

/* cape_cons: build [h t] cape, collapsing trivial cases. */
static cape_t cape_cons(cape_t h, cape_t t)
{
    if (cape_is_known(h) && cape_is_known(t)) return cape_known();
    if (cape_is_wild(h)  && cape_is_wild(t))  return cape_wild();
    return alloc_cell(h, t);
}

/*
 * cape_pull: extract sub-cape at Nock axis ax.
 * Axis 1 = self.  Axis 2 = head.  Axis 3 = tail.
 * Axis n (n>3): recurse: even → head side, odd → tail side.
 * Returns WILD on any axis that doesn't exist (fault-tolerant).
 */
cape_t cape_pull(cape_t c, noun ax)
{
    if (!noun_is_direct(ax)) return cape_wild();
    uint64_t a = direct_val(ax);
    if (a == 0) return cape_wild();   /* axis 0 is invalid in Nock */
    if (a == 1) return c;
    /* Walk from MSB to LSB of axis (skip leading 1 bit). */
    int depth = 63;
    while (depth > 0 && !((a >> depth) & 1)) depth--;
    depth--;   /* skip the leading 1 */
    while (depth >= 0) {
        if (noun_is_atom(c)) return c;  /* atom cape propagates down */
        if ((a >> depth) & 1)
            c = cape_tail(c);
        else
            c = cape_head(c);
        depth--;
    }
    return c;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Stage 7b — Sock operations  (mirrors Hoon ++so in skan.hoon)
 *
 *   sock_dunno(sub)        → [| 0] — completely unknown result
 *   sock_known(val)        → [& val] — exactly known
 *   sock_pull(sock, ax)    → sub-sock at Nock axis ax
 *   sock_huge(a, b)        → true iff a ⊇ b (a subsumes b)
 *   sock_knit(a, b)        → autocons: [a.data b.data] with combined cape
 *   sock_purr(a, b)        → intersection: known only where both agree
 *   sock_pack(a, b)        → join for %6 branches (like purr but for data)
 *   sock_darn(sub, ax, edit) → tree edit: replace sub-noun at ax with edit
 * ═══════════════════════════════════════════════════════════════════════════ */

/* sock_dunno: completely unknown result, subject for reference only.
 * Mirrors  ++dunno:so  in skan.hoon — produce wildcard sock. */
static sock_t sock_dunno(sock_t sub)
{
    (void)sub;
    return (sock_t){ .cape = cape_wild(), .data = NOUN_ZERO };
}

/* sock_known: fully known constant. */
static sock_t sock_known(noun val)
{
    return (sock_t){ .cape = cape_known(), .data = val };
}

/*
 * sock_pull: extract sub-sock at Nock axis ax.
 * Mirrors ++pull:so in skan.hoon.
 * If the axis doesn't exist in the data noun, returns dunno.
 */
sock_t sock_pull(sock_t s, noun ax)
{
    if (!noun_is_direct(ax)) return sock_dunno(s);
    uint64_t a = direct_val(ax);
    if (a == 0) return sock_dunno(s);

    cape_t c = cape_pull(s.cape, ax);
    noun   d = s.data;

    /* Walk the data noun the same way as the cape. */
    if (a != 1) {
        int depth = 63;
        while (depth > 0 && !((a >> depth) & 1)) depth--;
        depth--;
        while (depth >= 0) {
            if (!noun_is_cell(d)) return sock_dunno(s);
            cell_t *cell = (cell_t *)(uintptr_t)cell_ptr(d);
            if ((a >> depth) & 1)
                d = cell->tail;
            else
                d = cell->head;
            depth--;
        }
    }
    return (sock_t){ .cape = c, .data = d };
}

/*
 * sock_huge: does sock `a` subsume sock `b`?
 * a ⊇ b means: everywhere b is KNOWN, a is also KNOWN (and equal).
 * Mirrors ++huge:so in skan.hoon.
 */
bool sock_huge(sock_t a, sock_t b)
{
    /* If b is entirely wild, a trivially subsumes b. */
    if (cape_is_wild(b.cape)) return true;
    /* If b is entirely known, a must also be entirely known and equal. */
    if (cape_is_known(b.cape))
        return cape_is_known(a.cape) && noun_eq(a.data, b.data);
    /* Both are cell capes — recurse. */
    if (noun_is_atom(a.cape)) {
        /* a.cape is KNOWN or WILD atom — handle as uniform.
         * If a.cape=WILD, a doesn't subsume any non-wild b. */
        if (cape_is_wild(a.cape)) return false;
        /* a.cape=KNOWN: a.data must equal b.data at every known position.
         * We approximate: if a is fully known and equal to b's data, ok. */
        return noun_eq(a.data, b.data);
    }
    if (noun_is_atom(b.cape)) return false;  /* b is cell, a is not — handled above */
    /* Both cell capes: split into head/tail and recurse. */
    sock_t ah = sock_pull(a, direct(2));
    sock_t at = sock_pull(a, direct(3));
    sock_t bh = sock_pull(b, direct(2));
    sock_t bt = sock_pull(b, direct(3));
    return sock_huge(ah, bh) && sock_huge(at, bt);
}

/*
 * sock_knit: autocons of two socks — produces a cell sock.
 * Mirrors ++knit:so in skan.hoon: combine head-sock and tail-sock.
 */
sock_t sock_knit(sock_t h, sock_t t)
{
    cape_t c = cape_cons(h.cape, t.cape);
    noun   d = alloc_cell(h.data, t.data);
    return (sock_t){ .cape = c, .data = d };
}

/*
 * sock_purr: intersection — the result is KNOWN only where both socks agree.
 * Mirrors ++purr:so in skan.hoon.
 * Used for %6 branches: we know the result where both branches agree.
 */
sock_t sock_purr(sock_t a, sock_t b)
{
    if (cape_is_wild(a.cape)) return sock_dunno(a);
    if (cape_is_wild(b.cape)) return sock_dunno(b);
    if (cape_is_known(a.cape) && cape_is_known(b.cape)) {
        if (noun_eq(a.data, b.data)) return a;
        return sock_dunno(a);
    }
    /* At least one is a cell cape — recurse per-axis. */
    sock_t ah = sock_pull(a, direct(2));
    sock_t at = sock_pull(a, direct(3));
    sock_t bh = sock_pull(b, direct(2));
    sock_t bt = sock_pull(b, direct(3));
    return sock_knit(sock_purr(ah, bh), sock_purr(at, bt));
}

/*
 * sock_darn: tree edit — replace the noun at axis `ax` in `s` with `edit`.
 * Mirrors ++darn:so in skan.hoon (which itself mirrors Nock %10 / hax()).
 * Returns a new sock representing the edited noun.
 */
sock_t sock_darn(sock_t s, noun ax, sock_t edit)
{
    if (!noun_is_direct(ax)) return sock_dunno(s);
    uint64_t a = direct_val(ax);
    if (a == 0) return sock_dunno(s);
    if (a == 1) return edit;
    /* Recurse: axis n → head (n*2) or tail (n*2+1). */
    uint64_t parent = a >> 1;
    bool is_tail = (a & 1);
    sock_t cur = sock_pull(s, direct(parent));
    sock_t new_h = is_tail ? sock_pull(cur, direct(2))
                           : edit;
    sock_t new_t = is_tail ? edit
                           : sock_pull(cur, direct(3));
    sock_t new_cur = sock_knit(new_h, new_t);
    return sock_darn(s, direct(parent), new_cur);
}
