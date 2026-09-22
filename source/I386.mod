(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2018-2023, Anton Krotov
    All rights reserved.
*)

MODULE I386;

IMPORT SYSTEM, IL, REG, UTILS, LISTS, BIN, PE32, LE, ELF, PROG, SCAN,
       CHL := CHUNKLISTS, PATHS, TARGETS, ERRORS;


CONST

    eax = REG.R0; ecx = REG.R1; edx = REG.R2;

    al = eax; cl = ecx; dl = edx; ah = 4;

    ax = eax; cx = ecx; dx = edx;

    esp = 4;
    ebp = 5;

    MAX_FR = 7;

    sete = 94H; setne = 95H; setl = 9CH; setge = 9DH; setle = 9EH; setg = 9FH; setc = 92H; setnc = 93H;

    je = 84H; jne = 85H; jl = 8CH; jge = 8DH; jle = 8EH; jg = 8FH; jb = 82H; jnb = 83H;


    (* Bytes of code one node collects. OutByte fills the newest node until it
       holds CODECHUNK bytes and only then makes another, so this is the
       granularity of the code list and of nothing else: the bytes are emitted
       in list order whatever the nodes are, and the image is the same either
       way. A larger node means fewer of them for the writer to walk. *)
    CODECHUNK = 64;

    FPR_ERR = 41;

    (* What a node of the list stands for. The list holds one kind of record
       with a kind field rather than a record type per kind, so a walk tells the
       nodes apart by reading that field: the type tests it used to make cost a
       call into the runtime for every node, and for OutByte every byte. *)
    tCODE  = 0;
    tLABEL = 1;
    tJMP   = 2;
    tJCC   = 3;
    tCALL  = 4;
    tRELOC = 5;

    (* Nodes per chunk, and how many chunks the arena can hold: a self-host
       makes on the order of a hundred thousand nodes. See NODEBODY. *)
    SLOTS = 1024;
    MAXCHUNKS = 4096;


TYPE

    COMMAND = IL.COMMAND;

    (* One record type for every node of the list, told apart by its kind, and
       one pointer to it. The list used to hold a type per node kind - a code
       node, a label, a jump, a call, a relocation - and a walk had to ask each
       node what it was. Every such question is a guarded test, and a guarded
       test in this compiler is a call into the runtime that reads the tag in
       front of the record; OutByte asks on every byte it emits and the fixup
       walks ask once per node per pass, which is where the time was going.

       The kinds share the fields they need rather than each having its own
       layout. A node of any kind is carved out of a chunk (see NODEBODY and
       NewNode) and the arena hands back its index, so the list is a vector of
       nodes and a walk is an index running from zero, with no links to follow
       and no casts to make.

       The fixed part of a node is what the arena needs to carve it and what
       InsertNode needs to move it; the code bytes are the tail. *)
    NODEBODY = RECORD

        kind:   INTEGER;    (* tCODE ... tRELOC *)
        offset: INTEGER;    (* where the node begins in the section *)
        label:  INTEGER;    (* tLABEL: the label's value; tJMP/tJCC/tCALL: the label aimed at *)
        diff:   INTEGER;    (* tJMP/tJCC/tCALL: the signed distance to that label *)
        short:  BOOLEAN;    (* tJMP/tJCC/tCALL: whether the short form is in use *)
        jmp:    INTEGER;    (* tJCC: which condition *)
        op:     INTEGER;    (* tRELOC: which relocation *)
        value:  INTEGER;    (* tRELOC: the value to relocate *)
        len:    INTEGER;    (* tCODE: how many bytes of code are in use *)
        code:   ARRAY CODECHUNK OF BYTE

    END;

    NODE = POINTER TO NODEBODY;

    (* Every node used to be a block of its own on the heap, and a self-host
       makes hundreds of thousands of them. They are carved out of chunks
       instead, the way IL already carves its commands: a chunk is a single
       block as far as the heap is concerned and holds SLOTS nodes, so the
       allocator has far fewer blocks to walk past and far fewer headers to
       write - which is where the cost was.

       The chunks are held in one array and a node is named by its index in it,
       so the list walks by counting and no node needs a link or a tag. *)
    CHUNK = POINTER TO RECORD

        node: ARRAY SLOTS OF NODEBODY

    END;


VAR

    R: REG.REGS;

    program: BIN.PROGRAM;

    tcount, LocVarSize, mainLocVarSize: INTEGER;

    FR: ARRAY 1000 OF INTEGER;

    fname: PATHS.PATH;

    (* The place a floating point constant is emitted at, and the one the main
       body's constants are emitted at. A constant is not emitted where it is
       written but at the head of the procedure, whose stack frame the constant
       is read from, so its push goes at FltConstLabel and the pushes of a
       procedure follow one another from there: fltIns counts them. The two are
       node indices, and -1 stands for the head of a main body that has not
       begun; mainFltConstLabel, mainLocVarSize and mainFltIns are what this
       pair is saved in while a procedure body is being generated, since the
       procedures of Oberon-07 do not nest. *)
    FltConstLabel, mainFltConstLabel: INTEGER;
    fltIns, mainFltIns: INTEGER;

    chunks: ARRAY MAXCHUNKS OF CHUNK;   (* the chunks handed out, in order *)
    nchunks: INTEGER;                   (* how many of them there are *)
    ncount:  INTEGER;                   (* how many nodes the list holds *)
    last:    NODE;                      (* the newest node, for OutByte *)


(* Where a node is. The chunks are uniform, so its index alone says it: the
   chunk is the index divided by the slots in one, the slot the remainder. *)
PROCEDURE NodeAddr (i: INTEGER): INTEGER;
BEGIN
    RETURN SYSTEM.ADR(chunks[i DIV SLOTS].node[i MOD SLOTS])
END NodeAddr;


PROCEDURE NodeAt (i: INTEGER): NODE;
VAR
    adr: INTEGER;

BEGIN
    adr := NodeAddr(i);

    RETURN SYSTEM.VAL(NODE, adr)
END NodeAt;


(* How many of a chunk's slots hold a node. Every chunk but the last is full. *)
PROCEDURE Used (i: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF i = nchunks - 1 THEN
        res := ncount - i * SLOTS
    ELSE
        res := SLOTS
    END;

    RETURN res
END Used;


(* Make room for one more node at the end of the list. *)
PROCEDURE Grow;
BEGIN
    IF (nchunks = 0) OR (Used(nchunks - 1) = SLOTS) THEN
        ASSERT(nchunks < MAXCHUNKS);
        NEW(chunks[nchunks]);
        INC(nchunks)
    END
END Grow;


(* A node of the given kind with nothing else in it. The kinds share one record,
   so the fields another kind uses have to be cleared here. *)
PROCEDURE InitNode (n: NODE; kind: INTEGER);
BEGIN
    n.kind   := kind;
    n.offset := 0;
    n.label  := 0;
    n.diff   := 0;
    n.short  := FALSE;
    n.jmp    := 0;
    n.op     := 0;
    n.value  := 0;
    n.len    := 0
END InitNode;


PROCEDURE CopyNode (src, dst: INTEGER);
BEGIN
    SYSTEM.MOVE(NodeAddr(src), NodeAddr(dst), SYSTEM.SIZE(NODEBODY))
END CopyNode;


(* A fresh node of the given kind, at the end of the list. *)
PROCEDURE NewNode (kind: INTEGER): NODE;
VAR
    n: NODE;

BEGIN
    Grow;
    n := NodeAt(ncount);
    InitNode(n, kind);
    INC(ncount);
    last := n;

    RETURN n
END NewNode;


(* Open a place at the given index by moving the nodes from there to the end up
   by one slot. The list gains a node, which the caller fills in.

   One chunk at a time, from the top down. The nodes of a chunk are contiguous
   and a chunk above the one being shifted has already been shifted, so a full
   chunk simply hands its last node to the base of the chunk above - which the
   pass has already emptied. The chunks are not contiguous with one another, so
   every index has to be counted from the base of its own chunk: lo and hi are
   chunk-local here and only b, the base, is absolute.

   The nodes inside a chunk go one at a time and from the top down. Every one of
   them lands above where it was, and SYSTEM.MOVE copies towards the higher
   address, so a single move of the whole run would read what it had just
   written and smear each node over the next. *)
PROCEDURE ShiftUp (at: INTEGER);
VAR
    i, b, lo, hi, k: INTEGER;

BEGIN
    Grow;   (* room for the node the shift pushes out at the end *)

    i := (ncount - 1) DIV SLOTS;
    b := i * SLOTS;
    hi := Used(i);

    WHILE (i >= 0) & (b + hi > at) DO
        lo := at - b;
        IF lo < 0 THEN lo := 0 END;

        IF hi = SLOTS THEN
            CopyNode(b + hi - 1, b + hi);
            DEC(hi)
        END;

        k := hi;
        WHILE k > lo DO
            DEC(k);
            CopyNode(b + k, b + k + 1)
        END;

        DEC(i);
        b  := i * SLOTS;
        hi := Used(i)   (* i is -1 on the last turn, when no chunk is read *)
    END
END ShiftUp;


(* A fresh node of the given kind at the given index, the nodes from there on
   moving up to make room for it. *)
PROCEDURE InsertNode (at, kind: INTEGER): NODE;
VAR
    n: NODE;

BEGIN
    ShiftUp(at);
    n := NodeAt(at);
    InitNode(n, kind);
    INC(ncount);
    last := NodeAt(ncount - 1);

    RETURN n
END InsertNode;


(* Give the whole arena back and start an empty list. *)
PROCEDURE Reset;
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE i < nchunks DO
        DISPOSE(chunks[i]);
        chunks[i] := NIL;
        INC(i)
    END;

    nchunks := 0;
    ncount  := 0;
    last    := NIL;
    FltConstLabel := -1;
    mainFltConstLabel := -1;
    fltIns := 0;
    mainFltIns := 0
END Reset;


(* Nothing of the list survives a call, so this belongs at the end of a code
   generation and nowhere else. *)
PROCEDURE Free*;
BEGIN
    Reset
END Free;


PROCEDURE OutByte* (n: BYTE);
VAR
    c: NODE;

BEGIN
    c := last;   (* the node the bytes are being collected in, if there is one *)

    IF (c # NIL) & (c.kind = tCODE) & (c.len < CODECHUNK) THEN
        c.code[c.len] := n;
        INC(c.len)
    ELSE
        c := NewNode(tCODE);
        c.code[0] := n;
        c.len := 1
    END

END OutByte;


PROCEDURE OutInt (n: INTEGER);
BEGIN
    OutByte(n MOD 256);
    OutByte(UTILS.Byte(n, 1));
    OutByte(UTILS.Byte(n, 2));
    OutByte(UTILS.Byte(n, 3))
END OutInt;


PROCEDURE OutByte2 (a, b: BYTE);
BEGIN
    OutByte(a);
    OutByte(b)
END OutByte2;


PROCEDURE OutByte3 (a, b, c: BYTE);
BEGIN
    OutByte(a);
    OutByte(b);
    OutByte(c)
END OutByte3;


PROCEDURE OutWord (n: INTEGER);
BEGIN
    ASSERT((0 <= n) & (n <= 65535));
    OutByte2(n MOD 256, n DIV 256)
END OutWord;


PROCEDURE isByte* (n: INTEGER): BOOLEAN;
    RETURN (-128 <= n) & (n <= 127)
END isByte;


PROCEDURE short (n: INTEGER): INTEGER;
    RETURN 2 * ORD(isByte(n))
END short;


PROCEDURE long (n: INTEGER): INTEGER;
    RETURN 40H * ORD(~isByte(n))
END long;


PROCEDURE OutIntByte (n: INTEGER);
BEGIN
    IF isByte(n) THEN
        OutByte(n MOD 256)
    ELSE
        OutInt(n)
    END
END OutIntByte;


PROCEDURE shift* (op, reg: INTEGER);
BEGIN
    CASE op OF
    |IL.opASR, IL.opASR1, IL.opASR2: OutByte(0F8H + reg)
    |IL.opROR, IL.opROR1, IL.opROR2: OutByte(0C8H + reg)
    |IL.opLSL, IL.opLSL1, IL.opLSL2: OutByte(0E0H + reg)
    |IL.opLSR, IL.opLSR1, IL.opLSR2: OutByte(0E8H + reg)
    END
END shift;


PROCEDURE oprr (op: BYTE; reg1, reg2: INTEGER); (* op reg1, reg2 *)
BEGIN
    OutByte2(op, 0C0H + 8 * reg2 + reg1)
END oprr;


PROCEDURE mov (reg1, reg2: INTEGER); (* mov reg1, reg2 *)
BEGIN
    oprr(89H, reg1, reg2)
END mov;


PROCEDURE xchg (reg1, reg2: INTEGER); (* xchg reg1, reg2 *)
BEGIN
    IF eax IN {reg1, reg2} THEN
        OutByte(90H + reg1 + reg2)
    ELSE
        oprr(87H, reg1, reg2)
    END
END xchg;


PROCEDURE pop (reg: INTEGER);
BEGIN
    OutByte(58H + reg) (* pop reg *)
END pop;


PROCEDURE push (reg: INTEGER);
BEGIN
    OutByte(50H + reg) (* push reg *)
END push;


PROCEDURE xor (reg1, reg2: INTEGER); (* xor reg1, reg2 *)
BEGIN
    oprr(31H, reg1, reg2)
END xor;


PROCEDURE movrc (reg, n: INTEGER);
BEGIN
    IF n = 0 THEN
        xor(reg, reg)
    ELSE
        OutByte(0B8H + reg); (* mov reg, n *)
        OutInt(n)
    END
END movrc;


PROCEDURE pushc* (n: INTEGER);
BEGIN
    OutByte(68H + short(n)); (* push n *)
    OutIntByte(n)
END pushc;


PROCEDURE test (reg: INTEGER);
BEGIN
    OutByte2(85H, 0C0H + reg * 9)  (* test reg, reg *)
END test;


PROCEDURE neg (reg: INTEGER);
BEGIN
    OutByte2(0F7H, 0D8H + reg)  (* neg reg *)
END neg;


PROCEDURE not (reg: INTEGER);
BEGIN
    OutByte2(0F7H, 0D0H + reg)  (* not reg *)
END not;


PROCEDURE add (reg1, reg2: INTEGER); (* add reg1, reg2 *)
BEGIN
    oprr(01H, reg1, reg2)
END add;


PROCEDURE oprc* (op, reg, n: INTEGER);
BEGIN
    IF (reg = eax) & ~isByte(n) THEN
        CASE op OF
        |0C0H: op := 05H (* add *)
        |0E8H: op := 2DH (* sub *)
        |0F8H: op := 3DH (* cmp *)
        |0E0H: op := 25H (* and *)
        |0C8H: op := 0DH (* or  *)
        |0F0H: op := 35H (* xor *)
        END;
        OutByte(op);
        OutInt(n)
    ELSE
        OutByte2(81H + short(n), op + reg MOD 8);
        OutIntByte(n)
    END
END oprc;


PROCEDURE andrc (reg, n: INTEGER); (* and reg, n *)
BEGIN
    oprc(0E0H, reg, n)
END andrc;


PROCEDURE orrc (reg, n: INTEGER); (* or reg, n *)
BEGIN
    oprc(0C8H, reg, n)
END orrc;


PROCEDURE xorrc (reg, n: INTEGER); (* xor reg, n *)
BEGIN
    oprc(0F0H, reg, n)
END xorrc;


PROCEDURE addrc (reg, n: INTEGER); (* add reg, n *)
BEGIN
    oprc(0C0H, reg, n)
END addrc;


PROCEDURE subrc (reg, n: INTEGER); (* sub reg, n *)
BEGIN
    oprc(0E8H, reg, n)
END subrc;


PROCEDURE cmprc (reg, n: INTEGER); (* cmp reg, n *)
BEGIN
    IF n = 0 THEN
        test(reg)
    ELSE
        oprc(0F8H, reg, n)
    END
END cmprc;


PROCEDURE cmprr (reg1, reg2: INTEGER); (* cmp reg1, reg2 *)
BEGIN
    oprr(39H, reg1, reg2)
END cmprr;


PROCEDURE setcc* (cc, reg: INTEGER); (* setcc reg *)
BEGIN
    IF reg >= 8 THEN
        OutByte(41H)
    END;
    OutByte3(0FH, cc, 0C0H + reg MOD 8)
END setcc;


PROCEDURE ret*;
BEGIN
    OutByte(0C3H)
END ret;


PROCEDURE drop;
BEGIN
    REG.Drop(R)
END drop;


PROCEDURE GetAnyReg (): INTEGER;
    RETURN REG.GetAnyReg(R)
END GetAnyReg;


PROCEDURE cond* (op: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    CASE op OF
    |IL.opGT, IL.opGTC: res := jg
    |IL.opGE, IL.opGEC: res := jge
    |IL.opLT, IL.opLTC: res := jl
    |IL.opLE, IL.opLEC: res := jle
    |IL.opEQ, IL.opEQC: res := je
    |IL.opNE, IL.opNEC: res := jne
    END

    RETURN res
END cond;


PROCEDURE inv0* (op: INTEGER): INTEGER;
    RETURN ORD(BITS(op) / {0})
END inv0;


PROCEDURE Reloc* (op, value: INTEGER);
VAR
    r: NODE;

BEGIN
    r := NewNode(tRELOC);
    r.op    := op;
    r.value := value
END Reloc;


(* The pushes of one floating point constant, at the head of the procedure the
   constant belongs to. The two halves of the value go in front of the pushes
   already made at that place, so the count of them says where this one goes. *)
PROCEDURE PushFlt (at: INTEGER; value: REAL);
VAR
    a, b, n: INTEGER;


    PROCEDURE pushImm (at, value: INTEGER);
    VAR
        c: NODE;
        i: INTEGER;

    BEGIN
        c := InsertNode(at + fltIns, tCODE);
        INC(fltIns);
        IF isByte(value) THEN
            c.code[0] := 6AH;
            c.code[1] := value MOD 256;
            c.len := 2
        ELSE
            c.code[0] := 68H;
            FOR i := 1 TO 4 DO
                c.code[i] := UTILS.Byte(value, i - 1)
            END;
            c.len := 5
        END
    END pushImm;


BEGIN
    n := UTILS.splitf(value, a, b);
    pushImm(at, b);
    pushImm(at, a)
END PushFlt;


PROCEDURE jcc* (cc, label: INTEGER);
VAR
    j: NODE;

BEGIN
    j := NewNode(tJCC);
    j.label := label;
    j.jmp   := cc
END jcc;


PROCEDURE jmp* (label: INTEGER);
VAR
    j: NODE;

BEGIN
    j := NewNode(tJMP);
    j.label := label
END jmp;


(* short is set here and not in InitNode: a call is always the long form, and
   the pass that shortens a jump to a byte's reach tests the flag to decide
   whether there is anything to shorten. *)
PROCEDURE call* (label: INTEGER);
VAR
    c: NODE;

BEGIN
    c := NewNode(tCALL);
    c.label := label;
    c.short := TRUE
END call;


PROCEDURE Pic (reg, opcode, value: INTEGER);
BEGIN
    OutByte(0E8H); OutInt(0); (* call L
                                 L: *)
    pop(reg);
    OutByte2(081H, 0C0H + reg);  (* add reg, ... *)
    Reloc(opcode, value)
END Pic;


PROCEDURE CallRTL (pic: BOOLEAN; proc: INTEGER);
VAR
    label: INTEGER;
    reg1:  INTEGER;

BEGIN
    label := IL.codes.rtl[proc];

    IF label < 0 THEN
        label := -label;
        IF pic THEN
            reg1 := GetAnyReg();
            Pic(reg1, BIN.PICIMP, label);
            OutByte2(0FFH, 010H + reg1);  (* call dword[reg1] *)
            drop
        ELSE
            OutByte2(0FFH, 015H);  (* call dword[label] *)
            Reloc(BIN.RIMP, label)
        END
    ELSE
        call(label)
    END
END CallRTL;


PROCEDURE SetLabel* (label: INTEGER);
VAR
    L: NODE;

BEGIN
    L := NewNode(tLABEL);
    L.label := label
END SetLabel;


(* Turn the list into the bytes of a section.

   The jumps have to be sized before they can be written, and a jump that was
   long may turn out to reach its label with a byte once the jumps before it
   have shortened, so the offsets are measured, the jumps are shortened where
   they now reach, and the two are repeated until a pass shortens nothing.
   Only then is anything written out. *)
PROCEDURE fixup*;
VAR
    code:     NODE;
    i, j:     INTEGER;
    count:    INTEGER;
    shorted:  BOOLEAN;

BEGIN

    REPEAT

        shorted := FALSE;
        count := 0;
        i := 0;

        WHILE i < ncount DO
            code := NodeAt(i);
            code.offset := count;

            CASE code.kind OF
            |tCODE:  INC(count, code.len)
            |tLABEL: BIN.SetLabel(program, code.label, count)
            |tJMP:   IF code.short THEN INC(count, 2) ELSE INC(count, 5) END; code.offset := count
            |tJCC:   IF code.short THEN INC(count, 2) ELSE INC(count, 6) END; code.offset := count
            |tCALL:  INC(count, 5); code.offset := count
            |tRELOC: INC(count, 4)
            END;

            INC(i)
        END;

        i := 0;
        WHILE i < ncount DO
            code := NodeAt(i);

            IF code.kind IN {tJMP, tJCC, tCALL} THEN
                code.diff := BIN.GetLabel(program, code.label) - code.offset;
                IF ~code.short & isByte(code.diff) THEN
                    code.short := TRUE;
                    shorted := TRUE
                END
            END;

            INC(i)
        END

    UNTIL ~shorted;

    i := 0;
    WHILE i < ncount DO
        code := NodeAt(i);

        CASE code.kind OF

        |tCODE:
                j := 0;
                WHILE j < code.len DO
                    BIN.PutCode(program, code.code[j]);
                    INC(j)
                END

        |tLABEL:

        |tJMP:
                IF code.short THEN
                    BIN.PutCode(program, 0EBH);
                    BIN.PutCode(program, code.diff MOD 256)
                ELSE
                    BIN.PutCode(program, 0E9H);
                    BIN.PutCode32LE(program, code.diff)
                END

        |tJCC:
                IF code.short THEN
                    BIN.PutCode(program, code.jmp - 16);
                    BIN.PutCode(program, code.diff MOD 256)
                ELSE
                    BIN.PutCode(program, 0FH);
                    BIN.PutCode(program, code.jmp);
                    BIN.PutCode32LE(program, code.diff)
                END

        |tCALL:
                BIN.PutCode(program, 0E8H);
                BIN.PutCode32LE(program, code.diff)

        |tRELOC:
                BIN.PutReloc(program, code.op);
                BIN.PutCode32LE(program, code.value)

        END;

        INC(i)
    END

END fixup;


PROCEDURE UnOp (VAR reg: INTEGER);
BEGIN
    REG.UnOp(R, reg)
END UnOp;


PROCEDURE BinOp (VAR reg1, reg2: INTEGER);
BEGIN
    REG.BinOp(R, reg1, reg2)
END BinOp;


PROCEDURE PushAll (NumberOfParameters: INTEGER);
BEGIN
    REG.PushAll(R);
    DEC(R.pushed, NumberOfParameters)
END PushAll;


PROCEDURE NewLabel (): INTEGER;
BEGIN
    BIN.NewLabel(program)
    RETURN IL.NewLabel()
END NewLabel;


PROCEDURE GetRegA;
BEGIN
    ASSERT(REG.GetReg(R, eax))
END GetRegA;


PROCEDURE fcmp;
BEGIN
    GetRegA;
    OutByte2(0DAH, 0E9H);       (* fucompp *)
    OutByte3(09BH, 0DFH, 0E0H); (* fstsw ax *)
    OutByte(09EH);              (* sahf *)
    OutByte(0B8H); OutInt(0)    (* mov eax, 0 *)
END fcmp;


PROCEDURE movzx* (reg1, reg2, offs: INTEGER; word: BOOLEAN); (* movzx reg1, byte/word[reg2 + offs] *)
VAR
    b: BYTE;

BEGIN
    OutByte2(0FH, 0B6H + ORD(word));
    IF (offs = 0) & (reg2 # ebp) THEN
        b := 0
    ELSE
        b := 40H + long(offs)
    END;
    OutByte(b + (reg1 MOD 8) * 8 + reg2 MOD 8);
    IF reg2 = esp THEN
        OutByte(24H)
    END;
    IF b # 0 THEN
        OutIntByte(offs)
    END
END movzx;


PROCEDURE _movrm* (reg1, reg2, offs, size: INTEGER; mr: BOOLEAN);
VAR
    b: BYTE;

BEGIN
    IF size = 16 THEN
        OutByte(66H)
    END;
    IF (reg1 >= 8) OR (reg2 >= 8) OR (size = 64) THEN
        OutByte(40H + reg2 DIV 8 + 4 * (reg1 DIV 8) + 8 * ORD(size = 64))
    END;
    OutByte(8BH - 2 * ORD(mr) - ORD(size = 8));
    IF (offs = 0) & (reg2 # ebp) THEN
        b := 0
    ELSE
        b := 40H + long(offs)
    END;
    OutByte(b + (reg1 MOD 8) * 8 + reg2 MOD 8);
    IF reg2 = esp THEN
        OutByte(24H)
    END;
    IF b # 0 THEN
        OutIntByte(offs)
    END
END _movrm;


PROCEDURE movmr (reg1, offs, reg2: INTEGER); (* mov dword[reg1+offs], reg2 *)
BEGIN
    _movrm(reg2, reg1, offs, 32, TRUE)
END movmr;


PROCEDURE movrm (reg1, reg2, offs: INTEGER); (* mov reg1, dword[reg2 + offs] *)
BEGIN
    _movrm(reg1, reg2, offs, 32, FALSE)
END movrm;


PROCEDURE movmr8* (reg1, offs, reg2: INTEGER); (* mov byte[reg1+offs], reg2_8 *)
BEGIN
    _movrm(reg2, reg1, offs, 8, TRUE)
END movmr8;


PROCEDURE movrm8* (reg1, reg2, offs: INTEGER); (* mov reg1_8, byte[reg2+offs] *)
BEGIN
    _movrm(reg1, reg2, offs, 8, FALSE)
END movrm8;


PROCEDURE movmr16* (reg1, offs, reg2: INTEGER); (* mov word[reg1+offs], reg2_16 *)
BEGIN
    _movrm(reg2, reg1, offs, 16, TRUE)
END movmr16;


PROCEDURE movrm16* (reg1, reg2, offs: INTEGER); (* mov reg1_16, word[reg2+offs] *)
BEGIN
    _movrm(reg1, reg2, offs, 16, FALSE)
END movrm16;


PROCEDURE pushm* (reg, offs: INTEGER); (* push qword[reg+offs] *)
VAR
    b: BYTE;

BEGIN
    IF reg >= 8 THEN
        OutByte(41H)
    END;
    OutByte(0FFH);
    IF (offs = 0) & (reg # ebp) THEN
        b := 30H
    ELSE
        b := 70H + long(offs)
    END;
    OutByte(b + reg MOD 8);
    IF reg = esp THEN
        OutByte(24H)
    END;
    IF b # 30H THEN
        OutIntByte(offs)
    END
END pushm;


PROCEDURE LoadFltConst (value: REAL);
BEGIN
    PushFlt(FltConstLabel, value);
    INC(LocVarSize, 8);
    IF FltConstLabel = mainFltConstLabel THEN
        mainLocVarSize := LocVarSize;
        mainFltIns := fltIns
    END;
    OutByte2(0DDH, 045H + long(-LocVarSize)); (* fld qword[ebp - LocVarSize] *)
    OutIntByte(-LocVarSize)
END LoadFltConst;


PROCEDURE translate (pic: BOOLEAN; stroffs, target: INTEGER);
VAR
    cmd, next: COMMAND;

    reg1, reg2, reg3, fr: INTEGER;

    n, a, label, cc: INTEGER;

    opcode, param1, param2: INTEGER;

    float: REAL;

BEGIN
    cmd := IL.codes.commands;

    fr := -1;

    WHILE cmd # NIL DO

        (* This pass never revisits a command, so everything behind us is dead. *)
        IL.freeUpTo(cmd);

        param1 := cmd.param1;
        param2 := cmd.param2;

        opcode := cmd.opcode;

        CASE opcode OF

        |IL.opJMP:
            jmp(param1)

        |IL.opCALL:
            call(param1)

        |IL.opCALLI:
            IF pic THEN
                reg1 := GetAnyReg();
                Pic(reg1, BIN.PICIMP, param1);
                OutByte2(0FFH, 010H + reg1);  (* call dword[reg1] *)
                drop
            ELSE
                OutByte2(0FFH, 015H);  (* call dword[L] *)
                Reloc(BIN.RIMP, param1)
            END

        |IL.opCALLP:
            UnOp(reg1);
            OutByte2(0FFH, 0D0H + reg1);  (* call reg1 *)
            drop;
            ASSERT(R.top = -1)

        |IL.opFASTCALL:
            IF param2 = 1 THEN
                pop(ecx)
            ELSIF param2 = 2 THEN
                pop(ecx);
                pop(edx)
            END

        |IL.opPRECALL:
            PushAll(0);
            IF (param2 # 0) & (fr >= 0) THEN
                subrc(esp, 8)
            END;
            INC(FR[0]);
            FR[FR[0]] := fr + 1;
            WHILE fr >= 0 DO
                subrc(esp, 8);
                OutByte3(0DDH, 01CH, 024H); (* fstp qword[esp] *)
                DEC(fr)
            END;
            ASSERT(fr = -1)

        |IL.opALIGN16:
            ASSERT(eax IN R.regs);
            mov(eax, esp);
            andrc(esp, -16);
            n := (3 - param2 MOD 4) * 4;
            IF n > 0 THEN
                subrc(esp, n)
            END;
            push(eax)

        |IL.opRESF, IL.opRES:
            ASSERT(R.top = -1);
            ASSERT(fr = -1);
            n := FR[FR[0]]; DEC(FR[0]);

            IF opcode = IL.opRESF THEN
                INC(fr);
                IF n > 0 THEN
                    OutByte3(0DDH, 5CH + long(n * 8), 24H);
                    OutIntByte(n * 8); (* fstp qword[esp + n*8] *)
                    DEC(fr);
                    INC(n)
                END;

                IF fr + n > MAX_FR THEN
                    ERRORS.ErrorMsg(fname, param1, param2, FPR_ERR)
                END
            ELSE
                GetRegA
            END;

            WHILE n > 0 DO
                OutByte3(0DDH, 004H, 024H); (* fld qword[esp] *)
                addrc(esp, 8);
                INC(fr);
                DEC(n)
            END

        |IL.opENTER:
            ASSERT(R.top = -1);

            SetLabel(param1);

            IF cmd.param3 > 0 THEN
                pop(eax);
                IF cmd.param3 >= 2 THEN
                    push(edx)
                END;
                push(ecx);
                push(eax)
            END;

            push(ebp);
            mov(ebp, esp);

            n := param2;
            IF n > 4 THEN
                movrc(ecx, n);
                pushc(0);             (* L: push 0 *)
                OutByte2(0E2H, 0FCH)  (* loop L    *)
            ELSE
                WHILE n > 0 DO
                    pushc(0);
                    DEC(n)
                END
            END;
            SetLabel(NewLabel());
            FltConstLabel := ncount;
            fltIns := 0;
            LocVarSize := param2 * 4

        |IL.opLEAVE, IL.opLEAVER, IL.opLEAVEF:
            IF opcode = IL.opLEAVER THEN
                UnOp(reg1);
                IF reg1 # eax THEN
                    mov(eax, reg1)
                END;
                drop
            END;

            ASSERT(R.top = -1);

            IF opcode = IL.opLEAVEF THEN
                DEC(fr)
            END;

            ASSERT(fr = -1);

            IF LocVarSize > 0 THEN
                mov(esp, ebp)
            END;

            pop(ebp);

            IF param2 > 0 THEN
                OutByte(0C2H); OutWord(param2 * 4 MOD 65536) (* ret param2*4 *)
            ELSE
                ret
            END;
            FltConstLabel := mainFltConstLabel;
            fltIns := mainFltIns;
            LocVarSize := mainLocVarSize

        |IL.opPUSHC:
            pushc(param2)

        |IL.opONERR:
            pushc(param2);
            jmp(param1)

        |IL.opPARAM:
            IF param2 = 1 THEN
                UnOp(reg1);
                push(reg1);
                drop
            ELSE
                ASSERT(R.top + 1 <= param2);
                PushAll(param2)
            END

        |IL.opCLEANUP:
            IF param2 # 0 THEN
                addrc(esp, param2 * 4)
            END

        |IL.opPOPSP:
            pop(esp)

        |IL.opCONST:
            movrc(GetAnyReg(), param2)

        |IL.opLABEL:
            SetLabel(param1) (* L: *)

        |IL.opNOP, IL.opAND, IL.opOR:

        |IL.opGADR:
            next := cmd.next;
            IF next.opcode = IL.opADDC THEN
                INC(param2, next.param2);
                cmd := next
            END;
            reg1 := GetAnyReg();
            IF pic THEN
                Pic(reg1, BIN.PICBSS, param2)
            ELSE
                OutByte(0B8H + reg1);  (* mov reg1, _bss + param2 *)
                Reloc(BIN.RBSS, param2)
            END

        |IL.opLADR:
            next := cmd.next;
            n := param2 * 4;
            IF next.opcode = IL.opADDC THEN
                INC(n, next.param2);
                cmd := next
            END;
            OutByte2(8DH, 45H + GetAnyReg() * 8 + long(n));  (* lea reg1, dword[ebp + n] *)
            OutIntByte(n)

        |IL.opVADR, IL.opLLOAD32:
            movrm(GetAnyReg(), ebp, param2 * 4)

        |IL.opSADR:
            reg1 := GetAnyReg();
            IF pic THEN
                Pic(reg1, BIN.PICDATA, stroffs + param2);
            ELSE
                OutByte(0B8H + reg1);  (* mov reg1, _data + stroffs + param2 *)
                Reloc(BIN.RDATA, stroffs + param2)
            END

        |IL.opSAVEC:
            UnOp(reg1);
            OutByte2(0C7H, reg1); OutInt(param2);  (* mov dword[reg1], param2 *)
            drop

        |IL.opSAVE8C:
            UnOp(reg1);
            OutByte3(0C6H, reg1, param2 MOD 256);  (* mov byte[reg1], param2 *)
            drop

        |IL.opSAVE16C:
            UnOp(reg1);
            OutByte3(66H, 0C7H, reg1); OutWord(param2 MOD 65536);  (* mov word[reg1], param2 *)
            drop

        |IL.opVLOAD32:
            reg1 := GetAnyReg();
            movrm(reg1, ebp, param2 * 4);
            movrm(reg1, reg1, 0)

        |IL.opGLOAD32:
            reg1 := GetAnyReg();
            IF pic THEN
                Pic(reg1, BIN.PICBSS, param2);
                movrm(reg1, reg1, 0)
            ELSE
                OutByte2(08BH, 05H + reg1 * 8);  (* mov reg1, dword[_bss + param2] *)
                Reloc(BIN.RBSS, param2)
            END

        |IL.opLOAD32:
            UnOp(reg1);
            movrm(reg1, reg1, 0)

        |IL.opVLOAD8:
            reg1 := GetAnyReg();
            movrm(reg1, ebp, param2 * 4);
            movzx(reg1, reg1, 0, FALSE)

        |IL.opGLOAD8:
            reg1 := GetAnyReg();
            IF pic THEN
                Pic(reg1, BIN.PICBSS, param2);
                movzx(reg1, reg1, 0, FALSE)
            ELSE
                OutByte3(00FH, 0B6H, 05H + reg1 * 8); (* movzx reg1, byte[_bss + param2] *)
                Reloc(BIN.RBSS, param2)
            END

        |IL.opLLOAD8:
            movzx(GetAnyReg(), ebp, param2 * 4, FALSE)

        |IL.opLOAD8:
            UnOp(reg1);
            movzx(reg1, reg1, 0, FALSE)

        |IL.opVLOAD16:
            reg1 := GetAnyReg();
            movrm(reg1, ebp, param2 * 4);
            movzx(reg1, reg1, 0, TRUE)

        |IL.opGLOAD16:
            reg1 := GetAnyReg();
            IF pic THEN
                Pic(reg1, BIN.PICBSS, param2);
                movzx(reg1, reg1, 0, TRUE)
            ELSE
                OutByte3(00FH, 0B7H, 05H + reg1 * 8);  (* movzx reg1, word[_bss + param2] *)
                Reloc(BIN.RBSS, param2)
            END

        |IL.opLLOAD16:
            movzx(GetAnyReg(), ebp, param2 * 4, TRUE)

        |IL.opLOAD16:
            UnOp(reg1);
            movzx(reg1, reg1, 0, TRUE)

        |IL.opUMINUS:
            UnOp(reg1);
            neg(reg1)

        |IL.opADD:
            BinOp(reg1, reg2);
            add(reg1, reg2);
            drop

        |IL.opADDC:
            IF param2 # 0 THEN
                UnOp(reg1);
                next := cmd.next;
                CASE next.opcode OF
                |IL.opLOAD32:
                    movrm(reg1, reg1, param2);
                    cmd := next
                |IL.opLOAD16:
                    movzx(reg1, reg1, param2, TRUE);
                    cmd := next
                |IL.opLOAD8:
                    movzx(reg1, reg1, param2, FALSE);
                    cmd := next
                |IL.opLOAD32_PARAM:
                    pushm(reg1, param2);
                    drop;
                    cmd := next
                ELSE
                    IF param2 = 1 THEN
                        OutByte(40H + reg1) (* inc reg1 *)
                    ELSIF param2 = -1 THEN
                        OutByte(48H + reg1) (* dec reg1 *)
                    ELSE
                        addrc(reg1, param2)
                    END
                END
            END

        |IL.opSUB:
            BinOp(reg1, reg2);
            oprr(29H, reg1, reg2); (* sub reg1, reg2 *)
            drop

        |IL.opSUBR, IL.opSUBL:
            UnOp(reg1);
            IF param2 = 1 THEN
                OutByte(48H + reg1) (* dec reg1 *)
            ELSIF param2 = -1 THEN
                OutByte(40H + reg1) (* inc reg1 *)
            ELSIF param2 # 0 THEN
                subrc(reg1, param2)
            END;
            IF opcode = IL.opSUBL THEN
                neg(reg1)
            END

        |IL.opMULC:
            IF (cmd.next.opcode = IL.opADD) & ((param2 = 2) OR (param2 = 4) OR (param2 = 8)) THEN
                BinOp(reg1, reg2);
                OutByte3(8DH, 04H + reg1 * 8, reg1 + reg2 * 8 + 40H * UTILS.Log2(param2)); (* lea reg1, [reg1 + reg2 * param2] *)
                drop;
                cmd := cmd.next
            ELSE
                UnOp(reg1);

                a := param2;
                IF a > 1 THEN
                    n := UTILS.Log2(a)
                ELSIF a < -1 THEN
                    n := UTILS.Log2(-a)
                ELSE
                    n := -1
                END;

                IF a = 1 THEN

                ELSIF a = -1 THEN
                    neg(reg1)
                ELSIF a = 0 THEN
                    xor(reg1, reg1)
                ELSE
                    IF n > 0 THEN
                        IF a < 0 THEN
                            neg(reg1)
                        END;

                        IF n # 1 THEN
                            OutByte3(0C1H, 0E0H + reg1, n)   (* shl reg1, n *)
                        ELSE
                            OutByte2(0D1H, 0E0H + reg1)      (* shl reg1, 1 *)
                        END
                    ELSE
                        OutByte2(69H + short(a), 0C0H + reg1 * 9); (* imul reg1, a *)
                        OutIntByte(a)
                    END
                END
            END

        |IL.opMUL:
            BinOp(reg1, reg2);
            OutByte3(0FH, 0AFH, 0C0H + reg1 * 8 + reg2); (* imul reg1, reg2 *)
            drop

        |IL.opSAVE, IL.opSAVE32:
            BinOp(reg2, reg1);
            movmr(reg1, 0, reg2);
            drop;
            drop

        |IL.opSAVE8:
            BinOp(reg2, reg1);
            movmr8(reg1, 0, reg2);
            drop;
            drop

        |IL.opSAVE16:
            BinOp(reg2, reg1);
            movmr16(reg1, 0, reg2);
            drop;
            drop

        |IL.opSAVEP:
            UnOp(reg1);
            IF pic THEN
                reg2 := GetAnyReg();
                Pic(reg2, BIN.PICCODE, param2);
                movmr(reg1, 0, reg2);
                drop
            ELSE
                OutByte2(0C7H, reg1);  (* mov dword[reg1], L *)
                Reloc(BIN.RCODE, param2)
            END;
            drop

        |IL.opSAVEIP:
            UnOp(reg1);
            IF pic THEN
                reg2 := GetAnyReg();
                Pic(reg2, BIN.PICIMP, param2);
                pushm(reg2, 0);
                OutByte2(08FH, reg1);  (* pop dword[reg1] *)
                drop
            ELSE
                OutByte2(0FFH, 035H);  (* push dword[L] *)
                Reloc(BIN.RIMP, param2);
                OutByte2(08FH, reg1)   (* pop dword[reg1] *)
            END;
            drop

        |IL.opPUSHP:
            reg1 := GetAnyReg();
            IF pic THEN
                Pic(reg1, BIN.PICCODE, param2)
            ELSE
                OutByte(0B8H + reg1);  (* mov reg1, L *)
                Reloc(BIN.RCODE, param2)
            END

        |IL.opPUSHIP:
            reg1 := GetAnyReg();
            IF pic THEN
                Pic(reg1, BIN.PICIMP, param2);
                movrm(reg1, reg1, 0)
            ELSE
                OutByte2(08BH, 05H + reg1 * 8);  (* mov reg1, dword[L] *)
                Reloc(BIN.RIMP, param2)
            END

        |IL.opNOT:
            UnOp(reg1);
            test(reg1);
            setcc(sete, reg1);
            andrc(reg1, 1)

        |IL.opORD:
            UnOp(reg1);
            test(reg1);
            setcc(setne, reg1);
            andrc(reg1, 1)

        |IL.opSBOOL:
            BinOp(reg2, reg1);
            test(reg2);
            OutByte3(0FH, 95H, reg1); (* setne byte[reg1] *)
            drop;
            drop

        |IL.opSBOOLC:
            UnOp(reg1);
            OutByte3(0C6H, reg1, ORD(param2 # 0)); (* mov byte[reg1], 0/1 *)
            drop

        |IL.opEQ..IL.opGE,
         IL.opEQC..IL.opGEC:

            IF (IL.opEQ <= opcode) & (opcode <= IL.opGE) THEN
                BinOp(reg1, reg2);
                cmprr(reg1, reg2);
                drop
            ELSE
                UnOp(reg1);
                cmprc(reg1, param2)
            END;

            drop;
            cc := cond(opcode);
            next := cmd.next;

            IF next.opcode = IL.opJNZ THEN
                jcc(cc, next.param1);
                cmd := next
            ELSIF next.opcode = IL.opJZ THEN
                jcc(inv0(cc), next.param1);
                cmd := next
            ELSE
                reg1 := GetAnyReg();
                setcc(cc + 16, reg1);
                andrc(reg1, 1)
            END

        |IL.opEQB, IL.opNEB:
            BinOp(reg1, reg2);
            drop;

            test(reg1);
            OutByte2(74H, 5);  (* je @f *)
            movrc(reg1, 1);    (* mov reg1, 1
                                  @@: *)
            test(reg2);
            OutByte2(74H, 5);  (* je @f *)
            movrc(reg2, 1);    (* mov reg2, 1
                                  @@: *)

            cmprr(reg1, reg2);
            IF opcode = IL.opEQB THEN
                setcc(sete, reg1)
            ELSE
                setcc(setne, reg1)
            END;
            andrc(reg1, 1)

        |IL.opDROP:
            UnOp(reg1);
            drop

        |IL.opJNZ1:
            UnOp(reg1);
            test(reg1);
            jcc(jne, param1)

        |IL.opJG:
            UnOp(reg1);
            test(reg1);
            jcc(jg, param1)

        |IL.opJNZ:
            UnOp(reg1);
            test(reg1);
            jcc(jne, param1);
            drop

        |IL.opJZ:
            UnOp(reg1);
            test(reg1);
            jcc(je, param1);
            drop

        |IL.opSWITCH:
            UnOp(reg1);
            IF param2 = 0 THEN
                reg2 := eax
            ELSE
                reg2 := ecx
            END;
            IF reg1 # reg2 THEN
                ASSERT(REG.GetReg(R, reg2));
                ASSERT(REG.Exchange(R, reg1, reg2));
                drop
            END;
            drop

        |IL.opENDSW:

        |IL.opCASEL:
            cmprc(eax, param1);
            jcc(jl, param2)

        |IL.opCASER:
            cmprc(eax, param1);
            jcc(jg, param2)

        |IL.opCASELR:
            cmprc(eax, param1);
            IF param2 = cmd.param3 THEN
                jcc(jne, param2)
            ELSE
                jcc(jl, param2);
                jcc(jg, cmd.param3)
            END

        |IL.opCODE:
            OutByte(param2)

        |IL.opGET, IL.opGETC:
            IF opcode = IL.opGET THEN
                BinOp(reg1, reg2)
            ELSIF opcode = IL.opGETC THEN
                UnOp(reg2);
                reg1 := GetAnyReg();
                movrc(reg1, param1)
            END;
            drop;
            drop;

            IF param2 # 8 THEN
                _movrm(reg1, reg1, 0, param2 * 8, FALSE);
                _movrm(reg1, reg2, 0, param2 * 8, TRUE)
            ELSE
                PushAll(0);
                push(reg1);
                push(reg2);
                pushc(8);
                CallRTL(pic, IL._move)
            END

        |IL.opSAVES:
            UnOp(reg2);
            REG.PushAll_1(R);

            IF pic THEN
                reg1 := GetAnyReg();
                Pic(reg1, BIN.PICDATA, stroffs + param2);
                push(reg1);
                drop
            ELSE
                OutByte(068H);  (* push _data + stroffs + param2 *)
                Reloc(BIN.RDATA, stroffs + param2);
            END;

            push(reg2);
            drop;
            pushc(param1);
            CallRTL(pic, IL._move)

        |IL.opCHKIDX:
            UnOp(reg1);
            cmprc(reg1, param2);
            jcc(jb, param1)

        |IL.opCHKIDX2:
            BinOp(reg1, reg2);
            IF param2 # -1 THEN
                cmprr(reg2, reg1);
                jcc(jb, param1)
            END;
            INCL(R.regs, reg1);
            DEC(R.top);
            R.stk[R.top] := reg2

        |IL.opLEN:
            n := param2;
            UnOp(reg1);
            drop;
            EXCL(R.regs, reg1);

            WHILE n > 0 DO
                UnOp(reg2);
                drop;
                DEC(n)
            END;

            INCL(R.regs, reg1);
            ASSERT(REG.GetReg(R, reg1))

        |IL.opINCC:
            UnOp(reg1);
            IF param2 = 1 THEN
                OutByte2(0FFH, reg1) (* inc dword[reg1] *)
            ELSIF param2 = -1 THEN
                OutByte2(0FFH, reg1 + 8) (* dec dword[reg1] *)
            ELSE
                OutByte2(81H + short(param2), reg1); OutIntByte(param2) (* add dword[reg1], param2 *)
            END;
            drop

        |IL.opINC, IL.opDEC:
            BinOp(reg1, reg2);
            OutByte2(01H + 28H * ORD(opcode = IL.opDEC), reg1 * 8 + reg2); (* add/sub dword[reg2], reg1 *)
            drop;
            drop

        |IL.opINCCB, IL.opDECCB:
            UnOp(reg1);
            OutByte3(80H, 28H * ORD(opcode = IL.opDECCB) + reg1, param2 MOD 256); (* add/sub byte[reg1], n *)
            drop

        |IL.opINCB, IL.opDECB:
            BinOp(reg1, reg2);
            OutByte2(28H * ORD(opcode = IL.opDECB), reg1 * 8 + reg2); (* add/sub byte[reg2], reg1 *)
            drop;
            drop

        |IL.opMULS:
            BinOp(reg1, reg2);
            oprr(21H, reg1, reg2); (* and reg1, reg2 *)
            drop

        |IL.opMULSC:
            UnOp(reg1);
            andrc(reg1, param2)

        |IL.opDIVS:
            BinOp(reg1, reg2);
            xor(reg1, reg2);
            drop

        |IL.opDIVSC:
            UnOp(reg1);
            xorrc(reg1, param2)

        |IL.opADDS:
            BinOp(reg1, reg2);
            oprr(9H, reg1, reg2); (* or reg1, reg2 *)
            drop

        |IL.opSUBS:
            BinOp(reg1, reg2);
            not(reg2);
            oprr(21H, reg1, reg2); (* and reg1, reg2 *)
            drop

        |IL.opADDSC:
            UnOp(reg1);
            orrc(reg1, param2)

        |IL.opSUBSL:
            UnOp(reg1);
            not(reg1);
            andrc(reg1, param2)

        |IL.opSUBSR:
            UnOp(reg1);
            andrc(reg1, ORD(-BITS(param2)))

        |IL.opUMINS:
            UnOp(reg1);
            not(reg1)

        |IL.opLENGTH:
            PushAll(2);
            CallRTL(pic, IL._length);
            GetRegA

        |IL.opLENGTHW:
            PushAll(2);
            CallRTL(pic, IL._lengthw);
            GetRegA

        |IL.opASR, IL.opROR, IL.opLSL, IL.opLSR:
            UnOp(reg1);
            IF reg1 # ecx THEN
                ASSERT(REG.GetReg(R, ecx));
                ASSERT(REG.Exchange(R, reg1, ecx));
                drop
            END;

            BinOp(reg1, reg2);
            ASSERT(reg2 = ecx);
            OutByte(0D3H);
            shift(opcode, reg1); (* shift reg1, cl *)
            drop

        |IL.opASR1, IL.opROR1, IL.opLSL1, IL.opLSR1:
            UnOp(reg1);
            IF reg1 # ecx THEN
                ASSERT(REG.GetReg(R, ecx));
                ASSERT(REG.Exchange(R, reg1, ecx));
                drop
            END;

            reg1 := GetAnyReg();
            movrc(reg1, param2);
            BinOp(reg1, reg2);
            ASSERT(reg1 = ecx);
            OutByte(0D3H);
            shift(opcode, reg2); (* shift reg2, cl *)
            drop;
            drop;
            ASSERT(REG.GetReg(R, reg2))

        |IL.opASR2, IL.opROR2, IL.opLSL2, IL.opLSR2:
            UnOp(reg1);
            n := param2 MOD 32;
            IF n # 1 THEN
                OutByte(0C1H)
            ELSE
                OutByte(0D1H)
            END;
            shift(opcode, reg1); (* shift reg1, n *)
            IF n # 1 THEN
                OutByte(n)
            END

        |IL.opMAX, IL.opMIN:
            BinOp(reg1, reg2);
            cmprr(reg1, reg2);
            OutByte2(07DH + ORD(opcode = IL.opMIN), 2);  (* jge/jle L *)
            mov(reg1, reg2);
            (* L: *)
            drop

        |IL.opMAXC, IL.opMINC:
            UnOp(reg1);
            cmprc(reg1, param2);
            label := NewLabel();
            IF opcode = IL.opMINC THEN
                cc := jle
            ELSE
                cc := jge
            END;
            jcc(cc, label);
            movrc(reg1, param2);
            SetLabel(label)

        |IL.opIN, IL.opINR:
            IF opcode = IL.opINR THEN
                reg2 := GetAnyReg();
                movrc(reg2, param2)
            END;
            label := NewLabel();
            BinOp(reg1, reg2);
            cmprc(reg1, 32);
            OutByte2(72H, 4); (* jb L *)
            xor(reg1, reg1);
            jmp(label);
            (* L: *)
            OutByte3(0FH, 0A3H, 0C0H + reg2 + 8 * reg1); (* bt reg2, reg1 *)
            setcc(setc, reg1);
            andrc(reg1, 1);
            SetLabel(label);
            drop

        |IL.opINL:
            UnOp(reg1);
            OutByte3(0FH, 0BAH, 0E0H + reg1); OutByte(param2); (* bt reg1, param2 *)
            setcc(setc, reg1);
            andrc(reg1, 1)

        |IL.opRSET:
            PushAll(2);
            CallRTL(pic, IL._set);
            GetRegA

        |IL.opRSETR:
            PushAll(1);
            pushc(param2);
            CallRTL(pic, IL._set);
            GetRegA

        |IL.opRSETL:
            UnOp(reg1);
            REG.PushAll_1(R);
            pushc(param2);
            push(reg1);
            drop;
            CallRTL(pic, IL._set);
            GetRegA

        |IL.opRSET1:
            PushAll(1);
            CallRTL(pic, IL._set1);
            GetRegA

        |IL.opINCL, IL.opEXCL:
            BinOp(reg1, reg2);
            cmprc(reg1, 32);
            OutByte2(73H, 03H); (* jnb L *)
            OutByte(0FH);
            IF opcode = IL.opINCL THEN
                OutByte(0ABH) (* bts dword[reg2], reg1 *)
            ELSE
                OutByte(0B3H) (* btr dword[reg2], reg1 *)
            END;
            OutByte(reg2 + 8 * reg1);
            (* L: *)
            drop;
            drop

        |IL.opINCLC:
            UnOp(reg1);
            OutByte3(0FH, 0BAH, 28H + reg1); OutByte(param2); (* bts dword[reg1], param2 *)
            drop

        |IL.opEXCLC:
            UnOp(reg1);
            OutByte3(0FH, 0BAH, 30H + reg1); OutByte(param2); (* btr dword[reg1], param2 *)
            drop

        |IL.opDIV:
            PushAll(2);
            CallRTL(pic, IL._divmod);
            GetRegA

        |IL.opDIVR:
            n := UTILS.Log2(param2);
            IF n > 0 THEN
                UnOp(reg1);
                IF n # 1 THEN
                    OutByte3(0C1H, 0F8H + reg1, n) (* sar reg1, n *)
                ELSE
                    OutByte2(0D1H, 0F8H + reg1)    (* sar reg1, 1 *)
                END
            ELSIF n < 0 THEN
                PushAll(1);
                pushc(param2);
                CallRTL(pic, IL._divmod);
                GetRegA
            END

        |IL.opDIVL:
            UnOp(reg1);
            REG.PushAll_1(R);
            pushc(param2);
            push(reg1);
            drop;
            CallRTL(pic, IL._divmod);
            GetRegA

        |IL.opMOD:
            PushAll(2);
            CallRTL(pic, IL._divmod);
            mov(eax, edx);
            GetRegA

        |IL.opMODR:
            n := UTILS.Log2(param2);
            IF n > 0 THEN
                UnOp(reg1);
                andrc(reg1, param2 - 1);
            ELSIF n < 0 THEN
                PushAll(1);
                pushc(param2);
                CallRTL(pic, IL._divmod);
                mov(eax, edx);
                GetRegA
            ELSE
                UnOp(reg1);
                xor(reg1, reg1)
            END

        |IL.opMODL:
            UnOp(reg1);
            REG.PushAll_1(R);
            pushc(param2);
            push(reg1);
            drop;
            CallRTL(pic, IL._divmod);
            mov(eax, edx);
            GetRegA

        |IL.opERR:
            CallRTL(pic, IL._error)

        |IL.opABS:
            UnOp(reg1);
            test(reg1);
            OutByte2(07DH, 002H); (* jge L *)
            neg(reg1)             (* neg reg1
                                     L: *)

        |IL.opCOPY:
            IF (0 < param2) & (param2 <= 64) THEN
                BinOp(reg1, reg2);
                reg3 := GetAnyReg();
                FOR n := 0 TO param2 - param2 MOD 4 - 1 BY 4 DO
                    movrm(reg3, reg1, n);
                    movmr(reg2, n, reg3)
                END;
                n := param2 - param2 MOD 4;
                IF param2 MOD 4 >= 2 THEN
                    movrm16(reg3, reg1, n);
                    movmr16(reg2, n, reg3);
                    INC(n, 2);
                    DEC(param2, 2)
                END;
                IF param2 MOD 4 = 1 THEN
                    movrm8(reg3, reg1, n);
                    movmr8(reg2, n, reg3);
                END;
                drop;
                drop;
                drop
            ELSE
                PushAll(2);
                pushc(param2);
                CallRTL(pic, IL._move)
            END

        |IL.opMOVE:
            PushAll(3);
            CallRTL(pic, IL._move)

        |IL.opCOPYA:
            PushAll(4);
            pushc(param2);
            CallRTL(pic, IL._arrcpy);
            GetRegA

        |IL.opCOPYS:
            PushAll(4);
            pushc(param2);
            CallRTL(pic, IL._strcpy)

        |IL.opROT:
            PushAll(0);
            push(esp);
            pushc(param2);
            CallRTL(pic, IL._rot)

        |IL.opNEW:
            PushAll(1);
            CASE TARGETS.OS OF
            |TARGETS.osWIN32,
             TARGETS.osDPMI32:
                n := param2 + 4;
                ASSERT(UTILS.Align(n, 4))
            |TARGETS.osLINUX32:
                n := param2 + 16;
                ASSERT(UTILS.Align(n, 16))
            END;
            pushc(n);
            pushc(param1);
            CallRTL(pic, IL._new)

        |IL.opDISP:
            PushAll(1);
            CallRTL(pic, IL._dispose)

        |IL.opEQS .. IL.opGES:
            PushAll(4);
            pushc(opcode - IL.opEQS);
            CallRTL(pic, IL._strcmp);
            GetRegA

        |IL.opEQSW .. IL.opGESW:
            PushAll(4);
            pushc(opcode - IL.opEQSW);
            CallRTL(pic, IL._strcmpw);
            GetRegA

        |IL.opEQP, IL.opNEP, IL.opEQIP, IL.opNEIP:
            UnOp(reg1);
            CASE opcode OF
            |IL.opEQP, IL.opNEP:
                IF pic THEN
                    reg2 := GetAnyReg();
                    Pic(reg2, BIN.PICCODE, param1);
                    cmprr(reg1, reg2);
                    drop
                ELSE
                    OutByte2(081H, 0F8H + reg1);  (* cmp reg1, L *)
                    Reloc(BIN.RCODE, param1)
                END

            |IL.opEQIP, IL.opNEIP:
                IF pic THEN
                    reg2 := GetAnyReg();
                    Pic(reg2, BIN.PICIMP, param1);
                    OutByte2(03BH, reg1 * 8 + reg2);  (* cmp reg1, dword [reg2] *)
                    drop
                ELSE
                    OutByte2(3BH, 05H + reg1 * 8);    (* cmp reg1, dword[L] *)
                    Reloc(BIN.RIMP, param1)
                END

            END;
            drop;
            reg1 := GetAnyReg();

            CASE opcode OF
            |IL.opEQP, IL.opEQIP: setcc(sete,  reg1)
            |IL.opNEP, IL.opNEIP: setcc(setne, reg1)
            END;

            andrc(reg1, 1)

        |IL.opPUSHT:
            UnOp(reg1);
            movrm(GetAnyReg(), reg1, -4)

        |IL.opISREC:
            PushAll(2);
            param2 := param2*tcount;
            pushc(param2);
            CallRTL(pic, IL._isrec);
            GetRegA

        |IL.opIS:
            PushAll(1);
            param2 := param2*tcount;
            pushc(param2);
            CallRTL(pic, IL._is);
            GetRegA

        |IL.opTYPEGR:
            PushAll(1);
            param2 := param2*tcount;
            pushc(param2);
            CallRTL(pic, IL._guardrec);
            GetRegA

        |IL.opTYPEGP:
            UnOp(reg1);
            PushAll(0);
            push(reg1);
            param2 := param2*tcount;
            pushc(param2);
            CallRTL(pic, IL._guard);
            GetRegA

        |IL.opTYPEGD:
            UnOp(reg1);
            PushAll(0);
            pushm(reg1, -4);
            param2 := param2*tcount;
            pushc(param2);
            CallRTL(pic, IL._guardrec);
            GetRegA

        |IL.opCASET:
            push(ecx);
            push(ecx);
            param2 := param2*tcount;
            pushc(param2);
            CallRTL(pic, IL._guardrec);
            pop(ecx);
            test(eax);
            jcc(jne, param1)

        |IL.opPACK:
            BinOp(reg1, reg2);
            push(reg2);
            OutByte3(0DBH, 004H, 024H);   (* fild dword[esp]  *)
            OutByte2(0DDH, reg1);         (* fld qword[reg1]  *)
            OutByte2(0D9H, 0FDH);         (* fscale           *)
            OutByte2(0DDH, 018H + reg1);  (* fstp qword[reg1] *)
            OutByte3(0DBH, 01CH, 024H);   (* fistp dword[esp] *)
            pop(reg2);
            drop;
            drop

        |IL.opPACKC:
            UnOp(reg1);
            pushc(param2);
            OutByte3(0DBH, 004H, 024H);   (* fild dword[esp]  *)
            OutByte2(0DDH, reg1);         (* fld qword[reg1]  *)
            OutByte2(0D9H, 0FDH);         (* fscale           *)
            OutByte2(0DDH, 018H + reg1);  (* fstp qword[reg1] *)
            OutByte3(0DBH, 01CH, 024H);   (* fistp dword[esp] *)
            pop(reg1);
            drop

        |IL.opUNPK:
            BinOp(reg1, reg2);
            OutByte2(0DDH, reg1);         (* fld qword[reg1]   *)
            OutByte2(0D9H, 0F4H);         (* fxtract           *)
            OutByte2(0DDH, 018H + reg1);  (* fstp qword[reg1]  *)
            OutByte2(0DBH, 018H + reg2);  (* fistp dword[reg2] *)
            drop;
            drop

        |IL.opPUSHF:
            ASSERT(fr >= 0);
            DEC(fr);
            subrc(esp, 8);
            OutByte3(0DDH, 01CH, 024H)    (* fstp qword[esp] *)

        |IL.opLOADF:
            INC(fr);
            IF fr > MAX_FR THEN
                ERRORS.ErrorMsg(fname, param1, param2, FPR_ERR)
            END;
            UnOp(reg1);
            OutByte2(0DDH, reg1);         (* fld qword[reg1] *)
            drop

        |IL.opCONSTF:
            INC(fr);
            IF fr > MAX_FR THEN
                ERRORS.ErrorMsg(fname, param1, param2, FPR_ERR)
            END;
            float := cmd.float;
            IF float = 0.0 THEN
                OutByte2(0D9H, 0EEH)      (* fldz *)
            ELSIF float = 1.0 THEN
                OutByte2(0D9H, 0E8H)      (* fld1 *)
            ELSIF float = -1.0 THEN
                OutByte2(0D9H, 0E8H);     (* fld1 *)
                OutByte2(0D9H, 0E0H)      (* fchs *)
            ELSE
                LoadFltConst(float)
            END

        |IL.opSAVEF, IL.opSAVEFI:
            ASSERT(fr >= 0);
            DEC(fr);
            UnOp(reg1);
            OutByte2(0DDH, 018H + reg1); (* fstp qword[reg1] *)
            drop

        |IL.opADDF:
            ASSERT(fr >= 1);
            DEC(fr);
            OutByte2(0DEH, 0C1H)  (* faddp st1, st *)

        |IL.opSUBF:
            ASSERT(fr >= 1);
            DEC(fr);
            OutByte2(0DEH, 0E9H)  (* fsubp st1, st *)

        |IL.opSUBFI:
            ASSERT(fr >= 1);
            DEC(fr);
            OutByte2(0DEH, 0E1H)  (* fsubrp st1, st *)

        |IL.opMULF:
            ASSERT(fr >= 1);
            DEC(fr);
            OutByte2(0DEH, 0C9H)  (* fmulp st1, st *)

        |IL.opDIVF:
            ASSERT(fr >= 1);
            DEC(fr);
            OutByte2(0DEH, 0F9H)  (* fdivp st1, st *)

        |IL.opDIVFI:
            ASSERT(fr >= 1);
            DEC(fr);
            OutByte2(0DEH, 0F1H)  (* fdivrp st1, st *)

        |IL.opUMINF:
            ASSERT(fr >= 0);
            OutByte2(0D9H, 0E0H)  (* fchs *)

        |IL.opFABS:
            ASSERT(fr >= 0);
            OutByte2(0D9H, 0E1H)  (* fabs *)

        |IL.opFLT:
            INC(fr);
            IF fr > MAX_FR THEN
                ERRORS.ErrorMsg(fname, param1, param2, FPR_ERR)
            END;
            UnOp(reg1);
            push(reg1);
            OutByte3(0DBH, 004H, 024H); (* fild dword[esp] *)
            pop(reg1);
            drop

        |IL.opFLOOR:
            ASSERT(fr >= 0);
            DEC(fr);
            subrc(esp, 8);
            OutByte2(09BH, 0D9H); OutByte3(07CH, 024H, 004H);                   (* fstcw word[esp+4]                    *)
            OutByte2(09BH, 0D9H); OutByte3(07CH, 024H, 006H);                   (* fstcw word[esp+6]                    *)
            OutByte2(066H, 081H); OutByte3(064H, 024H, 004H); OutWord(0F3FFH);  (* and   word[esp+4], 1111001111111111b *)
            OutByte2(066H, 081H); OutByte3(04CH, 024H, 004H); OutWord(00400H);  (* or    word[esp+4], 0000010000000000b *)
            OutByte2(0D9H, 06CH); OutByte2(024H, 004H);                         (* fldcw word[esp+4]                    *)
            OutByte2(0D9H, 0FCH);                                               (* frndint                              *)
            OutByte3(0DBH, 01CH, 024H);                                         (* fistp dword[esp]                     *)
            pop(GetAnyReg());
            OutByte2(0D9H, 06CH); OutByte2(024H, 002H);                         (* fldcw word[esp+2]                    *)
            addrc(esp, 4)

        |IL.opEQF:
            ASSERT(fr >= 1);
            DEC(fr, 2);
            fcmp;
            OutByte2(07AH, 003H);       (* jp L *)
            setcc(sete, al)
                                        (* L: *)

        |IL.opNEF:
            ASSERT(fr >= 1);
            DEC(fr, 2);
            fcmp;
            OutByte2(07AH, 003H);       (* jp L *)
            setcc(setne, al)
                                        (* L: *)

        |IL.opLTF:
            ASSERT(fr >= 1);
            DEC(fr, 2);
            fcmp;
            OutByte2(07AH, 00EH);       (* jp L *)
            setcc(setc, al);
            setcc(sete, ah);
            test(eax);
            setcc(sete, al);
            andrc(eax, 1)
                                        (* L: *)

        |IL.opGTF:
            ASSERT(fr >= 1);
            DEC(fr, 2);
            fcmp;
            OutByte2(07AH, 00FH);       (* jp L *)
            setcc(setc, al);
            setcc(sete, ah);
            cmprc(eax, 1);
            setcc(sete, al);
            andrc(eax, 1)
                                        (* L: *)

        |IL.opLEF:
            ASSERT(fr >= 1);
            DEC(fr, 2);
            fcmp;
            OutByte2(07AH, 003H);       (* jp L *)
            setcc(setnc, al)
                                        (* L: *)

        |IL.opGEF:
            ASSERT(fr >= 1);
            DEC(fr, 2);
            fcmp;
            OutByte2(07AH, 010H);       (* jp L *)
            setcc(setc, al);
            setcc(sete, ah);
            OutByte2(000H, 0E0H);       (* add al, ah *)
            OutByte2(03CH, 001H);       (* cmp al, 1 *)
            setcc(sete, al);
            andrc(eax, 1)
                                        (* L: *)

        |IL.opINF:
            INC(fr);
            IF fr > MAX_FR THEN
                ERRORS.ErrorMsg(fname, param1, param2, FPR_ERR)
            END;
            LoadFltConst(UTILS.inf)


        |IL.opLADR_UNPK:
            n := param2 * 4;
            reg1 := GetAnyReg();
            OutByte2(8DH, 45H + reg1 * 8 + long(n));  (* lea reg1, dword[ebp + n] *)
            OutIntByte(n);
            BinOp(reg1, reg2);
            OutByte2(0DDH, reg1);         (* fld qword[reg1]   *)
            OutByte2(0D9H, 0F4H);         (* fxtract           *)
            OutByte2(0DDH, 018H + reg1);  (* fstp qword[reg1]  *)
            OutByte2(0DBH, 018H + reg2);  (* fistp dword[reg2] *)
            drop;
            drop

        |IL.opSADR_PARAM:
            IF pic THEN
                reg1 := GetAnyReg();
                Pic(reg1, BIN.PICDATA, stroffs + param2);
                push(reg1);
                drop
            ELSE
                OutByte(068H);  (* push _data + stroffs + param2 *)
                Reloc(BIN.RDATA, stroffs + param2)
            END

        |IL.opVADR_PARAM, IL.opLLOAD32_PARAM:
            pushm(ebp, param2 * 4)

        |IL.opCONST_PARAM:
            pushc(param2)

        |IL.opGLOAD32_PARAM:
            IF pic THEN
                reg1 := GetAnyReg();
                Pic(reg1, BIN.PICBSS, param2);
                pushm(reg1, 0);
                drop
            ELSE
                OutByte2(0FFH, 035H);  (* push dword[_bss + param2] *)
                Reloc(BIN.RBSS, param2)
            END

        |IL.opLOAD32_PARAM:
            UnOp(reg1);
            pushm(reg1, 0);
            drop

        |IL.opGADR_SAVEC:
            IF pic THEN
                reg1 := GetAnyReg();
                Pic(reg1, BIN.PICBSS, param1);
                OutByte2(0C7H, reg1);  (* mov dword[reg1], param2 *)
                OutInt(param2);
                drop
            ELSE
                OutByte2(0C7H, 05H);  (* mov dword[_bss + param1], param2 *)
                Reloc(BIN.RBSS, param1);
                OutInt(param2)
            END

        |IL.opLADR_SAVEC:
            n := param1 * 4;
            OutByte2(0C7H, 45H + long(n));  (* mov dword[ebp + n], param2 *)
            OutIntByte(n);
            OutInt(param2)

        |IL.opLADR_SAVE:
            UnOp(reg1);
            movmr(ebp, param2 * 4, reg1);
            drop

        |IL.opLADR_INCC:
            n := param1 * 4;
            IF ABS(param2) = 1 THEN
                OutByte2(0FFH, 45H + 8 * ORD(param2 = -1) + long(n));  (* inc/dec dword[ebp + n] *)
                OutIntByte(n)
            ELSE
                OutByte2(81H + short(param2), 45H + long(n)); (* add dword[ebp + n], param2 *)
                OutIntByte(n);
                OutIntByte(param2)
            END

        |IL.opLADR_INCCB, IL.opLADR_DECCB:
            n := param1 * 4;
            IF param2 = 1 THEN
                OutByte2(0FEH, 45H + 8 * ORD(opcode = IL.opLADR_DECCB) + long(n));  (* inc/dec byte[ebp + n] *)
                OutIntByte(n)
            ELSE
                OutByte2(80H, 45H + 28H * ORD(opcode = IL.opLADR_DECCB) + long(n)); (* add/sub byte[ebp + n], param2 *)
                OutIntByte(n);
                OutByte(param2 MOD 256)
            END

        |IL.opLADR_INC, IL.opLADR_DEC:
            n := param2 * 4;
            UnOp(reg1);
            OutByte2(01H + 28H * ORD(opcode = IL.opLADR_DEC), 45H + long(n) + reg1 * 8); (* add/sub dword[ebp + n], reg1 *)
            OutIntByte(n);
            drop

        |IL.opLADR_INCB, IL.opLADR_DECB:
            n := param2 * 4;
            UnOp(reg1);
            OutByte2(28H * ORD(opcode = IL.opLADR_DECB), 45H + long(n) + reg1 * 8); (* add/sub byte[ebp + n], reg1 *)
            OutIntByte(n);
            drop

        |IL.opLADR_INCL, IL.opLADR_EXCL:
            n := param2 * 4;
            UnOp(reg1);
            cmprc(reg1, 32);
            label := NewLabel();
            jcc(jnb, label);
            OutByte3(0FH, 0ABH + 8 * ORD(opcode = IL.opLADR_EXCL), 45H + long(n) + reg1 * 8); (* bts(r) dword[ebp + n], reg1 *)
            OutIntByte(n);
            SetLabel(label);
            drop

        |IL.opLADR_INCLC, IL.opLADR_EXCLC:
            n := param1 * 4;
            OutByte3(0FH, 0BAH, 6DH + long(n) + 8 * ORD(opcode = IL.opLADR_EXCLC)); (* bts(r) dword[ebp + n], param2 *)
            OutIntByte(n);
            OutByte(param2)

        |IL.opFNAME:
            IL.GetName(param1, fname)

        END;

        cmd := cmd.next
    END;

    (* The loop leaves the tail of the list behind. *)
    IL.freeUpTo(NIL);

    ASSERT(R.pushed = 0);
    ASSERT(R.top = -1);
    ASSERT(fr = -1)
END translate;


PROCEDURE prolog (pic: BOOLEAN; target, stack, dllret, dllfail: INTEGER): INTEGER;
VAR
    reg1, entry, L, dcount: INTEGER;

BEGIN
    entry := NewLabel();
    SetLabel(entry);
    dcount := CHL.Length(IL.codes.data);

    IF target = TARGETS.DPMI32LE THEN
        (* DOS/4GW requires this identification at the protected-mode entry.
           It is a loader signature, not a dependency on the Watcom CRT. *)
        OutByte2(0EBH, 7);
        OutByte3(57H, 41H, 54H); OutByte3(43H, 4FH, 4DH); OutByte(0);
        (* DOS/4GW enters with ES naming the PSP; the RTL needs flat ES. *)
        OutByte2(1EH, 07H); (* push ds; pop es *)
        OutByte(0FCH);      (* cld *)
        OutByte2(0DBH, 0E3H) (* fninit *)
    END;
    push(ebp);
    mov(ebp, esp);
    SetLabel(NewLabel());
    mainFltConstLabel := ncount;
    FltConstLabel := mainFltConstLabel;
    mainFltIns := 0;
    fltIns := 0;
    mainLocVarSize := 0;
    LocVarSize := 0;

    IF target IN {TARGETS.Win32DLL, TARGETS.DPMI32DLL} THEN
        pushm(ebp, 16);  (* the loader's third argument (Win32 DllMain's lpvReserved) *)
        pushm(ebp, 12);
        pushm(ebp, 8);
        CallRTL(pic, IL._dllentry);
        IF target = TARGETS.DPMI32DLL THEN
            (* 1 asks for the module bodies, 2 says the loader wants something
               else and the load stands, 0 is an attach that failed. The zero
               has to reach the loader unchanged: a module whose heap could not
               be attached must not be handed out as loaded, or the first
               allocation in it takes memory the EXE cannot free. See
               lib/dpmi32/API.dllentry. *)
            cmprc(eax, 0);
            jcc(je, dllfail);
            cmprc(eax, 1);
            jcc(jne, dllret)
        ELSE
            test(eax);
            jcc(je, dllret)
        END;
        pushc(0)
    ELSIF target = TARGETS.Linux32 THEN
        mov(eax, ebp);
        addrc(eax, 4);
        push(eax)
    ELSE
        pushc(0)
    END;

    IF pic THEN
        reg1 := GetAnyReg();
        Pic(reg1, BIN.PICCODE, entry);
        push(reg1);    (* push CODE *)
        Pic(reg1, BIN.PICDATA, 0);
        push(reg1);    (* push _data *)
        pushc(tcount);
        Pic(reg1, BIN.PICDATA, tcount * 4 + dcount);
        push(reg1);    (* push _data + tcount * 4 + dcount *)
        drop
    ELSE
        OutByte(68H);  (* push CODE *)
        Reloc(BIN.RCODE, entry);
        OutByte(68H);  (* push _data *)
        Reloc(BIN.RDATA, 0);
        pushc(tcount);
        OutByte(68H);  (* push _data + tcount * 4 + dcount *)
        Reloc(BIN.RDATA, tcount * 4 + dcount)
    END;

    CallRTL(pic, IL._init);

    IF target IN {TARGETS.Win32C, TARGETS.Win32GUI, TARGETS.Linux32, TARGETS.DPMI32PE} THEN
        L := NewLabel();
        pushc(0);
        push(esp);
        (* Include the header skipped by RTL._new, as for ordinary NEW. *)
        pushc(1024 * 1024 * stack + 4 + 12 * ORD(TARGETS.OS = TARGETS.osLINUX32));
        pushc(0);
        CallRTL(pic, IL._new);
        pop(eax);
        test(eax);
        jcc(je, L);
        addrc(eax, 1024 * 1024 * stack - 4);
        mov(esp, eax);
        SetLabel(L)
    END

    RETURN entry
END prolog;


(* The code label of a procedure the runtime module defines, for the one
   export that names a procedure rather than something the code generator
   already holds. The label only has a value once the procedure has been
   emitted, so the caller has to be one that setrtl has already marked used -
   the label of a procedure DelUnused dropped reads as 0. *)
PROCEDURE RtlProc (name: SCAN.IDSTR): INTEGER;
VAR
    id:    PROG.IDENT;
    ident: SCAN.IDENT;
    res:   INTEGER;

BEGIN
    res := 0;
    SCAN.setIdent(ident, name);
    id := PROG.getIdent(PROG.program.rtl, ident, FALSE);

    IF (id # NIL) & (id.proc # NIL) THEN
        id.proc.used := TRUE;
        res := id.proc.label
    ELSE
        ERRORS.WrongRTL(name)
    END;

    RETURN res
END RtlProc;


PROCEDURE epilog (pic: BOOLEAN; modname: ARRAY OF CHAR; target, stack, ver, dllinit, dllret, dllfail, sofinit: INTEGER);
VAR
    exp:  IL.EXPORT_PROC;
    path, name, ext: PATHS.PATH;

    dcount, i: INTEGER;


    PROCEDURE _import (imp: LISTS.LIST);
    VAR
        lib:  IL.IMPORT_LIB;
        proc: IL.IMPORT_PROC;

    BEGIN

        lib := imp.first(IL.IMPORT_LIB);
        WHILE lib # NIL DO
            BIN.Import(program, lib.name, 0);
            proc := lib.procs.first(IL.IMPORT_PROC);
            WHILE proc # NIL DO
                BIN.Import(program, proc.name, proc.label);
                proc := proc.next(IL.IMPORT_PROC)
            END;
            lib := lib.next(IL.IMPORT_LIB)
        END

    END _import;


BEGIN

    IF target IN {TARGETS.Win32C, TARGETS.Win32GUI, TARGETS.Linux32, TARGETS.DPMI32PE, TARGETS.DPMI32LE} THEN
        pushc(0);
        CallRTL(pic, IL._exit);
    ELSIF target IN {TARGETS.Win32DLL, TARGETS.DPMI32DLL} THEN
        SetLabel(dllret);
        movrc(eax, 1);
        OutByte(0C9H); (* leave *)
        OutByte3(0C2H, 0CH, 0); (* ret 12 *)
        IF target = TARGETS.DPMI32DLL THEN
            (* Where an attach that failed lands, so that the 0 the entry
               point answered is the 0 the loader sees. It is reached by a
               jump from the entry code and by nothing else: the module
               bodies fall into the answer 1 above, which is how a load that
               has to stand leaves. *)
            SetLabel(dllfail);
            movrc(eax, 0);
            OutByte(0C9H); (* leave *)
            OutByte3(0C2H, 0CH, 0) (* ret 12 *)
        END
    ELSIF target = TARGETS.Linux32SO THEN
        OutByte(0C9H); (* leave *)
        ret;
        SetLabel(sofinit);
        CallRTL(pic, IL._sofinit);
        ret
    END;

    fixup;

    dcount := CHL.Length(IL.codes.data);

    FOR i := 0 TO tcount - 1 DO
        BIN.PutData32LE(program, CHL.GetInt(IL.codes.types, i))
    END;

    FOR i := 0 TO dcount - 1 DO
        BIN.PutData(program, CHL.GetByte(IL.codes.data, i))
    END;

    program.modname := CHL.Length(program.data);

    PATHS.split(modname, path, name, ext);
    BIN.PutDataStr(program, name);
    BIN.PutDataStr(program, ext);
    BIN.PutData(program, 0);

    (* An HX-DOS EXE owns the process heap, and a DLL it loads has none of its
       own: the DLL is entered with the EXE already holding the one large DPMI
       block, so it must allocate through the EXE instead. The runtime's own
       allocator is therefore exported by name, and the DLL resolves it off
       the main module with GetProcAddress before its first allocation.
       Only the EXE exports it - a DLL has no heap to lend. *)
    IF target = TARGETS.DPMI32PE THEN
        BIN.Export(program, "new", RtlProc("_heapnew"));
        BIN.Export(program, "dispose", RtlProc("_heapdispose"))
    END;

    exp := IL.codes.export.first(IL.EXPORT_PROC);
    WHILE exp # NIL DO
        BIN.Export(program, exp.name, exp.label);
        exp := exp.next(IL.EXPORT_PROC)
    END;

    _import(IL.codes._import);

    IL.set_bss(MAX(IL.codes.bss, MAX(IL.codes.dmin - CHL.Length(IL.codes.data), 4)));

    BIN.SetParams(program, IL.codes.bss, stack * (1024 * 1024), WCHR(ver DIV 65536), WCHR(ver MOD 65536))
END epilog;


PROCEDURE align16* (bit64: BOOLEAN);
BEGIN
    IF TARGETS.WinLin THEN
        WHILE CHL.Length(IL.codes.data) MOD 16 # 0 DO
            CHL.PushByte(IL.codes.data, 0)
        END;
        WHILE CHL.Length(IL.codes.types) MOD (4 - 2*ORD(bit64)) # 0 DO
            CHL.PushInt(IL.codes.types, 0)
        END
    END
END align16;


PROCEDURE CodeGen* (outname: ARRAY OF CHAR; target: INTEGER; options: PROG.OPTIONS);
VAR
    dllret, dllfail, dllinit, sofinit: INTEGER;
    opt: PROG.OPTIONS;

BEGIN
    FR[0] := 0;
    align16(FALSE);
    tcount := CHL.Length(IL.codes.types);

    opt := options;
    IF target = TARGETS.DPMI32LE THEN opt.pic := FALSE END;

    Free;
    program := BIN.create(IL.codes.lcount);

    dllret  := NewLabel();
    dllfail := NewLabel();
    sofinit := NewLabel();

    IF TARGETS.OS = TARGETS.osLINUX32 THEN
        opt.pic := TRUE
    END;

    REG.Init(R, push, pop, mov, xchg, {eax, ecx, edx});

    dllinit := prolog(opt.pic, target, opt.stack, dllret, dllfail);
    translate(opt.pic, tcount * 4, target);
    epilog(opt.pic, outname, target, opt.stack, opt.version, dllinit, dllret, dllfail, sofinit);

    BIN.fixup(program);
    IF target = TARGETS.DPMI32LE THEN
        LE.write(program, outname)
    ELSIF target IN {TARGETS.DPMI32PE, TARGETS.DPMI32DLL} THEN
        PE32.writeHX(program, outname, target = TARGETS.DPMI32DLL, FALSE, opt.PE32FileAlignment)
    ELSIF TARGETS.OS = TARGETS.osWIN32 THEN
        PE32.write(program, outname, FALSE, target = TARGETS.Win32C, target = TARGETS.Win32DLL, FALSE, opt.PE32FileAlignment)
    ELSIF TARGETS.OS = TARGETS.osLINUX32 THEN
        ELF.write(program, outname, sofinit, target = TARGETS.Linux32SO, FALSE)
    END
END CodeGen;


PROCEDURE SetProgram* (prog: BIN.PROGRAM);
BEGIN
    Free;
    program := prog
END SetProgram;


END I386.