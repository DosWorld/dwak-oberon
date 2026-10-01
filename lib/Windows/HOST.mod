(*
    BSD 2-Clause License

    Copyright (c) 2018-2022, Anton Krotov
    All rights reserved.
*)

MODULE HOST;

IMPORT SYSTEM;


CONST

    slash* = "\";
    eol* = 0DX + 0AX;

    bit_depth* = (ORD(LSL(1, 31) > 0) + 1) * 32;
    maxint* = ROR(-2, 1);
    minint* = ROR(1, 1);

    MAX_PARAM = 1024;

    OFS_MAXPATHNAME = 128;


TYPE

    POverlapped = POINTER TO OVERLAPPED;

    OVERLAPPED = RECORD

        Internal:       INTEGER;
        InternalHigh:   INTEGER;
        Offset:         INTEGER;
        OffsetHigh:     INTEGER;
        hEvent:         INTEGER

    END;

    OFSTRUCT = RECORD

        cBytes:         CHAR;
        fFixedDisk:     CHAR;
        nErrCode:       WCHAR;
        Reserved1:      WCHAR;
        Reserved2:      WCHAR;
        szPathName:     ARRAY OFS_MAXPATHNAME OF CHAR

    END;

    PSecurityAttributes = POINTER TO TSecurityAttributes;

    TSecurityAttributes = RECORD

        nLength:               INTEGER;
        lpSecurityDescriptor:  INTEGER;
        bInheritHandle:        INTEGER

    END;


VAR

    hConsoleOutput: INTEGER;

    Params: ARRAY MAX_PARAM, 2 OF INTEGER;
    argc: INTEGER;

    maxreal*, inf*: REAL;


PROCEDURE [windows-, "kernel32.dll", "GetTickCount"]
    _GetTickCount (): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "GetStdHandle"]
    _GetStdHandle (nStdHandle: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "GetCommandLineA"]
    _GetCommandLine (): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "ReadFile"]
    _ReadFile (hFile, Buffer, nNumberOfBytesToRW: INTEGER; VAR NumberOfBytesRW: INTEGER; lpOverlapped: POverlapped): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "WriteFile"]
    _WriteFile (hFile, Buffer, nNumberOfBytesToRW: INTEGER; VAR NumberOfBytesRW: INTEGER; lpOverlapped: POverlapped): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "CloseHandle"]
    _CloseHandle (hObject: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "CreateFileA"]
    _CreateFile (
        lpFileName, dwDesiredAccess, dwShareMode: INTEGER;
        lpSecurityAttributes: PSecurityAttributes;
        dwCreationDisposition, dwFlagsAndAttributes,
        hTemplateFile: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "OpenFile"]
    _OpenFile (lpFileName: INTEGER; lpReOpenBuff: OFSTRUCT; uStyle: INTEGER): INTEGER;

(* The calls below back the RVMxI emulator's file syscalls.  It is a Windows
   program that has to answer them for a guest, so the host side of the RVM
   file interface is implemented here, on the same primitives the Windows
   File module uses.  The names match the RVMxI HOST modules, where each one
   is a thin syscall wrapper. *)

PROCEDURE [windows-, "kernel32.dll", "SetFilePointer"]
    _SetFilePointer (hFile, lDistanceToMove, lpDistanceToMoveHigh, dwMoveMethod: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "SetEndOfFile"]
    _SetEndOfFile (hFile: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "FindFirstFileA"]
    _FindFirstFile (lpFileName, lpFindFileData: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "FindClose"]
    _FindClose (hFindFile: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "DeleteFileA"]
    _DeleteFile (lpFileName: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "MoveFileA"]
    _MoveFile (lpExistingFileName, lpNewFileName: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "CreateDirectoryA"]
    _CreateDirectory (lpPathName: INTEGER; lpSecurityAttributes: PSecurityAttributes): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "RemoveDirectoryA"]
    _RemoveDirectory (lpPathName: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "GetFileTime"]
    _GetFileTime (hFile, lpCreationTime, lpLastAccessTime, lpLastWriteTime: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "SetFileTime"]
    _SetFileTime (hFile, lpCreationTime, lpLastAccessTime, lpLastWriteTime: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "FileTimeToDosDateTime"]
    _FileTimeToDosDateTime (lpFileTime, lpFatDate, lpFatTime: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "DosDateTimeToFileTime"]
    _DosDateTimeToFileTime (wFatDate, wFatTime, lpFileTime: INTEGER): INTEGER;

PROCEDURE [windows-, "kernel32.dll", "GetCurrentDirectoryA"]
    _GetCurrentDirectory (nBufferLength, lpBuffer: INTEGER): INTEGER;

PROCEDURE [windows, "kernel32.dll", "ExitProcess"]
    _ExitProcess (code: INTEGER);

PROCEDURE [ccall, "msvcrt.dll", "time"]
    _time (ptr: INTEGER): INTEGER;


PROCEDURE ExitProcess* (code: INTEGER);
BEGIN
    _ExitProcess(code)
END ExitProcess;


PROCEDURE GetCurrentDirectory* (VAR path: ARRAY OF CHAR);
VAR
    n: INTEGER;

BEGIN
    n := _GetCurrentDirectory(LEN(path), SYSTEM.ADR(path[0]));
    path[n] := slash;
    path[n + 1] := 0X
END GetCurrentDirectory;


PROCEDURE GetChar (adr: INTEGER): CHAR;
VAR
    res: CHAR;

BEGIN
    SYSTEM.GET(adr, res)
    RETURN res
END GetChar;


PROCEDURE ParamParse;
VAR
    p, count, cond: INTEGER;
    c: CHAR;


    PROCEDURE ChangeCond (A, B, C: INTEGER; VAR cond: INTEGER; c: CHAR);
    BEGIN
        IF (c <= 20X) & (c # 0X) THEN
            cond := A
        ELSIF c = 22X THEN
            cond := B
        ELSIF c = 0X THEN
            cond := 6
        ELSE
            cond := C
        END
    END ChangeCond;


BEGIN
    p := _GetCommandLine();
    cond := 0;
    count := 0;
    WHILE (count < MAX_PARAM) & (cond # 6) DO
        c := GetChar(p);
        CASE cond OF
        |0: ChangeCond(0, 4, 1, cond, c); IF cond = 1 THEN Params[count, 0] := p END
        |1: ChangeCond(0, 3, 1, cond, c); IF cond IN {0, 6} THEN Params[count, 1] := p - 1; INC(count) END
        |3: ChangeCond(3, 1, 3, cond, c); IF cond = 6 THEN Params[count, 1] := p - 1; INC(count) END
        |4: ChangeCond(5, 0, 5, cond, c); IF cond = 5 THEN Params[count, 0] := p END
        |5: ChangeCond(5, 1, 5, cond, c); IF cond = 6 THEN Params[count, 1] := p - 1; INC(count) END
        |6:
        END;
        INC(p)
    END;
    argc := count
END ParamParse;


PROCEDURE GetArg* (n: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    i, j, len: INTEGER;
    c: CHAR;

BEGIN
    j := 0;
    IF n < argc THEN
        len := LEN(s) - 1;
        i := Params[n, 0];
        WHILE (j < len) & (i <= Params[n, 1]) DO
            c := GetChar(i);
            IF c # 22X THEN
                s[j] := c;
                INC(j)
            END;
            INC(i)
        END
    END;
    s[j] := 0X
END GetArg;


PROCEDURE FileRead* (F: INTEGER; VAR Buffer: ARRAY OF CHAR; bytes: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF _ReadFile(F, SYSTEM.ADR(Buffer[0]), bytes, res, NIL) = 0 THEN
        res := -1
    END

    RETURN res
END FileRead;


PROCEDURE FileWrite* (F: INTEGER; Buffer: ARRAY OF BYTE; bytes: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF _WriteFile(F, SYSTEM.ADR(Buffer[0]), bytes, res, NIL) = 0 THEN
        res := -1
    END

    RETURN res
END FileWrite;


PROCEDURE FileCreate* (FName: ARRAY OF CHAR): INTEGER;
    RETURN _CreateFile(SYSTEM.ADR(FName[0]), 0C0000000H, 0, NIL, 2, 80H, 0)
END FileCreate;


PROCEDURE FileClose* (F: INTEGER);
BEGIN
    _CloseHandle(F)
END FileClose;


PROCEDURE FileOpen* (FName: ARRAY OF CHAR): INTEGER;
VAR
    ofstr: OFSTRUCT;
    res:   INTEGER;

BEGIN
    res := _OpenFile(SYSTEM.ADR(FName[0]), ofstr, 0);
    IF res = 0FFFFFFFFH THEN
        res := -1
    END

    RETURN res
END FileOpen;


PROCEDURE chmod* (FName: ARRAY OF CHAR);
END chmod;


(* FileReadAt - read from an open file into a buffer named by its address.
   The RVM file interface reads and writes this way rather than through open
   arrays, because File.Read is handed an address by its own caller and an
   open array cannot be built from one.
   Parameters: F - the open file; Buffer - the address to read into; bytes -
   how many bytes to read.
   Result: the number of bytes read, or -1 when the read failed. *)
PROCEDURE FileReadAt* (F, Buffer, bytes: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF _ReadFile(F, Buffer, bytes, res, NIL) = 0 THEN
        res := -1
    END

    RETURN res
END FileReadAt;


(* FileWriteAt - write to an open file from a buffer named by its address, the
   counterpart of FileReadAt above.
   Parameters: F - the open file; Buffer - the address to write from; bytes -
   how many bytes to write.
   Result: the number of bytes written, or -1 when the write failed. *)
PROCEDURE FileWriteAt* (F, Buffer, bytes: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF _WriteFile(F, Buffer, bytes, res, NIL) = 0 THEN
        res := -1
    END

    RETURN res
END FileWriteAt;


(* NoSeek (res) - TRUE when res is the INVALID_SET_FILE_POINTER that
   SetFilePointer answers on failure.  A 32-bit answer may reach a 64-bit
   INTEGER either sign-extended or zero-extended, depending on what the API
   left in the upper half of the register, so both spellings of -1 are
   recognized. *)
PROCEDURE NoSeek (res: INTEGER): BOOLEAN;
BEGIN
    RETURN (res = -1) OR (res = 0FFFFFFFFH)
END NoSeek;


(* SeekAbs (F, Offset) - move the cursor of an open file to an absolute
   offset, the position Truncate needs.  SetFilePointer wants the offset split
   into two 32-bit halves on a 64-bit target, and the BITS split below is the
   one lib/Windows/File.mod's FileSeek uses: the low half as a signed 32-bit
   value, and the address of the offset's high four bytes for the other.
   Parameters: F - the open file; Offset - the absolute offset to move to.
   Result: the new offset from the start of the file, or -1 when the call
   failed. *)
PROCEDURE SeekAbs (F, Offset: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF bit_depth = 32 THEN
        res := _SetFilePointer(F, Offset, 0, 0)
    ELSE
        res := _SetFilePointer(F, ORD(BITS(Offset) * {0..31}), SYSTEM.ADR(Offset) + 4, 0)
    END;
    IF NoSeek(res) THEN
        res := -1
    END

    RETURN res
END SeekAbs;


(* FileSeek - move the cursor of an open file.  Origin is SEEK_BEG, SEEK_CUR
   or SEEK_END (0, 1, 2), which are the FILE_BEGIN, FILE_CURRENT and
   FILE_END SetFilePointer takes as well.
   Parameters: F - the open file; Offset - how far to move; Origin - where the
   move starts from.
   Result: the new offset from the start of the file, or -1 when the call
   failed.  Only the low 32 bits of the offset come back, so an offset past
   4GB reads as -1. *)
PROCEDURE FileSeek* (F, Offset, Origin: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF bit_depth = 32 THEN
        res := _SetFilePointer(F, Offset, 0, Origin)
    ELSE
        res := _SetFilePointer(F, ORD(BITS(Offset) * {0..31}), SYSTEM.ADR(Offset) + 4, Origin)
    END;
    IF NoSeek(res) THEN
        res := -1
    END

    RETURN res
END FileSeek;


(* FileTruncate - set the length of the file behind an open handle.  A Size
   below the current length discards everything past it; a Size above it
   extends the file, and the gap reads back as zero bytes.  The cursor is left
   where it was, as POSIX ftruncate leaves it: the file's end is marked by
   seeking to Size, calling SetEndOfFile, and seeking back.
   Parameters: F - the open handle; Size - the new length in bytes.
   Result: 1 when the length was set, 0 when it was not. *)
PROCEDURE FileTruncate* (F, Size: INTEGER): INTEGER;
VAR
    res, cur: INTEGER;

BEGIN
    res := 0;
    cur := FileSeek(F, 0, 1);              (* SEEK_CUR: where the cursor is *)
    IF (cur >= 0) & (SeekAbs(F, Size) >= 0) & (_SetEndOfFile(F) # 0) THEN
        res := 1
    END;
    cur := FileSeek(F, cur, 0)             (* put the cursor back *)

    RETURN res
END FileTruncate;


(* FileOpenMode - open an existing file for reading, writing or both.  Mode is
   OPEN_R, OPEN_W or OPEN_RW (0, 1, 2), whose values are exactly the OF_READ,
   OF_WRITE and OF_READWRITE styles OpenFile takes.
   Parameters: FName - the file to open; Mode - how it is to be opened.
   Result: the handle, or -1 when the file could not be opened. *)
PROCEDURE FileOpenMode* (FName: ARRAY OF CHAR; Mode: INTEGER): INTEGER;
VAR
    ofstr: OFSTRUCT;
    res:   INTEGER;

BEGIN
    res := _OpenFile(SYSTEM.ADR(FName[0]), ofstr, Mode);
    IF res = 0FFFFFFFFH THEN
        res := -1
    END

    RETURN res
END FileOpenMode;


(* FileDelete - remove a file (DeleteFileA).  A directory is not a file here
   and is refused; FileRemoveDir is the call for that.
   Parameters: FName - the file to remove.
   Result: 1 when it is gone, 0 when it is not there or could not be
   removed. *)
PROCEDURE FileDelete* (FName: ARRAY OF CHAR): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF _DeleteFile(SYSTEM.ADR(FName[0])) = 0 THEN
        res := 0
    ELSE
        res := 1
    END

    RETURN res
END FileDelete;


(* FileRename - rename or move a file (MoveFileA).  Either name may be a full
   path, so the two may be in different directories, in which case the file
   moves; a file already sitting under NewName is replaced.
   Parameters: OldName - the file to rename; NewName - the name it should
   carry afterwards.
   Result: 1 when the rename succeeded, 0 when it did not. *)
PROCEDURE FileRename* (OldName, NewName: ARRAY OF CHAR): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF _MoveFile(SYSTEM.ADR(OldName[0]), SYSTEM.ADR(NewName[0])) = 0 THEN
        res := 0
    ELSE
        res := 1
    END

    RETURN res
END FileRename;


(* FindAttr (FName) - the WIN32_FIND_DATA attributes of the file or directory
   FName names, or -1 when nothing of that name is there.  FindFirstFileA
   fills a 320-byte WIN32_FIND_DATA, whose first field is the attributes
   DWORD, at offset 0; the rest of the struct is never looked at, and the
   handle it answers is closed right away.
   Parameters: FName - the name to look up.
   Result: the attribute bits, or -1 when the name is not there. *)
PROCEDURE FindAttr (FName: ARRAY OF CHAR): INTEGER;
VAR
    find: ARRAY 320 OF BYTE;
    h, res: INTEGER;

BEGIN
    res := -1;
    h := _FindFirstFile(SYSTEM.ADR(FName[0]), SYSTEM.ADR(find[0]));
    IF h # -1 THEN
        _FindClose(h);                       (* whatever it is, it is open *)
        res := 0;                            (* clear the half GET32 leaves *)
        SYSTEM.GET32(SYSTEM.ADR(find[0]), res)
    END

    RETURN res
END FindAttr;


(* IsDir (attr) - TRUE when FindAttr's attribute bits say "directory": bit 4
   (10H, FILE_ATTRIBUTE_DIRECTORY).  This dialect defines no AND, so the bit
   is picked out with DIV and MOD. *)
PROCEDURE IsDir (attr: INTEGER): BOOLEAN;
BEGIN
    RETURN (attr DIV 16) MOD 2 # 0
END IsDir;


(* FileExists - test for a file that is not a directory, matching the Exists
   of the Windows File module.
   Parameters: FName - the name to test.
   Result: 1 when FName names a file, 0 otherwise. *)
PROCEDURE FileExists* (FName: ARRAY OF CHAR): INTEGER;
VAR
    attr, res: INTEGER;

BEGIN
    attr := FindAttr(FName);
    IF (attr < 0) OR IsDir(attr) THEN
        res := 0
    ELSE
        res := 1
    END

    RETURN res
END FileExists;


(* FileDirExists - test for a directory, the ExistsDir of the Windows File
   module.
   Parameters: FName - the name to test.
   Result: 1 when FName names a directory, 0 otherwise. *)
PROCEDURE FileDirExists* (FName: ARRAY OF CHAR): INTEGER;
VAR
    attr, res: INTEGER;

BEGIN
    attr := FindAttr(FName);
    IF (attr >= 0) & IsDir(attr) THEN
        res := 1
    ELSE
        res := 0
    END

    RETURN res
END FileDirExists;


(* FileMakeDir - create a directory (CreateDirectoryA).  The parent directory
   has to be there already.
   Parameters: FName - the directory to create.
   Result: 1 when it was created, 0 when it was not - because it is already
   there, or because a parent of it is missing. *)
PROCEDURE FileMakeDir* (FName: ARRAY OF CHAR): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF _CreateDirectory(SYSTEM.ADR(FName[0]), NIL) = 0 THEN
        res := 0
    ELSE
        res := 1
    END

    RETURN res
END FileMakeDir;


(* FileRemoveDir - remove an empty directory (RemoveDirectoryA).  A directory
   with anything in it is refused.
   Parameters: FName - the directory to remove.
   Result: 1 when it is gone, 0 when it is not. *)
PROCEDURE FileRemoveDir* (FName: ARRAY OF CHAR): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF _RemoveDirectory(SYSTEM.ADR(FName[0])) = 0 THEN
        res := 0
    ELSE
        res := 1
    END

    RETURN res
END FileRemoveDir;


(* FileGetTime - the last write time of a file, packed into the 32-bit DOS
   date/time the project passes around: bits 0..4 seconds DIV 2, bits 5..10
   minutes, bits 11..15 hours, bits 16..20 day, bits 21..24 month, bits
   25..31 year - 1980.  The file is opened with FILE_READ_ATTRIBUTES (80H)
   and full sharing, which is enough for a timestamp even while something else
   has the file open, and GetFileTime fills an 8-byte FILETIME that
   FileTimeToDosDateTime splits into the two 16-bit words - the date half
   first, then the time half, which is the order the packed form wants.
   Parameters: FName - the file to look at.
   Result: the packed date/time, or -1 when the file could not be opened or
   carries no timestamp. *)
PROCEDURE FileGetTime* (FName: ARRAY OF CHAR): INTEGER;
VAR
    ft: ARRAY 8 OF BYTE;
    h, res, date, time: INTEGER;

BEGIN
    res := -1;
    h := _CreateFile(SYSTEM.ADR(FName[0]), 80H, 3, NIL, 3, 80H, 0);
    IF h # -1 THEN
        date := 0;
        time := 0;
        IF (_GetFileTime(h, 0, 0, SYSTEM.ADR(ft[0])) # 0) &
           (_FileTimeToDosDateTime(SYSTEM.ADR(ft[0]), SYSTEM.ADR(date), SYSTEM.ADR(time)) # 0) THEN
            res := date * 65536 + time
        END;
        _CloseHandle(h)
    END

    RETURN res
END FileGetTime;


(* FileSetTime - stamp the last write time of a file with a packed DOS
   date/time, as FileGetTime returns one.  The DOS form carries no separate
   access time and neither does the FAT timestamp it stands for, so only the
   write time is set.  The file is opened with FILE_WRITE_ATTRIBUTES (100H)
   and full sharing; DosDateTimeToFileTime builds the FILETIME from the date
   and time halves of the packed value, high half first.
   Parameters: FName - the file to stamp; Time - the packed time to stamp it
   with.
   Result: 1 when the stamp was applied, 0 when the file could not be opened
   or the stamp was refused. *)
PROCEDURE FileSetTime* (FName: ARRAY OF CHAR; Time: INTEGER): INTEGER;
VAR
    ft: ARRAY 8 OF BYTE;
    h, res: INTEGER;

BEGIN
    res := 0;
    IF Time < 0 THEN
        Time := 0                    (* no date at all: pin it to the epoch *)
    END;
    h := _CreateFile(SYSTEM.ADR(FName[0]), 100H, 3, NIL, 3, 80H, 0);
    IF h # -1 THEN
        IF (_DosDateTimeToFileTime(Time DIV 65536, Time MOD 65536, SYSTEM.ADR(ft[0])) # 0) &
           (_SetFileTime(h, 0, 0, SYSTEM.ADR(ft[0])) # 0) THEN
            res := 1
        END;
        _CloseHandle(h)
    END

    RETURN res
END FileSetTime;


PROCEDURE OutChar* (c: CHAR);
VAR
    count: INTEGER;
BEGIN
    _WriteFile(hConsoleOutput, SYSTEM.ADR(c), 1, count, NIL)
END OutChar;


PROCEDURE GetTickCount* (): INTEGER;
    RETURN _GetTickCount() DIV 10
END GetTickCount;


PROCEDURE letter (c: CHAR): BOOLEAN;
    RETURN ("a" <= c) & (c <= "z") OR ("A" <= c) & (c <= "Z")
END letter;


PROCEDURE isRelative* (path: ARRAY OF CHAR): BOOLEAN;
    RETURN ~(letter(path[0]) & (path[1] = ":"))
END isRelative;


PROCEDURE UnixTime* (): INTEGER;
    RETURN _time(0)
END UnixTime;


PROCEDURE splitf* (x: REAL; VAR a, b: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    a := 0;
    b := 0;
    SYSTEM.GET32(SYSTEM.ADR(x), a);
    SYSTEM.GET32(SYSTEM.ADR(x) + 4, b);
    SYSTEM.GET(SYSTEM.ADR(x), res)
    RETURN res
END splitf;


PROCEDURE d2s* (x: REAL): INTEGER;
VAR
    h, l, s, e: INTEGER;

BEGIN
    e := splitf(x, l, h);

    s := ASR(h, 31) MOD 2;
    e := (h DIV 100000H) MOD 2048;
    IF e <= 896 THEN
        h := (h MOD 100000H) * 8 + (l DIV 20000000H) MOD 8 + 800000H;
        REPEAT
            h := h DIV 2;
            INC(e)
        UNTIL e = 897;
        e := 896;
        l := (h MOD 8) * 20000000H;
        h := h DIV 8
    ELSIF (1151 <= e) & (e < 2047) THEN
        e := 1151;
        h := 0;
        l := 0
    ELSIF e = 2047 THEN
        e := 1151;
        IF (h MOD 100000H # 0) OR (BITS(l) * {0..31} # {}) THEN
            h := 80000H;
            l := 0
        END
    END;
    DEC(e, 896)

    RETURN LSL(s, 31) + LSL(e, 23) + (h MOD 100000H) * 8 + (l DIV 20000000H) MOD 8
END d2s;


BEGIN
    inf := SYSTEM.INF();
    maxreal := 1.9;
    PACK(maxreal, 1023);
    hConsoleOutput := _GetStdHandle(-11);
    ParamParse
END HOST.