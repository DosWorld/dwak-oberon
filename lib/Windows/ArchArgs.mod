(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2019-2020, Anton Krotov
    All rights reserved.

    The Windows primitives behind the portable Args: the address of the
    command line the loader wrote, and the environment block.  Walking the
    command line into arguments lives in lib/common/Args.mod.
*)

MODULE ArchArgs;

IMPORT SYSTEM, WINAPI;


CONST

    MAX_ENV = 256;                      (* the most entries that can be indexed *)


VAR

    envc*: INTEGER;
    Env:  ARRAY MAX_ENV OF INTEGER;     (* where each NAME=VALUE entry starts *)


PROCEDURE CommandLine* (): INTEGER;
BEGIN
    RETURN WINAPI.GetCommandLineA()
END CommandLine;


(* The environment arrives as a single block: the strings follow one another
   to the end, a NUL after each and a further NUL after the last, and the
   block belongs to the caller until it is given back.  The address of each
   entry is taken down here and the block is returned at once, so a program
   that reads the environment many times reads it from these rather than
   from a block that would have to be held open.

   The block opens with entries whose name is empty - "=C:=C:\dir" and its
   like, which name the current directory of a drive.  DOS never had them
   and Linux never had them, so they are left out here and the numbering
   starts at the first real NAME=VALUE entry. *)
PROCEDURE InitEnv;
VAR
    block, p: INTEGER;
    c: CHAR;

BEGIN
    envc := 0;
    block := WINAPI.GetEnvironmentStringsA();
    IF block # 0 THEN
        p := block;
        SYSTEM.GET(p, c);
        WHILE c # 0X DO
            IF c # "=" THEN
                IF envc < MAX_ENV THEN
                    Env[envc] := p;
                    INC(envc)
                END
            END;
            WHILE c # 0X DO
                INC(p);
                SYSTEM.GET(p, c)
            END;
            INC(p);
            SYSTEM.GET(p, c)
        END;
        WINAPI.FreeEnvironmentStringsA(block)
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
    InitEnv
END ArchArgs.
