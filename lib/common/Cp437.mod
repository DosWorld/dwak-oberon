MODULE Cp437;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   Code page 437 and UTF-8, both ways.

   The framework's screen is a grid of code points, and a byte on a host's
   screen is a character of one code page - the IBM PC's, which is what a
   console font, a DOS program and the DOS clipboard all agree on.  The
   clipboard is not that: it is Unicode, and on Windows it is UTF-16 behind a
   UTF-8 edge.  So a copy out of a text widget is a conversion, and a paste
   into one is the same conversion backwards, and this is the only place either
   is made.

   THE LOWER HALF IS MAPPED, and it was not always.  It used to be left exactly
   as it is, on the argument that its glyphs - the arrows QuickHelp frames a
   link with are 10H and 11H, the triangles, the smileys - are a *screen's*
   characters and not text anybody typed, so no copy carries one and no paste
   needs one.  That argument is still true of the clipboard and it is no longer
   true of the screen: the screen is now a grid of code points, a frame draws
   itself with real arrows, and a code point has to be able to become the byte
   of whatever page the host happens to be on - 437 here, 866 on a Russian DOS
   box, something else again elsewhere.  A page that answered "no such
   character" for its own arrow glyph would leave every frame undrawable on
   every page but this one.  So the thirty-one glyphs below 80H are mapped, and
   Cp866 carries the identical thirty-one, because they are the VGA font's and
   every OEM page was built on 437's layout.

   Four bytes of that range are not glyphs but something a text stream means by
   - NUL, TAB, LF and CR - and those four stay themselves in both directions.
   A text area cuts its lines at exactly the last two, so a conversion that
   turned one of them into the note or the circle drawn at that byte would make
   a paste of a real line break impossible to tell from a paste of a
   decoration, and would put a line break where nobody typed one.

   Above 7FH there is no rule to derive and a table to keep.  It is kept once:
   Point is the table, and ByteOf searches it rather than holding a second one
   - so the two directions cannot come to disagree about a byte, which two
   tables in two places eventually do.

   A code point the code page has not got becomes '?', which is what a DOS
   program copying from a Windows clipboard sees and has always seen, and it is
   the answer the host itself gives: lib/dpmi32/ArchClip.mod measures the DOS
   clipboard answering the same way for the same reason.
*)

CONST
    SHIFT = 80H;                        (* where 437 stops being the VGA font's *)
    TABLE = 80H;                        (* and how many entries the page adds *)

(* No VAR section on purpose.  The table is code and not data, so importing
   this module costs a program nothing until something calls it, and then only
   the procedures it called. *)


(* The code point of one byte of the code page.

   Entries above 80H are in byte order from there, so a reader checking one
   against a printed table counts from the top of the list and not from the top
   of the page.  The groups are the page's own: Latin-1 with the line-drawing
   accents, the box-drawing set, the blocks and shades, and Greek with the
   mathematical signs. *)
PROCEDURE Point* (b: INTEGER): INTEGER;
VAR cp: INTEGER;
BEGIN
    cp := b;                            (* 20H through 7EH are themselves *)
    IF (b < 0) OR (b > 0FFH) THEN
        cp := 0                         (* not a byte of this page at all *)
    ELSIF b < SHIFT THEN
        CASE b OF
            01H: cp := 0263AH | 02H: cp := 0263BH | 03H: cp := 02665H | 04H: cp := 02666H |
            05H: cp := 02663H | 06H: cp := 02660H | 07H: cp := 02022H | 08H: cp := 025D8H |
            0BH: cp := 02642H | 0CH: cp := 02640H | 0EH: cp := 0266BH | 0FH: cp := 0263CH |
            10H: cp := 025BAH | 11H: cp := 025C4H | 12H: cp := 02195H | 13H: cp := 0203CH |
            14H: cp := 000B6H | 15H: cp := 000A7H | 16H: cp := 025ACH | 17H: cp := 021A8H |
            18H: cp := 02191H | 19H: cp := 02193H | 1AH: cp := 02192H | 1BH: cp := 02190H |
            1CH: cp := 0221FH | 1DH: cp := 02194H | 1EH: cp := 025B2H | 1FH: cp := 025BCH |
            7FH: cp := 02302H
        ELSE
            (* 09H, 0AH and 0DH, and 20H through 7EH: the stream's own *)
        END
    ELSE
        CASE b OF
            80H: cp := 0C7H | 81H: cp := 00FCH | 82H: cp := 0E9H | 83H: cp := 0E2H |
            84H: cp := 0E4H | 85H: cp := 0E0H | 86H: cp := 0E5H | 87H: cp := 0E7H |
            88H: cp := 0EAH | 89H: cp := 0EBH | 8AH: cp := 0E8H | 8BH: cp := 0EFH |
            8CH: cp := 0EEH | 8DH: cp := 0ECH | 8EH: cp := 0C4H | 8FH: cp := 0C5H |
            90H: cp := 0C9H | 91H: cp := 0E6H | 92H: cp := 0C6H | 93H: cp := 0F4H |
            94H: cp := 0F6H | 95H: cp := 0F2H | 96H: cp := 0FBH | 97H: cp := 0F9H |
            98H: cp := 0FFH | 99H: cp := 0D6H | 9AH: cp := 0DCH | 9BH: cp := 0A2H |
            9CH: cp := 0A3H | 9DH: cp := 0A5H | 9EH: cp := 20A7H | 9FH: cp := 192H |
            0A0H: cp := 0E1H | 0A1H: cp := 0EDH | 0A2H: cp := 0F3H | 0A3H: cp := 0FAH |
            0A4H: cp := 0F1H | 0A5H: cp := 0D1H | 0A6H: cp := 0AAH | 0A7H: cp := 0BAH |
            0A8H: cp := 0BFH | 0A9H: cp := 2310H | 0AAH: cp := 0ACH | 0ABH: cp := 0BDH |
            0ACH: cp := 0BCH | 0ADH: cp := 0A1H | 0AEH: cp := 0ABH | 0AFH: cp := 0BBH |
            0B0H: cp := 2591H | 0B1H: cp := 2592H | 0B2H: cp := 2593H | 0B3H: cp := 2502H |
            0B4H: cp := 2524H | 0B5H: cp := 2561H | 0B6H: cp := 2562H | 0B7H: cp := 2556H |
            0B8H: cp := 2555H | 0B9H: cp := 2563H | 0BAH: cp := 2551H | 0BBH: cp := 2557H |
            0BCH: cp := 255DH | 0BDH: cp := 255CH | 0BEH: cp := 255BH | 0BFH: cp := 2510H |
            0C0H: cp := 2514H | 0C1H: cp := 2534H | 0C2H: cp := 252CH | 0C3H: cp := 251CH |
            0C4H: cp := 2500H | 0C5H: cp := 253CH | 0C6H: cp := 255EH | 0C7H: cp := 255FH |
            0C8H: cp := 255AH | 0C9H: cp := 2554H | 0CAH: cp := 2569H | 0CBH: cp := 2566H |
            0CCH: cp := 2560H | 0CDH: cp := 2550H | 0CEH: cp := 256CH | 0CFH: cp := 2567H |
            0D0H: cp := 2568H | 0D1H: cp := 2564H | 0D2H: cp := 2565H | 0D3H: cp := 2559H |
            0D4H: cp := 2558H | 0D5H: cp := 2552H | 0D6H: cp := 2553H | 0D7H: cp := 256BH |
            0D8H: cp := 256AH | 0D9H: cp := 2518H | 0DAH: cp := 250CH | 0DBH: cp := 2588H |
            0DCH: cp := 2584H | 0DDH: cp := 258CH | 0DEH: cp := 2590H | 0DFH: cp := 2580H |
            0E0H: cp := 3B1H | 0E1H: cp := 0DFH | 0E2H: cp := 393H | 0E3H: cp := 3C0H |
            0E4H: cp := 3A3H | 0E5H: cp := 3C3H | 0E6H: cp := 0B5H | 0E7H: cp := 3C4H |
            0E8H: cp := 3A6H | 0E9H: cp := 398H | 0EAH: cp := 3A9H | 0EBH: cp := 3B4H |
            0ECH: cp := 221EH | 0EDH: cp := 3C6H | 0EEH: cp := 3B5H | 0EFH: cp := 2229H |
            0F0H: cp := 2261H | 0F1H: cp := 0B1H | 0F2H: cp := 2265H | 0F3H: cp := 2264H |
            0F4H: cp := 2320H | 0F5H: cp := 2321H | 0F6H: cp := 0F7H | 0F7H: cp := 2248H |
            0F8H: cp := 0B0H | 0F9H: cp := 2219H | 0FAH: cp := 0B7H | 0FBH: cp := 221AH |
            0FCH: cp := 207FH | 0FDH: cp := 0B2H | 0FEH: cp := 25A0H | 0FFH: cp := 0A0H
        ELSE
            cp := 0                     (* no byte of the page reaches here *)
        END
    END;

    RETURN cp
END Point;


(* The byte of the code page that draws this code point, or -1 when the page has
   no such character.

   Searched and not tabled: a second table is a second thing to keep in step,
   and the search is over one page at most once per character of a conversion.
   No code point appears twice in the page, so the first hit is the only one. *)
PROCEDURE ByteOf* (cp: INTEGER): INTEGER;
VAR b: INTEGER;
BEGIN
    b := 0;
    WHILE (b < 100H) & (Point(b) # cp) DO
        INC(b)
    END;
    IF b >= 100H THEN
        b := -1
    END;

    RETURN b
END ByteOf;


(* How many bytes the UTF-8 of this code point takes.  Nothing this module
   produces is ever four bytes wide - every code point of the code page is
   under 2640H - but the decoder above accepts four, so the two are not
   symmetric and do not have to be. *)
PROCEDURE Width (cp: INTEGER): INTEGER;
VAR n: INTEGER;
BEGIN
    IF cp < 80H THEN
        n := 1
    ELSIF cp < 800H THEN
        n := 2
    ELSE
        n := 3
    END;

    RETURN n
END Width;


(* The UTF-8 of one code point, written from dst[ofs] on.  Width has to have
   been asked first: this writes the whole of the sequence and has nowhere to
   put a half of one. *)
PROCEDURE Emit (cp, ofs: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN
    IF cp < 80H THEN
        dst[ofs] := CHR(cp)
    ELSIF cp < 800H THEN
        dst[ofs] := CHR(0C0H + cp DIV 40H);
        dst[ofs + 1] := CHR(80H + cp MOD 40H)
    ELSE
        dst[ofs] := CHR(0E0H + cp DIV 1000H);
        dst[ofs + 1] := CHR(80H + cp DIV 40H MOD 40H);
        dst[ofs + 2] := CHR(80H + cp MOD 40H)
    END
END Emit;


(* The screen's text as UTF-8.  Answers the number of bytes written.

   The result is cut at the room there is and a sequence that does not fit is
   not started, so what comes out is always whole characters - a buffer that
   ended in the first byte of a three-byte character would be text no decoder
   could read, and a clipboard is read by another program entirely. *)
PROCEDURE ToUtf8* (src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR): INTEGER;
VAR
    i, j, cp, n, lim: INTEGER;
    stop: BOOLEAN;
BEGIN
    lim := LEN(dst) - 1;                (* the terminator keeps the last byte *)
    i := 0;
    j := 0;
    stop := FALSE;
    WHILE ~stop & (i < LEN(src)) & (src[i] # 0X) DO
        cp := Point(ORD(src[i]));
        n := Width(cp);
        IF j + n > lim THEN
            stop := TRUE
        ELSE
            Emit(cp, j, dst);
            INC(j, n);
            INC(i)
        END
    END;
    dst[j] := 0X;

    RETURN j
END ToUtf8;


(* One code point of a UTF-8 sequence starting at u[i], which is the number of
   bytes it took, and 0 when what is there is not a sequence.

   The rules are the encoding's own: a lead byte says how many follow it, a
   continuation byte is 80H to 0BFH, and a form that could have been written
   shorter - C0H and C1H, and the overlong three- and four-byte forms - is not
   accepted, because two spellings of one character make a string that has two
   different byte sequences and compares unequal to itself.  A surrogate half
   and anything past U+10FFFF are refused for the same reason: they are not
   characters and no decoder may hand one to a caller. *)
PROCEDURE Decode (u: ARRAY OF CHAR; i: INTEGER; VAR cp: INTEGER): INTEGER;
VAR
    b, nb, k, v, lo, hi, n: INTEGER;
    ok: BOOLEAN;
BEGIN
    b := ORD(u[i]);
    n := 0;
    cp := 0;
    IF b < 80H THEN
        cp := b;
        n := 1
    ELSE
        IF (b >= 0C2H) & (b <= 0DFH) THEN
            nb := 1; v := b - 0C0H; lo := 80H; hi := 7FFH
        ELSIF (b >= 0E0H) & (b <= 0EFH) THEN
            nb := 2; v := b - 0E0H; lo := 800H; hi := 0FFFFH
        ELSIF (b >= 0F0H) & (b <= 0F4H) THEN
            nb := 3; v := b - 0F0H; lo := 10000H; hi := 10FFFFH
        ELSE
            nb := -1; v := 0; lo := 0; hi := 0   (* a continuation byte, or C0/C1 *)
        END;
        IF nb >= 0 THEN
            ok := TRUE;
            k := 0;
            WHILE ok & (k < nb) DO
                IF i + 1 + k >= LEN(u) THEN
                    ok := FALSE
                ELSE
                    b := ORD(u[i + 1 + k]);
                    IF (b < 80H) OR (b > 0BFH) THEN
                        ok := FALSE
                    ELSE
                        v := v * 40H + (b - 80H)
                    END
                END;
                INC(k)
            END;
            IF ok & ((v < lo) OR (v > hi)) THEN
                ok := FALSE              (* written shorter than it had to be *)
            END;
            IF ok & (v >= 0D800H) & (v <= 0DFFFH) THEN
                ok := FALSE              (* a surrogate half is not a character *)
            END;
            IF ok THEN
                cp := v;
                n := nb + 1
            END
        END
    END;

    RETURN n
END Decode;


(* UTF-8 text as the screen's own bytes.  Answers the number of bytes written.

   A code point the code page has not got becomes '?': it is the answer the
   host gives for the same reason, and it is the only one that keeps the
   character count of the text - a character dropped would move every character
   after it and a paste would land in the wrong place.  A sequence that is not
   well formed is one byte of the source and one '?', so a decoder run at a
   buffer that is not text at all still stops. *)
PROCEDURE FromUtf8* (u: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR): INTEGER;
VAR
    i, j, cp, n, b, lim: INTEGER;
BEGIN
    lim := LEN(dst) - 1;
    i := 0;
    j := 0;
    WHILE (i < LEN(u)) & (u[i] # 0X) & (j < lim) DO
        n := Decode(u, i, cp);
        IF n = 0 THEN
            b := -1;                    (* not a sequence: one byte, one '?' *)
            n := 1
        ELSE
            b := ByteOf(cp)
        END;
        IF b < 0 THEN
            dst[j] := "?"
        ELSE
            dst[j] := CHR(b)
        END;
        INC(j);
        INC(i, n)
    END;
    dst[j] := 0X;

    RETURN j
END FromUtf8;


END Cp437.
