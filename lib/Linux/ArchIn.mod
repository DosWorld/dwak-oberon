(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2020-2021, Anton Krotov
    All rights reserved.

    The Linux primitive behind the portable In: characters from standard
    input.  The parsing lives in lib/common/In.mod.

    fgets is asked for a line rather than libc being asked for bytes,
    because a terminal hands a line over anyway: it is the terminal that
    does the editing and releases nothing until Enter, so reading a byte at
    a time through the syscall would change nothing a program could see
    while costing a call per byte.  Holding the line also keeps the line's
    own breaks visible to the parser, so In.Ln stops at the end of the line
    it was called on.
*)

MODULE ArchIn;

IMPORT SYSTEM, Libdl, LINAPI, API;


CONST

    BUFSIZE = 1024;


VAR

    buf: ARRAY BUFSIZE OF CHAR;
    pos, len: INTEGER;

    fgets: PROCEDURE [linux-] (string: INTEGER; num: INTEGER; filestream: INTEGER): INTEGER;


PROCEDURE Fill (): BOOLEAN;
VAR
    i, n: INTEGER;

BEGIN
    n := 0;
    IF fgets(SYSTEM.ADR(buf[0]), BUFSIZE, LINAPI.stdin) # 0 THEN
        (* fgets stops at a newline or when the buffer is full, and NUL
           terminates what it wrote, so the newline is kept and the length is
           the text that arrived. *)
        i := 0;
        WHILE (i < BUFSIZE) & (buf[i] # 0X) DO
            INC(i)
        END;
        n := i
    END;
    pos := 0;
    len := n;

    RETURN n > 0
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

    SYSTEM.PUT(SYSTEM.ADR(fgets), Libdl.sym(API.libc, "fgets"));
    ASSERT(fgets # NIL);
    pos := 0;
    len := 0

END ArchIn.
