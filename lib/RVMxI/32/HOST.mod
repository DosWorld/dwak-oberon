(*
    BSD 2-Clause License

    Copyright (c) 2020-2022, Anton Krotov
    All rights reserved.
*)

MODULE HOST;

IMPORT SYSTEM, Trap;


CONST

    $IF (host_linux)

    slash* = "/";
    eol* = 0AX;

    $ELSE

    slash* = "\";
    eol* = 0DX + 0AX;

    $END

    bit_depth* = 32;
    maxint* = 7FFFFFFFH;
    minint* = 80000000H;


VAR

    maxreal*, inf*: REAL;


PROCEDURE syscall0 (fn: INTEGER): INTEGER;
BEGIN
    Trap.syscall(SYSTEM.ADR(fn))
    RETURN fn
END syscall0;


PROCEDURE syscall1 (fn, p1: INTEGER): INTEGER;
BEGIN
    Trap.syscall(SYSTEM.ADR(fn))
    RETURN fn
END syscall1;


PROCEDURE syscall2 (fn, p1, p2: INTEGER): INTEGER;
BEGIN
    Trap.syscall(SYSTEM.ADR(fn))
    RETURN fn
END syscall2;


PROCEDURE syscall3 (fn, p1, p2, p3: INTEGER): INTEGER;
BEGIN
    Trap.syscall(SYSTEM.ADR(fn))
    RETURN fn
END syscall3;


PROCEDURE syscall4 (fn, p1, p2, p3, p4: INTEGER): INTEGER;
BEGIN
    Trap.syscall(SYSTEM.ADR(fn))
    RETURN fn
END syscall4;


PROCEDURE ExitProcess* (code: INTEGER);
BEGIN
    code := syscall1(0, code)
END ExitProcess;


PROCEDURE GetCurrentDirectory* (VAR path: ARRAY OF CHAR);
VAR
    a: INTEGER;
BEGIN
    a := syscall2(1, LEN(path), SYSTEM.ADR(path[0]))
END GetCurrentDirectory;


PROCEDURE GetArg* (n: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
    n := syscall3(2, n, LEN(s), SYSTEM.ADR(s[0]))
END GetArg;


PROCEDURE FileRead* (F: INTEGER; VAR Buffer: ARRAY OF CHAR; bytes: INTEGER): INTEGER;
    RETURN syscall4(3, F, LEN(Buffer), SYSTEM.ADR(Buffer[0]), bytes)
END FileRead;


PROCEDURE FileWrite* (F: INTEGER; Buffer: ARRAY OF BYTE; bytes: INTEGER): INTEGER;
    RETURN syscall4(4, F, LEN(Buffer), SYSTEM.ADR(Buffer[0]), bytes)
END FileWrite;


PROCEDURE FileCreate* (FName: ARRAY OF CHAR): INTEGER;
    RETURN syscall2(5, LEN(FName), SYSTEM.ADR(FName[0]))
END FileCreate;


PROCEDURE FileClose* (F: INTEGER);
BEGIN
    F := syscall1(6, F)
END FileClose;


PROCEDURE FileOpen* (FName: ARRAY OF CHAR): INTEGER;
    RETURN syscall2(7, LEN(FName), SYSTEM.ADR(FName[0]))
END FileOpen;


(* The calls below are the rest of the file interface ArchFile is built on.
   Each one is a single syscall: the first word of the argument block carries
   the function number, the words after it are the arguments, and the answer
   comes back in the first word, which is what the syscallN helpers return.
   The numbers match the dispatcher in tools/RVMxI.mod and the implementations
   in the emulator's own HOST module (lib/Windows/HOST.mod).  Read and write
   take a buffer address rather than an open array, because ArchFile.Read is
   handed an address by its own caller and an open array cannot be built from
   one. *)

PROCEDURE FileReadAt* (F, Buffer, bytes: INTEGER): INTEGER;
    RETURN syscall3(13, F, Buffer, bytes)
END FileReadAt;


PROCEDURE FileWriteAt* (F, Buffer, bytes: INTEGER): INTEGER;
    RETURN syscall3(14, F, Buffer, bytes)
END FileWriteAt;


PROCEDURE FileSeek* (F, Offset, Origin: INTEGER): INTEGER;
    RETURN syscall3(15, F, Offset, Origin)
END FileSeek;


PROCEDURE FileOpenMode* (FName: ARRAY OF CHAR; Mode: INTEGER): INTEGER;
    RETURN syscall3(16, LEN(FName), SYSTEM.ADR(FName[0]), Mode)
END FileOpenMode;


PROCEDURE FileDelete* (FName: ARRAY OF CHAR): BOOLEAN;
    RETURN syscall2(17, LEN(FName), SYSTEM.ADR(FName[0])) # 0
END FileDelete;


PROCEDURE FileRename* (OldName, NewName: ARRAY OF CHAR): BOOLEAN;
    RETURN syscall4(18, LEN(OldName), SYSTEM.ADR(OldName[0]), LEN(NewName), SYSTEM.ADR(NewName[0])) # 0
END FileRename;


PROCEDURE FileExists* (FName: ARRAY OF CHAR): BOOLEAN;
    RETURN syscall2(19, LEN(FName), SYSTEM.ADR(FName[0])) # 0
END FileExists;


PROCEDURE FileDirExists* (FName: ARRAY OF CHAR): BOOLEAN;
    RETURN syscall2(20, LEN(FName), SYSTEM.ADR(FName[0])) # 0
END FileDirExists;


PROCEDURE FileMakeDir* (FName: ARRAY OF CHAR): BOOLEAN;
    RETURN syscall2(21, LEN(FName), SYSTEM.ADR(FName[0])) # 0
END FileMakeDir;


PROCEDURE FileRemoveDir* (FName: ARRAY OF CHAR): BOOLEAN;
    RETURN syscall2(22, LEN(FName), SYSTEM.ADR(FName[0])) # 0
END FileRemoveDir;


PROCEDURE FileGetTime* (FName: ARRAY OF CHAR): INTEGER;
    RETURN syscall2(23, LEN(FName), SYSTEM.ADR(FName[0]))
END FileGetTime;


PROCEDURE FileSetTime* (FName: ARRAY OF CHAR; time: INTEGER): BOOLEAN;
    RETURN syscall3(24, LEN(FName), SYSTEM.ADR(FName[0]), time) # 0
END FileSetTime;


PROCEDURE FileTruncate* (F, Size: INTEGER): BOOLEAN;
    RETURN syscall2(25, F, Size) # 0
END FileTruncate;


PROCEDURE chmod* (FName: ARRAY OF CHAR);
VAR
    a: INTEGER;
BEGIN
    a := syscall2(12, LEN(FName), SYSTEM.ADR(FName[0]))
END chmod;


PROCEDURE OutChar* (c: CHAR);
VAR
    a: INTEGER;
BEGIN
    a := syscall1(8, ORD(c))
END OutChar;


PROCEDURE GetTickCount* (): INTEGER;
    RETURN syscall0(9)
END GetTickCount;


PROCEDURE isRelative* (path: ARRAY OF CHAR): BOOLEAN;
    RETURN syscall2(11, LEN(path), SYSTEM.ADR(path[0])) # 0
END isRelative;


PROCEDURE UnixTime* (): INTEGER;
    RETURN syscall0(10)
END UnixTime;


PROCEDURE s2d (x: INTEGER; VAR h, l: INTEGER);
VAR
    s, e, f: INTEGER;
BEGIN
    s := ASR(x, 31) MOD 2;
    f := x MOD 800000H;
    e := (x DIV 800000H) MOD 256;
    IF e = 255 THEN
        e := 2047
    ELSE
        INC(e, 896)
    END;
    h := LSL(s, 31) + LSL(e, 20) + (f DIV 8);
    l := (f MOD 8) * 20000000H
END s2d;


PROCEDURE d2s* (x: REAL): INTEGER;
VAR
    i: INTEGER;
BEGIN
    SYSTEM.GET(SYSTEM.ADR(x), i)
    RETURN i
END d2s;


PROCEDURE splitf* (x: REAL; VAR a, b: INTEGER): INTEGER;
BEGIN
    s2d(d2s(x), b, a)
    RETURN a
END splitf;


BEGIN
    inf := SYSTEM.INF();
    maxreal := 1.9;
    PACK(maxreal, 127)
END HOST.