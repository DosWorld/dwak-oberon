# Oberon-07 compiler

 Oberon-07 compiler for x64 (**Windows**, **Linux**), x86 (**Windows**, **Linux**, **KolibriOS**, **HX-DOS**), MSP430x{1,2}xx, STM32 Cortex-M3

## Links

[obGraph](https://github.com/prospero78/obGraph)

```text
Test graphics possibility
```

[additional-modules](https://github.com/VadimAnIsaev/Oberon-07-additional-modules)

```text
Additional modules
```

## Build targets

Linux

```bash
make              # Builds the compiler for Linux x64
make lin64        # -//-
make lin32        # Builds the compiler for Linux x32
make lin64sample1 # Builds and runs sample 1 for Linux x64
make lin64sample2 # Builds and runs sample 2 for Linux x64
make win64        # Builds the compiler for Windows x64
make win32        # Builds the compiler for Windows x32
make kos          # Builds the compiler for KolibriOS
make hxdos        # Builds the compiler for DOS (HX-DOS Extender), as ./hxcomp.exe
make hxdosdll     # Builds the HX-DOS sample DLL into ./bin/hxdos/
```
