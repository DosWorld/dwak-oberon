(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.
*)

MODULE OPT;

IMPORT IL, TARGETS, CHL := CHUNKLISTS;

CONST
    dead = -1;  (* Reserved opNOP parameter; loop markers use 1 and 2. *)


(* Only these commands have no run-time or code-generator state effects.
   In particular, DROP and the procedure/CASE markers are not transparent. *)
PROCEDURE Transparent (cmd: IL.COMMAND): BOOLEAN;
    RETURN (cmd.opcode = IL.opNOP) OR (cmd.opcode = IL.opAND) OR
           (cmd.opcode = IL.opOR)
END Transparent;


PROCEDURE Target (targets: CHL.INTLIST; label: INTEGER): INTEGER;
VAR
    result: INTEGER;
BEGIN
    result := label;
    IF (label >= 0) & (label < IL.codes.lcount) THEN
        result := CHL.GetInt(targets, label)
    END
    RETURN result
END Target;


(* Resolve the functional graph without recursion. -1 means unvisited and
   -2 marks the current path. A cycle is represented by one of its labels;
   its final jump remains a self-loop, preserving nontermination. *)
PROCEDURE Resolve (links, targets: CHL.INTLIST);
VAR
    i, label, dest, next: INTEGER;
BEGIN
    FOR i := 0 TO IL.codes.lcount - 1 DO
        label := i;
        WHILE CHL.GetInt(targets, label) = -1 DO
            CHL.SetInt(targets, label, -2);
            label := CHL.GetInt(links, label)
        END;
        dest := CHL.GetInt(targets, label);
        IF dest = -2 THEN
            dest := label
        END;
        label := i;
        WHILE CHL.GetInt(targets, label) = -2 DO
            next := CHL.GetInt(links, label);
            CHL.SetInt(targets, label, dest);
            label := next
        END
    END
END Resolve;


PROCEDURE Mark (cmd: IL.COMMAND);
BEGIN
    cmd.opcode := IL.opNOP;
    cmd.param1 := 0;
    cmd.param2 := dead
END Mark;


(* Rewrites leave tombstones until Sweep. Only skip those tombstones when
   matching adjacent commands: original NOPs and labels remain barriers. *)
PROCEDURE Next (cmd: IL.COMMAND): IL.COMMAND;
BEGIN
    cmd := cmd.next;
    WHILE (cmd # NIL) & (cmd.opcode = IL.opNOP) & (cmd.param2 = dead) DO
        cmd := cmd.next
    END
    RETURN cmd
END Next;


PROCEDURE Prev (cmd: IL.COMMAND): IL.COMMAND;
BEGIN
    cmd := cmd.prev;
    WHILE (cmd # NIL) & (cmd.opcode = IL.opNOP) & (cmd.param2 = dead) DO
        cmd := cmd.prev
    END
    RETURN cmd
END Prev;


PROCEDURE FuseLoad (cur, next: IL.COMMAND): BOOLEAN;
VAR
    local, indirect, global: INTEGER;
    fused: BOOLEAN;
BEGIN
    local := -1;
    CASE next.opcode OF
    |IL.opLOAD8:  local := IL.opLLOAD8;  indirect := IL.opVLOAD8;  global := IL.opGLOAD8
    |IL.opLOAD16: local := IL.opLLOAD16; indirect := IL.opVLOAD16; global := IL.opGLOAD16
    |IL.opLOAD32: local := IL.opLLOAD32; indirect := IL.opVLOAD32; global := IL.opGLOAD32
    |IL.opLOAD64: local := IL.opLLOAD64; indirect := IL.opVLOAD64; global := IL.opGLOAD64
    ELSE
    END;
    fused := local # -1;
    IF fused THEN
        CASE cur.opcode OF
        |IL.opLADR: cur.opcode := local
        |IL.opVADR: cur.opcode := indirect
        |IL.opGADR: cur.opcode := global
        ELSE fused := FALSE
        END
    END
    RETURN fused
END FuseLoad;


PROCEDURE FuseTarget (cur, nov: IL.COMMAND): BOOLEAN;
VAR
    old_opcode, param2: INTEGER;


    PROCEDURE set (cur: IL.COMMAND; opcode, param2: INTEGER);
    BEGIN
        cur.opcode := opcode;
        cur.param1 := cur.param2;
        cur.param2 := param2
    END set;


BEGIN
    IF IL.codes.cpu IN {TARGETS.cpuI386P, TARGETS.cpuAMD64, TARGETS.cpuMSP430} THEN

        old_opcode := cur.opcode;
        param2 := nov.param2;

        IF (nov.opcode = IL.opPARAM) & (param2 = 1) THEN

            CASE old_opcode OF
            |IL.opGLOAD64: cur.opcode := IL.opGLOAD64_PARAM
            |IL.opLLOAD64: cur.opcode := IL.opLLOAD64_PARAM
            |IL.opLOAD64:  cur.opcode := IL.opLOAD64_PARAM
            |IL.opGLOAD32: cur.opcode := IL.opGLOAD32_PARAM
            |IL.opLLOAD32: cur.opcode := IL.opLLOAD32_PARAM
            |IL.opLOAD32:  cur.opcode := IL.opLOAD32_PARAM
            |IL.opSADR:    cur.opcode := IL.opSADR_PARAM
            |IL.opVADR:    cur.opcode := IL.opVADR_PARAM
            |IL.opCONST:   cur.opcode := IL.opCONST_PARAM
            ELSE
                old_opcode := -1
            END

        ELSIF old_opcode = IL.opLADR THEN

            CASE nov.opcode OF
            |IL.opSAVEC: set(cur, IL.opLADR_SAVEC, param2)
            |IL.opSAVE:  cur.opcode := IL.opLADR_SAVE
            |IL.opINC:   cur.opcode := IL.opLADR_INC
            |IL.opDEC:   cur.opcode := IL.opLADR_DEC
            |IL.opINCB:  cur.opcode := IL.opLADR_INCB
            |IL.opDECB:  cur.opcode := IL.opLADR_DECB
            |IL.opINCL:  cur.opcode := IL.opLADR_INCL
            |IL.opEXCL:  cur.opcode := IL.opLADR_EXCL
            |IL.opUNPK:  cur.opcode := IL.opLADR_UNPK
            |IL.opINCC:  set(cur, IL.opLADR_INCC, param2)
            |IL.opINCCB: set(cur, IL.opLADR_INCCB, param2)
            |IL.opDECCB: set(cur, IL.opLADR_DECCB, param2)
            |IL.opINCLC: set(cur, IL.opLADR_INCLC, param2)
            |IL.opEXCLC: set(cur, IL.opLADR_EXCLC, param2)
            ELSE
                old_opcode := -1
            END

        ELSIF (nov.opcode = IL.opSAVEC) & (old_opcode = IL.opGADR) THEN
            set(cur, IL.opGADR_SAVEC, param2)

        ELSIF (nov.opcode = IL.opMULC) & (old_opcode = IL.opMULC) THEN
            cur.param2 := cur.param2 * param2

        ELSIF (nov.opcode = IL.opADDC) & (old_opcode = IL.opADDC) THEN
            INC(cur.param2, param2)

        ELSE
            old_opcode := -1
        END

    ELSIF IL.codes.cpu IN {TARGETS.cpuTHUMB, TARGETS.cpuRVM32I, TARGETS.cpuRVM64I} THEN

        old_opcode := cur.opcode;
        param2 := nov.param2;

        IF (old_opcode = IL.opLADR) & (nov.opcode = IL.opSAVE) THEN
            cur.opcode := IL.opLADR_SAVE
        ELSIF (old_opcode = IL.opLADR) & (nov.opcode = IL.opINCC) THEN
            set(cur, IL.opLADR_INCC, param2)
        ELSIF (nov.opcode = IL.opMULC) & (old_opcode = IL.opMULC) THEN
            cur.param2 := cur.param2 * param2
        ELSIF (nov.opcode = IL.opADDC) & (old_opcode = IL.opADDC) THEN
            INC(cur.param2, param2)
        ELSE
            old_opcode := -1
        END

    ELSE
        old_opcode := -1
    END;

    RETURN old_opcode # -1
END FuseTarget;


PROCEDURE FusePair (cur, next: IL.COMMAND): BOOLEAN;
VAR
    fused: BOOLEAN;
BEGIN
    fused := TRUE;
    IF (cur.opcode = IL.opNOT) & (next.opcode = IL.opNOT) THEN
        Mark(cur);
        Mark(next)
    ELSIF (cur.opcode = IL.opNOT) &
          ((next.opcode = IL.opJZ) OR (next.opcode = IL.opJNZ)) THEN
        IF next.opcode = IL.opJZ THEN
            next.opcode := IL.opJNZ
        ELSE
            next.opcode := IL.opJZ
        END;
        Mark(cur)
    ELSIF ((cur.opcode = IL.opAND) OR (cur.opcode = IL.opOR)) &
          (next.opcode = IL.opORD) THEN
        Mark(next)
    ELSIF (cur.opcode = IL.opCASEL) & (next.opcode = IL.opCASER) &
          (cur.param1 = next.param1) THEN
        cur.opcode := IL.opCASELR;
        cur.param3 := next.param2;
        Mark(next)
    ELSIF (cur.opcode = IL.opCONST) &
          ((next.opcode = IL.opJZ) OR (next.opcode = IL.opJNZ)) THEN
        IF (cur.param2 = 0) = (next.opcode = IL.opJZ) THEN
            next.opcode := IL.opJMP
        ELSE
            Mark(next)
        END;
        Mark(cur)
    ELSIF FuseLoad(cur, next) OR FuseTarget(cur, next) THEN
        Mark(next)
    ELSE
        fused := FALSE
    END
    RETURN fused
END FusePair;


(* Revisit the surviving left operand after a rewrite. This handles chained
   folds and address/load/parameter triples without repeated full passes. *)
PROCEDURE Pairs;
VAR
    cur, next: IL.COMMAND;
BEGIN
    cur := IL.codes.commands;
    WHILE cur # NIL DO
        next := Next(cur);
        IF (((cur.opcode = IL.opADDC) OR (cur.opcode = IL.opSUBR)) & (cur.param2 = 0)) OR
           (((cur.opcode = IL.opMULC) OR (cur.opcode = IL.opDIVR)) & (cur.param2 = 1)) THEN
            Mark(cur);
            cur := Prev(cur)
        ELSIF (next # NIL) & FusePair(cur, next) THEN
            IF (cur.opcode = IL.opNOP) & (cur.param2 = dead) THEN
                cur := Prev(cur)
            END
        ELSE
            cur := next
        END
    END
END Pairs;


PROCEDURE SetJump (cmd: IL.COMMAND; label: INTEGER);
BEGIN
    cmd.opcode := IL.opJMP;
    cmd.param1 := label;
    cmd.param2 := label
END SetJump;


(* Recognize the Boolean materialization emitted by term/SimpleExpression:
       Jcc B; A: CONST x; DROP; JMP E; B: CONST (1-x); E: AND/OR
   followed by JZ/JNZ. Route both arms directly to the consumer's destination
   or E, and discard the materialized value and its consumer together.
   Keeping A, B and E preserves all earlier short-circuit branch destinations.
   In particular, DROP disappears only as part of this balanced template. *)
PROCEDURE BooleanBranch (marker: IL.COMMAND);
VAR
    part: ARRAY 9 OF IL.COMMAND;
    branch, cmd: IL.COMMAND;
    i, dest: INTEGER;
    valid, taken: BOOLEAN;
BEGIN
    branch := Next(marker);
    IF (branch # NIL) & ((branch.opcode = IL.opJZ) OR (branch.opcode = IL.opJNZ)) THEN
        part[8] := marker;
        cmd := marker;
        i := 7;
        WHILE (i >= 0) & (cmd # NIL) DO
            cmd := Prev(cmd);
            part[i] := cmd;
            DEC(i)
        END;
        valid := cmd # NIL;
        IF valid THEN
            valid := ((part[0].opcode = IL.opJZ) OR (part[0].opcode = IL.opJNZ)) &
                (part[1].opcode = IL.opLABEL) & (part[2].opcode = IL.opCONST) &
                (part[3].opcode = IL.opDROP) & (part[4].opcode = IL.opJMP) &
                (part[5].opcode = IL.opLABEL) & (part[6].opcode = IL.opCONST) &
                (part[7].opcode = IL.opLABEL);
            IF valid THEN
                valid := (part[0].param1 = part[5].param1) &
                    (part[4].param1 = part[7].param1) &
                    ((part[2].param2 = 0) OR (part[2].param2 = 1)) &
                    (part[6].param2 = 1 - part[2].param2)
            END
        END;
        IF valid THEN
            FOR i := 2 TO 6 BY 4 DO
                taken := (part[i].param2 = 0) = (branch.opcode = IL.opJZ);
                IF taken THEN
                    dest := branch.param1
                ELSE
                    dest := part[7].param1
                END;
                SetJump(part[i], dest)
            END;
            Mark(part[3]);
            Mark(part[4]);
            Mark(marker);
            Mark(branch)
        END
    END
END BooleanBranch;


PROCEDURE Booleans (tail: IL.COMMAND);
VAR
    cmd: IL.COMMAND;
BEGIN
    (* An outer Boolean consumer is lowered first, so an inner template may
       feed the conditional jump that remains at the head of the outer one. *)
    cmd := tail;
    WHILE cmd # NIL DO
        IF (cmd.opcode = IL.opAND) OR (cmd.opcode = IL.opOR) THEN
            BooleanBranch(cmd)
        END;
        cmd := cmd.prev
    END
END Booleans;


(* Keep links stable during optimization, then reclaim marked nodes in one
   sweep. The head/tail sentinels and original loop markers are retained. *)
PROCEDURE Sweep;
VAR
    cmd, next: IL.COMMAND;
BEGIN
    cmd := IL.codes.commands;
    WHILE cmd # NIL DO
        next := cmd.next;
        IF (cmd.prev # NIL) & (next # NIL) &
           (cmd.opcode = IL.opNOP) & (cmd.param2 = dead) THEN
            IF IL.getlast() = cmd THEN
                IL.setlast(cmd.prev)
            END;
            IL.delete2(cmd, cmd)
        END;
        cmd := next
    END
END Sweep;


(* A backward walk also handles JMP L; L: JMP M; M: in one pass.
   Conditional jumps must not simply be removed: JZ/JNZ consume a value.
   Likewise, do not delete arbitrary unreachable commands: the back ends
   maintain their expression register stacks by walking the entire stream. *)
PROCEDURE MarkJumps (tail: IL.COMMAND; labels: CHL.INTLIST);
VAR
    cmd, prev, following: IL.COMMAND;
    i, group: INTEGER;
    redundant: BOOLEAN;
BEGIN
    FOR i := 0 TO IL.codes.lcount - 1 DO
        CHL.SetInt(labels, i, -1)
    END;
    group := 0;
    following := NIL;
    cmd := tail;
    WHILE cmd # NIL DO
        prev := cmd.prev;
        IF cmd.opcode = IL.opLABEL THEN
            CHL.SetInt(labels, cmd.param1, group);
            following := cmd
        ELSIF cmd.opcode = IL.opJMP THEN
            redundant := FALSE;
            IF (cmd.param1 >= 0) & (cmd.param1 < IL.codes.lcount) THEN
                redundant := CHL.GetInt(labels, cmd.param1) = group
            END;
            IF redundant THEN
                Mark(cmd)
            ELSE
                (* A second unconditional jump cannot be reached from the
                   first. Stop at every label, including unreferenced ones. *)
                IF (following # NIL) & (following.opcode = IL.opJMP) THEN
                    Mark(following)
                END;
                following := cmd;
                INC(group)
            END
        ELSIF ~Transparent(cmd) THEN
            following := cmd;
            INC(group)
        END;
        cmd := prev
    END
END MarkJumps;


PROCEDURE Optimize*;
VAR
    links, targets: CHL.INTLIST;
    cmd, tail: IL.COMMAND;
    i, dest: INTEGER;
BEGIN
    Pairs;

    links := CHL.CreateIntList();
    targets := CHL.CreateIntList();
    FOR i := 0 TO IL.codes.lcount - 1 DO
        CHL.PushInt(links, i);
        CHL.PushInt(targets, -1)
    END;

    cmd := IL.codes.commands;
    tail := NIL;
    WHILE cmd # NIL DO
        tail := cmd;
        cmd := cmd.next
    END;

    Booleans(tail);

    (* Record adjacent label aliases and labels followed by a JMP. Procedure
       entry points, raw code and all stateful pseudo-ops are barriers. *)
    cmd := tail;
    dest := -1;
    WHILE cmd # NIL DO
        IF cmd.opcode = IL.opLABEL THEN
            IF (dest >= 0) & (dest < IL.codes.lcount) THEN
                CHL.SetInt(links, cmd.param1, dest)
            END;
            dest := cmd.param1
        ELSIF cmd.opcode = IL.opJMP THEN
            dest := cmd.param1
        ELSIF ~Transparent(cmd) THEN
            dest := -1
        END;
        cmd := cmd.prev
    END;
    Resolve(links, targets);

    cmd := IL.codes.commands;
    WHILE cmd # NIL DO
        CASE cmd.opcode OF
        |IL.opJMP, IL.opJZ, IL.opJNZ, IL.opJNZ1, IL.opJG:
            cmd.param1 := Target(targets, cmd.param1);
            cmd.param2 := cmd.param1
        |IL.opCASEL, IL.opCASER:
            cmd.param2 := Target(targets, cmd.param2)
        |IL.opCASELR:
            cmd.param2 := Target(targets, cmd.param2);
            cmd.param3 := Target(targets, cmd.param3)
        ELSE
        END;
        cmd := cmd.next
    END;

    MarkJumps(tail, links);
    Sweep;
    CHL.Free(targets);
    CHL.Free(links)
END Optimize;


END OPT.
