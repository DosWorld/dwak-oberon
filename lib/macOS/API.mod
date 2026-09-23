(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.
*)

MODULE API;

(* libSystem bootstrap pointers are bound by MACHO.mod. Other entry points
   are resolved through dlsym during init. The [systemv] convention denotes the
   x86-64 System V ABI used by Darwin C functions as well. Raw syscalls remain
   only for early error reporting and the pre-initialization exit fallback. *)

IMPORT SYSTEM;


CONST

    OS* = "MACOS";
    eol* = 0AX;

    BIT_DEPTH* = 64;

    SYS_exit    = 2000001H;
    SYS_read    = 2000003H;
    SYS_write   = 2000004H;
    SYS_open    = 2000005H;
    SYS_close   = 2000006H;
    SYS_unlink  = 200000AH;
    SYS_fcntl   = 200005CH;
    SYS_mmap    = 20000C5H;
    SYS_lseek   = 20000C7H;
    SYS_gettimeofday = 2000074H;

    F_GETPATH = 50;

    PROT_READ = 1; PROT_WRITE = 2;
    MAP_PRIVATE = 2; MAP_ANON = 1000H;


TYPE

    SOFINI = PROCEDURE;

    Trap = PROCEDURE (ModNum, ModNamePtr, line, error: INTEGER);


VAR

    MainArgc*, MainArgv*, MainEnvp*: INTEGER;

    libSystem*: INTEGER;
    dlopen*: PROCEDURE [systemv] (name, flags: INTEGER): INTEGER;
    dlsym*: PROCEDURE [systemv] (handle, name: INTEGER): INTEGER;
    dlerror*: PROCEDURE [systemv] (): INTEGER;
    closeLibrary: PROCEDURE [systemv] (handle: INTEGER): INTEGER;
    malloc: PROCEDURE [systemv] (size: INTEGER): INTEGER;
    free: PROCEDURE [systemv] (p: INTEGER);
    cExit: PROCEDURE [systemv] (code: INTEGER);
    errnoAddress: PROCEDURE [systemv] (): INTEGER;
    cOpen: PROCEDURE [systemv] (path, flags, mode: INTEGER): INTEGER;
    cClose: PROCEDURE [systemv] (fd: INTEGER): INTEGER;
    cRead, cWrite: PROCEDURE [systemv] (fd, buf, count: INTEGER): INTEGER;
    cSeek: PROCEDURE [systemv] (fd, offset, origin: INTEGER): INTEGER;
    cStat, cRename, cUtimes: PROCEDURE [systemv] (a, b: INTEGER): INTEGER;
    cUnlink, cRmdir: PROCEDURE [systemv] (path: INTEGER): INTEGER;
    cMkdir, cChmod: PROCEDURE [systemv] (path, mode: INTEGER): INTEGER;
    cTruncate: PROCEDURE [systemv] (fd, size: INTEGER): INTEGER;
    getcwd*: PROCEDURE [systemv] (buf, size: INTEGER): INTEGER;
    cGetTimeOfDay: PROCEDURE [systemv] (tv, tz: INTEGER): INTEGER;
    cClockGetTime: PROCEDURE [systemv] (clock, ts: INTEGER): INTEGER;

    fini: SOFINI;
    trap*: Trap;


(* rax <- syscall number (with the BSD class bit already set), the other
   six registers <- the syscall's own arguments; on return, CF set means
   rax holds -errno instead of a positive result, matching Linux's raw
   syscall convention so the rest of the runtime needs no Darwin-specific
   error handling. *)
PROCEDURE [oberon-] syscall* (rax, rdi, rsi, rdx, r10, r8, r9: INTEGER): INTEGER;
BEGIN
    SYSTEM.CODE(
    048H, 08BH, 045H, 010H,  (*  mov rax, qword [rbp + 16]  *)
    048H, 08BH, 07DH, 018H,  (*  mov rdi, qword [rbp + 24]  *)
    048H, 08BH, 075H, 020H,  (*  mov rsi, qword [rbp + 32]  *)
    048H, 08BH, 055H, 028H,  (*  mov rdx, qword [rbp + 40]  *)
    04CH, 08BH, 055H, 030H,  (*  mov r10, qword [rbp + 48]  *)
    04CH, 08BH, 045H, 038H,  (*  mov r8,  qword [rbp + 56]  *)
    04CH, 08BH, 04DH, 040H,  (*  mov r9,  qword [rbp + 64]  *)
    00FH, 005H,              (*  syscall                    *)
    073H, 003H,              (*  jnc L1                     *)
    048H, 0F7H, 0D8H,        (*  neg rax                    *)
                             (*  L1:                        *)
    05DH,                    (*  pop rbp                    *)
    0C2H, 038H, 000H         (*  ret 56                     *)
    )
    RETURN 0
END syscall;


PROCEDURE DebugMsg* (lpText, lpCaption: INTEGER);
    PROCEDURE puts (p: INTEGER);
    VAR
        n, r: INTEGER;
        c: CHAR;
    BEGIN
        n := 0; c := 0X;
        IF p # 0 THEN SYSTEM.GET(p + n, c) END;
        WHILE c # 0X DO
            INC(n);
            SYSTEM.GET(p + n, c)
        END;
        r := syscall(SYS_write, 2, p, n, 0, 0, 0)
    END puts;

BEGIN
    puts(lpCaption);
    puts(lpText)
END DebugMsg;


(* C int is 32 bits; INTEGER is 64. C callees need not sign-extend EAX. *)
PROCEDURE IntResult(r: INTEGER): INTEGER;
BEGIN
    r := r MOD 100000000H;
    IF r >= 80000000H THEN DEC(r, 100000000H) END
    RETURN r
END IntResult;

PROCEDURE Error*(): INTEGER;
VAR p, e: INTEGER;
BEGIN
    p := errnoAddress(); e := 0; SYSTEM.GET32(p, e)
    RETURN e
END Error;

PROCEDURE dlclose*(handle: INTEGER): INTEGER;
BEGIN RETURN IntResult(closeLibrary(handle)) END dlclose;

PROCEDURE Open*(path, flags, mode: INTEGER): INTEGER;
BEGIN RETURN IntResult(cOpen(path, flags, mode)) END Open;

PROCEDURE Close*(fd: INTEGER): INTEGER;
BEGIN RETURN IntResult(cClose(fd)) END Close;

PROCEDURE Read*(fd, buf, count: INTEGER): INTEGER;
VAR r: INTEGER;
BEGIN
    REPEAT r := cRead(fd, buf, count) UNTIL (r # -1) OR (Error() # 4)
    RETURN r
END Read;

PROCEDURE Write*(fd, buf, count: INTEGER): INTEGER;
VAR r: INTEGER;
BEGIN
    REPEAT r := cWrite(fd, buf, count) UNTIL (r # -1) OR (Error() # 4)
    RETURN r
END Write;

PROCEDURE Seek*(fd, offset, origin: INTEGER): INTEGER;
BEGIN RETURN cSeek(fd, offset, origin) END Seek;

PROCEDURE Stat*(path, buf: INTEGER): INTEGER;
BEGIN RETURN IntResult(cStat(path, buf)) END Stat;

PROCEDURE Rename*(old, new: INTEGER): INTEGER;
BEGIN RETURN IntResult(cRename(old, new)) END Rename;

PROCEDURE Unlink*(path: INTEGER): INTEGER;
BEGIN RETURN IntResult(cUnlink(path)) END Unlink;

PROCEDURE Rmdir*(path: INTEGER): INTEGER;
BEGIN RETURN IntResult(cRmdir(path)) END Rmdir;

PROCEDURE Mkdir*(path, mode: INTEGER): INTEGER;
BEGIN RETURN IntResult(cMkdir(path, mode)) END Mkdir;

PROCEDURE Chmod*(path, mode: INTEGER): INTEGER;
BEGIN RETURN IntResult(cChmod(path, mode)) END Chmod;

PROCEDURE Truncate*(fd, size: INTEGER): INTEGER;
BEGIN RETURN IntResult(cTruncate(fd, size)) END Truncate;

PROCEDURE Utimes*(path, tv: INTEGER): INTEGER;
BEGIN RETURN IntResult(cUtimes(path, tv)) END Utimes;

PROCEDURE GetTimeOfDay*(tv: INTEGER): INTEGER;
BEGIN RETURN IntResult(cGetTimeOfDay(tv, 0)) END GetTimeOfDay;

PROCEDURE ClockGetTime*(clock, ts: INTEGER): INTEGER;
BEGIN RETURN IntResult(cClockGetTime(clock, ts)) END ClockGetTime;

PROCEDURE _NEW* (size: INTEGER): INTEGER;
VAR res, pos, stop: INTEGER;
BEGIN
    res := 0;
    IF size > 0 THEN
        res := malloc(size);
        IF res # 0 THEN
            pos := res; stop := res + size;
            WHILE pos <= stop - 8 DO SYSTEM.PUT(pos, 0); INC(pos, 8) END;
            WHILE pos < stop DO SYSTEM.PUT8(pos, 0); INC(pos) END
        END
    END
    RETURN res
END _NEW;

PROCEDURE _DISPOSE* (p: INTEGER): INTEGER;
BEGIN
    free(p)
    RETURN 0
END _DISPOSE;

PROCEDURE GetSym(name: ARRAY OF CHAR; address: INTEGER);
VAR p: INTEGER;
BEGIN
    p := dlsym(libSystem, SYSTEM.ADR(name[0]));
    IF p = 0 THEN
        (* RTL's diagnostic metadata is not initialized yet. *)
        DebugMsg(SYSTEM.ADR(name[0]), SYSTEM.SADR("missing libSystem symbol: "));
        p := syscall(SYS_exit, 1, 0, 0, 0, 0, 0)
    END;
    SYSTEM.PUT(address, p)
END GetSym;


PROCEDURE exit* (code: INTEGER);
VAR
    res: INTEGER;
BEGIN
    IF cExit # NIL THEN cExit(code) END;
    res := syscall(SYS_exit, code, 0, 0, 0, 0, 0)
END exit;


PROCEDURE exit_thread* (code: INTEGER);
BEGIN
    exit(code)
END exit_thread;


PROCEDURE init* (sp, code: INTEGER);
VAR image, cmd, count, kind, size, name, off, bytes, boot, magic: INTEGER;
BEGIN
    fini := NIL;
    trap := NIL;
    (* AMD64 passes a temporary {argc, argv, envp} tuple from LC_MAIN. *)
    SYSTEM.GET(sp, MainArgc);
    SYSTEM.GET(sp + 8, MainArgv);
    SYSTEM.GET(sp + 16, MainEnvp);
    (* MACHO's code begins after 760 bytes of header/load commands. Locate
       __DATA and read its last two pointers, already bound by dyld. Use
       file offsets relative to the actual image base, so ASLR is supported. *)
    image := code - 760; SYSTEM.GET32(image, magic); ASSERT(magic = 0FEEDFACFH);
    SYSTEM.GET32(image + 16, count); cmd := image + 32; boot := 0;
    WHILE count > 0 DO
        SYSTEM.GET32(cmd, kind); SYSTEM.GET32(cmd + 4, size);
        IF kind = 19H THEN
            SYSTEM.GET32(cmd + 8, name);
            IF name = 41445F5FH THEN (* __DA, followed by TA *)
                name := 0; SYSTEM.GET16(cmd + 12, name);
                IF name = 4154H THEN
                    SYSTEM.GET(cmd + 40, off); SYSTEM.GET(cmd + 48, bytes);
                    boot := image + off + bytes - 16
                END
            END
        END;
        INC(cmd, size); DEC(count)
    END;
    ASSERT(boot # 0);
    SYSTEM.GET(boot, dlopen); SYSTEM.GET(boot + 8, dlsym);
    ASSERT((dlopen # NIL) & (dlsym # NIL));
    libSystem := dlopen(SYSTEM.SADR("/usr/lib/libSystem.B.dylib"), 2); (* RTLD_NOW *)
    ASSERT(libSystem # 0);
    GetSym("malloc", SYSTEM.ADR(malloc));
    GetSym("free", SYSTEM.ADR(free));
    GetSym("exit", SYSTEM.ADR(cExit));
    GetSym("dlclose", SYSTEM.ADR(closeLibrary));
    GetSym("dlerror", SYSTEM.ADR(dlerror));
    GetSym("__error", SYSTEM.ADR(errnoAddress));
    GetSym("open", SYSTEM.ADR(cOpen));
    GetSym("close", SYSTEM.ADR(cClose));
    GetSym("read", SYSTEM.ADR(cRead));
    GetSym("write", SYSTEM.ADR(cWrite));
    GetSym("lseek", SYSTEM.ADR(cSeek));
    GetSym("stat$INODE64", SYSTEM.ADR(cStat));
    GetSym("rename", SYSTEM.ADR(cRename));
    GetSym("unlink", SYSTEM.ADR(cUnlink));
    GetSym("rmdir", SYSTEM.ADR(cRmdir));
    GetSym("mkdir", SYSTEM.ADR(cMkdir));
    GetSym("chmod", SYSTEM.ADR(cChmod));
    GetSym("ftruncate", SYSTEM.ADR(cTruncate));
    GetSym("utimes", SYSTEM.ADR(cUtimes));
    GetSym("getcwd", SYSTEM.ADR(getcwd));
    GetSym("gettimeofday", SYSTEM.ADR(cGetTimeOfDay));
    GetSym("clock_gettime", SYSTEM.ADR(cClockGetTime))
END init;


PROCEDURE dllentry* (hinstDLL, fdwReason, lpvReserved: INTEGER): INTEGER;
    RETURN 0
END dllentry;


PROCEDURE sofinit*;
BEGIN
    IF fini # NIL THEN
        fini
    END
END sofinit;


PROCEDURE SetFini* (ProcFini: SOFINI);
BEGIN
    fini := ProcFini
END SetFini;


PROCEDURE SetTrap* (_trap: Trap);
BEGIN
    trap := _trap
END SetTrap;


END API.
