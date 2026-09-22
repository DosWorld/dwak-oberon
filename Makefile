OC=boot64.exe
OC_RUN=wine $(OC)

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
macos64: $(OC)
	$(OC_RUN) ./source/Compiler.mod macos64 -out ./bin/m64comp -stk 2
