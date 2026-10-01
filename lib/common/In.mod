(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The portable In: text input for every target.  Only the source of the
    characters is platform specific, and that is all ArchIn holds - it hands
    them over one at a time.  Everything that reads meaning into them is
    done here, in Oberon.

    This is the macOS In, which has always parsed by hand, brought up to the
    common layer.  The other three went through C: Linux and Windows by way
    of libc sscanf, HX-DOS by way of a parser of its own.  sscanf accepts
    spellings no Oberon program has reason to produce - "0x1f", "inf", a
    trailing "f" - and it made Done answer a question about the parse, did
    sscanf recognise anything, rather than about the input.  Callers test
    Done to learn that the input has run out, and here that is the only
    thing it means: Done is FALSE only when there was no character left to
    read.

    A real is read as an optional sign, digits, an optional fraction and an
    optional decimal exponent, and that is the whole of the accepted
    spelling.  The value is accumulated in REAL arithmetic, so a literal
    carrying more significant digits than a REAL holds comes back rounded,
    as it must.
*)

MODULE In;

IMPORT ArchIn;


VAR

    Done*: BOOLEAN;


PROCEDURE GetChar (VAR c: CHAR): BOOLEAN;
BEGIN
    RETURN ArchIn.GetChar(c)
END GetChar;


(* A string ends at the line feed.  A carriage return is dropped rather than
   stored, so a line read from a Windows console and a line read from a
   Linux one arrive looking the same. *)
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


(* The sign is taken before the digits, so "-" on its own reads as Done with
   x = 0.  A caller that has to tell a zero from a missing number tests Done
   alone, which is the same answer the hand-written parsers have always
   given. *)
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


(* Done reports the integer part or the fraction having carried a digit -
   not the exponent, which is optional in every language that has one. *)
PROCEDURE Real* (VAR x: REAL);
VAR
    c: CHAR;
    ok, neg, any: BOOLEAN;
    scale: REAL;
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


(* Ln consumes the line feed that ends the line it was called on, so a Ln
   following an Int or a String steps over that line's remainder and stops
   there rather than waiting for the next line. *)
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
    ArchIn.Open;
    Done := TRUE
END Open;


END In.
