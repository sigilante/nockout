#pragma once
/*
 * ska.h — Subject Knowledge Analysis (Phase 7)
 *
 * Ports the core types of dozreg-toplud/ska (skan.hoon / noir.hoon / sock.hoon)
 * to C.  The scan pass produces a `nomm_t` annotated AST; the cook pass resolves
 * cross-arm references and produces `nomm1_t`, which `run_nomm1()` interprets
 * directly with O(1) jet dispatch at `%ds2` sites.
 *
 * Reference: skan.hoon:1..2300, noir.hoon, sock.hoon (dozreg-toplud/ska)
 * Paper: Afonin ~dozreg-toplud, "Subject Knowledge Analysis", UTJ Vol. 3 Issue 1
 */

#include "noun.h"
#include "nock.h"
#include <stdint.h>
#include <stdbool.h>

/* ── cape_t — boolean subject-knowledge tree ─────────────────────────────────
 *
 * Maps directly to Hoon $cape:  +$  cape  $@(? [cape cape])
 *   CAPE_KNOWN (atom &, 0) — this subtree of the subject is fully known
 *   CAPE_WILD  (atom |, 1) — this subtree is a wildcard (may be anything)
 *   ptr to cape_cell_t     — cell: separate knowledge for head and tail
 *
 * We encode this as a tagged noun so it can live on the noun heap and be
 * equality-tested cheaply.  We use direct-atom nouns for KNOWN and WILD and
 * cell nouns `[head_cape tail_cape]` for the tree case — i.e. a cape IS a noun.
 */
#define CAPE_KNOWN  NOUN_YES   /* & — 0 as direct atom */
#define CAPE_WILD   NOUN_NO    /* | — 1 as direct atom */

typedef noun cape_t;           /* noun whose value is a $cape tree */

/* ── sock_t — partial noun (cape + data) ─────────────────────────────────────
 *
 * Maps to Hoon $sock:  +$  sock  [=cape data=*]
 * Already defined in nock.h as:  typedef struct { noun cape; noun data; } sock_t;
 * Where cape=KNOWN, data is authoritative.  Where cape=WILD, data is ignored.
 * SKA uses the same type directly.
 */

/* ── site_t — evalsite identifier ────────────────────────────────────────────
 * Unique ID for a Nock-2 call site within the analysis.
 * arm  = index of the arm being analysed (0 = entry arm)
 * site = monotone counter within that arm
 */
typedef struct {
    uint32_t arm;
    uint32_t site;
} site_t;

/* ── glob_t — call label (memo index or arm+site) ───────────────────────────
 * Maps to Hoon $glob:  +$  glob  $%([%memo p=@] [%site p=site])
 */
typedef enum { GLOB_MEMO, GLOB_SITE } glob_kind_t;
typedef struct {
    glob_kind_t kind;
    union {
        uint32_t memo_idx;
        site_t   site;
    };
} glob_t;

/* ── bell_t — call site identity (subject template + formula) ────────────────
 * Maps to Hoon $bell:  +$  bell  [bus=sock fol=*]
 * Stored at `%ds2` / `%dus2` annotated call sites in the final nomm1 AST.
 */
typedef struct {
    sock_t  bus;   /* expected subject shape at this call site */
    noun    fol;   /* formula to be called */
} bell_t;

/* ── nomm_t — annotated Nock AST produced by scan pass ──────────────────────
 *
 * All opcodes are structurally identical to Nock except Nock-2, which is
 * split into three variants based on how much we know at analysis time:
 *
 *   NOMM_I2   — indirect: formula not known; fallback to nock_eval()
 *   NOMM_DS2  — direct safe: formula is %0 or %1; no eval needed for formula
 *   NOMM_DUS2 — direct unsafe: formula known but complex; eval once then cache
 *
 * After the cook pass, all NOMM_DS2/NOMM_DUS2 carry a resolved bell_t and an
 * optional jet pointer.
 */
typedef enum {
    NOMM_0,    /* slot      — [0 ax]                          */
    NOMM_1,    /* quote     — [1 val]                         */
    NOMM_2,    /* eval      — only in nomm1; see i2/ds2/dus2  */
    NOMM_3,    /* cell?     — [3 p]                           */
    NOMM_4,    /* inc       — [4 p]                           */
    NOMM_5,    /* eq?       — [5 p q]                         */
    NOMM_6,    /* if        — [6 c y n]                       */
    NOMM_7,    /* compose   — [7 p q]                         */
    NOMM_8,    /* push      — [8 p q]                         */
    NOMM_9,    /* invoke    — [9 ax core_fol]                 */
    NOMM_10,   /* hax/edit  — [10 [ax val_fol] tgt_fol]       */
    NOMM_11,   /* hint      — [11 {tag clue?} main_fol]       */
    NOMM_12,   /* scry      — [12 [ref_fol thunk_fol]]        */
    NOMM_DIST, /* autocons  — [[p_fol] q_fol]                 */
    NOMM_I2,   /* indirect call — neither sub nor fol known   */
    NOMM_DS2,  /* direct-safe   — formula is %0 or %1 literal */
    NOMM_DUS2, /* direct-unsafe — formula statically known    */
} nomm_tag_t;

/* Forward declaration for recursive type. */
typedef struct nomm_s nomm_t;

struct nomm_s {
    nomm_tag_t tag;
    union {
        /* NOMM_0: slot */
        struct { noun ax; } n0;
        /* NOMM_1: quote */
        struct { noun val; } n1;
        /* NOMM_3, NOMM_4: unary sub-formula */
        struct { nomm_t *p; } n_unary;
        /* NOMM_5: equality [5 p q] — two independent sub-formulas */
        struct { nomm_t *p; nomm_t *q; } n5;
        /* NOMM_6: if-then-else */
        struct { nomm_t *c; nomm_t *y; nomm_t *n; } n6;
        /* NOMM_7: compose [7 p q] — q evaluated on p's product */
        struct { nomm_t *p; nomm_t *q; } n7;
        /* NOMM_8: push [8 p q] — q evaluated on [*[a p] a] */
        struct { nomm_t *p; nomm_t *q; } n8;
        /* NOMM_9: arm invoke [9 ax core_fol] */
        struct { noun ax; nomm_t *core_fol; } n9;
        /* NOMM_10: hax tree-edit [10 [ax val_fol] tgt_fol] */
        struct { noun ax; nomm_t *val_fol; nomm_t *tgt_fol; } n10;
        /* NOMM_11: hint — static ([11 tag main]) or dynamic ([11 [tag clue] main]) */
        struct { noun tag; nomm_t *clue; nomm_t *main; bool is_dyn; } n11;
        /* NOMM_12: scry [12 [ref_fol thunk_fol]] */
        struct { nomm_t *ref_fol; nomm_t *thunk_fol; } n12;
        /* NOMM_DIST: autocons [[p_fol] q_fol] — head and tail are separate formulas */
        struct { nomm_t *p; nomm_t *q; } ndist;
        /* NOMM_I2: indirect call — subject and formula both dynamic */
        struct { nomm_t *p; nomm_t *q; } i2;
        /* NOMM_DS2: direct safe — formula is %0 or %1 literal */
        struct { nomm_t *p; glob_t glob; } ds2;
        /* NOMM_DUS2: direct unsafe — formula statically known but complex */
        struct { nomm_t *p; nomm_t *q; glob_t glob; } dus2;
    };
    /* Scan-pass annotation: evaluator's knowledge of the product noun. */
    sock_t prod;
};

/* ── nomm1_t — final annotated AST after cook pass ──────────────────────────
 * Like nomm_t but all Nock-2 sites carry an optional bell_t + jet pointer.
 * NOMM_DS2 and NOMM_DUS2 from the nomm are both collapsed to NOMM_2 here;
 * the distinction lives in whether bell is set and whether jet is non-NULL.
 */
typedef struct nomm1_s nomm1_t;
struct nomm1_s {
    nomm_tag_t tag;
    union {
        struct { noun ax; } n0;
        struct { noun val; } n1;
        struct { nomm1_t *p; } n_unary;
        struct { nomm1_t *p; nomm1_t *q; } n5;
        struct { nomm1_t *c; nomm1_t *y; nomm1_t *n; } n6;
        struct { nomm1_t *p; nomm1_t *q; } n7;
        struct { nomm1_t *p; nomm1_t *q; } n8;
        struct { noun ax; nomm1_t *core_fol; } n9;
        struct { noun ax; nomm1_t *val_fol; nomm1_t *tgt_fol; } n10;
        struct { noun tag; nomm1_t *clue; nomm1_t *main; bool is_dyn; } n11;
        struct { nomm1_t *ref_fol; nomm1_t *thunk_fol; } n12;
        struct { nomm1_t *p; nomm1_t *q; } ndist;
        /* NOMM_2: unified call site (was i2 / ds2 / dus2 before cook) */
        struct {
            nomm1_t  *p;            /* subject formula */
            nomm1_t  *q;            /* formula formula (NULL for direct-safe) */
            bool      has_bell;     /* true if bell is valid */
            bell_t    bell;         /* subject template + formula for matching */
            jet_fn_t  jet;          /* non-NULL if a hot jet matched, else NULL */
        } n2;
    };
    sock_t prod;
};

/* ── frond_t — one loop assumption (parent-kid pair) ─────────────────────────
 * When the loop heuristic fires, we record the parent and child eval sites
 * involved.  After the cycle exits, all fronds are validated; if any fail,
 * the pair is added to block_loop and the arm is re-analysed.
 */
typedef struct {
    site_t par;       /* site guessed as the loop head     */
    site_t kid;       /* site that triggered the guess      */
    sock_t par_sub;   /* subject sock at the parent site    */
    sock_t kid_sub;   /* full subject sock at the child     */
    cape_t kid_tak;   /* part of subject the kid uses as code */
} frond_t;

#define SKA_MAX_FRONDS  64

/* ── cycle_t — one SCC (strongly connected component) ───────────────────────
 * Maps to Hoon $cycle in skan.hoon.
 * Tracks a set of mutually recursive eval sites while they are being analysed.
 */
#define SKA_MAX_CYCLE_SITES 32
typedef struct {
    site_t   entry;                        /* cycle head (smallest site ID)   */
    site_t   latch;                        /* most recently added loopy site  */
    int      nfronds;
    frond_t  fronds[SKA_MAX_FRONDS];
    int      nsites;
    site_t   sites[SKA_MAX_CYCLE_SITES];   /* all sites in the cycle          */
    /* melo cache: within-cycle memoisation (keyed by formula noun + sub sock) */
    int      nmelo;
    struct { noun fol; sock_t sub; site_t site; } melo[SKA_MAX_CYCLE_SITES];
} cycle_t;

/* ── site_info_t — per-evalsite record (stored in short_t / long_t) ─────────
 * After an evalsite is finalised, we store what the scan produced so that
 * the cook pass can resolve cross-arm references.
 */
typedef struct {
    site_t   id;
    sock_t   sub;      /* subject sock at entry        */
    noun     fol;      /* formula noun                 */
    nomm_t  *nomm;     /* annotated AST (scan output)  */
    sock_t   prod;     /* product sock (scan output)   */
    cape_t   want;     /* which axes used as code      */
} site_info_t;

/* ── memo_entry_t — cross-arm memoisation record ─────────────────────────────
 * Maps to `long.memo` in skan.hoon.  Caches the analysis of a (formula, sock)
 * pair so that re-analysis of the same arm from a different context can reuse
 * the result if the subsumption check passes.
 */
typedef struct {
    uint32_t     idx;       /* monotone memo index (used as glob MEMO id)  */
    noun         fol;       /* formula noun                                 */
    sock_t       less_memo; /* minimal subject sock that produced this memo */
    sock_t       less_code; /* which axes of that sock were used as code    */
    nomm_t      *nomm;      /* annotated AST                               */
    sock_t       prod;      /* product sock                                 */
} memo_entry_t;

#define SKA_MAX_MEMOS   128
#define SKA_MAX_SITES   256
#define SKA_MAX_ARMS    64
#define SKA_MAX_STACK   64   /* max %2 nesting depth for loop detection     */

/* ── arm_info_t — per-arm record ─────────────────────────────────────────────
 * Maps to long.arms (areas, doors, sites) in skan.hoon.
 */
typedef struct {
    uint32_t    arm_idx;
    noun        fol;            /* formula noun for this arm          */
    int         nsites;
    site_info_t sites[SKA_MAX_SITES / SKA_MAX_ARMS];
} arm_info_t;

/* ── short_t — per-arm scan state ────────────────────────────────────────────
 * Maps to Hoon $short in skan.hoon.
 * Owns the mutable state used while scanning one arm.
 */
typedef struct {
    uint32_t     arm_idx;       /* index of this arm in long_t.arms   */
    uint32_t     site_gen;      /* next evalsite ID counter            */

    /* Active loop tracking: a stack of open cycles. */
    int          ncycles;
    cycle_t      cycle_stack[8];

    /* want[i] = cape describing which axes of the subject site i uses as code */
    int          nwant;
    struct { site_t site; cape_t want; } want[SKA_MAX_SITES];

    /* block_loop: pairs known NOT to be loops (frond validation failures). */
    int          nblock;
    struct { site_t par; site_t kid; } block_loop[SKA_MAX_FRONDS];

    /* nope_melo: (fol, sub) pairs known NOT to melo-cache. */
    int          nnope;
    struct { noun fol; sock_t sub; } nope_melo[SKA_MAX_SITES];

    /* fols.stack: formula stack for loop heuristic (current %2 call chain). */
    int          fols_depth;
    struct {
        noun   fol;
        sock_t sub;
        site_t site;
    } fols_stack[SKA_MAX_STACK];

    /* Locals: finalised non-memo sites for this arm. */
    int          nlocals;
    site_info_t  locals[SKA_MAX_SITES];

    /* Reference to global state (not owned). */
    struct long_s *lon;
} short_t;

/* ── long_t — global cross-arm analysis state ────────────────────────────────
 * Maps to Hoon $long in skan.hoon.
 * Shared across all arms; owns memo cache and per-arm results.
 */
typedef struct long_s {
    uint32_t     arm_gen;       /* next arm index                     */
    uint32_t     memo_gen;      /* next memo index                    */

    int          nmemos;
    memo_entry_t memos[SKA_MAX_MEMOS];

    int          narms;
    arm_info_t   arms[SKA_MAX_ARMS];
} long_t;

/* ── boil_t — cook pass output ───────────────────────────────────────────────
 * The cook pass walks long_t and produces boil_t: a map from (arm, site) to
 * nomm1_t, ready for run_nomm1() to execute.
 */
typedef struct {
    long_t  *lon;               /* back-reference to source analysis  */
    nomm1_t *entry;             /* nomm1 for the entry arm's formula  */
    /* Flat array of all resolved sites; indexed by arm_info_t position. */
    int      nsites;
    struct { site_t id; nomm1_t *nomm1; } sites[SKA_MAX_SITES];
} boil_t;

/* ── Public API ──────────────────────────────────────────────────────────────
 *
 * ska_nock(subject, formula, jets, sky) → noun
 *   Analyze (subject, formula) with the scan pass, then evaluate the
 *   resulting nomm_t AST.  Gives identical answers to nock_eval() but with
 *   jet dispatch at statically-identified call sites.
 *   This is the primary entry point for all SKA-evaluated Nock.
 *
 * ska_analyze(subject, formula, jets, sky) → boil_t*
 *   Run scan + cook passes only (no evaluation).
 *   Returns NULL on hard failure (e.g., allocation exhaustion).
 *
 * run_nomm1(nomm1, subject, jets, sky) → noun
 *   Interpret a cooked nomm1 AST.  Dispatches jets at annotated %2 sites.
 *   Falls back to nock_eval() at unannotated (indirect) %2 sites.
 */
noun    ska_nock(noun subject, noun formula,
                 const wilt_t *jets, sky_fn_t sky);

boil_t *ska_analyze(noun subject, noun formula,
                    const wilt_t *jets, sky_fn_t sky);

noun    run_nomm1(const nomm1_t *n, noun subject,
                  const wilt_t *jets, sky_fn_t sky);

/* Reclaim all nomm_t / nomm1_t / boil_t arena allocations. */
void  ska_arena_reset(void);
