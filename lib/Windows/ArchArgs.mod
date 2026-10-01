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

    (* The copy of the environment block that InitEnv makes.  Win32 caps a
       variable at 32767 characters and an environment block in practice
       well below that; a block that does not fit is not copied. *)
    MAX_ENV_CHARS = 32768;


VAR

    envc*: INTEGER;
    EnvBuf: ARRAY MAX_ENV_CHARS OF CHAR;    (* the entries, copied out of the block *)
    Env:  ARRAY MAX_ENV OF INTEGER;     (* where each NAME=VALUE entry starts *)


PROCEDURE CommandLine* (): INTEGER;
BEGIN
    RETURN WINAPI.GetCommandLineA()
END CommandLine;


(* The environment arrives as a single block: the strings follow one another
   to the end, a NUL after each and a further NUL after the last, and the
   block belongs to the caller, who must give it back again with
   FreeEnvironmentStringsA.  What this module keeps is therefore not the
   block but a copy of it, because Env[] has to stay readable for as long as
   the program runs.  Both of the other two answers are wrong.  Reading the
   block after giving it back is silent corruption - the entries are still
   there until the first Win32 call that allocates, and after that they are
   whatever was allocated over them, so an environment read late in a run is
   garbage while the same read at startup happens to be fine.  Holding the
   block instead of copying it does leak it.

   The copy lives in a static buffer and is not an allocation: it is
   written once, and the part of it that is never written is never
   committed.  An environment larger than the buffer is the one case the
   copy cannot serve; there the block itself is walked and, exceptionally,
   not given back, because dropping entries would lose names.

   The block opens with entries whose name is empty - "=C:=C:\dir" and its
   like, which name the current directory of a drive.  DOS never had them
   and Linux never had them, so they are left out here and the numbering
   starts at the first real NAME=VALUE entry. *)
PROCEDURE InitEnv;
VAR
    block, p, len, i: INTEGER;
    c: CHAR;
    copied: BOOLEAN;

BEGIN
    envc := 0;
    block := WINAPI.GetEnvironmentStringsA();
    IF block # 0 THEN
        (* Measure the block: its entries, the NUL after each of them, and
           the further NUL that ends the block - the same walk the scan
           below makes, only counting.  It reads no character past the end
           of the block, which the copy below relies on. *)
        p := block; len := 0;
        SYSTEM.GET(p, c);
        WHILE c # 0X DO
            WHILE c # 0X DO
                INC(p); INC(len);
                SYSTEM.GET(p, c)
            END;
            INC(p); INC(len);
            SYSTEM.GET(p, c)
        END;
        INC(len);

        copied := len <= MAX_ENV_CHARS;
        IF copied THEN
            i := 0;
            WHILE i < len DO
                SYSTEM.GET(block + i, c);
                EnvBuf[i] := c;
                INC(i)
            END;
            WINAPI.FreeEnvironmentStringsA(block);
            p := SYSTEM.ADR(EnvBuf[0])
        ELSE
            p := block
        END;

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
    InitEnv
END ArchArgs.
