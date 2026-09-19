(*

Example for LaunchPad MSP-EXP430G2 Rev1.5

  Blinks the green LED.
  When the P1.3 button is pressed, the red LED is turned on/off.

*)

MODULE Button;

IMPORT SYSTEM, MSP430;


CONST

    REDLED   = {0};
    GREENLED = {6};
    BUTTON   = {3};

    (* port P1 registers *)
    P1OUT = 21H;
    P1DIR = 22H;
    P1IFG = 23H;
    P1IE  = 25H;
    P1REN = 27H;


PROCEDURE test_bits (mem: INTEGER; bits: SET): SET;
VAR
    b: BYTE;

BEGIN
    SYSTEM.GET(mem, b)
    RETURN bits * BITS(b)
END test_bits;


PROCEDURE set_bits (mem: INTEGER; bits: SET);
VAR
    b: BYTE;

BEGIN
    SYSTEM.GET(mem, b);
    SYSTEM.PUT8(mem, BITS(b) + bits)
END set_bits;


PROCEDURE clr_bits (mem: INTEGER; bits: SET);
VAR
    b: BYTE;

BEGIN
    SYSTEM.GET(mem, b);
    SYSTEM.PUT8(mem, BITS(b) - bits)
END clr_bits;


PROCEDURE inv_bits (mem: INTEGER; bits: SET);
VAR
    b: BYTE;

BEGIN
    SYSTEM.GET(mem, b);
    SYSTEM.PUT8(mem, BITS(b) / bits)
END inv_bits;


(* interrupt handler *)
PROCEDURE int (priority: INTEGER; interrupt: MSP430.TInterrupt);
BEGIN
    IF priority = 18 THEN                          (* interrupt from port P1 *)
        IF test_bits(P1IFG, BUTTON) = BUTTON THEN  (* button pressed *)
            inv_bits(P1OUT, REDLED);               (* toggle the LED *)
            MSP430.Delay(500);                     (* delay to let the button release *)
            clr_bits(P1IFG, BUTTON)                (* clear the interrupt flag *)
        END
    END
END int;


PROCEDURE main;
BEGIN
    (* initialize the port P1 registers *)
    SYSTEM.PUT8(P1DIR, REDLED + GREENLED);  (* output *)
    set_bits(P1REN, BUTTON);                (* enable the pull-up resistor *)
    set_bits(P1OUT, BUTTON);                (* pull up to power *)
    set_bits(P1IE,  BUTTON);                (* enable interrupts from the button *)

    MSP430.SetIntProc(int);  (* set the interrupt handler *)
    MSP430.EInt;             (* enable interrupts *)

    (* infinite loop *)
    WHILE TRUE DO
        inv_bits(P1OUT, GREENLED); (* toggle the LED *)
        MSP430.Delay(800)          (* delay *)
    END
END main;


BEGIN
    main
END Button.
