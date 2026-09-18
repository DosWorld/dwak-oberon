(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    HXDOS port of the Out module. No msvcrt and no Win32 DLL imports:
    formatting is done in Oberon and the characters go to the DOS console.

    Two routes reach the screen. Plain output is written with AH=40h, so a
    program that redirects stdout still has its output land in the file. Once
    a colour has been selected there is nothing to negotiate: DOS has no call
    that sets the attribute of the text it is given, so the characters are
    placed in video memory directly, in that attribute. Redirected output
    keeps to the DOS route and loses the colour, the same way it does on
    Windows.
*)

MODULE Out;

IMPORT SYSTEM, DOS;


CONST

    d = 1.0 - 5.0E-12;


VAR

    console: BOOLEAN;                   (* stdout is the console, not a file *)
    Realp: PROCEDURE (x: REAL; width: INTEGER);


PROCEDURE WrStr (adr, len: INTEGER);
BEGIN
    IF len > 0 THEN
        IF console & DOS.AttrOn() THEN
            DOS.WrAttr(adr, len, DOS.Attr())
        ELSE
            DOS.WrBuf(adr, len)
        END
    END
END WrStr;


PROCEDURE Char* (c: CHAR);
BEGIN
    WrStr(SYSTEM.ADR(c), 1)
END Char;


PROCEDURE String* (s: ARRAY OF CHAR);
BEGIN
    WrStr(SYSTEM.ADR(s[0]), LENGTH(s))
END String;


(* A DOS console is an OEM one, so a wide character has to be mapped to the
   code page before it can be written; 866 is the one this target assumes. *)
PROCEDURE WrWChar (c: WCHAR);
VAR
    u, b: INTEGER;
    ch:   CHAR;

BEGIN
    u := ORD(c);
    IF u < 100H THEN
        b := u
    ELSIF (u >= 410H) & (u <= 42FH) THEN
        b := 80H + u - 410H
    ELSIF (u >= 430H) & (u <= 43FH) THEN
        b := 0A0H + u - 430H
    ELSIF (u >= 440H) & (u <= 44FH) THEN
        b := 0E0H + u - 440H
    ELSIF u = 401H THEN
        b := 0F0H
    ELSIF u = 451H THEN
        b := 0F1H
    ELSE
        b := ORD("?")
    END;
    ch := CHR(b);
    WrStr(SYSTEM.ADR(ch), 1)
END WrWChar;


PROCEDURE CharW* (c: WCHAR);
BEGIN
    WrWChar(c)
END CharW;


PROCEDURE StringW* (s: ARRAY OF WCHAR);
VAR
    i, n: INTEGER;

BEGIN
    n := LENGTH(s);
    i := 0;
    WHILE i < n DO
        WrWChar(s[i]);
        INC(i)
    END
END StringW;


PROCEDURE WriteInt (x, n: INTEGER);
VAR
    i: INTEGER;
    a: ARRAY 16 OF CHAR;
    neg: BOOLEAN;

BEGIN
    i := 0;
    IF n < 1 THEN
        n := 1
    END;
    IF x < 0 THEN
        x := -x;
        DEC(n);
        neg := TRUE
    END;
    REPEAT
        a[i] := CHR(x MOD 10 + ORD("0"));
        x := x DIV 10;
        INC(i)
    UNTIL x = 0;
    WHILE n > i DO
        Char(" ");
        DEC(n)
    END;
    IF neg THEN
        Char("-")
    END;
    REPEAT
        DEC(i);
        Char(a[i])
    UNTIL i = 0
END WriteInt;


PROCEDURE IsNan (AValue: REAL): BOOLEAN;
VAR
    h, l: SET;

BEGIN
    SYSTEM.GET(SYSTEM.ADR(AValue), l);
    SYSTEM.GET(SYSTEM.ADR(AValue) + 4, h)
    RETURN (h * {20..30} = {20..30}) & ((h * {0..19} # {}) OR (l * {0..31} # {}))
END IsNan;


PROCEDURE IsInf (x: REAL): BOOLEAN;
    RETURN ABS(x) = SYSTEM.INF()
END IsInf;


PROCEDURE Int* (x, width: INTEGER);
VAR
    i: INTEGER;

BEGIN
    IF x # 80000000H THEN
        WriteInt(x, width)
    ELSE
        FOR i := 12 TO width DO
            Char(20X)
        END;
        String("-2147483648")
    END
END Int;


PROCEDURE OutInf (x: REAL; width: INTEGER);
VAR
    s: ARRAY 5 OF CHAR;
    i: INTEGER;

BEGIN
    IF IsNan(x) THEN
        s := "Nan";
        INC(width)
    ELSIF IsInf(x) & (x > 0.0) THEN
        s := "+Inf"
    ELSIF IsInf(x) & (x < 0.0) THEN
        s := "-Inf"
    END;
    FOR i := 1 TO width - 4 DO
        Char(" ")
    END;
    String(s)
END OutInf;


PROCEDURE Ln*;
BEGIN
    Char(0DX);
    Char(0AX)
END Ln;


PROCEDURE _FixReal (x: REAL; width, p: INTEGER);
VAR
    e, len, i: INTEGER;
    y: REAL;
    minus: BOOLEAN;

BEGIN
    IF IsNan(x) OR IsInf(x) THEN
        OutInf(x, width)
    ELSIF p < 0 THEN
        Realp(x, width)
    ELSE
        len := 0;
        minus := FALSE;
        IF x < 0.0 THEN
            minus := TRUE;
            INC(len);
            x := ABS(x)
        END;
        e := 0;
        WHILE x >= 10.0 DO
            x := x / 10.0;
            INC(e)
        END;
        IF e >= 0 THEN
            len := len + e + p + 1;
            IF x > 9.0 + d THEN
                INC(len)
            END;
            IF p > 0 THEN
                INC(len)
            END
        ELSE
            len := len + p + 2
        END;
        FOR i := 1 TO width - len DO
            Char(" ")
        END;
        IF minus THEN
            Char("-")
        END;
        y := x;
        WHILE (y < 1.0) & (y # 0.0) DO
            y := y * 10.0;
            DEC(e)
        END;
        IF e < 0 THEN
            IF x - FLT(FLOOR(x)) > d THEN
                Char("1");
                x := 0.0
            ELSE
                Char("0");
                x := x * 10.0
            END
        ELSE
            WHILE e >= 0 DO
                IF x - FLT(FLOOR(x)) > d THEN
                    IF x > 9.0 THEN
                        String("10")
                    ELSE
                        Char(CHR(FLOOR(x) + ORD("0") + 1))
                    END;
                    x := 0.0
                ELSE
                    Char(CHR(FLOOR(x) + ORD("0")));
                    x := (x - FLT(FLOOR(x))) * 10.0
                END;
                DEC(e)
            END
        END;
        IF p > 0 THEN
            Char(".")
        END;
        WHILE p > 0 DO
            IF x - FLT(FLOOR(x)) > d THEN
                Char(CHR(FLOOR(x) + ORD("0") + 1));
                x := 0.0
            ELSE
                Char(CHR(FLOOR(x) + ORD("0")));
                x := (x - FLT(FLOOR(x))) * 10.0
            END;
            DEC(p)
        END
    END
END _FixReal;


PROCEDURE Real* (x: REAL; width: INTEGER);
VAR
    e, n, i: INTEGER;
    minus: BOOLEAN;

BEGIN
    IF IsNan(x) OR IsInf(x) THEN
        OutInf(x, width)
    ELSE
        e := 0;
        n := 0;
        IF width > 23 THEN
            n := width - 23;
            width := 23
        ELSIF width < 9 THEN
            width := 9
        END;
        width := width - 5;
        IF x < 0.0 THEN
            x := -x;
            minus := TRUE
        ELSE
            minus := FALSE
        END;
        WHILE x >= 10.0 DO
            x := x / 10.0;
            INC(e)
        END;
        WHILE (x < 1.0) & (x # 0.0) DO
            x := x * 10.0;
            DEC(e)
        END;
        IF x > 9.0 + d THEN
            x := 1.0;
            INC(e)
        END;
        FOR i := 1 TO n DO
            Char(" ")
        END;
        IF minus THEN
            x := -x
        END;
        Realp := Real;
        _FixReal(x, width, width - 3);
        Char("E");
        IF e >= 0 THEN
            Char("+")
        ELSE
            Char("-");
            e := ABS(e)
        END;
        IF e < 100 THEN
            Char("0")
        END;
        IF e < 10 THEN
            Char("0")
        END;
        Int(e, 0)
    END
END Real;


PROCEDURE FixReal* (x: REAL; width, p: INTEGER);
BEGIN
    Realp := Real;
    _FixReal(x, width, p)
END FixReal;


PROCEDURE Open*;
BEGIN
    console := DOS.IsConsole()
END Open;


BEGIN

    (* Until Open has had a chance to look, assume the console. A program that
       never calls it should still get its colours. *)
    console := TRUE

END Out.
