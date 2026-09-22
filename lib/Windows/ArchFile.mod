(*
    BSD 2-Clause License

    Copyright (c) 2019-2021, Anton Krotov
    All rights reserved.
*)

MODULE ArchFile;

IMPORT SYSTEM, WINAPI, API;


CONST

    OPEN_R* = 0;     OPEN_W* = 1;     OPEN_RW* = 2;
    SEEK_BEG* = 0;   SEEK_CUR* = 1;   SEEK_END* = 2;

    DOS_EPOCH_YEAR = 1980;              (* the first year a DOS date holds *)
    DOS_LAST_YEAR  = 2107;              (* the last: 1980 + 127 *)

    OPEN_EXISTING         = 3;          (* CreateFileA disposition *)
    SHARE_RW              = 3;          (* FILE_SHARE_READ OR FILE_SHARE_WRITE *)
    FILE_READ_ATTRIBUTES  = 80H;
    FILE_WRITE_ATTRIBUTES = 100H;


PROCEDURE Exists* (FName: ARRAY OF CHAR): BOOLEAN;
VAR
    FindData: WINAPI.TWin32FindData;
    Handle:   INTEGER;
    attr:     SET;

BEGIN
    Handle := WINAPI.FindFirstFileA(SYSTEM.ADR(FName[0]), FindData);
    IF Handle # -1 THEN
        WINAPI.FindClose(Handle);
        SYSTEM.GET32(SYSTEM.ADR(FindData.dwFileAttributes), attr);
        IF 4 IN attr THEN
            Handle := -1
        END
    END

    RETURN Handle # -1
END Exists;


PROCEDURE Delete* (FName: ARRAY OF CHAR): BOOLEAN;
    RETURN WINAPI.DeleteFileA(SYSTEM.ADR(FName[0])) # 0
END Delete;


PROCEDURE Create* (FName: ARRAY OF CHAR): INTEGER;
    RETURN WINAPI.CreateFileA(SYSTEM.ADR(FName[0]), 0C0000000H, 0, NIL, 2, 80H, 0)
END Create;


PROCEDURE Close* (F: INTEGER);
BEGIN
    WINAPI.CloseHandle(F)
END Close;


(* Valid - TRUE when F is an open handle: one that Open, Create or Load
   returned successfully.  OpenFile answers -1 when it fails, and on win64
   that same 32-bit result can reach a caller as 4294967295 instead, so both
   spellings count as failure here.  CreateFileA and FindFirstFileA answer
   INVALID_HANDLE_VALUE, which a HANDLE carries as a full 64-bit -1.
   Parameters: F - the handle.
   Result: TRUE when F may be read, written, seeked or closed. *)
PROCEDURE Valid* (F: INTEGER): BOOLEAN;
BEGIN
    RETURN (F # -1) & (F # 0FFFFFFFFH)
END Valid;


PROCEDURE Open* (FName: ARRAY OF CHAR; Mode: INTEGER): INTEGER;
VAR
    ofstr: WINAPI.OFSTRUCT;
    res:   INTEGER;

BEGIN
    res := WINAPI.OpenFile(SYSTEM.ADR(FName[0]), ofstr, Mode);
    IF res = 0FFFFFFFFH THEN
        (* OpenFile answers HFILE_ERROR, which is -1 in 32 bits, but it is a
           32-bit result: the win64 ABI leaves the top half of RAX to the
           callee, so it arrives here as 4294967295 and not as -1.  Every
           caller tests against -1, so fold the two spellings into one. *)
        res := -1
    END;

    RETURN res
END Open;


PROCEDURE Seek* (F, Offset, Origin: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF API.BIT_DEPTH = 32 THEN
        res := WINAPI.SetFilePointer(F, Offset, 0, Origin)
    ELSE
        res := WINAPI.SetFilePointer(F, ORD(BITS(Offset) * {0..31}), SYSTEM.ADR(Offset) + 4, Origin)
    END

    RETURN res
END Seek;


PROCEDURE Read* (F, Buffer, Count: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF WINAPI.ReadFile(F, Buffer, Count, SYSTEM.ADR(res), NIL) = 0 THEN
        res := -1
    END

    RETURN res
END Read;


PROCEDURE Write* (F, Buffer, Count: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF WINAPI.WriteFile(F, Buffer, Count, SYSTEM.ADR(res), NIL) = 0 THEN
        res := -1
    END

    RETURN res
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
    RETURN WINAPI.RemoveDirectoryA(SYSTEM.ADR(DirName[0])) # 0
END RemoveDir;


PROCEDURE ExistsDir* (DirName: ARRAY OF CHAR): BOOLEAN;
VAR
    Code: SET;

BEGIN
    Code := WINAPI.GetFileAttributesA(SYSTEM.ADR(DirName[0]))
    RETURN (Code # {0..31}) & (4 IN Code)
END ExistsDir;


PROCEDURE CreateDir* (DirName: ARRAY OF CHAR): BOOLEAN;
    RETURN WINAPI.CreateDirectoryA(SYSTEM.ADR(DirName[0]), NIL) # 0
END CreateDir;


(* Rename - gives the file OldName the name NewName, which may place it in
   another directory of the same volume.  MoveFileA is the Win32 rename
   call; it refuses, and this answers FALSE, when NewName is already there.
   Parameters: OldName - the name to rename; NewName - the name to use.
   Result: TRUE when the file was renamed. *)
PROCEDURE Rename* (OldName, NewName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN WINAPI.MoveFileA(SYSTEM.ADR(OldName[0]), SYSTEM.ADR(NewName[0])) # 0
END Rename;


(* Truncate - shrinks or extends the file behind the open handle F to Size
   bytes.  The two moves and the marking of the new end all go through Seek,
   so the 64-bit offset win64con needs is the one Seek already builds; what
   is done here is seeking to the length wanted, telling the system that is
   now the end of the file, and then putting the handle back where the
   caller had it, so a read or a write carried on afterwards still lands
   where it would have.
   Parameters: F - the handle; Size - the length to leave the file with.
   Result: TRUE when the file is Size bytes long and the handle is back
   where it was. *)
PROCEDURE Truncate* (F, Size: INTEGER): BOOLEAN;
VAR
    pos: INTEGER;
    res: BOOLEAN;

BEGIN
    res := FALSE;
    pos := Seek(F, 0, SEEK_CUR);

    IF pos # -1 THEN
        IF Seek(F, Size, SEEK_BEG) # -1 THEN
            IF WINAPI.SetEndOfFile(F) # 0 THEN
                res := TRUE
            END
        END;
        IF Seek(F, pos, SEEK_BEG) = -1 THEN
            res := FALSE
        END
    END

    RETURN res
END Truncate;


(* The packed time is the 32-bit DOS date/time word the rest of the project
   uses: bits 0..4 seconds DIV 2, bits 5..10 minutes, bits 11..15 hours,
   bits 16..20 day, bits 21..24 month, bits 25..31 year - 1980.  It reads as
   (date SHL 16) OR timeOfDay, and it is a local wall-clock stamp.

   Win32 keeps every file stamp as a FILETIME - 100-nanosecond intervals
   counted from 1601-01-01 - and FileTimeToSystemTime turns one into the
   civil fields of a TSystemTime, SystemTimeToFileTime the reverse.  Those
   two calls are where the shift between the 1601 and the 1980 epoch is
   done: a FILETIME is a 64-bit count, so a hand-written shift would need
   64-bit division and multiplication, and neither that count nor the
   seconds from 1980 to the end of the DOS range fit in the 32-bit INTEGER
   win32con builds this module with.  All that is left here is the packing
   of the civil fields into the DOS word, done by the two private
   procedures below. *)


(* PackDosTime - packs a civil date and time into the DOS date/time word.
   The word can only count from 1980 to 2107, so a stamp from before 1980
   is clamped onto the DOS epoch, 1980-01-01 00:00:00, and one from after
   December 2107 onto 2107-12-31 23:59:58.
   Parameters: Y, M, D, h, m, s - the civil date and time to pack.
   Result: the packed date/time. *)
PROCEDURE PackDosTime (Y, M, D, h, m, s: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF Y < DOS_EPOCH_YEAR THEN
        Y := DOS_EPOCH_YEAR; M := 1; D := 1; h := 0; m := 0; s := 0
    ELSIF Y > DOS_LAST_YEAR THEN
        Y := DOS_LAST_YEAR; M := 12; D := 31; h := 23; m := 59; s := 58
    END;

    res := LSL(Y - DOS_EPOCH_YEAR, 25) + LSL(M, 21) + LSL(D, 16) +
           LSL(h, 11) + LSL(m, 5) + s DIV 2

    RETURN res
END PackDosTime;


(* UnpackDosTime - unpacks the DOS date/time word into the civil fields of a
   TSystemTime, ready for SystemTimeToFileTime.  The year needs no check:
   the word holds 1980..2107 by construction.  The other fields are wider
   than a calendar is - six bits of minute, five of hour, four of month - and
   a day or a month of zero is not a date at all, so each is clamped to
   something the conversion accepts.  That also makes a word of zeroes read
   back as the DOS epoch, 1980-01-01 00:00:00.
   Parameters: time - the packed date/time to unpack; st - the TSystemTime
   it is written to. *)
PROCEDURE UnpackDosTime (time: INTEGER; VAR st: WINAPI.TSystemTime);
VAR
    sec, min, hour, day, month, year, zero: INTEGER;

BEGIN
    sec   := (time MOD 32) * 2;
    min   := (time DIV 32) MOD 64;
    hour  := (time DIV 2048) MOD 32;
    day   := (time DIV 65536) MOD 32;
    month := (time DIV 2097152) MOD 16;
    year  := (time DIV 33554432) MOD 128 + DOS_EPOCH_YEAR;
    zero  := 0;

    IF sec > 59 THEN sec := 59 END;
    IF min > 59 THEN min := 59 END;
    IF hour > 23 THEN hour := 23 END;
    IF day > 31 THEN day := 31 ELSIF day < 1 THEN day := 1 END;
    IF month > 12 THEN month := 12 ELSIF month < 1 THEN month := 1 END;

    (* A WCHAR field will not take an INTEGER directly, and SYSTEM.VAL wants
       a designator rather than a constant; the four fields that matter are
       therefore converted from their local variables and the two the API
       does not use, DayOfWeek and MSec, from zero. *)
    st.Year      := SYSTEM.VAL(WCHAR, year);
    st.Month     := SYSTEM.VAL(WCHAR, month);
    st.DayOfWeek := SYSTEM.VAL(WCHAR, zero);
    st.Day       := SYSTEM.VAL(WCHAR, day);
    st.Hour      := SYSTEM.VAL(WCHAR, hour);
    st.Min       := SYSTEM.VAL(WCHAR, min);
    st.Sec       := SYSTEM.VAL(WCHAR, sec);
    st.MSec      := SYSTEM.VAL(WCHAR, zero)
END UnpackDosTime;


(* GetTime - reads the last-write time of the file FName as the packed DOS
   date/time word described above.  GetFileTime answers in UTC, so the stamp
   goes through FileTimeToLocalFileTime first: the DOS word is local time.
   Parameters: FName - the name of the file; time - the stamp read, or 0.
   Result: TRUE when the file exists and its stamp was read, FALSE when it
   does not exist. *)
PROCEDURE GetTime* (FName: ARRAY OF CHAR; VAR time: INTEGER): BOOLEAN;
VAR
    st:  WINAPI.TSystemTime;
    ft:  WINAPI.TFileTime;
    lft: WINAPI.TFileTime;
    h:   INTEGER;
    res: BOOLEAN;

BEGIN
    res  := FALSE;
    time := 0;
    h := WINAPI.CreateFileA(SYSTEM.ADR(FName[0]), FILE_READ_ATTRIBUTES,
                            SHARE_RW, NIL, OPEN_EXISTING, 0, 0);

    IF h # -1 THEN
        IF WINAPI.GetFileTime(h, 0, 0, SYSTEM.ADR(ft.dwLowDateTime)) # 0 THEN
            IF WINAPI.FileTimeToLocalFileTime(SYSTEM.ADR(ft.dwLowDateTime),
                       SYSTEM.ADR(lft.dwLowDateTime)) # 0 THEN
                IF WINAPI.FileTimeToSystemTime(SYSTEM.ADR(lft.dwLowDateTime),
                           SYSTEM.ADR(st.Year)) # 0 THEN
                    time := PackDosTime(ORD(st.Year), ORD(st.Month),
                                        ORD(st.Day), ORD(st.Hour),
                                        ORD(st.Min), ORD(st.Sec));
                    res := TRUE
                END
            END
        END;
        WINAPI.CloseHandle(h)
    END

    RETURN res
END GetTime;


(* SetTime - sets the last-write time of the file FName to the packed DOS
   date/time word described above.  The word is local time, so the FILETIME
   SystemTimeToFileTime produces goes through LocalFileTimeToFileTime before
   SetFileTime stores it.
   Parameters: FName - the name of the file; time - the packed date/time.
   Result: TRUE when the file exists and its stamp was set. *)
PROCEDURE SetTime* (FName: ARRAY OF CHAR; time: INTEGER): BOOLEAN;
VAR
    st:  WINAPI.TSystemTime;
    ft:  WINAPI.TFileTime;
    lft: WINAPI.TFileTime;
    h:   INTEGER;
    res: BOOLEAN;

BEGIN
    res := FALSE;
    h := WINAPI.CreateFileA(SYSTEM.ADR(FName[0]), FILE_WRITE_ATTRIBUTES,
                            SHARE_RW, NIL, OPEN_EXISTING, 0, 0);

    IF h # -1 THEN
        UnpackDosTime(time, st);
        IF WINAPI.SystemTimeToFileTime(SYSTEM.ADR(st.Year),
                   SYSTEM.ADR(lft.dwLowDateTime)) # 0 THEN
            IF WINAPI.LocalFileTimeToFileTime(SYSTEM.ADR(lft.dwLowDateTime),
                       SYSTEM.ADR(ft.dwLowDateTime)) # 0 THEN
                IF WINAPI.SetFileTime(h, 0, 0,
                           SYSTEM.ADR(ft.dwLowDateTime)) # 0 THEN
                    res := TRUE
                END
            END
        END;
        WINAPI.CloseHandle(h)
    END

    RETURN res
END SetTime;


END ArchFile.