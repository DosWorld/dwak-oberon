(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The Windows primitive behind the portable In: characters from standard
    input.  The parsing lives in lib/common/In.mod.

    A console hands input over a line at a time - it is the console that
    edits the line and decides when Enter has been pressed - so a line is
    what is read here and its characters are served from it afterwards.  A
    redirected stdin is read the same way, which is why the two do not
    differ to the parser above.
*)

MODULE ArchIn;

IMPORT SYSTEM, WINAPI;


CONST

    STD_INPUT_HANDLE = -10;
    BUFSIZE = 1024;


VAR

    hIn:  INTEGER;
    buf:  ARRAY BUFSIZE OF CHAR;
    pos, len: INTEGER;


(* A console and a redirected stdin need different calls and neither says
   which it is.  ReadConsoleA is tried first because a console is the usual
   case; it fails when stdin is a file, a pipe or NUL, and ReadFile answers
   for all of those.  Each call is judged by its own return value rather
   than by the count it was given, because a failed call is documented to
   leave that count alone and an untouched count from an earlier read would
   read as input that was never there.

   The count is an INTEGER and both calls write four bytes of it.  It is
   zeroed before each call so the bytes they do not write are already what
   they mean. *)
PROCEDURE Fill (): BOOLEAN;
VAR
    res: INTEGER;

BEGIN
    len := 0;
    res := WINAPI.ReadConsoleA(hIn, SYSTEM.ADR(buf[0]), BUFSIZE, SYSTEM.ADR(len), 0);
    IF res = 0 THEN
        len := 0;
        res := WINAPI.ReadFile(hIn, SYSTEM.ADR(buf[0]), BUFSIZE, SYSTEM.ADR(len), NIL)
    END;
    IF res = 0 THEN
        len := 0
    END;
    pos := 0;

    RETURN len > 0
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


(* The handle is looked up again here because a program with no console of
   its own allocates one first, and the handle it wants is the one that
   exists afterwards. *)
PROCEDURE Open*;
BEGIN
    hIn := WINAPI.GetStdHandle(STD_INPUT_HANDLE);
    pos := 0;
    len := 0
END Open;


BEGIN

    hIn := WINAPI.GetStdHandle(STD_INPUT_HANDLE);
    pos := 0;
    len := 0

END ArchIn.
