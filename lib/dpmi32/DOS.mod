(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    DPMI32 low-level DOS layer. No Win32 DLL imports.

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
    offset. Both therefore live in one DOS block, taken once at load time (64
    KB allocated from the host on the DPMI targets, the 8 KB buffer the
    extender lends on Adam). A path is copied into it by LowName and file data
    goes through its transfer buffer, which is what the wrappers below hide
    from their callers; a caller that reaches for DOS.Intr* itself has to do
    the same and says so by putting the block's segment in the DS field of the
    Registers record.

    DPMI is not a real mode service, so its own calls are made directly, by
    Int31, the one interrupt this layer still spells as an instruction. Three
    things that look like DOS services are DPMI's and cannot be reflected
    either: the memory functions of int 21h (see AllocDOS), the loader API of
    the extender (AX=4B00h, AX=4B80h..4B86h, answered by DPMILD32 in protected
    mode), and AH=4Ch, which terminates the client only because the host
    intercepts it - reflected, it reaches the real mode DOS, which terminates
    the extender's own stub and leaves this program running (see Exit).

    A second extender answers the same int 31h with an API of its own: DOS32,
    which runs the Adam image this compiler writes for dpmi32adam
    (doc/ADAM.TXT). It has none of the DPMI calls above - 0400h, 0100h, 0500h,
    0501h and 0502h are not in its dispatcher, and a client that makes one is
    reflected into real mode, where there is no host to answer it - and what
    it offers instead is its own set: AX=EE02h reports the addresses of the
    program, and AX=EE42h/EE40h allocate a block and undo the last
    allocation. The rest of this layer is the same on both, because both are
    reached the same way: a reflected real mode interrupt.

    What Adam does change is every address in the module. DOS32 loads the
    program under one selector based at the start of the program block, not at
    0, so the first megabyte - the BIOS data area, text video memory, the PSP
    and the environment DOS set up - is out of reach of the program's own data
    selector: an address there is (linear - program base), and what the
    extender hands over is already in that form (it calls the PSP, the
    environment and the path "offsets relative to the main program segment",
    and its own 8 KB buffer sits at 16*AX - base). progBase below is 0 on
    every other target and that base here, and every address below 1 MB is
    named as `linear - progBase`, so the code that reads the BIOS data area or
    writes text video memory is the same text on every target and no selector
    is ever switched.

    The real mode call structure is the one thing that has to be placed rather
    than just addressed. It must be in memory this program can name, because
    the program has to fill it in and read it back; on the DPMI targets the
    block is flat, so its own contents qualify and the structure sits at
    LOW_RMCS inside it, while on Adam a structure in the 8 KB buffer would be
    addressed as an offset into a segment the program cannot name, and it is a
    variable of this module instead.

    Every name this layer hands to DOS goes through an LFN function first -
    open and create AH=716Ch, delete AH=7141h, attributes AH=7143h, rename
    AH=7156h, mkdir and rmdir AH=7139h/713Ah, the current directory AH=7147h -
    and through the classic 8.3 form of the same call when that one does not
    answer. The LFN subfunctions are the only ones that reach a long name, and
    the 8.3 forms are the only ones a DOS without LFN support has at all, so a
    layer that wants to work on either has to carry both.

    Which of the two is there cannot be asked in advance: there is no call that
    reports LFN support, and a DOS that does not have the subfunctions answers
    them with error 7100h, "function not supported" - the same carry flag and
    the same shape of refusal as a name that is not there. What a long name
    service does guarantee is that it returns with the carry flag clear when it
    has run. The flag is therefore set before such a call and read after it:
    clear means the call ran, set means it failed or was never there, and the
    classic form goes behind it. Every LFN call here is written that way, and
    the classic call it falls back to is entered with the flag clear, the way
    any other DOS call is (section 2 of doc/dpmi32.txt has the measurements).

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

    (* BIOS data area and text video memory. Both are below 1 MB, which on
       Adam is outside what the program's own data selector reaches, so every
       address here is used as `BDA_x - progBase` / `VID - progBase`: on every
       other target progBase is 0 and that is the address itself, and on Adam
       it is the difference between a linear address and one this program can
       name (see the module header). *)
    BDA_COLS = 44AH;                    (* number of text columns *)
    BDA_ROWS = 484H;                    (* number of text rows, minus one *)
    BDA_CURS = 450H;                    (* cursor position on page 0 *)
    VID      = 0B8000H;                 (* text page 0 of the colour adapter *)
    SPACE    = 20H;
    DEF_ATTR = 7;                       (* light grey on black *)

    (* The find area: what a directory walk keeps in the block, carved off the
       top of the transfer buffer.

       Three things live in it, and they are all here rather than in the path
       buffer because a walk outlives the call that started it. The path buffer
       is rewritten by every other call in this module that takes a name, so a
       caller that reads an entry and then opens it - the thing a directory
       dialog does - would take the walked directory out from under the walk
       that found it. The find area is touched by nothing but the walk itself.

         +000h  the LFN walk's find block          323 bytes
         +150h  the classic walk's DTA               43 bytes
         +180h  the walk's path                     512 bytes

       The block and the DTA are both live at once in LFN mode - the block holds
       the entry while the DTA is where that entry's stamp is asked for - so
       they do not overlap. The path holds the directory the walk is in with
       *.* after it, for as long as the walk lasts, and an entry's name is
       written over the *.* when that entry's stamp is asked for; in the classic
       walk it is the mask AH=4Eh and AH=4Fh are both given, and is never
       overwritten.

       The area ends where the transfer buffer used to, so the stack below it -
       which the comment above allots the Adam target 2 KB of, and which the
       compiler itself is built and self-hosted on - is exactly as large as it
       was. What shrinks is the transfer buffer, and that is staging space this
       layer already reads and writes in a loop of chunks. *)
    LOW_FIND_LEN = 400H;

$IF (DOS32)

    (* Adam: the extender lends the program one 8 KB buffer - the one its own
       file services use - and that is the whole of the DOS memory this layer
       has (int 31h AX=EE02h). The layout below does not fit in it, and it does
       not have to: the call structure has to be somewhere the program can
       address it, and on Adam that is the program's own data (see Intr), since
       anything a real mode service is pointed at travels as a segment and an
       offset whatever it is. What is left for the buffer is the two names, the
       transfer buffer and the stack a reflected call runs on.

       0000h  unused, the call structure being in the program's data
       0040h  the path buffer                     512 bytes
              one name, or two of 256 bytes each for the calls that take two
       0240h  the transfer buffer              4544 bytes
       1400h  the find area                     1024 bytes
       1800h .. 2000h  the real mode stack         2 KB *)
    LOW_BUF = 2000H;                    (* the buffer EE02h lends, in bytes *)
    LOW_NAME = 40H;
    LOW_NAME_LEN = 200H;
    LOW_HALF = 100H;
    LOW_NAME2 = LOW_NAME + LOW_HALF;
    LOW_DATA = 240H;
    LOW_DATA_LEN = 15C0H;               (* the transfer buffer and the find area *)
    LOW_SP = LOW_BUF;                   (* where that stack starts, growing down *)

$ELSE

    (* The DOS block: 64 KB, the largest single block DOS hands out, and the
       only memory a real mode service can be pointed at. Everything a
       reflected call needs that DOS has to read or write lives here - the call
       structure, one path, and the buffer file data passes through - and the
       rest of the block is the stack the reflected call runs on.

       0000h  the real mode call structure          50 bytes
       0040h  the path buffer                     512 bytes
              one name, or two of 256 bytes each for the calls that take
              two names: the old one at 0040h, the new one at 0140h
       0240h  the transfer buffer              48128 bytes
       0BE40h  the find area                    1024 bytes
       0C240h .. 0FFFEh  the real mode stack        ~15 KB *)
    LOW_BLOCK = 1000H;                  (* the block, in paragraphs *)
    LOW_RMCS = 0;                       (* segment offset into the block *)
    LOW_NAME = 40H;
    LOW_NAME_LEN = 200H;
    LOW_HALF = 100H;                    (* the path buffer holds one name or two
                                           of this many bytes each: a call that
                                           takes two names - rename is the one -
                                           stages them at LOW_NAME and LOW_NAME2,
                                           and a name that does not fit its half
                                           is cut like any other *)
    LOW_NAME2 = LOW_NAME + LOW_HALF;
    LOW_DATA = 240H;
    LOW_DATA_LEN = 0C000H;              (* the transfer buffer and the find area *)
    LOW_SP = 0FFFEH;                    (* where that stack starts, growing down *)

$END

    (* The transfer buffer proper, and the find area at the top of it. Derived
       and not written twice: the two layout comments above say where the whole
       buffer ends, and these two say where it is divided. LOW_DATA_LEN stays
       the extent the comments describe, so the arithmetic here reads straight
       off them. *)
    LOW_STAGE_LEN = LOW_DATA_LEN - LOW_FIND_LEN;
    LOW_FIND = LOW_DATA + LOW_STAGE_LEN;
    LOW_FBLK = LOW_FIND;                (* the LFN walk's find block *)
    LOW_DTA  = LOW_FIND + 150H;         (* the classic walk's DTA *)
    LOW_PATH = LOW_FIND + 180H;         (* the walk's path *)
    LOW_PATH_LEN = 200H;

    (* The fields of the LFN find block, as DOSBox-X fills them in per
       doc/dpmi32.txt: the attribute is a dword whose low byte is the DOS
       attribute, the size is a pair of dwords and the name is a 260 byte
       ASCIZ field. cAlternateFileName is at 130H and not 12CH - 44 + 260 - and
       that one offset is worth being careful about: 12CH falls inside the zero
       tail of cFileName and reads as an empty alias for every entry, which is
       a reading that produces a whole design around a field that is not
       empty. The alias is filled in exactly when the name is not already
       valid 8.3, which is what makes it the right name to hand the classic
       side. *)
    FBLK_ATTR = 0;                      (* dword; its low byte is the attribute *)
    FBLK_SIZE = 20H;                    (* dword; nFileSizeLow *)
    FBLK_NAME = 2CH;                    (* 260 bytes, ASCIZ *)
    FBLK_NAME_LEN = 104H;
    FBLK_ALT = 130H;                    (* 14 bytes, ASCIZ; empty for 8.3 *)
    FBLK_ALT_LEN = 0EH;

    (* The fields of the DTA the classic walk fills: the attribute byte, the two
       packed words and the size, in front of a 13 byte ASCIZ name. *)
    DTA_ATTR = 15H;
    DTA_TIME = 16H;
    DTA_DATE = 18H;
    DTA_SIZE = 1AH;
    DTA_NAME = 1EH;
    DTA_NAME_LEN = 0DH;

    (* What a walk is asked for. No caller gets to choose this one.

       The two matchers disagree, and not only across the two walks: measured
       under DOSBox-X, ?E* and TE* find TEST1.MOD through the LFN walk and
       nothing at all through the classic one, and *E* finds thirteen where the
       classic walk finds four. So which entries a caller is offered would
       otherwise depend on whether the host running it happens to have LFN
       support, which is not a difference any caller could be told about. A walk
       here is therefore always started on *.* - measured to mean every entry in
       both walks, extensionless names and directories included - and the
       caller's own mask is applied by Dirs.Match, once, for every platform.

       17H is read-only, hidden, system and directory. 10H leaves a read-only
       file out; 3FH additionally returns the volume label, which is not a
       directory entry on any other platform and is not one here either. *)
    FIND_ATTR = 17H;

    (* The two negatives a walk's handle can be. A walk that is over, and one
       that was never started, are FIND_NONE; the 8.3 walk has no handle at all,
       its state being the DTA, and is FIND_CLASSIC. *)
    FIND_NONE = -1;
    FIND_CLASSIC = -2;

    (* The program segment prefix DOS builds for every program: its command
       tail is a length byte and then that many characters, with no
       terminator of its own. *)
    PSP_TAIL = 80H;
    PSP_ENV  = 2CH;

    (* Bit 0 of the flags word. A call is entered with it set when the caller
       has to know whether the service ran at all - see the module header. *)
    CARRY = 1;

    (* The fields of the real mode call structure, at the offsets DPMI 0.9
       gives them: the 32-bit registers in the order EDI, ESI, EBP, a reserved
       dword, EBX, EDX, ECX, EAX, then the 16-bit flags, segment registers and
       the CS:IP and SS:SP the service is entered and left with. *)
    RM_FLAGS_IN = 202H;                 (* the interrupt enable, and bit 1,
                                           which is one on every processor *)


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

    (* A walk in progress. handle is the LFN search's own handle, or
       FIND_CLASSIC for the 8.3 walk, which keeps its state in the DTA and has
       no handle at all, or FIND_NONE for a walk that is over - which is what
       FindFirst leaves behind when the directory is not there or is empty, and
       what FindNext and FindClose leave behind when they have finished.

       tail is where the *.* that ends the walk's path begins, so that an
       entry's name can be written over it to make the path that entry's stamp
       is asked for. It is an offset into LOW_PATH and stays valid for the whole
       walk, because nothing but the walk writes there. *)
    Find* = RECORD
        handle*: INTEGER;
        tail*:   INTEGER
    END;


VAR

    attr:   INTEGER;                    (* attribute chosen by SetAttr *)
    attrOn: BOOLEAN;                    (* set once a colour was chosen *)

    (* Where this program's segment starts. Zero on every target whose client
       runs at linear 0 - which is all of them but Adam - and the base DOS32
       reports in EBX (int 31h AX=EE02h), around 20 MB, under DOS32. Every
       address below 1 MB is named as `linear - progBase` so that the same
       expression is the address itself on one target and the address to hand
       to SYSTEM on the other. See the module header. *)
    progBase: INTEGER;

$IF (DOS32)

    (* Adam: what the extender reports for the PSP, the environment and the
       program's own path, in the form the program can address them in - the
       offsets EE02h calls "relative to the main program segment". They are not
       linear addresses: the PSP sits *below* the program base, so the linear
       address of what pspNear points at is progBase + pspNear. The other
       targets reach all three through DOS itself and need no such address. *)
    pspNear, envNear, pathNear: INTEGER;

    (* The call structure, in the program's own data. A variable here rather
       than at LOW_RMCS in the block for two reasons: the block on this target
       is the extender's 8 KB one and cannot afford the room, and a structure
       the host has to read has to be somewhere the program can name - which,
       with the extender's selector based at the program rather than at 0, is
       the program's own data. *)
    rmRec:  Call;

$END

    lowSeg: INTEGER;                    (* the DOS block, as DOS names it *)
    lowLin: INTEGER;                    (* the same block, as this program does *)
    rm:     CallP;                      (* the call structure *)
    rmAdr:  INTEGER;                    (* where it is, as ES:EDI wants it *)


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
   do after any DOS call.

   The one flag the caller has a say in is the carry, bit 0: a service the
   caller is not sure is there at all is entered with it set and judged by
   whether the service cleared it, so the flag the caller passed in the
   record's Flags field is carried into the call and the rest of the word
   comes from RM_FLAGS_IN. *)
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
    rm.Flags := WCHR(RM_FLAGS_IN + ORD(r.Flags) MOD 2);
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
    q.EDI := rmAdr;                     (* ES:EDI = the call structure *)
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


(* Copy the NUL terminated string at adr into the block at off, cutting it at
   max bytes: the one copy every wrapper that hands DOS a name goes through.
   LowName is this with the whole path buffer to itself, LowName2 with the half
   of it that the second name of a call that takes two names goes in.

   A string too long for the room it is given is cut and the service then
   refuses the truncated name, the way it refuses any name it cannot find. *)
PROCEDURE LowNameAt (adr, off, max: INTEGER);
VAR
    i: INTEGER;
    c: CHAR;

BEGIN
    i := 0;
    SYSTEM.GET(adr + i, c);
    WHILE (c # 0X) & (i < max - 1) DO
        SYSTEM.PUT(lowLin + off + i, c);
        INC(i);
        SYSTEM.GET(adr + i, c)
    END;
    c := 0X;
    SYSTEM.PUT(lowLin + off + i, c)
END LowNameAt;


(* The one name of a call that takes one, at the start of the path buffer. This
   is the copy the file system wrappers below use, and it may run to the end of
   the buffer: no DOS path has room for more than LOW_NAME_LEN characters. *)
PROCEDURE LowName (adr: INTEGER);
BEGIN
    LowNameAt(adr, LOW_NAME, LOW_NAME_LEN)
END LowName;


(* The second name of a call that takes two, in the far half of the path buffer.
   Only rename needs it, and it is bounded by that half so that neither name can
   reach into the other; LOW_HALF bytes is as much as a DOS path has room for. *)
PROCEDURE LowName2 (adr: INTEGER);
BEGIN
    LowNameAt(adr, LOW_NAME2, LOW_HALF)
END LowName2;


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
$IF (DOS32)
BEGIN
    (* DOS32 has no DPMI memory service to call: 0100h is not in its int 31h
       dispatcher, and a client that made the call would be reflected into
       real mode, where there is no host to answer it. Memory under DOS32
       comes from the extender's own AX=EE42h (DpmiAlloc below); a caller that
       wants a real mode segment rather than memory has the 8 KB buffer that
       AX=EE02h reports. Nothing is allocated, and the refusal is reported the
       way DOS reports one, as error 8, "insufficient memory". *)
    seg := 0;
    sel := 0;
    err := 8
$ELSE
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
$END
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


(* Allocate linear memory (DPMI int 31h AX=0501h) and report the version of
   the host that would answer it (AX=0400h). *)
PROCEDURE DpmiVer* (): INTEGER;
VAR
    r: Registers;

BEGIN
$IF (DOS32)
    (* 0400h is not a call DOS32 answers - it is reflected into real mode,
       where this client dies - so what comes back here is the extender's own
       version call instead, the one it does answer. A caller gets DOS32's
       version (330H for DOS32 3.3) where it would get DPMI's on the other
       targets; both are the number the extender reports for itself, which is
       what the name of this procedure is about. *)
    Zero(r);
    r.EAX := 0EE00H;
    Int31(SYSTEM.ADR(r));
    RETURN r.EAX MOD 10000H
$ELSE
    Zero(r);
    r.EAX := 400H;
    Int31(SYSTEM.ADR(r));
    RETURN r.EAX MOD 10000H
$END
END DpmiVer;


$IF (DOS32)

(* Give back the block the extender handed out last (int 31h AX=EE40h). This
   allocator keeps no handles at all: EE42h hands out a block and EE40h takes
   back whichever block was handed out most recently, with nothing to say
   which one that was. So the only block that can be undone is the one just
   made, and that is how the two callers below use it - one asked for more
   than the machine has and got a smaller block for its trouble, the other
   asked for far more than that just to be told the size. Both undo before
   they return, so that what they leave behind is the allocation state they
   found. *)
PROCEDURE UndoAlloc;
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 0EE40H;
    Int31(SYSTEM.ADR(r))
END UndoAlloc;

$END


(* DPMI int 31h AX=0500h: how much memory is left. The host fills a 48-byte
   record whose first dword is the largest block it can still allocate. That
   is the figure to ask 0501h for; a size picked in advance would either be
   refused or leave memory the host could have given us unused. Returns 0 if
   the host does not answer. *)
PROCEDURE DpmiMaxFree* (): INTEGER;
$IF (DOS32)
VAR
    r: Registers;

BEGIN
    (* There is no 0500h record to read here, so the size is asked for the
       other way round: EE42h is given a size no machine can meet, and answers
       in EAX with the largest one it can - a 4 KB multiple, the same figure
       0500h would have reported. That request did not fail outright, it was
       partly met, so EAX is also what has to be given back; EAX = 0 is the
       one answer that means nothing was allocated and so nothing may be
       undone. What is left in EDX - the block that was allocated and undone -
       is of no interest here and is not read. *)
    Zero(r);
    r.EAX := 0EE42H;
    r.EDX := 7FFFF000H;
    Int31(SYSTEM.ADR(r));
    IF r.EAX # 0 THEN UndoAlloc END;

    RETURN r.EAX
$ELSE
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
$END
END DpmiMaxFree;


(* DPMI int 31h AX=0501h: allocate linear memory.
   Input size in BX:CX (BX high, CX low);
   output linear address in BX:CX, handle in SI:DI. *)
PROCEDURE DpmiAlloc* (size: INTEGER; VAR addr, handle, cf, err: INTEGER);
$IF (DOS32)
VAR
    r: Registers;

BEGIN
    (* EE42h takes the size in EDX and answers with the block's near pointer in
       EDX - an address this program can use as it stands, the extender having
       based its selector at the program - and the size it actually gave in
       EAX. The carry says whether the request was met: clear, and the block is
       the size that was asked for; set, and it is EAX bytes, a smaller block
       handed over rather than a refusal.

       There is no handle to hand back - 0502h takes one and this extender has
       no such call - so handle is 0, and the caller's answer is the carry and
       the error code, exactly as on the other targets. A block that came back
       short is not used: the caller asked for a size and, as far as it can
       tell, did not get it, so the block is given back and the failure is
       reported as error 8, "insufficient memory". API.SetupHeap retries with
       half the size, and a second, successful call is then what the heap is
       built on. Undoing first is what keeps that retry from allocating on top
       of a block nobody holds. *)
    Zero(r);
    r.EAX := 0EE42H;
    r.EDX := size;
    Int31(SYSTEM.ADR(r));
    IF ORD(r.Flags) MOD 2 = 0 THEN
        addr := r.EDX;
        handle := 0;
        cf := 0;
        err := 0
    ELSE
        IF r.EAX # 0 THEN UndoAlloc END;
        addr := 0;
        handle := 0;
        cf := 1;
        err := 8
    END
$ELSE
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
$END
END DpmiAlloc;


(* DPMI int 31h AX=0502h: free linear memory. Handle in SI:DI.

   Only a block the caller took with DpmiAlloc may be freed here. The process
   heap is one such number that must not be: the host releases every block a
   client owns when the client ends, and freeing that one first faults in the
   host, which is why API.FreeHeap lets its handle go unclosed rather than
   spending it here (API.mod, and HDPMI\I31MEM.ASM). *)
PROCEDURE DpmiFree* (handle: INTEGER);
$IF (DOS32)
BEGIN
    (* No handle is asked for and none can be honoured: this extender frees the
       preceding allocation and there is no way to name another (UndoAlloc).
       Every caller here has just allocated what it is freeing, which is the
       one case EE40h can serve, and the argument is ignored rather than
       refused - a handle is 0 on this target anyway. *)
    UndoAlloc
$ELSE
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 502H;
    r.ESI := handle DIV 10000H;
    r.EDI := handle MOD 10000H;
    Int31(SYSTEM.ADR(r))
$END
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
        IF chunk > LOW_STAGE_LEN THEN chunk := LOW_STAGE_LEN END;
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
   its own DOS output continue from there. The area is below 1 MB, so on Adam
   each address is the one this program can name (see the module header). *)

PROCEDURE ScrCols* (): INTEGER;
VAR
    c: CHAR;
    n: INTEGER;

BEGIN
    SYSTEM.GET(BDA_COLS - progBase, c);
    n := ORD(c);
    IF n < 1 THEN n := 80 END;

    RETURN n
END ScrCols;


PROCEDURE ScrRows* (): INTEGER;
VAR
    c: CHAR;
    n: INTEGER;

BEGIN
    SYSTEM.GET(BDA_ROWS - progBase, c);
    n := ORD(c);
    IF n < 1 THEN n := 25 ELSE INC(n) END;

    RETURN n
END ScrRows;


(* Text video memory, as the address this program has to name it by: `VID`
   everywhere but Adam, where the client's segment is based at progBase and the
   screen is therefore `VID - progBase`, the same arithmetic every other
   below-1 MB address in this module is named with.

   It is handed out rather than kept private because a screen is a run of bytes
   and a redraw is one move per row, so a caller that wants the whole row in one
   SYSTEM.MOVE needs the address and not a call per cell.  What such a caller
   must not do is write the bare 0B8000h: on Adam that reaches memory nobody is
   displaying, and reading the screen back reaches the same place, so the
   program draws a perfect picture into a place no one can see and its own
   dumps still agree with a working build's.  Take the address from here. *)
PROCEDURE Video* (): INTEGER;
VAR
    p: INTEGER;

BEGIN
    p := VID - progBase;

    RETURN p
END Video;


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
    SYSTEM.GET(BDA_CURS - progBase, c);     x := ORD(c);
    SYSTEM.GET(BDA_CURS + 1 - progBase, c); y := ORD(c)
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
    c := CHR(x MOD 256); SYSTEM.PUT(BDA_CURS - progBase, c);
    c := CHR(y MOD 256); SYSTEM.PUT(BDA_CURS + 1 - progBase, c);
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


(* The eighth bit of an attribute byte.

   Four bits of a cell's attribute are the foreground and three are the
   background, which leaves one over - and that one is read by the adapter as
   blink, so a background of eight or more is not a colour but a cell that
   flashes.  Asking the BIOS for intensity instead is what gives the background
   a fourth bit: the sixteen colours are then sixteen on both sides of the cell
   and nothing flickers.  A program that wants a light background has no other
   way to say so, and one that has asked for it owes the next program the bit
   back - which is why this is a call and not a state the runtime remembers. *)
PROCEDURE SetBlink* (on: BOOLEAN);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 1003H;                 (* AH=10h AL=03h: the blink/intensity bit *)
    IF on THEN r.EBX := 1 ELSE r.EBX := 0 END;
    Intr(10H, r)
END SetBlink;


(* Blank the screen in the given attribute and home the cursor. *)
PROCEDURE ClearScr* (a: INTEGER);
VAR
    n, p: INTEGER;
    w: WCHAR;

BEGIN
    w := WCHR(a MOD 256 * 100H + SPACE);
    n := ScrCols() * ScrRows();
    p := VID - progBase;
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
    SYSTEM.MOVE(VID + cols * 2 - progBase, VID - progBase, (rows - 1) * cols * 2);
    w := WCHR(a MOD 256 * 100H + SPACE);
    n := cols;
    p := VID + (rows - 1) * cols * 2 - progBase;
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
            p := VID + (y * cols + x) * 2 - progBase;
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
   goes in DS:ESI, so it is copied into the block and pointed at there.

   AH=3Dh opens an existing file and AH=3Ch creates one; both take the name at
   DS:DX instead of DS:ESI, which is the only difference that matters here,
   and neither has anything to do with the action word, which is what tells
   the two apart. *)
PROCEDURE OpenLFN (name, access, action: INTEGER; VAR h: INTEGER);
VAR
    r: Registers;

BEGIN
    LowName(name);
    Zero(r);
    r.Flags := WCHR(CARRY);
    r.EAX := 716CH;
    r.EBX := access;
    r.ECX := 0;                         (* attributes *)
    r.EDX := action;
    r.EDI := 0;                         (* no alias hint *)
    r.ESI := LOW_NAME;
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        Zero(r);
        IF action = 1 THEN
            r.EAX := 3D00H + access MOD 256
        ELSE
            r.EAX := 3C00H
        END;
        r.ECX := 0;                     (* attributes, which only 3Ch reads *)
        r.EDX := LOW_NAME;
        Intr(21H, r)
    END;
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

   AH=4300h is the same call for a host without LFN support and answers with
   the same byte in the same register. The LFN form is measured to reach a long
   name that the 8.3 form does not, and both are measured to answer for a short
   one, so the LFN call is the one tried first. *)
PROCEDURE FileAttr* (name: INTEGER; VAR a: INTEGER);
VAR
    r: Registers;

BEGIN
    LowName(name);
    Zero(r);
    r.Flags := WCHR(CARRY);
    r.EAX := 7143H;
    r.EDX := LOW_NAME;
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        Zero(r);
        r.EAX := 4300H;
        r.EDX := LOW_NAME;
        Intr(21H, r)
    END;
    IF ORD(r.Flags) MOD 2 # 0 THEN
        a := -1
    ELSE
        a := r.ECX MOD 10000H
    END
END FileAttr;


(* AH=7141h: delete. The name goes in DS:EDX, which for a real mode service
   means a segment and an offset, so it is copied into the block like every
   other name.

   The 8.3 form AH=41h is not the same call with a shorter name: measured under
   DOSBox-X with LFN on, it answers error 2, "file not found", for a long name
   - while deleting the file's short alias succeeds - and the same file goes
   away through AH=7141h. Both forms delete a short name, so the older call
   behind the newer one covers every DOS that has no newer one. *)
PROCEDURE FileDelete* (name: INTEGER): BOOLEAN;
VAR
    r: Registers;

BEGIN
    LowName(name);
    Zero(r);
    r.Flags := WCHR(CARRY);
    r.EAX := 7141H;
    r.EDX := LOW_NAME;
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        Zero(r);
        r.EAX := 4100H;
        r.EDX := LOW_NAME;
        Intr(21H, r)
    END;
    RETURN ORD(r.Flags) MOD 2 = 0
END FileDelete;


(* AH=7156h: rename a file, and AH=56h for a host without LFN support. Both
   take the two names at once - the old one at DS:DX and the new one at ES:DI -
   which makes this the one call here that is pointed at two strings. Both have
   to be in the block, which is why the path buffer holds two names: the old one
   is staged at its start by LowNameAt and the new one at LOW_NAME2 by LowName2,
   one half of the buffer each, and the block's segment reaches both - Intr
   leaves DS and ES at it when the caller does not name a segment, and this
   caller does not.

   The 8.3 form behind the LFN one takes the same two pointers and differs in
   nothing but the function number. The LFN call is tried first and judged by
   the carry flag, which is set before it: the LFN subfunctions are the only
   ones that reach a long name, and a host that has none answers them with
   7100h and the carry set, which is what sends the call down the older path.

   Parameters: oldname - the name to change; newname - the name to change it to.
   Result: TRUE when the service renamed it. *)
PROCEDURE Rename* (oldname, newname: INTEGER): BOOLEAN;
VAR
    r: Registers;

BEGIN
    LowNameAt(oldname, LOW_NAME, LOW_HALF);
    LowName2(newname);
    Zero(r);
    r.Flags := WCHR(CARRY);
    r.EAX := 7156H;
    r.EDX := LOW_NAME;
    r.EDI := LOW_NAME2;
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        Zero(r);
        r.EAX := 5600H;
        r.EDX := LOW_NAME;
        r.EDI := LOW_NAME2;
        Intr(21H, r)
    END;
    RETURN ORD(r.Flags) MOD 2 = 0
END Rename;


(* AH=7139h: make a directory, and AH=39h for a host without LFN support. The
   name is at DS:EDX in both, so nothing moves but the function number. *)
PROCEDURE MkDir* (name: INTEGER): BOOLEAN;
VAR
    r: Registers;

BEGIN
    LowName(name);
    Zero(r);
    r.Flags := WCHR(CARRY);
    r.EAX := 7139H;
    r.EDX := LOW_NAME;
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        Zero(r);
        r.EAX := 3900H;
        r.EDX := LOW_NAME;
        Intr(21H, r)
    END;
    RETURN ORD(r.Flags) MOD 2 = 0
END MkDir;


(* AH=713Ah removes a directory, AH=3Ah on a host that has no LFN form. *)
PROCEDURE RmDir* (name: INTEGER): BOOLEAN;
VAR
    r: Registers;

BEGIN
    LowName(name);
    Zero(r);
    r.Flags := WCHR(CARRY);
    r.EAX := 713AH;
    r.EDX := LOW_NAME;
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        Zero(r);
        r.EAX := 3A00H;
        r.EDX := LOW_NAME;
        Intr(21H, r)
    END;
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
        IF chunk > LOW_STAGE_LEN THEN
            chunk := LOW_STAGE_LEN
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
        IF chunk > LOW_STAGE_LEN THEN
            chunk := LOW_STAGE_LEN
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


(* AH=7140h: give the file behind an open handle a new length, and, behind it,
   the two classic calls that do the same job for a host without the LFN
   services: AH=42h moves the file pointer to that length and the write of no
   bytes that follows it, AH=40h with CX=0, marks the end of the file there.
   DOS cuts a file as readily as it extends one, filling what it adds with
   zeros, so a smaller and a larger length are both reached.

   The LFN call takes the handle in BX and the length as a 64-bit value at
   ES:DI - the block again, holding the length in its low half and zero in its
   high one. The 8.3 path has no such call and is given the length in CX:DX
   instead, the form FileSeek above already writes.

   A position belongs to the handle and not to the file, so it is saved before
   the call and put back after it: the classic path has just moved it to the
   new end, and there is nothing that says the LFN one leaves it alone. The
   first seek is also what reports the position, and a handle DOS will not seek
   is a handle this call refuses.

   Parameters: h - the open handle; size - the length to leave the file with.
   Result: TRUE when the file is that long and the handle sits where it did;
   FALSE for a size below zero and for a handle DOS does not take. *)
PROCEDURE Truncate* (h, size: INTEGER): BOOLEAN;
VAR
    r: Registers;
    pos, at, hi: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    IF size >= 0 THEN
        FileSeek(h, 0, 1, pos);         (* where the caller had left it *)
        IF pos >= 0 THEN
            hi := 0;                    (* a length is not negative here *)
            SYSTEM.PUT(lowLin + LOW_DATA, size);
            SYSTEM.PUT(lowLin + LOW_DATA + 4, hi);
            Zero(r);
            r.Flags := WCHR(CARRY);
            r.EAX := 7140H;
            r.EBX := h;
            r.EDI := LOW_DATA;
            Intr(21H, r);
            IF ORD(r.Flags) MOD 2 # 0 THEN
                FileSeek(h, size, 0, at);
                IF at = size THEN       (* DOS has to be at the new end *)
                    Zero(r);
                    r.EAX := 4000H;
                    r.EBX := h;
                    r.ECX := 0;
                    r.EDX := LOW_DATA;
                    Intr(21H, r)
                END
            END;
            ok := ORD(r.Flags) MOD 2 = 0;
            FileSeek(h, pos, 0, at);
            IF at # pos THEN
                ok := FALSE
            END
        END
    END;

    RETURN ok
END Truncate;


(* The current directory of a drive, as a NUL terminated string without the
   drive letter, in dest. DOS writes it to DS:ESI - the block again - and it is
   copied out to the caller afterwards.

   drive is the 0-based index GetDrive hands back (0 = A:), and DOS wants the
   number one above that (0 = the default drive) - which is why it is the
   caller's drive and not simply 0. An empty string comes back when the drive
   has no directory to report, the usual case being a drive that is not
   there. *)
PROCEDURE GetCurDir* (dest, max, drive: INTEGER);
VAR
    r: Registers;
    i: INTEGER;
    c: CHAR;

BEGIN
    (* Two forms of "get current directory", LFN first: AH=7147h and, behind
       it, the older AH=47h for a host that does not carry the LFN services.
       The name is written to DS:ESI in both - there is no register to move -
       and the second call is only made when the first one fails.

       max is the room at dest INCLUDING the terminator, and what is written
       is cut to it.  Nothing the service is given says how much room there
       is, so a caller that passed a buffer and no length would be one service
       answer away from a buffer overrun; the copy below is therefore made
       through the block, whose length is known, rather than by handing DOS
       the caller's buffer.

       The answer is the path with NO drive letter and NO leading separator,
       and it is EMPTY for the root of a drive - so a caller that wants an
       absolute path writes the letter, the colon and a separator first and
       lets this fill in what follows, which for a root is nothing at all.
       A drive that is not there answers empty as well, and so does a host
       that has neither service. *)
    Zero(r);
    r.Flags := WCHR(CARRY);
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
        WHILE (c # 0X) & (i < LOW_NAME_LEN - 1) & (i < max - 1) DO
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


(* DriveExists - whether the machine has the drive d, 0 for A:.

   AH=36h is "free space on a drive".  A drive that is not there answers
   0FFFFH in AX, and - measured under DOSBox-X on 2026-09-26 - asking about a
   drive does NOT move the default one, so a caller may walk every letter
   without ending up on another drive.  That is the whole of the test, and the
   scan is what Dirs.Drives is built from, because DOS has no call that lists
   its drives: the one that looks like it, AH=0Eh, answers the number of the
   LAST drive letter on this host (26, for Z:) and not a count, so nothing
   here uses it.

   A drive whose media is not in the machine answers 0FFFFH too, so a floppy
   drive with no disk in it reads as not there.  That is the reading that
   costs a caller least: the alternative is a drive it can offer and cannot
   read.  The free space numbers AH=36h also returns are ignored - a full
   disk is not a drive that is missing. *)
PROCEDURE DriveExists* (d: INTEGER): BOOLEAN;
VAR
    r: Registers;
    ax: INTEGER;

BEGIN
    Zero(r);
    r.EAX := 3600H;
    r.EDX := d + 1;
    Intr(21H, r);
    ax := r.EAX MOD 10000H;

    RETURN ax # 0FFFFH
END DriveExists;


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


(* AH=5700h: the date and time a file was last written. The service answers
   with the two 16-bit DOS fields the packed value of this pair is made of, the
   time word in CX and the date word in DX, and this procedure puts the date
   word in the high half of the result and the time word in the low one:
   seconds DIV 2 land in bits 0..4 and year - 1980 in bits 25..31. (HX's own
   GetFileTime reads the same call the same way: CX is the time and DX the
   date.)

   The service is given a handle, not a name, and DOS has no path-taking form of
   it in either its classic or its LFN shape - the LFN call that answers for a
   handle, AH=71A6h, hands back a Win32-style structure rather than these two
   words, and has no counterpart for setting them. A name is therefore opened
   first, and through OpenLFN, so that the long name is reached and the handle
   is one DOS itself gave for it; it is closed again on both paths, so nothing
   is left open behind a call that failed.

   Parameters: name - the file to read the time of. time - receives the packed
   date and time. Result: TRUE when the file exists and the service answered;
   FALSE when it does not, which is the open failing, and also for a directory,
   which DOS does not open as a file. *)
PROCEDURE GetFileTime* (name: INTEGER; VAR time: INTEGER): BOOLEAN;
VAR
    r: Registers;
    h: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    time := 0;
    OpenLFN(name, 0, 1, h);             (* read access, the file as it is *)
    IF h # -1 THEN
        Zero(r);
        r.EAX := 5700H;
        r.EBX := h;
        Intr(21H, r);
        IF ORD(r.Flags) MOD 2 = 0 THEN
            time := r.EDX * 10000H + r.ECX;
            ok := TRUE
        END;
        FileClose(h)
    END;

    RETURN ok
END GetFileTime;


(* AH=5701h: set the date and time a file was last written. The two words go
   back where they came from - the time word in CX, the date word in DX - so the
   packed value is split into them again, with DIV and MOD rather than bit
   fields: this runtime divides towards minus infinity, so both words come out
   right even for a date far enough ahead to have put the sign bit of the packed
   value in use.

   The file has to be opened first, like GetFileTime above and for the same
   reason, and it is opened for reading and writing rather than read only,
   because setting a stamp is a write to the file. A file DOS will not open that
   way - a read-only one - is therefore reported as one it did not stamp.

   Parameters: name - the file to stamp; time - the packed date and time to set.
   Result: TRUE when the service set it. *)
PROCEDURE SetFileTime* (name, time: INTEGER): BOOLEAN;
VAR
    r: Registers;
    h: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    OpenLFN(name, 2, 1, h);             (* read and write, the file as it is *)
    IF h # -1 THEN
        Zero(r);
        r.EAX := 5701H;
        r.EBX := h;
        r.ECX := time MOD 10000H;
        r.EDX := time DIV 10000H;
        Intr(21H, r);
        ok := ORD(r.Flags) MOD 2 = 0;
        FileClose(h)
    END;

    RETURN ok
END SetFileTime;


(* The ASCIZ string at off in the block, copied out to adr and terminated
   there: the block's half of LowNameAt, and bounded the same way twice over -
   by the field the string lives in and by the room the caller has for it. The
   field bound is what keeps a missing terminator from running off the end of
   the find area; the caller's is what keeps this from running off the end of
   whatever record it was handed.

   adr is an address and not an offset, so the same procedure copies into a
   caller's record and into the block: lowLin + off is what a copy that stays
   inside the find area is given. *)
PROCEDURE LowGrab (off, adr, srcmax, max: INTEGER);
VAR
    i: INTEGER;
    c: CHAR;

BEGIN
    IF srcmax < max THEN max := srcmax END;
    i := 0;
    SYSTEM.GET(lowLin + off + i, c);
    WHILE (c # 0X) & (i < max - 1) DO
        SYSTEM.PUT(adr + i, c);
        INC(i);
        SYSTEM.GET(lowLin + off + i, c)
    END;
    c := 0X;
    SYSTEM.PUT(adr + i, c)
END LowGrab;


(* A field of the block, for the two DOS structures a walk reads. Both carry
   their numbers in the order every DOS structure does - low byte first - and
   the attribute is the low byte of a dword in the LFN block and a byte of its
   own in the DTA, which is why it is read a byte at a time in both. *)
PROCEDURE LowByte (off: INTEGER): INTEGER;
VAR
    c: CHAR;

BEGIN
    SYSTEM.GET(lowLin + off, c);
    RETURN ORD(c)
END LowByte;


PROCEDURE LowWord (off: INTEGER): INTEGER;
BEGIN
    RETURN LowByte(off) + LowByte(off + 1) * 100H
END LowWord;


PROCEDURE LowLong (off: INTEGER): INTEGER;
BEGIN
    RETURN LowWord(off) + LowWord(off + 2) * 10000H
END LowLong;


(* AH=1Ah, once at the start of a walk: point DOS at the DTA in the find area.

   It is set for both walks and not only for the classic one. The classic walk
   fills that address as its result and keeps its search state in it between
   calls, and the LFN walk asks the same classic API for each entry's stamp,
   whose answer arrives there too. Asking for a stamp before the DTA has been
   pointed anywhere is the mistake this costs one call to avoid: the answer
   lands in the program's own default DTA, which the walk never looks at, and
   every entry comes back with no date. *)
PROCEDURE FindDta;
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 1A00H;
    r.EDX := LOW_DTA;
    Intr(21H, r)
END FindDta;


(* AH=71A1h: end an LFN search. The handle goes in BX and there is nothing to
   read back. Closing one that is not open is refused rather than fatal -
   measured under DOSBox-X, a second close answers AX=0006 with the carry set -
   which is why every caller here asks whether the walk is still open first. *)
PROCEDURE FindCloseLFN (h: INTEGER);
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 71A1H;
    r.EBX := h;
    Intr(21H, r)
END FindCloseLFN;


(* The path a walk is started on, built in the find area: the directory the
   caller named, a separator when it did not end in one, and *.* - see
   FIND_ATTR for why the caller's own mask never reaches DOS.

   A directory that already ends in the separator, or in the colon of a drive
   letter, is not given a second one; an empty name is the current directory
   and gets no separator either.

   What comes back is where the *.* begins. That offset is what lets an entry's
   name be written over the mask later on, which is how the stamp below is
   asked for a path and not for a bare name: AH=4Eh searches the current
   directory of the current drive unless the mask carries a path of its own, so
   a walk of anywhere but the current directory would ask about the wrong
   directory - and find a file of the same name in it, or nothing.

   The name is cut at LOW_PATH_LEN - 20 rather than at the buffer's end, so
   that even a directory that fills it leaves room for the separator, the mask
   and an entry's name after them. *)
PROCEDURE FindPath (dir: INTEGER): INTEGER;
VAR
    i, tail: INTEGER;
    c: CHAR;

BEGIN
    LowNameAt(dir, LOW_PATH, LOW_PATH_LEN - 20);
    i := 0;
    SYSTEM.GET(lowLin + LOW_PATH + i, c);
    WHILE c # 0X DO
        INC(i);
        SYSTEM.GET(lowLin + LOW_PATH + i, c)
    END;
    IF i > 0 THEN
        SYSTEM.GET(lowLin + LOW_PATH + i - 1, c);
        IF (c # "\") & (c # ":") THEN
            c := "\";
            SYSTEM.PUT(lowLin + LOW_PATH + i, c);
            INC(i)
        END
    END;
    tail := i;
    c := "*"; SYSTEM.PUT(lowLin + LOW_PATH + i, c); INC(i);
    c := "."; SYSTEM.PUT(lowLin + LOW_PATH + i, c); INC(i);
    c := "*"; SYSTEM.PUT(lowLin + LOW_PATH + i, c); INC(i);
    c := 0X;  SYSTEM.PUT(lowLin + LOW_PATH + i, c);
    RETURN tail
END FindPath;


(* The last-write stamp of the entry an LFN walk is holding, as the packed local
   word the rest of this tree uses (Files.DosTime, and every ArchFile's own
   conversion), or 0 when the call did not answer.

   The LFN block has a FILETIME of its own and it is not used, because it is a
   UTC instant and DOS has no conversion: measured under DOSBox-X with LFN on,
   AX=71A7h in two plausible shapes and AX=71A8h all return with the carry
   clear and convert nothing at all, and AX=71A6h fails with AX=0008. What is
   used instead is the classic call - AH=4Eh on the entry's own name, whose
   answer in the DTA is already the packed local word. The name handed over is
   cAlternateFileName when the block filled that in and cFileName otherwise:
   they are the same entry, one of them in the form the classic side can match,
   and the alias is empty exactly when the name is already 8.3.

   A directory has no other source at all. AH=57h accepts a long name when LFN
   is on but fails on a directory in every form tried, while AH=4Eh answers for
   all of them - so this one call covers files and directories alike.

   The name is written over the *.* that ends the walk's path, which is what
   makes it a path: the directory the walk is in, then the entry. It leaves the
   path buffer alone, and it is measured not to disturb the open LFN search -
   the classic API keeps its state in the DTA and the LFN walk's is in the
   handle DOS gave out. *)
PROCEDURE FindStamp (VAR f: Find): INTEGER;
VAR
    r: Registers;
    dst, t: INTEGER;

BEGIN
    dst := lowLin + LOW_PATH + f.tail;
    IF LowByte(LOW_FBLK + FBLK_ALT) # 0 THEN
        LowGrab(LOW_FBLK + FBLK_ALT, dst, FBLK_ALT_LEN,
                LOW_PATH_LEN - f.tail)
    ELSE
        LowGrab(LOW_FBLK + FBLK_NAME, dst, FBLK_NAME_LEN,
                LOW_PATH_LEN - f.tail)
    END;
    Zero(r);
    r.EAX := 4E00H;
    r.ECX := FIND_ATTR;
    r.EDX := LOW_PATH;
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 # 0 THEN
        t := 0
    ELSE
        t := LowWord(LOW_DTA + DTA_DATE) * 10000H + LowWord(LOW_DTA + DTA_TIME)
    END;

    RETURN t
END FindStamp;


(* Start a walk of the directory dir, which is ASCIZ and may or may not end in a
   separator. TRUE when there is an entry to read, FALSE for a directory that is
   not there and for one that is empty - the two are the same answer, as they
   are to any caller of this.

   The LFN walk is tried first and judged by the carry flag, which is set before
   the call: a host without the LFN subfunctions answers 714Eh with 7100h and
   the carry set, and the classic walk behind it is the same two calls the file
   services above fall back to - AH=1Ah once, then AH=4Eh - with an 8.3 name in
   the DTA instead of a long one in the block.

   The entry that was found is left where it was delivered and is read by the
   FindNext that follows, not here: both walks deliver an entry per call and
   both overwrite the previous one, so reading and advancing are one step and
   belong together.

   The mask goes in DS:DX, not in DS:SI, which is the one thing about this call
   that has to be measured rather than read off a specification - the LFN find
   is documented with an SI form and DOSBox-X does not answer that one. A mask
   at DS:SI is not seen at all: the call reads whatever is at DS:DX, so with DX
   left at zero it reads the empty string at the block's first byte and answers
   AX=0012h, "no more files", which reads exactly like a directory with nothing
   in it. The SI form is the shape this was first written in, and the symptom
   was a walk that silently fell through to the classic 8.3 leg for every
   directory on every run. *)
PROCEDURE FindFirst* (dir: INTEGER; VAR f: Find): BOOLEAN;
VAR
    r: Registers;

BEGIN
    f.tail := FindPath(dir);
    f.handle := FIND_NONE;
    FindDta;
    Zero(r);
    r.Flags := WCHR(CARRY);
    r.EAX := 714EH;
    r.ECX := FIND_ATTR;
    r.EDX := LOW_PATH;                  (* DS:DX, the mask - not DS:SI *)
    r.EDI := LOW_FBLK;                  (* ES:DI, the 323 byte block *)
    Intr(21H, r);
    IF ORD(r.Flags) MOD 2 = 0 THEN
        f.handle := r.EAX MOD 10000H
    ELSE
        Zero(r);
        r.EAX := 4E00H;
        r.ECX := FIND_ATTR;
        r.EDX := LOW_PATH;
        Intr(21H, r);
        IF ORD(r.Flags) MOD 2 = 0 THEN f.handle := FIND_CLASSIC END
    END;

    RETURN f.handle # FIND_NONE
END FindFirst;


(* The entry the last call delivered, and then the walk is moved on.

   Reading before advancing is not a choice - each of the calls that finds the
   next entry writes over the one before it - and it is why the name, the
   attribute, the size and the stamp are all taken before the advance below.

   When the walk runs out the LFN search is closed here rather than left for
   FindClose, because a caller that reads every entry and stops would otherwise
   leave a DOS handle open for the life of the program. FindClose then finds a
   handle of FIND_NONE and leaves it alone, so the two do not close twice.

   The classic walk needs no such care: its state is the DTA, which the block
   owns anyway. *)
PROCEDURE FindNext* (VAR f: Find; namadr, namemax: INTEGER;
                     VAR attr, size, time: INTEGER): BOOLEAN;
VAR
    r: Registers;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    attr := 0; size := 0; time := 0;
    IF f.handle >= 0 THEN
        ok := TRUE;
        LowGrab(LOW_FBLK + FBLK_NAME, namadr, FBLK_NAME_LEN, namemax);
        attr := LowByte(LOW_FBLK + FBLK_ATTR);
        size := LowLong(LOW_FBLK + FBLK_SIZE);
        time := FindStamp(f);
        Zero(r);
        r.Flags := WCHR(CARRY);
        r.EAX := 714FH;
        r.EBX := f.handle;              (* the handle goes back in BX *)
        r.EDI := LOW_FBLK;
        Intr(21H, r);
        IF ORD(r.Flags) MOD 2 # 0 THEN
            FindCloseLFN(f.handle);
            f.handle := FIND_NONE
        END
    ELSIF f.handle = FIND_CLASSIC THEN
        ok := TRUE;
        LowGrab(LOW_DTA + DTA_NAME, namadr, DTA_NAME_LEN, namemax);
        attr := LowByte(LOW_DTA + DTA_ATTR);
        size := LowLong(LOW_DTA + DTA_SIZE);
        time := LowWord(LOW_DTA + DTA_DATE) * 10000H +
                LowWord(LOW_DTA + DTA_TIME);
        Zero(r);
        r.EAX := 4F00H;
        r.ECX := FIND_ATTR;
        r.EDX := LOW_PATH;
        Intr(21H, r);
        IF ORD(r.Flags) MOD 2 # 0 THEN f.handle := FIND_NONE END
    END;

    RETURN ok
END FindNext;


(* End a walk. Idempotent: one that is already over - because it was read to the
   end, or because this was called twice, or because it never started - is left
   alone, and the classic walk needs nothing at all. *)
PROCEDURE FindClose* (VAR f: Find);
BEGIN
    IF f.handle >= 0 THEN FindCloseLFN(f.handle) END;
    f.handle := FIND_NONE
END FindClose;


(* Where the name of this program's file begins, or 0 when it cannot be had.

   On the DPMI targets the PE loader answers two int 21h calls that DKRNL32
   uses for the same purpose: AX=4B82h returns the handle of the main module in
   EAX, and AX=4B86h with that handle in EDX returns a flat pointer to the
   module's file name. Going through them is what keeps this module free of
   Win32 imports while still yielding the real program path: the environment
   segment of a client's PSP is empty, so the usual DOS route - the name that
   follows the environment block - is closed here.

   Adam needs neither call and has neither: the extender reported the path when
   the program started (AX=EE02h, in ECX), already in the form this program can
   read it in.

   Only the HX loader answers 4B82h and 4B86h. Both stubs of the third target
   carry a WDOSX kernel and WDOSX has neither call; it does not answer the
   DOS32 AX=EE02h either, even though the same kernel emulates the rest of the
   DOS32 API for an Adam image. Measured on a dpmi32le program: AX=4B82h leaves
   EAX at 4B82h with the carry set, and AX=EE02h does the same and leaves ECX
   as whatever it held before - so asking it would hand back a garbage pointer
   for the caller to walk. There is nothing else to ask: the environment
   segment is empty here, and an LE image carries its own module *name* but
   never the directory it was loaded from. So on this target ProgPath reports
   -1, and a lib\ lookup stays relative to the current directory. *)
PROCEDURE [stdcall] GetModuleName (VAR adr: INTEGER);
$IF (DOS32)
BEGIN
    adr := pathNear
$ELSE
BEGIN
    adr := 0;
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
$END
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
   with it.

   None of the four below has an Adam branch that reaches anything: DOS32 has
   no loader - it loads one program and that is the one already running - and
   the int 21h entries the loader answers belong to the DPMI extender's Dynamic
   Link Module. Asking for them there would not fail quietly either: on Adam
   they are reflected into real mode, where DOS sees them as its own EXEC and
   resource calls and acts on them, which is the last thing a client that
   wanted a DLL handle should cause. So each answers the "no module" its caller
   already has to handle, and a program that loads nothing portable works on
   both. *)
PROCEDURE [stdcall] LoadModule (nameadr: INTEGER; VAR h: INTEGER);
$IF (DOS32)
BEGIN
    h := 0
$ELSE
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
$END
END LoadModule;


(* EDX holds the export name's linear address. The loader treats a value whose
   high word is zero as an ordinal instead, which cannot happen for a string in
   this program's image or heap - those live far above 64K - so only the name
   form is reachable from here. *)
PROCEDURE [stdcall] GetProcAdr (h, nameadr: INTEGER; VAR adr: INTEGER);
$IF (DOS32)
BEGIN
    adr := 0
$ELSE
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
$END
END GetProcAdr;


(* AX=4B82h answers with the module-list entry for the name in EDX, or, when
   EDX is zero, for the module the current task was started from: the EXE. A
   DLL asks for it to reach what the EXE exports. *)
PROCEDURE [stdcall] GetMainModule (VAR h: INTEGER);
$IF (DOS32)
BEGIN
    h := 0
$ELSE
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
$END
END GetMainModule;


(* The carry flag is what FreeModule32 sets when the handle is not in the
   module list; EAX is not part of its answer, so it is turned into one here
   before popad puts the saved registers back. *)
PROCEDURE [stdcall] FreeModule (h: INTEGER; VAR ok: INTEGER);
$IF (DOS32)
BEGIN
    ok := 0
$ELSE
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
$END
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


(* The base of this program's PSP, as this program can address it, or 0 when it
   cannot be established. The PSP opens with a jump and its fields are read at
   fixed offsets from whatever this returns, so the only thing that matters
   about the two shapes it takes - a linear base on one target group and an
   offset into the program's own segment on the other - is that a field's
   address is this plus the field's offset.

   Two targets reach it two ways, because what DOS calls the current PSP is not
   this program under either of the DOS32 extenders: a program loaded by an
   extender is DOS's second program, the first being the extender's own stub,
   and a real mode service answers about the first. On the DPMI targets the PSP
   is still the right one - the host keeps DOS's idea of the current program in
   step - and int 21h AH=51h answers with it. Through Intr the answer is a real
   mode segment in BX, because what a reflected call returns is what the real
   mode handler left and a real mode handler has no selector to name a segment
   with; that suits this runtime, where the block runs with the flat relation
   lowLin = lowSeg * 16 (see the module header), so a segment is its own linear
   base times 16 and no selector translation is needed. Measured under DOSBox-X
   with the tail of a real command line: the segment answers, and the byte at
   segment * 16 + 80H is the length of the tail this program was started with.
   The same call reaches that PSP as int 21h AH=62h, so either service can be
   used; AH=51h is the one DOS documents.

   On Adam the answer comes from the extender instead (AX=EE02h), which is the
   only source that knows about the program DOS32 loaded rather than the stub
   DOS ran.

   A base of 0 is not a PSP and is reported as no answer at all - a base of 0
   would otherwise read as "the PSP is at address 0", which is the real mode
   interrupt table. *)
PROCEDURE PspBase (VAR base: INTEGER);
$IF (DOS32)
BEGIN
    IF pspNear = 0 THEN base := 0 ELSE base := pspNear END
$ELSE
VAR
    r: Registers;

BEGIN
    Zero(r);
    r.EAX := 5100H;                     (* AH=51h: the current PSP *)
    Intr(21H, r);
    IF r.EBX = 0 THEN base := 0 ELSE base := r.EBX * 16 END
$END
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


(* The address of the DOS environment block, as this program can address it, or
   0 when there is none.

   The PSP opens with a jump, and the word at offset 2Ch of it is the segment
   the environment lives in.  That the offset is a fixed one is the whole of
   the agreement here - it is older than any other part of the PSP and DOS
   itself never moved it - so the block is found through PspBase and, on the
   DPMI targets, the flat relation, exactly as the command tail is.

   On Adam the extender reports the environment at once (AX=EE02h, in EDI) and
   that is the address to use: the PSP here is the one DOS32 built rather than
   the one DOS built, and the word at 2Ch of it names the environment by a real
   mode segment, which is a form this program would have to translate. The
   answer from EE02h is already the form it wants, so what PspBase and the
   field would together spell out is read straight off the call instead.

   A segment of 0 means no block: the environment is a run of NUL terminated
   NAME=VALUE strings ended by a further NUL, and a block at address 0 would be
   the real mode interrupt table read as text. *)
PROCEDURE EnvPtr* (): INTEGER;
$IF (DOS32)
BEGIN
    RETURN envNear
$ELSE
VAR
    base, seg: INTEGER;
    w: WCHAR;

BEGIN
    PspBase(base);
    IF base = 0 THEN
        seg := 0
    ELSE
        (* The field is a word, and reading it into an INTEGER would take the
           word after it as well, so it is read as the 16 bits it is. *)
        SYSTEM.GET(base + PSP_ENV, w);
        seg := ORD(w)
    END;

    RETURN seg * 16
$END
END EnvPtr;


(* No block, so no interrupt can be reflected and no DOS call can be made at
   all: say so and stop. The message goes straight into video memory, which
   needs no DOS to write it, and the stop is Exit, which is the one call here
   that needs no block. *)
PROCEDURE NoBlock;
VAR
    msg: ARRAY 48 OF CHAR;
    i, p: INTEGER;

BEGIN
    msg := "DPMI32: no DOS memory for the interrupt block";
    p := VID + 2 * 80 * 10 - progBase;  (* the eleventh line of the screen *)
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
$IF (DOS32)
VAR
    r: Registers;

BEGIN
    (* There is nothing to allocate here: the extender lent the program its
       buffer when it started it, and reported it - and everything else a
       program needs to know about itself - in one call at that point. 8 KB at
       16 * AX is all the DOS memory this layer gets, and it is enough for what
       the buffer is for, because the call structure does not live in it (see
       the layout constants and Intr).

       The three near pointers are kept exactly as they come. They are offsets
       from the start of the program, this program's own selector is based
       there, so they address what they name as they stand and every field
       behind them is an ordinary SYSTEM.GET; that is also why lowLin is the
       buffer's linear address minus the base rather than the address itself.

       progBase is set before the buffer is tested: everything outside the
       program's own image - the BIOS data area and video memory that NoBlock
       writes into - is addressed as `linear - progBase`, and the one path that
       has no DOS call to fall back on is the one that needs the base most. *)
    Zero(r);
    r.EAX := 0EE02H;
    Int31(SYSTEM.ADR(r));
    lowSeg := r.EAX MOD 10000H;
    progBase := r.EBX;
    pspNear := r.ESI;
    envNear := r.EDI;
    pathNear := r.ECX;
    IF lowSeg = 0 THEN
        NoBlock                     (* says so and stops; it does not return *)
    END;
    lowLin := lowSeg * 16 - progBase;
    (* The structure's address is what the call needs and what the pointer to
       it is made from, and SYSTEM.VAL takes a designator rather than an
       expression, so it is read once into rmAdr and the pointer is that. *)
    rmAdr := SYSTEM.ADR(rmRec);
    rm := SYSTEM.VAL(CallP, rmAdr)
$ELSE
VAR
    sel, err: INTEGER;

BEGIN
    progBase := 0;                  (* this client runs at linear 0 *)
    AllocDOS9(LOW_BLOCK, lowSeg, sel, err);
    IF lowSeg = 0 THEN
        NoBlock                     (* says so and stops; it does not return *)
    END;
    lowLin := lowSeg * 16;          (* flat model: the linear base *)
    rm := SYSTEM.VAL(CallP, lowLin); (* the call structure, at LOW_RMCS = 0 *)
    rmAdr := lowLin + LOW_RMCS
$END
END GetBlock;


BEGIN
    GetBlock
END DOS.
