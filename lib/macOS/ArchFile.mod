(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    macOS file primitives using libSystem through API. C int results are
    normalized there; read/write retry interrupted calls.
*)

MODULE ArchFile;

IMPORT SYSTEM, API;


CONST

    OPEN_R* = 0;   OPEN_W* = 1;   OPEN_RW* = 2;
    SEEK_BEG* = 0; SEEK_CUR* = 1; SEEK_END* = 2;

    O_RDONLY = 0; O_WRONLY = 1; O_RDWR = 2;
    O_CREAT  = 0200H; O_TRUNC = 0400H;

    (* x86-64 Darwin stat$INODE64, verified against the installed SDK and
       native stat calls: sizeof = 144, mode_t = uint16 at 4, mtime at 48. *)
    STAT_SIZE = 144;
    ST_MODE_OFFS = 4;
    S_IFMT = 0F000H; S_IFDIR = 04000H;
    ST_MTIME_OFFS = 48;

    (* 1980-01-01 00:00:00 UTC - the earliest instant the packed DOS date/time
       can hold - as seconds since the Unix epoch *)
    DOS_EPOCH = 315532800;


TYPE

    (* struct timeval on x86-64 Darwin, as libc utimes reads it: an
       8-byte time_t tv_sec at offset 0, then a 4-byte suseconds_t tv_usec at
       offset 8, padded out to 16 bytes.  INTEGER is 64 bits on this target
       (API.BIT_DEPTH = 64), so this record has exactly that shape: tvSec
       lands at 0 and tvUsec at 8.  The kernel reads only the low four bytes of
       tvUsec, and this module sets them to zero, so the upper half is never
       looked at.
       Checked against the native x86-64 Darwin layout. *)
    TimeVal = RECORD tvSec, tvUsec: INTEGER END;


PROCEDURE OpenFlags (Mode: INTEGER): INTEGER;
VAR
    res: INTEGER;
BEGIN
    CASE Mode OF
    |OPEN_W:  res := O_WRONLY
    |OPEN_RW: res := O_RDWR
    ELSE      res := O_RDONLY
    END
    RETURN res
END OpenFlags;


PROCEDURE GetAttr (FName: ARRAY OF CHAR; VAR mode: INTEGER): BOOLEAN;
VAR
    st: ARRAY STAT_SIZE OF BYTE;
    res: INTEGER;

BEGIN
    res := API.Stat(SYSTEM.ADR(FName[0]), SYSTEM.ADR(st[0]));
    IF res >= 0 THEN
        mode := 0;
        SYSTEM.GET16(SYSTEM.ADR(st[0]) + ST_MODE_OFFS, mode)
    END

    RETURN res >= 0
END GetAttr;


(* CivilFromDays - the calendar date a count of whole days since the Unix
   epoch (1970-01-01) falls on.  This is Howard Hinnant's civil_from_days
   algorithm: adding 719468 shifts the epoch to 0000-03-01, which pushes the
   leap day to the end of the shifted year and makes every shifted year
   exactly 146097/400 days long.  The shifted day count then splits into
   400-year eras, years inside the era, and finally a month and a day through
   the (153*mp+2)/5 month-length trick, so no table and no per-month branch is
   needed.  Every value here is non-negative - the caller clamps to 1980-01-01,
   the 3652nd day after the Unix epoch - so Oberon's floored DIV needs no sign
   correction.
   Parameters: days - days since 1970-01-01, at least 3652.
   Parameters: y - the year found; mo - the month (1..12) found; d - the day
   (1..31) found. *)
PROCEDURE CivilFromDays (days: INTEGER; VAR y, mo, d: INTEGER);
VAR
    z, era, doe, yoe, doy, mp: INTEGER;

BEGIN
    z   := days + 719468;
    era := z DIV 146097;
    doe := z - era * 146097;                            (* 0 .. 146096 *)
    yoe := (doe - doe DIV 1460 + doe DIV 36524 - doe DIV 146096) DIV 365;
    y   := yoe + era * 400;
    doy := doe - (365 * yoe + yoe DIV 4 - yoe DIV 100); (* 0 .. 365 *)
    mp  := (5 * doy + 2) DIV 153;                       (* 0 .. 11 *)
    d   := doy - (153 * mp + 2) DIV 5 + 1;              (* 1 .. 31 *)
    IF mp < 10 THEN
        mo := mp + 3
    ELSE
        mo := mp - 9
    END;
    IF mo <= 2 THEN
        y := y + 1
    END
END CivilFromDays;


(* DaysFromCivil - the inverse of CivilFromDays: the number of whole days
   since 1970-01-01 that a calendar date falls after.  It is the same epoch
   shift run backwards, and it too expects non-negative operands - SetTime
   only ever passes a year of 1980 or later.
   Parameters: y - the year; mo - the month (1..12); d - the day (1..31).
   Result: days since 1970-01-01. *)
PROCEDURE DaysFromCivil (y, mo, d: INTEGER): INTEGER;
VAR
    yy, era, yoe, doe, doy, mp: INTEGER;

BEGIN
    IF mo <= 2 THEN
        yy := y - 1
    ELSE
        yy := y
    END;
    era := yy DIV 400;
    yoe := yy - era * 400;                              (* 0 .. 399 *)
    IF mo > 2 THEN
        mp := mo - 3
    ELSE
        mp := mo + 9
    END;
    doy := (153 * mp + 2) DIV 5 + d - 1;                (* 0 .. 365 *)
    doe := yoe * 365 + yoe DIV 4 - yoe DIV 100 + doy;   (* 0 .. 146096 *)

    RETURN era * 146097 + doe - 719468
END DaysFromCivil;


(* PackDOS - a Unix timestamp packed into the 32-bit DOS date/time the rest of
   the project passes around: bits 0..4 seconds DIV 2, bits 5..10 minutes,
   bits 11..15 hours, bits 16..20 day, bits 21..24 month, bits 25..31
   year - 1980.  The fields do not overlap, so * and + assemble the word
   exactly as SHL and OR would - this dialect defines neither of those for
   INTEGER.  The conversion is done in UTC, because the libc calls that produce
   the timestamp answer in UTC and this preserves the existing portable file API contract.  An instant older than the DOS epoch has no representation at
   all and is clamped to 1980-01-01 00:00:00.
   Parameters: secs - seconds since 1970-01-01.
   Result: the packed date/time. *)
PROCEDURE PackDOS (secs: INTEGER): INTEGER;
VAR
    days, tod, y, mo, d, h, mi, s: INTEGER;

BEGIN
    secs := MAX(DOS_EPOCH, MIN(secs, 4354819198)); (* 2107-12-31 23:59:58 *)
    days := secs DIV 86400;
    tod  := secs MOD 86400;
    h    := tod DIV 3600;
    mi   := (tod MOD 3600) DIV 60;
    s    := tod MOD 60;
    CivilFromDays(days, y, mo, d);

    (* y - 1980 takes bits 9..15, mo bits 5..8 and d bits 0..4 of the date
       half; h takes bits 11..15, mi bits 5..10 and s DIV 2 bits 0..4 of the
       time-of-day half. *)
    RETURN ((y - 1980) * 512 + mo * 32 + d) * 65536 + h * 2048 + mi * 32 + s DIV 2
END PackDOS;


(* UnpackDOS - the inverse of PackDOS: the Unix timestamp a packed DOS
   date/time stands for, read as UTC again.  SetTime is the only caller and
   validates every field before calling this procedure.
   Parameters: time - the packed date/time, not negative.
   Result: seconds since 1970-01-01. *)
PROCEDURE UnpackDOS (time: INTEGER): INTEGER;
VAR
    date, tod, days, todSecs: INTEGER;

BEGIN
    date := time DIV 65536;
    tod  := time MOD 65536;
    days := DaysFromCivil(date DIV 512 + 1980, (date DIV 32) MOD 16, date MOD 32);
    todSecs := (tod DIV 2048) * 3600 + ((tod DIV 32) MOD 64) * 60 + (tod MOD 32) * 2;

    RETURN days * 86400 + todSecs
END UnpackDOS;


PROCEDURE Exists* (FName: ARRAY OF CHAR): BOOLEAN;
VAR
    mode: INTEGER;
BEGIN
    RETURN GetAttr(FName, mode) & (ORD(BITS(mode) * BITS(S_IFMT)) # S_IFDIR)
END Exists;


PROCEDURE ExistsDir* (DirName: ARRAY OF CHAR): BOOLEAN;
VAR
    mode: INTEGER;
BEGIN
    RETURN GetAttr(DirName, mode) & (ORD(BITS(mode) * BITS(S_IFMT)) = S_IFDIR)
END ExistsDir;


(* GetTime - the last modification time of a file, in the packed DOS form
   PackDOS describes.  A file that is not there is not an error, only a FALSE
   result, so this doubles as a test for existence.
   Parameters: FName - the file to look up; time - its modification time, in
   the packed form, and left alone when the result is FALSE.
   Result: TRUE when the file exists and time was set. *)
PROCEDURE GetTime* (FName: ARRAY OF CHAR; VAR time: INTEGER): BOOLEAN;
VAR
    st: ARRAY STAT_SIZE OF BYTE;
    res, secs: INTEGER;

BEGIN
    res := API.Stat(SYSTEM.ADR(FName[0]), SYSTEM.ADR(st[0]));
    IF res >= 0 THEN
        SYSTEM.GET(SYSTEM.ADR(st[0]) + ST_MTIME_OFFS, secs);
        time := PackDOS(secs)
    END;

    RETURN res >= 0
END GetTime;


(* SetTime - stamp the modification time of a file with a packed DOS time, as
   GetTime returns one (libc utimes).  The DOS form carries no
   separate access time, so utimes is handed the same instant for both of its
   timeval entries.
   Parameters: FName - the file to stamp; time - the packed time to stamp it
   with.
   Result: TRUE when the file exists and the stamp was applied. *)
PROCEDURE SetTime* (FName: ARRAY OF CHAR; time: INTEGER): BOOLEAN;
VAR tv: ARRAY 2 OF TimeVal;
    secs, res, date, tod, year, month, day, y, m, d: INTEGER;
    valid: BOOLEAN;
BEGIN
    valid := (time >= 0) & (time <= 0FFFFFFFFH); res := -1;
    IF valid THEN
        date := time DIV 65536; tod := time MOD 65536;
        year := date DIV 512 + 1980; month := date DIV 32 MOD 16; day := date MOD 32;
        valid := (month >= 1) & (month <= 12) & (day >= 1) &
                 (tod DIV 2048 < 24) & (tod DIV 32 MOD 64 < 60) & (tod MOD 32 < 30);
        IF valid THEN
            CivilFromDays(DaysFromCivil(year, month, day), y, m, d);
            valid := (y = year) & (m = month) & (d = day)
        END;
        IF valid THEN
            secs := UnpackDOS(time);
            tv[0].tvSec := secs; tv[0].tvUsec := 0;
            tv[1].tvSec := secs; tv[1].tvUsec := 0;
            res := API.Utimes(SYSTEM.ADR(FName[0]), SYSTEM.ADR(tv[0]))
        END
    END
    RETURN res = 0
END SetTime;


PROCEDURE Delete* (FName: ARRAY OF CHAR): BOOLEAN;
    RETURN API.Unlink(SYSTEM.ADR(FName[0])) >= 0
END Delete;


(* Rename - rename or move a file (libc rename).  Either name may
   be a full path, and NewName is replaced if something is already there.
   Parameters: OldName - the file to rename; NewName - the name it should
   carry afterwards.
   Result: TRUE when the rename succeeded. *)
PROCEDURE Rename* (OldName, NewName: ARRAY OF CHAR): BOOLEAN;
    RETURN API.Rename(SYSTEM.ADR(OldName[0]), SYSTEM.ADR(NewName[0])) >= 0
END Rename;


PROCEDURE Close* (F: INTEGER);
VAR
    res: INTEGER;
BEGIN
    res := API.Close(F)
END Close;


(* Valid - TRUE when F is an open handle: one that Open, Create or Load
   returned successfully.  The libc wrapper returns -1 when open fails.
   Parameters: F - the handle.
   Result: TRUE when F may be read, written, seeked or closed. *)
PROCEDURE Valid* (F: INTEGER): BOOLEAN;
BEGIN
    RETURN F >= 0
END Valid;


PROCEDURE Open* (FName: ARRAY OF CHAR; Mode: INTEGER): INTEGER;
    RETURN API.Open(SYSTEM.ADR(FName[0]), OpenFlags(Mode), 0)
END Open;


PROCEDURE Create* (FName: ARRAY OF CHAR): INTEGER;
    RETURN API.Open(SYSTEM.ADR(FName[0]), O_WRONLY + O_CREAT + O_TRUNC, 01B6H)
END Create;


PROCEDURE Seek* (F, Offset, Origin: INTEGER): INTEGER;
    RETURN API.Seek(F, Offset, Origin)
END Seek;


PROCEDURE Write* (F, Buffer, Count: INTEGER): INTEGER;
    RETURN API.Write(F, Buffer, Count)
END Write;


PROCEDURE Read* (F, Buffer, Count: INTEGER): INTEGER;
    RETURN API.Read(F, Buffer, Count)
END Read;


(* Truncate - set the length of the file behind an open handle (libc
   ftruncate).  A Size below the current length discards
   everything past it; a Size above the current length extends the file, and
   the gap reads back as zero bytes.  The read/write cursor is not moved.
   Parameters: F - the open handle; Size - the new length in bytes.
   Result: TRUE when the length was set.  The libc wrapper returns -1
   when it fails - a handle that is not open for writing, or one that names no
   regular file, among others - so only a non-negative answer is success. *)
PROCEDURE Truncate* (F, Size: INTEGER): BOOLEAN;
VAR
    res: INTEGER;

BEGIN
    res := API.Truncate(F, Size)

    RETURN res >= 0
END Truncate;


(* Load returns an API allocation; callers release it with API._DISPOSE,
   not language DISPOSE (there is no RTL type header). Empty files return
   a nonzero allocation with Size=0. All failure paths leave Size=0. *)
PROCEDURE Load* (FName: ARRAY OF CHAR; VAR Size: INTEGER): INTEGER;
VAR res, n, f, wanted, done: INTEGER; ok: BOOLEAN;
BEGIN
    res := 0; Size := 0; f := Open(FName, OPEN_R);
    IF f >= 0 THEN
        wanted := Seek(f, 0, SEEK_END);
        ok := (wanted >= 0) & (Seek(f, 0, SEEK_BEG) = 0);
        IF ok THEN
            res := API._NEW(MAX(wanted, 1)); ok := res # 0; done := 0;
            WHILE ok & (done < wanted) DO
                n := Read(f, res + done, wanted - done);
                IF n > 0 THEN INC(done, n) ELSE ok := FALSE END
            END;
            IF ok THEN Size := wanted
            ELSIF res # 0 THEN res := API._DISPOSE(res) END
        END;
        Close(f)
    END
    RETURN res
END Load;


PROCEDURE RemoveDir* (DirName: ARRAY OF CHAR): BOOLEAN;
    RETURN API.Rmdir(SYSTEM.ADR(DirName[0])) >= 0
END RemoveDir;


PROCEDURE CreateDir* (DirName: ARRAY OF CHAR): BOOLEAN;
    RETURN API.Mkdir(SYSTEM.ADR(DirName[0]), 01FFH) >= 0 (* 0777 *)
END CreateDir;


END ArchFile.
