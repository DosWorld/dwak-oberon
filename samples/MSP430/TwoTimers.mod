(*

Example for LaunchPad MSP-EXP430G2 Rev1.5

  The green LED blinks on signals from timer A,
  the red one on signals from the watchdog timer in interval mode

*)

MODULE TwoTimers;

IMPORT SYSTEM, MSP430;


CONST

    REDLED   = {0};
    GREENLED = {6};

    (* port P1 registers *)
    P1OUT = 21H;
    P1DIR = 22H;


    (* interrupt enable register 1 *)
    IE1 = 00H;

        (* bits of the IE1 register *)
        WDTIE = {0};
        NMIIE = {4};


    (* interrupt flag register 1 *)
    IFG1 = 02H;

        (* bits of the IFG1 register *)
        WDTIFG = {0};
        NMIIFG = {4};


    WDTCTL = 0120H; (* watchdog timer register *)

        (* bits of the WDTCTL register *)
        WDTIS0   = {0};
        WDTIS1   = {1};
        WDTSSEL  = {2};
        WDTCNTCL = {3};
        WDTTMSEL = {4};
        WDTNMI   = {5};
        WDTNMIES = {6};
        WDTHOLD  = {7};
        WDTPW    = {9, 11, 12, 14};  (* protection key *)


    (* timer A registers *)
    TACTL = 0160H;

        (* bits of the TACTL register *)
        TAIFG   = {0};
        TAIE    = {1};
        TACLR   = {2};
        MC0     = {4};
        MC1     = {5};
        ID0     = {6};
        ID1     = {7};
        TASSEL0 = {8};
        TASSEL1 = {9};

    TAR = 0170H;

    TACCTL0 = 0162H;

        (* bits of the TACCTL0 register *)
        CCIE = {4};
        CAP  = {8};

    TACCR0 = 0172H;


PROCEDURE set_bits (mem: INTEGER; bits: SET);
VAR
    b: BYTE;

BEGIN
    SYSTEM.GET(mem, b);
    SYSTEM.PUT8(mem, BITS(b) + bits)
END set_bits;


PROCEDURE inv_bits (mem: INTEGER; bits: SET);
VAR
    b: BYTE;

BEGIN
    SYSTEM.GET(mem, b);
    SYSTEM.PUT8(mem, BITS(b) / bits)
END inv_bits;


(* interrupt handler *)
PROCEDURE int (priority: INTEGER; interrupt: MSP430.TInterrupt);
VAR
    x: SET;

BEGIN
    IF priority = 26 THEN                 (* interrupt from the watchdog timer *)
        inv_bits(P1OUT, REDLED)           (* toggle the LED *)
    ELSIF priority = 24 THEN              (* interrupt from timer A *)
        SYSTEM.GET(TACTL, x);             (* read the TACTL register *)
        IF TAIFG * x = TAIFG THEN         (* an interrupt occurred *)
            SYSTEM.PUT(TACTL, x - TAIFG); (* clear the interrupt flag and update the TACTL register *)
            inv_bits(P1OUT, GREENLED);    (* toggle the LED *)
        END
    END
END int;


PROCEDURE main;
BEGIN
    (* initialize the P1DIR register *)
    set_bits(P1DIR, REDLED + GREENLED);

    (* initial state of the LEDs - on *)
    set_bits(P1OUT, REDLED + GREENLED);

    MSP430.SetIntProc(int);  (* set the interrupt handler *)
    MSP430.EInt;             (* enable interrupts *)

    (* initialize the timer A registers *)
    SYSTEM.PUT(TAR, 0);
    SYSTEM.PUT(TACCTL0, CCIE + CAP);
    SYSTEM.PUT(TACCR0, 0FFFFH);
    SYSTEM.PUT(TACTL, TAIE + MC0 + MC1 + TASSEL1 + ID0 + ID1);

    (* initialize the watchdog timer registers *)
    set_bits(IE1, WDTIE);
    SYSTEM.PUT(WDTCTL, WDTPW + WDTIS1 + WDTSSEL + WDTCNTCL + WDTTMSEL)
END main;


BEGIN
    main
END TwoTimers.
