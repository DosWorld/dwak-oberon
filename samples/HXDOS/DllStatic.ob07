MODULE DllStatic;

IMPORT SYSTEM, Console, Out, API;

CONST
    DLLLIB = "DLLLIB.DLL";

TYPE
    Rec = POINTER TO RECORD v: INTEGER END;

VAR
    res, base, size, handle: INTEGER;
    p: Rec;

(* A link-time import. The loader resolves DLLLIB.DLL while this program is
   being loaded, so the module has to be next to it before it starts. The
   convention is the one a plain Oberon procedure is compiled with, so an
   exported Oberon procedure is directly callable this way. The third element
   of the flag is the name to look for in the DLL and "" means the name the
   declaration itself uses.

   The DLL is entered before this program's own module body runs, and it takes
   its allocator from the main module at that point - so the heap is already
   shared by the time either of them allocates. *)
PROCEDURE [windows-, DLLLIB, ""] Add* (a, b: INTEGER): INTEGER;
PROCEDURE [windows-, DLLLIB, ""] Mul* (a, b: INTEGER): INTEGER;
PROCEDURE [windows-, DLLLIB, ""] Sub* (a, b: INTEGER): INTEGER;
PROCEDURE [windows-, DLLLIB, ""] Calls* (): INTEGER;
PROCEDURE [windows-, DLLLIB, ""] MakeInt* (v: INTEGER): INTEGER;
PROCEDURE [windows-, DLLLIB, ""] DropInt* (adr: INTEGER);

BEGIN
    Console.open;

    API.HeapInfo(base, size, handle);
    Out.String("DllStatic: heap at "); Out.Int(base, 0);
    Out.String(" size "); Out.Int(size, 0); Out.Ln;

    res := Add(2, 3);
    Out.String("DllStatic: Add(2,3) ="); Out.Int(res, 0); Out.Ln;

    res := Mul(6, 7);
    Out.String("DllStatic: Mul(6,7) ="); Out.Int(res, 0); Out.Ln;

    (* Not commutative, so the argument order is settled by the sign. *)
    res := Sub(9, 4);
    Out.String("DllStatic: Sub(9,4) ="); Out.Int(res, 0);
    Out.String(" (5 means the arguments arrived in order)"); Out.Ln;

    res := Calls();
    Out.String("DllStatic: calls  ="); Out.Int(res, 0); Out.Ln;

    res := MakeInt(4242);
    Out.String("DllStatic: DLL gave "); Out.Int(res, 0);
    IF (res >= base) & (res < base + size) THEN
        Out.String(" - inside the EXE heap"); Out.Ln
    ELSE
        Out.String(" - OUTSIDE the EXE heap"); Out.Ln
    END;

    p := SYSTEM.VAL(Rec, res);
    Out.String("DllStatic: value     ="); Out.Int(p.v, 0); Out.Ln;
    DISPOSE(p);
    Out.String("DllStatic: disposed by the EXE"); Out.Ln;

    NEW(p); p.v := 99;
    DropInt(SYSTEM.VAL(INTEGER, p));
    Out.String("DllStatic: EXE-allocated record dropped by the DLL"); Out.Ln;

    Out.String("DllStatic: done"); Out.Ln
END DllStatic.
