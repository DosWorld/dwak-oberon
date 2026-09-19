@echo off
rem Builds hxcomp.exe - the compiler compiled for the hxdos target - into the
rem repo root, which is where it is started from: on this target lib\ is
rem resolved against the CURRENT directory, not against the binary (HOST.mod
rem returns a constant for argv[0] and an empty current directory).
rem The name has to be 8.3. A longer one is not started at all - the HX loader
rem is handed the mangled name and then cannot find the file.
Compiler.exe source\Compiler.mod hxdos -out hxcomp.exe -stk 2 -fa 512
@pause
