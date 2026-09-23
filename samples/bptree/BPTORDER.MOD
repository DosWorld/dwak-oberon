(*
   Public domain
   Copyright (c) 2026-, DosWorld

   Deterministic English, Ukrainian, Czech and German comparators.
   IDs identify these exact rules, not a platform locale or a function address. *)
MODULE BPTOrder;

CONST
    EnglishID* = 1;
    EnglishNoCaseID* = 2;

    UkrainianID* = 3;
    UkrainianNoCaseID* = 4;

    CzechID* = 5;
    CzechNoCaseID* = 6;

    GermanID* = 7;
    GermanNoCaseID* = 8;

PROCEDURE Compare(a, b: ARRAY OF CHAR; fold: BOOLEAN): INTEGER;
VAR i, x, y, result: INTEGER;
BEGIN
    i := 0; result := 0;
    REPEAT
        x := 0; y := 0;
        IF i < LEN(a) THEN x := ORD(a[i]) END;
        IF i < LEN(b) THEN y := ORD(b[i]) END;
        IF fold THEN
            IF (x >= ORD("A")) & (x <= ORD("Z")) THEN INC(x, 32) END;
            IF (y >= ORD("A")) & (y <= ORD("Z")) THEN INC(y, 32) END
        END;
        IF x < y THEN result := -1 ELSIF x > y THEN result := 1 END;
        INC(i)
    UNTIL (result # 0) OR (x = 0);
    RETURN result
END Compare;

PROCEDURE English*(a, b: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN Compare(a, b, FALSE)
END English;

PROCEDURE EnglishNoCase*(a, b: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN Compare(a, b, TRUE)
END EnglishNoCase;

(* Language comparators use primary letter order, then accents, then case.
   They accept validated UTF-8. Unknown characters retain scalar order after
   the supported alphabet. No Unicode normalization is performed. *)
PROCEDURE Scalar(s: ARRAY OF CHAR; VAR i: INTEGER): INTEGER;
VAR x, n, j: INTEGER;
BEGIN
    x := 0;
    IF i < LEN(s) THEN x := ORD(s[i]); INC(i) END;
    IF x >= 192 THEN
        IF x < 224 THEN n := 1; x := x MOD 32
        ELSIF x < 240 THEN n := 2; x := x MOD 16
        ELSE n := 3; x := x MOD 8 END;
        j := 0;
        WHILE (j < n) & (i < LEN(s)) DO
            x := x * 64 + ORD(s[i]) MOD 64; INC(i); INC(j)
        END
    END;
    RETURN x
END Scalar;

PROCEDURE Lower(x: INTEGER): INTEGER;
BEGIN
    IF (x >= 65) & (x <= 90) OR (x >= 192) & (x <= 214) OR
       (x >= 216) & (x <= 222) OR (x >= 1040) & (x <= 1071) THEN INC(x, 32)
    ELSIF (x = 1028) OR (x = 1030) OR (x = 1031) THEN INC(x, 80)
    ELSIF x = 1168 THEN x := 1169
    ELSIF x = 7838 THEN x := 223
    ELSIF (x = 268) OR (x = 270) OR (x = 282) OR (x = 327) OR
          (x = 344) OR (x = 352) OR (x = 356) OR (x = 366) OR (x = 381) THEN INC(x)
    END;
    RETURN x
END Lower;

PROCEDURE Position(alphabet: ARRAY OF CHAR; x: INTEGER): INTEGER;
VAR i, n, c, result: INTEGER;
BEGIN
    i := 0; n := 0; result := 0;
    REPEAT
        c := Scalar(alphabet, i); INC(n);
        IF c = x THEN result := n END
    UNTIL (c = 0) OR (result # 0);
    RETURN result
END Position;

PROCEDURE Element(s: ARRAY OF CHAR; VAR i, pending: INTEGER;
                  language: INTEGER; VAR primary, accent, letterCase: INTEGER);
VAR original, x, j, y, pos: INTEGER;
BEGIN
    accent := 0; letterCase := 0;
    IF pending # 0 THEN primary := pending; pending := 0
    ELSE
        original := Scalar(s, i); x := Lower(original);
        IF original = x THEN letterCase := 1 END;
        primary := x + 1024;
        IF x = 0 THEN primary := 0
        ELSIF language = 1 THEN
            pos := Position("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя", x);
            IF pos # 0 THEN primary := 256 + pos END
        ELSE
            IF language = 2 THEN
                CASE x OF
                225: x := 97; accent := 1 |
                269: x := 99; accent := 10 |
                271: x := 100; accent := 1 |
                233: x := 101; accent := 1 |
                283: x := 101; accent := 2 |
                237: x := 105; accent := 1 |
                328: x := 110; accent := 1 |
                243: x := 111; accent := 1 |
                345: x := 114; accent := 10 |
                353: x := 115; accent := 10 |
                357: x := 116; accent := 1 |
                250: x := 117; accent := 1 |
                367: x := 117; accent := 2 |
                253: x := 121; accent := 1 |
                382: x := 122; accent := 10
                ELSE END
            ELSE
                CASE x OF
                228: x := 97; accent := 1 |
                246: x := 111; accent := 1 |
                252: x := 117; accent := 1 |
                223: x := 115; accent := 1; pending := 256 + (115 - 97) * 2
                ELSE END
            END;
            IF (x >= 97) & (x <= 122) THEN
                primary := 256 + (x - 97) * 2;
                IF accent = 10 THEN INC(primary); accent := 0 END;
                IF (language = 2) & (x = 99) & (primary = 260) THEN
                    j := i; y := Scalar(s, j);
                    IF Lower(y) = 104 THEN
                        i := j; primary := 271;
                        (* Preserve all four case variants of the contraction. *)
                        letterCase := letterCase * 2;
                        IF y = 104 THEN INC(letterCase) END
                    END
                END
            END
        END
    END
END Element;

PROCEDURE LanguageCompare(a, b: ARRAY OF CHAR; language: INTEGER; fold: BOOLEAN): INTEGER;
VAR i, j, pa, pb, x, y, ax, ay, cx, cy, secondary, tertiary, result: INTEGER;
BEGIN
    i := 0; j := 0; pa := 0; pb := 0;
    secondary := 0; tertiary := 0; result := 0;
    REPEAT
        Element(a, i, pa, language, x, ax, cx);
        Element(b, j, pb, language, y, ay, cy);
        IF x < y THEN result := -1 ELSIF x > y THEN result := 1 END;
        IF secondary = 0 THEN
            IF ax < ay THEN secondary := -1 ELSIF ax > ay THEN secondary := 1 END
        END;
        IF tertiary = 0 THEN
            IF cx < cy THEN tertiary := -1 ELSIF cx > cy THEN tertiary := 1 END
        END
    UNTIL (result # 0) OR (x = 0);
    IF result = 0 THEN
        result := secondary;
        IF (result = 0) & ~fold THEN result := tertiary END
    END;
    RETURN result
END LanguageCompare;

PROCEDURE Ukrainian*(a, b: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN LanguageCompare(a, b, 1, FALSE)
END Ukrainian;

PROCEDURE UkrainianNoCase*(a, b: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN LanguageCompare(a, b, 1, TRUE)
END UkrainianNoCase;

PROCEDURE Czech*(a, b: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN LanguageCompare(a, b, 2, FALSE)
END Czech;

PROCEDURE CzechNoCase*(a, b: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN LanguageCompare(a, b, 2, TRUE)
END CzechNoCase;

PROCEDURE German*(a, b: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN LanguageCompare(a, b, 3, FALSE)
END German;

PROCEDURE GermanNoCase*(a, b: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN LanguageCompare(a, b, 3, TRUE)
END GermanNoCase;

END BPTOrder.
