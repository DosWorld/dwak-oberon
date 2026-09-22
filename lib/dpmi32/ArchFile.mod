(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2019-2021, Anton Krotov
    All rights reserved.

    HXDOS port of the File module. No Win32 DLL imports: everything goes
    through the DOS file services in DOS. A handle is a DOS handle, and -1
    still marks a failure.
*)

MODULE ArchFile;

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


(* Rename - move OldName onto NewName: they may name different directories, in
   which case the file moves with the call.  DOS.Rename asks the LFN subfunction
   first and the 8.3 one behind it, so a long name is reached on a host that has
   them and a short one on a host that does not.
   Parameters: OldName - the file to move; NewName - where to move it to.
   Result: TRUE when it was renamed. *)
PROCEDURE Rename* (OldName, NewName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN DOS.Rename(SYSTEM.ADR(OldName[0]), SYSTEM.ADR(NewName[0]))
END Rename;


(* GetTime - when a file was last written, as the packed DOS date and time the
   DOS services use: bits 0..4 seconds DIV 2, bits 5..10 minutes, bits 11..15
   hours, bits 16..20 day, bits 21..24 month, bits 25..31 year - 1980.
   Parameters: FName - the file to look at; time - receives the stamp.
   Result: TRUE when the file is there, FALSE when it is not. *)
PROCEDURE GetTime* (FName: ARRAY OF CHAR; VAR time: INTEGER): BOOLEAN;
BEGIN
    RETURN DOS.GetFileTime(SYSTEM.ADR(FName[0]), time)
END GetTime;


(* SetTime - stamp a file with a packed DOS date and time, in the same form
   GetTime returns.
   Parameters: FName - the file to stamp; time - the stamp to give it.
   Result: TRUE when DOS set it, FALSE when the file is not there or is one it
   will not open for writing. *)
PROCEDURE SetTime* (FName: ARRAY OF CHAR; time: INTEGER): BOOLEAN;
BEGIN
    RETURN DOS.SetFileTime(SYSTEM.ADR(FName[0]), time)
END SetTime;


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


(* Valid - TRUE when F is an open handle: one that Open, Create or Load
   returned successfully.  The DOS open sets the handle to -1 when it fails.
   Parameters: F - the handle.
   Result: TRUE when F may be read, written, seeked or closed. *)
PROCEDURE Valid* (F: INTEGER): BOOLEAN;
BEGIN
    RETURN F # -1
END Valid;


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


(* Truncate - shrink or extend the file behind the open handle F to Size
   bytes: a smaller size cuts the tail off, a larger one fills what it adds
   with zeros, and where the handle reads and writes next is not moved by
   this.  The DOS call behind it is asked for the LFN way first and, when
   that one does not answer, done the older way - seek to the length and
   write no bytes there - the same two-step fallback the name-taking calls
   here use for the services themselves.
   Parameters: F - the open handle; Size - the length to leave the file with.
   Result: TRUE when the file is Size bytes long and the handle is back where
   it was, FALSE when F is not an open handle, is not a file this process may
   write, or Size is negative. *)
PROCEDURE Truncate* (F, Size: INTEGER): BOOLEAN;
BEGIN
    RETURN DOS.Truncate(F, Size)
END Truncate;


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


END ArchFile.