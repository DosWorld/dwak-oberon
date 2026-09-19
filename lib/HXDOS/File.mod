(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2019-2021, Anton Krotov
    All rights reserved.

    HXDOS port of the File module. No Win32 DLL imports: everything goes
    through the DOS file services in DOS. A handle is a DOS handle, and -1
    still marks a failure.
*)

MODULE File;

IMPORT SYSTEM, DOS, API;


CONST

    OPEN_R* = 0;     OPEN_W* = 1;     OPEN_RW* = 2;
    SEEK_BEG* = 0;   SEEK_CUR* = 1;   SEEK_END* = 2;

    ATTR_DIR = 4;                       (* bit 4 of the attribute byte *)


(* A directory is not a file, so Exists rejects it just as the Win32 version
   did. DOS.FileAttr answers -1 for a name that is not there at all. *)
PROCEDURE Exists* (FName: ARRAY OF CHAR): BOOLEAN;
VAR
    attr: INTEGER;

BEGIN
    DOS.FileAttr(SYSTEM.ADR(FName[0]), attr)
    RETURN (attr >= 0) & ~(ATTR_DIR IN BITS(attr))
END Exists;


PROCEDURE Delete* (FName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN DOS.FileDelete(SYSTEM.ADR(FName[0]))
END Delete;


PROCEDURE Create* (FName: ARRAY OF CHAR): INTEGER;
VAR
    h: INTEGER;

BEGIN
    DOS.FileCreate(SYSTEM.ADR(FName[0]), h)
    RETURN h
END Create;


PROCEDURE Close* (F: INTEGER);
BEGIN
    DOS.FileClose(F)
END Close;


PROCEDURE Open* (FName: ARRAY OF CHAR; Mode: INTEGER): INTEGER;
VAR
    h: INTEGER;

BEGIN
    DOS.FileOpenMode(SYSTEM.ADR(FName[0]), Mode, h)
    RETURN h
END Open;


PROCEDURE Seek* (F, Offset, Origin: INTEGER): INTEGER;
VAR
    pos: INTEGER;

BEGIN
    DOS.FileSeek(F, Offset, Origin, pos)
    RETURN pos
END Seek;


PROCEDURE Read* (F, Buffer, Count: INTEGER): INTEGER;
VAR
    n: INTEGER;

BEGIN
    DOS.FileRead(F, Buffer, Count, n)
    RETURN n
END Read;


PROCEDURE Write* (F, Buffer, Count: INTEGER): INTEGER;
VAR
    n: INTEGER;

BEGIN
    DOS.FileWrite(F, Buffer, Count, n)
    RETURN n
END Write;


PROCEDURE Load* (FName: ARRAY OF CHAR; VAR Size: INTEGER): INTEGER;
VAR
    res, n, F: INTEGER;

BEGIN
    res := 0;
    F := Open(FName, OPEN_R);

    IF F # -1 THEN
        Size := Seek(F, 0, SEEK_END);
        n    := Seek(F, 0, SEEK_BEG);
        res  := API._NEW(Size);
        IF (res = 0) OR (Read(F, res, Size) # Size) THEN
            IF res # 0 THEN
                res := API._DISPOSE(res);
                Size := 0
            END
        END;
        Close(F)
    END

    RETURN res
END Load;


PROCEDURE RemoveDir* (DirName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN DOS.RmDir(SYSTEM.ADR(DirName[0]))
END RemoveDir;


PROCEDURE ExistsDir* (DirName: ARRAY OF CHAR): BOOLEAN;
VAR
    attr: INTEGER;

BEGIN
    DOS.FileAttr(SYSTEM.ADR(DirName[0]), attr)
    RETURN (attr >= 0) & (ATTR_DIR IN BITS(attr))
END ExistsDir;


PROCEDURE CreateDir* (DirName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN DOS.MkDir(SYSTEM.ADR(DirName[0]))
END CreateDir;


END File.