for %%f in (samples\MSP430\*.mod) do Compiler.exe %%f msp430 -rom 2048 -ram 128
@pause
