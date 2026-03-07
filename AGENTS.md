# Fock — Agent Briefing

## What This Project Is

**Fock** is a bare-metal Nock VM implemented as a Forth kernel on AArch64 (Raspberry Pi 3/4).
The name reflects the dual nature: **Fo**rth + No**ck**.

The research thesis: a Nock 4K evaluator can run as Forth words on bare-metal AArch64, with
jets implemented as live-patchable Forth words registered in the Forth dictionary. This is
architecturally novel relative to existing Nock runtimes (Vere, Sword) which use static C jet
tables requiring recompilation.

This is a solo, unfunded research artifact. The goal is a working proof of concept, not a
production system.

## Repository Layout

```
nockout/                    ← project root (git repo)
├── Makefile                ← build system (lives here, not in src/)
├── AGENTS.md               ← this file
└── src/
    ├── boot.s              ← AArch64 entry point, core parking, BSS zero
    ├── uart.c              ← PL011 UART driver (for QEMU; real Pi needs GPIO mux)
    ├── uart.h
    ├── memory.h            ← physical memory map constants (single source of truth)
    ├── main.c              ← C entry: uart_init, stack canary, calls forth_main
    ├── forth.s             ← THE MAIN FILE: entire Forth kernel in AArch64 asm
    └── linker.ld           ← linker script, entry at 0x80000
```

## Build System

```bash
make          # build kernel8.img
make run      # run in QEMU (Ctrl-A X to quit)
make debug    # QEMU + GDB server on :1234, breaks at main
make deploy   # copy kernel8.img to /private/tftpboot for Pi netboot
make clean
```

Toolchain: `aarch64-elf-gcc`, `aarch64-elf-ld`, `aarch64-elf-objcopy`, `aarch64-elf-gdb`
Install: `brew install aarch64-elf-gcc aarch64-elf-binutils aarch64-elf-gdb qemu tio`

QEMU target: `-machine raspi3b`. UART maps to stdio via `-nographic`.

## Memory Map (src/memory.h)

```
0x00080000  kernel load address / boot stack (grows down, small)
0x00089000  TIB (terminal input buffer, 256 bytes)
0x00090000  Forth dictionary base — grows UP           (4MB)
0x00470000  Stack guard / canary (STACK_CANARY = 0xDEADF0C4)
0x00470000  Forth data stack top — grows DOWN          (64KB)
0x00480000  Forth return stack top — grows DOWN        (64KB)
0x00490000  Noun event arena base — bump alloc         (32MB)
0x02490000  Noun persistent heap base — refcounted     (64MB)
0x3F000000  MMIO (do not use for heap)
```

All addresses are absolute physical. Noun cell pointers are always absolute —
never region-relative offsets. This is deliberate: it allows the heap to grow
without rewriting existing pointers.

## AArch64 Register Conventions (src/forth.s)

**RESERVED — never clobber:**
```
x27  IP   — Instruction Pointer (next word in current definition)
x26  DSP  — Data Stack Pointer (grows down, points TO top item)
x25  RSP  — Return Stack Pointer (grows down, points TO top item)
x24  W    — Working register (current dictionary entry address)
```

**RESERVED for future noun heap (Phase 2+):**
```
x19-x23   — available for noun heap pointers, GC roots, etc.
```

**Scratch — any word may clobber:**
```
x0-x18
```

Stack push/pop convention:
```asm
// Push x0:
str x0, [DSP, #-8]!   // pre-decrement then store

// Pop into x0:
ldr x0, [DSP], #8     // load then post-increment
```

## Dictionary Entry Layout (src/forth.s)

Every word (primitive or colon definition) has this exact header:

```
offset  0 : link      [8 bytes] — pointer to previous entry (0 = end of chain)
offset  8 : flags|len [8 bytes] — low byte = name length, bits 15:8 = flags
offset 16 : name      [8 bytes] — ASCII name, zero-padded to 8 bytes (max 7 chars)
offset 24 : codeword  [8 bytes] — pointer to machine code to execute
offset 32 : body               — varies by word type (see below)
```

Flag bits (applied to the HIGH byte of the flags|len field, i.e. shifted << 8):
```
F_IMMEDIATE = 0x80
F_HIDDEN    = 0x40
```

Body interpretation:
- **defcode** (primitive): body is native AArch64 machine code, ends with NEXT
- **DOCON** words: body[0] is the constant value
- **DOVAR** words: body[0] is the variable's storage cell
- **DOCOL** words (colon defs): body is a list of entry addresses (execution tokens)

## Inner Interpreter

**NEXT macro** — dispatches to next word in current definition:
```asm
ldr  W, [IP], #8      // W = entry address at IP; IP advances by 8
ldr  x0, [W, #24]     // x0 = codeword (at entry + 24)
br   x0               // jump to codeword
```

**DOCOL** — enters a colon definition:
```asm
str  IP, [RSP, #-8]!  // push current IP to return stack
add  IP, W, #32       // IP = body of this word (W + 32)
NEXT                   // dispatch first word in body
```

**EXIT** — leaves a colon definition:
```asm
ldr  IP, [RSP], #8    // pop saved IP from return stack
NEXT                   // resume caller
```

**EXECUTE** — execute word whose entry address is on the data stack:
```asm
ldr  W, [DSP], #8     // pop entry address into W
ldr  x0, [W, #24]     // load codeword
br   x0               // dispatch (no NEXT — executed word calls its own NEXT)
```

## Assembler Macros (src/forth.s)

```asm
defcode "NAME", len, label, flags
    // Creates header + codeword pointing to immediately following asm
    // Asm code follows; must end with NEXT
    // Entry address: word_<label>
    // Code address:  code_<label>

defvar "NAME", len, label, flags, initial_value
    // Creates header with codeword = DOVAR and one storage cell
    // Executing the word pushes the ADDRESS of the storage cell
    // Storage cell address: word_<label> + 32

defconst "NAME", len, label, flags, value
    // Creates header with codeword = DOCON and one value cell
    // Executing the word pushes the VALUE
```

The `link` assembler symbol is updated by each `defword` invocation and ends up
holding the address of the last defined word. `forth_main` patches this into
LATEST's storage cell at runtime.

## QUIT Loop (the outer interpreter)

QUIT is a `defcode` (primitive), not a colon definition. It implements the
standard Forth outer interpreter:

1. Reset both stacks (also serves as ABORT target)
2. Read a line from UART into TIB (inline REFILL)
3. For each space-delimited token:
   - Search dictionary (FIND): if found, execute or compile depending on STATE
     and F_IMMEDIATE flag
   - If not found, try NUMBER: if parseable, push or compile LIT+value
   - If neither: print " ?" and restart
4. At end of line: print " ok" (if interpreting), print prompt, go to 2

**Trampoline mechanism**: When QUIT executes a word, it sets IP to
`trampoline_quit` (a cell containing `word_quit`'s address) before branching to
the codeword. This gives NEXT a valid IP to return to after the word completes,
causing it to loop back into QUIT.

## Current Status

**Phase 0: COMPLETE**
- QEMU boots, UART works, netboot configured.

**Phase 1: COMPLETE**
- REPL boots: `Fock v0.1  AArch64 Forth` banner + `> ` prompt.
- Full primitive set: arithmetic, stack ops, comparisons, memory, I/O.
- Colon definitions (`: ;`), RECURSE.
- Control flow: `IF ELSE THEN`, `BEGIN UNTIL AGAIN`, `BEGIN WHILE REPEAT`.
- `.` prints hex intentionally — decimal requires bignum (Phase 4). Do not change.

**Phase 2: COMPLETE**
- noun.h/noun.c: 4-type tagged noun, bump allocator, refcount, noun_eq.
- Forth words: `>NOUN`, `NOUN>`, `CONS`, `CAR`, `CDR`, `ATOM?`, `CELL?`, `=NOUN`.
- Bug fixed: `noun_is_atom` and `ATOM?`/`CELL?` checked bit63 only, missing direct atoms (tag=01).
  Corrected to `(n >> 62) != 0`.

**Phase 3: COMPLETE (opcodes 0–10)**
- `src/nock.c`: `slot()`, `hax()`, and `nock()` implementing opcodes 0–10.
- All TCO opcodes (2, 6, 7, 8, 9, 10-static) use `goto loop` — zero stack growth.
- `hax(a, val, target)`: recursive tree edit, mirrors `slot` path-bit traversal.
- Opcode 10: static hint (atom b → TCO eval d), dynamic/tree-edit ([b c] → hax(b, *[a c], *[a d])).
- Crash behaviour: `nock_crash()` prints to UART then `longjmp(nock_abort, 1)` back to QUIT.
- Forth words: `SLOT ( axis noun -- result )`, `NOCK ( subject formula -- product )`.

**Phase 3b: COMPLETE (op 11 + hint infrastructure)**
- Evaluator widened to `nock_eval(subject, formula, const wilt_t *jets, sky_fn_t sky)` (internal static).
- Public shims: `nock(s,f)` → `nock_eval(s,f,NULL,NULL)`; `nock_ex(s,f,jets,sky)` exposes full API.
- `src/nock.h` now exports: `sky_fn_t`, `sock_t`, `wilt_t` (WILT_MAX=16), `wilt_entry_t`, `jet_fn_t`.
- Hint tag constants (Urbit cord encoding, LSB = first char):
  `%wild`=0x646C6977, `%slog`=0x676F6C73, `%xray`=0x79617278, `%mean`=0x6E61656D, etc.
- Op 11 static hint: TCO eval d, discard atom tag.
- Op 11 dynamic hint dispatch:
  - `%wild` — `parse_wilt()` parses `$wilt` clue noun into `wild_buf` (local frame); `jets = &wild_buf`.
  - `%slog` — `uart_puts` + `noun_print()` to UART (bare-metal printf).
  - `%xray` — `noun_print()` recursive noun tree dump to UART (bare-metal noun inspector).
  - `%mean`, `%memo`, `%bout` — silent stubs; correct to no-op per spec.
  - unknown tags — silent no-op.
- `noun_print(noun, depth)`: recursive noun tree printer; depth-limited at 12; direct atoms as hex.
- `sock_match(cape, data, subject)`: structural pattern match per `$cape`/`$sock` spec.
- `parse_wilt(noun, wilt_t*)`: parses Hoon list of `[label [cape data]]` pairs.
- Hot state: `hot_state[]` array with sentinel; `hot_lookup(label)` → `jet_fn_t`. Empty until Phase 11d.
- Op 9 now checks `jets` before TCO: scans wilt for matching sock, calls jet if found.
- UART backspace fix: BS/DEL now sends `\b \b` erase sequence; echo moved after character classification
  in both `REFILL` and the inline QUIT input loop.
- Regression test suite: `tests/run_tests.sh` — 59 tests, all passing (ops 0–11 + SLOT + distribution rule).
- Note: Forth hex literals (`0x...`) are not supported by the REPL (BASE=10). Use decimal cord values in tests.

## Immediate Tasks for This Agent

- Phase 11c: populate `hot_state[]` with first real jets (`dec`, `add` as C functions).
- Phase 11d: Forth words `.JETS` (print dashboard), `.WILT` (print active registrations), jet hit counters.
- Phase 3c: DONE. `src/setjmp.h` + `src/setjmp.s`: bare-metal AArch64 setjmp/longjmp (saves
  x19–x28, x29/x30, sp; no FP regs). `jmp_buf nock_abort` established in QUIT `.Lquit_restart`
  after stack reset. `nock_crash()` longjmps there; QUIT reprints prompt and loops cleanly.
- Phase 4: bignum atoms.

## Future: Nock Evaluator in Forth (Phase 5+)

The Nock evaluator currently lives in C (`src/nock.c`) and is called from Forth via `bl nock`.
Moving it to Forth is possible and aligns with the project thesis:

- The opcode switch becomes a dispatch table of execution tokens indexed by opcode.
- `goto loop` TCO becomes `BEGIN ... AGAIN` with `EXIT` for early returns — more natural in Forth.
- Jets would then be ordinary Forth dictionary entries installed at runtime from the REPL, with no
  C recompilation or reflash required.
- **The Forth dictionary IS the jet dashboard** — a jet is just a word with the right name.
- C stays for: allocator (`noun.c`), UART, and performance-critical jets.
- Only the *dispatch logic* moves to Forth.

Do this after Phase 5, once jets are proven out and the evaluator is mostly bypassed for production code.

## Noun Representation

Every noun is a 64-bit word. The top two bits are the tag:

```
Bits 63:62  tag
  00  cell            bits 61:0 = 32-bit heap pointer to [head, tail] pair
                      bits 61:32 = 30 bits reserved (GC metadata, TBD)
  01  direct atom     bits 61:0 = value  (0 .. 2^62-1)
  10  indirect atom   bits 61:32 = low 30 bits of BLAKE3 hash (fast equality pre-check)
                      bits 31:0  = 32-bit pointer to atom struct in RAM
  11  content atom    bits 61:0  = 62-bit BLAKE3 prefix (identity IS the hash)
                      actual limb data lives in the atom store (RAM cache / SD card)
```

Heap struct for type-10 (indirect) atoms:
```c
struct atom {
    uint64_t  size;      // number of 64-bit limbs
    uint32_t  blake3[8]; // full 256-bit BLAKE3 hash (all-zero = not yet computed)
    uint64_t  limbs[];   // little-endian limb data
};
```

Tag constants (defined in `src/noun.h`):
```c
#define TAG_CELL     (0ULL << 62)
#define TAG_DIRECT   (1ULL << 62)
#define TAG_INDIRECT (2ULL << 62)
#define TAG_CONTENT  (3ULL << 62)
#define TAG_MASK     (3ULL << 62)
```

Notes:
- Direct atoms cover all values up to ~4.6×10^18 — sufficient for most Nock programs.
- Type-11 (content atom) is reserved for Phase 4b; stubs only in Phase 2.
- The 30-bit hash prefix in type-10 words is the low 30 bits of the full BLAKE3 hash,
  written once when `hash_atom()` is first called on that atom.
- For large atoms (4GB+) that cannot be RAM-resident, type-11 content addressing is
  the correct representation. The atom store hot cache maps 62-bit hash → atom struct;
  the cold store (Phase 6) backs this with SD card block I/O.

## BLAKE3 Plan

- **Hash function**: BLAKE3, truncated to 62 bits for type-11 content atoms.
- **Why BLAKE3**: Merkle tree structure allows hashing 4GB+ atoms in 1KB streaming
  chunks without full RAM residency. Same hash regardless of chunk boundaries.
- **Implementation**: Roll our own C implementation from the BLAKE3 spec (Nockchain
  uses Rust; the official reference C implementation is the closest starting point).
  Target: `src/blake3.c` + `src/blake3.h`, no libc, no SIMD required initially.
  Core is ~400 lines: G mixing function (7 rounds), chunk compression, Merkle parents.
- **When needed**: Phase 4b (after bignum arithmetic). Phase 2 allocates type-10 atoms
  with the hash field zeroed; hashing is deferred until Phase 4b.

## Phase 2 Implementation Order

```
Phase 2a  src/noun.h      — tag constants, NOUN typedef, pack/unpack macros
Phase 2b  src/noun.c      — alloc_cell(), cell_inc(), cell_dec()
                            alloc_indirect() — hash field left zero
Phase 2c  src/forth.s     — CONS, CAR, CDR, ATOM?, CELL?, =noun Forth words
Phase 2d  smoke test       — 1 2 CONS CDR . → 2 etc.
```

## Subject Knowledge Analysis (Phase 5 Design)

Reference: Afonin ~dozreg-toplud, "Subject Knowledge Analysis", UTJ Vol. 3 Issue 1.

SKA is a static analysis pass that takes a `(subject, formula)` pair and produces:
1. A **call graph** — every Nock 2/9 site annotated as *direct* (formula statically known) or *indirect*
2. A **subject mask** (`$cape`) — which axes of the subject are used *as code*

**How it works**: Run a partial Nock interpreter symbolically. Subject is `$sock = (cape, data)` where
unknown parts are stubbed with 0. Propagate known information through the formula tree. At each
Nock 2 site, if the formula operand is fully known, record the callee and enter a new analysis frame;
if not, mark the call indirect and return unknown result.

**Why it matters for Fock**:

- **Jet matching becomes compile-time**: Walk the call graph once; at each direct call site compute
  the battery hash and look it up in the Forth dictionary. If found, annotate the call with a direct
  Forth word pointer. No per-call hash lookup at runtime.
- **Direct calls**: Annotated direct calls skip the full `nock()` eval and dispatch straight to the
  callee's Forth word or compiled bytecode. Paper reports ~1.7× speedup.
- **Correct cache keying**: Cache key is `(masked_subject, formula)` not `(full_subject, formula)`.
  Without the mask, changing a counter value in the subject causes a cache miss even when the code
  hasn't changed. The mask says "only these axes matter for the call graph."
- **Nomm**: SKA output is annotated Nock where Nock 2 sites carry `info=(unit [sock formula])`.
  Our equivalent: a Forth word whose body contains direct `bl` instructions to known call targets.

**Loop handling (required, not optional)**: A naive partial evaluator loops forever on `dec`.
Must detect backedges (Tarjan SCC), defer fixpoint search to SCC exit, then validate.

**When to implement**: Phase 5. Entry point is the `%wild` hint (see Jet Architecture below).
The `$cape` boolean-tree type needs to be added to `noun.h`.

**Indirect call exceptions** (rare): over-the-wire code, Nock 12, vase-mode Hoon compiler.
All other Arvo/Gall code is fully analyzable statically.

## Jet Architecture (`%wild` + SKA — first-class citizens)

**Decided**: We do NOT implement `%fast` cold-state accumulation. It is a stateful memory leak by design.
Instead, `%wild` (UIP-0122, ~ritpub-sipsyl) is the sole jet registration mechanism.

### Why `%wild` over `%fast`

`%fast` is a side effect disguised as a hint: it mutates a global `battery_hash → label` table that
can never be safely pruned and cannot migrate between piers without re-running introduction forms.
`%wild` embeds the necessary cold-state slice *directly in the Nock*, scoped to the hinted computation.

### `%wild` clue structure

```hoon
+$  cape  $@(? [cape cape])        ::  noun mask: & = known, | = wildcard
+$  sock  [=cape data=*]           ::  core template
+$  wilt  (list [l=* s=sock])      ::  list of [label sock] registrations
```

The `%wild` dynamic hint clue is a `$wilt` noun (constant — the clue formula MUST be `[1 clue]`).
The `cape`/`sock` types are identical to those used by SKA. This is intentional — `%wild` is
essentially a way to ship SKA output (subject masks + labels) inside the Nock itself.

### Sock matching

```
match(cape, data, noun):
    cape == &(0)     →  noun == data           (exact match required)
    cape == |(1)     →  true                   (wildcard, any noun matches)
    cape is cell, noun is atom  →  false       (structural mismatch)
    cape is cell, noun is cell  →  match(cape.h, data.h, noun.h)
                                && match(cape.t, data.t, noun.t)
```

Battery position (axis 2) is always `cape=&` (must match exactly). Sample/payload is `cape=|` (wildcard).
This means a jet fires for any gate with the right battery, regardless of what's in the sample.

### Evaluator signature (target)

```c
noun nock(noun subject, noun formula, const wilt_t *jets, sky_fn_t sky);
```

- `jets`: current scoped `$wilt` registrations (NULL = none). Lives on the C stack, scoped automatically.
- `sky`: scry handler (NULL = crash on op 12). Added in Phase 3b.
- `%wild` hint fires → parse clue → pass new `wilt_t*` into recursive calls → scope exits when call returns.

### Hot state (compile-time, lives in the binary)

```c
typedef noun (*jet_fn_t)(noun core);
typedef struct { const char *label; jet_fn_t fn; } hot_entry_t;
static const hot_entry_t hot_state[] = {
    { "/dec/one/vial", jet_dec },
    { "/add/one/vial", jet_add },
    // ...
};
```

Jet functions are C (or Forth words via ABI-compatible wrapper). No dynamic registration — the hot
state is fixed at compile time. `%wild` provides the runtime bridge from label → matched core.

### Dispatch at op 9

```
op 9 fires:
    core = nock(subject, c_formula, jets, sky)
    arm  = slot(b, core)
    if jets != NULL:
        for each [label sock] in jets:
            if match(sock.cape, sock.data, core):
                jet = hot_lookup(label)
                if jet: return jet(core)   ← bypass Nock
    subject = core; formula = arm; goto loop
```

### Phase plan for jet infrastructure

| Phase | Work |
|---|---|
| **11a** | Op 11 in `nock.c`; hint dispatch table; `%wild` handler parses `$wilt` |
| **11b** | Sock matching (`noun_match`); `wilt_t` struct; pass through evaluator |
| **11c** | Op 9 dispatch hook; hot state table; first jets (`dec`, `add`) |
| **11d** | Forth words: `.JETS`, `.WILT`, jet hit counters |
| **5** | SKA: symbolic partial evaluator, annotated Nock, compile-time jet matching |

### Compatibility note

We will NOT implement `%fast` cold-state machinery. If we ever need to interop with Hoon-compiled
Nock that emits `%fast` hints, we silently ignore them (correct: `%fast` is purely advisory).
`%wild` hints from future Hoon tooling are the target.

## Architecture Decisions (do not reverse without understanding the rationale)

| Decision | Choice | Rationale |
|---|---|---|
| UART driver | PL011 at 0x3F201000 | QEMU raspi3b emulates PL011, not mini-UART |
| Atom tag scheme | 2-bit tag, 4 types | Covers direct/indirect/content; see Noun Representation |
| Large atom identity | BLAKE3 content hash (62 bits) | Enables O(1) equality, structural sharing, SD-card backing for 4GB+ atoms |
| Memory model | Arena + refcount heap | No stop-world GC; event arena reset after each +poke |
| Noun stack | Separate from Forth stacks | GC root discipline; no mixed-type stack bugs |
| Jets | `%wild` + SKA, hot state in C binary | Stateless registration; no cold-state accumulation; `%fast` intentionally NOT implemented |
| Loom/road | REJECTED | 32-bit legacy; replaced by 64-bit arena+refcount |
| Bignum | Roll our own (Phase 4) | FSL bignum is wrong license; other options unsuitable |
| BLAKE3 | Roll our own C (Phase 4b) | Nockchain is Rust; reference C impl is the base |
| Forth kernel | Hand-written AArch64 asm | No suitable MIT-licensed vendorable option |
| Kernel noun shape | Deferred | Arvo (+poke) vs Shrine (x/y/z queries) — decide before Phase 6 |

## Phase Plan Summary

| Phase | Description | Status |
|---|---|---|
| 0 | Toolchain, QEMU, Hello UART | DONE |
| 1 | Forth kernel: inner interpreter + REPL + control flow | DONE |
| 2 | Noun heap: tagged pointers, cell alloc, refcount | DONE |
| 3 | Nock 4K eval loop (opcodes 0–10, TCO, `hax`) | DONE |
| 3b | Op 11 + hint dispatch (`%wild`, `%slog`, `%xray`) + jet infrastructure | DONE |
| 3c | longjmp crash recovery (back to QUIT instead of halt) | DONE |
| 4 | Bignum atoms | TODO |
| 4b | BLAKE3 implementation + hash_atom() + intern() | TODO |
| 5 | SKA: symbolic partial eval, annotated Nock, compile-time jet matching | TODO |
| 6 | jam/cue + SD card load + atom cold store | TODO |
| 7 | Kernel loop: +poke event dispatch, effects vocabulary | TODO |
| N | North integration (parallel track) | ONGOING |

PoC gate: Phases 0-5. Everything after is "turning it into an OS."

## Key Source References in the Codebase

- `src/memory.h` — single source of truth for all region boundaries
- `src/noun.h`   — noun tag constants, NOUN typedef, pack/unpack macros (Phase 2+)
- `src/noun.c`   — cell/atom allocators, refcount (Phase 2+)
- `src/forth.s`  — Forth kernel: inner interpreter, primitives, QUIT, control flow
- `src/boot.s`   — entry at `_start`, parks cores 1-3, zeros BSS, calls `main`
- `src/uart.c`   — PL011 UART init/read/write (no GPIO mux — QEMU doesn't need it)
- `src/main.c`   — writes stack canary, calls `forth_main`

## What This Is NOT

- Not a port of any existing Forth (not lbForth, not zForth, not jonesforth)
- Not GPL-encumbered (everything is written from scratch, MIT)
- Not targeting a hosted OS (bare metal only, no libc, no syscalls)
- Not Arvo (kernel noun shape TBD; may be Shrine instead)
- Not trying to be ANS Forth compliant (standard-ish but pragmatic)
