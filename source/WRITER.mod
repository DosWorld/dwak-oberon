(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2018-2021, Anton Krotov
    All rights reserved.
*)

MODULE WRITER;

IMPORT Files, ERRORS, UTILS;


VAR

    counter*: INTEGER;
    file: Files.File;


PROCEDURE align* (n, _align: INTEGER): INTEGER;
BEGIN
    ASSERT(UTILS.Align(n, _align))
    RETURN n
END align;


PROCEDURE WriteByte* (n: BYTE);
BEGIN
    IF Files.WriteByte(file, n) = 1 THEN
        INC(counter)
    ELSE
        ERRORS.Error(201)
    END
END WriteByte;


PROCEDURE Write* (chunk: ARRAY OF BYTE; bytes: INTEGER);
VAR
    n: INTEGER;

BEGIN
    n := Files.BlockWrite(file, chunk, bytes);
    IF n # bytes THEN
        ERRORS.Error(201)
    END;
    INC(counter, n)
END Write;


PROCEDURE Write64LE* (n: INTEGER);
VAR
    i: INTEGER;

BEGIN
    FOR i := 0 TO 7 DO
        WriteByte(n MOD 256);
        n := ASR(n, 8)
    END
END Write64LE;


PROCEDURE Write32LE* (n: INTEGER);
VAR
    i: INTEGER;

BEGIN
    FOR i := 0 TO 3 DO
        WriteByte(UTILS.Byte(n, i))
    END
END Write32LE;


PROCEDURE Write16LE* (n: INTEGER);
BEGIN
    WriteByte(UTILS.Byte(n, 0));
    WriteByte(UTILS.Byte(n, 1))
END Write16LE;


PROCEDURE Padding* (FileAlignment: INTEGER);
VAR
    i: INTEGER;

BEGIN
    i := align(counter, FileAlignment) - counter;
    WHILE i > 0 DO
        WriteByte(0);
        DEC(i)
    END
END Padding;


PROCEDURE Create* (FileName: ARRAY OF CHAR);
BEGIN
    counter := 0;
    IF ~Files.ReWrite(file, FileName) THEN
        ERRORS.Error(201)
    END
END Create;


PROCEDURE Close*;
BEGIN
    Files.Close(file)
END Close;


END WRITER.