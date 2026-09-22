MODULE MyLib;

IMPORT SYSTEM, Out;

TYPE
    Rec = POINTER TO RECORD v: INTEGER END;

VAR
    calls: INTEGER;

PROCEDURE Add* (a, b: INTEGER): INTEGER;
BEGIN
    INC(calls);
    RETURN a + b
END Add;


PROCEDURE Mul* (a, b: INTEGER): INTEGER;
BEGIN
    INC(calls);
    RETURN a * b
END Mul;


PROCEDURE Sub* (a, b: INTEGER): INTEGER;
BEGIN
    INC(calls);
    RETURN a - b
END Sub;


PROCEDURE Calls* (): INTEGER;
    RETURN calls
END Calls;


(* The DLL has no heap of its own. NEW here goes through the EXE's allocator,
   which the runtime resolved at attach, so what comes back lies inside the
   EXE's block and the EXE can read and dispose it. *)
PROCEDURE MakeInt* (v: INTEGER): INTEGER;
VAR
    p: Rec;

BEGIN
    NEW(p);
    p.v := v;

    RETURN SYSTEM.VAL(INTEGER, p)
END MakeInt;


(* And the other way: memory the EXE allocated, released from here. *)
PROCEDURE DropInt* (adr: INTEGER);
VAR
    p: Rec;

BEGIN
    p := SYSTEM.VAL(Rec, adr);
    DISPOSE(p)
END DropInt;


BEGIN
    calls := 0;
    Out.String("DllLib: attached"); Out.Ln
END MyLib.
