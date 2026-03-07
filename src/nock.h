#pragma once
#include "noun.h"

/*
 * Nock 4K evaluator — Phase 3b.
 *
 * nock(subject, formula)            → product  (crashes on error)
 * nock_ex(subject, formula, j, sky) → product  (full API)
 * slot(axis, subject)               → noun     (Nock / operator)
 *
 * Crash behaviour: nock_crash() prints to UART and halts the CPU.
 * longjmp recovery (back to QUIT) is deferred to Phase 3c.
 */

/* ── Scry handler (Nock 12) ────────────────────────────────────────────── */
/* Returns the scry result or crashes.  NULL = crash on any op 12.         */
typedef noun (*sky_fn_t)(noun path);

/* ── Sock: noun template for jet matching (%wild / SKA) ─────────────────── */
/*
 * cape: & (NOUN_YES = 0) → positions in `data` must match subject exactly
 *        | (NOUN_NO  = 1) → wildcard, any noun matches
 *        cell             → recurse into head/tail
 */
typedef struct { noun cape; noun data; } sock_t;

/* ── Wilt: scoped %wild registration list ────────────────────────────────── */
/* Lives on the C stack, scoped to the hinted computation.                  */
#define WILT_MAX 16
typedef struct { noun label; sock_t sock; } wilt_entry_t;
typedef struct { int len; wilt_entry_t e[WILT_MAX]; } wilt_t;

/* ── Jet function type ────────────────────────────────────────────────────── */
typedef noun (*jet_fn_t)(noun core, const wilt_t *jets, sky_fn_t sky);

/* ── Crash recovery ──────────────────────────────────────────────────────── */
/* QUIT's restart path calls setjmp(nock_abort) to establish the recovery    */
/* point.  nock_crash() calls longjmp(nock_abort,1) to unwind back to it.   */
#include "setjmp.h"
extern jmp_buf nock_abort;

/* ── Public API ──────────────────────────────────────────────────────────── */
noun nock(noun subject, noun formula);
noun nock_ex(noun subject, noun formula, const wilt_t *jets, sky_fn_t sky);
noun slot(noun axis, noun subject);
