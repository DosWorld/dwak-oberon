WINE ?= wine
PYTHON ?= python3
OC ?= boot64.exe
OC_RUN ?= $(WINE) $(OC)
MACOS_BOOT = .build/macos64-bootstrap.exe

.PHONY: all lin32 lin64 win32 win64 macos64 dpmi32 macos64-bootstrap

all: lin32 lin64 win32 win64 macos64 dpmi32

lin64: $(OC)
	$(OC_RUN) ./source/Compiler.mod linux64exe -out ./bin/l64comp -stk 2
lin32: $(OC)
	$(OC_RUN) ./source/Compiler.mod linux32exe -out ./bin/l32comp -stk 2
win64: $(OC)
	$(OC_RUN) ./source/Compiler.mod win64con -out ./bin/w64comp.exe -stk 2
win32: $(OC)
	$(OC_RUN) ./source/Compiler.mod win32con -out ./bin/w32comp.exe -stk 2
dpmi32: $(OC)
	$(OC_RUN) ./source/Compiler.mod dpmi32pe -out ./bin/D32COMP.EXE -stk 2 -fa 512
# Runtime and Mach-O bootstrap bindings must come from the same source version.
# The seed compiler can have an old writer even when it compiles new sources.
macos64-bootstrap: $(OC)
	mkdir -p .build
	$(OC_RUN) ./source/Compiler.mod win64con -def CPU_AMD64 -def BITS_64 -l ./lib -out ./$(MACOS_BOOT) -stk 2

macos64: macos64-bootstrap
	$(WINE) ./$(MACOS_BOOT) ./source/Compiler.mod macos64 -l ./lib -out ./.build/m64comp -stk 2
	$(PYTHON) tests/check_macho.py ./.build/m64comp
	chmod +x ./.build/m64comp
	mv -f ./.build/m64comp ./bin/m64comp
