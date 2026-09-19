(*
  Example for STM32L152C-DISCO

  Depending on the value of the LED constant,
  the blue or the green LED blinks.
*)

MODULE Blink;

IMPORT SYSTEM;


CONST

    GPIOB = 40020400H;
        GPIOB_MODER = GPIOB;
        GPIOB_BSRR  = GPIOB + 18H;

    RCC = 40023800H;
        RCC_AHBENR  = RCC + 1CH;

    Blue  = 6;  (* PB6 *)
    Green = 7;  (* PB7 *)

    LED = Blue;

VAR

    x: SET;
    state: BOOLEAN;


PROCEDURE Delay (x: INTEGER);
BEGIN
    REPEAT
        DEC(x)
    UNTIL x = 0
END Delay;


BEGIN
    (* enable GPIOB *)
    SYSTEM.GET(RCC_AHBENR, x);
    SYSTEM.PUT(RCC_AHBENR, x + {1});

    (* configure PB6 or PB7 as output *)
    SYSTEM.GET(GPIOB_MODER, x);
    SYSTEM.PUT(GPIOB_MODER, x - {LED * 2 - 1} + {LED * 2});

    state := FALSE;
    REPEAT
        (* turn the LED on or off *)
        SYSTEM.PUT(GPIOB_BSRR, {LED + 16 * ORD(state)});
        state := ~state;
        Delay(200000)
    UNTIL FALSE
END Blink.