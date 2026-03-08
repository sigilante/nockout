#pragma once
#include "noun.h"

/*
 * Noun serialization: jam / cue  (Phase 5a)
 *
 * jam: noun → atom   (bitstream encoding with back-reference deduplication)
 * cue: atom → noun   (inverse: decode bitstream back to noun)
 *
 * Encoding overview:
 *   Atom:       tag=0,  followed by mat(atom)
 *   Cell:       tag=01, followed by jam(head) jam(tail)
 *   Back-ref:   tag=11, followed by mat(bit-cursor of earlier occurrence)
 *
 * mat/rub: self-describing integer encoding.
 *   mat(0) = [len=1, bits=1]
 *   mat(k) = [len=2b+a, bits=(b zeros)(1)(b-1 low bits of a)(a bits of k)]
 *     where a = bn_met(k), b = bit_length(a)
 */

noun jam(noun n);   /* noun  → serialized atom              */
noun cue(noun a);   /* atom  → deserialized noun            */
