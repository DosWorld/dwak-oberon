(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    RVMxI port of the File module.  Every operation is a syscall: the HOST
    module issues it, the emulator (tools/RVMxI.mod) answers it on the machine
    the emulator runs on, and the two agree on the function numbers.  The calls
    therefore behave as the emulator's own host behaves, which is the Windows
    File module's behaviour - a handle of -1 means failure, and a timestamp is
    the same packed 32-bit DOS date/time word.
*)

MODULE ArchFile;

IMPORT SYSTEM, HOST, RTL;


CONST

    OPEN_R* = 0;   OPEN_W* = 1;   OPEN_RW* = 2;
    SEEK_BEG* = 0; SEEK_CUR* = 1; SEEK_END* = 2;


(* Exists - TRUE when FName names a file.  A directory is not a file here;
   ExistsDir is the call for that.
   Parameters: FName - the name to test. *)
PROCEDURE Exists* (FName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN HOST.FileExists(FName)
END Exists;


(* ExistsDir - TRUE when DirName names a directory.
   Parameters: DirName - the name to test. *)
PROCEDURE ExistsDir* (DirName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN HOST.FileDirExists(DirName)
END ExistsDir;


(* GetTime - the write time of a file, in the packed DOS form: bits 0..4
   seconds DIV 2, bits 5..10 minutes, bits 11..15 hours, bits 16..20 day,
   bits 21..24 month, bits 25..31 year - 1980.  The host answers -1 for a file
   it cannot look at, and then time is left alone, so a failed call cannot be
   mistaken for a real stamp.
   Parameters: FName - the file to look at; time - its packed write time,
   untouched when the result is FALSE.
   Result: TRUE when the file exists and time was set. *)
PROCEDURE GetTime* (FName: ARRAY OF CHAR; VAR time: INTEGER): BOOLEAN;
VAR
    t: INTEGER;

BEGIN
    t := HOST.FileGetTime(FName);
    IF t >= 0 THEN
        time := t
    END

    RETURN t >= 0
END GetTime;


(* SetTime - stamp the write time of a file with a packed DOS time, as GetTime
   returns one.
   Parameters: FName - the file to stamp; time - the packed time to stamp it
   with.
   Result: TRUE when the stamp was applied. *)
PROCEDURE SetTime* (FName: ARRAY OF CHAR; time: INTEGER): BOOLEAN;
BEGIN
    RETURN HOST.FileSetTime(FName, time)
END SetTime;


(* Delete - remove a file.  A directory is refused; RemoveDir is the call for
   that.
   Parameters: FName - the file to remove.
   Result: TRUE when it is gone. *)
PROCEDURE Delete* (FName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN HOST.FileDelete(FName)
END Delete;


(* Rename - rename or move a file.  Either name may be a full path, and
   NewName is replaced if something is already there.
   Parameters: OldName - the file to rename; NewName - the name it should
   carry afterwards.
   Result: TRUE when the rename succeeded. *)
PROCEDURE Rename* (OldName, NewName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN HOST.FileRename(OldName, NewName)
END Rename;


(* Close - close an open file.  This is the one operation of the module with
   no result, so a handle that is not open goes unreported.
   Parameters: F - the handle to close. *)
PROCEDURE Close* (F: INTEGER);
BEGIN
    HOST.FileClose(F)
END Close;


(* Valid - TRUE when F is an open handle: one that Open, Create or Load
   returned successfully.  The host answers -1 when it fails, as the Windows
   module does.
   Parameters: F - the handle.
   Result: TRUE when F may be read, written, seeked, truncated or closed. *)
PROCEDURE Valid* (F: INTEGER): BOOLEAN;
BEGIN
    RETURN F # -1
END Valid;


(* Open - open an existing file.  Mode is OPEN_R, OPEN_W or OPEN_RW, and says
   what the file is opened for.
   Parameters: FName - the file to open; Mode - how it is to be opened.
   Result: the handle, or -1 when the file is not there or cannot be opened
   that way. *)
PROCEDURE Open* (FName: ARRAY OF CHAR; Mode: INTEGER): INTEGER;
BEGIN
    RETURN HOST.FileOpenMode(FName, Mode)
END Open;


(* Create - make a new file, or empty one that is already there, and open it
   for writing.
   Parameters: FName - the file to create.
   Result: the handle, or -1 when the file could not be created. *)
PROCEDURE Create* (FName: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN HOST.FileCreate(FName)
END Create;


(* Seek - move the read/write cursor of an open file.  Origin is SEEK_BEG,
   SEEK_CUR or SEEK_END, and Offset is counted from it.
   Parameters: F - the open file; Offset - how far to move; Origin - where the
   move starts from.
   Result: the new offset from the start of the file, or -1 when the move
   failed. *)
PROCEDURE Seek* (F, Offset, Origin: INTEGER): INTEGER;
BEGIN
    RETURN HOST.FileSeek(F, Offset, Origin)
END Seek;


(* Write - write Count bytes to an open file, at the cursor, from the address
   Buffer.  The buffer is an address rather than an array because Files hands
   on the address its own caller gave it, and an open array cannot be built
   from one.
   Parameters: F - the open file; Buffer - the address to write from; Count -
   how many bytes to write.
   Result: the number of bytes written, or -1 when the write failed. *)
PROCEDURE Write* (F, Buffer, Count: INTEGER): INTEGER;
BEGIN
    RETURN HOST.FileWriteAt(F, Buffer, Count)
END Write;


(* Read - read Count bytes from an open file, at the cursor, into the address
   Buffer; the counterpart of Write above.
   Parameters: F - the open file; Buffer - the address to read into; Count -
   how many bytes to read.
   Result: the number of bytes read, or -1 when the read failed. *)
PROCEDURE Read* (F, Buffer, Count: INTEGER): INTEGER;
BEGIN
    RETURN HOST.FileReadAt(F, Buffer, Count)
END Read;


(* Truncate - set the length of the file behind an open handle.  A Size below
   the current length discards everything past it; a Size above the current
   length extends the file, and the gap reads back as zero bytes.  The cursor
   is left where it was.
   Parameters: F - the open handle; Size - the new length in bytes.
   Result: TRUE when the length was set. *)
PROCEDURE Truncate* (F, Size: INTEGER): BOOLEAN;
BEGIN
    RETURN HOST.FileTruncate(F, Size)
END Truncate;


(* Load - read a whole file into a fresh block of heap and answer the block's
   address.  The block comes from RTL._new, the only allocator this target
   has, and holds no record, so it carries the type tag 0; RTL._new counts the
   tag word in its size argument, hence the added SYSTEM.SIZE(INTEGER), and
   answers 0 when the heap is full.  A short read counts as a failure, and
   this heap cannot take the block back - there is no _dispose here - so a
   failed Load leaves it where it is.
   Parameters: FName - the file to read; Size - its length in bytes, and 0
   when the result is 0.
   Result: the address of the block, or 0 when the file could not be read. *)
PROCEDURE Load* (FName: ARRAY OF CHAR; VAR Size: INTEGER): INTEGER;
VAR
    res, n, F: INTEGER;

BEGIN
    res := 0;
    Size := 0;
    F := Open(FName, OPEN_R);

    IF F >= 0 THEN
        Size := Seek(F, 0, SEEK_END);
        n := Seek(F, 0, SEEK_BEG);          (* back to the start to read it *)
        RTL._new(0, Size + SYSTEM.SIZE(INTEGER), res);
        IF res # 0 THEN
            IF Read(F, res, Size) # Size THEN
                res := 0;
                Size := 0
            END
        ELSE
            Size := 0
        END;
        Close(F)
    END

    RETURN res
END Load;


(* RemoveDir - remove an empty directory.  A directory with anything in it is
   refused.
   Parameters: DirName - the directory to remove.
   Result: TRUE when it is gone. *)
PROCEDURE RemoveDir* (DirName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN HOST.FileRemoveDir(DirName)
END RemoveDir;


(* CreateDir - create a directory.  The parent directory has to be there
   already.
   Parameters: DirName - the directory to create.
   Result: TRUE when it was created. *)
PROCEDURE CreateDir* (DirName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN HOST.FileMakeDir(DirName)
END CreateDir;


END ArchFile.
