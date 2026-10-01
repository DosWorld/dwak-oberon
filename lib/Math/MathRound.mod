(* ******************************************
   Additional functions to the module Math.
   Rounding functions.
   Vadim Isaev, 2020
********************************************* *)

MODULE MathRound;

IMPORT Math;


(* Returns the integer part of a argument x.*)
PROCEDURE trunc* (x: REAL): REAL;
VAR
    a: REAL;

BEGIN
    a := FLT(FLOOR(x));
    IF (x < 0.0) & (x # a) THEN
        a := a + 1.0
    END

    RETURN a
END trunc;


(* Returns the fractional part of the argument x *)
PROCEDURE frac* (x: REAL): REAL;
    RETURN x - trunc(x)
END frac;


(* Rounding to the nearest integer. *)
PROCEDURE round* (x: REAL): REAL;
VAR
    a: REAL;

BEGIN
    a := trunc(x);
    IF ABS(frac(x)) >= 0.5 THEN
        a := a + FLT(Math.sgn(x))
    END

    RETURN a
END round;


(* Rounding to a largest integer *)
PROCEDURE ceil* (x: REAL): REAL;
VAR
    a: REAL;

BEGIN
    a := FLT(FLOOR(x));
    IF x # a THEN
        a := a + 1.0
    END

    RETURN a
END ceil;


(* Rounding to a smallest integer *)
PROCEDURE floor* (x: REAL): REAL;
    RETURN FLT(FLOOR(x))
END floor;


(* Rounding to a specified number of digits:
   - if Digits is negative, rounding is performed
     in the digits after the decimal point;
   - if Digits is positive, rounding is performed
     in the digits before the decimal point  *)
PROCEDURE SimpleRoundTo* (AValue: REAL; Digits: INTEGER): REAL;
VAR
    RV, a : REAL;

BEGIN
    RV := Math.ipower(10.0, -Digits);
    IF AValue < 0.0 THEN
        a := trunc((AValue * RV) - 0.5)
    ELSE
        a := trunc((AValue * RV) + 0.5)
    END

    RETURN a / RV
END SimpleRoundTo;


END MathRound.