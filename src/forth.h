#pragma once
#include <stdint.h>
#include "noun.h"

/*
 * C-callable exports from the Forth kernel (src/forth.s).
 *
 * All of these are pure assembly; no C translation unit required.
 * The dictionary entry type is an opaque struct pointer — callers
 * only ever pass it back to forth_call_jet or inspect offset 16
 * (name field) for display purposes.
 */

/* Opaque dictionary entry type — layout is internal to forth.s.
 * Forward declaration here; ska.h also forward-declares it. */
#ifndef DICT_ENTRY_DEFINED
#define DICT_ENTRY_DEFINED
typedef struct dict_entry dict_entry_t;
#endif

/* Search the Forth dictionary by label cord.
 * A cord is a LE-packed ASCII string; the dictionary name field stores
 * the same encoding, so comparison is a single 64-bit integer test.
 * Returns the entry pointer, or NULL if not found / F_HIDDEN. */
extern dict_entry_t *find_by_cord(uint64_t cord);

/* Return the current head of the Forth dictionary chain (LATEST).
 * Use before/after forth_eval_string to identify newly-compiled words. */
extern dict_entry_t *dict_get_latest(void);

/* Return the name cord of a dictionary entry (offset 16, 8-byte LE).
 * Useful for printing jet names in the SKA dashboard. */
static inline uint64_t dict_entry_name(const dict_entry_t *e) {
    return *(const uint64_t *)((const uint8_t *)e + 16);
}

/* Call a Forth dictionary word as a Nock jet.
 * Pushes core onto the Forth data stack, dispatches to the word's
 * codeword via the jet trampoline, pops and returns the result.
 * Saves and restores all C callee-saved and Forth machine registers. */
extern noun forth_call_jet(dict_entry_t *entry, noun core);

/* forth_eval_string: C-callable Forth text evaluator (Stage 9e).
 * Compiles/executes src[0..len) as Forth source in the current dictionary.
 * Returns 0 on success, -1 on parse error (setjmp-guarded). */
extern int forth_eval_string(const char *src, size_t len);

/* Entry point — called from main.c; never returns. */
extern void forth_main(void);
