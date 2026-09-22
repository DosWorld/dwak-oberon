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


PROCEDURE GetArg* (n: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    i, len, ptr: INTEGER;
    c: CHAR;

BEGIN
    i := 0;
    len := LEN(s) - 1;
    IF (0 <= n) & (n <= argc + envc) & (n # argc) & (len > 0) THEN
        IF n < argc THEN
            SYSTEM.GET(API.MainArgv + n * SYSTEM.SIZE(INTEGER), ptr)
        ELSE
            SYSTEM.GET(API.MainEnvp + (n - argc - 1) * SYSTEM.SIZE(INTEGER), ptr)
        END;
        REPEAT
            SYSTEM.GET(ptr, c);
            s[i] := c;
            INC(i);
            INC(ptr)
        UNTIL (c = 0X) OR (i = len)
    END;
    s[i] := 0X
END GetArg;


PROCEDURE GetEnv* (n: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
    IF (0 <= n) & (n < envc) THEN
        GetArg(n + argc + 1, s)
    ELSE
        s[0] := 0X
    END
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