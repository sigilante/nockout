// src/setjmp.s — bare-metal AArch64 setjmp/longjmp
// No FP registers (-mgeneral-regs-only).
//
// jmp_buf layout (uint64_t[13]):
//   offset  0: x19   offset  8: x20
//   offset 16: x21   offset 24: x22
//   offset 32: x23   offset 40: x24
//   offset 48: x25   offset 56: x26
//   offset 64: x27   offset 72: x28
//   offset 80: x29   offset 88: x30
//   offset 96: sp

    .text
    .balign 4

// int setjmp(jmp_buf env)   — save context, return 0
    .global setjmp
setjmp:
    stp     x19, x20, [x0, #0]
    stp     x21, x22, [x0, #16]
    stp     x23, x24, [x0, #32]
    stp     x25, x26, [x0, #48]
    stp     x27, x28, [x0, #64]
    stp     x29, x30, [x0, #80]
    mov     x1, sp
    str     x1,       [x0, #96]
    mov     x0, #0
    ret

// void longjmp(jmp_buf env, int val)   — restore context, return val (min 1)
    .global longjmp
longjmp:
    ldp     x19, x20, [x0, #0]
    ldp     x21, x22, [x0, #16]
    ldp     x23, x24, [x0, #32]
    ldp     x25, x26, [x0, #48]
    ldp     x27, x28, [x0, #64]
    ldp     x29, x30, [x0, #80]
    ldr     x2,       [x0, #96]
    mov     sp, x2
    // Return val: if val==0 return 1, otherwise return val
    cmp     w1, #0
    csinc   x0, x1, xzr, ne
    ret
