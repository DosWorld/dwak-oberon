(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The Windows answer to "where is the running image", behind the portable
    Program.  GetModuleFileNameA and not argv[0], for the reason the rest of
    this tree asks it: an image started by a full path, by a bare name found
    on the PATH, and by a shell that changed its mind all answer the same
    thing here, and none of the three has to be parsed.

   `0` as the module handle asks for the image of the calling process.  The
   call answers 0 on failure and answers nSize when the buffer was too small,
   with the name cut short - both leave nothing usable, so both answer the
   empty string rather than a path with no end on it.
*)

MODULE ArchProgram;

IMPORT SYSTEM;


CONST

    (* the name each declaration below is bound to; the table is per module
       in this tree, not shared through a header *)
    KERNEL = "kernel32.dll";


PROCEDURE [windows-, KERNEL, ""] GetModuleFileNameA (hModule, lpFilename, nSize: INTEGER): INTEGER;


PROCEDURE Path* (VAR s: ARRAY OF CHAR);
VAR
    n: INTEGER;

BEGIN
    s[0] := 0X;
    IF LEN(s) > 1 THEN
        n := GetModuleFileNameA(0, SYSTEM.ADR(s[0]), LEN(s));
        IF (n > 0) & (n < LEN(s)) THEN
            s[n] := 0X
        ELSE
            s[0] := 0X
        END
    END
END Path;


END ArchProgram.
