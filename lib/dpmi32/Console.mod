(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2019-2020, Anton Krotov
    All rights reserved.

    DPMI32 port of the Console module. No Win32 DLL imports: the cursor lives
    in the BIOS data area, and the sixteen colour constants below are the
    VGA text attributes, so they can be handed to DOS.Attr unchanged.
*)

MODULE Console;

IMPORT DOS, In, Out;


CONST

    Black* = 0;     Blue* = 1;          Green* = 2;       Cyan* = 3;
    Red* = 4;       Magenta* = 5;       Brown* = 6;       LightGray* = 7;
    DarkGray* = 8;  LightBlue* = 9;     LightGreen* = 10; LightCyan* = 11;
    LightRed* = 12; LightMagenta* = 13; Yellow* = 14;     White* = 15;


PROCEDURE SetCursor* (X, Y: INTEGER);
BEGIN
    DOS.SetCursor(X, Y)
END SetCursor;


PROCEDURE GetCursor* (VAR X, Y: INTEGER);
BEGIN
    DOS.GetCursor(X, Y)
END GetCursor;


(* Clearing in the attribute that is currently selected keeps the blanked
   cells and the following output the same colour. *)
PROCEDURE Cls*;
BEGIN
    DOS.ClearScr(DOS.Attr())
END Cls;


(* Choosing a colour redirects Out to video memory for good: it is the only
   way to give the characters an attribute on this target. *)
PROCEDURE SetColor* (FColor, BColor: INTEGER);
BEGIN
    IF (FColor IN {0..15}) & (BColor IN {0..15}) THEN
        DOS.SetAttr(LSL(BColor, 4) + FColor)
    END
END SetColor;


PROCEDURE GetCursorX* (): INTEGER;
VAR
    X, Y: INTEGER;

BEGIN
    DOS.GetCursor(X, Y)
    RETURN X
END GetCursorX;


PROCEDURE GetCursorY* (): INTEGER;
VAR
    X, Y: INTEGER;

BEGIN
    DOS.GetCursor(X, Y)
    RETURN Y
END GetCursorY;


(* A DOS client is attached to the console from the start; there is nothing
   to allocate or to hand back. *)
PROCEDURE open*;
BEGIN
    In.Open;
    Out.Open
END open;


PROCEDURE exit* (b: BOOLEAN);
END exit;


END Console.