(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    HXDOS low-level DOS layer. No Win32 DLL imports.

    A protected mode program cannot execute a real mode interrupt itself: int
    21h belongs to the real mode DOS and the BIOS interrupts to the real mode
    ROM. What a DPMI host offers instead is the call that runs one on the
    client's behalf - int 31h AX=0300h, "simulate real mode interrupt" - and
    that is how every interrupt this layer issues is issued, whatever its
    number. The number travels in BL, so DOS (int 21h), the BIOS and anything
    else a program may need are one call with one argument, which is why
    DOS.Intr* takes the interrupt number first and the registers second.

    That call needs a real mode call structure - the register set the service
    is entered with - and the structure, like everything a service is pointed
    at, can only live below 1 MB: a real mode address is a segment and an
    offset. Both therefore live in one 64 KB DOS block, allocated once at load
    time. A path is copied into it by LowName and file data goes through its
    transfer buffer, which is what the wrappers below hide from their callers;
    a caller that reaches for DOS.Intr* itself has to do the same and says so
    by putting the block's segment in the DS field of the Registers record.

    DPMI is not a real mode service, so its own calls are made directly, by
    Int31, the one interrupt this layer still spells as an instruction. Three
    things that look like DOS services are DPMI's and cannot be reflected
    either: the memory functions of int 21h (see AllocDOS), the loader API of
    the extender (AX=4B00h, AX=4B80h..4B86h, answered by DPMILD32 in protected
    mode), and AH=4Ch, which terminates the client only because the host
    intercepts it - reflected, it reaches the real mode DOS, which terminates
    the extender's own stub and leaves this program running (see Exit).

    Note: every name this layer hands to DOS goes through an LFN function -
    open and create AH=716Ch, delete AH=7141h, attributes AH=7143h, mkdir and
    rmdir AH=7139h/713Ah, the current directory AH=7147h - because the 8.3
    forms do not cover every name a caller has. Measured under DOSBox-X: AH=41h
    answers error 2, "file not found", for a long name that AH=7141h deletes,
    while both forms delete a short name, so preferring the LFN call costs
    nothing. The 8.3 forms are not broken here - AH=4300h was measured to
    answer for a long name too - but that is the host translating the name for
    them, and the LFN subfunctions are the ones a host is obliged to provide
    (section 2 of doc/hxdos.txt has the measurements).

    General registers are 32-bit (INTEGER); the low word is the 16-bit
    register (AX, BX, ...). Segment/flag fields are WORD, and the register
    values a real mode service returns are 16-bit, so the high words a caller
    reads back after DOS.Intr* are zero.

    Text output has two layers. DOS.WrBuf goes through the DOS console and
    therefore honours output redirection, but DOS owns the attribute of every
    cell it writes: there is no DOS call that sets the colour of subsequent
    output. When a program selects a colour, the character attribute is
    therefore not negotiable any more and DOS.WrAttr writes the characters
    into text video memory itself, in the requested attribute. Both layers
    keep the cursor in the BIOS data area, which is what DOS reads before
    every write of its own.
*)

MODULE DOS;

IMPORT SYSTEM;


CONST

    (* BIOS data area, addressable because an HX client runs flat. *)
    BDA_COLS = 44AH;                    (* number of text columns *)
    BDA_ROWS = 484H;                    (* number of text rows, minus one *)
    BDA_CURS = 450H;                    (* cursor position on page 0 *)
    VID      = 0B8000H;                 (* text page 0 of the colour adapter *)
    SPACE    = 20H;
    DEF_ATTR = 7;                       (* light grey on black *)

    (* The DOS block: 64 KB, the largest single block DOS hands out, and the
       only memory a real mode service can be pointed at. Everything a
       reflected call needs that DOS has to read or write lives here - the call
       structure, one path, and the buffer file data passes through - and the
       rest of the block is the stack the reflected call runs on.

       0000h  the real mode call structure          50 bytes
       0040h  the path buffer                     512 bytes
       0240h  the transfer buffer               48 KB
       0C240h .. 0FFFEh  the real mode stack        ~15 KB *)
    LOW_BLOCK = 1000H;                  (* the block, in paragraphs *)
    LOW_RMCS = 0;                       (* segment offset into the block *)
    LOW_NAME = 40H;
    LOW_NAME_LEN = 200H;
    LOW_DATA = 240H;
    LOW_DATA_LEN = 0C000H;
    LOW_SP = 0FFFEH;                    (* where that stack starts, growing down *)

    (* The program segment prefix DOS builds for every program: its command
       tail is a length byte and then that many characters, with no
       terminator of its own. *)
    PSP_TAIL = 80H;

    (* The fields of the real mode call structure, at the offsets DPMI 0.9
       gives them: the 32-bit registers in the order EDI, ESI, EBP, a reserved
       dword, EBX, EDX, ECX, EAX, then the 16-bit flags, segment registers and
       the CS:IP and SS:SP the service is entered and left with. *)
    RM_FLAGS_IN = 202H;                 (* interrupt enable, one trace flag *)


TYPE

    WORD = WCHAR;

    Registers* = RECORD
        EAX*, EBX*, ECX*, EDX*, ESI*, EDI*, EBP*, ESP*: INTEGER;
        Flags*, ES*, DS*, FS*, GS*, CS*, SS*: WORD
    END;

    (* The same register set in the order the host reads it, which is why it
       is a record of its own rather than a reinterpretation of Registers. *)
    Call = RECORD
        EDI, ESI, EBP, res: INTEGER;
        EBX, EDX, ECX, EAX: INTEGER;
        Flags, ES, DS, FS, GS, IP, CS, SP, SS: WORD
    END;

    CallP = POINTER TO Call;


VAR

    attr:   INTEGER;                    (* attribute chosen by SetAttr *)
    attrOn: BOOLEAN;                    (* set once a colour was chosen *)

    lowSeg: INTEGER;                    (* the DOS block, as DOS names it *)
    lowLin: INTEGER;                    (* the same block, as this program does *)
    rm:     CallP;                      (* the call structure inside it, at LOW_RMCS *)


(* Execute int 31h with the registers from the record at rcadr. This is the
   direct DPMI call, the one interrupt this layer still spells as an
   instruction: the number is a constant of the instruction, so nothing has to
   choose it at run time.

   0CDH, 031H is the whole of it. What surrounds it is the register transfer:
   the six dwords a DPMI service takes are loaded from the record before the
   interrupt and stored back after it, and the four segment registers the call
   must not disturb are parked in the 16 bytes the frame reserves with
   `sub esp,16` - [ebp-48] and down - which are clear of the pushad area right
   above them. Saving them in that area instead would hand the caller three of
   its registers back with a segment selector in the low half, because pushad
   puts eax, ecx and edx in its top twelve bytes. The spare bytes are addressed
   off ebp rather than esp because the pushes after the interrupt move esp.

   EBP and ESP are the client's own and are not loaded or stored; the flags are
   captured after the interrupt into the record's Flags field, where the carry
   bit is how a DPMI service reports an error. *)
PROCEDURE [stdcall] Int31 (rcadr: INTEGER);
BEGIN
    SYSTEM.CODE(
    060H,                               (* pushad *)
    083H, 0ECH, 010H,                   (* sub esp,16 *)
    08CH, 0C0H, 066H, 089H, 045H, 0D0H, (* mov ax,es; mov [ebp-48],ax *)
    08CH, 0D8H, 066H, 089H, 045H, 0D2H, (* mov ax,ds; mov [ebp-46],ax *)
    08CH, 0E0H, 066H, 089H, 045H, 0D4H, (* mov ax,fs; mov [ebp-44],ax *)
    08CH, 0E8H, 066H, 089H, 045H, 0D6H, (* mov ax,gs; mov [ebp-42],ax *)
    08BH, 045H, 008H,                   (* mov eax,[ebp+8]  rcadr *)
    08BH, 058H, 004H,                   (* mov ebx,[eax+4]  EBX *)
    08BH, 048H, 008H,                   (* mov ecx,[eax+8]  ECX *)
    08BH, 050H, 00CH,                   (* mov edx,[eax+12] EDX *)
    08BH, 070H, 010H,                   (* mov esi,[eax+16] ESI *)
    08BH, 078H, 014H,                   (* mov edi,[eax+20] EDI *)
    08BH, 000H,                         (* mov eax,[eax+0]  EAX *)
    0CDH, 031H,                         (* int 31h *)
    09CH,                               (* pushfd; the carry is the error *)
    050H, 053H, 051H, 052H, 056H, 057H, (* push eax,ebx,ecx,edx,esi,edi *)
    08BH, 05DH, 008H,                   (* mov ebx,[ebp+8]  rcadr *)
    05FH, 089H, 07BH, 014H,             (* pop edi; mov [ebx+20],edi *)
    05EH, 089H, 073H, 010H,             (* pop esi; mov [ebx+16],esi *)
    05AH, 089H, 053H, 00CH,             (* pop edx; mov [ebx+12],edx *)
    059H, 089H, 04BH, 008H,             (* pop ecx; mov [ebx+8],ecx *)
    058H, 089H, 043H, 004H,             (* pop eax; mov [ebx+4],eax *)
    058H, 089H, 003H,                   (* pop eax; mov [ebx+0],eax *)
    058H, 066H, 089H, 043H, 020H,       (* pop eax; mov [ebx+32],ax (Flags) *)
    066H, 08BH, 045H, 0D0H, 08EH, 0C0H, (* mov ax,[ebp-48]; mov es,ax *)
    066H, 08BH, 045H, 0D2H, 08EH, 0D8H, (* mov ax,[ebp-46]; mov ds,ax *)
    066H, 08BH, 045H, 0D4H, 08EH, 0E0H, (* mov ax,[ebp-44]; mov fs,ax *)
    066H, 08BH, 045H, 0D6H, 08EH, 0E8H, (* mov ax,[ebp-42]; mov gs,ax *)
    083H, 0C4H, 010H,                   (* add esp,16 *)
    061H                                (* popad *)
    )
END Int31;


(* The one entry point for every interrupt this runtime issues: DOS is int 21h
   and the BIOS is int 10h, and both are the same call with a different number.

   A protected mode program cannot execute a real mode interrupt itself, so the
   host is asked to simulate it (int 31h AX=0300h). The number travels in BL
   and the host enters the real mode handler with the registers of the call
   structure at ES:EDI; this procedure fills that structure from the record,
   makes the call and copies the result back.

   A real mode interrupt is 16-bit throughout, so what goes in is taken modulo
   10000H and what comes back is masked to 16 bits: the high words a caller
   reads are zeros, which is what the service left in them.
   The structure's DS and ES are the block's segment when the caller leaves
   them zero, so a caller that puts an offset in the block (LOW_NAME, or any
   address inside it) in ESI, EDI or EDX does not also have to say which
   segment it is in. FS, GS and the CS:IP a real mode return would use are
   emptied, the call runs on the block's own stack, and it is entered with the
   flags of RM_FLAGS_IN - the flags it leaves behind carry the error, as they
   do after any DOS call. *)
PROCEDURE Intr* (int: INTEGER; VAR r: Registers);
VAR
    q: Registers;

BEGIN
    rm.EDI := r.EDI MOD 10000H;
    rm.ESI := r.ESI MOD 10000H;
    rm.EBP := 0;
    rm.res := 0;
    rm.EBX := r.EBX MOD 10000H;
    rm.EDX := r.EDX MOD 10000H;
    rm.ECX := r.ECX MOD 10000H;
    rm.EAX := r.EAX MOD 10000H;
    rm.Flags := WCHR(RM_FLAGS_IN);
    IF ORD(r.ES) = 0 THEN rm.ES := WCHR(lowSeg) ELSE rm.ES := r.ES END;
    IF ORD(r.DS) = 0 THEN rm.DS := WCHR(lowSeg) ELSE rm.DS := r.DS END;
    rm.FS := WCHR(0); rm.GS := WCHR(0);
    rm.IP := WCHR(0); rm.CS := WCHR(0);
    rm.SP := WCHR(LOW_SP); rm.SS := WCHR(lowSeg);

    (* Only the six general registers are read back out of q, so only they are
       written into it: Int31 loads EAX, EBX, ECX, EDX, ESI and EDI and leaves
       the rest of the record alone. *)
    q.EAX := 300H;                      (* simulate real mode interrupt *)
    q.EBX := int MOD 100H;              (* BL = the number *)
    q.ECX := 0;
    q.EDX := 0;
    q.ESI := 0;
    q.EDI := lowLin + LOW_RMCS;         (* ES:EDI = the call structure *)
    Int31(SYSTEM.ADR(q));

    r.EAX := rm.EAX MOD 10000H;
    r.EBX := rm.EBX MOD 10000H;
    r.ECX := rm.ECX MOD 10000H;
    r.EDX := rm.EDX MOD 10000H;
    r.ESI := rm.ESI MOD 10000H;
    r.EDI := rm.EDI MOD 10000H;
    r.Flags := rm.Flags;
    r.ES := rm.ES; r.DS := rm.DS;
    r.FS := rm.FS; r.GS := rm.GS
END Intr;


(* Copy the NUL terminated string at adr into the block's path buffer, so that
   the wrappers below can hand a service the offset LOW_NAME in the block's
   segment. A string too long for the buffer is cut and the service then
   refuses the truncated name, the way it refuses any name it cannot find. *)
PROCEDURE LowName (adr: INTEGER);
VAR
    i: INTEGER;
    c: CHAR;

BEGIN
    i := 0;
    SYSTEM.GET(adr + i, c);
    WHILE (c # 0X) & (i < LOW_NAME_LEN - 1) DO
        SYSTEM.PUT(lowLin + LOW_NAME + i, c);
        INC(i);
        SYSTEM.GET(adr + i, c)
    END;
    c := 0X;
    SYSTEM.PUT(lowLin + LOW_NAME + i, c)
END LowName;


(* Execute int 31h AX=0500h with EDI addressing the caller's 48-byte buffer.
   The host writes the record through ES:EDI, so ES is pointed at the flat
   data selector for the call and put back afterwards. The saved ES lives in
   the scratch the frame reserves, not in the pushad area. *)
PROCEDURE [stdcall] Exec31Buf (bufadr: INTEGER);
BEGIN
    SYSTEM.CODE(
    060H,                               (* pushad *)
    083H, 0ECH, 010H,                   (* sub esp,16 *)
    08CH, 0C0H, 066H, 089H, 004H, 024H, (* mov ax,es; mov [esp],ax *)
    08CH, 0D8H, 08EH, 0C0H,             (* mov ax,ds; mov es,ax *)
    08BH, 045H, 008H,                   (* mov eax,[ebp+8] bufadr *)
    089H, 0C7H,                         (* mov edi,eax *)
    031H, 0C0H,                         (* xor eax,eax *)
    031H, 0DBH,                         (* xor ebx,ebx *)
    031H, 0C9H,                         (* xor ecx,ecx *)
    031H, 0D2H,                         (* xor edx,edx *)
    031H, 0F6H,                         (* xor esi,esi *)
    066H, 0B8H, 000H, 005H,             (* mov ax,0500h *)
    0CDH, 031H,                         (* int 31h *)
    066H, 08BH, 004H, 024H, 08EH, 0C0H, (* mov ax,[esp]; mov es,ax *)
    083H, 0C4H, 010H,                   (* add esp,16 *)
    061H                                (* popad *)
    )
END Exec31Buf;


PROCEDURE Zero (VAR r: Registers);
BEGIN
    r.EAX := 0; r.EBX := 0; r.ECX := 0; r.EDX := 0;
    r.ESI := 0; r.EDI := 0; r.EBP := 0; r.ESP := 0;
    r.Flags := WCHR(0); r.ES := WCHR(0); r.DS := WCHR(0);
    r.FS := WCHR(0); r.GS := WCHR(0); r.CS := WCHR(0); r.SS := WCHR(0)
END Zero;


(* DPMI 0.9: allocate DOS memory block (int 31h AX=0100h).
   Returns real-mode segment in seg and selector in sel; on failure seg and
   sel are 0 and err carries the DPMI error code (DOS error 8, "insufficient
   memory", is the usual one). *)
PROCEDURE AllocDOS9* (paras: INTEGER; VAR seg, sel, err: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 100H;
    r.EBX := paras;
    Int31(SYSTEM.ADR(r));
    IF ORD(r.Flags) MOD 2 # 0 THEN
        seg := 0;
        sel := 0;
        err := r.EAX MOD 10000H
    ELSE
        seg := r.EAX MOD 10000H;
        sel := r.EDX MOD 10000H;
        err := 0
    END
END AllocDOS9;


(* Allocate a block of DOS memory and return its real mode segment; the linear
   address is seg*16 in the flat model. This is int 31h AX=0100h and not int
   21h AH=48h: the memory functions of int 21h belong to the DPMI host rather
   than to DOS, so a client that reaches DOS with 48h asks the wrong side and
   gets a block that is not its own - one the host will not give back for it
   when the program ends. *)
PROCEDURE AllocDOS* (paras: INTEGER; VAR seg: INTEGER);
VAR
    sel, err: INTEGER;

BEGIN
    AllocDOS9(paras, seg, sel, err)
END AllocDOS;


(* Allocate linear memory (DPMI int 31h AX=0501h). Returns linear address
   in addr (flat), memory handle in handle and the carry flag in cf. *)
PROCEDURE DpmiVer* (): INTEGER;
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 400H;
    Int31(SYSTEM.ADR(r));
    RETURN r.EAX MOD 10000H
END DpmiVer;


(* DPMI int 31h AX=0500h: how much memory is left. The host fills a 48-byte
   record whose first dword is the largest block it can still allocate. That
   is the figure to ask 0501h for; a size picked in advance would either be
   refused or leave memory the host could have given us unused. Returns 0 if
   the host does not answer. *)
PROCEDURE DpmiMaxFree* (): INTEGER;
CONST
    UNANSWERED = -1;

VAR
    info: ARRAY 12 OF INTEGER;
    res:  INTEGER;

BEGIN
    info[0] := UNANSWERED;
    Exec31Buf(SYSTEM.ADR(info));
    res := info[0];
    IF res = UNANSWERED THEN res := 0 END;

    RETURN res
END DpmiMaxFree;


(* DPMI int 31h AX=0501h: allocate linear memory.
   Input size in BX:CX (BX high, CX low);
   output linear address in BX:CX, handle in SI:DI. *)
PROCEDURE DpmiAlloc* (size: INTEGER; VAR addr, handle, cf, err: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 501H;
    r.EBX := size DIV 10000H;
    r.ECX := size MOD 10000H;
    Int31(SYSTEM.ADR(r));
    addr := (r.EBX MOD 10000H) * 10000H + (r.ECX MOD 10000H);
    handle := (r.ESI MOD 10000H) * 10000H + (r.EDI MOD 10000H);
    cf := ORD(r.Flags) MOD 2;
    err := r.EAX MOD 10000H
END DpmiAlloc;


(* DPMI int 31h AX=0502h: free linear memory. Handle in SI:DI.

   Only a block the caller took with DpmiAlloc may be freed here. The process
   heap is one such number that must not be: the host releases every block a
   client owns when the client ends, and freeing that one first faults in the
   host, which is why API.FreeHeap lets its handle go unclosed rather than
   spending it here (API.mod, and HDPMI\I31MEM.ASM). *)
PROCEDURE DpmiFree* (handle: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 502H;
    r.ESI := handle DIV 10000H;
    r.EDI := handle MOD 10000H;
    Int31(SYSTEM.ADR(r))
END DpmiFree;


PROCEDURE PutChar* (c: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 200H;
    r.EDX := c;
    Intr(21H, r)
END PutChar;


(* AH=40h takes a 16-bit count (CX) and the data at DS:DX, which can only be
   an address in the block, so large requests are split and each piece is
   copied into the transfer buffer first. *)
PROCEDURE WrBuf* (adr, len: INTEGER);
VAR
    r: Registers;
    rem, chunk, got: INTEGER;

BEGIN
    rem := len;
    WHILE rem > 0 DO
        chunk := rem;
        IF chunk > LOW_DATA_LEN THEN chunk := LOW_DATA_LEN END;
        SYSTEM.MOVE(adr, lowLin + LOW_DATA, chunk);
        Zero(r);
        r.EAX := 4000H;
        r.EBX := 1;
        r.ECX := chunk;
        r.EDX := LOW_DATA;
        Intr(21H, r);
        IF ORD(r.Flags) MOD 2 # 0 THEN
            rem := 0
        ELSE
            got := r.EAX MOD 10000H;
            IF got = 0 THEN rem := 0 ELSE INC(adr, got); DEC(rem, got) END
        END
    END
END WrBuf;


(* AH=44h AL=00h: device information for handle 1. Bit 7 of DX separates a
   character device (the console) from a file, which is how a redirected
   stdout is recognised. *)
PROCEDURE IsConsole* (): BOOLEAN;
VAR
    r: Registers;
    b: BOOLEAN;

BEGIN
    Zero(r);
    r.EAX := 4400H;
    r.EBX := 1;
    Intr(21H, r);
    b := ORD(r.Flags) MOD 2 = 0;
    IF b THEN
        b := r.EDX MOD 256 DIV 80H = 1
    END;

    RETURN b
END IsConsole;


(* Buffered line input, AH=0Ah. bufadr points at a buffer whose first byte the
   caller has set to the maximum length; DOS stores the number of characters
   read in the second one and echoes a CR, so the count never includes it. DOS
   writes the line into DS:DX and that is in the block: the buffer is copied
   in, the service runs, and the line is copied back out to the caller. *)
PROCEDURE RdLine* (bufadr, max: INTEGER; VAR len: INTEGER);
VAR
    r: Registers;
    c: CHAR;

BEGIN
    IF max > 0FEH THEN max := 0FEH END;
    c := CHR(max);
    SYSTEM.PUT(lowLin + LOW_NAME, c);
    Zero(r);
    r.EAX := 0A00H;
    r.EDX := LOW_NAME;
    Intr(21H, r);
    SYSTEM.GET(lowLin + LOW_NAME + 1, c);
    len := ORD(c);
    IF len > max THEN len := max END;
    SYSTEM.MOVE(lowLin + LOW_NAME, bufadr, len + 2)
END RdLine;


(* Text screen geometry and cursor. Both come from the BIOS data area, which
   DOS itself consults, so a program that moves the cursor with SetCursor sees
   its own DOS output continue from there. *)

PROCEDURE ScrCols* (): INTEGER;
VAR
    c: CHAR;
    n: INTEGER;

BEGIN
    SYSTEM.GET(BDA_COLS, c);
    n := ORD(c);
    IF n < 1 THEN n := 80 END;

    RETURN n
END ScrCols;


PROCEDURE ScrRows* (): INTEGER;
VAR
    c: CHAR;
    n: INTEGER;

BEGIN
    SYSTEM.GET(BDA_ROWS, c);
    n := ORD(c);
    IF n < 1 THEN n := 25 ELSE INC(n) END;

    RETURN n
END ScrRows;


(* Program the CRTC through the colour adapter ports so that the visible
   cursor follows the value written into the BIOS data area. Registers 0Eh and
   0Fh hold the cursor as one linear offset, high byte first, and not as a row
   and a column, so the caller passes y * cols + x. *)
PROCEDURE [stdcall] CrtcCursor (loc: INTEGER);
BEGIN
    SYSTEM.CODE(
    060H,                               (* pushad *)
    066H, 0BAH, 0D4H, 003H,             (* mov dx,03D4h *)
    0B0H, 00EH,                         (* mov al,0Eh *)
    0EEH,                               (* out dx,al *)
    042H,                               (* inc dx *)
    08BH, 045H, 008H,                   (* mov eax,[ebp+8] loc *)
    0C1H, 0E8H, 008H,                   (* shr eax,8 *)
    0EEH,                               (* out dx,al *)
    04AH,                               (* dec dx *)
    0B0H, 00FH,                         (* mov al,0Fh *)
    0EEH,                               (* out dx,al *)
    042H,                               (* inc dx *)
    08BH, 045H, 008H,                   (* mov eax,[ebp+8] loc *)
    0EEH,                               (* out dx,al *)
    061H                                (* popad *)
    )
END CrtcCursor;


PROCEDURE GetCursor* (VAR x, y: INTEGER);
VAR
    c: CHAR;

BEGIN
    SYSTEM.GET(BDA_CURS, c);     x := ORD(c);
    SYSTEM.GET(BDA_CURS + 1, c); y := ORD(c)
END GetCursor;


PROCEDURE SetCursor* (x, y: INTEGER);
VAR
    c: CHAR;
    cols, rows: INTEGER;

BEGIN
    cols := ScrCols();
    rows := ScrRows();
    IF x < 0 THEN x := 0 END;
    IF y < 0 THEN y := 0 END;
    IF x > cols - 1 THEN x := cols - 1 END;
    IF y > rows - 1 THEN y := rows - 1 END;
    c := CHR(x MOD 256); SYSTEM.PUT(BDA_CURS, c);
    c := CHR(y MOD 256); SYSTEM.PUT(BDA_CURS + 1, c);
    CrtcCursor(y * cols + x)
END SetCursor;


PROCEDURE SetAttr* (a: INTEGER);
BEGIN
    attr := a MOD 256;
    attrOn := TRUE
END SetAttr;


PROCEDURE Attr* (): INTEGER;
VAR
    a: INTEGER;

BEGIN
    IF attrOn THEN a := attr ELSE a := DEF_ATTR END;

    RETURN a
END Attr;


PROCEDURE AttrOn* (): BOOLEAN;
BEGIN
    RETURN attrOn
END AttrOn;


(* Blank the screen in the given attribute and home the cursor. *)
PROCEDURE ClearScr* (a: INTEGER);
VAR
    n, p: INTEGER;
    w: WCHAR;

BEGIN
    w := WCHR(a MOD 256 * 100H + SPACE);
    n := ScrCols() * ScrRows();
    p := VID;
    WHILE n > 0 DO
        SYSTEM.PUT(p, w);
        INC(p, 2);
        DEC(n)
    END;
    SetCursor(0, 0)
END ClearScr;


(* Scroll the screen up one line and blank the last one. *)
PROCEDURE ScrollUp (a: INTEGER);
VAR
    cols, rows, n, p: INTEGER;
    w: WCHAR;

BEGIN
    cols := ScrCols();
    rows := ScrRows();
    SYSTEM.MOVE(VID + cols * 2, VID, (rows - 1) * cols * 2);
    w := WCHR(a MOD 256 * 100H + SPACE);
    n := cols;
    p := VID + (rows - 1) * cols * 2;
    WHILE n > 0 DO
        SYSTEM.PUT(p, w);
        INC(p, 2);
        DEC(n)
    END
END ScrollUp;


(* Write len characters from adr straight into text video memory in attribute
   a. CR returns to the first column and LF moves down; DOS behaves the same
   way, so a CR LF pair still ends a line. Scrolling keeps the last row free
   and the cursor is published to the BIOS data area before returning, which
   is what any following DOS output resumes from. *)
PROCEDURE WrAttr* (adr, len, a: INTEGER);
VAR
    i, x, y, cols, rows, p: INTEGER;
    c: CHAR;

BEGIN
    cols := ScrCols();
    rows := ScrRows();
    GetCursor(x, y);
    IF x > cols - 1 THEN x := cols - 1 END;
    IF y > rows - 1 THEN y := rows - 1 END;
    i := 0;
    WHILE i < len DO
        SYSTEM.GET(adr + i, c);
        IF c = 0DX THEN
            x := 0
        ELSIF c = 0AX THEN
            INC(y);
            IF y > rows - 1 THEN ScrollUp(a); y := rows - 1 END
        ELSE
            p := VID + (y * cols + x) * 2;
            SYSTEM.PUT(p, WCHR(a MOD 256 * 100H + ORD(c)));
            INC(x);
            IF x > cols - 1 THEN
                x := 0;
                INC(y);
                IF y > rows - 1 THEN ScrollUp(a); y := rows - 1 END
            END
        END;
        INC(i)
    END;
    SetCursor(x, y)
END WrAttr;


(* Terminate the program, AH=4Ch. The one DOS function here that is written
   out as an instruction instead of being reflected, and it has to be: what
   ends the program is the DPMI host, which intercepts int 21h AH=4Ch in
   protected mode and tears the client down. Asked to simulate 4Ch in real
   mode, the host hands it to real mode DOS, whose current program is the
   extender's own stub and not this one - the call returns and the client
   keeps running, which is a program that prints its result and then hangs.

   It reads no pointer and needs no structure, so unlike the rest of the
   module it works in the one case where nothing else does: a program that
   could not allocate the block (NoBlock below). *)
PROCEDURE [stdcall] Exit* (code: INTEGER);
BEGIN
    SYSTEM.CODE(
    08BH, 045H, 008H,                   (* mov eax,[ebp+8]  code *)
    066H, 005H, 000H, 04CH,             (* add ax,4C00h *)
    0CDH, 021H                          (* int 21h *)
    )
END Exit;


(* LFN open. action: 1 = open existing, 0x12 = create/truncate. access is the
   DOS access word: 0 read only, 1 write only, 2 read and write, with sharing
   mode 0 (compatibility), the same combination the old AH=3Dh used. The name
   goes in DS:ESI, so it is copied into the block and pointed at there. *)
PROCEDURE OpenLFN (name, access, action: INTEGER; VAR h: INTEGER);
VAR
    r: Registers;

BEGIN
    LowName(name);
    Zero(r);
    r.EAX := 716CH;
    r.EBX := access;
    r.ECX := 0;                         (* attributes *)
    r.EDX := action;
    r.EDI := 0;                         (* no alias hint *)
    r.ESI := LOW_NAME;
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        h := -1
    ELSE
        h := r.EAX MOD 10000H
    END
END OpenLFN;


PROCEDURE FileOpen* (name: INTEGER; VAR h: INTEGER);
BEGIN
    OpenLFN(name, 0, 1, h)
END FileOpen;


PROCEDURE FileOpenMode* (name, mode: INTEGER; VAR h: INTEGER);
BEGIN
    OpenLFN(name, mode MOD 4, 1, h)
END FileOpenMode;


PROCEDURE FileCreate* (name: INTEGER; VAR h: INTEGER);
BEGIN
    OpenLFN(name, 2, 12H, h)
END FileCreate;


(* AH=7143h: the attribute byte of a name, or -1 when it is not there. Bit 4
   of the result marks a directory, which is how File.Exists and File.ExistsDir
   tell the two apart.

   The LFN form for the same reason the rest of the names here are: the 8.3
   AH=4300h was measured to answer for a long name under DOSBox-X - it returns
   the same byte this one does, 32 (archive) for a file and 16 (directory) for
   "." - but that is the host translating the name, and a host whose LFN driver
   serves only the LFN subfunctions is the one this layer is written for. *)
PROCEDURE FileAttr* (name: INTEGER; VAR a: INTEGER);
VAR
    r: Registers;

BEGIN
    LowName(name);
    Zero(r);
    r.EAX := 7143H;
    r.EDX := LOW_NAME;
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        a := -1
    ELSE
        a := r.ECX MOD 10000H
    END
END FileAttr;


(* AH=7141h: delete. The name goes in DS:EDX, which for a real mode service
   means a segment and an offset, so it is copied into the block like every
   other name.

   The 8.3 form AH=41h is not the same call with a shorter name. Measured
   under DOSBox-X with LFN on, it answers error 2, "file not found", for a long
   name - while deleting the file's short alias succeeds - and the same file
   goes away through AH=7141h. Both forms delete a short name, so this one
   covers what the other did and the names it could not reach. *)
PROCEDURE FileDelete* (name: INTEGER): BOOLEAN;
VAR
    r: Registers;

BEGIN
    LowName(name);
    Zero(r);
    r.EAX := 7141H;
    r.EDX := LOW_NAME;
    Intr(21H, r);
    RETURN ORD(r.Flags) MOD 2 = 0
END FileDelete;


PROCEDURE MkDir* (name: INTEGER): BOOLEAN;
VAR
    r: Registers;

BEGIN
    LowName(name);
    Zero(r);
    r.EAX := 7139H;
    r.EDX := LOW_NAME;
    Intr(21H, r);
    RETURN ORD(r.Flags) MOD 2 = 0
END MkDir;


PROCEDURE RmDir* (name: INTEGER): BOOLEAN;
VAR
    r: Registers;

BEGIN
    LowName(name);
    Zero(r);
    r.EAX := 713AH;
    r.EDX := LOW_NAME;
    Intr(21H, r);
    RETURN ORD(r.Flags) MOD 2 = 0
END RmDir;


(* AH=42h: move the file pointer. whence is 0 from the start, 1 from the
   current position, 2 from the end. Returns the new absolute offset, or -1.
   The offset goes into CX:DX as a 32-bit value, and it may well be negative -
   seeking backwards from the end is the normal way to read a file's tail - so
   the two halves are taken as bit fields rather than with DIV and MOD, whose
   result for a negative dividend would depend on the rounding rule. *)
PROCEDURE FileSeek* (h, off, whence: INTEGER; VAR pos: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 4200H + whence MOD 256;
    r.EBX := h;
    r.ECX := ORD(BITS(off) * {16..31}) DIV 10000H;
    r.EDX := ORD(BITS(off) * {0..15});
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        pos := -1
    ELSE
        pos := (r.EDX MOD 10000H) * 10000H + (r.EAX MOD 10000H)
    END
END FileSeek;


(* AH=3Fh takes a 16-bit count (CX) and puts the data at DS:DX, so large
   requests are split and each piece lands in the transfer buffer first and is
   copied out to the caller from there. *)
PROCEDURE FileRead* (h, buf, len: INTEGER; VAR n: INTEGER);
VAR
    r: Registers;
    total, rem, chunk, got, p: INTEGER;
    stop, bad: BOOLEAN;

BEGIN
    total := 0;
    rem := len;
    p := buf;
    stop := FALSE;
    bad := FALSE;
    WHILE (rem > 0) & ~stop DO
        chunk := rem;
        IF chunk > LOW_DATA_LEN THEN
            chunk := LOW_DATA_LEN
        END;
        Zero(r);
        r.EAX := 3F00H;
        r.EBX := h;
        r.ECX := chunk;
        r.EDX := LOW_DATA;
        Intr(21H, r);
        IF ORD(r.Flags) MOD 2 # 0 THEN
            bad := TRUE;
            stop := TRUE
        ELSE
            got := r.EAX MOD 10000H;
            IF got = 0 THEN
                stop := TRUE
            ELSE
                SYSTEM.MOVE(lowLin + LOW_DATA, p, got);
                INC(total, got);
                INC(p, got);
                DEC(rem, got);
                IF got < chunk THEN
                    stop := TRUE
                END
            END
        END
    END;
    IF bad & (total = 0) THEN n := -1 ELSE n := total END
END FileRead;


(* AH=40h takes a 16-bit count (CX) and the data at DS:DX, so large requests
   are split and each piece is copied into the transfer buffer first. *)
PROCEDURE FileWrite* (h, buf, len: INTEGER; VAR n: INTEGER);
VAR
    r: Registers;
    total, rem, chunk, got, p: INTEGER;
    stop, bad: BOOLEAN;

BEGIN
    total := 0;
    rem := len;
    p := buf;
    stop := FALSE;
    bad := FALSE;
    WHILE (rem > 0) & ~stop DO
        chunk := rem;
        IF chunk > LOW_DATA_LEN THEN
            chunk := LOW_DATA_LEN
        END;
        SYSTEM.MOVE(p, lowLin + LOW_DATA, chunk);
        Zero(r);
        r.EAX := 4000H;
        r.EBX := h;
        r.ECX := chunk;
        r.EDX := LOW_DATA;
        Intr(21H, r);
        IF ORD(r.Flags) MOD 2 # 0 THEN
            bad := TRUE;
            stop := TRUE
        ELSE
            got := r.EAX MOD 10000H;
            INC(total, got);
            INC(p, got);
            DEC(rem, got);
            IF got < chunk THEN
                stop := TRUE
            END
        END
    END;
    IF bad & (total = 0) THEN n := -1 ELSE n := total END
END FileWrite;


PROCEDURE FileClose* (h: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 3E00H;
    r.EBX := h;
    Intr(21H, r)
END FileClose;


(* The current directory of a drive, as a NUL terminated string without the
   drive letter, in dest. DOS writes it to DS:ESI - the block again - and it is
   copied out to the caller afterwards.

   drive is the 0-based index GetDrive hands back (0 = A:), and DOS wants the
   number one above that (0 = the default drive) - which is why it is the
   caller's drive and not simply 0. An empty string comes back when the drive
   has no directory to report, the usual case being a drive that is not
   there. *)
PROCEDURE GetCurDir* (dest, drive: INTEGER);
VAR
    r: Registers;
    i: INTEGER;
    c: CHAR;

BEGIN
    (* Two forms of "get current directory", LFN first: AH=7147h and, behind
       it, the older AH=47h for a host that does not carry the LFN services.
       Both were measured to answer here; the second call is only made when the
       first one fails. *)
    Zero(r);
    r.EAX := 7147H;
    r.EDX := drive + 1;
    r.ESI := LOW_NAME;
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        Zero(r);
        r.EAX := 4700H;
        r.EDX := drive + 1;
        r.ESI := LOW_NAME;
        Intr(21H, r)
    END;

    (* Only a call that answered has left an answer. When neither did, the
       buffer holds whatever the DOS block held - not a string - so the caller
       gets an empty one: a caller cannot tell a failure from a directory here,
       and an empty path is the harmless of the two readings. *)
    i := 0;
    IF ORD(r.Flags) MOD 2 = 0 THEN
        SYSTEM.GET(lowLin + LOW_NAME + i, c);
        WHILE (c # 0X) & (i < LOW_NAME_LEN - 1) DO
            SYSTEM.PUT(dest + i, c);
            INC(i);
            SYSTEM.GET(lowLin + LOW_NAME + i, c)
        END
    END;
    c := 0X;
    SYSTEM.PUT(dest + i, c)
END GetCurDir;


PROCEDURE GetDrive* (VAR d: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 1900H;
    Intr(21H, r);
    d := r.EAX MOD 256
END GetDrive;


(* int 21h AH=2Ch: CH=hour, CL=minute, DH=second, DL=hundredths *)
PROCEDURE GetTime100* (VAR h, m, s, hs: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 2C00H;
    Intr(21H, r);
    h  := (r.ECX DIV 256) MOD 256;
    m  := r.ECX MOD 256;
    s  := (r.EDX DIV 256) MOD 256;
    hs := r.EDX MOD 256
END GetTime100;


PROCEDURE GetTime* (VAR h, m, s: INTEGER);
VAR
    hs: INTEGER;

BEGIN
    GetTime100(h, m, s, hs)
END GetTime;


(* int 21h AH=2Ah: CX=year, DH=month, DL=day *)
PROCEDURE GetDate* (VAR y, mo, d: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 2A00H;
    Intr(21H, r);
    y  := r.ECX MOD 10000H;
    mo := (r.EDX DIV 256) MOD 256;
    d  := r.EDX MOD 256
END GetDate;


(* The PE loader answers two int 21h calls that DKRNL32 uses for the same
   purpose: AX=4B82h returns the handle of the main module in EAX, and
   AX=4B86h with that handle in EDX returns a flat pointer to the module's
   file name. Going through them is what keeps this module free of Win32
   imports while still yielding the real program path: the environment
   segment of a client's PSP is empty, so the usual DOS route - the name that
   follows the environment block - is closed here. *)
PROCEDURE [stdcall] GetModuleName (VAR adr: INTEGER);
BEGIN
    SYSTEM.CODE(
    060H,                               (* pushad *)
    031H, 0D2H,                         (* xor edx,edx *)
    066H, 0B8H, 082H, 04BH,             (* mov ax,4B82h *)
    0CDH, 021H,                         (* int 21h *)
    072H, 00CH,                         (* jc  fail *)
    089H, 0C2H,                         (* mov edx,eax *)
    066H, 0B8H, 086H, 04BH,             (* mov ax,4B86h *)
    0CDH, 021H,                         (* int 21h *)
    072H, 002H,                         (* jc  fail *)
    0EBH, 002H,                         (* jmp store *)
    031H, 0C0H,                         (* fail: xor eax,eax *)
    08BH, 055H, 008H,                   (* store: mov edx,[ebp+8] adr *)
    089H, 002H,                         (* mov [edx],eax *)
    061H                                (* popad *)
    )
END GetModuleName;


PROCEDURE ProgPath* (dest, max: INTEGER; VAR len: INTEGER);
VAR
    p:  INTEGER;
    c:  CHAR;

BEGIN
    GetModuleName(p);
    IF p = 0 THEN
        len := -1
    ELSE
        len := 0;
        SYSTEM.GET(p, c);
        WHILE (c # 0X) & (len < max - 1) DO
            SYSTEM.PUT(dest + len, c);
            INC(len);
            SYSTEM.GET(p + len, c)
        END;
        c := 0X;
        SYSTEM.PUT(dest + len, c)
    END
END ProgPath;


(* The rest of the loader API that DKRNL32 wraps: AX=4B00h loads a module,
   AX=4B81h resolves one of its exports, AX=4B80h releases it. The loader is
   reached by int 21h directly, as with the two calls above, which is what
   keeps a program that loads a DLL from importing one to do it.

   AX=4B00h is the classic DOS EXEC entry and the loader reads the caller's ES
   to tell the two apart: HX's own LoadLibraryExA clears ES and EBX before the
   call "since there is no parameter block for DLLs", and an image that does
   not carry IMAGE_FILE_DLL is given the entry point of an application when ES
   is not zero. This is also why the call is written out here rather than made
   through Intr: the loader answers it in protected mode, where the name is a
   flat address and the reflection of a real mode interrupt has nothing to do
   with it. *)
PROCEDURE [stdcall] LoadModule (nameadr: INTEGER; VAR h: INTEGER);
BEGIN
    SYSTEM.CODE(
    060H,                               (* pushad *)
    006H,                               (* push es *)
    031H, 0DBH,                         (* xor ebx,ebx *)
    08EH, 0C3H,                         (* mov es,bx *)
    08BH, 055H, 008H,                   (* mov edx,[ebp+8]  nameadr *)
    066H, 0B8H, 000H, 04BH,             (* mov ax,4B00h *)
    0CDH, 021H,                         (* int 21h *)
    007H,                               (* pop es *)
    072H, 002H,                         (* jc  fail *)
    0EBH, 002H,                         (* jmp store *)
    031H, 0C0H,                         (* fail: xor eax,eax *)
    08BH, 055H, 00CH,                   (* store: mov edx,[ebp+12] h *)
    089H, 002H,                         (* mov [edx],eax *)
    061H                                (* popad *)
    )
END LoadModule;


(* EDX holds the export name's linear address. The loader treats a value whose
   high word is zero as an ordinal instead, which cannot happen for a string in
   this program's image or heap - those live far above 64K - so only the name
   form is reachable from here. *)
PROCEDURE [stdcall] GetProcAdr (h, nameadr: INTEGER; VAR adr: INTEGER);
BEGIN
    SYSTEM.CODE(
    060H,                               (* pushad *)
    08BH, 05DH, 008H,                   (* mov ebx,[ebp+8]  h *)
    08BH, 055H, 00CH,                   (* mov edx,[ebp+12] nameadr *)
    066H, 0B8H, 081H, 04BH,             (* mov ax,4B81h *)
    0CDH, 021H,                         (* int 21h *)
    072H, 002H,                         (* jc  fail *)
    0EBH, 002H,                         (* jmp store *)
    031H, 0C0H,                         (* fail: xor eax,eax *)
    08BH, 055H, 010H,                   (* store: mov edx,[ebp+16] adr *)
    089H, 002H,                         (* mov [edx],eax *)
    061H                                (* popad *)
    )
END GetProcAdr;


(* AX=4B82h answers with the module-list entry for the name in EDX, or, when
   EDX is zero, for the module the current task was started from: the EXE. A
   DLL asks for it to reach what the EXE exports. *)
PROCEDURE [stdcall] GetMainModule (VAR h: INTEGER);
BEGIN
    SYSTEM.CODE(
    060H,                               (* pushad *)
    031H, 0D2H,                         (* xor edx,edx      - the main module *)
    066H, 0B8H, 082H, 04BH,             (* mov ax,4B82h *)
    0CDH, 021H,                         (* int 21h *)
    08BH, 055H, 008H,                   (* mov edx,[ebp+8] h *)
    089H, 002H,                         (* mov [edx],eax *)
    061H                                (* popad *)
    )
END GetMainModule;


(* The carry flag is what FreeModule32 sets when the handle is not in the
   module list; EAX is not part of its answer, so it is turned into one here
   before popad puts the saved registers back. *)
PROCEDURE [stdcall] FreeModule (h: INTEGER; VAR ok: INTEGER);
BEGIN
    SYSTEM.CODE(
    060H,                               (* pushad *)
    08BH, 055H, 008H,                   (* mov edx,[ebp+8]  h *)
    066H, 0B8H, 080H, 04BH,             (* mov ax,4B80h *)
    0CDH, 021H,                         (* int 21h *)
    019H, 0C0H,                         (* sbb eax,eax  (0 freed, -1 not) *)
    0F7H, 0D0H,                         (* not eax *)
    08BH, 055H, 00CH,                   (* mov edx,[ebp+12] ok *)
    089H, 002H,                         (* mov [edx],eax *)
    061H                                (* popad *)
    )
END FreeModule;


(* Load a module, by name, the way the loader resolves it: a module already in
   memory is returned as it is, otherwise the current directory and PATH are
   searched. The result is 0 if the module could not be loaded, which includes
   the case of its own entry point having refused the load. *)
PROCEDURE Load* (name: ARRAY OF CHAR): INTEGER;
VAR
    h: INTEGER;

BEGIN
    h := 0;
    LoadModule(SYSTEM.ADR(name[0]), h);

    RETURN h
END Load;


PROCEDURE GetProc* (h: INTEGER; name: ARRAY OF CHAR): INTEGER;
VAR
    adr: INTEGER;

BEGIN
    adr := 0;
    GetProcAdr(h, SYSTEM.ADR(name[0]), adr);

    RETURN adr
END GetProc;


(* The module the process was started from. A DLL passes it to GetProc to
   reach the procedures the EXE exports - in this runtime, the allocator. *)
PROCEDURE MainHandle* (): INTEGER;
VAR
    h: INTEGER;

BEGIN
    h := 0;
    GetMainModule(h);

    RETURN h
END MainHandle;


(* Release a module. The loader drops its own reference and calls the entry
   point once more, with DLL_PROCESS_DETACH, unless another module still
   holds a reference to it. The outcome is FALSE when the handle is not one
   the loader knows. *)
PROCEDURE Free* (h: INTEGER): BOOLEAN;
VAR
    ok: INTEGER;

BEGIN
    ok := 0;
    FreeModule(h, ok);

    RETURN ok # 0
END Free;


(* The linear base of this program's PSP, or 0 when it cannot be established.

   int 21h AH=51h answers with the PSP, and through Intr the answer is its real
   mode segment in BX - because what a reflected call returns is what the real
   mode handler left, and a real mode handler has no selector to name a
   segment with. That suits this runtime: the block runs with the flat
   relation lowLin = lowSeg * 16 (see the module header), so a segment is its
   own linear base times 16, and no DPMI selector translation is needed to
   read the PSP. Measured under DOSBox-X with the tail of a real command line:
   the segment answers, and the byte at segment * 16 + 80H is the length of the
   tail this program was started with.

   A segment of 0 is not a PSP and is reported as no answer at all - a base of
   0 would otherwise read as "the PSP is at address 0", which is the real mode
   interrupt table. The same call reaches the same PSP as int 21h AH=62h, so
   either service can be used here; AH=51h is the one DOS documents. *)
PROCEDURE PspBase (VAR base: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 5100H;                     (* AH=51h: the current PSP *)
    Intr(21H, r);
    IF r.EBX = 0 THEN base := 0 ELSE base := r.EBX * 16 END
END PspBase;


(* Copy the DOS command tail into dest as a NUL terminated string, with its
   length in len. DOS counts the tail without a terminator, so dest needs room
   for the count plus the one written here; 127 characters is the most a DOS
   tail can hold, and the count is clamped to that before it is used, because
   it is a byte of the PSP and not a number this layer produced.

   The PSP is reached through PspBase; a base of 0 leaves len at 0 and dest an
   empty string, so a caller cannot tell a missing block from an empty command
   line - an empty command line is the harmless of the two readings. *)
PROCEDURE CmdLine* (dest: INTEGER; VAR len: INTEGER);
VAR
    base, i, n: INTEGER;
    c: CHAR;

BEGIN
    PspBase(base);
    i := 0;
    IF base # 0 THEN
        SYSTEM.GET(base + PSP_TAIL, c);
        n := ORD(c);
        IF n > 127 THEN n := 127 END;
        WHILE i < n DO
            SYSTEM.GET(base + PSP_TAIL + 1 + i, c);
            SYSTEM.PUT(dest + i, c);
            INC(i)
        END
    END;
    c := 0X;
    SYSTEM.PUT(dest + i, c);
    len := i
END CmdLine;


(* No block, so no interrupt can be reflected and no DOS call can be made at
   all: say so and stop. The message goes straight into video memory, which
   needs no DOS to write it, and the stop is Exit, which is the one call here
   that needs no block. *)
PROCEDURE NoBlock;
VAR
    msg: ARRAY 48 OF CHAR;
    i, p: INTEGER;

BEGIN
    msg := "HXDOS: no DOS memory for the interrupt block";
    p := VID + 2 * 80 * 10;             (* the eleventh line of the screen *)
    i := 0;
    WHILE msg[i] # 0X DO
        SYSTEM.PUT(p, WCHR(DEF_ATTR * 100H + ORD(msg[i])));
        INC(p, 2);
        INC(i)
    END;
    Exit(1)
END NoBlock;


(* Allocate the one block every reflected call is built on, and fill in what
   it is addressed through - or say why not and stop. Called once, from the
   module body below.

   The allocation is AllocDOS9 and not a second copy of the same int 31h call:
   this is the same service, in the same module, and the block is a DOS memory
   block like any other. 64 KB is the largest single block DOS hands out, and a
   program it is refused to cannot call DOS at all, which is what NoBlock says
   out loud before stopping. *)
PROCEDURE GetBlock;
VAR
    sel, err: INTEGER;

BEGIN
    AllocDOS9(LOW_BLOCK, lowSeg, sel, err);
    IF lowSeg = 0 THEN
        NoBlock                     (* says so and stops; it does not return *)
    END;
    lowLin := lowSeg * 16;          (* flat model: the linear base *)
    rm := SYSTEM.VAL(CallP, lowLin) (* the call structure, at LOW_RMCS = 0 *)
END GetBlock;


BEGIN
    GetBlock
END DOS.
