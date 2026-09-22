(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2020-2021, Anton Krotov
    All rights reserved.

    The HX-DOS primitive behind the portable In: characters from standard
    input.  No msvcrt and no Win32 DLL imports: DOS line input, AH=0Ah, and
    the parsing above it in lib/common/In.mod.

    DOS hands input over a line at a time, like every console does, so a
    line is what is read here and its characters are served from it
    afterwards. *)

MODULE ArchIn;

IMPORT SYSTEM, DOS;


CONST

    (* AH=0Ah counts the line with a single byte, so no line can be longer
       than 254 characters however much room the buffer has. *)
    BUFSIZE = 256;


VAR

    buf: ARRAY BUFSIZE OF CHAR;
    pos, len: INTEGER;


(* DOS fills the buffer as [0] maximum, [1] count, [2..] the characters, so
   the text starts two bytes in and is moved down before it is served.

   DOS ends the line it stores with the carriage return and keeps the line
   feed to itself, which would leave an In.Ln after an In.Int looking for
   the next line instead of the end of this one, so the line feed DOS did
   not store is put back here.  There is room for it: the count DOS can
   return is 254 at the most and the buffer holds 256. *)
PROCEDURE Fill (): BOOLEAN;
VAR
    count: INTEGER;

BEGIN
    DOS.RdLine(SYSTEM.ADR(buf[0]), BUFSIZE, count);
    IF count < 0 THEN
        count := 0
    END;
    SYSTEM.MOVE(SYSTEM.ADR(buf[2]), SYSTEM.ADR(buf[0]), count);
    IF (count > 0) & (buf[count - 1] = 0DX) THEN
        buf[count] := 0AX;
        INC(count)
    END;
    pos := 0;
    len := count;

    RETURN count > 0
END Fill;


PROCEDURE GetChar* (VAR c: CHAR): BOOLEAN;
VAR
    ok: BOOLEAN;

BEGIN
    ok := TRUE;
    IF pos >= len THEN
        ok := Fill()
    END;
    IF ok THEN
        c := buf[pos];
        INC(pos)
    END;

    RETURN ok
END GetChar;


PROCEDURE Open*;
BEGIN
    pos := 0;
    len := 0
END Open;


BEGIN

    pos := 0;
    len := 0

END ArchIn.
