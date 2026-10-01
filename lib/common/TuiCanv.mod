MODULE TuiCanv;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A text canvas: a grid of w by h cells, four bytes each - the character and
   its attribute - held in a ByteArr.  Cell (x, y) is at (w*y + x) * 4, its
   character two bytes there and its attribute two bytes further on.

   THE CHARACTER OF A CELL IS A CODE POINT, and that is a change.  A cell used
   to be two bytes in the layout a DOS text screen has at 0B8000h - a byte of
   code page 866 and a byte of attribute - and the whole framework drew in that
   page and nothing else.  It does not any more: a frame draws itself with real
   line-drawing code points, so the same canvas can be shown on a host set to
   437, on a Russian box set to 866, on a Windows console that takes Unicode,
   and on whatever the next host is set to - and the conversion happens once,
   at the host's edge (TuiScr), through the one module that knows which page
   that is (TuiPage).

   The attribute is two bytes wide because the cell is: nothing uses more than
   the low byte of it today - the sixteen VGA colours Attr builds - and it
   costs nothing to carry a word, while a three-byte cell would put every
   second cell on an odd address and cost the fills their word stores.

   That is no longer the layout of any screen, and it does not need to be: the
   screen layer converts, a cell at a time, which it had to do anyway on a host
   whose page is not the canvas's.

   This module is portable - ByteArr, Charset, TuiPage, Files, Strings and SYSTEM - so
   the whole drawing layer above it runs on any target.  It is written for the
   targets that have a screen, which are the 32- and 64-bit ones: a cell is
   four bytes and both of its fills go through ByteArr.Fill32, which a 16-bit
   target has not got.  Nothing on the small targets imports this module and
   neither of them has a screen to draw it on.

   Coordinates are clipped, never asserted: a widget that draws partly outside
   its canvas is the normal case (a window moved off the edge), not an error.
   Only Create insists on a sane size.

   The frame characters are named by the code point the Unicode standard gives
   them, and not by the byte any one code page puts them at.  The byte is what
   the old constants were and what a reader may still be looking for: 0C4X is
   the single horizontal line and is U+2500, 0B3X is the vertical and is
   U+2502, 0DAX is the top left corner and is U+250C, 018X is the up arrow and
   is U+2191, 0DBX is the full block and is U+2588, 0B0X to 0B2X are the three
   shades and are U+2591 to U+2593.  Both pages this build carries put them at
   exactly those bytes, which is why nothing moved when the constants became
   code points - and the reason both pages can carry them is that both are the
   VGA font's below 80H, where the arrows and the triangles live. *)

IMPORT ByteArr, Charset, TuiPage, Files, Strings, SYSTEM, Oberon;

CONST

    (* The sixteen VGA text attributes, under the names lib/dpmi32/Console.mod
       gives them.  An attribute byte is the background times sixteen plus the
       foreground, which Attr builds. *)
    Black* = 0;     Blue* = 1;          Green* = 2;       Cyan* = 3;
    Red* = 4;       Magenta* = 5;       Brown* = 6;       LightGray* = 7;
    DarkGray* = 8;  LightBlue* = 9;     LightGreen* = 10; LightCyan* = 11;
    LightRed* = 12; LightMagenta* = 13; Yellow* = 14;     White* = 15;

    DEF_ATTR* = 7;                      (* what a fresh canvas is cleared to *)

    (* The four bytes of a cell.  A canvas is w * h of them, and the two places
       that work the offset out - the drawing methods and the fills - are the
       only ones that need the number. *)
    CELL* = 4;
    ATTR_OFS* = 2;                      (* where in a cell the attribute is *)

    (* The single and double line frames, the arrows, the triangles, the blocks
       and the three shades, by their code points. *)
    SL_H* = WCHR(2500H); SL_V* = WCHR(2502H); SL_VR* = WCHR(251CH);
    SL_TL* = WCHR(250CH); SL_TR* = WCHR(2510H);
    SL_BL* = WCHR(2514H); SL_BR* = WCHR(2518H);
    DL_H* = WCHR(2550H); DL_V* = WCHR(2551H);
    DL_TL* = WCHR(2554H); DL_TR* = WCHR(2557H);
    DL_BL* = WCHR(255AH); DL_BR* = WCHR(255DH);
    ARROW_UP* = WCHR(2191H); ARROW_DOWN* = WCHR(2193H);
    ARROW_LEFT* = WCHR(2190H); ARROW_RIGHT* = WCHR(2192H);
    TRI_RIGHT* = WCHR(25BAH); TRI_LEFT* = WCHR(25C4H);
    BLOCK* = WCHR(2588H);
    SHADE_LIGHT* = WCHR(2591H); SHADE_MED* = WCHR(2592H); SHADE_DARK* = WCHR(2593H);

    (* What Print and Dump take for nothing.  Every page this build carries -
       and every OEM page there is - draws 20H through 7EH as the ASCII it is;
       only 01H to 1FH and 7FH differ between them, because those are the VGA
       font's own glyphs.  So a byte in this range is its own code point
       whatever the page says, and neither the string a label is made of nor
       the row a dump is made of pays a conversion to find that out. *)
    ASCII_LO = 20H;
    ASCII_HI = 7EH;

TYPE

    Canvas* = POINTER TO CanvasDesc;

    (* The framework's name for the character of a cell.  It is the language's
       own WCHAR - Tui re-exports it under this name, and a WCHAR is a WCHAR
       wherever it is written, so the two spellings are one type. *)
    Char* = WCHAR;

    (* A canvas is an object of the library like any other: it extends the root
       and binds the inherited `Done`, so `Oberon.Done(c)` and `c.Done(c)` are
       the two ways to give one back.  It used to declare a `Done` of its own,
       typed with its own pointer - see the note in TuiWidg and the manual in
       Oberon.mod on why a class has one destructor and not a second one. *)
    CanvasDesc* = RECORD (Oberon.ObjectDesc)
        data: ByteArr.ByteArray;      (* w*h*4 bytes; private to the methods *)
        w*, h*: INTEGER;

        (* One pointer per method, bound by Create - the style ByteArr and
           Arrays use, self passed by hand at every call. *)
        Clear*:   PROCEDURE (self: Canvas; attr: INTEGER);
        Put*:     PROCEDURE (self: Canvas; x, y: INTEGER; ch: Char; attr: INTEGER);
        Get*:     PROCEDURE (self: Canvas; x, y: INTEGER): Char;
        AttrAt*:  PROCEDURE (self: Canvas; x, y: INTEGER): INTEGER;
        SetAttr*: PROCEDURE (self: Canvas; x, y, attr: INTEGER);
        Print*:   PROCEDURE (self: Canvas; x, y: INTEGER; s: ARRAY OF CHAR;
                            attr: INTEGER);
        HLine*:   PROCEDURE (self: Canvas; x, y, n: INTEGER; ch: Char; attr: INTEGER);
        VLine*:   PROCEDURE (self: Canvas; x, y, n: INTEGER; ch: Char; attr: INTEGER);
        Fill*:    PROCEDURE (self: Canvas; x, y, w, h: INTEGER; ch: Char;
                            attr: INTEGER);
        Frame*:   PROCEDURE (self: Canvas; x, y, w, h, attr: INTEGER;
                            double: BOOLEAN);
        Scroll*:  PROCEDURE (self: Canvas; x, y, w, h, n, attr: INTEGER);
        Blit*:    PROCEDURE (self: Canvas; x, y: INTEGER; src: Canvas);
        GetRow*:  PROCEDURE (self: Canvas; y, n: INTEGER; dst: ByteArr.ByteArray);
        PutRow*:  PROCEDURE (self: Canvas; y, n: INTEGER; src: ByteArr.ByteArray);
        Dump*:    PROCEDURE (self: Canvas; name: ARRAY OF CHAR): BOOLEAN
    END;


(* An attribute byte from a foreground and a background colour. *)
PROCEDURE Attr* (fg, bg: INTEGER): INTEGER;
VAR a: INTEGER;
BEGIN
    a := bg * 16 + fg;
    RETURN a
END Attr;


(* A cell as Fill32 writes one: the character in the low two bytes and the
   attribute in the high two, which is the order they are laid out in. *)
PROCEDURE CellOf (ch: Char; attr: INTEGER): INTEGER;
VAR v: INTEGER;
BEGIN
    v := ORD(ch) + attr * 10000H;
    RETURN v
END CellOf;


(* The cell (x, y) is inside the canvas. *)
PROCEDURE Inside (self: Canvas; x, y: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (x >= 0) & (y >= 0) & (x < self.w) & (y < self.h);
    RETURN r
END Inside;


(* The whole canvas to one character and one pair: one call into the byte
   array, which fills the run with the CPU's own string store - rep stosd on an
   x86 target - a block at a time.

   A canvas asks for this shape more than any other, so it is worth its own
   call: a cell written on its own through Put16 costs two calls into the byte
   array that holds it, each of which works out which block its byte is in and
   checks the index, and a canvas is thousands of cells.  Measured on the DOS
   target, twenty fills of an eighty by twenty-five canvas took 5.07 s that way
   and 3.04 s as one call a screen, where the same twenty cost 3.0 s of DOSBox
   start-up and nothing else - so the fill of a screen is now unmeasurable
   rather than a tenth of a second. *)
PROCEDURE Clear (self: Canvas; attr: INTEGER);
BEGIN
    IF (self.w > 0) & (self.h > 0) THEN
        self.data.Fill32(self.data, 0, self.w * self.h * CELL,
                         ORD(" ") + attr * 10000H)
    END
END Clear;


PROCEDURE Put (self: Canvas; x, y: INTEGER; ch: Char; attr: INTEGER);
VAR ofs: INTEGER;
BEGIN
    IF Inside(self, x, y) THEN
        ofs := (self.w * y + x) * CELL;
        self.data.Put16(self.data, ofs, ORD(ch));
        self.data.Put16(self.data, ofs + ATTR_OFS, attr)
    END
END Put;


PROCEDURE Get (self: Canvas; x, y: INTEGER): Char;
VAR ch: Char;
BEGIN
    ch := " ";
    IF Inside(self, x, y) THEN
        ch := WCHR(self.data.Get16(self.data, (self.w * y + x) * CELL))
    END;
    RETURN ch
END Get;


PROCEDURE AttrAt (self: Canvas; x, y: INTEGER): INTEGER;
VAR a: INTEGER;
BEGIN
    a := DEF_ATTR;
    IF Inside(self, x, y) THEN
        a := self.data.Get16(self.data, (self.w * y + x) * CELL + ATTR_OFS)
    END;
    RETURN a
END AttrAt;


(* Recolour a cell without touching the character in it: what the mouse cursor
   is drawn with. *)
PROCEDURE SetAttr (self: Canvas; x, y, attr: INTEGER);
BEGIN
    IF Inside(self, x, y) THEN
        self.data.Put16(self.data, (self.w * y + x) * CELL + ATTR_OFS, attr)
    END
END SetAttr;


(* One byte of the program's own text as the character a canvas holds.

   This is the conversion every widget that draws a byte string one character at
   a time needs, and the reason it is here once instead of in each of them is
   that a widget drawing a whole string can use Print and a widget drawing a
   field with a selection through it cannot: it wants a different pair on each
   cell, so it takes the string apart itself and needs the character of one byte.

   20H through 7EH are the same character in every page this build carries, and a
   label, a title, a menu and a file name are all made of those, so the common
   case is one comparison and no call at all.  Anything else is asked of the page
   the program's text is in, which is what makes a byte a Cyrillic letter on a box
   set to 866 and an accented one on a box set to 437 - and lets either of them
   reach a Windows console, which draws neither as a byte. *)
PROCEDURE CharOf* (b: INTEGER): Char;
VAR ch: Char;
BEGIN
    IF (b >= ASCII_LO) & (b <= ASCII_HI) THEN
        ch := WCHR(b)
    ELSE
        ch := WCHR(TuiPage.OfText(b))
    END;
    RETURN ch
END CharOf;


(* Write the string from (x, y) on, up to its 0X, stopping at the right edge.

   The string is bytes and a cell is a code point, so every character of it is a
   conversion; CharOf is where that conversion lives and what it costs.

   ONE BYTE IS ONE CELL IN EVERY PAGE BUT ONE, and that is why the loop has two
   arms.  On 437, 866 and Unicode a byte is a character, so the byte index is the
   cell index and the old loop stands - it is the ELSE arm below, unchanged.  On
   **PageUtf8** it is not: a character is one to four bytes and the two indices
   come apart, so the cell column is counted separately from the byte position and
   the decode is asked how far it read (Charset.Decode, one cell per code point).

   The page is read ONCE, before the loop, and the test is not a guess at the
   string.  A caller must not try UTF-8 first and fall back to the page on a
   failure, and the reason is a measured one: 866 Cyrillic "Привет" is
   8F E0 A8 A2 A5 E2, whose 8F is a stray continuation byte - it would fail and
   fall back correctly - but the very next three bytes E0 A8 A2 are a WELL FORMED
   three-byte sequence, so the rest of the string would be swallowed into one
   nonsense code point and no fallback would happen.  Which page a program's text
   is in is a setting the program made, not something to be discovered by trying.

   A byte no sequence decodes from becomes U+FFFD, one byte at a time, so a
   malformed string still advances and never traps. *)
PROCEDURE Print (self: Canvas; x, y: INTEGER; s: ARRAY OF CHAR; attr: INTEGER);
VAR i, n, cp, len, page: INTEGER;
BEGIN
    page := TuiPage.Text();
    i := 0;
    IF page = Charset.PageUtf8 THEN
        n := 0;                        (* n is the cell column, i the byte one *)
        WHILE (i < LEN(s)) & (s[i] # 0X) DO
            Charset.Decode(s, i, page, cp, len);
            self.Put(self, x + n, y, WCHR(cp), attr);
            INC(i, len);
            INC(n)
        END
    ELSE
        WHILE (i < LEN(s)) & (s[i] # 0X) DO
            self.Put(self, x + i, y, CharOf(ORD(s[i])), attr);
            INC(i)
        END
    END
END Print;


PROCEDURE HLine (self: Canvas; x, y, n: INTEGER; ch: Char; attr: INTEGER);
VAR i: INTEGER;
BEGIN
    FOR i := x TO x + n - 1 DO
        self.Put(self, i, y, ch, attr)
    END
END HLine;


PROCEDURE VLine (self: Canvas; x, y, n: INTEGER; ch: Char; attr: INTEGER);
VAR i: INTEGER;
BEGIN
    FOR i := y TO y + n - 1 DO
        self.Put(self, x, i, ch, attr)
    END
END VLine;


(* A rectangle of one character and one pair.

   Clipped to the canvas, which is what it was when every cell went through
   Put: a caller may ask for cells off the edge and gets the ones that are on
   it.  A row of the rectangle is one Fill32 - the cells of a row are
   contiguous, (w*y + x) * 4, so a row is the longest run there is and the
   rows are the only ones: two rows of a canvas are w cells apart and no
   rectangle has them adjacent unless it is the whole canvas.  A rectangle
   whose rows do abut, because it is w cells wide, is still filled a row at a
   time - the call per row is nothing beside the fill itself. *)
PROCEDURE Fill (self: Canvas; x, y, w, h: INTEGER; ch: Char; attr: INTEGER);
VAR j, x0, y0, x1, y1, ofs, cells: INTEGER;
BEGIN
    x0 := x; y0 := y; x1 := x + w - 1; y1 := y + h - 1;
    IF x0 < 0 THEN x0 := 0 END;
    IF y0 < 0 THEN y0 := 0 END;
    IF x1 > self.w - 1 THEN x1 := self.w - 1 END;
    IF y1 > self.h - 1 THEN y1 := self.h - 1 END;
    IF (x0 <= x1) & (y0 <= y1) THEN
        cells := (x1 - x0 + 1) * CELL;
        FOR j := y0 TO y1 DO
            ofs := (self.w * j + x0) * CELL;
            self.data.Fill32(self.data, ofs, cells, ORD(ch) + attr * 10000H)
        END
    END
END Fill;


(* A box of w by h cells with its top left corner at (x, y).  A single line
   frame for a window that does not have the focus, a double one for the window
   that does. *)
PROCEDURE Frame (self: Canvas; x, y, w, h, attr: INTEGER; double: BOOLEAN);
VAR hz, vt, tl, tr, bl, br: Char;
BEGIN
    IF double THEN
        hz := DL_H; vt := DL_V;
        tl := DL_TL; tr := DL_TR; bl := DL_BL; br := DL_BR
    ELSE
        hz := SL_H; vt := SL_V;
        tl := SL_TL; tr := SL_TR; bl := SL_BL; br := SL_BR
    END;
    IF (w >= 2) & (h >= 2) THEN
        self.HLine(self, x + 1, y, w - 2, hz, attr);
        self.HLine(self, x + 1, y + h - 1, w - 2, hz, attr);
        self.VLine(self, x, y + 1, h - 2, vt, attr);
        self.VLine(self, x + w - 1, y + 1, h - 2, vt, attr);
        self.Put(self, x, y, tl, attr);
        self.Put(self, x + w - 1, y, tr, attr);
        self.Put(self, x, y + h - 1, bl, attr);
        self.Put(self, x + w - 1, y + h - 1, br, attr)
    END
END Frame;


(* Move the rows of the rectangle up by n and blank the n rows that come free at
   the bottom.  ByteArr.Move copies in whichever direction the two ranges
   need, which SYSTEM.MOVE does not. *)
PROCEDURE Scroll (self: Canvas; x, y, w, h, n, attr: INTEGER);
VAR i, rows: INTEGER;
BEGIN
    IF (n > 0) & (n < h) & (w > 0) & (h > 0) THEN
        rows := h - n;
        FOR i := 0 TO rows - 1 DO
            self.data.Move(self.data, ((y + i) * self.w + x) * CELL,
                           ((y + i + n) * self.w + x) * CELL, w * CELL)
        END;
        self.Fill(self, x, y + rows, w, n, " ", attr)
    END
END Scroll;


(* Copy the whole of src onto this canvas with its top left corner at (x, y),
   clipped at the edges.  This is how a window reaches the desktop. *)
PROCEDURE Blit (self: Canvas; x, y: INTEGER; src: Canvas);
VAR i, dx, sx, n, dy: INTEGER;
BEGIN
    FOR i := 0 TO src.h - 1 DO
        dy := y + i;
        IF Inside(self, 0, dy) THEN
            dx := x;
            sx := 0;
            n := src.w;
            IF dx < 0 THEN
                sx := -dx;
                n := n + dx;
                dx := 0
            END;
            IF dx + n > self.w THEN n := self.w - dx END;
            IF n > 0 THEN
                self.data.Copy(self.data, (self.w * dy + dx) * CELL, src.data,
                               (src.w * i + sx) * CELL, n * CELL)
            END
        END
    END
END Blit;


(* n bytes of row y - n cells, four bytes each - copied to the start of dst,
   which must have room for them.

   The copy goes through the method that knows about blocks, and it has to: a
   canvas is a byte array, and a row of one is not necessarily at a single
   address, so there is no address this module could hand out for a row.  A row
   of the screen is what both of these are for - TuiScr compares a row of the
   canvas with a row of the screen, and puts a row of the screen back into a
   canvas - without either of them unpicking what a canvas is made of. *)
PROCEDURE GetRow (self: Canvas; y, n: INTEGER; dst: ByteArr.ByteArray);
BEGIN
    ASSERT((y >= 0) & (y < self.h) & (n >= 0) & (n <= self.w * CELL));
    self.data.Copy(dst, 0, self.data, y * self.w * CELL, n)
END GetRow;


(* The other way: n bytes at the start of src become the first n bytes of row
   y.  This is how a screen, read back a row at a time, reaches a canvas. *)
PROCEDURE PutRow (self: Canvas; y, n: INTEGER; src: ByteArr.ByteArray);
BEGIN
    ASSERT((y >= 0) & (y < self.h) & (n >= 0) & (n <= self.w * CELL));
    self.data.CopyMem(self.data, y * self.w * CELL, src.Adr(src, 0), n)
END PutRow;


PROCEDURE HexDigit (b: INTEGER): CHAR;
VAR c: CHAR;
BEGIN
    IF b < 10 THEN c := CHR(48 + b) ELSE c := CHR(55 + b) END;
    RETURN c
END HexDigit;


PROCEDURE Header (self: Canvas; VAR s: ARRAY OF CHAR);
VAR t: ARRAY 16 OF CHAR; more: BOOLEAN;
BEGIN
    Strings.Copy("TUI dump ", s);
    Strings.FromInt(self.w, t);
    more := Strings.Append(t, s);
    more := Strings.Append("x", s);
    Strings.FromInt(self.h, t);
    more := Strings.Append(t, s)
END Header;


(* Write the canvas to a text file, characters first and then attributes, so
   that two runs of the same drawing can be compared as files.  The format is
   the one samples/tui/README.md documents:

       line 1        TUI dump 80x25
       lines 2-26    the 80 characters of each row, in CP866
       line 27       (empty)
       lines 28-52   the 80 attributes of each row, two hex digits per cell

   The character rows are CP866 bytes, which is what a DOS console shows; the
   attribute rows are hex so that they survive any viewer.

   THE PAGE OF THE DUMP IS 866 AND IS NOT THE SCREEN'S.  A dump is a file two
   runs are compared as, so its page is a property of the format and not of the
   host that produced it - the same drawing dumped on Windows and on a DOS box
   has to come out as the same bytes, or the comparison the framework is
   verified with compares two machines instead of two revisions.  866 is what
   the format was written in and what every dump on record is.  A code point
   866 has not got becomes '?', as it does everywhere else. *)
PROCEDURE Dump (self: Canvas; name: ARRAY OF CHAR): BOOLEAN;
VAR
    f: Files.File;
    line: ARRAY 320 OF CHAR;
    ok: BOOLEAN;
    written: INTEGER;               (* what the file calls answer; nothing reads it *)
    x, y, n, a, cp, b: INTEGER;
BEGIN
    ok := Files.ReWrite(f, name);
    IF ok THEN
        Header(self, line);
        written := Files.WriteLine(f, line);
        FOR y := 0 TO self.h - 1 DO
            n := self.w;
            IF n > LEN(line) - 1 THEN n := LEN(line) - 1 END;
            FOR x := 0 TO n - 1 DO
                cp := self.data.Get16(self.data, (self.w * y + x) * CELL);
                IF (cp >= ASCII_LO) & (cp <= ASCII_HI) THEN
                    b := cp
                ELSE
                    b := Charset.ByteOn(cp, Charset.Page866)
                END;
                IF b < 0 THEN b := ORD("?") END;
                IF b = 0 THEN b := ORD(" ") END;  (* a 0X would cut the line short *)
                line[x] := CHR(b)
            END;
            line[n] := 0X;
            written := Files.WriteLine(f, line)
        END;
        written := Files.WriteLine(f, "");
        FOR y := 0 TO self.h - 1 DO
            n := self.w;
            IF 2 * n > LEN(line) - 1 THEN n := (LEN(line) - 1) DIV 2 END;
            FOR x := 0 TO n - 1 DO
                a := self.data.Get16(self.data, (self.w * y + x) * CELL + ATTR_OFS);
                IF a > 0FFH THEN a := 0FFH END;
                line[x * 2] := HexDigit(a DIV 16);
                line[x * 2 + 1] := HexDigit(a MOD 16)
            END;
            line[n * 2] := 0X;
            written := Files.WriteLine(f, line)
        END;
        Files.Close(f)
    END;
    RETURN ok
END Dump;


(* Give the cell block back and then the record, which is the DISPOSE that
   answers the NEW of Create.  The parameter is `Oberon.Object` and the guard
   below is why: this is what goes into the inherited `Done` field, whose
   declared type is `PROCEDURE (self: Object)`, and a procedure variable has to
   match its field's type exactly. *)
PROCEDURE DoneCanvas (self: Oberon.Object);
VAR c: Canvas;
BEGIN
    c := self(Canvas);
    c.data.Done(c.data);
    DISPOSE(c)
END DoneCanvas;


PROCEDURE Create* (w, h: INTEGER): Canvas;
VAR c: Canvas;
BEGIN
    ASSERT((w > 0) & (h > 0));
    NEW(c);
    c.w := w;
    c.h := h;
    c.data := ByteArr.Create(w * h * CELL);
    c.Clear := Clear;
    c.Put := Put;
    c.Get := Get;
    c.AttrAt := AttrAt;
    c.SetAttr := SetAttr;
    c.Print := Print;
    c.HLine := HLine;
    c.VLine := VLine;
    c.Fill := Fill;
    c.Frame := Frame;
    c.Scroll := Scroll;
    c.Blit := Blit;
    c.GetRow := GetRow;
    c.PutRow := PutRow;
    c.Dump := Dump;
    c.Done := DoneCanvas;
    c.Clear(c, DEF_ATTR);
    RETURN c
END Create;

END TuiCanv.
