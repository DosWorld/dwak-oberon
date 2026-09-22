(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2020-2022, 2025, Anton Krotov
    All rights reserved.

    The Windows primitives behind the portable Out: one byte to standard
    output, one UTF-16 code unit to the console.
*)

MODULE ArchOut;

IMPORT SYSTEM, WINAPI;


CONST

    STD_OUTPUT_HANDLE = -11;


VAR

    hOut: INTEGER;


PROCEDURE Open*;
BEGIN
    (* The handle is taken again here and not only at module start, because a
       GUI subsystem program has no console until it calls AllocConsole and the
       handle it held before that is not the one it writes to afterwards. *)
    hOut := WINAPI.GetStdHandle(STD_OUTPUT_HANDLE)
END Open;


(* One byte, written to the standard output handle.  That handle is a file one
   when the output has been redirected and a console one otherwise, and
   WriteFile covers both, so a redirected program keeps its output. *)
PROCEDURE Char* (c: CHAR);
VAR
    count: INTEGER;

BEGIN
    WINAPI.WriteFile(hOut, SYSTEM.ADR(c), 1, SYSTEM.ADR(count), NIL)
END Char;


(* One UTF-16 code unit.  A console takes it directly and says so by taking it;
   a redirected stdout has no such call at all, so the unit is then encoded to
   UTF-8 and written as bytes, which is what that stream is - the same encoding
   the portable Out produces for the targets whose console is not wide.  Which
   of the two it is cannot be asked once and remembered from the handle alone:
   the answer is the call's own, so it is the call that decides.  Without the
   fallback the text of a program that redirected its output would simply be
   lost, WriteConsoleW having no file to write to.

   Below 80H the unit is one byte, below 800H two, and anything else three,
   which is the encoding Utf8To16 reads back.  Only the basic multilingual
   plane is handled: a surrogate pair is not recombined, which matches what the
   rest of the library does with wide text. *)
PROCEDURE CharW* (c: WCHAR);
VAR
    count, u, n: INTEGER;
    buf: ARRAY 4 OF CHAR;

BEGIN
    IF WINAPI.WriteConsoleW(hOut, SYSTEM.ADR(c), 1, 0, 0) = 0 THEN
        u := ORD(c);
        IF u < 80H THEN
            buf[0] := CHR(u);
            n := 1
        ELSIF u < 800H THEN
            buf[0] := CHR(0C0H + u DIV 40H);
            buf[1] := CHR(80H + u MOD 40H);
            n := 2
        ELSE
            buf[0] := CHR(0E0H + u DIV 1000H);
            buf[1] := CHR(80H + (u DIV 40H) MOD 40H);
            buf[2] := CHR(80H + u MOD 40H);
            n := 3
        END;
        WINAPI.WriteFile(hOut, SYSTEM.ADR(buf), n, SYSTEM.ADR(count), NIL)
    END
END CharW;


BEGIN

    (* Taken once here as well, so that a program which never calls Open still
       writes to the right place. *)
    hOut := WINAPI.GetStdHandle(STD_OUTPUT_HANDLE)

END ArchOut.
