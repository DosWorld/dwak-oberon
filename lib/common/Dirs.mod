(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2018-2022, Anton Krotov
    All rights reserved.

    Dirs - directory enumeration, shared by every target.

    This module is the one directory interface a program should use.  It is
    written against the platform ArchDir module (lib/<target>/ArchDir.mod),
    which every platform supplies, and it adds the two things that module
    leaves out: the wildcard, and the two entries every directory begins
    with.

    The wildcard is the reason the module exists.  The platform is asked for
    a directory and nothing else - it is never handed a mask - so the mask is
    compared here, once, and all four platforms filter identically.  That is
    not only tidiness: DOS's two find services do not agree with each other
    about a mask, so a walk there is asked for everything and the mask is
    applied to what comes back, and a Unix readdir has no mask to be given at
    all.

    An entry carries the base name with no directory part, whether it is a
    directory, its size, its date and time in the packed DOS form
    Files.DosTime uses, and its attribute byte.  The attribute byte is a DOS
    one on every platform: DOS and Windows have it natively, and the Unix
    modules synthesise the two bits that mean anything there - the directory
    bit, and the read-only bit - and leave the rest clear.

    A Finder is a record of the caller's, not a heap object: nothing here
    allocates, so it works on every target including the ones with no
    DISPOSE.  Zero a Finder, walk it, and release it with FindClose.  A
    Finder that has never been started, one read to its end, and one closed
    twice all behave: FindNext on any of them answers FALSE rather than
    trapping.

    The rest of the module is the path work a browser needs and the platform
    cannot do for it: Separator, Join, Parent, MatchAny, Drives and
    CurrentDir.  Separator is a compile time constant and not a call, because
    a target's separator is a property of the target; the other five add the
    two things every platform differs on - how a path is put together, and
    which drives there are - on top of the two primitives ArchDir supplies,
    so that a caller writes one piece of code for every target.  On Unix
    there are no drives: Drives answers the one entry "/", and the code in a
    caller that walks the list is the same code it is on DOS.

    Nothing here has a current drive of its own to change, and nothing here
    changes one: CurrentDir reads where the program is, and a caller that
    wants to be somewhere else says so in the path it passes to the file
    calls, which is what makes a dialog on another drive a matter of building
    a longer string rather than of moving the process.
*)

MODULE Dirs;

IMPORT ArchDir, Strings;


CONST

    (* The room a mask may take.  A mask longer than this is truncated, which
       is what every other fixed buffer in this tree does with one. *)
    MaskMax = 260;

    (* The room one drive name takes: "C:" and its terminator.  Unix has no
       drives and answers the one entry "/", so this is room to spare there
       rather than a second rule. *)
    DriveMax = 4;

    (* The bits of the attribute byte an Entry carries, by number rather than
       as masks, so that a test reads `AttrDir IN BITS(e.attr)`. *)
    AttrReadOnly* = 0;  AttrHidden* = 1;  AttrSystem* = 2;
    AttrVolume*   = 3;  AttrDir*    = 4;  AttrArchive* = 5;

    (* What separates one part of a path from the next.  It is not a function
       and not a variable: a target has one separator and it is known when the
       target is.  Join adds it, Parent cuts at it, and a caller with a path of
       its own to build spells it the same way rather than guessing, which is
       the whole reason it is published.

       The arms are the four targets that have a directory walk, which are the
       four that have an ArchDir module.  There is deliberately no $ELSE: a
       target that gets an ArchDir and no arm here should fail to compile
       rather than quietly be given one of these four separators. *)
$IF (WINDOWS)
    Separator* = "\";
$ELSIF (LINUX)
    Separator* = "/";
$ELSIF (MACOS)
    Separator* = "/";
$ELSIF (DOS)
    Separator* = "\";
$END

TYPE

    (* One entry of a directory.  The record belongs to the platform module,
       because that is where it is filled in: on Windows it is a
       WIN32_FIND_DATA narrowed, on dpmi32 a DOS find block.  The alias makes
       it the same record here, so an Entry may be passed to either module. *)
    Entry* = ArchDir.Entry;

    (* A walk in progress.  inner is the platform's own state, mask is the one
       it was started with - kept because the platform is never told it - and
       pending says whether the entry the platform is holding has already been
       shown.  A platform's FindFirst reads an entry as soon as it starts, so
       without that flag the first entry would be handed out twice.

       THE PLATFORM'S WALK IS THE WIDE ONE WHERE THE PLATFORM HAS ONE, and
       that is the whole of what this type decides.  A name a walk answers is
       text and the caller draws it, so which text it is is the host's
       business and not the caller's: FindFirstFileA answers bytes of the
       console's code page, which for a Russian name are somebody else's
       letters - the file box listed the file and then could not open it, and
       a tree drew the name as mojibake.  FindFirstFileW answers UTF-16, Take
       converts it once, and everything above - the mask, the entry, the
       caller - sees one encoding and never has to know.  A target whose walk
       already answers the bytes its console draws converts nothing.

       This used to be two parallel surfaces, Finder/FindFirst and
       FinderW/FindFirstW, and the choice was the caller's; the only caller
       that needed the wide one was the file box, and the two samples that
       needed it next were left with the narrow walk.  The choice belongs
       here. *)
$IF (WINDOWS)
    Finder* = RECORD
        inner:   ArchDir.FinderW;
        mask:    ARRAY MaskMax OF CHAR;
        pending: BOOLEAN
    END;
$ELSE
    Finder* = RECORD
        inner:   ArchDir.Finder;
        mask:    ARRAY MaskMax OF CHAR;
        pending: BOOLEAN
    END;
$END


(* One character against one, ASCII case-insensitively.  Strings.Cap cases in
   place, so this needs a copy of each. *)
PROCEDURE Same (a, b: CHAR): BOOLEAN;
VAR
    x, y: CHAR;

BEGIN
    x := a; y := b;
    Strings.Cap(x); Strings.Cap(y)

    RETURN x = y
END Same;


(* The "." and ".." every directory begins with, which no caller of a walk
   wants and which would otherwise be offered to the mask as ordinary names.
   Only the first two characters are looked at, so an array of any length is
   safe to pass. *)
PROCEDURE Dot (name: ARRAY OF CHAR): BOOLEAN;
VAR
    r: BOOLEAN;

BEGIN
    r := FALSE;
    IF name[0] = "." THEN
        IF name[1] = 0X THEN r := TRUE END;
        IF (name[1] = ".") & (name[2] = 0X) THEN r := TRUE END
    END;

    RETURN r
END Dot;


(* One run of characters against one, `?` standing for one character of the
   name and `*` for any run of them.  The two runs are named by index rather
   than copied out: name is read from nlo up to nhi and mask from mlo up to
   mhi, and each mhi is the position just past the half of the mask being
   asked.  A `*` here stands for any run of the characters that half is made
   of, which is what the caller's split decides.

   The star is resolved by backtracking rather than by recursion: the
   position of the last `*` and the name character it was tried at are kept,
   and a mismatch after a `*` moves the name on one and returns the mask to
   just after that star. *)
PROCEDURE Run (name, mask: ARRAY OF CHAR;
               nlo, nhi, mlo, mhi: INTEGER): BOOLEAN;
VAR
    i, j, star, mark: INTEGER;
    ok: BOOLEAN;

BEGIN
    i := nlo; j := mlo; star := -1; mark := nlo; ok := TRUE;
    WHILE ok & (i < nhi) DO
        IF (j < mhi) & (mask[j] = "*") THEN
            star := j; mark := i; INC(j)
        ELSIF (j < mhi) & ((mask[j] = "?") OR Same(name[i], mask[j])) THEN
            INC(i); INC(j)
        ELSIF star >= 0 THEN
            j := star + 1; INC(mark); i := mark
        ELSE
            ok := FALSE
        END
    END;
    WHILE ok & (j < mhi) & (mask[j] = "*") DO INC(j) END;

    RETURN ok & (j = mhi)
END Run;


(* Where the last dot of s is, or -1 when it has none. *)
PROCEDURE LastDot (s: ARRAY OF CHAR): INTEGER;
VAR
    i, r, n: INTEGER;

BEGIN
    i := 0; r := -1; n := Strings.Length(s);
    WHILE i < n DO
        IF s[i] = "." THEN r := i END;
        INC(i)
    END;

    RETURN r
END LastDot;


(* Match - whether a name is one a mask selects.

   The mask is DOS's: `?` stands for one character, `*` for any run of them,
   and the comparison is ASCII case-insensitive, so `*.mod` and `*.MOD` are
   the same question.  A `*` and the `*.*` every caller writes mean
   everything, extensionless names and directories included.

   That last part is the whole of the rule and it is not what a plain
   wildcard matcher does, so it is worth stating exactly.  A mask that
   contains a dot is asked of the name in two halves, split at the name's
   last dot: the part before it against the mask's part before its dot, and
   the part after it against the mask's part after its.  A name with nothing
   after its dot has an empty extension, and a `*` matches an empty run, so
   `*.*` selects `SUBDIR` as readily as `BETA.MOD` - while `*.MOD` still
   refuses `ALPHA.TXT`, because there the extension half is `MOD` and not a
   star.  A mask with **no** dot is asked of the whole name, dot included,
   which is what lets `?E*` and `TE*` select `TEST1.MOD`: splitting those at
   a dot that the mask does not have would ask the `T` of `TE` to match
   `TEST1` alone and would find nothing.

   Splitting is also what keeps the answer honest about a name that has more
   than one dot in it: the last one is the separator, so `A Long File
   Name.TXT` has the extension `TXT` and not ` Name.TXT`. *)
PROCEDURE Match* (name, mask: ARRAY OF CHAR): BOOLEAN;
VAR
    nend, mend, nb, ne, md: INTEGER;
    r: BOOLEAN;

BEGIN
    nend := Strings.Length(name);
    mend := Strings.Length(mask);
    md := LastDot(mask);
    (* the name's two halves, and for a name with no dot the first is the
       whole name and the second is empty *)
    nb := LastDot(name);
    IF nb < 0 THEN
        nb := nend; ne := nend
    ELSE
        ne := nb + 1
    END;
    IF md < 0 THEN
        r := Run(name, mask, 0, nend, 0, mend)
    ELSE
        r := Run(name, mask, 0, nb, 0, md) &
             Run(name, mask, ne, nend, md + 1, mend)
    END;

    RETURN r
END Match;


(* Whether the entry the platform is holding is one to show. *)
PROCEDURE Wanted (VAR f: Finder; name: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN f.inner.ok & ~Dot(name) & Match(name, f.mask)
END Wanted;


(* The entry the platform is holding, as the caller's own record.

   The two Entries are the same record with one field spelled in the other
   character type, so the name is the only thing to convert: UTF-16 to UTF-8
   on the wide walk, a copy on every other.  The name goes straight into the
   caller's Entry rather than through a buffer of this module's, because the
   caller's Entry is already exactly the size a name is allowed to be.
   Parameters: f - the walk; e - receives the name, and only the name. *)
PROCEDURE Take (VAR f: Finder; VAR e: Entry);
VAR n: INTEGER;
BEGIN
$IF (WINDOWS)
    n := Strings.Utf16To8(f.inner.e.name, e.name)
$ELSE
    Strings.Copy(f.inner.e.name, e.name)
$END
END Take;


(* One step of the platform's own walk. *)
PROCEDURE Advance (VAR f: Finder): BOOLEAN;
VAR ok: BOOLEAN;
BEGIN
$IF (WINDOWS)
    ok := ArchDir.FindNextW(f.inner)
$ELSE
    ok := ArchDir.FindNext(f.inner)
$END
    RETURN ok
END Advance;


(* Release the platform's own walk. *)
PROCEDURE Release (VAR f: Finder);
BEGIN
$IF (WINDOWS)
    ArchDir.FindCloseW(f.inner)
$ELSE
    ArchDir.FindClose(f.inner)
$END
END Release;


(* Start the platform's own walk of dir.

   The mask the platform is handed is always the everything mask: a mask is
   this module's own text and matching it is this module's own business, so
   the platform is asked for every entry and Wanted throws away the ones the
   caller's mask does not accept.  That is what lets one mask mean the same
   thing on four platforms whose own matching differs. *)
PROCEDURE Start (VAR f: Finder; dir: ARRAY OF CHAR): BOOLEAN;
VAR ok: BOOLEAN;
$IF (WINDOWS)
    d:    ARRAY MaskMax OF WCHAR;
    n:    INTEGER;
$END
BEGIN
$IF (WINDOWS)
    n := Strings.Utf8To16(dir, d);
    ok := (n > 0) & ArchDir.FindFirstW(d, f.inner)
$ELSE
    ok := ArchDir.FindFirst(dir, f.inner)
$END
    RETURN ok
END Start;


(* Take the next entry the mask accepts, advancing the platform walk past
   everything it does not, and answer whether there was one.

   A directory's size is not a size - DOS answers 4096 for "." and anything
   at all for others - so it is zeroed here rather than passed on as if it
   meant something. *)
PROCEDURE Next (VAR f: Finder; VAR e: Entry): BOOLEAN;
VAR
    more, got: BOOLEAN;

BEGIN
    got := FALSE;
    more := TRUE;
    WHILE more & ~got DO
        IF f.pending THEN
            f.pending := FALSE;
            Take(f, e);
            got := Wanted(f, e.name)
        ELSE
            more := Advance(f);
            f.pending := more
        END
    END;
    IF got THEN
        e.isDir := f.inner.e.isDir;
        e.size  := f.inner.e.size;
        e.time  := f.inner.e.time;
        e.attr  := f.inner.e.attr;
        IF e.isDir THEN e.size := 0 END
    END;

    RETURN got
END Next;


PROCEDURE CopyMask (VAR f: Finder; mask: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < MaskMax - 1) & (i < LEN(mask)) & (mask[i] # 0X) DO
        f.mask[i] := mask[i];
        INC(i)
    END;
    f.mask[i] := 0X
END CopyMask;


(* FindFirst - start a walk of the directory dir with the mask mask, and show
   the first entry it selects.

   dir is a path that may or may not end in a separator, and may be "." for
   the current directory.  An empty directory and one that is not there are
   the same answer, FALSE, as they are to every platform's own call. *)
PROCEDURE FindFirst* (VAR f: Finder; dir, mask: ARRAY OF CHAR; VAR e: Entry): BOOLEAN;
BEGIN
    CopyMask(f, mask);
    f.pending := Start(f, dir);

    RETURN Next(f, e)
END FindFirst;


PROCEDURE FindNext* (VAR f: Finder; VAR e: Entry): BOOLEAN;
BEGIN
    RETURN Next(f, e)
END FindNext;


(* FindClose - release a walk.  Idempotent, and a walk that was never started
   is released just as quietly. *)
PROCEDURE FindClose* (VAR f: Finder);
BEGIN
    Release(f);
    f.pending := FALSE
END FindClose;


(* Copy - the first n characters of s into d, terminated.  The one place the
   two procedures below stop writing is here, so a destination too small for
   what is being put in it is cut in one place rather than in each of them. *)
PROCEDURE Copy (s: ARRAY OF CHAR; n: INTEGER; VAR d: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < n) & (i < LEN(s)) & (i < LEN(d) - 1) DO
        d[i] := s[i];
        INC(i)
    END;
    d[i] := 0X
END Copy;


(* Join - dir and name as one path.

   The separator goes in only where it is missing: a dir that already ends in
   one keeps it, and a dir that is a bare drive - "C:" - gets one, which is
   what turns a relative name on C: into an absolute one on C:.  An empty dir
   gives name alone, so a caller with nothing to say about the directory has
   nothing to pass.

   What this does not do is read name: a name that carries a drive or a
   leading separator is joined like any other and lands in the middle of the
   result.  That is the one rule a caller has to know, and it is the rule a
   caller wants - the directory is the dialog's, and the name is not allowed
   to move it. *)
PROCEDURE Join* (dir, name: ARRAY OF CHAR; VAR full: ARRAY OF CHAR);
VAR
    i, n: INTEGER;

BEGIN
    n := 0;
    i := 0;
    WHILE (i < LEN(dir)) & (dir[i] # 0X) & (n < LEN(full) - 1) DO
        full[n] := dir[i];
        INC(n); INC(i)
    END;
    IF (n > 0) & (full[n - 1] # Separator) & (n < LEN(full) - 1) THEN
        full[n] := Separator;
        INC(n)
    END;
    i := 0;
    WHILE (i < LEN(name)) & (name[i] # 0X) & (n < LEN(full) - 1) DO
        full[n] := name[i];
        INC(n); INC(i)
    END;
    full[n] := 0X
END Join;


(* Parent - the directory above dir.

   The cut is at the last separator, which is then dropped - except where what
   is left of it is a drive and nothing else, and there the separator is the
   root and stays.  So "C:\a\b" gives "C:\a", "C:\a" gives "C:\", and "C:\"
   gives itself; on Unix "/a/b" gives "/a" and "/a" gives "/".

   A trailing separator names no level of its own, so it is not one to walk
   up from: "C:\a\" is "C:\a" and gives "C:\", and "/a/" gives "/".  The one
   separator that is not dropped is that of a drive's own root, which would
   otherwise leave a bare "C:" - a path relative to wherever C: happens to be
   - in place of an absolute one.

   A dir that is already a root therefore answers itself, and that is how a
   caller tells whether there is anywhere to go up to: an answer equal to the
   question is a root, and there is no separate flag for it.

   A UNC path - "\\server\share" - is not a shape this knows about: it cuts at
   the last separator like any other, so the parent of a share is the server's
   name alone.  Nothing in this tree walks into one, and the alternative is a
   second grammar in a module whose whole point is that there is one. *)
PROCEDURE Parent* (dir: ARRAY OF CHAR; VAR up: ARRAY OF CHAR);
VAR
    i, n, cut, keep: INTEGER;

BEGIN
    n := Strings.Length(dir);
    WHILE (n > 1) & (dir[n - 1] = Separator) &
          ~((n = 3) & (dir[1] = ":")) DO
        DEC(n)
    END;
    cut := -1;
    i := n - 1;
    WHILE (i >= 0) & (cut < 0) DO
        IF dir[i] = Separator THEN cut := i END;
        DEC(i)
    END;
    IF cut < 0 THEN
        keep := n                       (* no separator at all: unchanged *)
    ELSIF cut = 0 THEN
        keep := 1                       (* the root of a path with no drive *)
    ELSIF dir[cut - 1] = ":" THEN
        keep := cut + 1                 (* the separator is the root of a drive *)
    ELSE
        keep := cut
    END;

    Copy(dir, keep, up)
END Parent;


(* MatchAny - whether a name is one of the masks selects.

   masks is a list of the shapes Match takes, separated by ";".  An empty
   element selects nothing and is skipped rather than handed to Match, which
   would ask whether the name is empty.  A list with no ";" in it is the one
   mask it looks like, so a caller with a single mask writes the mask.

   The splitting is done here rather than in Match because Match works on one
   mask and this is the list; the wildcard rules themselves are Match's and
   are written once, which is the point of the module. *)
PROCEDURE MatchAny* (name, masks: ARRAY OF CHAR): BOOLEAN;
VAR
    one: ARRAY MaskMax OF CHAR;
    i, n, k: INTEGER;
    hit: BOOLEAN;

BEGIN
    hit := FALSE;
    i := 0;
    n := Strings.Length(masks);
    WHILE ~hit & (i <= n) DO
        k := 0;
        WHILE (i < n) & (masks[i] # ";") DO
            IF k < MaskMax - 1 THEN one[k] := masks[i]; INC(k) END;
            INC(i)
        END;
        one[k] := 0X;
        IF k > 0 THEN hit := Match(name, one) END;
        IF i >= n THEN i := n + 1 ELSE INC(i) END
    END;

    RETURN hit
END MatchAny;


(* Drives - the drives this machine has, and which of them is current.

   s receives the names separated by ";", as MatchAny takes its masks, and
   the answer is how many there are.  cur receives the index of the current
   drive in that list, or -1 when the list does not hold it - which is the
   row a caller showing the list should have selected.

   The work is the platform's, because only the platform knows what a drive
   is: DOS and Windows have letters and walk them, and Unix has no drives at
   all and answers the single entry "/" so that a caller's loop looks the
   same everywhere. *)
PROCEDURE Drives* (VAR s: ARRAY OF CHAR; VAR cur: INTEGER): INTEGER;
BEGIN
    RETURN ArchDir.Drives(s, cur)
END Drives;


(* CurrentDir - the directory the program is in, as an absolute path.

   Absolute is the whole of it: on DOS and Windows the drive letter is part
   of the answer, so that a caller can show it and can navigate away from it
   and back.  A platform that cannot answer leaves s empty, and an empty
   directory is the harmless reading of that - the paths a caller builds from
   it are relative ones, which is where the program already is. *)
PROCEDURE CurrentDir* (VAR s: ARRAY OF CHAR);
BEGIN
    ArchDir.CurrentDir(s)
END CurrentDir;




END Dirs.
