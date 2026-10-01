(*
    BSD 2-Clause License

    Copyright (c) 2019-2021, Anton Krotov
    All rights reserved.
*)

MODULE ArchFile;

(*
   The Windows file system, and its names are Unicode.

   EVERY NAME-TAKING CALL HERE IS THE WIDE ONE, and that is the whole of what
   this file is about.  A name arrives as UTF-8 - that is what the portable
   layer above speaks and what a file dialog hands back - and the narrow Win32
   entry points take it as bytes of the ANSI code page, so a Russian name
   reaches them as a different name and the call answers "no such file".  The
   dialog would list the file and then refuse to open it.  Widen turns the UTF-8
   into the UTF-16 the wide calls want, and every call below is the W twin of
   the A one it used to be.

   That includes Open, which used OpenFile - a Win16 relic in kernel32 with no
   wide twin at all, so there is no way to make it take a Unicode name.  It is
   CreateFileW now, with the same three sharing and disposition values the other
   callers here already pass, and the one visible difference is that a name that
   does not exist is refused by name rather than by an error code - which is what
   every caller tests for anyway (Valid).

   Nothing else about this module changes: the handle, the seek, the read and
   the write are byte calls and were never told the name. *)

IMPORT SYSTEM, WINAPI, API, Strings;


CONST

    OPEN_R* = 0;     OPEN_W* = 1;     OPEN_RW* = 2;
    SEEK_BEG* = 0;   SEEK_CUR* = 1;   SEEK_END* = 2;

    DOS_EPOCH_YEAR = 1980;              (* the first year a DOS date holds *)
    DOS_LAST_YEAR  = 2107;              (* the last: 1980 + 127 *)

    OPEN_EXISTING         = 3;          (* CreateFileW disposition *)
    SHARE_RW              = 3;          (* FILE_SHARE_READ OR FILE_SHARE_WRITE *)
    FILE_READ_ATTRIBUTES  = 80H;
    FILE_WRITE_ATTRIBUTES = 100H;

    GENERIC_READ          = 80000000H;  (* the two halves of CreateFileW's *)
    GENERIC_WRITE         = 40000000H;  (* dwDesiredAccess, as Create asks for
                                           both of them at once *)
    GENERIC_RW            = 0C0000000H;

    (* The UTF-16 buffer a name is widened into before a call.  A Win32 path is
       at most MAX_PATH characters, 260, and this is four times that, so a name
       longer than Windows itself allows is the only one that is cut - and it is
       cut by Utf8To16, at a whole character, with a terminator. *)
    WMAX = 1024;


(* A name as Windows wants it: the UTF-8 the layer above speaks, widened into
   the caller's UTF-16 buffer.  The count Utf8To16 answers is not wanted here -
   every name below is passed to the system as a terminated string and nothing
   reads its length - and a function call cannot stand as a statement in this
   language, which is why this wrapper is a proper procedure and not a call. *)
PROCEDURE Widen (FName: ARRAY OF CHAR; VAR w: ARRAY OF WCHAR);
VAR n: INTEGER;
BEGIN
    n := Strings.Utf8To16(FName, w)
END Widen;


PROCEDURE Exists* (FName: ARRAY OF CHAR): BOOLEAN;
VAR
    FindData: WINAPI.TWin32FindDataW;
    Handle:   INTEGER;
    attr:     SET;
    w:        ARRAY WMAX OF WCHAR;

BEGIN
    Widen(FName, w);
    Handle := WINAPI.FindFirstFileW(SYSTEM.ADR(w[0]), FindData);
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
VAR w: ARRAY WMAX OF WCHAR;
BEGIN
    Widen(FName, w);
    RETURN WINAPI.DeleteFileW(SYSTEM.ADR(w[0])) # 0
END Delete;


PROCEDURE Create* (FName: ARRAY OF CHAR): INTEGER;
VAR w: ARRAY WMAX OF WCHAR;
BEGIN
    Widen(FName, w);
    RETURN WINAPI.CreateFileW(SYSTEM.ADR(w[0]), GENERIC_RW, 0, NIL, 2, 80H, 0)
END Create;


PROCEDURE Close* (F: INTEGER);
BEGIN
    WINAPI.CloseHandle(F)
END Close;


(* Valid - TRUE when F is an open handle: one that Open, Create or Load
   returned successfully.  Every one of those is CreateFileW now, and every one
   of them answers -1 when it fails; on win64 that same 32-bit result can reach
   a caller as 4294967295 instead, so both spellings count as failure here.
   FindFirstFileW answers INVALID_HANDLE_VALUE too, which a HANDLE carries as a
   full 64-bit -1.
   Parameters: F - the handle.
   Result: TRUE when F may be read, written, seeked or closed. *)
PROCEDURE Valid* (F: INTEGER): BOOLEAN;
BEGIN
    RETURN (F # -1) & (F # 0FFFFFFFFH)
END Valid;


(* Open an existing file.  This was OpenFile, which cannot be given a Unicode
   name at all - it has no wide twin - so it is CreateFileW now, opening what is
   already there and never making one.  The access is the mode the caller asked
   for, the sharing is the same SHARE_RW the attribute calls below use, and the
   answer is INVALID_HANDLE_VALUE when the name is not there, which is what every
   caller of this tests against. *)
PROCEDURE Open* (FName: ARRAY OF CHAR; Mode: INTEGER): INTEGER;
VAR
    w:     ARRAY WMAX OF WCHAR;
    acc:   INTEGER;
    res:   INTEGER;

BEGIN
    acc := GENERIC_READ;
    IF Mode = OPEN_W THEN
        acc := GENERIC_WRITE
    ELSIF Mode = OPEN_RW THEN
        acc := GENERIC_RW
    END;

    Widen(FName, w);
    res := WINAPI.CreateFileW(SYSTEM.ADR(w[0]), acc, SHARE_RW, NIL,
                              OPEN_EXISTING, 80H, 0);
    IF res = 0FFFFFFFFH THEN
        (* CreateFileW answers INVALID_HANDLE_VALUE, which a HANDLE carries as a
           full 64-bit -1; on win64 that same 32-bit result can reach a caller
           as 4294967295 instead.  Every caller tests against -1, so fold the two
           spellings into one - which is what this did for OpenFile's
           HFILE_ERROR before it. *)
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
VAR w: ARRAY WMAX OF WCHAR;
BEGIN
    Widen(DirName, w);
    RETURN WINAPI.RemoveDirectoryW(SYSTEM.ADR(w[0])) # 0
END RemoveDir;


PROCEDURE ExistsDir* (DirName: ARRAY OF CHAR): BOOLEAN;
VAR
    Code: SET;
    w:    ARRAY WMAX OF WCHAR;

BEGIN
    Widen(DirName, w);
    Code := WINAPI.GetFileAttributesW(SYSTEM.ADR(w[0]))
    RETURN (Code # {0..31}) & (4 IN Code)
END ExistsDir;


PROCEDURE CreateDir* (DirName: ARRAY OF CHAR): BOOLEAN;
VAR w: ARRAY WMAX OF WCHAR;
BEGIN
    Widen(DirName, w);
    RETURN WINAPI.CreateDirectoryW(SYSTEM.ADR(w[0]), NIL) # 0
END CreateDir;


(* Rename - gives the file OldName the name NewName, which may place it in
   another directory of the same volume.  MoveFileW is the Win32 rename
   call; it refuses, and this answers FALSE, when NewName is already there.
   Parameters: OldName - the name to rename; NewName - the name to use.
   Result: TRUE when the file was renamed. *)
PROCEDURE Rename* (OldName, NewName: ARRAY OF CHAR): BOOLEAN;
VAR wo, wn: ARRAY WMAX OF WCHAR;
BEGIN
    Widen(OldName, wo);
    Widen(NewName, wn);
    RETURN WINAPI.MoveFileW(SYSTEM.ADR(wo[0]), SYSTEM.ADR(wn[0])) # 0
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
    w:   ARRAY WMAX OF WCHAR;

BEGIN
    res  := FALSE;
    time := 0;
    Widen(FName, w);
    h := WINAPI.CreateFileW(SYSTEM.ADR(w[0]), FILE_READ_ATTRIBUTES,
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
    w:   ARRAY WMAX OF WCHAR;

BEGIN
    res := FALSE;
    Widen(FName, w);
    h := WINAPI.CreateFileW(SYSTEM.ADR(w[0]), FILE_WRITE_ATTRIBUTES,
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