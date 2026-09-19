(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    HXDOS host layer. No Win32 DLL imports: console, files, arguments and
    the current directory are provided by DOS (int 21h) via the DOS module.
*)

MODULE HOST;

IMPORT SYSTEM, DOS;


CONST

    slash* = "\";
    eol* = 0DX + 0AX;

    bit_depth* = (ORD(LSL(1, 31) > 0) + 1) * 32;
    maxint* = ROR(-2, 1);
    minint* = ROR(1, 1);

    MAX_PARAM = 64;
    MAXLEN = 260;


VAR

    argc: INTEGER;
    argv: ARRAY MAX_PARAM OF ARRAY MAXLEN OF CHAR;
    cmdline: ARRAY 1024 OF CHAR;
    cmdlen: INTEGER;
    tok: ARRAY MAXLEN OF CHAR;
    tl: INTEGER;

    maxreal*, inf*: REAL;


PROCEDURE Append (VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
VAR
    i, j: INTEGER;

BEGIN
    i := LENGTH(dst);
    j := 0;
    WHILE (src[j] # 0X) & (i < LEN(dst) - 1) DO
        dst[i] := src[j];
        INC(i);
        INC(j)
    END;
    dst[i] := 0X
END Append;


PROCEDURE CopyZ (src: INTEGER; VAR dst: ARRAY OF CHAR);
VAR
    i: INTEGER;
    c: CHAR;

BEGIN
    i := 0;
    SYSTEM.GET(src, c);
    WHILE (c # 0X) & (i < LEN(dst) - 1) DO
        dst[i] := c;
        INC(i);
        SYSTEM.GET(src + i, c)
    END;
    dst[i] := 0X
END CopyZ;


PROCEDURE Flush;
BEGIN
    IF (tl > 0) & (argc < MAX_PARAM) THEN
        COPY(tok, argv[argc]);
        INC(argc)
    END;
    tl := 0;
    tok[0] := 0X
END Flush;


(* The command tail into argv. argv[0] is a constant and not the module path:
   on this target the compiler finds lib\ beside the CURRENT directory, and
   PATHS makes that directory out of argv[0] - a real path here would turn the
   lookup into an absolute one pointing at wherever the binary was loaded
   from, which is not where lib\ is (section 4 of doc/hxdos.txt).

   Args parses these same rules over a command line it builds itself, and that
   line begins with the real program path - which is exactly the argv[0] this
   one must not have. That single difference is why the compiler parses here
   instead of calling it; the samples, which want the program path, use Args. *)
PROCEDURE ParamParse;
VAR
    i: INTEGER;
    c: CHAR;
    inq: BOOLEAN;

BEGIN
    (* arg0: synthesized as <current dir>\Compiler.exe; only the directory
       matters, it is used to locate lib/HXDOS. *)
    argv[0][0] := 0X;
    Append(argv[0], "Compiler.exe");
    argc := 1;

    tl := 0;
    tok[0] := 0X;
    inq := FALSE;
    i := 0;
    WHILE i < cmdlen DO
        c := cmdline[i];
        IF inq THEN
            IF c = '"' THEN
                inq := FALSE
            ELSE
                IF tl < MAXLEN - 1 THEN
                    tok[tl] := c;
                    INC(tl);
                    tok[tl] := 0X
                END
            END
        ELSIF c = '"' THEN
            inq := TRUE
        ELSIF (c = " ") OR (c = 09X) THEN
            Flush
        ELSE
            IF tl < MAXLEN - 1 THEN
                tok[tl] := c;
                INC(tl);
                tok[tl] := 0X
            END
        END;
        INC(i)
    END;
    Flush
END ParamParse;


PROCEDURE GetArg* (n: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    j: INTEGER;

BEGIN
    j := 0;
    IF (0 <= n) & (n < argc) THEN
        WHILE (argv[n][j] # 0X) & (j < LEN(s) - 1) DO
            s[j] := argv[n][j];
            INC(j)
        END
    END;
    s[j] := 0X
END GetArg;


PROCEDURE GetCurrentDirectory* (VAR path: ARRAY OF CHAR);
BEGIN
    (* Empty on purpose, and not because the call is missing: DOS.GetCurDir
       answers - AH=7147h, with AH=47h behind it - and was measured doing so.
       It is what DOS answers that makes it useless here: the part of a path
       below the root of its drive, carrying neither the drive nor a leading
       backslash, so prepending it would not turn a relative path into an
       absolute one. An empty prefix leaves every path this host builds
       relative to the current directory, which is what the compiler's lib\
       lookup is built around (section 4 of doc/hxdos.txt). *)
    path[0] := 0X
END GetCurrentDirectory;


PROCEDURE FileRead* (F: INTEGER; VAR Buffer: ARRAY OF CHAR; bytes: INTEGER): INTEGER;
VAR
    n: INTEGER;

BEGIN
    DOS.FileRead(F, SYSTEM.ADR(Buffer[0]), bytes, n);
    RETURN n
END FileRead;


PROCEDURE FileWrite* (F: INTEGER; Buffer: ARRAY OF BYTE; bytes: INTEGER): INTEGER;
VAR
    n: INTEGER;

BEGIN
    DOS.FileWrite(F, SYSTEM.ADR(Buffer[0]), bytes, n);
    RETURN n
END FileWrite;


PROCEDURE FileCreate* (FName: ARRAY OF CHAR): INTEGER;
VAR
    h: INTEGER;

BEGIN
    DOS.FileCreate(SYSTEM.ADR(FName[0]), h);
    IF h = 0 THEN
        h := -1
    END
    RETURN h
END FileCreate;


PROCEDURE FileClose* (F: INTEGER);
BEGIN
    DOS.FileClose(F)
END FileClose;


PROCEDURE FileOpen* (FName: ARRAY OF CHAR): INTEGER;
VAR
    h: INTEGER;

BEGIN
    DOS.FileOpen(SYSTEM.ADR(FName[0]), h);
    IF h = 0 THEN
        h := -1
    END
    RETURN h
END FileOpen;


PROCEDURE chmod* (FName: ARRAY OF CHAR);
END chmod;


PROCEDURE ExitProcess* (code: INTEGER);
BEGIN
    DOS.Exit(code)
END ExitProcess;


PROCEDURE OutChar* (c: CHAR);
BEGIN
    DOS.PutChar(ORD(c))
END OutChar;


PROCEDURE GetTickCount* (): INTEGER;
VAR
    h, m, s: INTEGER;

BEGIN
    DOS.GetTime(h, m, s);
    RETURN (h * 3600 + m * 60 + s) * 100
END GetTickCount;


PROCEDURE letter (c: CHAR): BOOLEAN;
    RETURN ("a" <= c) & (c <= "z") OR ("A" <= c) & (c <= "Z")
END letter;


PROCEDURE isRelative* (path: ARRAY OF CHAR): BOOLEAN;
    (* The length test comes first because path[1] is read below: a path of one
       character or none has no second character, and `&` would not save it -
       a path of "G" alone is a letter and then past the end of the string. *)
    RETURN (LEN(path) < 2) OR
           ~(letter(path[0]) & (path[1] = ":"))
END isRelative;


PROCEDURE Days (y, mo, d: INTEGER): INTEGER;
VAR
    era, yoe, doy, doe, m: INTEGER;

BEGIN
    m := mo;
    IF m <= 2 THEN
        DEC(y)
    END;
    IF m > 2 THEN
        m := m - 3
    ELSE
        m := m + 9
    END;
    era := y DIV 400;
    yoe := y - era * 400;
    doy := (153 * m + 2) DIV 5 + d - 1;
    doe := yoe * 365 + yoe DIV 4 - yoe DIV 100 + doy;
    RETURN era * 146097 + doe - 719468
END Days;


PROCEDURE UnixTime* (): INTEGER;
VAR
    y, mo, d, h, mi, s: INTEGER;

BEGIN
    DOS.GetDate(y, mo, d);
    DOS.GetTime(h, mi, s);
    RETURN Days(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
END UnixTime;


PROCEDURE splitf* (x: REAL; VAR a, b: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    a := 0;
    b := 0;
    SYSTEM.GET32(SYSTEM.ADR(x), a);
    SYSTEM.GET32(SYSTEM.ADR(x) + 4, b);
    SYSTEM.GET(SYSTEM.ADR(x), res)
    RETURN res
END splitf;


PROCEDURE d2s* (x: REAL): INTEGER;
VAR
    h, l, s, e: INTEGER;

BEGIN
    e := splitf(x, l, h);

    s := ASR(h, 31) MOD 2;
    e := (h DIV 100000H) MOD 2048;
    IF e <= 896 THEN
        h := (h MOD 100000H) * 8 + (l DIV 20000000H) MOD 8 + 800000H;
        REPEAT
            h := h DIV 2;
            INC(e)
        UNTIL e = 897;
        e := 896;
        l := (h MOD 8) * 20000000H;
        h := h DIV 8
    ELSIF (1151 <= e) & (e < 2047) THEN
        e := 1151;
        h := 0;
        l := 0
    ELSIF e = 2047 THEN
        e := 1151;
        IF (h MOD 100000H # 0) OR (BITS(l) * {0..31} # {}) THEN
            h := 80000H;
            l := 0
        END
    END;
    DEC(e, 896);

    RETURN LSL(s, 31) + LSL(e, 23) + (h MOD 100000H) * 8 + (l DIV 20000000H) MOD 8
END d2s;


BEGIN
    inf := SYSTEM.INF();
    maxreal := 1.9;
    PACK(maxreal, 1023);
    DOS.CmdLine(SYSTEM.ADR(cmdline[0]), cmdlen);
    ParamParse
END HOST.
