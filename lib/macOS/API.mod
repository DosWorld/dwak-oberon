(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.
*)

MODULE API;

(* The runtime never calls into libSystem - it only names it (MACHO.mod's
   empty chained-fixups trick), because dyld refuses a binary that names no
   dependency at all. Everything real goes through raw BSD/XNU syscalls:
   the syscall trampoline below OR's in the 0x2000000 Unix class bit and
   turns the carry-flag error convention into a Linux-style negative
   return, so callers can use the same "< 0 is an error" idiom the rest of
   this compiler's runtimes already use. *)

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

    heapTop, heapEnd: INTEGER;

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
        n := 0;
        SYSTEM.GET(p + n, c);
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


(* A bump allocator over anonymous pages: the runtime never frees memory
   back to the kernel (matching every other target here, whose _DISPOSE is
   a no-op or a pooled free list at best), so mmap is only ever asked to
   grow the arena. *)
PROCEDURE grow (need: INTEGER): BOOLEAN;
CONST
    CHUNK = 4 * 1024 * 1024;
VAR
    size, p: INTEGER;
    ok: BOOLEAN;

BEGIN
    size := need;
    IF size < CHUNK THEN
        size := CHUNK
    END;
    IF size MOD 1000H # 0 THEN
        INC(size, 1000H - size MOD 1000H)
    END;

    p := syscall(SYS_mmap, 0, size, PROT_READ + PROT_WRITE, MAP_PRIVATE + MAP_ANON, -1, 0);
    ok := p >= 0;
    IF ok THEN
        heapTop := p;
        heapEnd := p + size
    END

    RETURN ok
END grow;


PROCEDURE _NEW* (size: INTEGER): INTEGER;
VAR
    res, ptr, words, need: INTEGER;
    ok: BOOLEAN;

BEGIN
    need := size;
    IF need MOD 8 # 0 THEN
        INC(need, 8 - need MOD 8)
    END;

    IF heapTop + need > heapEnd THEN
        ok := grow(need)
    ELSE
        ok := TRUE
    END;

    IF ok THEN
        res := heapTop;
        INC(heapTop, need);

        ptr := res;
        words := size DIV SYSTEM.SIZE(INTEGER);
        WHILE words > 0 DO
            SYSTEM.PUT(ptr, 0);
            INC(ptr, SYSTEM.SIZE(INTEGER));
            DEC(words)
        END
    ELSE
        res := 0
    END

    RETURN res
END _NEW;


PROCEDURE _DISPOSE* (p: INTEGER): INTEGER;
    RETURN 0
END _DISPOSE;


PROCEDURE exit* (code: INTEGER);
VAR
    res: INTEGER;
BEGIN
    res := syscall(SYS_exit, code, 0, 0, 0, 0, 0)
END exit;


PROCEDURE exit_thread* (code: INTEGER);
BEGIN
    exit(code)
END exit_thread;


PROCEDURE init* (sp, code: INTEGER);
BEGIN
    fini := NIL;
    trap := NIL;
    (* AMD64 passes a temporary {argc, argv, envp} tuple from LC_MAIN. *)
    SYSTEM.GET(sp, MainArgc);
    SYSTEM.GET(sp + 8, MainArgv);
    SYSTEM.GET(sp + 16, MainEnvp);
    heapTop := 0;
    heapEnd := 0
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
