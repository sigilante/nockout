#include <stdint.h>
#include "noun.h"
#include "nock.h"
#include "uart.h"

/* ── Crash ───────────────────────────────────────────────────────────────── */

static void nock_crash(const char *msg) {
    uart_puts("\r\nnock crash: ");
    uart_puts(msg);
    uart_puts("\r\n");
    for (;;) {}     /* halt — Phase 3c will longjmp to QUIT instead */
}

/* ── Noun printer (%slog, %xray) ─────────────────────────────────────────── */

static void uart_hex64(uint64_t v) {
    char buf[17];
    buf[16] = '\0';
    for (int i = 15; i >= 0; i--) {
        buf[i] = "0123456789abcdef"[v & 0xF];
        v >>= 4;
    }
    uart_puts(buf);
}

#define NOUN_PRINT_DEPTH_MAX 12

static void noun_print(noun n, int depth) {
    if (depth > NOUN_PRINT_DEPTH_MAX) { uart_puts("..."); return; }
    if (noun_is_atom(n)) {
        if (noun_is_direct(n))
            uart_hex64(direct_val(n));
        else
            uart_puts("<bignum>");
        return;
    }
    cell_t *c = (cell_t *)(uintptr_t)cell_ptr(n);
    uart_puts("[");
    noun_print(c->head, depth + 1);
    uart_puts(" ");
    noun_print(c->tail, depth + 1);
    uart_puts("]");
}

/* ── Hint tag constants (Urbit cord encoding: LSB = first char) ──────────── */

#define HINT_WILD  0x646C6977ULL   /* %wild */
#define HINT_SLOG  0x676F6C73ULL   /* %slog */
#define HINT_XRAY  0x79617278ULL   /* %xray */
#define HINT_MEAN  0x6E61656DULL   /* %mean */
#define HINT_MEMO  0x6F6D656DULL   /* %memo */
#define HINT_BOUT  0x74756F62ULL   /* %bout */

/* ── Wilt parsing ────────────────────────────────────────────────────────── */

/*
 * Parse a $wilt noun (Hoon list of [label sock] pairs) into a wilt_t.
 * A Hoon list is either 0 (null) or [[head tail_of_pair] rest].
 *   element = [label [cape data]]
 */
static void parse_wilt(noun wilt_noun, wilt_t *out) {
    out->len = 0;
    while (noun_is_cell(wilt_noun) && out->len < WILT_MAX) {
        cell_t *cons  = (cell_t *)(uintptr_t)cell_ptr(wilt_noun);
        noun    elem  = cons->head;
        wilt_noun     = cons->tail;

        if (!noun_is_cell(elem)) continue;          /* malformed — skip */
        cell_t *ep    = (cell_t *)(uintptr_t)cell_ptr(elem);
        noun    label = ep->head;
        noun    sock  = ep->tail;                   /* [cape data] */

        if (!noun_is_cell(sock)) continue;          /* malformed — skip */
        cell_t *sp    = (cell_t *)(uintptr_t)cell_ptr(sock);

        out->e[out->len].label     = label;
        out->e[out->len].sock.cape = sp->head;
        out->e[out->len].sock.data = sp->tail;
        out->len++;
    }
}

/* ── Sock matching ────────────────────────────────────────────────────────── */

/*
 * Does (cape, data) match subject?
 *   cape == NOUN_YES (0) → exact: data must equal subject
 *   cape == NOUN_NO  (1) → wildcard: always matches
 *   cape is cell         → recurse into head and tail
 */
static int sock_match(noun cape, noun data, noun subject) {
    if (noun_is_atom(cape)) {
        if (direct_val(cape) == 0)      /* & — exact match */
            return noun_eq(data, subject);
        return 1;                       /* | — wildcard */
    }
    if (!noun_is_cell(subject)) return 0;   /* structural mismatch */
    cell_t *cc = (cell_t *)(uintptr_t)cell_ptr(cape);
    cell_t *dc = (cell_t *)(uintptr_t)cell_ptr(data);
    cell_t *sc = (cell_t *)(uintptr_t)cell_ptr(subject);
    return sock_match(cc->head, dc->head, sc->head)
        && sock_match(cc->tail, dc->tail, sc->tail);
}

/* ── Hot state (Phase 11d: populated with real jets) ─────────────────────── */

typedef struct { uint64_t label_cord; jet_fn_t fn; } hot_entry_t;

static const hot_entry_t hot_state[] = {
    { 0, NULL }     /* sentinel — no jets yet */
};

static jet_fn_t hot_lookup(noun label) {
    if (!noun_is_direct(label)) return NULL;
    uint64_t cord = direct_val(label);
    for (int i = 0; hot_state[i].fn != NULL; i++) {
        if (hot_state[i].label_cord == cord)
            return hot_state[i].fn;
    }
    return NULL;
}

/* ── Hax  (#[axis val target]) ──────────────────────────────────────────── */

/*
 * Tree edit: replace the noun at axis `a` within `target` with `new_val`.
 * Mirrors the slot path traversal but rebuilds cells on the way back up.
 *
 *   #[1 v t]     = v
 *   #[2 v [h t]] = [v t]
 *   #[3 v [h t]] = [h v]
 *   #[2k v t]    = #[k/even-step …]  (recurse into head subtree)
 *   #[2k+1 v t]  = #[k/odd-step …]   (recurse into tail subtree)
 */
static noun hax(uint64_t a, noun new_val, noun target) {
    if (a == 0)
        nock_crash("edit axis 0");
    if (a == 1)
        return new_val;
    if (!noun_is_cell(target))
        nock_crash("edit in atom");

    cell_t *t = (cell_t *)(uintptr_t)cell_ptr(target);

    /* depth = floor(log2(a)); first path bit selects head(0) vs tail(1) */
    int d = 0;
    uint64_t tmp = a;
    while (tmp > 1) { tmp >>= 1; d++; }

    int first = (int)((a >> (d - 1)) & 1);

    /* sub-axis within the chosen child: strip the leading 1-bit and the
     * first path bit, then re-attach the sentinel 1-bit. */
    uint64_t sub = (a & ((1ULL << (d - 1)) - 1)) | (1ULL << (d - 1));

    if (first == 0)
        return alloc_cell(hax(sub, new_val, t->head), t->tail);
    else
        return alloc_cell(t->head, hax(sub, new_val, t->tail));
}

/* ── Slot  (/[axis subject]) ─────────────────────────────────────────────── */

/*
 * Axis encodes a path through the binary tree.  The leading 1-bit is a
 * sentinel; the remaining bits, read MSB-first, form the path:  0 = head,
 * 1 = tail.
 *
 *   axis 1      → root (whole subject)
 *   axis 2      → head           (path: 0)
 *   axis 3      → tail           (path: 1)
 *   axis 4      → head of head   (path: 0 0)
 *   axis 5      → tail of head   (path: 0 1)
 *   axis 6      → head of tail   (path: 1 0)
 *   axis 7      → tail of tail   (path: 1 1)
 */
noun slot(noun axis, noun subject) {
    if (!noun_is_direct(axis))
        nock_crash("slot axis not direct");

    uint64_t a = direct_val(axis);
    if (a == 0)
        nock_crash("slot axis 0");

    /* find depth = floor(log2(a)) — the number of path bits */
    int depth = 0;
    uint64_t tmp = a;
    while (tmp > 1) { tmp >>= 1; depth++; }

    /* follow path bits from bit (depth-1) down to bit 0 */
    for (int i = depth - 1; i >= 0; i--) {
        if (!noun_is_cell(subject))
            nock_crash("slot in atom");
        cell_t *c = (cell_t *)(uintptr_t)cell_ptr(subject);
        if ((a >> i) & 1)
            subject = c->tail;
        else
            subject = c->head;
    }
    return subject;
}

/* ── Nock eval ───────────────────────────────────────────────────────────── */

/*
 * Internal evaluator.  All recursive calls go through here so that
 * `jets` and `sky` are threaded through the entire computation.
 *
 * `wild_buf` holds at most one %wild registration set per stack frame.
 * When op 11 fires a %wild hint, we parse the clue into `wild_buf` and
 * update `jets` to point to it.  Because `goto loop` keeps us in the
 * same frame, `wild_buf` stays live until the frame returns.
 */
static noun nock_eval(noun subject, noun formula,
                      const wilt_t *jets, sky_fn_t sky) {
    wilt_t wild_buf;    /* local %wild registration buffer */
loop:
    if (!noun_is_cell(formula))
        nock_crash("nock atom");

    cell_t *f = (cell_t *)(uintptr_t)cell_ptr(formula);
    noun head = f->head;
    noun tail = f->tail;

    /* ── Distribution rule: *[a [b c] d] = [*[a b c] *[a d]] ── */
    if (noun_is_cell(head)) {
        noun left  = nock_eval(subject, head, jets, sky);
        noun right = nock_eval(subject, tail, jets, sky);
        return alloc_cell(left, right);
    }

    /* head is an atom — it's the opcode */
    if (!noun_is_direct(head))
        nock_crash("opcode not direct");
    uint64_t op = direct_val(head);

    switch (op) {

    /* ── 0  *[a 0 b]  =  /[b a]  ── */
    case 0:
        return slot(tail, subject);

    /* ── 1  *[a 1 b]  =  b  ── */
    case 1:
        return tail;

    /* ── 2  *[a 2 b c]  =  *[*[a b] *[a c]]  (TCO: loop) ── */
    case 2: {
        if (!noun_is_cell(tail))
            nock_crash("op2 tail not cell");
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun new_subj = nock_eval(subject, args->head, jets, sky);
        noun new_form = nock_eval(subject, args->tail, jets, sky);
        subject = new_subj;
        formula = new_form;
        goto loop;
    }

    /* ── 3  *[a 3 b]  =  ?*[a b]  (wut: 0=cell, 1=atom) ── */
    case 3: {
        noun r = nock_eval(subject, tail, jets, sky);
        return noun_is_cell(r) ? NOUN_YES : NOUN_NO;
    }

    /* ── 4  *[a 4 b]  =  +*[a b]  (lus: increment atom) ── */
    case 4: {
        noun r = nock_eval(subject, tail, jets, sky);
        if (!noun_is_direct(r))
            nock_crash("op4 increment non-direct (bignum NYI)");
        return direct(direct_val(r) + 1);
    }

    /* ── 5  *[a 5 b c]  =  =[*[a b] *[a c]]  (tis: 0=equal, 1=not) ── */
    case 5: {
        if (!noun_is_cell(tail))
            nock_crash("op5 tail not cell");
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun left  = nock_eval(subject, args->head, jets, sky);
        noun right = nock_eval(subject, args->tail, jets, sky);
        return noun_eq(left, right) ? NOUN_YES : NOUN_NO;
    }

    /* ── 9  *[a 9 b c]  =  *[*[a c] 0 b]  (arm invocation, TCO) ──
     *
     * Evaluate c against subject to get a core, pull the arm formula
     * at axis b, then evaluate that arm with the core as its own subject.
     * This is every function call in Hoon.
     *
     * Before falling through to Nock eval, check the active %wild
     * registrations: if any sock matches the core, dispatch to the jet.
     */
    case 9: {
        if (!noun_is_cell(tail))
            nock_crash("op9 tail not cell");
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun b    = args->head;
        noun core = nock_eval(subject, args->tail, jets, sky);
        noun arm  = slot(b, core);

        /* ── Jet dispatch ── */
        if (jets != NULL) {
            for (int i = 0; i < jets->len; i++) {
                if (sock_match(jets->e[i].sock.cape,
                               jets->e[i].sock.data, core)) {
                    jet_fn_t fn = hot_lookup(jets->e[i].label);
                    if (fn != NULL)
                        return fn(core, jets, sky);
                }
            }
        }

        subject = core;
        formula = arm;
        goto loop;                      /* TCO */
    }

    /* ── 6  *[a 6 b c d]  =  if *[a b] then *[a c] else *[a d]  (TCO) ── */
    case 6: {
        if (!noun_is_cell(tail))
            nock_crash("op6 tail not cell");
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun b = args->head;                    /* condition formula */
        if (!noun_is_cell(args->tail))
            nock_crash("op6 missing branches");
        cell_t *branches = (cell_t *)(uintptr_t)cell_ptr(args->tail);
        noun cond = nock_eval(subject, b, jets, sky);
        if (noun_eq(cond, NOUN_YES)) {
            formula = branches->head;           /* then-branch c */
            goto loop;
        } else if (noun_eq(cond, NOUN_NO)) {
            formula = branches->tail;           /* else-branch d */
            goto loop;
        } else {
            nock_crash("op6 condition not 0 or 1");
            return NOUN_ZERO;
        }
    }

    /* ── 7  *[a 7 b c]  =  *[*[a b] c]  (compose, TCO) ── */
    case 7: {
        if (!noun_is_cell(tail))
            nock_crash("op7 tail not cell");
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        subject = nock_eval(subject, args->head, jets, sky);
        formula = args->tail;
        goto loop;
    }

    /* ── 8  *[a 8 b c]  =  *[[*[a b] a] c]  (pin, TCO) ── */
    case 8: {
        if (!noun_is_cell(tail))
            nock_crash("op8 tail not cell");
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun pinned = nock_eval(subject, args->head, jets, sky);
        subject = alloc_cell(pinned, subject);  /* [*[a b] a] */
        formula = args->tail;
        goto loop;
    }

    /* ── 10  tree edit / hint ─────────────────────────────────────────────
     *
     *  *[a 10 [b c] d]  =  #[b *[a c] *[a d]]   (tree edit)
     *  *[a 10 b c]      =  *[a c]                 (static hint, ignore b)
     */
    case 10: {
        if (!noun_is_cell(tail))
            nock_crash("op10 tail not cell");
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun hint = args->head;
        noun d    = args->tail;

        if (noun_is_cell(hint)) {
            cell_t *hc = (cell_t *)(uintptr_t)cell_ptr(hint);
            noun b = hc->head;
            if (!noun_is_direct(b))
                nock_crash("op10 edit axis not direct");
            noun val    = nock_eval(subject, hc->tail, jets, sky);
            noun target = nock_eval(subject, d, jets, sky);
            return hax(direct_val(b), val, target);
        } else {
            formula = d;
            goto loop;
        }
    }

    /* ── 11  hint ──────────────────────────────────────────────────────────
     *
     *  *[a 11 b c]       =  *[a c]                (static hint, b is atom)
     *  *[a 11 [b c] d]   =  hint fires, then *[a d]  (dynamic hint)
     *
     * Supported dynamic hint tags:
     *   %wild  — parse $wilt clue, scope jet registrations into *[a d]
     *   %slog  — print clue noun to UART (bare-metal printf)
     *   %xray  — print clue noun tree to UART (noun inspector)
     *   %mean  — stub (stack trace, Phase 7)
     *   %memo  — stub (memoization, Phase 5)
     *   %bout  — stub (timing, future)
     *   other  — silent no-op
     */
    case 11: {
        if (!noun_is_cell(tail))
            nock_crash("op11 tail not cell");
        cell_t *args = (cell_t *)(uintptr_t)cell_ptr(tail);
        noun hint = args->head;
        noun d    = args->tail;

        if (!noun_is_cell(hint)) {
            /* Static hint: atom tag, no clue evaluation — just eval d */
            formula = d;
            goto loop;
        }

        /* Dynamic hint: hint = [b c] */
        cell_t *hc  = (cell_t *)(uintptr_t)cell_ptr(hint);
        noun b      = hc->head;     /* hint tag */
        noun c      = hc->tail;     /* clue formula */

        if (!noun_is_direct(b))
            nock_crash("op11 hint tag not direct");
        uint64_t tag = direct_val(b);

        /* Evaluate clue (for side effects and/or %wild registration) */
        noun clue = nock_eval(subject, c, jets, sky);

        switch (tag) {

        case HINT_WILD:
            /* Parse $wilt clue into wild_buf; scope registrations into d */
            parse_wilt(clue, &wild_buf);
            jets = &wild_buf;
            break;

        case HINT_SLOG:
            uart_puts("\r\nslog: ");
            noun_print(clue, 0);
            uart_puts("\r\n");
            break;

        case HINT_XRAY:
            uart_puts("\r\nxray: ");
            noun_print(clue, 0);
            uart_puts("\r\n");
            break;

        case HINT_MEAN:
        case HINT_MEMO:
        case HINT_BOUT:
        default:
            /* stub / no-op */
            (void)clue;
            break;
        }

        formula = d;
        goto loop;
    }

    default:
        nock_crash("unimplemented opcode");
        return NOUN_ZERO; /* unreachable */
    }
}

/* ── Public API ──────────────────────────────────────────────────────────── */

noun nock(noun subject, noun formula) {
    return nock_eval(subject, formula, NULL, NULL);
}

noun nock_ex(noun subject, noun formula, const wilt_t *jets, sky_fn_t sky) {
    return nock_eval(subject, formula, jets, sky);
}
