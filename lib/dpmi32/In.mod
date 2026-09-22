(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    HXDOS port of the In module. No msvcrt and no Win32 DLL imports: parsing
    is done in Oberon on top of the buffered DOS line input, AH=0Ah.
*)

MODULE In;

IMPORT SYSTEM, DOS;


CONST

    (* The buffer is roomy, but AH=0Ah counts with a single byte, so a line
       can carry at most 254 characters. *)
    MAX_LEN = 1024;


VAR

    Done*: BOOLEAN;
    s: ARRAY MAX_LEN + 4 OF CHAR;


(* DOS fills the buffer as [0] maximum, [1] count, [2..] the characters, so
   the text starts two bytes in and is moved down before it is handed out. *)
PROCEDURE String* (VAR str: ARRAY OF CHAR);
VAR
    count: INTEGER;

BEGIN
    DOS.RdLine(SYSTEM.ADR(s[0]), MAX_LEN, count);
    IF count < 0 THEN
        count := 0
    END;
    SYSTEM.MOVE(SYSTEM.ADR(s[2]), SYSTEM.ADR(s[0]), count);
    s[count] := 0X;
    COPY(s, str);
    str[LEN(str) - 1] := 0X;
    Done := TRUE
END String;


PROCEDURE Int* (VAR x: INTEGER);
VAR
    i, sign, res: INTEGER;

BEGIN
    String(s);
    i := 0;
    sign := 1;
    res := 0;
    Done := FALSE;

    WHILE (s[i] = " ") OR (s[i] = 09X) DO
        INC(i)
    END;
    IF s[i] = "-" THEN
        sign := -1;
        INC(i)
    ELSIF s[i] = "+" THEN
        INC(i)
    END;
    WHILE (s[i] >= "0") & (s[i] <= "9") DO
        res := res * 10 + (ORD(s[i]) - ORD("0"));
        INC(i);
        Done := TRUE
    END;
    x := sign * res
END Int;


PROCEDURE Real* (VAR x: REAL);
VAR
    i, exp, esign, k: INTEGER;
    res, frac: REAL;
    haveInt, haveFrac: BOOLEAN;

BEGIN
    String(s);
    i := 0;
    res := 0.0;
    frac := 0.1;
    exp := 0;
    esign := 1;
    Done := FALSE;

    WHILE (s[i] = " ") OR (s[i] = 09X) DO
        INC(i)
    END;
    IF s[i] = "-" THEN
        esign := -1;
        INC(i)
    ELSIF s[i] = "+" THEN
        INC(i)
    END;

    haveInt := FALSE;
    WHILE (s[i] >= "0") & (s[i] <= "9") DO
        res := res * 10.0 + FLT(ORD(s[i]) - ORD("0"));
        INC(i);
        haveInt := TRUE
    END;

    haveFrac := FALSE;
    IF s[i] = "." THEN
        INC(i);
        WHILE (s[i] >= "0") & (s[i] <= "9") DO
            res := res + frac * FLT(ORD(s[i]) - ORD("0"));
            frac := frac / 10.0;
            INC(i);
            haveFrac := TRUE
        END
    END;

    Done := haveInt OR haveFrac;

    IF (s[i] = "E") OR (s[i] = "e") THEN
        INC(i);
        k := 1;
        IF s[i] = "-" THEN
            k := -1;
            INC(i)
        ELSIF s[i] = "+" THEN
            INC(i)
        END;
        exp := 0;
        WHILE (s[i] >= "0") & (s[i] <= "9") DO
            exp := exp * 10 + (ORD(s[i]) - ORD("0"));
            INC(i)
        END;
        exp := exp * k
    END;

    IF exp > 0 THEN
        FOR k := 1 TO exp DO
            res := res * 10.0
        END
    ELSIF exp < 0 THEN
        FOR k := 1 TO -exp DO
            res := res / 10.0
        END
    END;

    x := FLT(esign) * res
END Real;


PROCEDURE Char* (VAR x: CHAR);
BEGIN
    String(s);
    x := s[0]
END Char;


PROCEDURE Ln*;
BEGIN
    String(s)
END Ln;


PROCEDURE Open*;
BEGIN
    Done := TRUE
END Open;


END In.
