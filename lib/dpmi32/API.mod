(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    DPMI32 runtime API. No Win32 DLL imports. Memory comes from one large
    flat 32-bit DPMI block (int 31h AX=0501h), sized from the free memory
    the host reports (AX=0500h); inside it a heap is used:
    blocks are linked in one list by linear offset, allocation takes the
    beginning of a free block and free merges with both neighbours. The HX
    host releases the whole block when the process terminates. Process exit
    goes through DOS int 21h.

    There is exactly one such block per process, and it belongs to the
    module the process was started from. A DLL loaded into that process
    takes no memory of its own: at attach it resolves the EXE's exported
    _new/_dispose and routes every allocation through them, so a record
    allocated inside a DLL is freed by the EXE's allocator and the other way
    round. A DLL that cannot find them refuses to load rather than run on a
    heap of its own.
*)

MODULE API;

IMPORT SYSTEM, DOS;


CONST

    OS* = "DPMI32";
    eol* = 0DX + 0AX;
    BIT_DEPTH* = (ORD(LSL(1, 31) > 0) + 1) * 32;

    FREE = 0;
    USED = 1;
    HDR = 16;               (* block header: prev, next, size, status *)
    MINSIZE = 8;            (* smallest payload a split-off block may have *)

    (* Last resort only, for a host that will not report its free memory:
       the ceiling to probe downwards from. No size is ever assumed. *)
    PROBE = 2000000H;

    (* Memory left to the loader. A module is mapped by the loader out of the
       same free memory this block is taken from, and a module that is loaded
       at run time is mapped while the program that asked for it is already
       running - so a program that takes every last byte here has taken away
       its own ability to load a DLL. The loader asks for the image in one
       piece and gets nothing if what is left is smaller, which is what makes
       this a reserve rather than just prudence. Taking a block never splits
       the free memory, so what is held back stays contiguous. *)
    RESERVE = 400000H;      (* 4 MB: a DLL image, with room to spare *)

    (* The loader enters a DLL once per process and once more when the module
       is released, so the entry point has to tell the two apart. *)
    DLL_PROCESS_DETACH = 0;
    DLL_PROCESS_ATTACH = 1;
    DLL_THREAD_ATTACH  = 2;
    DLL_THREAD_DETACH  = 3;


TYPE

    DLL_ENTRY* = PROCEDURE (hinstDLL, fdwReason, lpvReserved: INTEGER);

    Trap = PROCEDURE (ModNum, ModNamePtr, line, error: INTEGER);

    Alloc = PROCEDURE (size: INTEGER): INTEGER;


VAR

    base*: INTEGER;
    trap*: Trap;

    process_detach,
    thread_detach,
    thread_attach: DLL_ENTRY;

    heapBase: INTEGER;      (* start of the single DPMI chunk *)
    heapSize: INTEGER;      (* its size in bytes *)
    heapHandle: INTEGER;    (* DPMI memory handle *)

    (* The block the next search for a free block starts from. Searching from
       heapBase instead is what made allocation quadratic; LocalNew has the
       whole of it. *)
    roving: INTEGER;

    (* A DLL owns nothing. The loader enters one with the EXE already holding
       the process's one large DPMI block, so the only heap a DLL may use is
       the EXE's; these two are its _new and _dispose, resolved off the main
       module before the DLL's first allocation and NIL in the EXE itself,
       where the block below is what they stand for. *)
    hostNew,
    hostDispose: Alloc;


PROCEDURE [stdcall-] DosExit (code: INTEGER);
BEGIN
    SYSTEM.CODE(
    08BH, 045H, 008H,    (* mov  eax, [ebp+8] *)
    0B4H, 04CH,          (* mov  ah, 4Ch *)
    0CDH, 021H,          (* int  21h *)
    0C9H,                 (* leave *)
    0C3H                  (* ret *)
    )
END DosExit;


(* The chunk is a single DPMI block. It must not be released by the client:
   the HX host frees every block a client owns when the client terminates
   (HDPMI I31MEM.ASM, _freeclientmemory, called from _exitclient_pm). Calling
   int 31h AX=0502h on it faults in the host (the block borders the image). *)
PROCEDURE FreeHeap;
BEGIN
    heapHandle := 0
END FreeHeap;


PROCEDURE exit* (code: INTEGER);
BEGIN
    FreeHeap;
    DosExit(code)
END exit;


PROCEDURE exit_thread* (code: INTEGER);
BEGIN
    FreeHeap;
    DosExit(code)
END exit_thread;


PROCEDURE GetHdr (p, off: INTEGER): INTEGER;
VAR
    x: INTEGER;

BEGIN
    SYSTEM.GET(p + off, x);
    RETURN x
END GetHdr;


PROCEDURE SetHdr (p, off, v: INTEGER);
BEGIN
    SYSTEM.PUT(p + off, v)
END SetHdr;


(* Take one large DPMI block and work inside it. The size is whatever the
   host says it can still give (int 31h AX=0500h), never a figure assumed
   here. Should the host refuse that exact size its bookkeeping must have
   moved between the two calls, so ask for half and keep halving; 0501h
   rejects a size of 0, which ends the loop.

   A DLL asks the host for nothing: whatever is still free by the time it
   runs is what the EXE could not take, and a heap built on it would be a
   second, unreachable one. AttachHeap has already pointed _new at the EXE's,
   so this leaves with the block still unclaimed, as it found it.

   Called from init and again before the first allocation, whichever comes
   first, and it is the second caller that usually matters: a DLL imported at
   link time is entered - and allocates its type table - while the EXE is
   still being loaded, so the EXE's init has not run yet and the block has to
   come up on demand. The heapBase test makes the call idempotent. *)
PROCEDURE SetupHeap;
VAR
    addr, handle, cf, err, size: INTEGER;

BEGIN
    IF (hostNew = NIL) & (heapBase = 0) THEN
        size := DOS.DpmiMaxFree();
        IF size <= 0 THEN
            size := PROBE       (* the host would not say: probe downwards *)
        ELSIF size > RESERVE * 2 THEN
            DEC(size, RESERVE)
        ELSE
            size := size DIV 2  (* too little to hold anything back *)
        END;

        WHILE (heapBase = 0) & (size > 0) DO
            DOS.DpmiAlloc(size, addr, handle, cf, err);
            IF cf = 0 THEN
                heapBase := addr;
                heapSize := size;
                heapHandle := handle
            ELSE
                size := size DIV 2
            END
        END;

        IF heapSize > HDR + MINSIZE THEN    (* one free block over the chunk *)
            SetHdr(heapBase, 0, 0);
            SetHdr(heapBase, 4, 0);
            SetHdr(heapBase, 8, heapSize - HDR);
            SetHdr(heapBase, 12, FREE);
            roving := heapBase
        ELSE
            heapBase := 0;
            heapSize := 0;
            roving := 0
        END
    END
END SetupHeap;


PROCEDURE init* (reserved, code: INTEGER);
BEGIN
    process_detach := NIL;
    thread_detach  := NIL;
    thread_attach  := NIL;
    trap := NIL;
    base := code - 1000H;    (* SectionAlignment *)

    SetupHeap
END init;


(* The block this module owns: the process heap in the EXE, all zeroes in a
   DLL, which owns none.

   handle is reported for information and must not be handed back to
   DOS.DpmiFree: the host frees every block a client owns when the client
   terminates, and asking it to free this one faults inside the host, because
   the block borders the image (FreeHeap above, and _freeclientmemory in
   HDPMI\I31MEM.ASM). It is a number to print, not a handle to close. *)
PROCEDURE HeapInfo* (VAR base, size, handle: INTEGER);
BEGIN
    base := heapBase; size := heapSize; handle := heapHandle
END HeapInfo;


(* NEW must hand back zeroed memory: the Windows runtime allocates with
   HEAP_ZERO_MEMORY, so the compiler and its libraries are written against
   that promise and leave record fields to be filled in later. The DPMI
   block, unlike a fresh Windows heap, comes back from the host with the
   previous client's bytes still in it, so every block is cleared here. *)
PROCEDURE Zero (adr, len: INTEGER);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE i + 4 <= len DO
        SYSTEM.PUT(adr + i, 0); INC(i, 4)
    END;
    WHILE i < len DO
        SYSTEM.PUT(adr + i, 0X); INC(i)
    END
END Zero;


PROCEDURE HPrev (h: INTEGER): INTEGER;   RETURN GetHdr(h, 0) END HPrev;
PROCEDURE HNext (h: INTEGER): INTEGER;   RETURN GetHdr(h, 4) END HNext;
PROCEDURE HSize (h: INTEGER): INTEGER;   RETURN GetHdr(h, 8) END HSize;
PROCEDURE HStat (h: INTEGER): INTEGER;   RETURN GetHdr(h, 12) END HStat;


(* Whether h is the header of a block in the list at all, whatever its status:
   the neighbours it names have to point back at it. A block that is handed out
   stays a header until it is disposed, and disposing merges it into a free
   neighbour - after which the address lies inside a payload, where the words
   are whatever the client left there. So an address that was a header once is
   never trusted: it is checked before anything is searched from it.

   The bounds are written as `h <= heapBase + heapSize - HDR` rather than as
   `h + HDR <= heapBase + heapSize`: the second form wraps for a pointer near
   the top of INTEGER, and a pointer that is out of range is exactly what this
   test exists to catch - so it would pass the check it is meant to fail and
   then read a header through the wrap. Every other bound here is a comparison
   against a value the heap itself produced, so nothing else can wrap. *)
PROCEDURE IsHdr (h: INTEGER): BOOLEAN;
VAR
    ok: BOOLEAN;
    n: INTEGER;

BEGIN
    ok := (heapBase # 0) & (h >= heapBase) & (h <= heapBase + heapSize - HDR);

    IF ok THEN
        n := HNext(h);
        ok := (n = 0) OR ((n > h) & (n <= heapBase + heapSize - HDR) & (HPrev(n) = h))
    END;

    IF ok THEN
        n := HPrev(h);
        ok := (n = 0) OR ((n >= heapBase) & (n < h) & (HNext(n) = h))
    END;

    RETURN ok
END IsHdr;


(* First fit over the block list. The used part is taken from the BEGINNING
   of a free block, so the remainder stays right after it.

   The search starts at the roving pointer and not at heapBase. A search from
   the base walks past every block the heap has ever handed out, so the k-th
   live block costs the k-th allocation k steps and the program pays for the
   whole list again on every allocation - quadratic in what it holds. The
   front end of the compiler holds a hundred thousand blocks when it starts
   generating code, and generation allocates its way through all of them, so
   that walk is minutes of work. The roving pointer is left on the block an
   allocation came from, which makes the next search find the neighbouring free
   block within a step or two.

   A search that reaches the end of the heap without finding a block big enough
   wraps once to heapBase and runs up to the pointer it started from. That
   wrapped pass costs what a search from the base always cost, and it is what
   keeps a fragmented heap honest: no allocation is refused while a free block
   of the right size exists anywhere, which is what a roving pointer alone
   would risk. It is paid for only when it is needed. *)
PROCEDURE LocalNew (size: INTEGER): INTEGER;
VAR
    need, b, r, rest, res, start, stop: INTEGER;

BEGIN
    IF heapBase = 0 THEN
        SetupHeap          (* a DLL reached us before this module's init did *)
    END;

    res := 0;
    (* The size is bounded by the heap before it is rounded up: (size + 7)
       would wrap for a size near the top of INTEGER, and the rounded figure
       would then be small enough to hand out a block far smaller than the
       request. Nothing can be allocated that does not fit in the heap, so a
       size beyond it is not a request to serve. *)
    IF (size >= 0) & (size <= heapSize) THEN
        need := (size + 7) DIV 8 * 8;
        IF need < 8 THEN need := 8 END;

        start := roving;
        IF ~IsHdr(start) THEN
            start := heapBase   (* nothing roving yet, or merged away since *)
        END;

        b := start;
        stop := 0;              (* 0: the end of the heap is where this ends *)
        WHILE (b # 0) & (b # stop) & (res = 0) DO
            IF (HStat(b) = FREE) & (HSize(b) >= need) THEN
                rest := HSize(b) - need;
                IF rest >= MINSIZE + HDR THEN
                    r := b + HDR + need;
                    SetHdr(r, 0, b);
                    SetHdr(r, 4, HNext(b));
                    SetHdr(r, 8, rest - HDR);
                    SetHdr(r, 12, FREE);
                    IF HNext(b) # 0 THEN SetHdr(HNext(b), 0, r) END;
                    SetHdr(b, 4, r);
                    SetHdr(b, 8, need)
                END;
                SetHdr(b, 12, USED);
                res := b + HDR;
                Zero(res, need)
            ELSE
                b := HNext(b);
                IF (b = 0) & (start # heapBase) & (stop = 0) THEN
                    b := heapBase;      (* the one wrapped pass *)
                    stop := start
                END
            END
        END;

        IF res # 0 THEN
            roving := b     (* the next search starts where this one stopped *)
        END
    END;
    RETURN res
END LocalNew;


(* The allocator the whole process uses. In the EXE hostNew is NIL and this is
   the block the EXE took; in a DLL it is the EXE's own _new, which is what
   makes one heap serve both. *)
PROCEDURE _NEW* (size: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF hostNew # NIL THEN
        res := hostNew(size)
    ELSE
        res := LocalNew(size)
    END;

    RETURN res
END _NEW;


(* Whether h is the header of a block this heap has handed out. A DISPOSE is
   given whatever the program passes it, and the merge below writes block
   headers where the pointer says the neighbours are - so a pointer from
   another heap, one into the middle of a record, or one already merged away
   would corrupt the list silently. IsHdr makes the pointer name a block; the
   status makes that block one that was handed out and not given back. *)
PROCEDURE IsBlock (h: INTEGER): BOOLEAN;
BEGIN
    RETURN IsHdr(h) & (HStat(h) = USED)
END IsBlock;


(* A pointer that is not the start of an allocated block is not freed: the
   block it names cannot be found, and freeing the address anyway would take
   the headers around it with it. The block stays as it is, so this is a leak
   rather than a corruption - the caller handed over something that was never
   handed out. *)
PROCEDURE LocalDispose (p: INTEGER): INTEGER;
VAR
    h, n, pv: INTEGER;

BEGIN
    IF (p # 0) & IsBlock(p - HDR) THEN
        h := p - HDR;
        IF HStat(h) # FREE THEN
            SetHdr(h, 12, FREE);

            (* merge with the next block *)
            n := HNext(h);
            IF (n # 0) & (HStat(n) = FREE) THEN
                SetHdr(h, 8, HSize(h) + HDR + HSize(n));
                SetHdr(h, 4, HNext(n));
                IF HNext(n) # 0 THEN SetHdr(HNext(n), 0, h) END
            END;

            (* merge with the previous block *)
            pv := HPrev(h);
            IF (pv # 0) & (HStat(pv) = FREE) THEN
                SetHdr(pv, 8, HSize(pv) + HDR + HSize(h));
                SetHdr(pv, 4, HNext(h));
                IF HNext(h) # 0 THEN SetHdr(HNext(h), 0, pv) END
            END
        END
    END;
    RETURN 0
END LocalDispose;


PROCEDURE _DISPOSE* (p: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF hostDispose # NIL THEN
        res := hostDispose(p)
    ELSE
        res := LocalDispose(p)
    END;

    RETURN res
END _DISPOSE;


PROCEDURE DebugMsg* (lpText, lpCaption: INTEGER);
VAR
    buf: ARRAY 512 OF CHAR;
    c: CHAR;
    n: INTEGER;

BEGIN
    n := 0;
    SYSTEM.GET(lpText, c);
    WHILE (n < 511) & (c # 0X) DO
        buf[n] := c; INC(n); SYSTEM.GET(lpText + n, c)
    END;
    buf[n] := 0X;
    DOS.WrBuf(SYSTEM.ADR(buf[0]), n);
    DOS.PutChar(13); DOS.PutChar(10)
END DebugMsg;


(* Take the EXE's allocator. The loader resolves a DLL's own imports before it
   enters it, but an EXE cannot be named in an import descriptor - which EXE
   will load a given DLL is not known when the DLL is built - so the two
   procedures are asked for by name off the main module instead, through the
   loader's own AX=4B82h/AX=4B81h. That happens here, at attach, which is
   before the first allocation this module makes.

   A DLL that cannot find them has no memory it could legitimately use, so it
   refuses the load: the entry point returns 0, the loader reports the failure
   and the EXE that asked for the module gets a null handle back. That 0 is
   handed straight back by the code generator - I386.prolog compares the entry
   point's answer against 0 and against 1 instead of testing it - so it has to
   mean a failed attach and nothing else. *)
PROCEDURE AttachHeap (): BOOLEAN;
VAR
    h, adr: INTEGER;
    ok: BOOLEAN;
    msg: ARRAY 64 OF CHAR;

BEGIN
    h := DOS.MainHandle();
    ok := h # 0;

    IF ok THEN
        adr := DOS.GetProc(h, "new");
        ok := adr # 0;
        IF ok THEN
            hostNew := SYSTEM.VAL(Alloc, adr)
        END
    END;

    IF ok THEN
        adr := DOS.GetProc(h, "dispose");
        ok := adr # 0;
        IF ok THEN
            hostDispose := SYSTEM.VAL(Alloc, adr)
        END
    END;

    IF ~ok THEN
        msg := "dpmi32pe: DLL needs an EXE that exports new/dispose";
        DebugMsg(SYSTEM.ADR(msg[0]), 0)
    END;

    RETURN ok
END AttachHeap;


(* The loader calls this before the module body on load and again on release,
   with reason 0. What it answers is a reason, not a yes or a no:

     1 - this is the attach, run the module bodies;
     2 - the loader wants something else (release, thread attach/detach) and
         the load stands, but the bodies must not run a second time;
     0 - the attach failed and the load has to be refused.

   The three are distinct because 0 is the only way a DLL can say no, and
   because a release that answered 0 would refuse a load that has already
   happened. *)
PROCEDURE dllentry* (hinstDLL, fdwReason, lpvReserved: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := 2;

    CASE fdwReason OF
    |DLL_PROCESS_ATTACH:
        (* In an EXE AttachHeap is never reached: the EXE is the main module,
           it owns the block, and there is nothing to attach to. In a DLL it
           is the whole point of the entry point - no allocator, no load, and
           res stays 0. *)
        IF AttachHeap() THEN res := 1 ELSE res := 0 END
    |DLL_THREAD_ATTACH:
        IF thread_attach # NIL THEN
            thread_attach(hinstDLL, fdwReason, lpvReserved)
        END
    |DLL_THREAD_DETACH:
        IF thread_detach # NIL THEN
            thread_detach(hinstDLL, fdwReason, lpvReserved)
        END
    |DLL_PROCESS_DETACH:
        IF process_detach # NIL THEN
            process_detach(hinstDLL, fdwReason, lpvReserved)
        END
    ELSE
    END;

    RETURN res
END dllentry;


PROCEDURE sofinit*;
END sofinit;


PROCEDURE SetDll* (_process_detach, _thread_detach, _thread_attach: DLL_ENTRY);
BEGIN
    process_detach := _process_detach;
    thread_detach  := _thread_detach;
    thread_attach  := _thread_attach
END SetDll;


PROCEDURE SetTrap* (_trap: Trap);
BEGIN
    trap := _trap
END SetTrap;


END API.
