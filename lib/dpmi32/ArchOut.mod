(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The HX-DOS primitives behind the portable Out.  No msvcrt and no Win32 DLL
    imports: the characters go to the DOS console.

    Two routes reach the screen.  Plain output is written with AH=40h, so a
    program that redirects stdout still has its output land in the file.  Once
    a colour has been selected there is nothing to negotiate: DOS has no call
    that sets the attribute of the text it is given, so the characters are
    placed in video memory directly, in that attribute.  Redirected output
    keeps to the DOS route and loses the colour, the same way it does on
    Windows.
*)

MODULE ArchOut;

IMPORT SYSTEM, DOS;


VAR

    console: BOOLEAN;                   (* stdout is the console, not a file *)


PROCEDURE WrStr (adr, len: INTEGER);
BEGIN
    IF len > 0 THEN
        IF console & DOS.AttrOn() THEN
            DOS.WrAttr(adr, len, DOS.Attr())
        ELSE
            DOS.WrBuf(adr, len)
        END
    END
END WrStr;


PROCEDURE Char* (c: CHAR);
BEGIN
    WrStr(SYSTEM.ADR(c), 1)
END Char;


(* A DOS console is an OEM one, so a wide character has to be mapped to the
   code page before it can be written; 866 is the one this target assumes. *)
PROCEDURE CharW* (c: WCHAR);
VAR
    u, b: INTEGER;
    ch:   CHAR;

BEGIN
    u := ORD(c);
    IF u < 100H THEN
        b := u
    ELSIF (u >= 410H) & (u <= 42FH) THEN
        b := 80H + u - 410H
    ELSIF (u >= 430H) & (u <= 43FH) THEN
        b := 0A0H + u - 430H
    ELSIF (u >= 440H) & (u <= 44FH) THEN
        b := 0E0H + u - 440H
    ELSIF u = 401H THEN
        b := 0F0H
    ELSIF u = 451H THEN
        b := 0F1H
    ELSE
        b := ORD("?")
    END;
    ch := CHR(b);
    WrStr(SYSTEM.ADR(ch), 1)
END CharW;


PROCEDURE Open*;
BEGIN
    console := DOS.IsConsole()
END Open;


BEGIN

    (* Until Open has had a chance to look, assume the console.  A program that
       never calls it should still get its colours. *)
    console := TRUE

END ArchOut.
