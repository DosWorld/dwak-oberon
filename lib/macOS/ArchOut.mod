(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The macOS primitive behind the portable Out: one byte to standard output,
    written with a libSystem write(2) function.  The formatting lives in
    lib/common/Out.mod; what is left here is the write itself.
*)

MODULE ArchOut;

IMPORT HOST;


PROCEDURE Open*;
END Open;


PROCEDURE Char* (c: CHAR);
BEGIN
    HOST.OutChar(c)
END Char;


END ArchOut.
