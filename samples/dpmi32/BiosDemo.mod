MODULE BiosDemo;

(* The BIOS, reached through the same call DOS goes through.

   A protected mode program cannot execute a real mode interrupt itself, so
   lib/dpmi32 asks the DPMI host to simulate one (int 31h AX=0300h) and the
   number travels in a register: that is why DOS.Intr takes the interrupt
   number as its first argument, and why int 10h, int 11h and int 1Ah are
   reached exactly as int 21h is. Nothing here is a DOS service and nothing
   here goes through DOS.

   The console of this runtime is not built on the BIOS - it reads the cursor
   and the screen size out of the BIOS data area at 0x400 and writes video
   memory at 0xB8000 itself - so a program that wants a BIOS service has to
   ask for it, which is what this sample does.

   On the machine this was written on: the equipment word is 17511 (a colour
   adapter, one diskette, no coprocessor), the tick counter counts at 18.2 Hz
   from midnight, and the video state is mode 3 with 80 columns. *)

IMPORT SYSTEM, DOS, Out, Console;

VAR
    r: DOS.Registers;
    equ, ticks, mode, cols: INTEGER;


(* DOS.Intr reads the register record and there is no public way to clear one,
   so a service that only reads what it wants is given a record of zeroes and
   then the fields it does want. Intr fills ES and DS with the DOS block when
   the caller leaves them zero, which is what the segment fields are here. *)
PROCEDURE Zero (VAR x: DOS.Registers);
BEGIN
    x.EAX := 0; x.EBX := 0; x.ECX := 0; x.EDX := 0;
    x.ESI := 0; x.EDI := 0; x.EBP := 0; x.ESP := 0;
    x.Flags := WCHR(0); x.ES := WCHR(0); x.DS := WCHR(0);
    x.FS := WCHR(0); x.GS := WCHR(0); x.CS := WCHR(0); x.SS := WCHR(0)
END Zero;


BEGIN
    Console.open;

    Zero(r);
    DOS.Intr(11H, r);                   (* the equipment word comes back in AX *)
    equ := r.EAX MOD 10000H;
    Out.String("equipment word  ="); Out.Int(equ, 0); Out.Ln;

    Zero(r);                            (* AH=00h: the tick counter, CX:DX *)
    DOS.Intr(1AH, r);
    ticks := (r.ECX MOD 10000H) * 10000H + (r.EDX MOD 10000H);
    Out.String("ticks since boot="); Out.Int(ticks, 16);
    Out.String("  (18.2 a second)"); Out.Ln;

    Zero(r);
    r.EAX := 0F00H;                     (* AH=0Fh: the video state, AL and AH *)
    DOS.Intr(10H, r);
    mode := r.EAX MOD 256;
    cols := (r.EAX DIV 256) MOD 256;
    Out.String("video mode      ="); Out.Int(mode, 0); Out.Ln;
    Out.String("columns         ="); Out.Int(cols, 0); Out.Ln;

    Console.exit(TRUE)
END BiosDemo.
