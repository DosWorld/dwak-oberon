(*
    BSD 2-Clause License

    Copyright (c) 2020-2021, Anton Krotov
    All rights reserved.
*)

MODULE ArchFile;

IMPORT SYSTEM, Libdl, API;


CONST

    OPEN_R* = "rb";  OPEN_W* = "wb";  OPEN_RW* = "r+b";
    SEEK_BEG* = 0;   SEEK_CUR* = 1;   SEEK_END* = 2;

    (* the file type part of st_mode: st_mode AND S_IFMT is S_IFDIR when
       the entry is a directory *)
    S_IFMT  = 0F000H;
    S_IFDIR = 04000H;


TYPE

    (* struct stat as the x86-64 Linux ABI defines it - the layout glibc
       fills in for the plain stat symbol on this target, whose st_size
       and st_mtime are the 64-bit ones.  Offsets below are in bytes from
       the start of the record, and each line names the C field the slot
       covers:

             0   st_dev                8 bytes
             8   st_ino                8
            16   st_nlink              8
            24   st_mode               4  \
            28   st_uid                4  / one 8-byte slot
            32   st_gid                4  \
            36   __pad0                4  / one 8-byte slot
            40   st_rdev               8
            48   st_size               8
            56   st_blksize            8
            64   st_blocks             8
            72   st_atim               16  (tv_sec, then tv_nsec)
            88   st_mtim               16
           104   st_ctim               16
           120   __glibc_reserved[3]   24

           144   sizeof(struct stat)

       Every field is an 8-byte INTEGER and this compiler gives the fields
       consecutive 8-byte offsets, the alignment the C struct has, so the
       record lines up with the buffer stat writes into and is exactly as
       long as it - stat can never write past the end of it.  st_mode is
       the one field narrower than its slot, in the low half on this
       little-endian machine, and is read back with SYSTEM.GET32.

       The offsets are the ones the x86-64 psABI and the glibc headers
       give.  They were verified by compiling this record, with offsets
       and size checked on the same compiler for the win64 target, but
       not by running a Linux build.  Only this ABI is described: a 32-bit
       Linux build (target linux32exe) has the different i386 layout, and
       what is written here would not read it correctly. *)
    Stat = RECORD
        dev       : INTEGER;   (*   0 *)
        ino       : INTEGER;   (*   8 *)
        nlink     : INTEGER;   (*  16 *)
        mode      : INTEGER;   (*  24: st_mode in the low 4 bytes       *)
        gid       : INTEGER;   (*  32: st_gid in the low 4 bytes        *)
        rdev      : INTEGER;   (*  40 *)
        size      : INTEGER;   (*  48 *)
        blksize   : INTEGER;   (*  56 *)
        blocks    : INTEGER;   (*  64 *)
        atim_sec  : INTEGER;   (*  72 *)
        atim_nsec : INTEGER;   (*  80 *)
        mtim_sec  : INTEGER;   (*  88 *)
        mtim_nsec : INTEGER;   (*  96 *)
        ctim_sec  : INTEGER;   (* 104 *)
        ctim_nsec : INTEGER;   (* 112 *)
        reserved0 : INTEGER;   (* 120: __glibc_reserved, padding only   *)
        reserved1 : INTEGER;   (* 128 *)
        reserved2 : INTEGER    (* 136 *)
    END;


VAR

    fwrite,
    fread     : PROCEDURE [linux] (buffer, bytes, blocks, file: INTEGER): INTEGER;
    fseek     : PROCEDURE [linux] (file, offset, origin: INTEGER): INTEGER;
    ftell     : PROCEDURE [linux] (file: INTEGER): INTEGER;
    fopen     : PROCEDURE [linux] (fname, fmode: INTEGER): INTEGER;
    fclose    : PROCEDURE [linux] (file: INTEGER): INTEGER;
    remove    : PROCEDURE [linux] (fname: INTEGER): INTEGER;
    rename    : PROCEDURE [linux] (oldname, newname: INTEGER): INTEGER;
    stat      : PROCEDURE [linux] (fname, buf: INTEGER): INTEGER;
    mkdir     : PROCEDURE [linux] (dirname, mode: INTEGER): INTEGER;
    rmdir     : PROCEDURE [linux] (dirname: INTEGER): INTEGER;
    utime     : PROCEDURE [linux] (fname, times: INTEGER): INTEGER;
    ftruncate : PROCEDURE [linux] (fd, length: INTEGER): INTEGER;


PROCEDURE GetSym (lib: INTEGER; name: ARRAY OF CHAR; VarAdr: INTEGER);
VAR
    sym: INTEGER;

BEGIN
    sym := Libdl.sym(lib, name);
    ASSERT(sym # 0);
    SYSTEM.PUT(VarAdr, sym)
END GetSym;


PROCEDURE init;
VAR
    libc: INTEGER;

BEGIN
    libc := API.libc;
    GetSym(libc, "fread",  SYSTEM.ADR(fread));
    GetSym(libc, "fwrite", SYSTEM.ADR(fwrite));
    GetSym(libc, "fseek",  SYSTEM.ADR(fseek));
    GetSym(libc, "ftell",  SYSTEM.ADR(ftell));
    GetSym(libc, "fopen",  SYSTEM.ADR(fopen));
    GetSym(libc, "fclose", SYSTEM.ADR(fclose));
    GetSym(libc, "remove", SYSTEM.ADR(remove));
    GetSym(libc, "rename", SYSTEM.ADR(rename));
    GetSym(libc, "stat",   SYSTEM.ADR(stat));
    GetSym(libc, "mkdir",  SYSTEM.ADR(mkdir));
    GetSym(libc, "rmdir",  SYSTEM.ADR(rmdir));
    GetSym(libc, "utime",  SYSTEM.ADR(utime));
    GetSym(libc, "ftruncate", SYSTEM.ADR(ftruncate))
END init;


(* StatOf - the two fields of a file's struct stat the file and time
   procedures here are built on, from a call to stat(2).  See Stat for
   the layout of the buffer and for the ABI it assumes.
   Parameters: FName - path of the file or directory to look up.
               mode  - receives st_mode; its S_IFMT part is the type.
               mtime - receives st_mtim.tv_sec, in seconds since 1970.
   Result: TRUE when the entry exists, FALSE when it does not; mode and
   mtime are then undefined. *)
PROCEDURE StatOf (FName: ARRAY OF CHAR; VAR mode, mtime: INTEGER): BOOLEAN;
VAR
    st: Stat;
    res: BOOLEAN;

BEGIN
    res := stat(SYSTEM.ADR(FName[0]), SYSTEM.ADR(st)) = 0;
    IF res THEN
        SYSTEM.GET32(SYSTEM.ADR(st.mode), mode);
        mtime := st.mtim_sec
    END;

    RETURN res
END StatOf;


PROCEDURE Delete* (FName: ARRAY OF CHAR): BOOLEAN;
    RETURN remove(SYSTEM.ADR(FName[0])) = 0
END Delete;


(* Close* - close the open handle F.  A handle that is already closed, or
   was never open, is undefined behaviour in libc and is not checked.
   Parameters: F - the handle. *)
PROCEDURE Close* (F: INTEGER);
BEGIN
    F := fclose(F)
END Close;


(* Valid - TRUE when F is an open handle: one that Open, Create or Load
   returned successfully.  fopen answers NULL when it fails, so 0 is the
   one value no open handle can have.
   Parameters: F - the handle.
   Result: TRUE when F may be read, written, seeked or closed. *)
PROCEDURE Valid* (F: INTEGER): BOOLEAN;
BEGIN
    RETURN F # 0
END Valid;


PROCEDURE Open* (FName, Mode: ARRAY OF CHAR): INTEGER;
    RETURN fopen(SYSTEM.ADR(FName[0]), SYSTEM.ADR(Mode[0]))
END Open;


PROCEDURE Create* (FName: ARRAY OF CHAR): INTEGER;
    RETURN Open(FName, OPEN_W)
END Create;


PROCEDURE Seek* (F, Offset, Origin: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF fseek(F, Offset, Origin) = 0 THEN
        res := ftell(F)
    ELSE
        res := -1
    END

    RETURN res
END Seek;


PROCEDURE Write* (F, Buffer, Count: INTEGER): INTEGER;
    RETURN fwrite(Buffer, 1, Count, F)
END Write;


PROCEDURE Read* (F, Buffer, Count: INTEGER): INTEGER;
    RETURN fread(Buffer, 1, Count, F)
END Read;


PROCEDURE Load* (FName: ARRAY OF CHAR; VAR Size: INTEGER): INTEGER;
VAR
    res, n, F: INTEGER;

BEGIN
    res := 0;
    F := Open(FName, OPEN_R);

    IF F > 0 THEN
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


(* Truncate* - make the file behind the open handle F exactly Size bytes
   long.  A smaller size cuts the tail off a larger file, a larger one
   extends it with zeros; where the handle reads and writes next is not
   moved by this.
   Parameters: F    - the open handle.
               Size - the length to give the file, larger or smaller than
                      the one it has now, and not negative.
   Result: TRUE on success, FALSE when F is not an open handle, is not a
   file this process may write, or Size is negative. *)
PROCEDURE Truncate* (F, Size: INTEGER): BOOLEAN;
VAR
    res: BOOLEAN;

BEGIN
    res := ftruncate(F, Size) = 0;

    RETURN res
END Truncate;


(* Rename* - give the file or directory OldName the new name NewName.
   The name NewName must not exist, and both names have to be in the
   same filesystem: the two are one operation, so either the rename
   happens or nothing does.
   Parameters: OldName - the name to rename.
               NewName - the name to give it.
   Result: TRUE on success, FALSE when OldName does not exist, NewName
   is taken, or a directory is being moved to another filesystem. *)
PROCEDURE Rename* (OldName, NewName: ARRAY OF CHAR): BOOLEAN;
    RETURN rename(SYSTEM.ADR(OldName[0]), SYSTEM.ADR(NewName[0])) = 0
END Rename;


(* Exists* - whether FName names an existing file.  A directory is not a
   file here: Exists answers FALSE for one and ExistsDir answers TRUE,
   the same line the Windows module of this interface draws too.
   Parameters: FName - the name to look up.
   Result: TRUE when FName is an existing file, FALSE when it is missing
   or is a directory. *)
PROCEDURE Exists* (FName: ARRAY OF CHAR): BOOLEAN;
VAR
    mode, mtime: INTEGER;

BEGIN
    RETURN StatOf(FName, mode, mtime) & (ORD(BITS(mode) * BITS(S_IFMT)) # S_IFDIR)
END Exists;


(* ExistsDir* - whether DirName names an existing directory.
   Parameters: DirName - the name to look up.
   Result: TRUE when DirName is an existing directory, FALSE when it is
   missing or is some other kind of file. *)
PROCEDURE ExistsDir* (DirName: ARRAY OF CHAR): BOOLEAN;
VAR
    mode, mtime: INTEGER;

BEGIN
    RETURN StatOf(DirName, mode, mtime) & (ORD(BITS(mode) * BITS(S_IFMT)) = S_IFDIR)
END ExistsDir;


(* RemoveDir* - delete the directory DirName.  Only an empty directory
   can be removed; that is what rmdir, and RemoveDirectory on Windows,
   will do.
   Parameters: DirName - the directory to delete.
   Result: TRUE on success, FALSE when the directory does not exist or
   still has entries in it. *)
PROCEDURE RemoveDir* (DirName: ARRAY OF CHAR): BOOLEAN;
    RETURN rmdir(SYSTEM.ADR(DirName[0])) = 0
END RemoveDir;


(* CreateDir* - make the directory DirName.  Its parent directory must
   already exist, and the mode asked for is 0777, narrowed by the
   process umask as usual.
   Parameters: DirName - the directory to create.
   Result: TRUE on success, FALSE when it cannot be made, which includes
   the case where the name is already taken. *)
PROCEDURE CreateDir* (DirName: ARRAY OF CHAR): BOOLEAN;
    RETURN mkdir(SYSTEM.ADR(DirName[0]), 01FFH) = 0  (* 0777 *)
END CreateDir;


(* GetTime* - the modification time of FName, as the packed DOS date and
   time the rest of the project uses: bits 0..4 hold seconds DIV 2, bits
   5..10 minutes, bits 11..15 hours, bits 16..20 the day of the month,
   bits 21..24 the month and bits 25..31 the year less 1980.  The two
   halves are the date and the time of day, so a packed time is
   (date SHL 16) OR timeOfDay.

   The seconds stat reports are broken down as UTC - libc localtime is
   not called, so the value is not the local time that the DOS and
   Windows implementations of this convention would report.

   The format can hold the years 1980 to 2107 only, and a time outside
   that range is clamped to its nearest end rather than allowed to run
   over into the neighbouring fields: an earlier file answers
   1980-01-01 00:00:00, a later one answers 2107-12-31 23:59:58.
   Parameters: FName - path of an existing file or directory.
               time  - receives the packed date and time; left unchanged
                       when the result is FALSE.
   Result: TRUE when FName exists, FALSE when it does not. *)
PROCEDURE GetTime* (FName: ARRAY OF CHAR; VAR time: INTEGER): BOOLEAN;
VAR
    mode, secs: INTEGER;
    days, rest, z, era, doe, yoe, doy, mp: INTEGER;
    y, m, d, h, mi, s, date, tod: INTEGER;
    res: BOOLEAN;

BEGIN
    res := StatOf(FName, mode, secs);
    IF res THEN
        (* seconds since 1970 -> day number and time of day.  DIV rounds
           down and MOD never answers a negative value here, so both are
           right for the days before 1970 as well *)
        days := secs DIV 86400;
        rest := secs MOD 86400;
        h    := rest DIV 3600;
        mi   := (rest MOD 3600) DIV 60;
        s    := rest MOD 60;

        (* the day number -> year, month, day: the usual days-to-date
           conversion, day 0 being 1970-01-01, proleptic Gregorian *)
        z   := days + 719468;
        era := z DIV 146097;
        doe := z - era * 146097;
        yoe := (doe - doe DIV 1460 + doe DIV 36524 - doe DIV 146096) DIV 365;
        y   := yoe + era * 400;
        doy := doe - (365 * yoe + yoe DIV 4 - yoe DIV 100);
        mp  := (5 * doy + 2) DIV 153;
        d   := doy - (153 * mp + 2) DIV 5 + 1;
        m   := mp + 3;
        IF m > 12 THEN
            m := m - 12;
            INC(y)
        END;

        IF y < 1980 THEN
            y := 1980; m := 1; d := 1; h := 0; mi := 0; s := 0
        ELSIF y > 2107 THEN
            y := 2107; m := 12; d := 31; h := 23; mi := 59; s := 58
        END;

        (* the fields do not overlap, so * and + assemble the word the
           way SHL and OR would: the year takes bits 9..15 of the date
           half, the month bits 5..8 and the day bits 0..4, and the hour
           takes bits 11..15 of the time-of-day half, the minute bits
           5..10 and the seconds DIV 2 bits 0..4 *)
        date := (y - 1980) * 512 + m * 32 + d;
        tod  := h * 2048 + mi * 32 + s DIV 2;
        time := date * 65536 + tod
    END;

    RETURN res
END GetTime;


(* SetTime* - set the modification time of FName to time, the packed DOS
   date and time that GetTime reads and writes (see there for the two
   halves and for the years the format can hold).  The access time is
   set to the same value as the modification time, because utime takes
   the two together and only the modification time is of interest here.
   The packed fields are taken to be UTC, the opposite of the reading
   conversion in GetTime, so that a time written by SetTime is read back
   by GetTime unchanged.
   Parameters: FName - path of an existing file or directory.
               time  - the packed date and time to set.
   Result: TRUE on success, FALSE when FName does not exist or the
   caller is not allowed to change its times. *)
PROCEDURE SetTime* (FName: ARRAY OF CHAR; time: INTEGER): BOOLEAN;
VAR
    times: ARRAY 2 OF INTEGER;
    date, tod: INTEGER;
    y, m, d, h, mi, s, yy, era, yoe, mp, doy, doe, days, secs: INTEGER;
    res: BOOLEAN;

BEGIN
    (* the two halves of the word.  DIV rounds down and MOD never answers
       a negative value, so a word handed over sign-extended - what a
       caller reads out of a structure with a 32-bit packed time in it -
       still splits into the halves it holds *)
    date := (time DIV 65536) MOD 65536;
    tod  := time MOD 65536;
    s    := (tod MOD 32) * 2;
    mi   := (tod DIV 32) MOD 64;
    h    := (tod DIV 2048) MOD 32;
    d    := date MOD 32;
    m    := (date DIV 32) MOD 16;
    y    := date DIV 512 + 1980;

    (* the fields are wider than the calendar is, and a word that GetTime
       did not build can hold a day of nought or a month of fifteen, which
       is not a date at all.  Clamp each field onto the calendar, which
       also makes a word of zeroes read as the DOS epoch, 1980-01-01 *)
    IF s > 59 THEN s := 59 END;
    IF mi > 59 THEN mi := 59 END;
    IF h > 23 THEN h := 23 END;
    IF d > 31 THEN
        d := 31
    ELSIF d < 1 THEN
        d := 1
    END;
    IF m > 12 THEN
        m := 12
    ELSIF m < 1 THEN
        m := 1
    END;

    (* year, month, day -> the day number counted from 1970-01-01, the
       inverse of the conversion in GetTime, and then the seconds *)
    yy := y;
    IF m <= 2 THEN
        DEC(yy)
    END;
    era := yy DIV 400;
    yoe := yy - era * 400;
    IF m <= 2 THEN
        mp := m + 9
    ELSE
        mp := m - 3
    END;
    doy := (153 * mp + 2) DIV 5 + d - 1;
    doe := yoe * 365 + yoe DIV 4 - yoe DIV 100 + doy;
    days := era * 146097 + doe - 719468;
    secs := days * 86400 + h * 3600 + mi * 60 + s;

    times[0] := secs;
    times[1] := secs;
    res := utime(SYSTEM.ADR(FName[0]), SYSTEM.ADR(times)) = 0;

    RETURN res
END SetTime;


BEGIN
    init
END ArchFile.
