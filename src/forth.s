// src/forth.s
// Fock Forth Kernel — AArch64 bare metal
// Phase 1: Inner interpreter + primitives + QUIT loop
//
// ── Register assignments ─────────────────────────────────────────────────────
//   x27  IP  — Instruction Pointer: next cell to fetch from word list
//   x26  DSP — Data Stack Pointer: points TO top item, grows DOWN
//   x25  RSP — Return Stack Pointer: points TO top item, grows DOWN
//   x24  W   — Working register: current dictionary entry address
//
//   x0-x18   — scratch, any word may clobber
//   x19-x23  — reserved for noun heap pointers (Phase 2+)
//   x24-x27  — RESERVED, never clobber
//
// Stack convention: DSP/RSP point TO the top item.
//   Push: str x0, [DSP, #-8]!     (pre-decrement then store)
//   Pop:  ldr x0, [DSP], #8       (load then post-increment)
//
// ── Dictionary entry layout ──────────────────────────────────────────────────
//   offset  0 : link      [8 bytes] — address of previous entry (0 = end)
//   offset  8 : flags|len [8 bytes] — low byte = name length, high bits = flags
//   offset 16 : name      [8 bytes] — ASCII name, zero-padded to 8 bytes
//   offset 24 : codeword  [8 bytes] — pointer to machine code
//   offset 32 : body               — colon def: list of entry addrs
//                                    DOCON: the constant value
//                                    DOVAR: the variable storage cell
//
// ── Memory map (must match memory.h) ─────────────────────────────────────────

.set DICT_BASE,    0x00090000
.set DSTACK_TOP,   0x00480000
.set RSTACK_TOP,   0x00490000
.set TIB_BASE,     0x0008f000
.set TIB_SIZE,     256

// ── UART (PL011) ─────────────────────────────────────────────────────────────
// RPi 4 / QEMU raspi4b: PL011 at 0xFE201000
.set UART_DR,   0xFE201000
.set UART_FR,   0xFE201018

// ── Register aliases ─────────────────────────────────────────────────────────

IP  .req x27
DSP .req x26
RSP .req x25
W   .req x24

// ── Flag bits ────────────────────────────────────────────────────────────────

.set F_IMMEDIATE, 0x80
.set F_HIDDEN,    0x40

// ═════════════════════════════════════════════════════════════════════════════
// MACROS
// ═════════════════════════════════════════════════════════════════════════════

// NEXT — fetch next word, advance IP, dispatch via codeword.
.macro NEXT
    ldr     W, [IP], #8         // W = *IP (entry addr),  IP += 8
    ldr     x0, [W, #24]        // x0 = codeword at entry+24
    br      x0                  // jump to codeword
.endm

// Link chain — updated by each defword.
.set link, 0

// defword — emit the dictionary header only.
.macro defword name, len, label, flags
    .section .rodata
    .balign 8
    .global word_\label
word_\label:
    .quad   link
    .set    link, word_\label
    .quad   ((\flags) << 8) | (\len)
    .ascii  "\name"
    .balign 8, 0
    // codeword at +24, body at +32
.endm

// defcode — primitive; codeword points to immediately following asm.
.macro defcode name, len, label, flags
    defword "\name", \len, \label, \flags
    .quad   code_\label
    .text
    .balign 4
code_\label:
.endm

// defvar — variable; codeword = DOVAR, body = one storage cell.
.macro defvar name, len, label, flags, initial=0
    defword "\name", \len, \label, \flags
    .quad   DOVAR
    .quad   \initial
.endm

// defconst — constant; codeword = DOCON, body = value.
.macro defconst name, len, label, flags, value
    defword "\name", \len, \label, \flags
    .quad   DOCON
    .quad   \value
.endm

// ═════════════════════════════════════════════════════════════════════════════
// INNER INTERPRETER
// ═════════════════════════════════════════════════════════════════════════════

    .text
    .balign 4

// DOCOL — enter a colon definition.
// W holds the entry address. Push IP, set IP = body (W+32), dispatch.
    .global DOCOL
DOCOL:
    str     IP, [RSP, #-8]!
    add     IP, W, #32
    NEXT

// DOCON — push constant value stored at W+32.
    .global DOCON
DOCON:
    ldr     x0, [W, #32]
    str     x0, [DSP, #-8]!
    NEXT

// DOVAR — push address of storage cell at W+32.
    .global DOVAR
DOVAR:
    add     x0, W, #32
    str     x0, [DSP, #-8]!
    NEXT

// EXIT — leave a colon definition. Pop saved IP, resume caller.
defcode "EXIT", 4, exit, 0
    ldr     IP, [RSP], #8
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// STACK PRIMITIVES
// ═════════════════════════════════════════════════════════════════════════════

// DROP ( a -- )
defcode "DROP", 4, drop, 0
    ldr     x0, [DSP], #8
    NEXT

// DUP ( a -- a a )
defcode "DUP", 3, dup, 0
    ldr     x0, [DSP]
    str     x0, [DSP, #-8]!
    NEXT

// SWAP ( a b -- b a )
defcode "SWAP", 4, swap, 0
    ldr     x0, [DSP]
    ldr     x1, [DSP, #8]
    str     x0, [DSP, #8]
    str     x1, [DSP]
    NEXT

// OVER ( a b -- a b a )
defcode "OVER", 4, over, 0
    ldr     x0, [DSP, #8]
    str     x0, [DSP, #-8]!
    NEXT

// ROT ( a b c -- b c a )
// Before: [DSP]=c [DSP+8]=b [DSP+16]=a   After: [DSP]=a [DSP+8]=c [DSP+16]=b
defcode "ROT", 3, rot, 0
    ldr     x0, [DSP]           // x0 = c (top)
    ldr     x1, [DSP, #8]       // x1 = b
    ldr     x2, [DSP, #16]      // x2 = a (deepest)
    str     x2, [DSP]           // a → new top
    str     x0, [DSP, #8]       // c → new middle
    str     x1, [DSP, #16]      // b → new deep
    NEXT

// -ROT ( a b c -- c a b )
// Before: [DSP]=c [DSP+8]=b [DSP+16]=a   After: [DSP]=b [DSP+8]=a [DSP+16]=c
defcode "-ROT", 4, nrot, 0
    ldr     x0, [DSP]           // x0 = c (top)
    ldr     x1, [DSP, #8]       // x1 = b
    ldr     x2, [DSP, #16]      // x2 = a (deepest)
    str     x1, [DSP]           // b → new top
    str     x2, [DSP, #8]       // a → new middle
    str     x0, [DSP, #16]      // c → new deep
    NEXT

// NIP ( a b -- b )
defcode "NIP", 3, nip, 0
    ldr     x0, [DSP], #8
    str     x0, [DSP]
    NEXT

// 2DUP ( a b -- a b a b )
defcode "2DUP", 4, twodup, 0
    ldr     x0, [DSP]
    ldr     x1, [DSP, #8]
    sub     DSP, DSP, #16
    str     x0, [DSP]
    str     x1, [DSP, #8]
    NEXT

// 2DROP ( a b -- )
defcode "2DRP", 4, twodrop, 0
    add     DSP, DSP, #16
    NEXT

// ?DUP ( a -- a a | 0 )
defcode "?DUP", 4, qdup, 0
    ldr     x0, [DSP]
    cbz     x0, 1f
    str     x0, [DSP, #-8]!
1:  NEXT

// DEPTH ( -- n )
defcode "DPTH", 4, depth, 0
    ldr     x0, =DSTACK_TOP
    sub     x0, x0, DSP
    lsr     x0, x0, #3
    str     x0, [DSP, #-8]!
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// ARITHMETIC PRIMITIVES
// ═════════════════════════════════════════════════════════════════════════════

// + ( a b -- a+b )
defcode "+", 1, plus, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    add     x1, x1, x0
    str     x1, [DSP]
    NEXT

// - ( a b -- a-b )
defcode "-", 1, minus, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    sub     x1, x1, x0
    str     x1, [DSP]
    NEXT

// * ( a b -- a*b )
defcode "*", 1, mul, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    mul     x1, x1, x0
    str     x1, [DSP]
    NEXT

// /MOD ( a b -- rem quot )
defcode "/MOD", 4, divmod, 0
    ldr     x0, [DSP], #8       // x0 = b (divisor)
    ldr     x1, [DSP], #8       // x1 = a (dividend)
    sdiv    x2, x1, x0          // x2 = quotient
    msub    x3, x2, x0, x1      // x3 = remainder
    str     x2, [DSP, #-8]!    // push quot (top after swap below)
    str     x3, [DSP, #-8]!    // push rem  (top)
    // Stack is now ( rem quot ) as expected
    NEXT

// / ( a b -- a/b )   truncated quotient
defcode "/", 1, div, 0
    ldr     x0, [DSP], #8       // x0 = b (divisor)
    ldr     x1, [DSP]           // x1 = a (dividend)
    sdiv    x1, x1, x0
    str     x1, [DSP]
    NEXT

// MOD ( a b -- a mod b )   truncated remainder
defcode "MOD", 3, mod, 0
    ldr     x0, [DSP], #8       // x0 = b (divisor)
    ldr     x1, [DSP]           // x1 = a (dividend)
    sdiv    x2, x1, x0          // x2 = quotient
    msub    x1, x2, x0, x1      // x1 = a - (a/b)*b
    str     x1, [DSP]
    NEXT

// NEGATE ( a -- -a )
defcode "NEG", 3, negate, 0
    ldr     x0, [DSP]
    neg     x0, x0
    str     x0, [DSP]
    NEXT

// ABS ( a -- |a| )
defcode "ABS", 3, abs, 0
    ldr     x0, [DSP]
    cmp     x0, #0
    cneg    x0, x0, mi
    str     x0, [DSP]
    NEXT

// 1+ ( a -- a+1 )
defcode "1+", 2, oneplus, 0
    ldr     x0, [DSP]
    add     x0, x0, #1
    str     x0, [DSP]
    NEXT

// 1- ( a -- a-1 )
defcode "1-", 2, oneminus, 0
    ldr     x0, [DSP]
    sub     x0, x0, #1
    str     x0, [DSP]
    NEXT

// 2* ( a -- a<<1 )
defcode "2*", 2, twostar, 0
    ldr     x0, [DSP]
    lsl     x0, x0, #1
    str     x0, [DSP]
    NEXT

// 2/ ( a -- a>>1 ) arithmetic
defcode "2/", 2, twoslash, 0
    ldr     x0, [DSP]
    asr     x0, x0, #1
    str     x0, [DSP]
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// COMPARISON AND LOGIC
// ═════════════════════════════════════════════════════════════════════════════
// Forth boolean: 0 = false, -1 (all bits set) = true.
// CSETM sets all bits on match (gives -1), clears on no match (gives 0).

// = ( a b -- flag )
defcode "=", 1, eq, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    cmp     x0, x1
    csetm   x0, eq
    str     x0, [DSP]
    NEXT

// <> ( a b -- flag )
defcode "<>", 2, neq, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    cmp     x0, x1
    csetm   x0, ne
    str     x0, [DSP]
    NEXT

// < ( a b -- flag ) signed
defcode "<", 1, lt, 0
    ldr     x0, [DSP], #8       // b
    ldr     x1, [DSP]           // a
    cmp     x1, x0              // a < b?
    csetm   x0, lt
    str     x0, [DSP]
    NEXT

// > ( a b -- flag ) signed
defcode ">", 1, gt, 0
    ldr     x0, [DSP], #8       // b
    ldr     x1, [DSP]           // a
    cmp     x1, x0              // a > b?
    csetm   x0, gt
    str     x0, [DSP]
    NEXT

// <= ( a b -- flag )
defcode "<=", 2, le, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    cmp     x1, x0
    csetm   x0, le
    str     x0, [DSP]
    NEXT

// >= ( a b -- flag )
defcode ">=", 2, ge, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    cmp     x1, x0
    csetm   x0, ge
    str     x0, [DSP]
    NEXT

// U< ( a b -- flag ) unsigned
defcode "U<", 2, ult, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    cmp     x1, x0
    csetm   x0, lo
    str     x0, [DSP]
    NEXT

// 0= ( a -- flag )
defcode "0=", 2, zeq, 0
    ldr     x0, [DSP]
    cmp     x0, #0
    csetm   x0, eq
    str     x0, [DSP]
    NEXT

// 0< ( a -- flag )
defcode "0<", 2, zlt, 0
    ldr     x0, [DSP]
    cmp     x0, #0
    csetm   x0, lt
    str     x0, [DSP]
    NEXT

// 0> ( a -- flag )
defcode "0>", 2, zgt, 0
    ldr     x0, [DSP]
    cmp     x0, #0
    csetm   x0, gt
    str     x0, [DSP]
    NEXT

// AND ( a b -- a&b )
defcode "AND", 3, and, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    and     x1, x1, x0
    str     x1, [DSP]
    NEXT

// OR ( a b -- a|b )
defcode "OR", 2, or, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    orr     x1, x1, x0
    str     x1, [DSP]
    NEXT

// XOR ( a b -- a^b )
defcode "XOR", 3, xor, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    eor     x1, x1, x0
    str     x1, [DSP]
    NEXT

// INVERT ( a -- ~a )
defcode "INV", 3, invert, 0
    ldr     x0, [DSP]
    mvn     x0, x0
    str     x0, [DSP]
    NEXT

// LSHIFT ( a n -- a<<n )
defcode "LSH", 3, lshift, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    lsl     x1, x1, x0
    str     x1, [DSP]
    NEXT

// RSHIFT ( a n -- a>>n ) logical
defcode "RSH", 3, rshift, 0
    ldr     x0, [DSP], #8
    ldr     x1, [DSP]
    lsr     x1, x1, x0
    str     x1, [DSP]
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// MEMORY PRIMITIVES
// ═════════════════════════════════════════════════════════════════════════════

// @ ( addr -- val )
defcode "@", 1, fetch, 0
    ldr     x0, [DSP]
    ldr     x0, [x0]
    str     x0, [DSP]
    NEXT

// ! ( val addr -- )
defcode "!", 1, store, 0
    ldr     x0, [DSP], #8       // addr
    ldr     x1, [DSP], #8       // val
    str     x1, [x0]
    NEXT

// +! ( n addr -- )
defcode "+!", 2, plusstore, 0
    ldr     x0, [DSP], #8       // addr
    ldr     x1, [DSP], #8       // n
    ldr     x2, [x0]
    add     x2, x2, x1
    str     x2, [x0]
    NEXT

// C@ ( addr -- char )
defcode "C@", 2, cfetch, 0
    ldr     x0, [DSP]
    ldrb    w0, [x0]
    str     x0, [DSP]
    NEXT

// C! ( char addr -- )
defcode "C!", 2, cstore, 0
    ldr     x0, [DSP], #8       // addr
    ldr     x1, [DSP], #8       // char
    strb    w1, [x0]
    NEXT

// CELL+ ( addr -- addr+8 )
defcode "CEL+", 4, cellplus, 0
    ldr     x0, [DSP]
    add     x0, x0, #8
    str     x0, [DSP]
    NEXT

// CELLS ( n -- n*8 )
defcode "CELL", 4, cells, 0
    ldr     x0, [DSP]
    lsl     x0, x0, #3
    str     x0, [DSP]
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// RETURN STACK PRIMITIVES
// ═════════════════════════════════════════════════════════════════════════════

// >R ( a -- ) R( -- a )
defcode ">R", 2, tor, 0
    ldr     x0, [DSP], #8
    str     x0, [RSP, #-8]!
    NEXT

// R> ( -- a ) R( a -- )
defcode "R>", 2, fromr, 0
    ldr     x0, [RSP], #8
    str     x0, [DSP, #-8]!
    NEXT

// R@ ( -- a ) R( a -- a )
defcode "R@", 2, rfetch, 0
    ldr     x0, [RSP]
    str     x0, [DSP, #-8]!
    NEXT

// RDROP ( -- ) R( a -- )
defcode "RDP", 3, rdrop, 0
    add     RSP, RSP, #8
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// CONTROL FLOW PRIMITIVES
// ═════════════════════════════════════════════════════════════════════════════

// LIT — push the next cell in the word stream as a literal.
// At runtime: IP points past the opcode to the value cell.
defcode "LIT", 3, lit, 0
    ldr     x0, [IP], #8        // value; advance IP past it
    str     x0, [DSP, #-8]!
    NEXT

// BRANCH — unconditional relative branch.
// Cell after BRANCH is a signed byte offset added to IP.
// Offset is relative to the address of the offset cell itself plus 8
// (i.e. to the cell following the offset). So offset 0 means next word.
defcode "BRN", 3, branch, 0
    ldr     x0, [IP]            // load offset
    add     IP, IP, x0          // IP += offset  (IP already past BRN cell)
    NEXT

// 0BRANCH — branch if zero (false).
defcode "0BRN", 4, zbranch, 0
    ldr     x0, [DSP], #8       // pop condition
    cbnz    x0, 1f              // non-zero: don't branch
    ldr     x0, [IP]            // zero: load offset
    add     IP, IP, x0
    NEXT
1:  add     IP, IP, #8          // skip offset cell
    NEXT

// EXECUTE ( xt -- )
defcode "EXEC", 4, execute, 0
    ldr     W, [DSP], #8        // W = execution token (entry address)
    ldr     x0, [W, #24]        // load codeword
    br      x0

// ═════════════════════════════════════════════════════════════════════════════
// I/O PRIMITIVES
// ═════════════════════════════════════════════════════════════════════════════

// KEY ( -- char )
defcode "KEY", 3, key, 0
1:  ldr     x0, =UART_FR
    ldr     w1, [x0]
    tbnz    w1, #4, 1b          // RX FIFO empty: spin
    ldr     x0, =UART_DR
    ldr     w0, [x0]
    and     x0, x0, #0xFF
    str     x0, [DSP, #-8]!
    NEXT

// EMIT ( char -- )
defcode "EMIT", 4, emit, 0
    ldr     x1, [DSP], #8
1:  ldr     x0, =UART_FR
    ldr     w2, [x0]
    tbnz    w2, #5, 1b          // TX FIFO full: spin
    ldr     x0, =UART_DR
    str     w1, [x0]
    NEXT

// CR ( -- )
defcode "CR", 2, cr, 0
1:  ldr     x0, =UART_FR
    ldr     w1, [x0]
    tbnz    w1, #5, 1b
    ldr     x0, =UART_DR
    mov     w1, #13
    str     w1, [x0]
2:  ldr     x0, =UART_FR
    ldr     w1, [x0]
    tbnz    w1, #5, 2b
    ldr     x0, =UART_DR
    mov     w1, #10
    str     w1, [x0]
    NEXT

// SPACE ( -- )
defcode "SPC", 3, space, 0
1:  ldr     x0, =UART_FR
    ldr     w1, [x0]
    tbnz    w1, #5, 1b
    ldr     x0, =UART_DR
    mov     w1, #32
    str     w1, [x0]
    NEXT

// TYPE ( addr len -- )
defcode "TYPE", 4, type, 0
    ldr     x2, [DSP], #8       // len
    ldr     x1, [DSP], #8       // addr
    cbz     x2, 2f
1:  ldrb    w0, [x1], #1
.Ltype_wait:
    ldr     x3, =UART_FR
    ldr     w4, [x3]
    tbnz    w4, #5, .Ltype_wait
    ldr     x3, =UART_DR
    str     w0, [x3]
    subs    x2, x2, #1
    bne     1b
2:  NEXT

// ═════════════════════════════════════════════════════════════════════════════
// SYSTEM VARIABLES AND CONSTANTS
// ═════════════════════════════════════════════════════════════════════════════

defvar "HERE", 4, here,   0, DICT_BASE  // next free dictionary address
defvar "LTST", 4, latest, 0, 0          // most recent entry (set in forth_main)
defvar "STAT", 4, state,  0, 0          // 0=interpret 1=compile
defvar "BASE", 4, base,   0, 10         // number base
defvar ">IN",  3, toin,   0, 0          // offset into TIB
defvar "#TIB", 4, ntib,   0, 0          // valid chars in TIB

defconst "TIB",  3, tib,      0, TIB_BASE
defconst "CEL",  3, cellsize, 0, 8

// ═════════════════════════════════════════════════════════════════════════════
// DICTIONARY OPERATIONS
// ═════════════════════════════════════════════════════════════════════════════

// , ( val -- )   append cell to HERE, advance HERE
defcode ",", 1, comma, 0
    ldr     x0, [DSP], #8               // value to compile
    ldr     x1, =word_here + 32         // address of HERE's storage
    ldr     x1, [x1]                    // current HERE
    str     x0, [x1]                    // store value there
    add     x1, x1, #8
    ldr     x2, =word_here + 32
    str     x1, [x2]                    // update HERE
    NEXT

// C, ( char -- )   append byte to HERE, advance HERE by 1
defcode "C,", 2, ccomma, 0
    ldr     x0, [DSP], #8
    ldr     x1, =word_here + 32
    ldr     x1, [x1]
    strb    w0, [x1]
    add     x1, x1, #1
    ldr     x2, =word_here + 32
    str     x1, [x2]
    NEXT

// ALLOT ( n -- )   advance HERE by n bytes
defcode "ALT", 3, allot, 0
    ldr     x0, [DSP], #8
    ldr     x1, =word_here + 32
    ldr     x2, [x1]
    add     x2, x2, x0
    str     x2, [x1]
    NEXT

// ALIGN ( -- )   align HERE to next 8-byte boundary
defcode "ALN", 3, align, 0
    ldr     x0, =word_here + 32
    ldr     x1, [x0]
    add     x1, x1, #7
    and     x1, x1, #~7
    str     x1, [x0]
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// WORD PARSING
// ═════════════════════════════════════════════════════════════════════════════

// WORD ( delim -- addr len )
// Parse next delim-delimited token from TIB into a scratch buffer at HERE.
// Does NOT advance HERE permanently. Returns addr=HERE and byte count.
defcode "WORD", 4, word, 0
    ldr     x7, [DSP], #8               // x7 = delimiter

    ldr     x0, =word_toin + 32
    ldr     x1, [x0]                    // x1 = >IN
    ldr     x2, =word_ntib + 32
    ldr     x2, [x2]                    // x2 = #TIB
    ldr     x3, =TIB_BASE               // x3 = TIB base

    // Skip leading delimiters
.Lword_skip:
    cmp     x1, x2
    bge     .Lword_empty
    ldrb    w4, [x3, x1]
    cmp     w4, w7
    bne     .Lword_collect
    add     x1, x1, #1
    b       .Lword_skip

    // Collect non-delimiter chars
.Lword_collect:
    ldr     x5, =word_here + 32
    ldr     x5, [x5]                    // x5 = output buffer (HERE)
    mov     x6, #0                      // x6 = length

.Lword_loop:
    cmp     x1, x2
    bge     .Lword_done
    ldrb    w4, [x3, x1]
    cmp     w4, w7
    beq     .Lword_done
    strb    w4, [x5, x6]
    add     x1, x1, #1
    add     x6, x6, #1
    b       .Lword_loop

.Lword_done:
    ldr     x0, =word_toin + 32
    str     x1, [x0]                    // update >IN
    str     x5, [DSP, #-8]!            // push addr
    str     x6, [DSP, #-8]!            // push len (top)
    NEXT

.Lword_empty:
    ldr     x5, =word_here + 32
    ldr     x5, [x5]
    str     x5, [DSP, #-8]!
    str     xzr, [DSP, #-8]!
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// DICTIONARY SEARCH
// ═════════════════════════════════════════════════════════════════════════════

// FIND ( addr len -- entry | 0 )
// Walk the dictionary chain from LATEST. Returns entry address or 0.
// Skips hidden words. Caller checks F_IMMEDIATE bit in entry+8 if needed.
defcode "FIND", 4, find, 0
    ldr     x6, [DSP], #8               // x6 = len
    ldr     x5, [DSP], #8               // x5 = string addr

    ldr     x0, =word_latest + 32
    ldr     x0, [x0]                    // x0 = start of chain

.Lfind_loop:
    cbz     x0, .Lfind_notfound
    ldr     x1, [x0, #8]                // flags|len
    and     x2, x1, #(F_HIDDEN << 8)
    cbnz    x2, .Lfind_next             // hidden: skip
    and     x2, x1, #0xFF               // name length
    cmp     x2, x6
    bne     .Lfind_next                 // length mismatch

    // Compare characters
    add     x3, x0, #16                 // entry name field
    mov     x4, #0
.Lfind_cmp:
    cmp     x4, x6
    bge     .Lfind_found
    ldrb    w8, [x5, x4]
    ldrb    w9, [x3, x4]
    cmp     w8, w9
    bne     .Lfind_next
    add     x4, x4, #1
    b       .Lfind_cmp

.Lfind_found:
    str     x0, [DSP, #-8]!
    NEXT

.Lfind_next:
    ldr     x0, [x0]                    // follow link
    b       .Lfind_loop

.Lfind_notfound:
    str     xzr, [DSP, #-8]!
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// NUMBER PARSING
// ═════════════════════════════════════════════════════════════════════════════

// NUMBER ( addr len -- n true | false )
// Parse string as unsigned integer in current BASE.
defcode "NUM", 3, number, 0
    ldr     x6, [DSP], #8               // len
    ldr     x5, [DSP], #8               // addr
    cbz     x6, .Lnum_bad               // empty string

    ldr     x0, =word_base + 32
    ldr     x0, [x0]                    // x0 = BASE

    // Check for leading '-'
    ldrb    w1, [x5]
    mov     x9, #0                      // x9 = negative flag
    cmp     w1, #'-'
    bne     .Lnum_start
    mov     x9, #1
    add     x5, x5, #1
    sub     x6, x6, #1
    cbz     x6, .Lnum_bad

.Lnum_start:
    mov     x3, #0                      // accumulator
    mov     x4, #0                      // index

.Lnum_loop:
    cmp     x4, x6
    bge     .Lnum_ok
    ldrb    w1, [x5, x4]

    // Digit conversion
    cmp     w1, #'0'
    blt     .Lnum_bad
    cmp     w1, #'9'
    ble     .Lnum_dec
    cmp     w1, #'A'
    blt     .Lnum_bad
    cmp     w1, #'F'
    ble     .Lnum_upper
    cmp     w1, #'a'
    blt     .Lnum_bad
    cmp     w1, #'f'
    bgt     .Lnum_bad
    sub     w1, w1, #('a' - 10)
    b       .Lnum_digit
.Lnum_upper:
    sub     w1, w1, #('A' - 10)
    b       .Lnum_digit
.Lnum_dec:
    sub     w1, w1, #'0'
.Lnum_digit:
    cmp     x1, x0                      // digit >= base?
    bge     .Lnum_bad
    mul     x3, x3, x0
    add     x3, x3, x1
    add     x4, x4, #1
    b       .Lnum_loop

.Lnum_ok:
    cbnz    x9, 1f                      // apply sign
    b       2f
1:  neg     x3, x3
2:  str     x3, [DSP, #-8]!            // push number
    mov     x0, #-1
    str     x0, [DSP, #-8]!            // push true
    NEXT

.Lnum_bad:
    str     xzr, [DSP, #-8]!           // push false
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// REFILL — read a line from UART into TIB
// ═════════════════════════════════════════════════════════════════════════════

defcode "RFL", 3, refill, 0
    ldr     x5, =TIB_BASE
    mov     x6, #0                      // char count

.Lrfl_loop:
    // Blocking UART read
    ldr     x0, =UART_FR
.Lrfl_rx:
    ldr     w1, [x0]
    tbnz    w1, #4, .Lrfl_rx           // RX FIFO empty
    ldr     x0, =UART_DR
    ldr     w2, [x0]
    and     w2, w2, #0xFF

    // CR/LF → done (CRLF emitted below, no echo here)
    cmp     w2, #13
    beq     .Lrfl_done
    cmp     w2, #10
    beq     .Lrfl_done

    // BS/DEL → erase last char if buffer non-empty
    cmp     w2, #8
    beq     .Lrfl_bs
    cmp     w2, #127
    beq     .Lrfl_bs

    // Normal char: echo then store (if buffer not full)
    cmp     x6, #(TIB_SIZE - 1)
    bge     .Lrfl_loop
    ldr     x0, =UART_FR
.Lrfl_echo:
    ldr     w3, [x0]
    tbnz    w3, #5, .Lrfl_echo
    ldr     x0, =UART_DR
    str     w2, [x0]
    strb    w2, [x5, x6]
    add     x6, x6, #1
    b       .Lrfl_loop

.Lrfl_bs:
    cbz     x6, .Lrfl_loop             // nothing to erase
    sub     x6, x6, #1
    // Send \b \b  (move back, overwrite with space, move back)
    ldr     x0, =UART_FR
.Lrfl_bs1:
    ldr     w3, [x0]
    tbnz    w3, #5, .Lrfl_bs1
    ldr     x0, =UART_DR
    mov     w1, #8
    str     w1, [x0]
    ldr     x0, =UART_FR
.Lrfl_bs2:
    ldr     w3, [x0]
    tbnz    w3, #5, .Lrfl_bs2
    ldr     x0, =UART_DR
    mov     w1, #32
    str     w1, [x0]
    ldr     x0, =UART_FR
.Lrfl_bs3:
    ldr     w3, [x0]
    tbnz    w3, #5, .Lrfl_bs3
    ldr     x0, =UART_DR
    mov     w1, #8
    str     w1, [x0]
    b       .Lrfl_loop

.Lrfl_done:
    // Emit CRLF
    ldr     x0, =UART_FR
.Lrfl_cr1:
    ldr     w1, [x0]
    tbnz    w1, #5, .Lrfl_cr1
    ldr     x0, =UART_DR
    mov     w1, #13
    str     w1, [x0]
    ldr     x0, =UART_FR
.Lrfl_lf1:
    ldr     w1, [x0]
    tbnz    w1, #5, .Lrfl_lf1
    ldr     x0, =UART_DR
    mov     w1, #10
    str     w1, [x0]

    // Update TIB state
    ldr     x0, =word_ntib + 32
    str     x6, [x0]
    ldr     x0, =word_toin + 32
    str     xzr, [x0]
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// COMPILER PRIMITIVES
// ═════════════════════════════════════════════════════════════════════════════

// [ ( -- )   enter interpret mode (immediate)
defcode "[", 1, lbrac, F_IMMEDIATE
    ldr     x0, =word_state + 32
    str     xzr, [x0]
    NEXT

// ] ( -- )   enter compile mode
defcode "]", 1, rbrac, 0
    ldr     x0, =word_state + 32
    mov     x1, #1
    str     x1, [x0]
    NEXT

// ' ( <name> -- xt )   push execution token of next parsed word
defcode "'", 1, tick, 0
    // Parse next space-delimited word from TIB
    ldr     x7, =word_toin + 32
    ldr     x1, [x7]
    ldr     x8, =word_ntib + 32
    ldr     x2, [x8]
    ldr     x3, =TIB_BASE

    // Skip spaces
.Ltick_skip:
    cmp     x1, x2
    bge     .Ltick_none
    ldrb    w4, [x3, x1]
    cmp     w4, #' '
    bne     .Ltick_col
    add     x1, x1, #1
    b       .Ltick_skip

    // Collect word
.Ltick_col:
    ldr     x5, =word_here + 32
    ldr     x5, [x5]
    mov     x6, #0
.Ltick_coll:
    cmp     x1, x2
    bge     .Ltick_done
    ldrb    w4, [x3, x1]
    cmp     w4, #' '
    beq     .Ltick_done
    strb    w4, [x5, x6]
    add     x1, x1, #1
    add     x6, x6, #1
    b       .Ltick_coll
.Ltick_done:
    str     x1, [x7]

    // FIND it
    ldr     x0, =word_latest + 32
    ldr     x0, [x0]
.Ltick_find:
    cbz     x0, .Ltick_none
    ldr     x1, [x0, #8]
    and     x2, x1, #0xFF
    cmp     x2, x6
    bne     .Ltick_next
    add     x3, x0, #16
    mov     x4, #0
.Ltick_cmp:
    cmp     x4, x6
    bge     .Ltick_found
    ldrb    w8, [x5, x4]
    ldrb    w9, [x3, x4]
    cmp     w8, w9
    bne     .Ltick_next
    add     x4, x4, #1
    b       .Ltick_cmp
.Ltick_found:
    str     x0, [DSP, #-8]!
    NEXT
.Ltick_next:
    ldr     x0, [x0]
    ldr     x3, =TIB_BASE
    b       .Ltick_find
.Ltick_none:
    str     xzr, [DSP, #-8]!
    NEXT

// IMMEDIATE ( -- )   mark the most recent definition as immediate
defcode "IMM", 3, immediate, 0
    ldr     x0, =word_latest + 32
    ldr     x0, [x0]                    // current latest entry
    ldr     x1, [x0, #8]                // flags|len
    orr     x1, x1, #(F_IMMEDIATE << 8)
    str     x1, [x0, #8]
    NEXT

// HIDDEN ( entry -- )   toggle hidden flag on an entry
defcode "HID", 3, hidden, 0
    ldr     x0, [DSP], #8
    ldr     x1, [x0, #8]
    eor     x1, x1, #(F_HIDDEN << 8)
    str     x1, [x0, #8]
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// COLON DEFINITIONS
// ═════════════════════════════════════════════════════════════════════════════

// : ( -- )   begin a colon definition
// Parses next space-delimited token from TIB, builds a DOCOL header at HERE,
// updates LATEST and HERE, marks the entry hidden until ; completes, enters
// compile mode.
defcode ":", 1, colon, 0
    // Load current HERE — this will be the base of the new entry
    ldr     x10, =word_here + 32
    ldr     x10, [x10]                  // x10 = entry base

    // ── Parse next token from TIB ─────────────────────────────────────────
    ldr     x0, =word_toin + 32
    ldr     x1, [x0]                    // x1 = >IN
    ldr     x2, =word_ntib + 32
    ldr     x2, [x2]                    // x2 = #TIB
    ldr     x3, =TIB_BASE

    // Skip leading spaces
.Lcolon_skip:
    cmp     x1, x2
    bge     .Lcolon_noname
    ldrb    w4, [x3, x1]
    cmp     w4, #' '
    bne     .Lcolon_collect
    add     x1, x1, #1
    b       .Lcolon_skip

    // Collect name chars into entry+16; zero the field first
.Lcolon_collect:
    str     xzr, [x10, #16]             // zero name field
    add     x5, x10, #16               // x5 = name field address
    mov     x6, #0                      // x6 = length
.Lcolon_coll:
    cmp     x1, x2
    bge     .Lcolon_namedone
    ldrb    w4, [x3, x1]
    cmp     w4, #' '
    beq     .Lcolon_namedone
    cmp     x6, #7                      // max 7 chars (8th byte stays zero)
    bge     .Lcolon_namedone
    strb    w4, [x5, x6]
    add     x1, x1, #1
    add     x6, x6, #1
    b       .Lcolon_coll

.Lcolon_namedone:
    // Update >IN
    ldr     x0, =word_toin + 32
    str     x1, [x0]

    // ── Write dictionary header at x10 ───────────────────────────────────
    // [entry+0]  = link  = current LATEST
    ldr     x0, =word_latest + 32
    ldr     x0, [x0]
    str     x0, [x10]

    // [entry+8]  = flags|len  (hidden during compilation)
    orr     x0, x6, #(F_HIDDEN << 8)
    str     x0, [x10, #8]

    // [entry+16] = name  (already written above)

    // [entry+24] = codeword = DOCOL
    ldr     x0, =DOCOL
    str     x0, [x10, #24]

    // ── Update LATEST and HERE ────────────────────────────────────────────
    ldr     x0, =word_latest + 32
    str     x10, [x0]                   // LATEST = new entry

    add     x0, x10, #32               // HERE = entry + 32 (body starts here)
    ldr     x1, =word_here + 32
    str     x0, [x1]

    // ── Enter compile mode ────────────────────────────────────────────────
    ldr     x0, =word_state + 32
    mov     x1, #1
    str     x1, [x0]
    NEXT

.Lcolon_noname:
    NEXT                                // no name token — ignore silently

// ; ( -- )   end a colon definition  (IMMEDIATE)
// Compiles EXIT, unhides the new word, returns to interpret mode.
defcode ";", 1, semicolon, F_IMMEDIATE
    // Compile EXIT: append word_exit to HERE
    ldr     x0, =word_here + 32
    ldr     x1, [x0]                    // x1 = HERE
    ldr     x2, =word_exit
    str     x2, [x1]                    // write EXIT entry address
    add     x1, x1, #8
    str     x1, [x0]                    // update HERE

    // Unhide the word just defined (clear F_HIDDEN bit)
    ldr     x0, =word_latest + 32
    ldr     x0, [x0]                    // x0 = latest entry
    ldr     x1, [x0, #8]               // flags|len
    mov     x2, #(F_HIDDEN << 8)
    bic     x1, x1, x2                 // x1 &= ~(F_HIDDEN << 8)
    str     x1, [x0, #8]

    // Return to interpret mode
    ldr     x0, =word_state + 32
    str     xzr, [x0]
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// CONTROL FLOW COMPILER WORDS  (all F_IMMEDIATE — run at compile time)
// ═════════════════════════════════════════════════════════════════════════════
//
// Offset convention (BRN / 0BRN):
//   When code_branch / code_zbranch runs, IP points TO the offset cell.
//   The branch sets IP = &offset_cell + offset, then NEXT reads from there.
//   So:  offset = target_addr - &offset_cell
//   Forward jump (positive),  backward jump (negative).
//
// Data-stack protocol during compilation:
//   IF   ( -- fixup )            fixup = addr of the 0BRN offset cell
//   THEN ( fixup -- )            patches fixup so false branch exits block
//   ELSE ( fixup_if -- fixup_else )
//   BEGIN ( -- loop_addr )       loop_addr = first word of loop body
//   UNTIL ( loop_addr -- )       0BRN back to loop_addr when false (= 0)
//   AGAIN ( loop_addr -- )       unconditional BRN back to loop_addr
//   WHILE ( loop_addr -- loop_addr fixup_while )
//   REPEAT ( loop_addr fixup_while -- )

// IF  ( -- fixup )
defcode "IF", 2, if, F_IMMEDIATE
    ldr     x0, =word_here + 32
    ldr     x1, [x0]               // x1 = HERE
    ldr     x2, =word_zbranch
    str     x2, [x1]               // compile word_zbranch
    add     x1, x1, #8
    str     xzr, [x1]              // compile placeholder 0
    str     x1, [DSP, #-8]!        // push placeholder addr (fixup)
    add     x1, x1, #8
    str     x1, [x0]               // update HERE
    NEXT

// THEN  ( fixup -- )
// Back-patches the forward branch left by IF or ELSE.
defcode "THEN", 4, then, F_IMMEDIATE
    ldr     x1, [DSP], #8          // pop fixup (offset cell address)
    ldr     x0, =word_here + 32
    ldr     x2, [x0]               // x2 = HERE (branch target)
    sub     x3, x2, x1             // offset = HERE - fixup_addr
    str     x3, [x1]               // patch placeholder
    NEXT

// ELSE  ( fixup_if -- fixup_else )
// Compiles BRN over the else-body; back-patches IF's forward branch to here.
defcode "ELSE", 4, else, F_IMMEDIATE
    ldr     x0, =word_here + 32
    ldr     x1, [x0]               // x1 = HERE
    ldr     x2, =word_branch
    str     x2, [x1]               // compile word_branch
    add     x1, x1, #8
    str     xzr, [x1]              // compile placeholder 0
    mov     x4, x1                 // x4 = ELSE's placeholder addr (fixup_else)
    add     x1, x1, #8            // x1 = HERE = start of else-body
    str     x1, [x0]               // update HERE
    // Back-patch IF's placeholder: offset = HERE (start of else-body) - if_fixup
    ldr     x3, [DSP], #8          // pop IF's fixup addr
    sub     x5, x1, x3             // offset = start_of_else - if_fixup
    str     x5, [x3]               // patch IF's placeholder
    str     x4, [DSP, #-8]!        // push ELSE's fixup for THEN
    NEXT

// BEGIN  ( -- loop_addr )
// Records the current HERE as the loop-back target.
defcode "BEGIN", 5, begin, F_IMMEDIATE
    ldr     x0, =word_here + 32
    ldr     x1, [x0]               // x1 = HERE = loop-back target
    str     x1, [DSP, #-8]!        // push it
    NEXT

// UNTIL  ( loop_addr -- )
// Compile 0BRN back to loop_addr.  Loops while condition is false (= 0);
// exits when condition is true (non-zero).
defcode "UNTIL", 5, until, F_IMMEDIATE
    ldr     x3, [DSP], #8          // pop loop-back target T
    ldr     x0, =word_here + 32
    ldr     x1, [x0]               // x1 = HERE
    ldr     x2, =word_zbranch
    str     x2, [x1]               // compile word_zbranch
    add     x1, x1, #8             // x1 = offset cell addr
    sub     x4, x3, x1             // offset = T - &offset_cell  (negative)
    str     x4, [x1]               // compile offset
    add     x1, x1, #8
    str     x1, [x0]               // update HERE
    NEXT

// AGAIN  ( loop_addr -- )
// Compile unconditional BRN back to loop_addr (infinite loop).
defcode "AGAIN", 5, again, F_IMMEDIATE
    ldr     x3, [DSP], #8          // pop loop-back target T
    ldr     x0, =word_here + 32
    ldr     x1, [x0]               // x1 = HERE
    ldr     x2, =word_branch
    str     x2, [x1]               // compile word_branch
    add     x1, x1, #8             // x1 = offset cell addr
    sub     x4, x3, x1             // offset = T - &offset_cell  (negative)
    str     x4, [x1]               // compile offset
    add     x1, x1, #8
    str     x1, [x0]               // update HERE
    NEXT

// WHILE  ( loop_addr -- loop_addr fixup_while )
// Compile 0BRN + placeholder.  Exits loop when condition is false (= 0).
defcode "WHILE", 5, while, F_IMMEDIATE
    ldr     x0, =word_here + 32
    ldr     x1, [x0]               // x1 = HERE
    ldr     x2, =word_zbranch
    str     x2, [x1]               // compile word_zbranch
    add     x1, x1, #8
    str     xzr, [x1]              // compile placeholder 0
    mov     x4, x1                 // x4 = WHILE's fixup addr
    add     x1, x1, #8
    str     x1, [x0]               // update HERE
    str     x4, [DSP, #-8]!        // push fixup (loop_addr stays below it)
    NEXT

// RECURSE  ( -- )   compile a self-call to the word currently being defined.
// The word is hidden during compilation, so it can't be found by name;
// RECURSE compiles its entry address directly from LATEST.
defcode "RECURSE", 7, recurse, F_IMMEDIATE
    ldr     x0, =word_latest + 32
    ldr     x1, [x0]               // LATEST = entry of word being defined
    ldr     x0, =word_here + 32
    ldr     x2, [x0]               // HERE
    str     x1, [x2]               // compile self-reference
    add     x2, x2, #8
    str     x2, [x0]               // update HERE
    NEXT

// REPEAT  ( loop_addr fixup_while -- )
// Compile BRN back to loop_addr; back-patch WHILE's fixup to exit the loop.
defcode "REPEAT", 6, repeat, F_IMMEDIATE
    ldr     x5, [DSP], #8          // pop WHILE's fixup addr
    ldr     x3, [DSP], #8          // pop loop-back target T
    ldr     x0, =word_here + 32
    ldr     x1, [x0]               // x1 = HERE
    ldr     x2, =word_branch
    str     x2, [x1]               // compile word_branch
    add     x1, x1, #8             // x1 = offset cell addr
    sub     x4, x3, x1             // offset = T - &offset_cell  (negative)
    str     x4, [x1]               // compile backward offset
    add     x1, x1, #8             // x1 = HERE after REPEAT = loop exit addr
    str     x1, [x0]               // update HERE
    sub     x4, x1, x5             // offset = exit_addr - while_fixup
    str     x4, [x5]               // patch WHILE's placeholder
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// DEBUG / INTROSPECTION
// ═════════════════════════════════════════════════════════════════════════════

// .S ( -- )   print stack non-destructively as hex values
defcode ".S", 2, dots, 0
    mov     x10, DSP
    ldr     x11, =DSTACK_TOP
.Ldots_loop:
    cmp     x10, x11
    bge     .Ldots_done
    ldr     x0, [x10]
    bl      printhex64
    ldr     x1, =UART_FR
.Ldots_sp:
    ldr     w2, [x1]
    tbnz    w2, #5, .Ldots_sp
    ldr     x1, =UART_DR
    mov     w2, #' '
    str     w2, [x1]
    add     x10, x10, #8
    b       .Ldots_loop
.Ldots_done:
    NEXT

// . ( n -- )   print top of stack as hex + space
// Note: full decimal '.' requires bignum division (Phase 4).
// This hex version is correct and useful for all debug purposes now.
defcode ".", 1, dot, 0
    ldr     x0, [DSP], #8
    bl      printhex64
    ldr     x1, =UART_FR
.Ldot_sp:
    ldr     w2, [x1]
    tbnz    w2, #5, .Ldot_sp
    ldr     x1, =UART_DR
    mov     w2, #' '
    str     w2, [x1]
    NEXT

// WORDS ( -- )   list all non-hidden dictionary entries
defcode "WRDS", 4, words, 0
    ldr     x0, =word_latest + 32
    ldr     x0, [x0]
.Lwords_loop:
    cbz     x0, .Lwords_done
    ldr     x1, [x0, #8]               // flags|len
    and     x2, x1, #(F_HIDDEN << 8)
    cbnz    x2, .Lwords_next           // hidden: skip
    and     x2, x1, #0xFF              // name length
    add     x3, x0, #16                // name addr
    // TYPE the name
    mov     x4, #0
.Lwords_type:
    cmp     x4, x2
    bge     .Lwords_sp
    ldrb    w5, [x3, x4]
    ldr     x6, =UART_FR
.Lwords_tw:
    ldr     w7, [x6]
    tbnz    w7, #5, .Lwords_tw
    ldr     x6, =UART_DR
    str     w5, [x6]
    add     x4, x4, #1
    b       .Lwords_type
.Lwords_sp:
    ldr     x6, =UART_FR
.Lwords_spw:
    ldr     w7, [x6]
    tbnz    w7, #5, .Lwords_spw
    ldr     x6, =UART_DR
    mov     w7, #' '
    str     w7, [x6]
.Lwords_next:
    ldr     x0, [x0]
    b       .Lwords_loop
.Lwords_done:
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// NOUN PRIMITIVES  (Phase 2 — interfaces to noun.c)
// ═════════════════════════════════════════════════════════════════════════════
//
// Noun 64-bit word layout (bits 63:62 = tag):
//   00  cell        bits 31:0 = heap ptr to {refcount, pad, head, tail}
//   01  direct atom bits 61:0 = value
//   10  indirect    bits 61:32 = BLAKE3 prefix; bits 31:0 = heap ptr to atom_t
//   11  content     bits 61:0 = 62-bit BLAKE3 hash
//
// C functions called here use AAPCS; x24-x27 (W/RSP/DSP/IP) are callee-saved
// per AAPCS so they survive bl calls without explicit save/restore.

// CONS ( head tail -- cell )
defcode "CONS", 4, cons, 0
    ldr     x1, [DSP], #8       // x1 = tail (TOS)
    ldr     x0, [DSP], #8       // x0 = head
    bl      alloc_cell          // returns cell noun in x0
    str     x0, [DSP, #-8]!
    NEXT

// CAR ( cell -- head )   head of a cell noun
defcode "CAR", 3, car, 0
    ldr     x0, [DSP], #8       // x0 = cell noun
    and     x0, x0, #0xFFFFFFFF // extract 32-bit heap pointer
    ldr     x1, [x0, #8]        // cell_t.head at offset 8
    str     x1, [DSP, #-8]!
    NEXT

// CDR ( cell -- tail )   tail of a cell noun
defcode "CDR", 3, cdr, 0
    ldr     x0, [DSP], #8       // x0 = cell noun
    and     x0, x0, #0xFFFFFFFF // extract 32-bit heap pointer
    ldr     x1, [x0, #16]       // cell_t.tail at offset 16
    str     x1, [DSP, #-8]!
    NEXT

// >NOUN ( n -- noun )   wrap raw integer as a direct atom noun (bit63=0)
// In the new scheme direct(v) = v, so just clear bit 63.
defcode ">NOUN", 5, to_noun, 0
    ldr     x0, [DSP]
    lsl     x0, x0, #1          // clear bit 63
    lsr     x0, x0, #1
    str     x0, [DSP]
    NEXT

// NOUN> ( noun -- n )   extract raw integer from a direct atom noun
// direct_val(n) = n & 0x7FFF..., i.e. clear bit 63.
defcode "NOUN>", 5, from_noun, 0
    ldr     x0, [DSP]
    lsl     x0, x0, #1          // clear bit 63
    lsr     x0, x0, #1
    str     x0, [DSP]
    NEXT

// ATOM? ( noun -- flag )   true (-1) if atom (bits 63:62 ≠ 11), false (0) if cell
defcode "ATOM?", 5, isatom, 0
    ldr     x0, [DSP]
    lsr     x1, x0, #62         // top 2 bits → positions 1:0
    cmp     x1, #3
    csetm   x1, ne              // ne → -1 (atom), eq → 0 (cell)
    str     x1, [DSP]
    NEXT

// CELL? ( noun -- flag )   true (-1) if cell (bits 63:62 = 11), false (0) if atom
defcode "CELL?", 5, iscell, 0
    ldr     x0, [DSP]
    lsr     x1, x0, #62         // top 2 bits → positions 1:0
    cmp     x1, #3
    csetm   x1, eq              // eq → -1 (cell), ne → 0 (atom)
    str     x1, [DSP]
    NEXT

// =NOUN ( n1 n2 -- flag )   structural equality (calls noun_eq in noun.c)
defcode "=NOUN", 5, noueq, 0
    ldr     x1, [DSP], #8       // x1 = n2 (TOS)
    ldr     x0, [DSP], #8       // x0 = n1
    bl      noun_eq             // returns 1 (equal) or 0 (not equal)
    neg     x0, x0              // 1 → -1 (Forth true), 0 → 0 (Forth false)
    str     x0, [DSP, #-8]!
    NEXT

// HATOM ( noun -- noun' )   no-op in new scheme: atoms are always content-addressed.
defcode "HATOM", 5, hash_atom_word, 0
    NEXT

// PILL ( -- atom )   load jammed atom from PILL_BASE (QEMU -device loader).
//   Returns noun-zero (direct 0) if no pill was loaded.
//   Caller should CUE the result to decode the noun.
defcode "PILL", 4, pill, 0
    bl      pill_load           // noun.c: reads from PILL_BASE, returns atom
    str     x0, [DSP, #-8]!
    NEXT

// B3OK ( -- flag )   run official BLAKE3 test vectors; pushes 1=pass 0=fail
defcode "B3OK", 4, b3ok, 0
    bl      blake3_selftest     // blake3.c: returns 1 (pass) or 0 (fail)
    str     x0, [DSP, #-8]!
    NEXT

// N. ( noun -- )   print atom as decimal + space
// Calls bn_to_decimal_fill(noun) → fills bn_decimal_buf[], returns length.
defcode "N.", 2, ndot, 0
    ldr     x0, [DSP], #8
    bl      bn_to_decimal_fill  // x0 = length written into bn_decimal_buf[]
    cbz     x0, .Lndot_sp
    mov     x4, x0              // x4 = remaining chars
    ldr     x3, =bn_decimal_buf // x3 = buf pointer
.Lndot_loop:
    cbz     x4, .Lndot_sp
    ldrb    w5, [x3], #1
.Lndot_tx:
    ldr     x6, =UART_FR
    ldr     w7, [x6]
    tbnz    w7, #5, .Lndot_tx
    ldr     x6, =UART_DR
    str     w5, [x6]
    sub     x4, x4, #1
    b       .Lndot_loop
.Lndot_sp:
    ldr     x6, =UART_FR
.Lndot_spw:
    ldr     w7, [x6]
    tbnz    w7, #5, .Lndot_spw
    ldr     x6, =UART_DR
    mov     w7, #' '
    str     w7, [x6]
    NEXT

// BN+ ( noun1 noun2 -- noun )   bignum addition
defcode "BN+", 3, bnadd, 0
    ldr     x1, [DSP], #8
    ldr     x0, [DSP], #8
    bl      bn_add
    str     x0, [DSP, #-8]!
    NEXT

// BNDEC ( noun -- noun )   bignum decrement (crashes on zero)
defcode "BNDEC", 5, bndec, 0
    ldr     x0, [DSP], #8
    bl      bn_dec
    str     x0, [DSP, #-8]!
    NEXT

// BNMET ( noun -- n )   significant bit length; result is raw integer
defcode "BNMET", 5, bnmet, 0
    ldr     x0, [DSP], #8
    bl      bn_met              // returns uint64_t in x0
    str     x0, [DSP, #-8]!
    NEXT

// BNBEX ( n -- noun )   2^n as atom noun; n is raw integer
defcode "BNBEX", 5, bnbex, 0
    ldr     x0, [DSP], #8
    bl      bn_bex
    str     x0, [DSP, #-8]!
    NEXT

// BNLSH ( noun n -- noun )   left shift noun by n bits; n is raw integer
defcode "BNLSH", 5, bnlsh, 0
    ldr     x1, [DSP], #8      // k (raw integer)
    ldr     x0, [DSP], #8      // noun
    bl      bn_lsh
    str     x0, [DSP, #-8]!
    NEXT

// BNRSH ( noun n -- noun )   right shift noun by n bits; n is raw integer
defcode "BNRSH", 5, bnrsh, 0
    ldr     x1, [DSP], #8      // k (raw integer)
    ldr     x0, [DSP], #8      // noun
    bl      bn_rsh
    str     x0, [DSP, #-8]!
    NEXT

// BNOR ( n1 n2 -- n )   bitwise OR of two atom nouns
defcode "BNOR", 4, bnor, 0
    ldr     x1, [DSP], #8
    ldr     x0, [DSP], #8
    bl      bn_or
    str     x0, [DSP, #-8]!
    NEXT

// BNAND ( n1 n2 -- n )   bitwise AND of two atom nouns
defcode "BNAND", 5, bnand, 0
    ldr     x1, [DSP], #8
    ldr     x0, [DSP], #8
    bl      bn_and
    str     x0, [DSP, #-8]!
    NEXT

// BNXOR ( n1 n2 -- n )   bitwise XOR of two atom nouns
defcode "BNXOR", 5, bnxor, 0
    ldr     x1, [DSP], #8
    ldr     x0, [DSP], #8
    bl      bn_xor
    str     x0, [DSP, #-8]!
    NEXT

// BNMUL ( n1 n2 -- n )   bignum multiplication
defcode "BNMUL", 5, bnmul, 0
    ldr     x1, [DSP], #8
    ldr     x0, [DSP], #8
    bl      bn_mul
    str     x0, [DSP, #-8]!
    NEXT

// BNDIV ( n1 n2 -- n )   integer quotient: floor(n1 / n2)
defcode "BNDIV", 5, bndiv, 0
    ldr     x1, [DSP], #8
    ldr     x0, [DSP], #8
    bl      bn_div
    str     x0, [DSP, #-8]!
    NEXT

// BNMOD ( n1 n2 -- n )   remainder: n1 mod n2
defcode "BNMOD", 5, bnmod, 0
    ldr     x1, [DSP], #8
    ldr     x0, [DSP], #8
    bl      bn_mod
    str     x0, [DSP, #-8]!
    NEXT

// ─────────────────────────────────────────────────────────────────────────────
// JAM / CUE  (Phase 5a — noun serialization / deserialization)
// ─────────────────────────────────────────────────────────────────────────────

// JAM ( noun -- atom )   serialize noun to atom via jam encoding
defcode "JAM", 3, jam_word, 0
    ldr     x0, [DSP], #8
    bl      jam
    str     x0, [DSP, #-8]!
    NEXT

// CUE ( atom -- noun )   deserialize atom back to noun via cue decoding
defcode "CUE", 3, cue_word, 0
    ldr     x0, [DSP], #8
    bl      cue
    str     x0, [DSP, #-8]!
    NEXT

// ─────────────────────────────────────────────────────────────────────────────
// NOCK EVAL PRIMITIVES  (Phase 3 — interfaces to nock.c)
// ─────────────────────────────────────────────────────────────────────────────

// SLOT ( axis noun -- result )   Nock / operator: tree address lookup
defcode "SLOT", 4, slot, 0
    ldr     x1, [DSP], #8       // x1 = noun (subject)
    ldr     x0, [DSP], #8       // x0 = axis (direct atom)
    bl      slot                // slot(axis, subject)
    str     x0, [DSP, #-8]!
    NEXT

// SKA-EN ( -- addr )  when non-zero, NOCK routes through ska_nock
defvar "SKA-EN", 6, ska_enable, 0, 0

// NOCK ( subject formula -- product )   Nock 4K evaluator
// When SKA-EN is non-zero, routes through ska_nock (SKA-annotated eval).
defcode "NOCK", 4, nock_word, 0
    ldr     x1, [DSP], #8       // x1 = formula
    ldr     x0, [DSP], #8       // x0 = subject
    adr     x4, word_ska_enable
    ldr     x4, [x4, #32]       // load SKA-EN storage cell
    cbz     x4, .Lnock_plain
    mov     x2, #0              // jets = NULL
    mov     x3, #0              // sky  = NULL
    bl      ska_nock
    b       .Lnock_done
.Lnock_plain:
    bl      nock
.Lnock_done:
    str     x0, [DSP, #-8]!
    NEXT

// SKNOCK ( subject formula -- product )  SKA-analyzed Nock evaluator
// Runs the SKA scan pass over the formula, then evaluates the nomm_t AST.
// Gives identical results to NOCK but with static jet dispatch at annotated
// call sites.  Falls back to nock_ex() for op 9 / indirect op 2 sites.
defcode "SKNOCK", 6, sknock, 0
    ldr     x1, [DSP], #8       // x1 = formula
    ldr     x0, [DSP], #8       // x0 = subject
    mov     x2, #0              // jets = NULL
    mov     x3, #0              // sky  = NULL
    bl      ska_nock            // ska_nock(subject, formula, NULL, NULL)
    str     x0, [DSP, #-8]!
    NEXT

// .SKA ( subject formula -- )   Print SKA analysis dashboard to UART
// Runs ska_analyze (scan + cook) and prints call site statistics:
//   "SKA: N call sites (D direct, J jetted)"
defcode ".SKA", 4, dotska, 0
    ldr     x1, [DSP], #8       // x1 = formula
    ldr     x0, [DSP], #8       // x0 = subject
    bl      ska_print_stats     // ska_print_stats(subject, formula)
    NEXT

// ═════════════════════════════════════════════════════════════════════════════
// QUIT — the top-level interpreter loop
// ═════════════════════════════════════════════════════════════════════════════
//
// QUIT never returns. On error we jump back to .Lquit_restart.
// Implements the standard Forth outer interpreter:
//   loop:
//     refill TIB
//     for each word in TIB:
//       find in dictionary
//         if found and interpreting: execute
//         if found and immediate: execute
//         if found and compiling:  compile (append xt to HERE)
//       not found: try as number
//         if number and interpreting: push
//         if number and compiling:    compile LIT + value
//       not found and not number: error
//
defcode "QUIT", 4, quit, 0

.Lquit_restart:
    // Reset stacks unconditionally — this is also the ABORT target
    ldr     DSP, =DSTACK_TOP
    ldr     RSP, =RSTACK_TOP

    // Interpret mode
    ldr     x0, =word_state + 32
    str     xzr, [x0]

    // Establish (or re-establish) nock crash recovery point.
    // setjmp saves all callee-saved regs (x19-x28 inc. Forth VM regs,
    // x29/x30, sp) with stacks already clean.
    // Returns 0 on normal entry; 1 after longjmp from nock_crash()
    // (crash message already printed).  Either way fall through to prompt.
    ldr     x0, =nock_abort
    bl      setjmp
    // x0 ignored — both paths print the prompt and enter the line loop

    // Print prompt
    ldr     x0, =str_prompt
    ldr     x1, =str_prompt_end
    sub     x1, x1, x0
    bl      puts_uart

.Lquit_line:
    // Read a line from UART into TIB
    // (Inline REFILL — can't call Forth words from a primitive easily)
    ldr     x5, =TIB_BASE
    mov     x6, #0
.Lq_rxloop:
    ldr     x0, =UART_FR
.Lq_rxwait:
    ldr     w1, [x0]
    tbnz    w1, #4, .Lq_rxwait
    ldr     x0, =UART_DR
    ldr     w2, [x0]
    and     w2, w2, #0xFF
    // CR/LF → end of line (no echo; CRLF emitted below)
    cmp     w2, #13
    beq     .Lq_eol
    cmp     w2, #10
    beq     .Lq_eol
    // BS/DEL → erase last char if buffer non-empty
    cmp     w2, #8
    beq     .Lq_bs
    cmp     w2, #127
    beq     .Lq_bs
    // Normal char: echo then store (if buffer not full)
    cmp     x6, #(TIB_SIZE - 1)
    bge     .Lq_rxloop
    ldr     x0, =UART_FR
.Lq_txwait:
    ldr     w3, [x0]
    tbnz    w3, #5, .Lq_txwait
    ldr     x0, =UART_DR
    str     w2, [x0]
    strb    w2, [x5, x6]
    add     x6, x6, #1
    b       .Lq_rxloop
.Lq_bs:
    cbz     x6, .Lq_rxloop             // nothing to erase
    sub     x6, x6, #1
    // Send \b \b  (move back, overwrite with space, move back)
    ldr     x0, =UART_FR
.Lq_bs1:
    ldr     w3, [x0]
    tbnz    w3, #5, .Lq_bs1
    ldr     x0, =UART_DR
    mov     w1, #8
    str     w1, [x0]
    ldr     x0, =UART_FR
.Lq_bs2:
    ldr     w3, [x0]
    tbnz    w3, #5, .Lq_bs2
    ldr     x0, =UART_DR
    mov     w1, #32
    str     w1, [x0]
    ldr     x0, =UART_FR
.Lq_bs3:
    ldr     w3, [x0]
    tbnz    w3, #5, .Lq_bs3
    ldr     x0, =UART_DR
    mov     w1, #8
    str     w1, [x0]
    b       .Lq_rxloop
.Lq_eol:
    // Emit CRLF
    ldr     x0, =UART_FR
.Lq_cr:
    ldr     w1, [x0]
    tbnz    w1, #5, .Lq_cr
    ldr     x0, =UART_DR
    mov     w1, #13
    str     w1, [x0]
    ldr     x0, =UART_FR
.Lq_lf:
    ldr     w1, [x0]
    tbnz    w1, #5, .Lq_lf
    ldr     x0, =UART_DR
    mov     w1, #10
    str     w1, [x0]
    // Store TIB length, reset >IN
    ldr     x0, =word_ntib + 32
    str     x6, [x0]
    ldr     x0, =word_toin + 32
    str     xzr, [x0]

    // ── Process each word in the TIB ─────────────────────────────────────
.Lquit_word:
    .global quit_word_loop
quit_word_loop:
    // Parse next space-delimited token from TIB
    ldr     x0, =word_toin + 32
    ldr     x1, [x0]                    // >IN
    ldr     x2, =word_ntib + 32
    ldr     x2, [x2]                    // #TIB
    ldr     x3, =TIB_BASE

    // Skip leading spaces
.Lq_skip:
    cmp     x1, x2
    bge     .Lq_newline                 // exhausted — print ok, new prompt
    ldrb    w4, [x3, x1]
    cmp     w4, #' '
    bne     .Lq_collect
    add     x1, x1, #1
    b       .Lq_skip

    // Collect non-space chars into scratch buffer at HERE
.Lq_collect:
    ldr     x5, =word_here + 32
    ldr     x5, [x5]                    // token buffer = current HERE
    mov     x6, #0
.Lq_coll:
    cmp     x1, x2
    bge     .Lq_colldone
    ldrb    w4, [x3, x1]
    cmp     w4, #' '
    beq     .Lq_colldone
    strb    w4, [x5, x6]
    add     x1, x1, #1
    add     x6, x6, #1
    b       .Lq_coll
.Lq_colldone:
    // Update >IN
    ldr     x0, =word_toin + 32
    str     x1, [x0]
    // x5 = token addr, x6 = token len

    // ── Dictionary lookup ─────────────────────────────────────────────────
    ldr     x0, =word_latest + 32
    ldr     x0, [x0]
.Lq_find:
    cbz     x0, .Lq_number             // not found: try as number
    ldr     x1, [x0, #8]               // flags|len of this entry
    and     x2, x1, #(F_HIDDEN << 8)
    cbnz    x2, .Lq_fnext              // hidden: skip
    and     x2, x1, #0xFF              // name length
    cmp     x2, x6
    bne     .Lq_fnext
    add     x3, x0, #16                // name field
    mov     x4, #0
.Lq_fcmp:
    cmp     x4, x6
    bge     .Lq_found
    ldrb    w7, [x5, x4]
    ldrb    w8, [x3, x4]
    cmp     w7, w8
    bne     .Lq_fnext
    add     x4, x4, #1
    b       .Lq_fcmp
.Lq_fnext:
    ldr     x0, [x0]
    ldr     x3, =TIB_BASE
    b       .Lq_find

    // ── Word found in dictionary ──────────────────────────────────────────
.Lq_found:
    // x0 = entry address
    ldr     x1, [x0, #8]               // flags|len
    // Check immediate flag — immediate words always execute
    and     x2, x1, #(F_IMMEDIATE << 8)
    cbnz    x2, .Lq_execute

    // Check STATE
    ldr     x1, =word_state + 32
    ldr     x1, [x1]
    cbnz    x1, .Lq_compile            // compiling: append to HERE

    // Interpreting: execute it
.Lq_execute:
    // Set W = entry, load codeword, branch
    // We do this with a mini NEXT — but we need IP to be valid.
    // Solution: build a one-cell trampoline on the return stack.
    // After execution, the word's EXIT will pop our saved IP and
    // return to .Lquit_word via the trampoline cell we leave.
    //
    // Actually simpler: just call the codeword directly.
    // Non-colon words end with NEXT which needs a valid IP.
    // We point IP at a 'resume' cell that holds word_quit's entry.
    // This keeps NEXT safe for primitives that fall into it.
    mov     W, x0
    ldr     x0, =trampoline_quit
    mov     IP, x0
    ldr     x0, [W, #24]               // codeword
    br      x0

.Lq_compile:
    // Append the entry address (xt) to HERE
    ldr     x1, =word_here + 32
    ldr     x2, [x1]                   // current HERE
    str     x0, [x2]                   // write xt
    add     x2, x2, #8
    str     x2, [x1]                   // update HERE
    b       .Lquit_word

    // ── Try as number ─────────────────────────────────────────────────────
.Lq_number:
    // x5 = token addr, x6 = token len
    ldr     x0, =word_base + 32
    ldr     x0, [x0]                   // BASE

    // Check for leading '-'
    ldrb    w1, [x5]
    mov     x9, #0
    cmp     w1, #'-'
    bne     .Lq_numparse
    mov     x9, #1
    add     x5, x5, #1
    sub     x6, x6, #1
    cbz     x6, .Lq_error

.Lq_numparse:
    mov     x3, #0                     // accumulator
    mov     x4, #0                     // index
.Lq_numloop:
    cmp     x4, x6
    bge     .Lq_numok
    ldrb    w1, [x5, x4]
    cmp     w1, #'0'
    blt     .Lq_error
    cmp     w1, #'9'
    ble     .Lq_numdec
    cmp     w1, #'A'
    blt     .Lq_error
    cmp     w1, #'F'
    ble     .Lq_numupp
    cmp     w1, #'a'
    blt     .Lq_error
    cmp     w1, #'f'
    bgt     .Lq_error
    sub     w1, w1, #('a' - 10)
    b       .Lq_numdig
.Lq_numupp:
    sub     w1, w1, #('A' - 10)
    b       .Lq_numdig
.Lq_numdec:
    sub     w1, w1, #'0'
.Lq_numdig:
    cmp     x1, x0
    bge     .Lq_error
    mul     x3, x3, x0
    add     x3, x3, x1
    add     x4, x4, #1
    b       .Lq_numloop
.Lq_numok:
    cbnz    x9, 1f
    b       2f
1:  neg     x3, x3
2:
    // Number parsed successfully: x3 = value
    ldr     x1, =word_state + 32
    ldr     x1, [x1]
    cbz     x1, .Lq_push               // interpret: push

    // Compile: LIT + value
    ldr     x1, =word_here + 32
    ldr     x2, [x1]
    ldr     x4, =word_lit
    str     x4, [x2]                   // compile LIT
    add     x2, x2, #8
    str     x3, [x2]                   // compile value
    add     x2, x2, #8
    str     x2, [x1]                   // update HERE
    b       .Lquit_word

.Lq_push:
    str     x3, [DSP, #-8]!           // push number onto data stack
    b       .Lquit_word

    // ── Error — unknown word ──────────────────────────────────────────────
.Lq_error:
    // Print the offending token and "?" then reset
    ldr     x0, =str_err
    ldr     x1, =str_err_end
    sub     x1, x1, x0
    bl      puts_uart
    b       .Lquit_restart             // reset stacks, start over

    // ── End of line — print " ok" and prompt ─────────────────────────────
.Lq_newline:
    // Only print "ok" if in interpret mode (standard Forth convention)
    ldr     x0, =word_state + 32
    ldr     x0, [x0]
    cbnz    x0, .Lq_prompt_only

    ldr     x0, =str_ok
    ldr     x1, =str_ok_end
    sub     x1, x1, x0
    bl      puts_uart

.Lq_prompt_only:
    ldr     x0, =str_prompt
    ldr     x1, =str_prompt_end
    sub     x1, x1, x0
    bl      puts_uart
    b       .Lquit_line

// ── Trampoline — NEXT target after executing a word from QUIT ────────────────
// When QUIT dispatches a word, IP is set to trampoline_quit.
// For primitives: NEXT reads *IP = word_quit_resume, dispatches code_quit_resume
//   which branches to quit_word_loop (next token), leaving data stack intact.
// For colon defs: DOCOL pushes IP (=trampoline_quit) onto RSP; EXIT pops it
//   and does NEXT, which dispatches word_quit_resume → quit_word_loop.
// This preserves the data stack between words on a single input line.

// Internal word (hidden): jump to QUIT's token loop without resetting stacks.
defcode "_QR", 3, quit_resume, F_HIDDEN
    b       quit_word_loop

// ── Phase 6 — Kernel Loop ─────────────────────────────────────────────────

// KSHAPE  ( -- addr )   kernel shape: 0=Arvo 1=Shrine
//   Loaded from PILL header by KERNEL. Inspect with KSHAPE @
defvar "KSHAPE", 6, kshape, 0, 0

// NOUN-RX ( -- noun )   read length-framed cue-decoded noun from UART
defcode "NOUN-RX", 7, recv_noun, 0
    bl      uart_recv_noun          // kernel.c
    str     x0, [DSP, #-8]!
    NEXT

// NOUN-TX ( noun -- )   jam noun, write length-framed to UART
defcode "NOUN-TX", 7, send_noun, 0
    ldr     x0, [DSP], #8
    bl      uart_send_noun          // kernel.c
    NEXT

// DO-FX ( effects -- )   walk effect list, dispatch %out/%blit to UART
defcode "DO-FX", 5, dispatch_fx, 0
    ldr     x0, [DSP], #8
    bl      dispatch_effects        // kernel.c
    NEXT

// ALOOP ( kernel -- )   Arvo-shaped kernel event loop, never returns
defcode "ALOOP", 5, arvo_loop_word, 0
    ldr     x0, [DSP], #8
    bl      arvo_loop               // kernel.c; never returns

// SLOOP ( kernel -- )   Shrine-shaped kernel event loop, never returns
defcode "SLOOP", 5, shrine_loop_word, 0
    ldr     x0, [DSP], #8
    bl      shrine_loop             // kernel.c; never returns

// KERNEL ( -- )
//   Load PILL, decode kernel gate, dispatch to Arvo or Shrine loop
//   based on the shape byte in the PILL header (stored in KSHAPE).
//   Falls back to QUIT if no pill is present.
defcode "KERNEL", 6, kernel, 0
    bl      pill_load               // x0 = jammed atom; sets noun_pill_shape
    // propagate C global noun_pill_shape → KSHAPE variable
    ldr     x1, =noun_pill_shape
    ldr     w1, [x1]                // 32-bit C int
    ldr     x2, =word_kshape + 32   // KSHAPE storage cell
    str     x1, [x2]
    cbz     x0, .Lkernel_nopill
    bl      cue                     // x0 = kernel gate noun
    ldr     x1, =word_kshape + 32
    ldr     x1, [x1]
    cbnz    x1, .Lkernel_shrine
    bl      arvo_loop               // never returns
.Lkernel_shrine:
    bl      shrine_loop             // never returns
.Lkernel_nopill:
    b       code_quit               // no pill: start REPL

    .section .rodata
    .balign 8
trampoline_quit:
    .quad   word_quit_resume

// ═════════════════════════════════════════════════════════════════════════════
// HELPER SUBROUTINES (called via BL, not NEXT — these are C-ABI helpers)
// ═════════════════════════════════════════════════════════════════════════════

    .text
    .balign 4

// printhex64 ( x0 = value ) — print 16 hex digits to UART
// Clobbers x0-x4. Uses standard C ABI (bl/ret).
printhex64:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    mov     x4, x0                     // value
    mov     x3, #60                    // bit shift start
1:  lsr     x0, x4, x3
    and     x0, x0, #0xF
    cmp     x0, #10
    blt     2f
    add     x0, x0, #('A' - 10)
    b       3f
2:  add     x0, x0, #'0'
3:  // emit char in w0
    ldr     x1, =UART_FR
4:  ldr     w2, [x1]
    tbnz    w2, #5, 4b
    ldr     x1, =UART_DR
    str     w0, [x1]
    subs    x3, x3, #4
    bge     1b
    ldp     x29, x30, [sp], #16
    ret

// puts_uart ( x0 = addr, x1 = len ) — write a string to UART
// Clobbers x0-x4.
puts_uart:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    cbz     x1, .Lputs_done
    mov     x4, x0                     // addr
    mov     x3, x1                     // len
.Lputs_loop:
    ldrb    w0, [x4], #1
    ldr     x1, =UART_FR
.Lputs_wait:
    ldr     w2, [x1]
    tbnz    w2, #5, .Lputs_wait
    ldr     x1, =UART_DR
    str     w0, [x1]
    subs    x3, x3, #1
    bne     .Lputs_loop
.Lputs_done:
    ldp     x29, x30, [sp], #16
    ret

// ═════════════════════════════════════════════════════════════════════════════
// STRING LITERALS
// ═════════════════════════════════════════════════════════════════════════════

    .section .rodata
    .balign 4

str_banner:
    .ascii  "\r\nFock v0.1  AArch64 Forth\r\n"
str_banner_end:

str_ok:
    .ascii  " ok\r\n"
str_ok_end:

str_prompt:
    .ascii  "> "
str_prompt_end:

str_err:
    .ascii  " ?\r\n"
str_err_end:

// ═════════════════════════════════════════════════════════════════════════════
// COLD START
// ═════════════════════════════════════════════════════════════════════════════
// The initial "program" — a list of word addresses that Forth executes.
// IP is set to cold_start before the first NEXT. NEXT loads word_quit,
// loads DOCOL (its codeword), and DOCOL sets IP to quit's body.
// But QUIT is a defcode (primitive), not a colon def, so we handle it
// specially: cold_start just holds quit's entry; NEXT loads its codeword
// (code_quit) and branches there directly.

    .balign 8
    .global cold_start
cold_start:
    .quad   word_kernel

// ═════════════════════════════════════════════════════════════════════════════
// ENTRY POINT
// Called from main.c after UART init.
// Sets up VM registers, patches LATEST, prints banner, enters QUIT.
// ═════════════════════════════════════════════════════════════════════════════

    .text
    .balign 4
    .global forth_main
forth_main:
    // Callee-saved registers (we never return, but keep ABI clean)
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    // Initialize Forth VM registers
    ldr     DSP, =DSTACK_TOP            // data stack pointer
    ldr     RSP, =RSTACK_TOP            // return stack pointer

    // Patch LATEST to point at the last defword in the chain.
    // 'link' is the assembler symbol holding the last defined entry address.
    // We store it into LATEST's body at runtime.
    ldr     x0, =word_latest + 32       // address of LATEST's storage cell
    ldr     x1, =word_kernel        // last defined entry (see defcode order)
    str     x1, [x0]

    // Print banner
    ldr     x0, =str_banner
    ldr     x1, =str_banner_end
    sub     x1, x1, x0
    bl      puts_uart

    // Set IP to cold_start and fire NEXT — enters QUIT
    ldr     IP, =cold_start
    NEXT

    // Never reached
    ldp     x29, x30, [sp], #16
    ret
