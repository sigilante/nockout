#pragma once
#include <stdint.h>
#include <stddef.h>

/*
 * BLAKE3 hash function — bare-metal implementation.
 *
 * Spec: https://github.com/BLAKE3-team/BLAKE3-specs/blob/master/blake3.pdf
 * Block: 64 bytes.  Chunk: 1024 bytes.  Output: 32 bytes (256 bits).
 * G-function rotations: 16, 12, 8, 7 (32-bit words).  7 rounds per block.
 * IV: SHA-256 initial hash values (first 8 primes, fractional parts).
 * Merkle tree: subtree-stack algorithm; ROOT flag on final compress call.
 *
 * This implementation has no libc dependency (no memcpy/memset).
 */

/* Compute the BLAKE3 hash of `inlen` bytes at `input`.
   Writes exactly 32 bytes to `out`. */
void blake3_hash(const uint8_t *input, size_t inlen, uint8_t out[32]);

/* Run the official BLAKE3 test vectors (input[i] = i % 251, lengths 0, 1,
   63, 64, 65, 1024, 1025).  Returns 1 if all pass, 0 on any mismatch. */
int blake3_selftest(void);
