# Trinitite — Agent Briefing

## What This Project Is

**Trinitite** is a bare-metal Nock VM implemented as a Forth kernel on AArch64 (Raspberry Pi 3/4).
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

QEMU target: `-machine raspi4b`. UART maps to stdio via `-nographic`.

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

**Phase 0: COMPLETE** — QEMU boots, UART works, netboot configured.

**Phase 1: COMPLETE** — REPL, `:` `;`, full control flow. `.` prints hex (decimal needs bignum).

**Phase 2: COMPLETE** — `noun.h`/`noun.c`: tagged nouns, bump allocator, refcount.
Forth words: `>NOUN`, `NOUN>`, `CONS`, `CAR`, `CDR`, `ATOM?`, `CELL?`, `=NOUN`.

**Phase 3: COMPLETE** — `src/nock.c`: opcodes 0–10, TCO (`goto loop`), `hax()` tree edit.
`nock_crash()` longjmps to QUIT restart on fatal error.

**Phase 3b: COMPLETE** — Op 11 hint dispatch: `%wild` (jet registration), `%slog`, `%xray`.
Evaluator: `nock_eval(subject, formula, const wilt_t *jets, sky_fn_t sky)`.
`sock_match()` and `parse_wilt()` implement `$cape`/`$sock`/`$wilt` matching.
Hot state `hot_state[]`: 10 jets (dec/add/sub/mul/lth/gth/lte/gte/div/mod), keyed by label cord.

**Phases 4b/4c/4d/4e: COMPLETE** — BLAKE3 (`src/blake3.c`). Bignum (`src/bignum.c`):
add/sub/mul/div/mod/cmp/lsh/rsh/or/and/xor/bex/met, decimal print. Noun tag redesign:
direct atom = raw integer (bit 63 = 0).

**Phase 5a/5b/5c/5d: COMPLETE** — Jam/cue (`src/jam.c`). PILL loader (0x10000000).
Hot jets wired.

**Phase 7: COMPLETE** — Kernel loop: Arvo + Shrine shapes, UART framing, effect dispatch.
PILL v2 format. Forth words: `KSHAPE`, `RECV-NOUN`, `SEND-NOUN`, `DISPATCH-FX`,
`ARVO-LOOP`, `SHRINE-LOOP`, `KERNEL`.
CI: QEMU 9.2.0 from source (raspi4b).

## Immediate Tasks for This Agent

Phase 9 is complete (all 411 tests passing). The PoC gate (Phases 0–9) is cleared.
The Forth dictionary IS the jet dashboard — thesis demonstrated.

Next priorities:
- **Phase 10**: North integration (pending external dependency)
- **Phase 11**: SKA Phase 2 / full Hoon subset
- **Phase 12**: Large atom cold store (SD card backing)

## SKA Layer Relationship

SKA sits between the Forth layer and the Nock evaluator, as a one-time analysis pass at load time:

```
PILL load
    │
    ▼
ska_analyze(kernel, formula)         ← runs ONCE at boot
    │  produces nomm-1 AST (C structs on heap)
    │  %ds2 sites wired to hot_state[] fn pointers
    ▼
cached by formula in a hash map
    │
    ▼
Forth KERNEL word → NOCK word → nock_eval()
                                    │
                         checks SKA cache
                          ┌───────────┤
                        hit           miss
                          │           │
                     run_nomm1()   nock_eval() as before
                          │
               %ds2 → direct C call (no sock_match)
               %i2  → nock_eval() fallback
```

**The Forth layer does not change structurally** — only two new words are added.
**`%wild` and SKA are complementary**: `%wild` provides runtime subject knowledge
(which batteries are present); SKA uses that to classify every call site statically.

**Phase 9** goes further: the `cook` pass resolves `%ds2` sites to Forth dictionary
entries by label, not `hot_state[]` C pointers. A jet becomes a named Forth word.
Redefine the word at the REPL → the next `SKA` call rewires the call site immediately.

## Phase 9 — Forth as Jet Dashboard

In Phase 9, jets are ordinary Forth dictionary entries. The `cook` pass looks up the
label cord in the Forth dictionary instead of (or before) `hot_state[]`. This gives:

- **Live-patchable jets**: redefine a word at the REPL → immediately available.
- **No recompilation**: add/change jets without reflashing.
- **Introspection**: `.SKA` prints every `%ds2` site and which Forth word it calls.
- **The Forth dictionary IS the jet dashboard** — this is the thesis.

C stays for: allocator (`noun.c`), UART, performance-critical inner-loop jets.
Only the *dispatch decision* moves to Forth.

### `%tame` Hint

A new hint `%tame` embeds Forth jet source directly in a Nock program:

```
%tame clue = [label forth-source]    (cord × cord)
```

When `%tame` fires:
1. Check `find_by_cord(label)` — if already defined, skip (idempotent).
2. Otherwise call `forth_eval_string(forth-source)` to compile the word live.

`%tame` carries only the *definition*. `%wild` carries the *identity* (`$sock`).

### `%tame` + `%wild` Two-Hint Pattern

```hoon
~>  %tame.[label forth-source]   :: outer: compile the Forth word
~>  %wild.wilt                   :: inner: scope label→sock for computation
computation
```

Nock representation: `[11 [%tame clue-t] [11 [%wild clue-w] d]]`

Evaluation order (outer-first):
1. `%tame` fires → Forth word compiled into dictionary
2. `%wild` fires → wilt `(label → sock)` scoped over `d`
3. `d` evaluates → op 9 → `nock_op9_continue` finds label in wilt →
   `find_by_cord` finds the Forth word → ABI bridge calls it

`%wild` is **unchanged**. `%tame` is strictly additive. Programs using only `%wild`
with `hot_state[]` jets continue to work without modification.

### ABI Bridge

```c
noun forth_call_jet(dict_entry_t *entry, noun core,
                    const wilt_t *jets, sky_fn_t sky);
```

Convention: push `core` onto DSP (x26), dispatch to codeword, pop result.
Context `jets`/`sky` passed via C-visible globals to avoid disrupting the stack frame.

### cook_find_jet Priority

```
1. find_by_cord(label) → Forth dict  (live-defined words win)
2. hot_lookup(label)   → hot_state[] (static C fallback)
```

**First-call timing**: cook runs before `run_nomm1` evaluates. On first call `%tame`
has not fired; `find_by_cord` returns NULL; DS2 site falls back to `nock_op9_continue`
(correct). Pre-wiring kicks in on subsequent calls once the formula cache (Stage 9g) exists.

### Stage Plan

| Stage | Description |
|-------|-------------|
| **8a** | `find_by_cord(cord) → entry*`: Forth dict search by uint64 label cord, exported as C-callable |
| **8b** | ABI bridge: `forth_call_jet(entry*, noun, jets, sky) → noun` — push/pop DSP |
| **8c** | `cook_find_jet` in `ska.c`: check `find_by_cord` before `hot_state[]` |
| **8d** | `.SKA` updated to print Forth word name at each jetted `%ds2` site |
| **8e** | `forth_eval_string(src, len)`: C-callable Forth text evaluator; `setjmp` error guard |
| **8f** | `%tame` hint handler: parse clue, idempotency guard, call `forth_eval_string` |
| **8g** | `TIMER@` + SKA formula cache + benchmark word |

## Noun Representation

Every noun is a 64-bit word. The top two bits are the tag:

```
Bits 63:62  tag
  00  cell            bits 61:0 = 32-bit heap pointer to [head, tail] pair
                      bits 61:32 = 30 bits reserved (GC metadata, TBD)
  01  direct atom     bit 63 = 0; bits 62:0 = value  (0 .. 2^63-1)
  10  indirect atom   bits 61:0 = 62-bit BLAKE3 hash of limb data (identity IS the hash)
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
Direct atom boundary: direct atoms cover all values up to ~9.2×10^18 (2^63-1).
- Type-11 (content atom) is reserved for Phase 4b; stubs only in Phase 2.
- The 30-bit hash prefix in type-10 words is the low 30 bits of the full BLAKE3 hash,
  written once when `hash_atom()` is first called on that atom.
- For large atoms (4GB+) that cannot be RAM-resident, type-11 content addressing is
  the correct representation. The atom store hot cache maps 62-bit hash → atom struct;
  the cold store (Phase 7) backs this with SD card block I/O.

## Subject Knowledge Analysis (Phase 8)

Reference: [`dozreg-toplud/ska`](https://github.com/dozreg-toplud/ska) — `desk/lib/skan.hoon`
(2300 lines), `desk/sur/noir.hoon` (types), `desk/sur/sock.hoon` (`$cape`/`$sock`).
Paper: Afonin ~dozreg-toplud, "Subject Knowledge Analysis", UTJ Vol. 3 Issue 1.

### Algorithm overview

**Input**: `(subject: sock, formula: *)` — partial knowledge of the subject + the formula.

**Pass 1 — `scan`**: Symbolic partial evaluator. For each opcode, propagates `sock`
(partial knowledge of the noun at that point):
- `%0 ax` → `sock_pull(sub, ax)` — extract knowledge of sub-noun at axis
- `%1 val` → known constant
- `%6 c y n` → `sock_purr(prod_y, prod_n)` — intersection of branches
- `%7 p q` → compose — `prod_p` becomes subject for `q`
- `%9 ax f` → desugar to `[%7 f %2 [%0 1] %0 ax]`

For `%2 p q` — the key case:
- If `cape(prod_q) ≠ &` (formula expression not fully known): emit **`%i2`** (indirect)
- If formula known: check memo cache → check melo (within-cycle) cache →
  check loop heuristic (`close()`) → recurse and emit **`%ds2`** or **`%dus2`**

**Loop detection** (`close()` heuristic): When the same formula appears in the current
call stack with a compatible subject, guess it's a back-edge. Record the parent-kid pair
in `cycles`. On cycle exit, validate the assumption: the differing parts of the subject
must NOT be used as code. If wrong, add the pair to `block_loop` and **redo** the scan.
This correctly handles `dec`, `add`, and all tail-recursive Hoon gates.

**Pass 2 — `cook`**: Converts `nomm` → `nomm-1`. Resolves `%ds2`/`%dus2` site
references to concrete `[less-sock, formula]` pairs. Matches against `hot_state[]`
by label → stores `jet_fn_t` pointer.

### Key types

```c
// $cape: boolean tree mask (& = known, | = wildcard)
typedef struct cape_s cape_t;
struct cape_s { bool is_atom; union { bool known; struct { cape_t *h, *t; }; }; };

// $sock: partial knowledge of a noun
typedef struct { cape_t *cape; noun data; } sock_t;

// $bell: call site identity
typedef struct { sock_t bus; noun fol; } bell_t;

// $nomm: annotated Nock AST (Nock-2 split into three variants)
typedef enum {
    NOMM_0, NOMM_1, NOMM_I2, NOMM_DS2, NOMM_DUS2,
    NOMM_3, NOMM_4, NOMM_5, NOMM_6, NOMM_7,
    NOMM_10, NOMM_S11, NOMM_D11, NOMM_12
} nomm_tag_t;
```

### What we are NOT porting

- `%fast` hint processing — `%fast` is intentionally ignored; `%wild` is sole mechanism
- `$source` provenance tracking — use conservative `cape = &` initially; optimize later
- `++find-args` argument minimization — optimization, not needed for correctness
- Tarjan SCC (`++find-sccs`) — only used by `find-args`, not main scan/cook flow
- `++ka.rout` queue management — driven by `%fast` cold state discovery

## Jet Architecture (`%wild` + SKA — first-class citizens)

**Decided**: We do NOT implement `%fast` cold-state accumulation. It is a stateful memory
leak by design. Instead, `%wild` (UIP-0122, ~ritpub-sipsyl) is the sole jet registration
mechanism. `%wild` embeds cold-state directly in the Nock, scoped to the hinted computation.

### `%wild` clue structure

```hoon
+$  cape  $@(? [cape cape])        ::  noun mask: & = known, | = wildcard
+$  sock  [=cape data=*]           ::  core template
+$  wilt  (list [l=* s=sock])      ::  list of [label sock] registrations
```

The `cape`/`sock` types are identical to those used by SKA. `%wild` is essentially a way
to ship SKA output (subject masks + labels) inside the Nock itself.

### Sock matching

```
match(cape, data, noun):
    cape == &  →  noun == data           (exact match required)
    cape == |  →  true                   (wildcard)
    cape is cell, noun is atom  →  false
    cape is cell, noun is cell  →  match(h, h) && match(t, t)
```

Battery (axis 2) is always `cape=&`. Sample/payload is `cape=|`.
A jet fires for any gate with the right battery, regardless of sample.

### Dispatch at op 9 (current — runtime sock_match)

```
core = nock(subject, c_formula, jets, sky)
arm  = slot(b, core)
if jets != NULL:
    for each [label sock] in jets:
        if sock_match(sock.cape, sock.data, core):
            jet = hot_lookup(label)
            if jet: return jet(core)   ← bypass Nock
subject = core; formula = arm; goto loop
```

### Dispatch at op 9 (Phase 8 — SKA annotated)

```
core = run_nomm1(subject, c_nomm1, ...)  // %ds2 already resolved to jet_fn_t
// no sock_match needed — analysis already wired direct call sites
```

## Architecture Decisions (do not reverse without understanding the rationale)

| Decision | Choice | Rationale |
|---|---|---|
| UART driver | PL011 at 0x3F201000 | QEMU raspi4b emulates PL011, not mini-UART |
| Atom tag scheme | bit 63 = 0 → direct; tag 10 → indirect; tag 11 → cell | Direct atoms are raw integers; simplifies arithmetic |
| Large atom identity | BLAKE3 content hash (62 bits) | O(1) equality, structural sharing, SD-card backing for 4GB+ atoms |
| Memory model | Arena + refcount heap | No stop-world GC; event arena reset after each +poke |
| Jets | `%wild` + SKA, hot state in C binary | Stateless registration; no cold-state accumulation; `%fast` intentionally NOT implemented |
| SKA loop detection | Heuristic stack scan + frond validation + redo | Matches skan.hoon; no Tarjan SCC needed for main flow |
| Loom/road | REJECTED | 32-bit legacy; replaced by 64-bit arena+refcount |
| Bignum | Roll our own (Phase 4) | FSL bignum is wrong license; other options unsuitable |
| BLAKE3 | Roll our own C (Phase 4b) | Nockchain is Rust; reference C impl is the base |
| Forth kernel | Hand-written AArch64 asm | No suitable MIT-licensed vendorable option |
| Kernel noun shape | Both Arvo and Shrine supported | Shape byte in PILL header selects at load time |

## Phase Plan Summary

| Phase | Description | Status |
|---|---|---|
| 0 | Toolchain, QEMU, Hello UART | DONE |
| 1 | Forth kernel: inner interpreter + REPL + control flow | DONE |
| 2 | Noun heap: tagged pointers, cell alloc, refcount | DONE |
| 3 | Nock 4K eval loop (opcodes 0–10, TCO, `hax`) | DONE |
| 3b | Op 11 + hint dispatch (`%wild`, `%slog`, `%xray`) + jet infrastructure | DONE |
| 3c | longjmp crash recovery (back to QUIT instead of halt) | DONE |
| 4b | BLAKE3 implementation + `hash_atom()` | DONE |
| 4c/d/e | Bignum: add/sub/mul/div/mod/cmp/bit-ops, decimal print | DONE |
| 5a | jam/cue (noun serialization) | DONE |
| 5b | Hot jets: dec/add/sub/mul/lth/gth/lte/gte/div/mod | DONE |
| 5c | PILL loader (QEMU file loader at 0x10000000) | DONE |
| 5d | Noun tag redesign (direct atom = raw integer) | DONE |
| 7 | Kernel loop: Arvo + Shrine shapes, UART framing, effect dispatch | DONE |
| CI | QEMU raspi4b + 411 tests (REPL + Nock reference + crash recovery + SKA coverage inc. op2 all sub-cases) | DONE |
| 8 | SKA: symbolic partial eval, `$nomm` AST, compile-time jet matching | DONE |
| 9 | Forth as jet dashboard: evaluator dispatch in dictionary | DONE |

PoC gate: Phases 0–9 all DONE. **411 tests passing.** Next: Phases 10+ (pending external deps).

## Key Source References in the Codebase

- `src/memory.h`   — single source of truth for all region boundaries
- `src/noun.h`     — noun tag constants, NOUN typedef, pack/unpack macros
- `src/noun.c`     — cell/atom allocators, refcount
- `src/nock.c`     — Nock 4K evaluator, op 11 hints, `%wild` dispatch, hot jets
- `src/ska.h`      — SKA types: `cape_t`, `sock_t`, `nomm_t`, `bell_t`, `short_t`, `long_t` (Phase 8+)
- `src/ska.c`      — SKA scan/cook passes, cape/sock ops (Phase 8+)
- `src/forth.s`    — Forth kernel: inner interpreter, primitives, QUIT, control flow
- `src/boot.s`     — entry at `_start`, parks cores 1-3, zeros BSS, calls `main`
- `src/uart.c`     — PL011 UART init/read/write
- `src/main.c`     — writes stack canary, calls `forth_main`

## What This Is NOT

- Not a port of any existing Forth (not lbForth, not zForth, not jonesforth)
- Not GPL-encumbered (everything is written from scratch, MIT)
- Not targeting a hosted OS (bare metal only, no libc, no syscalls)
- Not Arvo (kernel noun shape TBD; may be Shrine instead)
- Not trying to be ANS Forth compliant (standard-ish but pragmatic)
