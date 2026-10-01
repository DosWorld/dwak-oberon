MODULE Cp866;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   Code page 866, both ways: the page a Russian DOS console is set to.

   437 and 866 are the two pages a byte of the framework's screen can be, and
   which one it is has nothing to do with the program: it is what the machine
   was set to before the program started.  So this is the same table Cp437
   keeps, for the other page, and the two are the whole of what the screen
   layer may choose from today.

   The two pages differ in one place only: the upper half.  Below 80H they are
   the same thirty-one glyphs - the smileys, the card suits, the arrows, the
   triangles - because those are the VGA font's and every OEM page was built on
   437's layout.  Python's own codecs do not carry them (they map the C0 range
   to the control characters), so they are written out here by hand, once, and
   Cp437 has the identical thirty-one.

   Four bytes of the low range are not glyphs but something a text stream means
   by: NUL, TAB, LF and CR.  They are left as themselves in both directions, on
   purpose - a text area cuts its lines at CR and LF, so a conversion that
   turned one of them into the note or the circle drawn at that byte would make
   a paste of a real line break impossible to tell from a paste of a decoration,
   and would put a line break where nobody typed one.

   Above 80H there is no rule to derive and a table to keep, and it is kept
   once: Point is the table and ByteOf searches it rather than holding a second
   one, so the two directions cannot come to disagree about a byte.

   A code point the page has not got becomes '?', which is what a console has
   always shown for what it cannot draw.
*)

CONST
    SHIFT = 80H;                        (* where the pages start to differ *)
    TABLE = 80H;                        (* and how many entries each has *)

(* No VAR section on purpose.  The table is code and not data, so importing
   this module costs a program nothing until something calls it. *)


(* The code point of one byte of the page. *)
PROCEDURE Point* (b: INTEGER): INTEGER;
VAR cp: INTEGER;
BEGIN
    cp := b;                            (* 20H through 7EH are themselves *)
    IF b < SHIFT THEN
        CASE b OF
            00H: cp := 0000H |                (* left alone: the stream's own *)
            0001H: cp := 0263AH | 0002H: cp := 0263BH | 0003H: cp := 02665H | 0004H: cp := 02666H |
            0005H: cp := 02663H | 0006H: cp := 02660H | 0007H: cp := 02022H | 0008H: cp := 025D8H |
            0009H: cp := 00009H | 000AH: cp := 0000AH | 000BH: cp := 02642H | 000CH: cp := 02640H |
            000DH: cp := 0000DH | 000EH: cp := 0266BH | 000FH: cp := 0263CH | 0010H: cp := 025BAH |
            0011H: cp := 025C4H | 0012H: cp := 02195H | 0013H: cp := 0203CH | 0014H: cp := 000B6H |
            0015H: cp := 000A7H | 0016H: cp := 025ACH | 0017H: cp := 021A8H | 0018H: cp := 02191H |
            0019H: cp := 02193H | 001AH: cp := 02192H | 001BH: cp := 02190H | 001CH: cp := 0221FH |
            001DH: cp := 02194H | 001EH: cp := 025B2H | 001FH: cp := 025BCH | 0020H: cp := 00020H |
            7FH: cp := 02302H
        ELSE
            cp := b                     (* 21H..7EH: the page is the ASCII *)
        END
    ELSE
        CASE b OF
            0080H: cp := 00410H | 0081H: cp := 00411H | 0082H: cp := 00412H | 0083H: cp := 00413H |
            0084H: cp := 00414H | 0085H: cp := 00415H | 0086H: cp := 00416H | 0087H: cp := 00417H |
            0088H: cp := 00418H | 0089H: cp := 00419H | 008AH: cp := 0041AH | 008BH: cp := 0041BH |
            008CH: cp := 0041CH | 008DH: cp := 0041DH | 008EH: cp := 0041EH | 008FH: cp := 0041FH |
            0090H: cp := 00420H | 0091H: cp := 00421H | 0092H: cp := 00422H | 0093H: cp := 00423H |
            0094H: cp := 00424H | 0095H: cp := 00425H | 0096H: cp := 00426H | 0097H: cp := 00427H |
            0098H: cp := 00428H | 0099H: cp := 00429H | 009AH: cp := 0042AH | 009BH: cp := 0042BH |
            009CH: cp := 0042CH | 009DH: cp := 0042DH | 009EH: cp := 0042EH | 009FH: cp := 0042FH |
            00A0H: cp := 00430H | 00A1H: cp := 00431H | 00A2H: cp := 00432H | 00A3H: cp := 00433H |
            00A4H: cp := 00434H | 00A5H: cp := 00435H | 00A6H: cp := 00436H | 00A7H: cp := 00437H |
            00A8H: cp := 00438H | 00A9H: cp := 00439H | 00AAH: cp := 0043AH | 00ABH: cp := 0043BH |
            00ACH: cp := 0043CH | 00ADH: cp := 0043DH | 00AEH: cp := 0043EH | 00AFH: cp := 0043FH |
            00B0H: cp := 02591H | 00B1H: cp := 02592H | 00B2H: cp := 02593H | 00B3H: cp := 02502H |
            00B4H: cp := 02524H | 00B5H: cp := 02561H | 00B6H: cp := 02562H | 00B7H: cp := 02556H |
            00B8H: cp := 02555H | 00B9H: cp := 02563H | 00BAH: cp := 02551H | 00BBH: cp := 02557H |
            00BCH: cp := 0255DH | 00BDH: cp := 0255CH | 00BEH: cp := 0255BH | 00BFH: cp := 02510H |
            00C0H: cp := 02514H | 00C1H: cp := 02534H | 00C2H: cp := 0252CH | 00C3H: cp := 0251CH |
            00C4H: cp := 02500H | 00C5H: cp := 0253CH | 00C6H: cp := 0255EH | 00C7H: cp := 0255FH |
            00C8H: cp := 0255AH | 00C9H: cp := 02554H | 00CAH: cp := 02569H | 00CBH: cp := 02566H |
            00CCH: cp := 02560H | 00CDH: cp := 02550H | 00CEH: cp := 0256CH | 00CFH: cp := 02567H |
            00D0H: cp := 02568H | 00D1H: cp := 02564H | 00D2H: cp := 02565H | 00D3H: cp := 02559H |
            00D4H: cp := 02558H | 00D5H: cp := 02552H | 00D6H: cp := 02553H | 00D7H: cp := 0256BH |
            00D8H: cp := 0256AH | 00D9H: cp := 02518H | 00DAH: cp := 0250CH | 00DBH: cp := 02588H |
            00DCH: cp := 02584H | 00DDH: cp := 0258CH | 00DEH: cp := 02590H | 00DFH: cp := 02580H |
            00E0H: cp := 00440H | 00E1H: cp := 00441H | 00E2H: cp := 00442H | 00E3H: cp := 00443H |
            00E4H: cp := 00444H | 00E5H: cp := 00445H | 00E6H: cp := 00446H | 00E7H: cp := 00447H |
            00E8H: cp := 00448H | 00E9H: cp := 00449H | 00EAH: cp := 0044AH | 00EBH: cp := 0044BH |
            00ECH: cp := 0044CH | 00EDH: cp := 0044DH | 00EEH: cp := 0044EH | 00EFH: cp := 0044FH |
            00F0H: cp := 00401H | 00F1H: cp := 00451H | 00F2H: cp := 00404H | 00F3H: cp := 00454H |
            00F4H: cp := 00407H | 00F5H: cp := 00457H | 00F6H: cp := 0040EH | 00F7H: cp := 0045EH |
            00F8H: cp := 000B0H | 00F9H: cp := 02219H | 00FAH: cp := 000B7H | 00FBH: cp := 0221AH |
            00FCH: cp := 02116H | 00FDH: cp := 000A4H | 00FEH: cp := 025A0H | 00FFH: cp := 000A0H
        ELSE
            cp := 0                     (* no byte of the page reaches here *)
        END
    END;

    RETURN cp
END Point;


(* The byte of the page that draws this code point, or -1 when the page has
   no such character.

   Searched and not tabled: a second table is a second thing to keep in step,
   and the search is over a page at most once per character of a conversion. *)
PROCEDURE ByteOf* (cp: INTEGER): INTEGER;
VAR b, found: INTEGER;
BEGIN
    found := -1;
    b := 0;
    WHILE (b < 100H) & (Point(b) # cp) DO
        INC(b)
    END;
    IF b < 100H THEN
        found := b
    END;

    RETURN found
END ByteOf;


END Cp866.
