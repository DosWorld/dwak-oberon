(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2020, Anton Krotov
    All rights reserved.

    The macOS primitives behind the portable Args.  argv and envp are two
    arrays of pointers the kernel hands over separately - MainArgv and
    MainEnvp - rather than one block, and both are read straight out of them
    with nothing to parse: the surface above them is lib/common/Args.mod.
*)

MODULE ArchArgs;

IMPORT SYSTEM, API;


VAR

    argc*, envc*: INTEGER;


PROCEDURE CopyString(ptr: INTEGER; VAR s: ARRAY OF CHAR);
VAR i: INTEGER; c: CHAR;
BEGIN
    IF LEN(s) > 0 THEN
        i := 0; c := 01X;
        WHILE (ptr # 0) & (i < LEN(s) - 1) & (c # 0X) DO
            SYSTEM.GET(ptr + i, c); s[i] := c;
            IF c # 0X THEN INC(i) END
        END;
        s[i] := 0X
    END
END CopyString;

PROCEDURE GetArg* (n: INTEGER; VAR s: ARRAY OF CHAR);
VAR ptr: INTEGER;
BEGIN
    ptr := 0;
    IF (0 <= n) & (n < argc) THEN
        SYSTEM.GET(API.MainArgv + n * SYSTEM.SIZE(INTEGER), ptr)
    END;
    CopyString(ptr, s)
END GetArg;

PROCEDURE GetEnv* (n: INTEGER; VAR s: ARRAY OF CHAR);
VAR ptr: INTEGER;
BEGIN
    ptr := 0;
    IF (0 <= n) & (n < envc) THEN
        SYSTEM.GET(API.MainEnvp + n * SYSTEM.SIZE(INTEGER), ptr)
    END;
    CopyString(ptr, s)
END GetEnv;


PROCEDURE init;
VAR
    ptr: INTEGER;

BEGIN
    argc := API.MainArgc;
    IF API.MainEnvp # 0 THEN
        envc := -1;
        REPEAT
            SYSTEM.GET(API.MainEnvp + (envc + 1) * SYSTEM.SIZE(INTEGER), ptr);
            INC(envc)
        UNTIL ptr = 0
    ELSE
        envc := 0
    END
END init;


BEGIN
    init
END ArchArgs.