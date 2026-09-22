(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.
*)

MODULE HOST;

IMPORT SYSTEM, API;


CONST

    slash* = "/";
    eol* = 0AX;

    bit_depth* = 64;
    maxint* = ROR(-2, 1);
    minint* = ROR(1, 1);

    SYS_exit    = 2000001H;
    SYS_read    = 2000003H;
    SYS_write   = 2000004H;
    SYS_open    = 2000005H;
    SYS_close   = 2000006H;
    SYS_chmod   = 200000FH;
    SYS_unlink  = 200000AH;
    SYS_fcntl   = 200005CH;
    SYS_lseek   = 20000C7H;
    SYS_gettimeofday = 2000074H;

    F_GETPATH = 50;

    O_RDONLY = 0; O_WRONLY = 1;
    O_CREAT  = 0200H; O_TRUNC = 0400H;

    MAXPATHLEN = 1024;


VAR

    maxreal*, inf*: REAL;

    argc: INTEGER;


PROCEDURE ExitProcess* (code: INTEGER);
BEGIN
    API.exit(code)
END ExitProcess;


PROCEDURE GetArg* (n: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    i, len, ptr: INTEGER;
    c: CHAR;

BEGIN
    i := 0;
    len := LEN(s) - 1;
    IF (0 <= n) & (n < argc) & (len > 0) THEN
        SYSTEM.GET(API.MainArgv + n * SYSTEM.SIZE(INTEGER), ptr);
        REPEAT
            SYSTEM.GET(ptr, c);
            s[i] := c;
            INC(i);
            INC(ptr)
        UNTIL (c = 0X) OR (i = len)
    END;
    s[i] := 0X
END GetArg;


(* No getcwd syscall exists on Darwin - libc's own getcwd(3) is built the
   same way: open "." and ask fcntl for the fd's full path. *)
PROCEDURE GetCurrentDirectory* (VAR path: ARRAY OF CHAR);
VAR
    fd, n, res, closeRes: INTEGER;
    buf: ARRAY MAXPATHLEN OF CHAR;

BEGIN
    fd := API.syscall(SYS_open, SYSTEM.SADR("."), O_RDONLY, 0, 0, 0, 0);
    IF fd >= 0 THEN
        res := API.syscall(SYS_fcntl, fd, F_GETPATH, SYSTEM.ADR(buf[0]), 0, 0, 0);
        closeRes := API.syscall(SYS_close, fd, 0, 0, 0, 0, 0);
        IF res >= 0 THEN
            COPY(buf, path)
        ELSE
            path[0] := 0X
        END
    ELSE
        path[0] := 0X
    END;

    n := LENGTH(path);
    IF (n = 0) OR (path[n - 1] # slash) THEN
        path[n] := slash;
        path[n + 1] := 0X
    END
END GetCurrentDirectory;


PROCEDURE FileRead* (F: INTEGER; VAR Buffer: ARRAY OF CHAR; bytes: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := API.syscall(SYS_read, F, SYSTEM.ADR(Buffer[0]), bytes, 0, 0, 0);
    IF res <= 0 THEN
        res := -1
    END

    RETURN res
END FileRead;


PROCEDURE FileWrite* (F: INTEGER; Buffer: ARRAY OF BYTE; bytes: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := API.syscall(SYS_write, F, SYSTEM.ADR(Buffer[0]), bytes, 0, 0, 0);
    IF res <= 0 THEN
        res := -1
    END

    RETURN res
END FileWrite;


PROCEDURE FileCreate* (FName: ARRAY OF CHAR): INTEGER;
    RETURN API.syscall(SYS_open, SYSTEM.ADR(FName[0]), O_WRONLY + O_CREAT + O_TRUNC, 01B6H, 0, 0, 0) (* 0666 *)
END FileCreate;


PROCEDURE FileClose* (File: INTEGER);
VAR
    res: INTEGER;
BEGIN
    res := API.syscall(SYS_close, File, 0, 0, 0, 0, 0)
END FileClose;


PROCEDURE chmod* (FName: ARRAY OF CHAR);
VAR res: INTEGER;
BEGIN
    res := API.syscall(SYS_chmod, SYSTEM.ADR(FName[0]), 01EDH, 0, 0, 0, 0); (* 0755 *)
    ASSERT(res = 0)
END chmod;


PROCEDURE FileOpen* (FName: ARRAY OF CHAR): INTEGER;
    RETURN API.syscall(SYS_open, SYSTEM.ADR(FName[0]), O_RDONLY, 0, 0, 0, 0)
END FileOpen;


PROCEDURE OutChar* (c: CHAR);
VAR
    res: INTEGER;

BEGIN
    res := API.syscall(SYS_write, 1, SYSTEM.ADR(c), 1, 0, 0, 0)
END OutChar;


PROCEDURE GetTickCount* (): INTEGER;
VAR
    tv: ARRAY 2 OF INTEGER; (* tv_sec: 8 bytes, tv_usec: 4 bytes + 4 padding *)
    res: INTEGER;

BEGIN
    res := API.syscall(SYS_gettimeofday, SYSTEM.ADR(tv[0]), 0, 0, 0, 0, 0);
    IF res >= 0 THEN
        res := tv[0] * 100 + (tv[1] MOD 100000000H) DIV 10000
    ELSE
        res := 0
    END

    RETURN res
END GetTickCount;


PROCEDURE isRelative* (path: ARRAY OF CHAR): BOOLEAN;
    RETURN path[0] # slash
END isRelative;


PROCEDURE UnixTime* (): INTEGER;
VAR
    tv: ARRAY 2 OF INTEGER;
    res: INTEGER;

BEGIN
    res := API.syscall(SYS_gettimeofday, SYSTEM.ADR(tv[0]), 0, 0, 0, 0, 0);
    IF res < 0 THEN
        tv[0] := 0
    END

    RETURN tv[0]
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
    DEC(e, 896)

    RETURN LSL(s, 31) + LSL(e, 23) + (h MOD 100000H) * 8 + (l DIV 20000000H) MOD 8
END d2s;


BEGIN
    inf := SYSTEM.INF();
    maxreal := 1.9;
    PACK(maxreal, 1023);
    argc := API.MainArgc
END HOST.
