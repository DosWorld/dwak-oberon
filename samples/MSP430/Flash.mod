(*

Example for LaunchPad MSP-EXP430G2 Rev1.5

  Flash memory write.
  On successful completion, the green LED is turned on,
  otherwise the red one.

*)

MODULE Flash;

IMPORT SYSTEM, MSP430;


CONST

    REDLED   = {0};
    GREENLED = {6};

    (* port P1 registers *)
    P1OUT = 21H;
    P1DIR = 22H;

    FERASE = {1};  (* "erase" mode *)
    FWRITE = {6};  (* "write" mode *)


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


(*
    erase and write flash memory
    adr   - address
    value - value to write
    mode  - mode (erase/write)
*)
PROCEDURE Write (adr, value: INTEGER; mode: SET);
CONST
    (* watchdog timer *)
    WDTCTL = 0120H;
        WDTHOLD  = {7};
        WDTPW    = {9, 11, 12, 14};

    (* flash controller registers *)
    FCTL1 = 0128H;
        ERASE = {1};
        WRT   = {6};

    FCTL2 = 012AH;
        FN0 = {0};
        FN1 = {1};
        FN2 = {2};
        FN3 = {3};
        FN4 = {4};
        FN5 = {5};
        FSSEL0 = {6};
        FSSEL1 = {7};

    FCTL3 = 012CH;
        LOCK = {4};

    FWKEY = {8, 10, 13, 15};

VAR
    wdt: SET;

BEGIN
    IF (mode = ERASE) OR (mode = WRT) THEN         (* check the requested mode *)
        SYSTEM.GET(WDTCTL, wdt);                   (* save the watchdog timer register value *)
        SYSTEM.PUT(WDTCTL, WDTPW + WDTHOLD);       (* stop the watchdog timer *)
        SYSTEM.PUT(FCTL2, FWKEY + FSSEL1 + FN0);   (* flash controller clock = SMCLK, divider = 2 *)
        SYSTEM.PUT(FCTL3, FWKEY);                  (* clear the LOCK flag *)
        SYSTEM.PUT(FCTL1, FWKEY + mode);           (* set the mode (write or erase) *)
        SYSTEM.PUT(adr, value);                    (* write *)
        SYSTEM.PUT(FCTL1, FWKEY);                  (* clear the mode *)
        SYSTEM.PUT(FCTL3, FWKEY + LOCK);           (* set LOCK *)
        SYSTEM.PUT(WDTCTL, WDTPW + wdt * {0..7})   (* restore the watchdog timer *)
    END
END Write;


(* error handler *)
PROCEDURE trap (modNum, modName, err, line: INTEGER);
BEGIN
    set_bits(P1OUT, REDLED) (* turn on the red LED *)
END trap;


PROCEDURE main;
CONST
    seg_adr = 0F800H; (* segment address for erase and write (MUST BE FREE!) *)

VAR
    adr, x, i, entry: INTEGER;

BEGIN
    (* initialize the port P1 registers *)
    SYSTEM.PUT8(P1DIR, REDLED + GREENLED);  (* output *)

    (* turn off the LEDs *)
    clr_bits(P1OUT, REDLED + GREENLED);

    MSP430.SetTrapProc(trap); (* set the error handler *)

    ASSERT(seg_adr MOD 512 = 0); (* the segment address must be a multiple of 512 *)

    (* get the address of the used part of flash memory
      (coincides with the program entry point) *)
    SYSTEM.GET(0FFFEH, entry);

    (* check that the segment is free *)
    ASSERT(seg_adr + 511 < entry);

    Write(seg_adr, 0, FERASE); (* erase the segment *)

    (* write the numbers 0..255 (256 words) into the segment *)
    adr := seg_adr;
    FOR i := 0 TO 255 DO
        Write(adr, i, FWRITE);
        INC(adr, 2)
    END;

    (* verify the write *)
    adr := seg_adr;
    FOR i := 0 TO 255 DO
        SYSTEM.GET(adr, x);
        ASSERT(x = i); (* if x # i, the error handler will be called *)
        INC(adr, 2)
    END;

    (* if there are no errors, turn on the green LED *)
    set_bits(P1OUT, GREENLED)
END main;


BEGIN
    main
END Flash.