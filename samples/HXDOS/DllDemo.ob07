MODULE DllDemo;

IMPORT SYSTEM, Console, Out, DOS, API;

TYPE
    Rec = POINTER TO RECORD v: INTEGER END;

    BinOp*   = PROCEDURE (a, b: INTEGER): INTEGER;
    GetInt*  = PROCEDURE (): INTEGER;
    PutGet*  = PROCEDURE (v: INTEGER): INTEGER;
    Dropper* = PROCEDURE (adr: INTEGER);

VAR
    h, adr, res, n: INTEGER;
    base, size, handle: INTEGER;
    add, mul: BinOp;
    mk: PutGet;
    cnt: GetInt;
    drop: Dropper;
    p: Rec;

BEGIN
    Console.open;

    API.HeapInfo(base, size, handle);
    Out.String("DllDemo: heap at "); Out.Int(base, 0);
    Out.String(" size "); Out.Int(size, 0); Out.Ln;

    h := DOS.Load("DLLLIB.DLL");
    IF h = 0 THEN
        Out.String("DllDemo: cannot load DLLLIB.DLL"); Out.Ln
    ELSE
        Out.String("DllDemo: DLLLIB.DLL at "); Out.Int(h, 0); Out.Ln;

        adr := DOS.GetProc(h, "Add");
        add := SYSTEM.VAL(BinOp, adr);
        adr := DOS.GetProc(h, "Mul");
        mul := SYSTEM.VAL(BinOp, adr);
        adr := DOS.GetProc(h, "Calls");
        cnt := SYSTEM.VAL(GetInt, adr);
        adr := DOS.GetProc(h, "MakeInt");
        mk := SYSTEM.VAL(PutGet, adr);
        adr := DOS.GetProc(h, "DropInt");
        drop := SYSTEM.VAL(Dropper, adr);

        res := add(2, 3);
        Out.String("DllDemo: Add(2,3) ="); Out.Int(res, 0); Out.Ln;

        res := mul(6, 7);
        Out.String("DllDemo: Mul(6,7) ="); Out.Int(res, 0); Out.Ln;

        n := cnt();
        Out.String("DllDemo: calls  ="); Out.Int(n, 0);
        Out.String(" (2 means the module body ran once)"); Out.Ln;

        (* Allocated inside the DLL. One heap means this address falls inside
           the block the EXE took, and the EXE's own DISPOSE can release it. *)
        n := mk(4242);
        Out.String("DllDemo: DLL gave "); Out.Int(n, 0);
        IF (n >= base) & (n < base + size) THEN
            Out.String(" - inside the EXE heap"); Out.Ln
        ELSE
            Out.String(" - OUTSIDE the EXE heap"); Out.Ln
        END;

        p := SYSTEM.VAL(Rec, n);
        Out.String("DllDemo: value     ="); Out.Int(p.v, 0); Out.Ln;
        DISPOSE(p);
        Out.String("DllDemo: disposed by the EXE"); Out.Ln;

        (* And the reverse: the EXE allocates, the DLL releases. *)
        NEW(p); p.v := 99;
        Out.String("DllDemo: EXE gave  "); Out.Int(SYSTEM.VAL(INTEGER, p), 0); Out.Ln;
        drop(SYSTEM.VAL(INTEGER, p));
        Out.String("DllDemo: disposed by the DLL"); Out.Ln;

        IF DOS.Free(h) THEN
            Out.String("DllDemo: freed"); Out.Ln
        ELSE
            Out.String("DllDemo: free failed"); Out.Ln
        END
    END;

    Out.String("DllDemo: done"); Out.Ln
END DllDemo.
