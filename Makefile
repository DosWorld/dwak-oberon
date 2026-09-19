lin64:
	./compiler ./source/Compiler.mod linux64exe -out ./bin/compiler -stk 2
lin32:
	./compiler ./source/Compiler.mod linux32exe -out ./bin/compiler32 -stk 2
lin64sample1:
	./compiler ./samples/linux/hello.mod linux64exe -out ./bin/hello -stk 2
	./bin/hello
lin64sample2:
	./compiler ./samples/linux/x11/animation.mod linux64exe -out ./bin/animation -stk 2
	./bin/animation
win64:
	./compiler ./source/Compiler.mod win64con -out ./bin/Compiler.exe -stk 2
win32:
	./compiler ./source/Compiler.mod win32con -out ./bin/Compiler32.exe -stk 2
kos:
	./compiler ./source/Compiler.mod kosexe -out ./bin/Compiler.kex -stk 2
hxdos:
	./compiler ./source/Compiler.mod hxdos -out ./hxcomp.exe -stk 2 -fa 512
hxdosdll:
	mkdir -p ./bin/hxdos
	./compiler ./samples/HXDOS/Dll/DllLib.mod hxdosdll -out ./bin/hxdos/DLLLIB.DLL -stk 2 -fa 512
hxdossamples: hxdosdll
	for f in ./samples/HXDOS/*.mod; do \
	    ./compiler $$f hxdos -out ./bin/hxdos/`basename $$f .mod`.exe -stk 2 -fa 512 || exit 1; \
	done
