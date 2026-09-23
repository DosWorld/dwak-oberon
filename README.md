# DWAK Oberon

**A self-hosting Oberon-07 compiler for 18 targets — one repository, no external toolchain.**

The compiler is written in Oberon-07 and compiles itself. Point it at a `.mod` file and
it emits a native executable for anything from 64-bit Windows to an MSP430 with 2 KB of
ROM. Everything is here: the sources, the run-time library for every target, the
samples, and a prebuilt bootstrap binary that starts the chain off. There is no C
compiler in the loop, nothing to install, nothing to configure.

Clone the repository, and you have a working Oberon compiler.

| | |
|---|---|
| **Language** | Oberon-07 — the [2016 report](doc/Oberon07.Report_2016_05_03.pdf), plus the compiler's own extensions |
| **Implemented in** | Oberon-07; the compiler is its own largest test case |
| **Hosts** | Windows x86/x64 · Linux x86/x64 · macOS x64 · DOS (DPMI) |
| **Output** | PE, ELF and Mach-O executables and shared libraries · raw ROM images · RVMxI bytecode |
| **Requires** | Nothing but this repository |
| **Licence** | BSD 2-Clause |

## Targets

A target is a word on the command line, not a separate build: one compiler binary
carries every back end.

| CPU | Targets |
|---|---|
| **x86-64** | `win64con` `win64gui` `win64dll` · `linux64exe` `linux64so` · `macos64` |
| **i386** | `win32con` `win32gui` `win32dll` · `linux32exe` `linux32so` · `dpmi32pe` `dpmi32dll` `dpmi32le` |
| **ARM Cortex-M3** | `stm32cm3` |
| **MSP430x1xx/2xx** | `msp430` |
| **RVMxI bytecode** | `rvm32i` `rvm64i` |

The last two emit bytecode for the small virtual machine in [`tools/`](tools) rather
than machine code: a portable target that runs wherever that interpreter has been
built, and a way to watch a program work one instruction at a time.

## Hello, Oberon

```oberon
MODULE Hello;

IMPORT Out;

BEGIN
    Out.String("Hello, world!");
    Out.Ln
END Hello.
```

`boot64.exe`, in the repository root, is the bootstrap compiler — a Windows x64 binary
that is already built and already committed. From the repository root:

```
boot64.exe Hello.mod win64con
```

```
DWAK Oberon Compiler v1.70 (64-bit) 23-Sep-2026. Copyright (c) 2026, DosWord ...
compiling (1) API (SYSTEM)
compiling (2) RTL (SYSTEM)
compiling (3) WINAPI (SYSTEM)
compiling (4) ArchOut (SYSTEM)
compiling (5) Out (SYSTEM)
compiling (6) Hello
1520 lines, 0.00 sec, 8192 bytes
```

The compiler says which modules it pulled in, how much source it read and what it
wrote. `Hello.exe` is now beside the source:

```
>Hello.exe
Hello, world!
```

The output name defaults to the module name with the target's extension; `-out`
overrides it. Change `win64con` to `linux64exe` and the same file compiles for Linux —
the `Out` that ends up in the image is a different one, and the source does not care.

## Compiling your own program

```
Compiler <main module> <target> [options]
```

`<main module>` is the `.mod` file holding the program — the one whose module body runs
first. The modules it imports are found next to it, then in the target's library, then
in the portable one, so `IMPORT Out` just works.

The options you will actually reach for:

| Option | Effect |
|---|---|
| `-out <file>` | Output file name (default: module name + target extension) |
| `-l <path>` | Where the `lib` directory is |
| `-stk <size>` | Stack size in megabytes |
| `-nochk <letters>` | Turn off run-time checks — pointers, types, indexes, `BYTE`, `CHR`, `WCHR` — by naming them in one word, e.g. `-nochk a` |
| `-def <name>` | Define a conditional-compilation symbol (see below) |
| `-ram` / `-rom <size>` | Memory sizes, for the microcontrollers |
| `-uses` | List the modules that were imported |
| `-upper` / `-lower` | Whether keywords may be written in lower case (default: they may) |

Running the compiler with no arguments prints the full list.

One thing worth knowing early: the compiler looks for the `lib` directory **next to its
own executable**, not next to the file you are compiling or the directory you are
standing in. `boot64.exe` sits in the root beside `lib/`, so it just works; the
compilers in `bin/` need `-l lib` (run from the root), or a copy of `lib/` beside them.

## One source, many targets

The language has conditional compilation built in, and the run-time library leans on it
heavily — but you can use it too:

```oberon
MODULE Greet;

IMPORT Out;

BEGIN
$IF (WINDOWS)
    Out.String("Hello from Windows")
$ELSIF (LINUX)
    Out.String("Hello from Linux")
$ELSE
    Out.String("Hello from somewhere else")
$END;
    Out.Ln
END Greet.
```

A symbol is a target name, a word you passed with `-def`, or one of the predefined ones
(`WINDOWS`, `LINUX`, `MACOS`, `DOS`, `DPMI32`, `CPU_I386`, `CPU_AMD64`, `BITS_16/32/64`,
`REAL_32/64`). An unknown symbol is silently false. [`doc/CC.txt`](doc/CC.txt) has the
grammar.

## Building the compilers

`make` rebuilds a compiler for every host from the current sources.

The results land in `bin/`:

| Binary | Runs on |
|---|---|
| `bin/w64comp.exe`, `bin/w32comp.exe` | Windows |
| `bin/l64comp`, `bin/l32comp` | Linux |
| `bin/m64comp` | macOS |
| `bin/D32COMP.EXE` | DOS, under a DPMI extender (`bin/DPMILD32.EXE`, `bin/HDPMI32.EXE`) |

The bootstrap cross-compiles, so one `boot64.exe` builds all six. Since the compiler
compiles itself, the whole thing is one long fixpoint: `source/` → a compiler → the
same compiler → the same binary, byte for byte.

## Repository layout

```
source/    the compiler itself — lexer, parser, semantic analysis, the CPU back ends
           (x86, x86-64, ARM, MSP430, RVMxI) and the object/format writers
           (PE, ELF, Mach-O, HEX, BIN)
lib/       the run-time libraries
  common/    portable modules every target shares: Out, In, Files, Strings, CSV, Args
  Windows/   Linux/   macOS/   dpmi32/   MSP430/   STM32CM3/   RVMxI/   Math/
samples/   example programs, one directory per target
doc/       per-target notes, the Windows library reference, the Oberon-07 report
tools/     RVMxI, the bytecode interpreter and disassembler
bin/       the built compilers
```

The portable modules in `lib/common/` are written against a thin platform layer named
with an `Arch` prefix (`ArchOut`, `ArchIn`, `ArchFile`, `ArchArgs`), which holds
primitives only — the logic lives in the common module. That is how `Out` means one
file for every target, and why a program that never touches the platform directly can
be moved between Windows, Linux, macOS and DOS unchanged.

## Documentation

`doc/` mixes English and Russian; `doc/CC.txt` (conditional compilation) and
`doc/WinLib.txt` (the Windows library) are the two to start with, and each target has
notes of its own. `AGENTS.md` in the root describes the conventions and the traps of
this particular tree.

## License

BSD 2-Clause. Derived from the Oberon-07 compiler by Anton Krotov (2018–2023);
maintained by [DosWorld](https://github.com/DosWorld).
