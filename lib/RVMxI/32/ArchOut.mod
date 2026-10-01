(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The RVM32I primitive behind the portable Out: one byte to standard output
    through the interpreter's HOST.  The formatting, which is where the 32-bit
    REAL of this target matters, lives in lib/common/Out.mod.
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
