MODULE OutDemo;

IMPORT Console, Out;

VAR
    i: INTEGER;

BEGIN
    Console.open;

    Out.String("DOS Out demo");
    Out.Ln;
    FOR i := 0 TO 3 DO
        Out.String("i =");
        Out.Int(i, 3);
        Out.Ln
    END;
    Out.Real(3.14159, 12);
    Out.Ln;

    Console.exit(TRUE)
END OutDemo.
