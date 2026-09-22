(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    macOS port of the In module: reads stdin a byte at a time through raw
    read(2) syscalls (HOST.FileRead on fd 0) and parses integers/reals by
    hand - no libSystem sscanf.
*)

MODULE In;

IMPORT HOST;


CONST

    STDIN = 0;
    MAX_LEN = 10240;


VAR

    Done*: BOOLEAN;


PROCEDURE GetChar (VAR c: CHAR): BOOLEAN;
VAR
    buf: ARRAY 1 OF CHAR;
    n: INTEGER;

BEGIN
    n := HOST.FileRead(STDIN, buf, 1);
    IF n = 1 THEN
        c := buf[0]
    END

    RETURN n = 1
END GetChar;


PROCEDURE String* (VAR str: ARRAY OF CHAR);
VAR
    i, len: INTEGER;
    c: CHAR;
    ok: BOOLEAN;

BEGIN
    i := 0;
    len := LEN(str) - 1;
    ok := GetChar(c);
    Done := ok;
    WHILE ok & (c # 0AX) & (i < len) DO
        IF c # 0DX THEN
            str[i] := c;
            INC(i)
        END;
        ok := GetChar(c)
    END;
    str[i] := 0X
END String;


PROCEDURE SkipSpaces (VAR c: CHAR; VAR ok: BOOLEAN);
BEGIN
    WHILE ok & ((c = 20X) OR (c = 09X) OR (c = 0AX) OR (c = 0DX)) DO
        ok := GetChar(c)
    END
END SkipSpaces;


PROCEDURE Int* (VAR x: INTEGER);
VAR
    c: CHAR;
    ok, neg, any: BOOLEAN;

BEGIN
    ok := GetChar(c);
    SkipSpaces(c, ok);

    neg := FALSE;
    IF ok & ((c = "+") OR (c = "-")) THEN
        neg := c = "-";
        ok := GetChar(c)
    END;

    x := 0;
    any := FALSE;
    WHILE ok & ("0" <= c) & (c <= "9") DO
        x := x * 10 + (ORD(c) - ORD("0"));
        any := TRUE;
        ok := GetChar(c)
    END;

    IF neg THEN
        x := -x
    END;

    Done := any
END Int;


PROCEDURE Real* (VAR x: REAL);
VAR
    c: CHAR;
    ok, neg, any: BOOLEAN;
    frac, scale: REAL;
    esign: BOOLEAN;
    exp: INTEGER;

BEGIN
    ok := GetChar(c);
    SkipSpaces(c, ok);

    neg := FALSE;
    IF ok & ((c = "+") OR (c = "-")) THEN
        neg := c = "-";
        ok := GetChar(c)
    END;

    x := 0.0;
    any := FALSE;
    WHILE ok & ("0" <= c) & (c <= "9") DO
        x := x * 10.0 + FLT(ORD(c) - ORD("0"));
        any := TRUE;
        ok := GetChar(c)
    END;

    IF ok & (c = ".") THEN
        ok := GetChar(c);
        scale := 0.1;
        WHILE ok & ("0" <= c) & (c <= "9") DO
            x := x + FLT(ORD(c) - ORD("0")) * scale;
            scale := scale / 10.0;
            any := TRUE;
            ok := GetChar(c)
        END
    END;

    IF ok & ((c = "E") OR (c = "e")) THEN
        ok := GetChar(c);
        esign := FALSE;
        IF ok & ((c = "+") OR (c = "-")) THEN
            esign := c = "-";
            ok := GetChar(c)
        END;
        exp := 0;
        WHILE ok & ("0" <= c) & (c <= "9") DO
            exp := exp * 10 + (ORD(c) - ORD("0"));
            ok := GetChar(c)
        END;
        IF esign THEN
            exp := -exp
        END;
        WHILE exp > 0 DO
            x := x * 10.0;
            DEC(exp)
        END;
        WHILE exp < 0 DO
            x := x / 10.0;
            INC(exp)
        END
    END;

    IF neg THEN
        x := -x
    END;

    Done := any
END Real;


PROCEDURE Char* (VAR x: CHAR);
BEGIN
    Done := GetChar(x)
END Char;


PROCEDURE Ln*;
VAR
    c: CHAR;
    ok: BOOLEAN;

BEGIN
    ok := GetChar(c);
    WHILE ok & (c # 0AX) DO
        ok := GetChar(c)
    END;
    Done := TRUE
END Ln;


PROCEDURE Open*;
BEGIN
    Done := TRUE
END Open;


END In.
