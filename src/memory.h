#pragma once

/*
 * Fock physical memory map
 * RPi 3: 1GB RAM (0x00000000 - 0x3FFFFFFF)
 * MMIO:  0x3F000000 - 0x3FFFFFFF (reserved, do not use)
 *
 * All addresses are absolute physical. Store absolute pointers
 * in noun cells — never region-relative offsets.
 */

/* Forth region: dictionary grows up, stacks grow down */
#define FORTH_BASE          0x00090000
#define FORTH_SIZE          0x00400000  /* 4MB */
#define FORTH_TOP           (FORTH_BASE + FORTH_SIZE)

/* Forth stacks at top of region, growing down */
#define RSTACK_TOP          (FORTH_TOP)
#define RSTACK_SIZE         0x00010000  /* 64KB return stack */
#define DSTACK_TOP          (RSTACK_TOP - RSTACK_SIZE)
#define DSTACK_SIZE         0x00010000  /* 64KB data stack */
#define DSTACK_GUARD        (DSTACK_TOP - DSTACK_SIZE)

/* Dictionary grows up from FORTH_BASE */
#define DICT_BASE           FORTH_BASE
#define DICT_TOP            DSTACK_GUARD  /* must not cross this */

/* Noun event arena: bump allocator, reset after each +poke */
#define ARENA_BASE          0x00490000
#define ARENA_SIZE          0x02000000  /* 32MB */
#define ARENA_TOP           (ARENA_BASE + ARENA_SIZE)

/* Noun persistent heap: refcounted cells and bignums */
#define HEAP_BASE           0x02490000
#define HEAP_SIZE           0x04000000  /* 64MB */
#define HEAP_TOP            (HEAP_BASE + HEAP_SIZE)

/*
 * Stack canary value — written to DSTACK_GUARD on boot.
 * Checked in error handler. If overwritten, stack has overflowed
 * into the dictionary.
 */
#define STACK_CANARY        0xDEADF0C4

/* Sanity check: heap must not reach MMIO */
#if (HEAP_BASE + HEAP_SIZE) > 0x3F000000
#error "Heap region overlaps MMIO"
#endif
