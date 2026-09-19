(*

Example for LaunchPad MSP-EXP430G2 Rev1.5

  Blinks the red LED.

*)
MODULE Blink;

IMPORT SYSTEM, MSP430;


CONST

    REDLED = {0};

    (* port P1 registers *)
    P1OUT = 21H;
    P1DIR = 22H;


PROCEDURE inv_bits (mem: INTEGER; bits: SET);
VAR
    b: BYTE;

BEGIN
    SYSTEM.GET(mem, b);
    SYSTEM.PUT8(mem, BITS(b) / bits)
END inv_bits;


BEGIN
    (* initialize the P1DIR register *)
    SYSTEM.PUT8(P1DIR, REDLED);

    (* infinite loop *)
    WHILE TRUE DO
        (* toggle the LED *)
        inv_bits(P1OUT, REDLED);
        (* delay *)
        MSP430.Delay(800)
    END
END Blink.
