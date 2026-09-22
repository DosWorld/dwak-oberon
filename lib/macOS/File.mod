(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    macOS port of the File module. Every operation is a raw BSD/XNU
    syscall (see API.syscall) - nothing here calls into libSystem.
*)

MODULE File;

IMPORT SYSTEM, API;


CONST

    OPEN_R* = 0;   OPEN_W* = 1;   OPEN_RW* = 2;
    SEEK_BEG* = 0; SEEK_CUR* = 1; SEEK_END* = 2;

    SYS_open   = 2000005H;
    SYS_close  = 2000006H;
    SYS_read   = 2000003H;
    SYS_write  = 2000004H;
    SYS_unlink = 200000AH;
    SYS_lseek  = 20000C7H;
    SYS_mkdir  = 2000088H;
    SYS_rmdir  = 2000089H;
    SYS_stat64 = 2000152H;

    O_RDONLY = 0; O_WRONLY = 1; O_RDWR = 2;
    O_CREAT  = 0200H; O_TRUNC = 0400H;

    (* struct stat64: st_mode is a 32-bit mode_t at offset 8 on this ABI *)
    STAT_SIZE = 192;
    ST_MODE_OFFS = 8;
    S_IFMT = 0F000H; S_IFDIR = 04000H;


PROCEDURE OpenFlags (Mode: INTEGER): INTEGER;
VAR
    res: INTEGER;
BEGIN
    CASE Mode OF
    |OPEN_W:  res := O_WRONLY
    |OPEN_RW: res := O_RDWR
    ELSE      res := O_RDONLY
    END
    RETURN res
END OpenFlags;


PROCEDURE GetAttr (FName: ARRAY OF CHAR; VAR mode: INTEGER): BOOLEAN;
VAR
    st: ARRAY STAT_SIZE OF BYTE;
    res: INTEGER;

BEGIN
    res := API.syscall(SYS_stat64, SYSTEM.ADR(FName[0]), SYSTEM.ADR(st[0]), 0, 0, 0, 0);
    IF res >= 0 THEN
        SYSTEM.GET32(SYSTEM.ADR(st[0]) + ST_MODE_OFFS, mode)
    END

    RETURN res >= 0
END GetAttr;


PROCEDURE Exists* (FName: ARRAY OF CHAR): BOOLEAN;
VAR
    mode: INTEGER;
BEGIN
    RETURN GetAttr(FName, mode) & (ORD(BITS(mode) * BITS(S_IFMT)) # S_IFDIR)
END Exists;


PROCEDURE ExistsDir* (DirName: ARRAY OF CHAR): BOOLEAN;
VAR
    mode: INTEGER;
BEGIN
    RETURN GetAttr(DirName, mode) & (ORD(BITS(mode) * BITS(S_IFMT)) = S_IFDIR)
END ExistsDir;


PROCEDURE Delete* (FName: ARRAY OF CHAR): BOOLEAN;
    RETURN API.syscall(SYS_unlink, SYSTEM.ADR(FName[0]), 0, 0, 0, 0, 0) >= 0
END Delete;


PROCEDURE Close* (F: INTEGER);
VAR
    res: INTEGER;
BEGIN
    res := API.syscall(SYS_close, F, 0, 0, 0, 0, 0)
END Close;


PROCEDURE Open* (FName: ARRAY OF CHAR; Mode: INTEGER): INTEGER;
    RETURN API.syscall(SYS_open, SYSTEM.ADR(FName[0]), OpenFlags(Mode), 0, 0, 0, 0)
END Open;


PROCEDURE Create* (FName: ARRAY OF CHAR): INTEGER;
    RETURN API.syscall(SYS_open, SYSTEM.ADR(FName[0]), O_WRONLY + O_CREAT + O_TRUNC, 01B6H, 0, 0, 0)
END Create;


PROCEDURE Seek* (F, Offset, Origin: INTEGER): INTEGER;
    RETURN API.syscall(SYS_lseek, F, Offset, Origin, 0, 0, 0)
END Seek;


PROCEDURE Write* (F, Buffer, Count: INTEGER): INTEGER;
    RETURN API.syscall(SYS_write, F, Buffer, Count, 0, 0, 0)
END Write;


PROCEDURE Read* (F, Buffer, Count: INTEGER): INTEGER;
    RETURN API.syscall(SYS_read, F, Buffer, Count, 0, 0, 0)
END Read;


PROCEDURE Load* (FName: ARRAY OF CHAR; VAR Size: INTEGER): INTEGER;
VAR
    res, n, F: INTEGER;

BEGIN
    res := 0;
    F := Open(FName, OPEN_R);

    IF F >= 0 THEN
        Size := Seek(F, 0, SEEK_END);
        n    := Seek(F, 0, SEEK_BEG);
        res  := API._NEW(Size);
        IF (res = 0) OR (Read(F, res, Size) # Size) THEN
            IF res # 0 THEN
                res := API._DISPOSE(res);
                Size := 0
            END
        END;
        Close(F)
    END

    RETURN res
END Load;


PROCEDURE RemoveDir* (DirName: ARRAY OF CHAR): BOOLEAN;
    RETURN API.syscall(SYS_rmdir, SYSTEM.ADR(DirName[0]), 0, 0, 0, 0, 0) >= 0
END RemoveDir;


PROCEDURE CreateDir* (DirName: ARRAY OF CHAR): BOOLEAN;
    RETURN API.syscall(SYS_mkdir, SYSTEM.ADR(DirName[0]), 01FFH, 0, 0, 0, 0) >= 0 (* 0777 *)
END CreateDir;


END File.
