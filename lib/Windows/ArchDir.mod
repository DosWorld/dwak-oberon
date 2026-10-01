(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2019-2021, Anton Krotov
    All rights reserved.

    Windows port of the Dirs module.  The walk is FindFirstFileA and
    FindNextFileA, which take a mask and fill a WIN32_FIND_DATA - so the
    directory is turned into one here, `dir\*`, and the mask a caller wrote is
    never handed to Win32 at all: the module above filters what comes back, so
    that all four platforms answer a mask the same way.  `*` is the everything
    mask here in the same sense it is for DOS, and it is the only one this
    module ever asks with.

    The 8-bit surface is the primary one and the wide surface sits beside it,
    which is how the owner asked for it and is also the cheaper of the two:
    neither surface converts anything.  FindFirstFileA takes the byte path and
    hands back byte names, and FindFirstFileW takes WCHARs and hands back
    WCHARs, so a caller that has one kind of text gets that kind back
    unchanged.  Neither is derived from the other, which is what a widening or
    a narrowing between them would amount to.

    Two fields arrive in a Win32 shape rather than the one an Entry carries.
    The size comes in two halves - the high one is dropped on a 32-bit build,
    where the INTEGER holding the answer has no room for it.  The stamp is a
    UTC FILETIME, while the packed word every other module in this tree speaks
    is local time, so it goes through FileTimeToLocalFileTime first, exactly as
    ArchFile.GetTime does.

    Drives and CurrentDir are the two path questions a browser asks, and
    neither belongs to the byte or the wide surface: each answers text of the
    kind the caller's own buffers are made of, and a caller's buffers are
    bytes.  GetLogicalDrives enumerates the drives and there is no call that
    says which one is current, so the letter is read off the current directory,
    which on this target always begins with its drive.
*)

MODULE ArchDir;

IMPORT SYSTEM, WINAPI, Strings;


CONST

    NameMax = 256;                      (* the room an Entry gives a name *)
    PathMax = 260;                      (* the room a Finder gives a path *)

    ATTR_MASK = 3FH;                    (* the six bits a DOS attribute byte has *)

    (* By number and not as the mask it makes, because `x IN BITS(s)` tests the
       bit whose *number* is x: ATTR_DIR is 4, and the FILE_ATTRIBUTE_DIRECTORY
       value it stands for is 16.  Written the other way round - 16 IN BITS(a) -
       the test asks about bit 16 of an eight-bit set and is FALSE for every
       entry, so no walk would ever have reported a directory. *)
    ATTR_DIR  = 4;                      (* bit 4: FILE_ATTRIBUTE_DIRECTORY, 16 *)
    BAD       = -1;                     (* FindFirstFileA's failure, -1 *)

    DOS_EPOCH_YEAR = 1980;              (* the first year a DOS date holds *)
    DOS_LAST_YEAR  = 2107;              (* the last: 1980 + 127 *)


TYPE

    (* One entry of a directory.  name is the base name with no directory part.
       attr is masked down to the six bits a DOS attribute byte has, so that a
       bit test means the same thing here as it does on DOS - and measured, the
       two agree bit for bit on the same files: an ordinary file answers 032H,
       the archive bit, and a directory 016H, the directory bit and nothing
       else, which is what the DOS walk reports for them too.  What that
       measurement did not cover was isDir, which is derived from the byte
       rather than being it, and which ATTR_DIR below got wrong until a file
       dialog walked a directory and showed no subdirectories at all.  size is what
       Win32 reported, which for a directory is a number it invents rather than
       a meaningful one, so a caller that cares zeroes it for an entry whose
       isDir is set. *)
    Entry* = RECORD
        name*:  ARRAY NameMax OF CHAR;
        isDir*: BOOLEAN;
        size*:  INTEGER;
        time*:  INTEGER;                (* packed DOS date and time *)
        attr*:  INTEGER                 (* the DOS attribute byte *)
    END;

    (* A walk in progress.  ok is whether the entry in e is one to show: FALSE
       means the walk is over.  fd is the caller's buffer, and Win32 is handed
       its address for every call of the walk, so the record a FindNextFile
       fills is the same memory a FindFirstFile filled. *)
    Finder* = RECORD
        fd:   WINAPI.TWin32FindData;
        path: ARRAY PathMax OF CHAR;
        h:    INTEGER;
        ok*:  BOOLEAN;
        e*:   Entry
    END;

    (* The wide surface, the same two records in WCHAR.  name holds the name as
       UTF-16, which is what a console and every other Win32 W entry point
       want, so nothing is converted on the way in or on the way out. *)
    EntryW* = RECORD
        name*:  ARRAY NameMax OF WCHAR;
        isDir*: BOOLEAN;
        size*:  INTEGER;
        time*:  INTEGER;
        attr*:  INTEGER
    END;

    FinderW* = RECORD
        fd:   WINAPI.TWin32FindDataW;
        path: ARRAY PathMax OF WCHAR;
        h:    INTEGER;
        ok*:  BOOLEAN;
        e*:   EntryW
    END;


(* PackDosTime - packs a civil date and time into the DOS date/time word.  The
   word can only count from 1980 to 2107, so a stamp from outside that range is
   clamped onto the nearest end of it.  ArchFile keeps this formula privately
   for the same reason it is here: the packed word is what every module above
   the platform layer speaks, and each platform layer owns its own conversion
   into it. *)
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


(* Stamp - the FILETIME Win32 reported, as the packed local date/time word.  A
   failure to convert leaves 0 behind rather than a guess. *)
PROCEDURE Stamp (VAR ft: WINAPI.TFileTime): INTEGER;
VAR
    lft: WINAPI.TFileTime;
    st:  WINAPI.TSystemTime;
    res: INTEGER;

BEGIN
    res := 0;
    IF WINAPI.FileTimeToLocalFileTime(SYSTEM.ADR(ft.dwLowDateTime),
               SYSTEM.ADR(lft.dwLowDateTime)) # 0 THEN
        IF WINAPI.FileTimeToSystemTime(SYSTEM.ADR(lft.dwLowDateTime),
                   SYSTEM.ADR(st.Year)) # 0 THEN
            res := PackDosTime(ORD(st.Year), ORD(st.Month), ORD(st.Day),
                               ORD(st.Hour), ORD(st.Min), ORD(st.Sec))
        END
    END

    RETURN res
END Stamp;


(* The high half of a Win32 file size, folded into the answer on a build whose
   INTEGER can hold it and dropped on one whose cannot: a 32-bit build has no
   room for it, and 100000000H is refused there outright as a number too large
   rather than wrapping to nothing.

   This is a procedure of its own because a $IF region in statement position
   has to be the last thing in the sequence it stands in - the parser wants the
   enclosing END straight after the $END and refuses any statement that
   follows - so the conditional cannot sit in the middle of Load. *)
PROCEDURE High (high: INTEGER): INTEGER;
BEGIN
$IF (BITS_64)
    RETURN high * 100000000H
$ELSE
    RETURN 0
$END
END High;


PROCEDURE Clear (VAR e: Entry);
BEGIN
    e.name[0] := 0X;
    e.isDir := FALSE; e.size := 0; e.time := 0; e.attr := 0
END Clear;


PROCEDURE ClearW (VAR e: EntryW);
BEGIN
    e.name[0] := WCHR(0);
    e.isDir := FALSE; e.size := 0; e.time := 0; e.attr := 0
END ClearW;


(* Load - read the entry Win32 is holding in fd out into e. *)
PROCEDURE Load (VAR f: Finder);
VAR
    i, low, high, attr: INTEGER;

BEGIN
    i := 0;
    WHILE (i < NameMax - 1) & (f.fd.cFileName[i] # 0X) DO
        f.e.name[i] := f.fd.cFileName[i];
        INC(i)
    END;
    f.e.name[i] := 0X;

    (* The attribute dword is read with GET32 into a zeroed INTEGER rather than
       assigned: it is a CARD32, and on a 64-bit build an INTEGER is wider than
       it is, so the half GET32 does not write has to be known to be zero. *)
    attr := 0;
    SYSTEM.GET32(SYSTEM.ADR(f.fd.dwFileAttributes), attr);
    f.e.attr := attr MOD (ATTR_MASK + 1);
    f.e.isDir := ATTR_DIR IN BITS(f.e.attr);

    low := 0; high := 0;
    SYSTEM.GET32(SYSTEM.ADR(f.fd.nFileSizeLow), low);
    SYSTEM.GET32(SYSTEM.ADR(f.fd.nFileSizeHigh), high);
    f.e.size := low + High(high);   (* a 32-bit build drops the high half *)
    f.e.time := Stamp(f.fd.ftLastWriteTime)
END Load;


PROCEDURE LoadW (VAR f: FinderW);
VAR
    i, low, high, attr: INTEGER;

BEGIN
    i := 0;
    WHILE (i < NameMax - 1) & (f.fd.cFileName[i] # WCHR(0)) DO
        f.e.name[i] := f.fd.cFileName[i];
        INC(i)
    END;
    f.e.name[i] := WCHR(0);

    attr := 0;
    SYSTEM.GET32(SYSTEM.ADR(f.fd.dwFileAttributes), attr);
    f.e.attr := attr MOD (ATTR_MASK + 1);
    f.e.isDir := ATTR_DIR IN BITS(f.e.attr);

    low := 0; high := 0;
    SYSTEM.GET32(SYSTEM.ADR(f.fd.nFileSizeLow), low);
    SYSTEM.GET32(SYSTEM.ADR(f.fd.nFileSizeHigh), high);
    f.e.size := low + High(high);   (* a 32-bit build drops the high half *)
    f.e.time := Stamp(f.fd.ftLastWriteTime)
END LoadW;


(* The directory with the everything mask on the end of it.  A path that
   already ends in a separator, or is a drive letter, keeps what it has. *)
PROCEDURE BuildPath (dir: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < PathMax - 3) & (i < LEN(dir)) & (dir[i] # 0X) DO
        path[i] := dir[i];
        INC(i)
    END;
    IF (i > 0) & (path[i - 1] # "\") & (path[i - 1] # ":") THEN
        path[i] := "\";
        INC(i)
    END;
    path[i] := "*";
    path[i + 1] := 0X
END BuildPath;


PROCEDURE BuildPathW (dir: ARRAY OF WCHAR; VAR path: ARRAY OF WCHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < PathMax - 3) & (i < LEN(dir)) & (dir[i] # WCHR(0)) DO
        path[i] := dir[i];
        INC(i)
    END;
    IF (i > 0) & (path[i - 1] # "\") & (path[i - 1] # ":") THEN
        path[i] := "\";
        INC(i)
    END;
    path[i] := "*";
    path[i + 1] := WCHR(0)
END BuildPathW;


(* Start a walk of the directory dir, which may or may not end in a separator,
   and show its first entry.  FALSE for a directory that is not there and for
   one with nothing in it, which are the same answer here. *)
PROCEDURE FindFirst* (dir: ARRAY OF CHAR; VAR f: Finder): BOOLEAN;
BEGIN
    BuildPath(dir, f.path);
    f.h := WINAPI.FindFirstFileA(SYSTEM.ADR(f.path[0]), f.fd);
    f.ok := f.h # BAD;
    IF f.ok THEN Load(f) ELSE Clear(f.e) END;

    RETURN f.ok
END FindFirst;


PROCEDURE FindNext* (VAR f: Finder): BOOLEAN;
BEGIN
    IF f.ok THEN
        f.ok := WINAPI.FindNextFileA(f.h, f.fd) # 0;
        IF f.ok THEN Load(f) END
    END;

    RETURN f.ok
END FindNext;


(* End a walk.  A finder that is already over - read to its end, or closed
   twice, or never started - is left alone. *)
PROCEDURE FindClose* (VAR f: Finder);
BEGIN
    IF f.h # BAD THEN WINAPI.FindClose(f.h) END;
    f.h := BAD;
    f.ok := FALSE
END FindClose;


PROCEDURE FindFirstW* (dir: ARRAY OF WCHAR; VAR f: FinderW): BOOLEAN;
BEGIN
    BuildPathW(dir, f.path);
    f.h := WINAPI.FindFirstFileW(SYSTEM.ADR(f.path[0]), f.fd);
    f.ok := f.h # BAD;
    IF f.ok THEN LoadW(f) ELSE ClearW(f.e) END;

    RETURN f.ok
END FindFirstW;


PROCEDURE FindNextW* (VAR f: FinderW): BOOLEAN;
BEGIN
    IF f.ok THEN
        f.ok := WINAPI.FindNextFileW(f.h, f.fd) # 0;
        IF f.ok THEN LoadW(f) END
    END;

    RETURN f.ok
END FindNextW;


PROCEDURE FindCloseW* (VAR f: FinderW);
BEGIN
    IF f.h # BAD THEN WINAPI.FindClose(f.h) END;
    f.h := BAD;
    f.ok := FALSE
END FindCloseW;


(* CurrentDir - the directory the program is in, as an absolute path.

   The wide call, like every other name-taking call in this tree: a directory
   whose name is not ASCII is a directory whose name the narrow call answers in
   the ANSI code page, and the layer above speaks UTF-8 - so Документы came back
   as bytes that are not those letters and the box drew somebody else's.  The
   UTF-16 the call answers is turned back into UTF-8 by Utf16To8, which is the
   same pair of converters every name in ArchFile goes through.

   GetCurrentDirectoryW answers the length it wrote in WCHARs, not counting the
   terminator, or - when the buffer is too small - the size that would have been
   needed.  So the answer is believed only when it fits, and the caller's buffer
   is emptied first and left empty otherwise: a directory longer than PathMax
   leaves it empty rather than leaving a length that looks like one. *)
PROCEDURE CurrentDir* (VAR s: ARRAY OF CHAR);
VAR
    w: ARRAY PathMax OF WCHAR;
    n: INTEGER;

BEGIN
    IF LEN(s) > 0 THEN s[0] := 0X END;
    IF LEN(s) > 1 THEN
        n := WINAPI.GetCurrentDirectoryW(PathMax, SYSTEM.ADR(w[0]));
        IF (n > 0) & (n < PathMax) THEN
            w[n] := WCHR(0);
            n := Strings.Utf16To8(w, s)
        END
    END
END CurrentDir;


(* Drives - every drive letter this machine has, and which of them is current.

   s receives the names separated by ";", the way Dirs.MatchAny takes its
   masks, and the answer is how many were written; cur receives the index of
   the current drive in that list, or -1 when the list does not hold it.  An
   entry that does not fit in s is not written and not counted, so the answer
   is always the number of rows a caller can read.

   GetLogicalDrives is one bit per letter, bit 0 for A:, and it is the only
   call that enumerates them.  There is no call that answers which drive is
   current, so the letter is read off the current directory, which is what
   CurrentDir is for - a directory on Windows always begins with its drive. *)
PROCEDURE Drives* (VAR s: ARRAY OF CHAR; VAR cur: INTEGER): INTEGER;
VAR
    dir:  ARRAY PathMax OF CHAR;
    mask: SET;
    i, n, k, d, room: INTEGER;

BEGIN
    n := 0; k := 0; cur := -1;
    room := LEN(s) - 1;
    mask := WINAPI.GetLogicalDrives();
    CurrentDir(dir);
    IF dir[0] = 0X THEN
        d := -1
    ELSE
        d := ORD(dir[0]) - ORD("A")
    END;
    FOR i := 0 TO 25 DO
        IF i IN mask THEN
            IF n + 3 <= room THEN
                IF k > 0 THEN s[n] := ";"; INC(n) END;
                s[n] := CHR(ORD("A") + i); INC(n);
                s[n] := ":"; INC(n);
                IF i = d THEN cur := k END;
                INC(k)
            END
        END
    END;
    s[n] := 0X;

    RETURN k
END Drives;


END ArchDir.
