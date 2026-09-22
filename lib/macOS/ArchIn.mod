(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The macOS primitive behind the portable In: one byte from standard input,
    read through the raw read(2) syscall that HOST wraps.  The parsing lives
    in lib/common/In.mod.

    Bytes are taken one at a time here rather than a line at a time because
    a terminal is the one thing that decides when a line is over, and asking
    the kernel for a single byte waits for exactly as long as the terminal
    makes it wait.  That leaves the line's breaks in the stream for the
    parser to see.
*)

MODULE ArchIn;

IMPORT HOST;


CONST

    STDIN = 0;


PROCEDURE GetChar* (VAR c: CHAR): BOOLEAN;
VAR
    buf: ARRAY 1 OF CHAR;
    n: INTEGER;

BEGIN
    n := HOST.FileRead(STDIN, buf, 1);
    IF n = 1 THEN
        c := buf[0]
    END;

    RETURN n = 1
END GetChar;


PROCEDURE Open*;
END Open;


END ArchIn.
