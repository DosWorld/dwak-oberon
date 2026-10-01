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
| **Output** | PE, LE, ELF and Mach-O executables and shared libraries · raw ROM images · RVMxI bytecode |
| **Requires** | Nothing but this repository |
| **Licence** | BSD 2-Clause |

## Targets

A target is a word on the command line, not a separate build: one compiler binary
carries every back end.

| CPU | Targets |
|---|---|
| **x86-64** | `win64con` `win64gui` `win64dll` · `linux64exe` `linux64so` · `macos64` |
| **i386** | `win32con` `win32gui` `win32dll` · `linux32exe` `linux32so` · `dpmi32pe` `dpmi32dll` `dpmi32le` `dpmi32adam` |
| **ARM Cortex-M3** | `stm32cm3` |
| **MSP430x1xx/2xx** | `msp430` |
| **RVMxI bytecode** | `rvm32i` `rvm64i` |

The three `dpmi32` targets are the same 32-bit DOS program under three different
extenders, and they differ in the container the loader is handed: `dpmi32pe` is a
PE image for the HX-DOS extender, `dpmi32le` an LE image for DOS/4GW and its
contemporaries, `dpmi32adam` the `Adam` format in [`doc/ADAM.TXT`](doc/ADAM.TXT)
for DOS32. What a program may *call* is not something the container decides — the
`DOS` module asks the extender which API it answers and picks a path, so one
source runs on all three.

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
| `-out <file>` | Output file name, as a path; either separator is accepted (default: module name + target extension, beside the module) |
| `-l <path>` | Where the `lib` directory is |
| `-stub <file>` | Custom PE/LE/DOS32 stub file, in place of the target's default (`W32PE.EXE` for Windows EXE/DLL and `dpmi32dll`, `D32PE.EXE` for `dpmi32pe`, `D32LE.EXE` for `dpmi32le`, `D32ADAM.EXE` for `dpmi32adam`, all found in `lib` otherwise) |
| `-stk <size>` | Stack size in megabytes (Windows, Linux, HX-DOS, LE-DOS, DOS32) |
| `-fa <size>` | PE32 file alignment: `512` (default), `1024`, `2048` or `4096` |
| `-ver <major.minor>` | Program version (LE-DOS) |
| `-nochk <letters>` | Turn off run-time checks — pointers, types, indexes, `BYTE`, `CHR`, `WCHR` — by naming them in one word, e.g. `-nochk a` |
| `-def <name>` | Define a conditional-compilation symbol (see below) |
| `-ram` / `-rom <size>` | Memory sizes, for the microcontrollers |
| `-tab <width>` | Tab width |
| `-uses` | List the modules that were imported |
| `-upper` / `-lower` | Whether keywords may be written in lower case (default: they may) |

Running the compiler with no arguments prints the full list.

Two things worth knowing early.

The compiler looks for the `lib` directory **next to its own executable**, not next to
the file you are compiling or the directory you are standing in — `lib_path` is seeded
from the directory `argv[0]` names. `boot64.exe` sits in the root beside `lib/`, so it
just works from anywhere; a compiler built elsewhere needs `-l <dir>`, or a copy of
`lib/` beside it. On DOS that path comes from the loader, so the same holds for
`dpmi32pe` and `dpmi32adam`. `dpmi32le` is the exception: the WDOSX kernel its stub
carries answers neither of the calls that report the loaded module's name, so there
`lib\` stays relative to the current directory and the compiler has to be started from
a directory that holds it.

The output file name comes from `-out` exactly as you spell it, and either separator
works — `-out C:/tmp/x.exe` and `-out C:\tmp\x.exe` are the same path on Windows, and
non-Windows hosts accept `\` too. An i386 image records its own base name (the part
after the last separator) inside itself, so the two spellings produce the same byte for
byte result, and a path with a directory in it stores only the name, not the directory.

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

`make` rebuilds a compiler for every host from the current sources. Each image lands in
the repository root, beside the source it came from — with no `-out` the compiler writes
the image next to the module you gave it, and that is the rule this tree keeps:

| Binary | Runs on |
|---|---|
| `w64oc.exe`, `w32oc.exe` | Windows |
| `l64oc`, `l32oc` | Linux |
| `m64oc` | macOS |
| `D32OC.EXE` | DOS, under a DPMI extender |

The bootstrap cross-compiles, so one `boot64.exe` builds all six (`OC` can be
overridden to use a different seed compiler; `OC_RUN` if it needs something
other than Wine to run).

`make` on its own also has `samples-win64`, `samples-win32`, `samples-stm32`,
`samples-msp430` and `microui` for the sample programs, and a `clean` for each side. The
samples are built beside their own sources, the same way.

On macOS, verify the complete native pipeline, including self-compilation, with:

```sh
python3 tests/check_macos_compiler.py ./m64oc --self-host
```

## Repository layout

```
source/    the compiler itself — lexer, parser, semantic analysis, the CPU back ends
           (x86, x86-64, ARM, MSP430, RVMxI) and the object/format writers
           (PE, LE, ELF, Mach-O, HEX, BIN)
lib/       the run-time libraries
  common/    portable modules every target shares: Out, In, Files, Strings, CSV, Args,
             the microui GUI library (Microui, MuBase, MuRender, Font, FontFile), and
             the text-mode framework of samples/tui (Tui, TuiWin, TuiWidg, TuiDlg,
             TuiFld, TuiList, TuiTbl, TuiTree, TuiPnl, TuiMenu, TuiFile, TuiApp
             and the rest - 21 modules, which lived in that sample until
             2026-09-30 and took their `Tui` names on 2026-10-01)
  Windows/   Linux/   macOS/   dpmi32/   MSP430/   STM32CM3/   RVMxI/   Math/
samples/   example programs, one directory per target; samples/microui/ is the GUI one,
           samples/tui/ the text-mode UI one (its framework is in lib/common/, and what
           stays in the sample is the demo, the dump harness and the documents), and
           samples/itsy/ (src/ examples/ docs/ bin/) is the Forth
3/         the 16-bit and 32-bit originals the ports were made from
doc/       per-target notes, the Windows library reference, the Oberon-07 report
tools/     RVMxI, the bytecode interpreter and disassembler (does not build — see
           tools/RVMxI.txt)
tests/     the standalone probes and their notes — the array, byte-array and hash-map
           types, the LE/Mach-O readers, the link-time optimiser, and the
           check_*.py scripts that drive them
extenders/ the DOS extenders, as shipped archives
wstubs/    the unpacked extender stubs an image is built around
NET/       the DOS packet driver and TCP/IP stack the network samples need
```

`Makefile` at the root builds the compilers, one image per `make` target
(`l64oc`, `l32oc`, `w64oc.exe`, `w32oc.exe`, `D32OC.EXE`, `m64oc`) and the sample
sweeps; `samples/microui/`,
`samples/QHelp/` and `OR/` have Makefiles of their own, and `samples/itsy` has one under
`samples/itsy/src/` — `make -C samples/itsy/src`. Every image is
written beside the source it came from, so the compiler images land in the root next to
`boot64.exe` and each sample lands in its own directory.

The portable modules in `lib/common/` are written against a thin platform layer named
with an `Arch` prefix (`ArchOut`, `ArchIn`, `ArchFile`, `ArchArgs`), which holds
primitives only — the logic lives in the common module. That is how `Out` means one
file for every target, and why a program that never touches the platform directly can
be moved between Windows, Linux, macOS and DOS unchanged.

## Documentation

`doc/` mixes English and Russian; `doc/CC.txt` (conditional compilation) and
`doc/WinLib.txt` (the Windows library) are the two to start with, and each target has
notes of its own. The DOS targets have a knowledge base of their own in
[`doc/dpmi32.txt`](doc/dpmi32.txt): the four `dpmi32*` targets, the stub files
behind them, the DPMI reflection, the DOS32 API and the DOSBox-X run recipe,
with the measurements each claim rests on. `AGENTS.md` in the root describes
the conventions and the traps of this particular tree.

The microui port has its two documents in `doc/`: `doc/microui.md` is the manual
for a program that uses the library, and `doc/microui-port.md` is the porting
record — the C correspondence, how each piece was verified, the known limits and
what writing a host for another platform would take. The library itself is
[microui](https://github.com/rxi/microui) ported to Oberon-07, and it is portable
in the same way `Out` is: `lib/common/` holds it and names no operating system,
and the one platform file is `lib/Windows/MuHost.mod`.

## License

BSD 2-Clause. Derived from the Oberon-07 compiler by Anton Krotov (2018–2023);
maintained by [DosWorld](https://github.com/DosWorld).
