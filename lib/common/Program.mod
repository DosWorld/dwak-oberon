(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    Where the running program is.  The portable half: it names no platform,
    and the one platform call behind it is ArchProgram's, one file per target.

    Everything here is split out of a path with Dirs.Separator and with the
    `.` that begins an extension, so a program asks the same question on
    every target and gets the same shape of answer.  A target whose loader
    does not say where the image came from answers the empty string, and that
    is a real answer rather than a failure: it is what the dpmi32le target
    does, and a caller that builds a path on it gets a bare file name, which
    every target reads as "in the current directory".

    The path is what the SYSTEM knows, not what the command line said.
    `prog.exe`, `.\prog.exe` and `C:\deep\prog.exe` all answer the last of
    those on Windows, because GetModuleFileNameA is asked and not argv[0];
    on macOS, where there is no such call, argv[0] is what there is, and a
    program started by a bare name therefore answers a bare name.
*)

MODULE Program;

IMPORT ArchProgram, Dirs, Strings;


CONST

    (* The longest path this module will hold.  Windows caps a path at 260
       and DOS at 128; the extra is for the targets that do not.  A path that
       does not fit is cut, which is what every other path in this tree does
       with one. *)
    MaxPath = 1024;


(* Path - the running image, as the system names it, or the empty string when
   the target has no way to ask. *)
PROCEDURE Path* (VAR s: ARRAY OF CHAR);
BEGIN
    ArchProgram.Path(s)
END Path;


(* Dir - the directory part of Path, without the separator on the end, or the
   empty string when Path is empty or holds no directory at all.  No
   separator on the end is what makes it the right argument for Dirs.Join,
   which adds one only when it is missing.

   `C:` is a directory here, and on Windows it means the current directory of
   drive C rather than its root.  That is the same meaning the path had, and
   GetModuleFileNameA never answers one. *)
PROCEDURE Dir* (VAR s: ARRAY OF CHAR);
VAR
    p: ARRAY MaxPath OF CHAR;
    i, last: INTEGER;

BEGIN
    s[0] := 0X;
    ArchProgram.Path(p);
    last := -1;
    i := 0;
    WHILE (i < LEN(p)) & (p[i] # 0X) DO
        IF (p[i] = "/") OR (p[i] = "\") OR (p[i] = ":") THEN last := i END;
        INC(i)
    END;
    IF last >= 0 THEN
        Strings.Extract(p, 0, last, s)
    END
END Dir;


(* Name - the file name part of Path, extension and all. *)
PROCEDURE Name* (VAR s: ARRAY OF CHAR);
VAR
    p: ARRAY MaxPath OF CHAR;
    i, from: INTEGER;

BEGIN
    s[0] := 0X;
    ArchProgram.Path(p);
    from := 0;
    i := 0;
    WHILE (i < LEN(p)) & (p[i] # 0X) DO
        IF (p[i] = "/") OR (p[i] = "\") THEN from := i + 1 END;
        INC(i)
    END;
    Strings.Extract(p, from, i - from, s)
END Name;


(* Base - Name with the extension taken off: `prog.exe` answers `prog`.  The
   dot has to be in the name and not in a directory, so a path whose last
   component holds none is answered whole. *)
PROCEDURE Base* (VAR s: ARRAY OF CHAR);
VAR
    n: ARRAY MaxPath OF CHAR;
    i, dot: INTEGER;

BEGIN
    Name(n);
    dot := -1;
    i := 0;
    WHILE (i < LEN(n)) & (n[i] # 0X) DO
        IF n[i] = "." THEN dot := i END;
        INC(i)
    END;
    IF dot > 0 THEN
        Strings.Extract(n, 0, dot, s)
    ELSE
        Strings.Copy(n, s)
    END
END Base;


(* DirOf - the directory a file beside the program's own image goes in, with
   the separator on the end and the empty string when there is no directory.
   It is what a caller that concatenates by hand wants; Dirs.Join takes Dir
   instead. *)
PROCEDURE DirOf* (VAR s: ARRAY OF CHAR);
VAR
    d: ARRAY MaxPath OF CHAR;
    n: INTEGER;

BEGIN
    Dir(d);
    n := Strings.Length(d);
    Strings.Copy(d, s);
    IF (n > 0) & (n < LEN(s) - 1) THEN
        s[n] := Dirs.Separator;
        s[n + 1] := 0X
    END
END DirOf;


END Program.
