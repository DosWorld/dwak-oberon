@echo off
rem Builds the HX-DOS samples into bin\hxdos\.
if not exist bin\hxdos mkdir bin\hxdos
rem The DLL lives in its own subdirectory, so the loop below does not reach it.
rem DllDemo.exe and DllStatic.exe load it, so it has to be built first.
Compiler.exe samples\HXDOS\Dll\DllLib.mod hxdosdll -out bin\hxdos\DLLLIB.DLL -stk 2 -fa 512
for %%f in (samples\HXDOS\*.mod) do Compiler.exe %%f hxdos -out bin\hxdos\%%~nf.exe -stk 2 -fa 512
@pause
