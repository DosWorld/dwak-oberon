Compiler.exe ./tools/RVMxI.mod win32con -nochk a -out RVM32I.exe
Compiler.exe source\Compiler.mod rvm32i -out Compiler32.bin -lower
RVM32I.exe Compiler32.bin -dis Compiler32.txt
RVM32I.exe Compiler32.bin -run source\Compiler.mod rvm32i -out Compiler32.bin -lower
@pause