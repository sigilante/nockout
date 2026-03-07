#pragma once
#include <stdint.h>

/*
 * Minimal setjmp/longjmp for bare-metal AArch64 (-mgeneral-regs-only).
 *
 * jmp_buf layout (13 × 8 = 104 bytes):
 *   [0..9]   x19–x28  (callee-saved, includes Forth VM regs x24–x27)
 *   [10]     x29      (frame pointer)
 *   [11]     x30      (link register — return address)
 *   [12]     sp
 */
typedef uint64_t jmp_buf[13];

int  setjmp(jmp_buf env);
__attribute__((noreturn)) void longjmp(jmp_buf env, int val);
