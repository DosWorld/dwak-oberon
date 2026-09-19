MODULE RemTest;

IMPORT SYSTEM, Console, Out, Args, File;

VAR
    f, n, i: INTEGER;
    buf: ARRAY 32 OF CHAR;
    a: ARRAY 64 OF CHAR;

BEGIN
    Console.open;

    FOR i := 0 TO 2 DO
        Args.GetArg(i, a);
        Out.String("arg"); Out.Int(i, 0);
        Out.String("=["); Out.String(a); Out.String("] ")
    END;
    Out.Ln;

    f := File.Create("REMT.TXT");
    Out.String("create="); Out.Int(f, 0); Out.Ln;
    buf[0] := "H"; buf[1] := "I"; buf[2] := "!";
    n := File.Write(f, SYSTEM.ADR(buf[0]), 3);
    Out.String("write="); Out.Int(n, 0); Out.Ln;
    File.Close(f);

    f := File.Open("REMT.TXT", 0);
    n := File.Read(f, SYSTEM.ADR(buf[0]), 3);
    buf[3] := 0X;
    Out.String("read="); Out.Int(n, 0);
    Out.String(" data="); Out.String(buf); Out.Ln;
    File.Close(f);

    IF File.Delete("REMT.TXT") THEN
        Out.String("deleted"); Out.Ln
    END;

    Console.exit(TRUE)
END RemTest.
