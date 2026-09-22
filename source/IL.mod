(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2018-2023, Anton Krotov
    All rights reserved.
*)

MODULE IL;

IMPORT SYSTEM, LISTS, SCAN, STRINGS, CHL := CHUNKLISTS, TARGETS, PATHS;


CONST

    (* How many commands one chunk of the command arena holds. *)
    SLOTS = 1024;

    call_stack* = 0;
    call_win64* = 1;
    call_sysv*  = 2;
    call_fast1* = 3;
    call_fast2* = 4;

    begin_loop* = 1; end_loop* = 2;

    opJMP* = 0; opLABEL* = 1; opCOPYS* = 2; opGADR* = 3; opCONST* = 4; opLLOAD32* = 5;
    opCOPYA* = 6; opCASET* = 7; opMULC* = 8; opMUL* = 9; opDIV* = 10; opMOD* = 11;
    opDIVL* = 12; opMODL* = 13; opDIVR* = 14; opMODR* = 15; opUMINUS* = 16;
    opADD* = 17; opSUB* = 18; opONERR* = 19; opSUBL* = 20; opADDC* = 21; opSUBR* = 22;
    opSAVE* = 23; opSAVEC* = 24; opSAVE8* = 25; opSAVE8C* = 26; (*opCHKBYTE* = 27;*) opDROP* = 28;
    opNOT* = 29;

    opEQ*  = 30; opNE* = opEQ + 1; opLT* = opEQ + 2; opLE* = opEQ + 3; opGT* = opEQ + 4; opGE* = opEQ + 5 (* 35 *);
    opEQC* = 36; opNEC* = opEQC + 1; opLTC* = opEQC + 2; opLEC* = opEQC + 3; opGTC* = opEQC + 4; opGEC* = opEQC + 5; (* 41 *)
    opEQF* = 42; opNEF* = opEQF + 1; opLTF* = opEQF + 2; opLEF* = opEQF + 3; opGTF* = opEQF + 4; opGEF* = opEQF + 5; (* 47 *)
    opEQS* = 48; opNES* = opEQS + 1; opLTS* = opEQS + 2; opLES* = opEQS + 3; opGTS* = opEQS + 4; opGES* = opEQS + 5; (* 53 *)
    opEQSW* = 54; opNESW* = opEQSW + 1; opLTSW* = opEQSW + 2; opLESW* = opEQSW + 3; opGTSW* = opEQSW + 4; opGESW* = opEQSW + 5 (* 59 *);

    opVLOAD32* = 60; opGLOAD32* = 61;

    opJZ* = 62; opJNZ* = 63;

    opSAVE32* = 64; opLLOAD8* = 65;

    opCONSTF* = 66; opLOADF* = 67; opSAVEF* = 68; opMULF* = 69; opDIVF* = 70; opDIVFI* = 71;
    opUMINF* = 72; opSAVEFI* = 73; opSUBFI* = 74; opADDF* = 75; opSUBF* = 76;

    opJNZ1* = 77; opJG* = 78;
    opINCCB* = 79; opDECCB* = 80; opINCB* = 81; opDECB* = 82;

    opCASEL* = 83; opCASER* = 84; opCASELR* = 85;

    opPOPSP* = 86;
    opWIN64CALL* = 87; opWIN64CALLI* = 88; opWIN64CALLP* = 89; opAND* = 90; opOR* = 91;

    opLOAD8* = 92; opLOAD16* = 93; opLOAD32* = 94; opPRECALL* = 95; opRES* = 96; opRESF* = 97;
    opPUSHC* = 98; opSWITCH* = 99;

    opSBOOL* = 100; opSBOOLC* = 101; opNOP* = 102;

    opMULS* = 103; opMULSC* = 104; opDIVS* = 105; opDIVSC* = 106;
    opADDS* = 107; opSUBS* = 108; opERR* = 109; opSUBSL* = 110; opADDSC* = 111; opSUBSR* = 112;
    opUMINS* = 113; opIN* = 114; opINL* = 115; opINR* = 116;
    opRSET* = 117; opRSETL* = 118; opRSETR* = 119; opRSET1* = 120; opLENGTH* = 121;

    opLEAVEC* = 122; opCODE* = 123; opALIGN16* = 124;
    opINCC* = 125; opINC* = 126; opDEC* = 127;
    opINCL* = 128; opEXCL* = 129; opINCLC* = 130; opEXCLC* = 131; opNEW* = 132; opDISP* = 133;
    opPACK* = 134; opPACKC* = 135; opUNPK* = 136; opCOPY* = 137; opENTER* = 138; opLEAVE* = 139;
    opCALL* = 140; opSAVEP* = 141; opCALLP* = 142; opEQP* = 143; opNEP* = 144; opLEAVER* = 145;
    opGET* = 146; opSAVE16* = 147; opABS* = 148; opFABS* = 149; opFLOOR* = 150; opFLT* = 151;
    opGETC* = 152; opORD* = 153; opASR* = 154; opLSL* = 155; opROR* = 156;
    opASR1* = 157; opLSL1* = 158; opROR1* = 159; opASR2* = 160; opLSL2* = 161; opROR2* = 162;
    opPUSHP* = 163; opLADR* = 164; opTYPEGP* = 165; opIS* = 166; opPUSHF* = 167; opVADR* = 168;
    opPUSHT* = 169; opTYPEGR* = 170; opISREC* = 171; opCHKIDX* = 172; opPARAM* = 173;
    opCHKIDX2* = 174; opLEN* = 175; opROT* = 176; opSAVES* = 177; opSADR* = 178; opLENGTHW* = 179;

    (*opCHR* = 180;*) opENDSW* = 181; opLEAVEF* = 182; opCLEANUP* = 183; opMOVE* = 184;
    opLSR* = 185; opLSR1* = 186; opLSR2* = 187;
    opMIN* = 188; opMINC* = 189; opMAX* = 190; opMAXC* = 191; opSYSVALIGN16* = 192;
    opEQB* = 193; opNEB* = 194; opINF* = 195; opWIN64ALIGN16* = 196; opVLOAD8* = 197; opGLOAD8* = 198;
    opLLOAD16* = 199; opVLOAD16* = 200; opGLOAD16* = 201;
    opLOAD64* = 202; opLLOAD64* = 203; opVLOAD64* = 204; opGLOAD64* = 205; opSAVE64* = 206;

    opTYPEGD* = 207; opCALLI* = 208; opPUSHIP* = 209; opSAVEIP* = 210; opEQIP* = 211; opNEIP* = 212;
    opSAVE16C* = 213; (*opWCHR* = 214;*) opHANDLER* = 215;

    opSYSVCALL* = 216; opSYSVCALLI* = 217; opSYSVCALLP* = 218; opFNAME* = 219; opFASTCALL* = 220;


    opSADR_PARAM* = -1; opLOAD64_PARAM* = -2; opLLOAD64_PARAM* = -3; opGLOAD64_PARAM* = -4;
    opVADR_PARAM* = -5; opCONST_PARAM* = -6; opGLOAD32_PARAM* = -7; opLLOAD32_PARAM* = -8;
    opLOAD32_PARAM* = -9;

    opLADR_SAVEC* = -10; opGADR_SAVEC* = -11; opLADR_SAVE* = -12;

    opLADR_INCC* = -13; opLADR_INCCB* = -14; opLADR_DECCB* = -15;
    opLADR_INC* = -16; opLADR_DEC* = -17; opLADR_INCB* = -18; opLADR_DECB* = -19;
    opLADR_INCL* = -20; opLADR_EXCL* = -21; opLADR_INCLC* = -22; opLADR_EXCLC* = -23;
    opLADR_UNPK* = -24;


    _init      *=   0;
    _move      *=   1;
    _strcmpw   *=   2;
    _exit      *=   3;
    _set       *=   4;
    _set1      *=   5;
    _lengthw   *=   6;
    _strcpy    *=   7;
    _length    *=   8;
    _divmod    *=   9;
    _dllentry  *=  10;
    _sofinit   *=  11;
    _arrcpy    *=  12;
    _rot       *=  13;
    _new       *=  14;
    _dispose   *=  15;
    _strcmp    *=  16;
    _error     *=  17;
    _is        *=  18;
    _isrec     *=  19;
    _guard     *=  20;
    _guardrec  *=  21;

    _fmul      *=  22;
    _fdiv      *=  23;
    _fdivi     *=  24;
    _fadd      *=  25;
    _fsub      *=  26;
    _fsubi     *=  27;
    _fcmp      *=  28;
    _floor     *=  29;
    _flt       *=  30;
    _pack      *=  31;
    _unpk      *=  32;


TYPE

    COMMAND* = POINTER TO CMD;

    (* One command of the intermediate language. The stream is a doubly linked
       list of these and every back end walks it from front to back, one node at
       a time, so a node carries its own links and nothing else: no inheritance
       and no type tag, which is what lets a command live in the arena below
       instead of on the heap. *)
    CMD* = RECORD

        opcode*:    INTEGER;
        param1*:    INTEGER;
        param2*:    INTEGER;
        param3*:    INTEGER;
        float*:     REAL;

        next*, prev*: COMMAND

    END;

    (* Commands are made in bulk and every one of them has the same size, so
       they are carved out of chunks instead of being allocated one by one. A
       chunk is a single block as far as the heap is concerned and holds SLOTS
       commands, which on the dpmi32pe target turns a hundred thousand blocks into
       a few hundred and keeps the allocator's block list short. Memory is only
       ever returned a chunk at a time, so an individual command is parked for
       reuse rather than disposed. *)
    CHUNK = POINTER TO RECORD

        next: CHUNK;
        used: INTEGER;
        body: ARRAY SLOTS OF CMD

    END;

    CMDSTACK = POINTER TO RECORD

        data: ARRAY 1000 OF COMMAND;
        top:  INTEGER

    END;

    EXPORT_PROC* = POINTER TO RECORD (LISTS.ITEM)

        label*: INTEGER;
        name*:  SCAN.IDSTR

    END;

    IMPORT_LIB* = POINTER TO RECORD (LISTS.ITEM)

        name*:   SCAN.TEXTSTR;
        procs*:  LISTS.LIST

    END;

    IMPORT_PROC* = POINTER TO RECORD (LISTS.ITEM)

        label*: INTEGER;
        lib*:   IMPORT_LIB;
        name*:  SCAN.TEXTSTR;
        count:  INTEGER

    END;


    CODES = RECORD

        cpu*:       INTEGER;    (* target of this command stream *)
        commands*:  COMMAND;    (* the head of the stream *)
        last:       COMMAND;    (* where the next command goes *)
        begcall:    CMDSTACK;
        endcall:    CMDSTACK;
        export*:    LISTS.LIST;
        _import*:   LISTS.LIST;
        types*:     CHL.INTLIST;
        data*:      CHL.BYTELIST;
        names*:     CHL.BYTELIST;   (* the file names opFNAME commands point at *)
        dmin*:      INTEGER;
        lcount*:    INTEGER;
        bss*:       INTEGER;
        rtl*:       ARRAY 33 OF INTEGER;
        errlabels*: ARRAY 12 OF INTEGER;

        charoffs:   ARRAY 256 OF INTEGER;
        wcharoffs:  ARRAY 65536 OF INTEGER;

        wstr:       ARRAY 4*1024 OF WCHAR
    END;


VAR

    codes*: CODES;

    pool:     COMMAND;  (* the commands given back, linked through next *)
    chunks:   CHUNK;    (* every chunk handed out, newest first *)
    curChunk: CHUNK;    (* the one still being carved from *)


PROCEDURE set_dmin* (value: INTEGER);
BEGIN
    codes.dmin := value
END set_dmin;


PROCEDURE set_bss* (value: INTEGER);
BEGIN
    codes.bss := value
END set_bss;


PROCEDURE set_rtl* (idx, label: INTEGER);
BEGIN
    codes.rtl[idx] := label
END set_rtl;


(* Carve one command out of the arena, opening a fresh chunk once the current
   one is full. A chunk is never released on its own, so a command that is no
   longer wanted goes back to the pool instead (see recycle). *)
PROCEDURE AllocCmd (): COMMAND;
VAR
    cmd: COMMAND;
    adr: INTEGER;

BEGIN
    IF (curChunk = NIL) OR (curChunk.used = SLOTS) THEN
        NEW(curChunk);
        curChunk.next := chunks;
        curChunk.used := 0;
        chunks := curChunk
    END;

    (* SYSTEM.VAL takes its second argument as a designator, so the
       address has to go through a variable first. *)
    adr := SYSTEM.ADR(curChunk.body[curChunk.used]);
    cmd := SYSTEM.VAL(COMMAND, adr);
    INC(curChunk.used);

    RETURN cmd
END AllocCmd;


(* A command that is no longer wanted is parked for the next NewCmd. It belongs
   to a chunk, and a chunk is only ever released whole, so there is nothing to
   give back here. *)
PROCEDURE recycle (cmd: COMMAND);
BEGIN
    cmd.next := pool;
    pool := cmd
END recycle;


PROCEDURE NewCmd (): COMMAND;
VAR
    cmd: COMMAND;

BEGIN
    cmd := pool;
    IF cmd = NIL THEN
        cmd := AllocCmd()
    ELSE
        pool := cmd.next
    END;

    RETURN cmd
END NewCmd;


(* Put `nov` into the stream right after `cur`. The stream is the command list
   itself -- codes.commands is its head -- so there is no separate list object
   to keep in step, and the tail the caller inserts after is codes.last. *)
PROCEDURE link (cur, nov: COMMAND);
VAR
    next: COMMAND;

BEGIN
    ASSERT(cur # NIL);
    ASSERT(nov # NIL);

    next := cur.next;
    nov.prev := cur;
    nov.next := next;
    cur.next := nov;

    IF next # NIL THEN
        next.prev := nov
    END
END link;


(* Take `cmd` out of the stream. Its links are cleared so that a command parked
   in the pool cannot be reached through them. *)
PROCEDURE unlink (cmd: COMMAND);
VAR
    prev, next: COMMAND;

BEGIN
    ASSERT(cmd # NIL);

    prev := cmd.prev;
    next := cmd.next;

    IF prev # NIL THEN
        prev.next := next
    ELSE
        codes.commands := next
    END;

    IF next # NIL THEN
        next.prev := prev
    END;

    cmd.prev := NIL;
    cmd.next := NIL
END unlink;


PROCEDURE setlast* (cmd: COMMAND);
BEGIN
    codes.last := cmd
END setlast;


PROCEDURE getlast* (): COMMAND;
    RETURN codes.last
END getlast;


PROCEDURE PutByte (b: BYTE);
BEGIN
    CHL.PushByte(codes.data, b)
END PutByte;


PROCEDURE AlignData (n: INTEGER);
BEGIN
    WHILE CHL.Length(codes.data) MOD n # 0 DO
        PutByte(0)
    END
END AlignData;


PROCEDURE putstr* (s: ARRAY OF CHAR): INTEGER;
VAR
    i, n, res: INTEGER;
BEGIN
    IF TARGETS.WinLin THEN
        AlignData(16)
    END;
    res := CHL.Length(codes.data);
    i := 0;
    n := LENGTH(s);
    WHILE i < n DO
        PutByte(ORD(s[i]));
        INC(i)
    END;

    PutByte(0)

    RETURN res
END putstr;


PROCEDURE putstr1* (c: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF codes.charoffs[c] = -1 THEN
        IF TARGETS.WinLin THEN
            AlignData(16)
        END;
        res := CHL.Length(codes.data);
        PutByte(c);
        PutByte(0);
        codes.charoffs[c] := res
    ELSE
        res := codes.charoffs[c]
    END

    RETURN res
END putstr1;


PROCEDURE putstrW* (s: ARRAY OF CHAR): INTEGER;
VAR
    i, n, res: INTEGER;

BEGIN
    IF TARGETS.WinLin THEN
        AlignData(16)
    ELSE
        AlignData(2)
    END;
    res := CHL.Length(codes.data);

    n := STRINGS.Utf8To16(s, codes.wstr);

    i := 0;
    WHILE i < n DO
        IF TARGETS.LittleEndian THEN
            PutByte(ORD(codes.wstr[i]) MOD 256);
            PutByte(ORD(codes.wstr[i]) DIV 256)
        ELSE
            PutByte(ORD(codes.wstr[i]) DIV 256);
            PutByte(ORD(codes.wstr[i]) MOD 256)
        END;
        INC(i)
    END;

    PutByte(0);
    PutByte(0)

    RETURN res
END putstrW;


PROCEDURE putstrW1* (c: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF codes.wcharoffs[c] = -1 THEN
        IF TARGETS.WinLin THEN
            AlignData(16)
        ELSE
            AlignData(2)
        END;
        res := CHL.Length(codes.data);

        IF TARGETS.LittleEndian THEN
            PutByte(c MOD 256);
            PutByte(c DIV 256)
        ELSE
            PutByte(c DIV 256);
            PutByte(c MOD 256)
        END;

        PutByte(0);
        PutByte(0);

        codes.wcharoffs[c] := res
    ELSE
        res := codes.wcharoffs[c]
    END

    RETURN res
END putstrW1;


PROCEDURE push (stk: CMDSTACK; cmd: COMMAND);
BEGIN
    INC(stk.top);
    stk.data[stk.top] := cmd
END push;


PROCEDURE pop (stk: CMDSTACK): COMMAND;
VAR
    res: COMMAND;
BEGIN
    res := stk.data[stk.top];
    DEC(stk.top)
    RETURN res
END pop;


PROCEDURE pushBegEnd* (VAR beg, _end: COMMAND);
BEGIN
    push(codes.begcall, beg);
    push(codes.endcall, _end);
    beg := codes.last;
    _end := beg.next
END pushBegEnd;


PROCEDURE popBegEnd* (VAR beg, _end: COMMAND);
BEGIN
    beg := pop(codes.begcall);
    _end := pop(codes.endcall)
END popBegEnd;


PROCEDURE AddRec* (base: INTEGER);
BEGIN
    CHL.PushInt(codes.types, base)
END AddRec;


PROCEDURE insert (cur, nov: COMMAND);
BEGIN
    link(cur, nov);
    codes.last := nov
END insert;


PROCEDURE AddCmd* (opcode: INTEGER; param: INTEGER);
VAR
    cmd: COMMAND;
BEGIN
    cmd := NewCmd();
    cmd.opcode := opcode;
    cmd.param1 := 0;
    cmd.param2 := param;
    insert(codes.last, cmd)
END AddCmd;


PROCEDURE AddCmd2* (opcode: INTEGER; param1, param2: INTEGER);
VAR
    cmd: COMMAND;
BEGIN
    cmd := NewCmd();
    cmd.opcode := opcode;
    cmd.param1 := param1;
    cmd.param2 := param2;
    insert(codes.last, cmd)
END AddCmd2;


PROCEDURE Const* (val: INTEGER);
BEGIN
    AddCmd(opCONST, val)
END Const;


PROCEDURE StrAdr* (adr: INTEGER);
BEGIN
    AddCmd(opSADR, adr)
END StrAdr;


PROCEDURE Param1*;
BEGIN
    AddCmd(opPARAM, 1)
END Param1;


PROCEDURE NewLabel* (): INTEGER;
BEGIN
    INC(codes.lcount)
    RETURN codes.lcount - 1
END NewLabel;


PROCEDURE SetLabel* (label: INTEGER);
BEGIN
    AddCmd2(opLABEL, label, 0)
END SetLabel;


PROCEDURE SetErrLabel* (errno: INTEGER);
BEGIN
    codes.errlabels[errno] := NewLabel();
    SetLabel(codes.errlabels[errno])
END SetErrLabel;


PROCEDURE AddCmd0* (opcode: INTEGER);
BEGIN
    AddCmd(opcode, 0)
END AddCmd0;


PROCEDURE delete2* (first, last: COMMAND);
VAR
    cur, next: COMMAND;

BEGIN
    cur := first;

    IF first # last THEN
        REPEAT
            next := cur.next;
            unlink(cur);
            recycle(cur);
            cur := next
        UNTIL cur = last
    END;

    unlink(cur);
    recycle(cur)
END delete2;


PROCEDURE Jmp* (opcode: INTEGER; label: INTEGER);
BEGIN
    AddCmd2(opcode, label, label)
END Jmp;


PROCEDURE OnError* (line, error: INTEGER);
BEGIN
    AddCmd2(opONERR, codes.errlabels[error], line)
END OnError;


PROCEDURE TypeGuard* (op, t: INTEGER; line, error: INTEGER);
VAR
    label: INTEGER;
BEGIN
    AddCmd(op, t);
    label := NewLabel();
    Jmp(opJNZ, label);
    OnError(line, error);
    SetLabel(label)
END TypeGuard;


PROCEDURE TypeCheck* (t: INTEGER);
BEGIN
    AddCmd(opIS, t)
END TypeCheck;


PROCEDURE TypeCheckRec* (t: INTEGER);
BEGIN
    AddCmd(opISREC, t)
END TypeCheckRec;


PROCEDURE New* (size, typenum: INTEGER);
BEGIN
    AddCmd2(opNEW, typenum, size)
END New;


PROCEDURE not*;
BEGIN
    AddCmd0(opNOT)
END not;


PROCEDURE _ord*;
BEGIN
    AddCmd0(opORD)
END _ord;


PROCEDURE Enter* (label, params: INTEGER): COMMAND;
VAR
    cmd: COMMAND;

BEGIN
    cmd := NewCmd();
    cmd.opcode := opENTER;
    cmd.param1 := label;
    cmd.param3 := params;
    insert(codes.last, cmd)

    RETURN codes.last
END Enter;


PROCEDURE Leave* (result, float: BOOLEAN; locsize, paramsize: INTEGER): COMMAND;
BEGIN
    IF result THEN
        IF float THEN
            AddCmd2(opLEAVEF, locsize, paramsize)
        ELSE
            AddCmd2(opLEAVER, locsize, paramsize)
        END
    ELSE
        AddCmd2(opLEAVE, locsize, paramsize)
    END

    RETURN codes.last
END Leave;


PROCEDURE EnterC* (label: INTEGER): COMMAND;
BEGIN
    SetLabel(label)
    RETURN codes.last
END EnterC;


PROCEDURE LeaveC* (): COMMAND;
BEGIN
    AddCmd0(opLEAVEC)
    RETURN codes.last
END LeaveC;


PROCEDURE fastcall (VAR callconv: INTEGER);
BEGIN
    IF callconv = call_fast1 THEN
        AddCmd(opFASTCALL, 1);
        callconv := call_stack
    ELSIF callconv = call_fast2 THEN
        AddCmd(opFASTCALL, 2);
        callconv := call_stack
    END
END fastcall;


PROCEDURE Call* (proc, callconv, fparams: INTEGER);
BEGIN
    fastcall(callconv);
    CASE callconv OF
    |call_stack: Jmp(opCALL, proc)
    |call_win64: Jmp(opWIN64CALL, proc)
    |call_sysv:  Jmp(opSYSVCALL, proc)
    END;
    codes.last.param2 := fparams
END Call;


PROCEDURE CallImp* (proc: LISTS.ITEM; callconv, fparams: INTEGER);
BEGIN
    fastcall(callconv);
    CASE callconv OF
    |call_stack: Jmp(opCALLI, proc(IMPORT_PROC).label)
    |call_win64: Jmp(opWIN64CALLI, proc(IMPORT_PROC).label)
    |call_sysv:  Jmp(opSYSVCALLI, proc(IMPORT_PROC).label)
    END;
    codes.last.param2 := fparams
END CallImp;


PROCEDURE CallP* (callconv, fparams: INTEGER);
BEGIN
    fastcall(callconv);
    CASE callconv OF
    |call_stack: AddCmd0(opCALLP)
    |call_win64: AddCmd(opWIN64CALLP, fparams)
    |call_sysv:  AddCmd(opSYSVCALLP, fparams)
    END
END CallP;


PROCEDURE AssignProc* (proc: INTEGER);
BEGIN
    Jmp(opSAVEP, proc)
END AssignProc;


PROCEDURE AssignImpProc* (proc: LISTS.ITEM);
BEGIN
    Jmp(opSAVEIP, proc(IMPORT_PROC).label)
END AssignImpProc;


PROCEDURE PushProc* (proc: INTEGER);
BEGIN
    Jmp(opPUSHP, proc)
END PushProc;


PROCEDURE PushImpProc* (proc: LISTS.ITEM);
BEGIN
    Jmp(opPUSHIP, proc(IMPORT_PROC).label)
END PushImpProc;


PROCEDURE ProcCmp* (proc: INTEGER; eq: BOOLEAN);
BEGIN
    IF eq THEN
        Jmp(opEQP, proc)
    ELSE
        Jmp(opNEP, proc)
    END
END ProcCmp;


PROCEDURE ProcImpCmp* (proc: LISTS.ITEM; eq: BOOLEAN);
BEGIN
    IF eq THEN
        Jmp(opEQIP, proc(IMPORT_PROC).label)
    ELSE
        Jmp(opNEIP, proc(IMPORT_PROC).label)
    END
END ProcImpCmp;


PROCEDURE load* (size: INTEGER);
BEGIN
    CASE size OF
    |1: AddCmd0(opLOAD8)
    |2: AddCmd0(opLOAD16)
    |4: AddCmd0(opLOAD32)
    |8: AddCmd0(opLOAD64)
    END
END load;


PROCEDURE SysPut* (size: INTEGER);
BEGIN
    CASE size OF
    |1: AddCmd0(opSAVE8)
    |2: AddCmd0(opSAVE16)
    |4: AddCmd0(opSAVE32)
    |8: AddCmd0(opSAVE64)
    END
END SysPut;


PROCEDURE savef* (inv: BOOLEAN);
BEGIN
    IF inv THEN
        AddCmd0(opSAVEFI)
    ELSE
        AddCmd0(opSAVEF)
    END
END savef;


PROCEDURE saves* (offset, length: INTEGER);
BEGIN
    AddCmd2(opSAVES, length, offset)
END saves;


PROCEDURE abs* (real: BOOLEAN);
BEGIN
    IF real THEN
        AddCmd0(opFABS)
    ELSE
        AddCmd0(opABS)
    END
END abs;


PROCEDURE shift_minmax* (op: CHAR);
BEGIN
    CASE op OF
    |"A": AddCmd0(opASR)
    |"L": AddCmd0(opLSL)
    |"O": AddCmd0(opROR)
    |"R": AddCmd0(opLSR)
    |"m": AddCmd0(opMIN)
    |"x": AddCmd0(opMAX)
    END
END shift_minmax;


PROCEDURE shift_minmax1* (op: CHAR; x: INTEGER);
BEGIN
    CASE op OF
    |"A": AddCmd(opASR1, x)
    |"L": AddCmd(opLSL1, x)
    |"O": AddCmd(opROR1, x)
    |"R": AddCmd(opLSR1, x)
    |"m": AddCmd(opMINC, x)
    |"x": AddCmd(opMAXC, x)
    END
END shift_minmax1;


PROCEDURE shift_minmax2* (op: CHAR; x: INTEGER);
BEGIN
    CASE op OF
    |"A": AddCmd(opASR2, x)
    |"L": AddCmd(opLSL2, x)
    |"O": AddCmd(opROR2, x)
    |"R": AddCmd(opLSR2, x)
    |"m": AddCmd(opMINC, x)
    |"x": AddCmd(opMAXC, x)
    END
END shift_minmax2;


PROCEDURE len* (dim: INTEGER);
BEGIN
    AddCmd(opLEN, dim)
END len;


PROCEDURE Float* (r: REAL; line, col: INTEGER);
VAR
    cmd: COMMAND;

BEGIN
    cmd := NewCmd();
    cmd.opcode := opCONSTF;
    cmd.float := r;
    cmd.param1 := line;
    cmd.param2 := col;
    insert(codes.last, cmd)
END Float;


PROCEDURE drop*;
BEGIN
    AddCmd0(opDROP)
END drop;


PROCEDURE _case* (a, b, L, R: INTEGER);
BEGIN
    AddCmd2(opCASEL, a, L);
    AddCmd2(opCASER, b, R)
END _case;


(* The name of the source file the commands that follow come from. It is 2048
   characters, far too big to travel inside a command, so it goes into a byte
   list of its own and the command carries where it starts. *)
PROCEDURE fname* (name: PATHS.PATH);
VAR
    cmd: COMMAND;

BEGIN
    cmd := NewCmd();
    cmd.opcode := opFNAME;
    cmd.param1 := CHL.PushStr(codes.names, name);
    insert(codes.last, cmd)
END fname;


(* The file name an opFNAME command stands for. The back ends read it to build
   the error messages they print while translating. *)
PROCEDURE GetName* (idx: INTEGER; VAR name: PATHS.PATH);
BEGIN
    ASSERT(CHL.GetStr(codes.names, idx, name))
END GetName;


PROCEDURE AddExp* (label: INTEGER; name: SCAN.IDSTR);
VAR
    exp: EXPORT_PROC;

BEGIN
    NEW(exp);
    exp.label := label;
    exp.name  := name;
    LISTS.push(codes.export, exp)
END AddExp;


PROCEDURE AddImp* (dll, proc: SCAN.TEXTSTR): IMPORT_PROC;
VAR
    lib: IMPORT_LIB;
    p:   IMPORT_PROC;

BEGIN
    lib := codes._import.first(IMPORT_LIB);
    WHILE (lib # NIL) & (lib.name # dll) DO
        lib := lib.next(IMPORT_LIB)
    END;

    IF lib = NIL THEN
        NEW(lib);
        lib.name := dll;
        lib.procs := LISTS.create(NIL);
        LISTS.push(codes._import, lib)
    END;

    p := lib.procs.first(IMPORT_PROC);
    WHILE (p # NIL) & (p.name # proc) DO
        p := p.next(IMPORT_PROC)
    END;

    IF p = NIL THEN
        NEW(p);
        p.name  := proc;
        p.label := NewLabel();
        p.lib   := lib;
        p.count := 1;
        LISTS.push(lib.procs, p)
    ELSE
        INC(p.count)
    END

    RETURN p
END AddImp;


PROCEDURE DelImport* (imp: LISTS.ITEM);
VAR
    lib: IMPORT_LIB;
    p:   IMPORT_PROC;

BEGIN
    p := imp(IMPORT_PROC);
    DEC(p.count);

    IF p.count = 0 THEN
        lib := p.lib;
        LISTS.delete(lib.procs, p);

        IF lib.procs.first = NIL THEN
            LISTS.delete(codes._import, lib);
            DISPOSE(lib.procs);
            DISPOSE(lib)
        END;

        DISPOSE(p)
    END
END DelImport;


PROCEDURE init* (pCPU: INTEGER);
VAR
    cmd: COMMAND;
    i:   INTEGER;

BEGIN
    pool := NIL;
    chunks := NIL;
    curChunk := NIL;

    codes.cpu := pCPU;

    NEW(codes.begcall);
    codes.begcall.top := -1;
    NEW(codes.endcall);
    codes.endcall.top := -1;
    codes.export   := LISTS.create(NIL);
    codes._import  := LISTS.create(NIL);
    codes.types    := CHL.CreateIntList();
    codes.data     := CHL.CreateByteList();
    codes.names    := CHL.CreateByteList();

    (* Two nops open the stream and codes.last stops at the first of them, so
       the first command the front end adds lands between the two. *)
    cmd := NewCmd(); cmd.opcode := opNOP; cmd.param2 := 0; cmd.prev := NIL; cmd.next := NIL;
    codes.commands := cmd;
    codes.last := cmd;
    cmd := NewCmd(); cmd.opcode := opNOP; cmd.param2 := 0; link(codes.last, cmd);

    AddRec(0);

    codes.lcount := 0;

    FOR i := 0 TO LEN(codes.charoffs) - 1 DO
        codes.charoffs[i] := -1
    END;

    FOR i := 0 TO LEN(codes.wcharoffs) - 1 DO
        codes.wcharoffs[i] := -1
    END

END init;


(* Unlink and release every node of `list`. The nodes go one at a time because
   DISPOSE invalidates the pointer it is given. The caller keeps the now empty
   header and disposes it itself. *)
PROCEDURE FreeNodes (list: LISTS.LIST);
VAR
    itm: LISTS.ITEM;

BEGIN
    itm := list.first;

    WHILE itm # NIL DO
        list.first := itm.next;
        DISPOSE(itm);
        itm := list.first
    END;

    list.last := NIL
END FreeNodes;


(* Hand back the commands code generation has already walked past. The back ends
   move through the command list strictly forwards and never look back, so every
   node before `cmd` is dead by the time the caller reaches it. Passing NIL
   releases the whole remainder, which is what the callers do once their loop is
   over. `cmd` itself is never touched.

   The commands go back to the pool, not to the heap: their memory belongs to a
   chunk, and a chunk is only ever released whole. Since nothing allocates a
   command during code generation the pool just sits there, which is fine -- the
   peak was reached while the front end was still running. *)
PROCEDURE freeUpTo* (cmd: COMMAND);
VAR
    cur: COMMAND;

BEGIN
    cur := codes.commands;

    WHILE (cur # NIL) & (cur # cmd) DO
        unlink(cur);
        recycle(cur);
        cur := codes.commands
    END
END freeUpTo;


(* Release everything IL allocated. Only valid once code generation is over; the
   module must not be used afterwards. *)
PROCEDURE Free*;
VAR
    node:  LISTS.ITEM;
    lib:   IMPORT_LIB;
    chunk: CHUNK;

BEGIN
    freeUpTo(NIL);
    codes.last := NIL;

    FreeNodes(codes.export);
    DISPOSE(codes.export);

    node := codes._import.first;
    WHILE node # NIL DO
        codes._import.first := node.next;
        lib := node(IMPORT_LIB);
        FreeNodes(lib.procs);
        DISPOSE(lib.procs);
        DISPOSE(lib);
        node := codes._import.first
    END;
    codes._import.last := NIL;
    DISPOSE(codes._import);

    (* Every command came out of a chunk, so the pool needs no draining: the
       commands still parked on it go away with the chunks that hold them, and
       so does the stream itself, whose nodes are the very same memory. *)
    WHILE chunks # NIL DO
        chunk := chunks;
        chunks := chunk.next;
        DISPOSE(chunk)
    END;
    curChunk := NIL;
    pool := NIL;
    codes.commands := NIL;
    codes.last := NIL;

    DISPOSE(codes.begcall);
    DISPOSE(codes.endcall);

    CHL.Free(codes.data);
    CHL.Free(codes.types);
    CHL.Free(codes.names)
END Free;


END IL.