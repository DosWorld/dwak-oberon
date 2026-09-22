(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2018-2021, 2023, 2025, Anton Krotov
    All rights reserved.

    Strings - the string library shared by every target.

    Everything under lib/common is compiled for every target, so this
    module has to stay inside the dialect's common subset.  The rules
    that actually bite here, each one checked against the compiler:

        - RETURN is the trailing clause of a *function* body.  It cannot
          appear inside IF or WHILE, and a proper procedure cannot use it
          at all.  Every place that used to return early now computes a
          result into a variable and falls through to one trailing RETURN.
        - LOOP and EXIT do not exist.  A WHILE with a flag replaces them.
        - MIN and MAX take two operands, never a type, so MIN(INTEGER) is
          not available and the most negative value is handled by
          arithmetic instead (see FromInt).
        - A character constant is written 09X.  0X09 is the integer 9.
        - Only POINTER TO RECORD is legal; a pointer to an array is not.
        - A procedure has to be declared before it is called, so the
          character predicates and Cap come first.
        - Identifiers are case sensitive, and a module name must match its
          file name exactly.

    Unicode lives at the end of the file.  WCHAR and WCHR only exist when
    the target is 32 bits or more, so Utf8To16 is compiled conditionally.
*)

MODULE Strings;


CONST

    MAXSTR* = 1024;


(* Cap, Letter, Digit, HexDigit and Space come first because CheckVer,
   StrToVer and ToUpper call them.  Letter accepts an underscore as well as
   the ASCII letters, HexDigit the upper case digits only, and Space
   everything above 0X and up to 20X. *)

PROCEDURE Cap* (VAR c: CHAR);
BEGIN
    IF ("a" <= c) & (c <= "z") THEN
        c := CHR(ORD(c) - ORD("a") + ORD("A"))
    END
END Cap;


PROCEDURE Letter* (c: CHAR): BOOLEAN;
BEGIN
    RETURN ("a" <= c) & (c <= "z") OR ("A" <= c) & (c <= "Z") OR (c = "_")
END Letter;


PROCEDURE Digit* (c: CHAR): BOOLEAN;
BEGIN
    RETURN ("0" <= c) & (c <= "9")
END Digit;


PROCEDURE HexDigit* (c: CHAR): BOOLEAN;
BEGIN
    RETURN ("0" <= c) & (c <= "9") OR ("A" <= c) & (c <= "F")
END HexDigit;


PROCEDURE Space* (c: CHAR): BOOLEAN;
BEGIN
    RETURN (0X < c) & (c <= 20X)
END Space;


(* Length - number of characters before the terminating 0X.
   Parameters: s - the string.
   Result: its length, at most LEN(s). *)
PROCEDURE Length* (s: ARRAY OF CHAR): INTEGER;
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO
        INC(i)
    END

    RETURN i
END Length;


(* Copy - copy src into dst and terminate it.
   Parameters: src - the source string; dst - receives it.
   Result: TRUE when all of src fitted. *)
PROCEDURE Copy* (src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR): BOOLEAN;
VAR
    i, room: INTEGER;
    ok: BOOLEAN;

BEGIN
    room := LEN(dst) - 1;
    i := 0;
    WHILE (i < LEN(src)) & (i < room) & (src[i] # 0X) DO
        dst[i] := src[i];
        INC(i)
    END;
    IF i < LEN(dst) THEN
        dst[i] := 0X
    END;

    ok := i >= LEN(src);
    IF ~ok THEN
        ok := src[i] = 0X
    END

    RETURN ok
END Copy;


(* CopyRange - copy count characters of src, from spos, into dst at dpos.
   Nothing is terminated and neither array is resized; the copy simply
   stops at whichever end comes first.
   Parameters: src, dst - the buffers; spos, dpos - the offsets they start
   at; count - how many characters to move. *)
PROCEDURE CopyRange* (src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR; spos, dpos, count: INTEGER);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < count) & (spos + i < LEN(src)) & (dpos + i < LEN(dst)) DO
        dst[dpos + i] := src[spos + i];
        INC(i)
    END
END CopyRange;


(* Append - append src to the end of dst and re-terminate it.
   Parameters: src - the string to add; dst - the string it is added to.
   Result: TRUE when all of src fitted. *)
PROCEDURE Append* (src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR): BOOLEAN;
VAR
    i, j, room: INTEGER;
    ok: BOOLEAN;

BEGIN
    i := 0;
    WHILE (i < LEN(dst)) & (dst[i] # 0X) DO
        INC(i)
    END;
    room := LEN(dst) - 1;

    j := 0;
    WHILE (j < LEN(src)) & (i < room) & (src[j] # 0X) DO
        dst[i] := src[j];
        INC(i);
        INC(j)
    END;
    IF i < LEN(dst) THEN
        dst[i] := 0X
    END;

    ok := j >= LEN(src);
    IF ~ok THEN
        ok := src[j] = 0X
    END

    RETURN ok
END Append;


(* Compare - order two strings, character by character, a missing character
   counting as 0X.  The loop carries a flag rather than returning early.
   Parameters: s1, s2 - the strings.
   Result: -1 if s1 < s2, 0 if they are equal, 1 if s1 > s2. *)
PROCEDURE Compare* (s1, s2: ARRAY OF CHAR): INTEGER;
VAR
    i, res: INTEGER;
    c1, c2: CHAR;
    done: BOOLEAN;

BEGIN
    i := 0;
    res := 0;
    done := FALSE;
    WHILE ~done DO
        c1 := 0X;
        c2 := 0X;
        IF i < LEN(s1) THEN c1 := s1[i] END;
        IF i < LEN(s2) THEN c2 := s2[i] END;
        IF c1 # c2 THEN
            done := TRUE;
            IF c1 < c2 THEN res := -1 ELSE res := 1 END
        ELSIF c1 = 0X THEN
            done := TRUE
        ELSE
            INC(i)
        END
    END

    RETURN res
END Compare;


PROCEDURE Equal* (s1, s2: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN Compare(s1, s2) = 0
END Equal;


(* Extract - copy at most n characters of src, from pos, into dst.
   Parameters: src - the source string; pos - where to start, clamped to
   the string; n - how many characters at most; dst - receives the text. *)
PROCEDURE Extract* (src: ARRAY OF CHAR; pos, n: INTEGER; VAR dst: ARRAY OF CHAR);
VAR
    i, slen: INTEGER;

BEGIN
    slen := Length(src);
    IF pos < 0 THEN pos := 0 END;
    IF pos > slen THEN pos := slen END;

    i := 0;
    WHILE (i < n) & (pos + i < slen) & (i < LEN(dst) - 1) DO
        dst[i] := src[pos + i];
        INC(i)
    END;
    IF i < LEN(dst) THEN
        dst[i] := 0X
    END
END Extract;


(* Insert - insert src into dst at pos, pushing the existing text right.
   Parameters: src - the text to insert; pos - where, clamped to dst;
   dst - the string that is modified.
   Result: TRUE when everything fitted. *)
PROCEDURE Insert* (src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR): BOOLEAN;
VAR
    dlen, i: INTEGER;
    tail: ARRAY MAXSTR OF CHAR;
    ok: BOOLEAN;

BEGIN
    dlen := Length(dst);
    IF pos < 0 THEN pos := 0 END;
    IF pos > dlen THEN pos := dlen END;

    i := 0;
    WHILE (pos + i < dlen) & (i < MAXSTR - 1) DO
        tail[i] := dst[pos + i];
        INC(i)
    END;
    tail[i] := 0X;

    IF pos < LEN(dst) THEN dst[pos] := 0X END;

    ok := Append(src, dst);
    ok := Append(tail, dst) & ok;

    RETURN ok
END Insert;


(* Delete - remove n characters of s, starting at pos.
   Parameters: s - the string that is modified; pos - where to start;
   n - how many characters to drop. *)
PROCEDURE Delete* (VAR s: ARRAY OF CHAR; pos, n: INTEGER);
VAR
    len, i: INTEGER;

BEGIN
    len := Length(s);
    IF pos < 0 THEN pos := 0 END;
    IF (pos < len) & (n > 0) THEN
        IF pos + n > len THEN n := len - pos END;

        i := pos;
        WHILE (i + n < len) & (i < LEN(s) - 1) DO
            s[i] := s[i + n];
            INC(i)
        END;
        IF i < LEN(s) THEN s[i] := 0X END
    END
END Delete;


(* Replace - replace every occurrence of old in s with new.  The rewrite is
   done in place: a longer replacement first shifts the remaining text
   right, a shorter one shifts it left.  Nothing is buffered, so the result
   is limited by LEN(s) alone rather than by MAXSTR.
   Parameters: old - the text to look for, an empty string matching
   nothing; new - what it becomes; s - the string that is modified.
   Result: TRUE when the whole result fitted in s. *)
PROCEDURE Replace* (old, new: ARRAY OF CHAR; VAR s: ARRAY OF CHAR): BOOLEAN;
VAR
    olen, nlen, slen, i, j, k: INTEGER;
    ok: BOOLEAN;

BEGIN
    olen := Length(old);
    nlen := Length(new);
    slen := Length(s);
    ok := TRUE;

    IF olen > 0 THEN
        i := 0;
        WHILE (i + olen <= slen) & ok DO
            j := 0;
            WHILE (j < olen) & (s[i + j] = old[j]) DO
                INC(j)
            END;
            IF j < olen THEN
                INC(i)
            ELSIF nlen > olen THEN
                IF slen + nlen - olen >= LEN(s) THEN
                    ok := FALSE
                ELSE
                    k := slen;
                    WHILE k > i DO
                        DEC(k);
                        s[k + nlen - olen] := s[k]
                    END;
                    k := 0;
                    WHILE k < nlen DO
                        s[i + k] := new[k];
                        INC(k)
                    END;
                    slen := slen + nlen - olen;
                    i := i + nlen
                END
            ELSE
                k := 0;
                WHILE k < nlen DO
                    s[i + k] := new[k];
                    INC(k)
                END;
                IF nlen < olen THEN
                    k := i + nlen;
                    WHILE k + olen - nlen < slen DO
                        s[k] := s[k + olen - nlen];
                        INC(k)
                    END;
                    slen := slen - (olen - nlen)
                END;
                i := i + nlen
            END
        END;
        IF slen < LEN(s) THEN
            s[slen] := 0X
        END
    END

    RETURN ok
END Replace;


(* ReplaceChar - replace every occurrence of one character with another.
   Parameters: s - the string that is modified; find - the character to
   look for; repl - what it becomes. *)
PROCEDURE ReplaceChar* (VAR s: ARRAY OF CHAR; find, repl: CHAR);
VAR
    i, len: INTEGER;

BEGIN
    len := Length(s);
    i := 0;
    WHILE i < len DO
        IF s[i] = find THEN
            s[i] := repl
        END;
        INC(i)
    END
END ReplaceChar;


(* Pos - find the first occurrence of pat in s.
   Parameters: pat - the text to look for, an empty pattern matching at 0;
   s - the string searched.
   Result: the offset of the first match, or -1. *)
PROCEDURE Pos* (pat, s: ARRAY OF CHAR): INTEGER;
VAR
    i, j, plen, slen, res: INTEGER;

BEGIN
    plen := Length(pat);
    slen := Length(s);
    res := -1;

    IF plen = 0 THEN
        res := 0
    ELSIF plen <= slen THEN
        i := 0;
        WHILE (res < 0) & (i <= slen - plen) DO
            j := 0;
            WHILE (j < plen) & (s[i + j] = pat[j]) DO
                INC(j)
            END;
            IF j = plen THEN
                res := i
            ELSE
                INC(i)
            END
        END
    END

    RETURN res
END Pos;


(* Search - move pos to the next (or previous) occurrence of a character.
   Parameters: s - the string searched; pos - where to start, and where the
   answer lands; c - the character looked for; forward - the direction.
   The result is -1 when there is no such character; a backward search that
   runs off the front also answers -1. *)
PROCEDURE Search* (s: ARRAY OF CHAR; VAR pos: INTEGER; c: CHAR; forward: BOOLEAN);
VAR
    len: INTEGER;

BEGIN
    len := Length(s);

    IF (0 <= pos) & (pos < len) THEN
        IF forward THEN
            WHILE (pos < len) & (s[pos] # c) DO
                INC(pos)
            END;
            IF pos = len THEN
                pos := -1
            END
        ELSE
            WHILE (pos >= 0) & (s[pos] # c) DO
                DEC(pos)
            END
        END
    ELSE
        pos := -1
    END
END Search;


(* ToUpper - fold every lower case letter of s to upper case, in place.
   Only the ASCII range is touched; UTF-8 bytes are left alone, which keeps
   a multi-byte sequence intact.
   Parameters: s - the string that is modified. *)
PROCEDURE ToUpper* (VAR s: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO
        Cap(s[i]);
        INC(i)
    END
END ToUpper;


(* ToLower - fold every upper case letter of s to lower case, in place.
   Parameters: s - the string that is modified. *)
PROCEDURE ToLower* (VAR s: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO
        IF ("A" <= s[i]) & (s[i] <= "Z") THEN
            s[i] := CHR(ORD(s[i]) - ORD("A") + ORD("a"))
        END;
        INC(i)
    END
END ToLower;


(* Reverse - reverse the characters of s in place.
   Parameters: s - the string that is modified. *)
PROCEDURE Reverse* (VAR s: ARRAY OF CHAR);
VAR
    i, j: INTEGER;
    c: CHAR;

BEGIN
    i := 0;
    j := Length(s) - 1;
    WHILE i < j DO
        c := s[i]; s[i] := s[j]; s[j] := c;
        INC(i); DEC(j)
    END
END Reverse;


(* Trim - drop leading and trailing spaces and tabs from s, in place.
   Parameters: s - the string that is modified. *)
PROCEDURE Trim* (VAR s: ARRAY OF CHAR);
VAR
    i, j, start, len: INTEGER;

BEGIN
    len := Length(s);
    start := 0;
    WHILE (start < len) & ((s[start] = " ") OR (s[start] = 09X)) DO
        INC(start)
    END;
    j := len - 1;
    WHILE (j >= start) & ((s[j] = " ") OR (s[j] = 09X)) DO
        DEC(j)
    END;

    i := 0;
    WHILE start + i <= j DO
        s[i] := s[start + i];
        INC(i)
    END;
    IF i < LEN(s) THEN s[i] := 0X END
END Trim;


(* TrimTo - copy source into result with the leading and trailing characters
   at or below 20X removed.  Unlike Trim this leaves source alone, which is
   what is wanted when the source is a token the parser still owns.
   Parameters: source - the string to trim; result - receives it. *)
PROCEDURE TrimTo* (source: ARRAY OF CHAR; VAR result: ARRAY OF CHAR);
VAR
    first, last, i, j: INTEGER;

BEGIN
    last := Length(source) - 1;
    j := 0;

    IF last >= 0 THEN
        first := 0;
        WHILE (first <= last) & (source[first] <= 20X) DO
            INC(first)
        END;
        WHILE (last >= 0) & (source[last] <= 20X) DO
            DEC(last)
        END;

        i := first;
        WHILE i <= last DO
            IF j < LEN(result) - 1 THEN
                result[j] := source[i];
                INC(j)
            END;
            INC(i)
        END
    END;

    IF j < LEN(result) THEN
        result[j] := 0X
    END
END TrimTo;


(* ToInt - read a decimal integer from the front of s, skipping leading
   blanks and accepting one leading sign.  Trailing rubbish is ignored, so
   the result is only FALSE when there is no digit at all.
   Parameters: s - the text; value - receives the number, 0 on failure.
   Result: TRUE when a digit was found. *)
PROCEDURE ToInt* (s: ARRAY OF CHAR; VAR value: INTEGER): BOOLEAN;
VAR
    i, n, len: INTEGER;
    neg, ok: BOOLEAN;

BEGIN
    len := Length(s);
    i := 0;
    WHILE (i < len) & ((s[i] = " ") OR (s[i] = 09X)) DO
        INC(i)
    END;

    neg := FALSE;
    IF (i < len) & ((s[i] = "-") OR (s[i] = "+")) THEN
        neg := s[i] = "-";
        INC(i)
    END;

    value := 0;
    ok := i < len;
    IF ok THEN
        ok := (s[i] >= "0") & (s[i] <= "9")
    END;

    IF ok THEN
        n := 0;
        WHILE (i < len) & (s[i] >= "0") & (s[i] <= "9") DO
            n := n * 10 + (ORD(s[i]) - ORD("0"));
            INC(i)
        END;
        IF neg THEN n := -n END;
        value := n
    END

    RETURN ok
END ToInt;


(* FromInt - write value in decimal into s.
   The digits are taken straight off the value without ever negating it.
   That is deliberate: MIN(INTEGER) has no positive counterpart, so the
   usual "make it positive, then peel off the digits" overflows on exactly
   one input.  Instead the negative value is divided down as it stands.
   In this dialect DIV floors and MOD is always non-negative, so
   v = (v DIV 10) * 10 + (v MOD 10) holds for a negative v as well; the
   remainder is 10-d rather than d, and the quotient is then one too small,
   which the +1 below corrects.  A v that is already a multiple of ten
   needs no correction.
   Parameters: value - the number; s - receives the text, truncated to fit
   and always terminated. *)
PROCEDURE FromInt* (value: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    buf: ARRAY 24 OF CHAR;
    i, j, v, d: INTEGER;

BEGIN
    v := value;
    i := 0;

    IF v < 0 THEN
        REPEAT
            d := v MOD 10;
            IF d = 0 THEN
                buf[i] := "0";
                v := v DIV 10
            ELSE
                buf[i] := CHR(ORD("0") + 10 - d);
                v := v DIV 10 + 1
            END;
            INC(i)
        UNTIL v = 0;
        buf[i] := "-";
        INC(i)
    ELSE
        REPEAT
            buf[i] := CHR(ORD("0") + v MOD 10);
            INC(i);
            v := v DIV 10
        UNTIL v = 0
    END;

    j := 0;
    WHILE (j < i) & (j < LEN(s) - 1) DO
        s[j] := buf[i - 1 - j];
        INC(j)
    END;
    IF j < LEN(s) THEN
        s[j] := 0X
    END
END FromInt;


(* CheckVer - test whether str is a version: digits, a dot, then digits,
   and nothing else.
   Parameters: str - the text.
   Result: TRUE when str has that shape. *)
PROCEDURE CheckVer (str: ARRAY OF CHAR): BOOLEAN;
VAR
    i, k: INTEGER;
    res: BOOLEAN;

BEGIN
    k := Length(str);
    res := k < LEN(str);

    IF res & Digit(str[0]) THEN
        i := 0;
        WHILE (i < k) & Digit(str[i]) DO
            INC(i)
        END;
        IF (i < k) & (str[i] = ".") THEN
            INC(i);
            IF i < k THEN
                WHILE (i < k) & Digit(str[i]) DO
                    INC(i)
                END
            ELSE
                res := FALSE
            END
        ELSE
            res := FALSE
        END;

        res := res & (i = k)
    ELSE
        res := FALSE
    END

    RETURN res
END CheckVer;


(* StrToVer - split a version string into its two numbers.
   Parameters: str - the text, in the shape CheckVer accepts; major, minor -
   receive the numbers.
   Result: TRUE when str was a version. *)
PROCEDURE StrToVer* (str: ARRAY OF CHAR; VAR major, minor: INTEGER): BOOLEAN;
VAR
    i: INTEGER;
    res: BOOLEAN;

BEGIN
    res := CheckVer(str);

    IF res THEN
        i := 0;
        minor := 0;
        major := 0;
        WHILE Digit(str[i]) DO
            major := major * 10 + ORD(str[i]) - ORD("0");
            INC(i)
        END;
        INC(i);
        WHILE Digit(str[i]) DO
            minor := minor * 10 + ORD(str[i]) - ORD("0");
            INC(i)
        END
    END

    RETURN res
END StrToVer;


(* HashStr - hash a name.  The value is only meaningful inside one run of
   one program: it is never written to a file, so any consistent function
   would do; this folding is kept because the compiler's symbol table was
   built with it.  On a 16-bit target there is no room for the fold, and
   the plain accumulation stands.
   Parameters: name - the text.
   Result: its hash. *)
PROCEDURE HashStr* (name: ARRAY OF CHAR): INTEGER;
VAR
    i, h: INTEGER;
    g: SET;

BEGIN
    h := 0;
    i := 0;
    WHILE (i < LEN(name)) & (name[i] # 0X) DO
        h := h * 16 + ORD(name[i]);
        $IF (BITS_32 | BITS_64)
            g := BITS(h) * {28..31};
            h := ORD(BITS(h) / BITS(LSR(ORD(g), 24)) - g)
        $END;
        INC(i)
    END

    RETURN h
END HashStr;


$IF (BITS_32 | BITS_64)
(* Utf8To16 - decode UTF-8 text into UTF-16 code units.
   Well formed sequences of up to three bytes are decoded; a byte that
   starts no sequence is passed through as its own code unit, and a
   truncated sequence at the end of src simply stops the decode.  The
   result is terminated with WCHR(0) when there is room for it.
   Parameters: src - the UTF-8 text; dst - receives the code units.
   Result: the number of code units written, not counting the terminator.
   WCHAR only exists when the target is 32 bits or more, which is why this
   procedure is compiled conditionally. *)
PROCEDURE Utf8To16* (src: ARRAY OF CHAR; VAR dst: ARRAY OF WCHAR): INTEGER;
VAR
    i, j, u, srclen, dstlen: INTEGER;
    c: CHAR;

BEGIN
    srclen := LEN(src);
    dstlen := LEN(dst);
    i := 0;
    j := 0;
    WHILE (i < srclen) & (j < dstlen) & (src[i] # 0X) DO
        c := src[i];
        CASE c OF
        |00X..7FX:
            u := ORD(c)

        |0C1X..0DFX:
            u := (ORD(c) - 0C0H) * 64;
            IF i + 1 < srclen THEN
                INC(i);
                INC(u, ORD(src[i]) MOD 64)
            END

        |0E1X..0EFX:
            u := (ORD(c) - 0E0H) * 4096;
            IF i + 1 < srclen THEN
                INC(i);
                INC(u, (ORD(src[i]) MOD 64) * 64)
            END;
            IF i + 1 < srclen THEN
                INC(i);
                INC(u, ORD(src[i]) MOD 64)
            END

        ELSE
        END;
        INC(i);
        dst[j] := WCHR(u);
        INC(j)
    END;
    IF j < dstlen THEN
        dst[j] := WCHR(0)
    END

    RETURN j
END Utf8To16;
$END


END Strings.
