lin64:
	./compiler ./source/Compiler.ob07 linux64exe -out ./bin/compiler -stk 2
lin32:
	./compiler ./source/Compiler.ob07 linux32exe -out ./bin/compiler32 -stk 2
lin64sample1:
	./compiler ./samples/linux/hello.ob07 linux64exe -out ./bin/hello -stk 2
	./bin/hello
lin64sample2:
	./compiler ./samples/linux/x11/animation.ob07 linux64exe -out ./bin/animation -stk 2
	./bin/animation
win64:
	./compiler ./source/Compiler.ob07 win64con -out ./bin/Compiler.exe -stk 2
win32:
	./compiler ./source/Compiler.ob07 win32con -out ./bin/Compiler32.exe -stk 2
kos:
	./compiler ./source/Compiler.ob07 kosexe -out ./bin/Compiler.kex -stk 2
hxdos:
	./compiler ./source/Compiler.ob07 hxdos -out ./hxcomp.exe -stk 2 -fa 512
hxdosdll:
	mkdir -p ./bin/hxdos
	./compiler ./samples/HXDOS/Dll/DllLib.ob07 hxdosdll -out ./bin/hxdos/DLLLIB.DLL -stk 2 -fa 512
