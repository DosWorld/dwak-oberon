OC ?= boot64.exe
OC_RUN ?= wine $(OC)

.PHONY: all lin32 lin64 win32 win64 macos64 dpmi32

all: lin32 lin64 win32 win64 macos64 dpmi32

lin64: $(OC)
	$(OC_RUN) ./source/Compiler.mod linux64exe -out ./bin/l64oc -stk 2
lin32: $(OC)
	$(OC_RUN) ./source/Compiler.mod linux32exe -out ./bin/l32oc -stk 2
win64: $(OC)
	$(OC_RUN) ./source/Compiler.mod win64con -out ./bin/w64oc.exe -stk 2
win32: $(OC)
	$(OC_RUN) ./source/Compiler.mod win32con -out ./bin/w32oc.exe -stk 2
dpmi32: $(OC)
	$(OC_RUN) ./source/Compiler.mod dpmi32pe -out ./bin/D32OC.EXE -stk 2 -fa 512
macos64: $(OC)
	$(OC_RUN) ./source/Compiler.mod macos64 -out ./bin/m64oc -stk 2
