(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2019-2020, Anton Krotov
    All rights reserved.

    The HX-DOS primitives behind the portable Args: the command line, put
    back together from the two places DOS keeps it in, and the environment
    block.  Walking the command line into arguments lives in
    lib/common/Args.mod.
*)

MODULE ArchArgs;

IMPORT SYSTEM, DOS;


CONST

    MAX_CMD  = 1024;
    MAX_TAIL = 128;                     (* DOS counts the tail with one byte *)
    MAX_ENV  = 256;                     (* the most entries that can be indexed *)


VAR

    cmd:  ARRAY MAX_CMD OF CHAR;
    tail: ARRAY MAX_TAIL OF CHAR;
    envc*: INTEGER;
    Env:  ARRAY MAX_ENV OF INTEGER;     (* where each NAME=VALUE entry starts *)


PROCEDURE CommandLine* (): INTEGER;
BEGIN
    RETURN SYSTEM.ADR(cmd[0])
END CommandLine;


(* Win32 hands a program one string: the quoted path of the executable, a
   space, then the arguments as the shell wrote them. DOS keeps the two
   apart - the path is what the loader knows the module by, the arguments are
   the command tail in the PSP - so the string is put back together here. The
   arguments keep their numbers either way, and quoting the path keeps a
   directory with a space in it in one piece. *)
PROCEDURE BuildCmdLine;
VAR
    len, tlen, n, i: INTEGER;

BEGIN
    n := 0;
    cmd[n] := '"'; INC(n);
    DOS.ProgPath(SYSTEM.ADR(cmd[n]), MAX_CMD DIV 2, len);
    IF len < 0 THEN
        (* The loader did not answer, so the name is not to be had. Leave a
           stand-in in place rather than let the first argument be mistaken
           for the program. *)
        cmd[n] := 'p'; INC(n); cmd[n] := 'r'; INC(n); cmd[n] := 'o'; INC(n);
        cmd[n] := 'g'; INC(n); cmd[n] := 'r'; INC(n); cmd[n] := 'a'; INC(n);
        cmd[n] := 'm'; INC(n); cmd[n] := '.'; INC(n); cmd[n] := 'e'; INC(n);
        cmd[n] := 'x'; INC(n); cmd[n] := 'e'; INC(n)
    ELSE
        INC(n, len)
    END;
    cmd[n] := '"'; INC(n);

    DOS.CmdLine(SYSTEM.ADR(tail[0]), tlen);
    IF (tlen > 0) & (tail[0] # " ") THEN
        cmd[n] := " "; INC(n)
    END;
    i := 0;
    WHILE (i < tlen) & (n < MAX_CMD - 1) DO
        cmd[n] := tail[i];
        INC(n);
        INC(i)
    END;
    cmd[n] := 0X
END BuildCmdLine;


(* The DOS environment block is a run of NUL terminated NAME=VALUE strings
   ended by a further NUL, and the segment it lives in sits at PSP offset
   2Ch.  There is nothing to skip here: DOS has no entries whose name is
   empty, which is the one thing that distinguishes this block from the one
   Windows hands over. *)
PROCEDURE InitEnv;
VAR
    p: INTEGER;
    c: CHAR;

BEGIN
    envc := 0;
    p := DOS.EnvPtr();
    IF p # 0 THEN
        SYSTEM.GET(p, c);
        WHILE c # 0X DO
            IF envc < MAX_ENV THEN
                Env[envc] := p;
                INC(envc)
            END;
            WHILE c # 0X DO
                INC(p);
                SYSTEM.GET(p, c)
            END;
            INC(p);
            SYSTEM.GET(p, c)
        END
    END
END InitEnv;


(* The whole "NAME=VALUE" entry, which is what Linux and macOS give too. *)
PROCEDURE GetEnv* (n: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    i, len, p: INTEGER;
    c: CHAR;

BEGIN
    i := 0;
    len := LEN(s) - 1;
    IF (n >= 0) & (n < envc) & (len > 0) THEN
        p := Env[n];
        SYSTEM.GET(p, c);
        WHILE (c # 0X) & (i < len) DO
            s[i] := c;
            INC(i);
            INC(p);
            SYSTEM.GET(p, c)
        END
    END;
    s[i] := 0X
END GetEnv;


BEGIN
    BuildCmdLine;
    InitEnv
END ArchArgs.
