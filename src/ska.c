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
#include "nock.h"
#include "bignum.h"
#include "uart.h"
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

/* ═══════════════════════════════════════════════════════════════════════════
 * Stage 7c — Scan pass (linear opcodes; op 2 / op 9 fall back to NOMM_I2)
 *
 * scan(sub, fol) → nomm_t*
 *   sub : current subject sock (what we know about the subject at this point)
 *   fol : formula noun to analyse
 *   Returns annotated nomm_t*.  Each node carries a `prod` sock recording
 *   what the evaluator knows about the result of this sub-formula.
 *
 * Reference: skan.hoon ++scan / ++scan-1 arms.
 * ═══════════════════════════════════════════════════════════════════════════ */

/* Helper: allocate and zero-init a nomm_t node from the arena. */
static nomm_t *nomm_alloc(void)
{
    return (nomm_t *)ska_alloc(sizeof(nomm_t));
}

/* Forward declaration for mutual recursion. */
static nomm_t *scan(sock_t sub, noun fol);

/*
 * scan_cell: scan a formula that has already been unpacked into (head, tail).
 * Handles the distribution rule and all named opcodes.
 */
static nomm_t *scan_cell(sock_t sub, noun head, noun tail)
{
    nomm_t *n = nomm_alloc();
    if (!n) return NULL;

    /* ── Distribution rule: *[a [b c] d] = [*[a b c] *[a d]] ── */
    if (noun_is_cell(head)) {
        nomm_t *p = scan(sub, head);
        nomm_t *q = scan(sub, tail);
        if (!p || !q) return NULL;
        n->tag    = NOMM_DIST;
        n->ndist.p = p;
        n->ndist.q = q;
        n->prod   = sock_knit(p->prod, q->prod);
        return n;
    }

    /* head must be a direct atom — the opcode */
    if (!noun_is_direct(head)) {
        uart_puts("ska: non-direct opcode\n");
        return NULL;
    }
    uint64_t op = direct_val(head);

    switch (op) {

    /* ── 0: slot /[b a] ── */
    case 0:
        n->tag    = NOMM_0;
        n->n0.ax  = tail;
        n->prod   = sock_pull(sub, tail);
        return n;

    /* ── 1: quote b ── */
    case 1:
        n->tag     = NOMM_1;
        n->n1.val  = tail;
        n->prod    = sock_known(tail);
        return n;

    /* ── 2: eval *[*[a b] *[a c]] — conservative NOMM_I2 at Stage 7c ── */
    case 2: {
        if (!noun_is_cell(tail)) {
            uart_puts("ska: op2 tail not cell\n");
            return NULL;
        }
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        nomm_t *p = scan(sub, args->head);   /* subject formula  */
        nomm_t *q = scan(sub, args->tail);   /* formula formula  */
        if (!p || !q) return NULL;
        n->tag   = NOMM_I2;
        n->i2.p  = p;
        n->i2.q  = q;
        n->prod  = sock_dunno(sub);
        return n;
    }

    /* ── 3: cell? ?*[a b] ── */
    case 3: {
        nomm_t *p = scan(sub, tail);
        if (!p) return NULL;
        n->tag       = NOMM_3;
        n->n_unary.p = p;
        n->prod      = (sock_t){ .cape = cape_wild(), .data = NOUN_ZERO };
        return n;
    }

    /* ── 4: inc +*[a b] ── */
    case 4: {
        nomm_t *p = scan(sub, tail);
        if (!p) return NULL;
        n->tag       = NOMM_4;
        n->n_unary.p = p;
        n->prod      = (sock_t){ .cape = cape_wild(), .data = NOUN_ZERO };
        return n;
    }

    /* ── 5: eq =[*[a b] *[a c]] ── */
    case 5: {
        if (!noun_is_cell(tail)) {
            uart_puts("ska: op5 tail not cell\n");
            return NULL;
        }
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        nomm_t *p = scan(sub, args->head);
        nomm_t *q = scan(sub, args->tail);
        if (!p || !q) return NULL;
        /* If both products are KNOWN and equal, result is KNOWN NOUN_YES. */
        sock_t prod;
        if (cape_is_known(p->prod.cape) && cape_is_known(q->prod.cape) &&
            noun_eq(p->prod.data, q->prod.data))
            prod = sock_known(NOUN_YES);
        else
            prod = (sock_t){ .cape = cape_wild(), .data = NOUN_ZERO };
        n->tag    = NOMM_5;
        n->n5.p   = p;
        n->n5.q   = q;
        n->prod   = prod;
        return n;
    }

    /* ── 6: if-then-else [6 c y n] ── */
    case 6: {
        if (!noun_is_cell(tail)) {
            uart_puts("ska: op6 tail not cell\n");
            return NULL;
        }
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun cond_fol = args->head;
        if (!noun_is_cell(args->tail)) {
            uart_puts("ska: op6 missing branches\n");
            return NULL;
        }
        cell_t *branches = (cell_t *)(uintptr_t)cell_ptr(args->tail);
        nomm_t *c = scan(sub, cond_fol);
        nomm_t *y = scan(sub, branches->head);
        nomm_t *nn = scan(sub, branches->tail);
        if (!c || !y || !nn) return NULL;
        /* If condition is KNOWN, result is the known branch. */
        sock_t prod;
        if (cape_is_known(c->prod.cape)) {
            if (noun_eq(c->prod.data, NOUN_YES))
                prod = y->prod;
            else
                prod = nn->prod;
        } else {
            prod = sock_purr(y->prod, nn->prod);
        }
        n->tag  = NOMM_6;
        n->n6.c = c;
        n->n6.y = y;
        n->n6.n = nn;
        n->prod = prod;
        return n;
    }

    /* ── 7: compose *[*[a b] c] ── */
    case 7: {
        if (!noun_is_cell(tail)) {
            uart_puts("ska: op7 tail not cell\n");
            return NULL;
        }
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        nomm_t *p = scan(sub, args->head);
        if (!p) return NULL;
        /* q is evaluated against p's product — pass p->prod as subject */
        nomm_t *q = scan(p->prod, args->tail);
        if (!q) return NULL;
        n->tag  = NOMM_7;
        n->n7.p = p;
        n->n7.q = q;
        n->prod = q->prod;
        return n;
    }

    /* ── 8: push *[[*[a b] a] c] ── */
    case 8: {
        if (!noun_is_cell(tail)) {
            uart_puts("ska: op8 tail not cell\n");
            return NULL;
        }
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        nomm_t *p = scan(sub, args->head);
        if (!p) return NULL;
        /* New subject is [*[a b], a] — knit product with original subject */
        sock_t pushed_sub = sock_knit(p->prod, sub);
        nomm_t *q = scan(pushed_sub, args->tail);
        if (!q) return NULL;
        n->tag  = NOMM_8;
        n->n8.p = p;
        n->n8.q = q;
        n->prod = q->prod;
        return n;
    }

    /* ── 9: invoke *[*[a c] 2 [0 1] 0 b]
     * Core = eval c; arm = slot(b, core); eval core as its own subject.
     * At Stage 7c: arm could recurse, so emit NOMM_9 and fall back in eval.
     * ── */
    case 9: {
        if (!noun_is_cell(tail)) {
            uart_puts("ska: op9 tail not cell\n");
            return NULL;
        }
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun b          = args->head;     /* axis to pull arm from core */
        nomm_t *core_fol = scan(sub, args->tail);
        if (!core_fol) return NULL;
        n->tag            = NOMM_9;
        n->n9.ax          = b;
        n->n9.core_fol    = core_fol;
        n->prod           = sock_dunno(sub);
        return n;
    }

    /* ── 10: hax tree-edit #[b *[a c] *[a d]]
     * tail = [[b c] d] where b=axis (atom), c=val formula, d=target formula
     * ── */
    case 10: {
        if (!noun_is_cell(tail)) {
            uart_puts("ska: op10 tail not cell\n");
            return NULL;
        }
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun hint = args->head;
        noun d    = args->tail;
        if (!noun_is_cell(hint)) {
            uart_puts("ska: op10 hint must be cell\n");
            return NULL;
        }
        cell_t *hc  = (cell_t *)(uintptr_t)cell_ptr(hint);
        noun b      = hc->head;   /* edit axis — must be direct atom */
        nomm_t *val_fol = scan(sub, hc->tail);
        nomm_t *tgt_fol = scan(sub, d);
        if (!val_fol || !tgt_fol) return NULL;
        /* Product: apply sock_darn if we know enough; else dunno. */
        sock_t prod;
        if (cape_is_known(tgt_fol->prod.cape) && cape_is_known(val_fol->prod.cape))
            prod = sock_darn(tgt_fol->prod, b, val_fol->prod);
        else
            prod = sock_dunno(sub);
        n->tag          = NOMM_10;
        n->n10.ax       = b;
        n->n10.val_fol  = val_fol;
        n->n10.tgt_fol  = tgt_fol;
        n->prod         = prod;
        return n;
    }

    /* ── 11: hint
     * Static:  [11 tag d]       → *[a d]         (tag is atom)
     * Dynamic: [11 [tag clue] d] → hint fires, then *[a d]
     * ── */
    case 11: {
        if (!noun_is_cell(tail)) {
            uart_puts("ska: op11 tail not cell\n");
            return NULL;
        }
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun hint = args->head;
        noun d    = args->tail;
        nomm_t *main_fol = scan(sub, d);
        if (!main_fol) return NULL;

        if (!noun_is_cell(hint)) {
            /* Static hint — tag is atom, no clue evaluation */
            n->tag         = NOMM_11;
            n->n11.tag     = hint;
            n->n11.clue    = NULL;
            n->n11.main    = main_fol;
            n->n11.is_dyn  = false;
            n->prod        = main_fol->prod;
        } else {
            /* Dynamic hint — hint = [tag clue_formula] */
            cell_t *hc   = (cell_t *)(uintptr_t)cell_ptr(hint);
            nomm_t *clue = scan(sub, hc->tail);
            if (!clue) return NULL;
            n->tag         = NOMM_11;
            n->n11.tag     = hc->head;
            n->n11.clue    = clue;
            n->n11.main    = main_fol;
            n->n11.is_dyn  = true;
            n->prod        = main_fol->prod;
        }
        return n;
    }

    /* ── 12: scry .^[*[a b] *[a c]] ── */
    case 12: {
        if (!noun_is_cell(tail)) {
            uart_puts("ska: op12 tail not cell\n");
            return NULL;
        }
        cell_t *args    = (cell_t *)(uintptr_t)cell_ptr(tail);
        nomm_t *ref_fol   = scan(sub, args->head);
        nomm_t *thunk_fol = scan(sub, args->tail);
        if (!ref_fol || !thunk_fol) return NULL;
        n->tag              = NOMM_12;
        n->n12.ref_fol      = ref_fol;
        n->n12.thunk_fol    = thunk_fol;
        n->prod             = sock_dunno(sub);
        return n;
    }

    default:
        uart_puts("ska: unknown opcode\n");
        return NULL;
    }
}

/*
 * scan: top-level scan entry for one formula noun.
 */
static nomm_t *scan(sock_t sub, noun fol)
{
    if (!noun_is_cell(fol)) {
        uart_puts("ska: formula is atom\n");
        return NULL;
    }
    cell_t *fc = (cell_t *)(uintptr_t)cell_ptr(fol);
    return scan_cell(sub, fc->head, fc->tail);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Stage 7c — eval_nomm: interpret a nomm_t AST
 *
 * Mirrors nock_eval() but dispatches on the nomm_t structure.
 * Linear opcodes are handled natively; NOMM_I2 / NOMM_9 fall back to
 * nock_eval() which has its own TCO loop.
 *
 * Note: extern nock_eval is not exposed in nock.h (it's static).
 * We use the public nock_ex() / nock() shim instead.
 * ═══════════════════════════════════════════════════════════════════════════ */

/* ── hax inline: tree edit #[a v t] ─────────────────────────────────────────
 * Mirrors the static hax() in nock.c.  Used by eval_nomm for NOMM_10.
 */
static noun ska_hax(uint64_t a, noun new_val, noun target)
{
    if (a == 0) nock_crash("ska hax: axis 0");
    if (a == 1) return new_val;
    if (!noun_is_cell(target)) nock_crash("ska hax: edit in atom");

    cell_t *t = (cell_t *)(uintptr_t)cell_ptr(target);
    int d = 0;
    uint64_t tmp = a;
    while (tmp > 1) { tmp >>= 1; d++; }
    int first = (int)((a >> (d - 1)) & 1);
    uint64_t sub_ax = (a & ((1ULL << (d - 1)) - 1)) | (1ULL << (d - 1));

    if (first == 0)
        return alloc_cell(ska_hax(sub_ax, new_val, t->head), t->tail);
    else
        return alloc_cell(t->head, ska_hax(sub_ax, new_val, t->tail));
}

/* ── ska_parse_wilt: parse a $wilt noun into a wilt_t ───────────────────────
 * Mirrors parse_wilt() in nock.c.
 * $wilt = (list [label [cape data]])
 */
static void ska_parse_wilt(noun wilt_noun, wilt_t *out)
{
    out->len = 0;
    while (noun_is_cell(wilt_noun) && out->len < WILT_MAX) {
        cell_t *cons  = (cell_t *)(uintptr_t)cell_ptr(wilt_noun);
        noun    elem  = cons->head;
        wilt_noun     = cons->tail;

        if (!noun_is_cell(elem)) continue;
        cell_t *ep    = (cell_t *)(uintptr_t)cell_ptr(elem);
        noun    label = ep->head;
        noun    sock  = ep->tail;

        if (!noun_is_cell(sock)) continue;
        cell_t *sp    = (cell_t *)(uintptr_t)cell_ptr(sock);

        out->e[out->len].label     = label;
        out->e[out->len].sock.cape = sp->head;
        out->e[out->len].sock.data = sp->tail;
        out->len++;
    }
}

/* Helper: forward a full nock call through the public nock_ex shim. */
static inline noun fallback(noun subj, noun fml,
                             const wilt_t *jets, sky_fn_t sky)
{
    return nock_ex(subj, fml, jets, sky);
}

static noun eval_nomm(const nomm_t *n, noun sub,
                      const wilt_t *jets, sky_fn_t sky)
{
    if (!n) {
        nock_crash("ska: eval_nomm null node");
        return NOUN_ZERO;  /* unreachable */
    }

    switch (n->tag) {

    case NOMM_0:
        return slot(n->n0.ax, sub);

    case NOMM_1:
        return n->n1.val;

    case NOMM_3: {
        noun r = eval_nomm(n->n_unary.p, sub, jets, sky);
        return noun_is_cell(r) ? NOUN_YES : NOUN_NO;
    }

    case NOMM_4: {
        noun r = eval_nomm(n->n_unary.p, sub, jets, sky);
        if (!noun_is_atom(r)) nock_crash("op4: increment of cell");
        return bn_inc(r);
    }

    case NOMM_5: {
        noun l = eval_nomm(n->n5.p, sub, jets, sky);
        noun r = eval_nomm(n->n5.q, sub, jets, sky);
        return noun_eq(l, r) ? NOUN_YES : NOUN_NO;
    }

    case NOMM_6: {
        noun cond = eval_nomm(n->n6.c, sub, jets, sky);
        if (noun_eq(cond, NOUN_YES))
            return eval_nomm(n->n6.y, sub, jets, sky);
        if (noun_eq(cond, NOUN_NO))
            return eval_nomm(n->n6.n, sub, jets, sky);
        nock_crash("op6: condition not 0 or 1");
        return NOUN_ZERO;
    }

    case NOMM_7: {
        noun mid = eval_nomm(n->n7.p, sub, jets, sky);
        return eval_nomm(n->n7.q, mid, jets, sky);
    }

    case NOMM_8: {
        noun val    = eval_nomm(n->n8.p, sub, jets, sky);
        noun new_sub = alloc_cell(val, sub);
        return eval_nomm(n->n8.q, new_sub, jets, sky);
    }

    case NOMM_9: {
        /* core = eval core_fol; then dispatch jets or eval arm */
        noun core = eval_nomm(n->n9.core_fol, sub, jets, sky);
        return nock_op9_continue(core, n->n9.ax, jets, sky);
    }

    case NOMM_10: {
        /* hax tree edit: #[ax val target] */
        noun val    = eval_nomm(n->n10.val_fol, sub, jets, sky);
        noun target = eval_nomm(n->n10.tgt_fol, sub, jets, sky);
        if (!noun_is_direct(n->n10.ax))
            nock_crash("op10: edit axis not direct");
        uint64_t ax = direct_val(n->n10.ax);
        if (ax == 0) nock_crash("op10: edit axis 0");
        return ska_hax(ax, val, target);
    }

    case NOMM_11: {
        if (n->n11.is_dyn) {
            noun clue = eval_nomm(n->n11.clue, sub, jets, sky);
            if (noun_is_direct(n->n11.tag) &&
                direct_val(n->n11.tag) == 0x646C6977ULL /* %wild */) {
                /* Parse the %wild clue and scope the new wilt into main. */
                wilt_t wild_buf;
                ska_parse_wilt(clue, &wild_buf);
                return eval_nomm(n->n11.main, sub, &wild_buf, sky);
            }
            (void)clue;
        }
        return eval_nomm(n->n11.main, sub, jets, sky);
    }

    case NOMM_12:
        /* Scry — fall back to nock_ex which will crash or dispatch sky */
        /* We can't reconstruct the formula noun here; crash informatively. */
        nock_crash("ska: op12 scry requires sky handler via fallback");
        return NOUN_ZERO;

    case NOMM_DIST: {
        noun head = eval_nomm(n->ndist.p, sub, jets, sky);
        noun tail = eval_nomm(n->ndist.q, sub, jets, sky);
        return alloc_cell(head, tail);
    }

    case NOMM_I2: {
        noun new_sub = eval_nomm(n->i2.p, sub, jets, sky);
        noun new_fol = eval_nomm(n->i2.q, sub, jets, sky);
        return fallback(new_sub, new_fol, jets, sky);
    }

    case NOMM_DS2:
    case NOMM_DUS2:
        /* DS2/DUS2 only appear after the cook pass (Stage 7f). */
        nock_crash("ska: ds2/dus2 in uncocked nomm");
        return NOUN_ZERO;

    case NOMM_2:
        /* NOMM_2 only appears in nomm1_t after cook pass. */
        nock_crash("ska: nomm_2 in uncocked nomm");
        return NOUN_ZERO;

    default:
        nock_crash("ska: unknown nomm tag");
        return NOUN_ZERO;
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Stage 7c — Public entry points
 * ═══════════════════════════════════════════════════════════════════════════ */

/*
 * ska_nock: analyze formula, then evaluate the resulting nomm_t AST.
 * Resets the arena on each call to avoid leaking nomm_t allocations.
 */
noun ska_nock(noun subject, noun formula,
              const wilt_t *jets, sky_fn_t sky)
{
    ska_arena_reset();

    /* Start with a fully wildcard subject sock (no static knowledge). */
    sock_t sub_sock = (sock_t){ .cape = cape_wild(), .data = subject };

    nomm_t *nomm = scan(sub_sock, formula);
    if (!nomm) {
        /* scan failed — fall back to nock_ex */
        return fallback(subject, formula, jets, sky);
    }

    return eval_nomm(nomm, subject, jets, sky);
}

/* Stubs for cook-pass API (Stage 7f). */
boil_t *ska_analyze(noun subject, noun formula,
                    const wilt_t *jets, sky_fn_t sky)
{
    (void)subject; (void)formula; (void)jets; (void)sky;
    return NULL;
}

noun run_nomm1(const nomm1_t *n, noun subject,
               const wilt_t *jets, sky_fn_t sky)
{
    (void)n; (void)subject; (void)jets; (void)sky;
    nock_crash("run_nomm1: cook pass not yet implemented (Stage 7f)");
    return NOUN_ZERO;
}
