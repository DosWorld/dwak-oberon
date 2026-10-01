(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   FontFile - glyphs out of a font file.

   Font draws from an image it fills through a painter, and MuHost is the
   painter that asks Windows.  This is the other one: it reads a file.  What it
   buys is the same font on every target - an installed face is a Windows
   thing, a bitmap font file is not - and it buys the small sizes a TrueType
   hinting engine will not make: a 3x5 or an 8x8 drawn as such rather than
   shrunk to it.

   Five formats, all of them one bit to a pixel, which is what the port draws:

     BDF    the X11 bitmap distribution format: a text file of per-glyph BITMAP
            blocks of hex.  What ttyp0, Terminus and the small faces are
            distributed in.
     HEX    GNU Unifont's own format, and its native one: CODEPOINT:hexdata,
            one line to a glyph.  Trivial to read, and the format that covers
            a whole plane.
     PSF1   Linux console fonts, the old header: 8 pixels wide, a height that
            fits in a byte, 256 or 512 glyphs, and optionally a table saying
            which code point each glyph is.
     PSF2   the same with a real header, an arbitrary height and width, and a
            Unicode table that is nearly always there.
     PCF    what BDF is compiled into, and the format X11 reads.  A table of
            contents and then the tables: the glyph metrics, the bitmaps, and
            an encoding that maps a code point to a glyph number.  Every table
            begins with a format word of its own and that word, not the file
            header, decides the byte order, the glyph padding and the bit
            order of what follows - so the reader is a family of layouts and
            not one.  Written and measured against the fonts in a Debian
            xfonts-base package, whose tables are all 0x0E: four bytes of
            glyph padding, MSB byte order, MSB bit order.

   Not read, and deliberately so:

     TTF/OTF  not a bitmap at all - quadratic curves and a rasteriser.
     .gz      inflate is a project of its own; every format above is read
              uncompressed, and a file that is still compressed is refused.

   The format is decided by what is in the file and not by its name.  An
   extension is a hint a user can get wrong; the first bytes are not.

   One representation, whatever was read.  Every glyph becomes a run of bytes,
   one bit to a pixel, the leftmost pixel of a row in the most significant bit
   of its first byte - which is how all five formats already write them, so
   BDF's and HEX's hex is expanded once at load and PSF's bytes are copied, and
   the painter then reads one kind of thing.  Beside the bitmaps sits an index:
   one record to a glyph, sorted by code point, holding where its bitmap is,
   the size of its ink box and where that box sits relative to the origin.

   The cell.  Font draws in a cell of one width and one height, so a file
   that is not monospace has to be made one, and the rule here is the widest:
   the cell is as wide as the widest advance in the file.  A cell narrower than
   some glyph's advance would overlap that glyph with the next, which is a
   fault, where a cell wider than most glyphs want is only loose, which is a
   look.  For the PSF and HEX formats, whose glyphs are whole cells with no
   advance of their own, the width is the file's own.

   Portability.  Nothing here names an operating system or a window: the file
   arrives through ByteArr, which reads it through Files, and the bitmaps
   live in the heap.  A host on a target with no GDI can use this as it stands.
*)
MODULE FontFile;

IMPORT SYSTEM, ByteArr, Font;


CONST
    (* One glyph in the index is six 32-bit words, in this order.  A flat run
       of words rather than an array of records because how many glyphs there
       are is the file's business and is not known until it has been read.

       The index is addressed in bytes - ByteArr is a byte array, and Get32
       and Put32 move four of them - so a record is `Slot` bytes and a field
       sits at its own offset within the record. *)
    Fcp = 0; Foff = 1; Fw = 2; Fh = 3; Fx = 4; Fy = 5;
    TuiFld = 6;
    Word = 4;
    Slot = TuiFld * Word;

    (* What the file turned out to be.  A host may show it; nothing here
       depends on it once the load is done. *)
    fmtUnknown* = 0;
    fmtBDF*     = 1;
    fmtHex*     = 2;
    fmtPSF1*    = 3;
    fmtPSF2*    = 4;
    fmtPCF*     = 5;

    (* Not a file at all: the tables a generated font module carries, which
       FromTable turns into a store.  A caller that shows the format says
       "built in" for this one. *)
    fmtModule*  = 6;

    (* PCF's table types, the ones this reader asks for.  The properties and
       the glyph names are not among them: nothing in a store comes from
       either.  A type may carry a byte-swap flag in its top bit, which is
       masked off where the type is compared. *)
    pcfAccelerators    = 2;
    pcfMetrics         = 4;
    pcfBitmaps         = 8;
    pcfEncodings       = 32;
    pcfBDFAccelerators = 256;

    (* A metrics table whose bit 8 is set keeps five bytes a glyph - the side
       bearings, the advance and the two vertical extents, each biased by 128
       - instead of six 16-bit numbers.  That is what files are written with;
       the plain layout is read as well.

       A bitmap table's low two bits are the glyph padding as a power of two,
       bit 2 says the most significant byte of a number comes first, and bit 3
       says the leftmost pixel is the most significant bit of its byte. *)
    pcfCompressed = 100H;

    (* The glyph number an encoding entry carries for a code point the font
       has not drawn. *)
    pcfNoSuchChar = 0FFFFH;

    (* A metrics or bitmap count past this is a corrupt file and not a font;
       the ceiling is only there so that a bad number cannot become a loop. *)
    MaxGlyphs = 100000;

    (* PSF1's mode byte. *)
    PSF1_512 = 1;
    PSF1_TABLE = 2;

    (* PSF2's flags word. *)
    PSF2_TABLE = 1;

    (* A glyph's ink box may not be larger than this in either direction.  No
       bitmap font is, and a number read out of a corrupt file must not become
       an allocation. *)
    MaxCellDim = 512;

    (* How many distinct glyph data lengths the HEX sniffer will tell apart
       before it gives up and takes the first.  A real file has one. *)
    MaxLens = 8;

    (* A PSF2 Unicode table entry is a run of UTF-8 code points with no
       terminator of its own; this is the room one is copied into.  The widest
       entry in the fonts this port was written against is 39 bytes. *)
    EntryMax = 64;


TYPE
    (* A store: the file's bytes, every glyph's bitmap, and the index.  The
       paint procedure is handed its address rather than the pointer, because
       that is the shape Font's painter has. *)
    Store* = POINTER TO StoreDesc;
    StoreDesc* = RECORD
        src:  ByteArr.ByteArray;   (* the file, byte for byte *)
        bits: ByteArr.ByteArray;   (* the bitmaps, one bit to a pixel *)
        idx:  ByteArr.ByteArray;   (* the index, `TuiFld` words per glyph *)
        n:    INTEGER;

        (* The cell Font is to be given, and where the baseline sits in it,
           counting rows from the top. *)
        cellW*, cellH*, ascent*: INTEGER;

        (* What the file turned out to be, for a program that wants to show
           it.  One of the fmt constants. *)
        format*: INTEGER
    END;


(*============================================================================
   reading the source

   Every scan below walks a ByteArray of the whole file.  A byte past the end
   reads as zero rather than being tested for at each of the hundred places a
   scanner looks ahead, and a zero ends every scan here: it is not a digit, not
   a letter, not a newline.
   ==========================================================================*)

PROCEDURE Byte (s: ByteArr.ByteArray; i: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    IF (i >= 0) & (i < s.Length(s)) THEN v := s.Get8(s, i) ELSE v := 0 END;

    RETURN v
END Byte;


PROCEDURE HexVal (c: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    v := -1;
    IF (c >= ORD("0")) & (c <= ORD("9")) THEN
        v := c - ORD("0")
    ELSIF (c >= ORD("A")) & (c <= ORD("F")) THEN
        v := c - ORD("A") + 10
    ELSIF (c >= ORD("a")) & (c <= ORD("f")) THEN
        v := c - ORD("a") + 10
    END;

    RETURN v
END HexVal;


PROCEDURE IsEol (c: INTEGER): BOOLEAN;
VAR
    res: BOOLEAN;

BEGIN
    res := (c = 0AH) OR (c = 0DH);

    RETURN res
END IsEol;


PROCEDURE IsSpace (c: INTEGER): BOOLEAN;
VAR
    res: BOOLEAN;

BEGIN
    res := IsEol(c) OR (c = 20H) OR (c = 09H) OR (c = 0);

    RETURN res
END IsSpace;


(* Kw - is `text` the word at i?  If it is, `after` is left just past it, which
   is where a keyword's own numbers begin.

   The comparison is by characters and not by string assignment, because what
   LENGTH answers for a string literal passed as an open array is not something
   a file can be written to depend on: a literal is an ARRAY n + 1 OF CHAR and
   this does not have to care which of n and n + 1 the parameter sees.

   What follows the word has to be a space or the end of a line, so that one
   keyword is not found inside a longer one. *)
PROCEDURE Kw (s: ByteArr.ByteArray; i: INTEGER; text: ARRAY OF CHAR;
              VAR after: INTEGER): BOOLEAN;
VAR
    k, n: INTEGER;
    ok: BOOLEAN;

BEGIN
    n := 0;
    WHILE (n < LENGTH(text)) & (text[n] # 0X) DO INC(n) END;
    ok := n > 0;
    k := 0;
    WHILE (k < n) & ok DO
        IF Byte(s, i + k) # ORD(text[k]) THEN ok := FALSE END;
        INC(k)
    END;
    IF ok THEN
        IF ~IsSpace(Byte(s, i + n)) THEN ok := FALSE END
    END;
    after := i + n;

    RETURN ok
END Kw;


(* AtWord - Kw for a caller that wants only the answer. *)
PROCEDURE AtWord (s: ByteArr.ByteArray; i: INTEGER;
                  text: ARRAY OF CHAR): BOOLEAN;
VAR
    after: INTEGER;

BEGIN
    RETURN Kw(s, i, text, after)
END AtWord;


(* SkipSpace - past spaces, tabs and line ends.

   Bounded by the file, and it has to be: a byte past the end reads as zero,
   zero counts as space here, and a scan that trusted that would walk off the
   end of a file that ends in a newline - which is every file - and never come
   back. *)
PROCEDURE SkipSpace (s: ByteArr.ByteArray; i: INTEGER): INTEGER;
VAR
    n: INTEGER;

BEGIN
    n := s.Length(s);
    WHILE (i < n) & IsSpace(Byte(s, i)) DO INC(i) END;

    RETURN i
END SkipSpace;


(* LineEnd - the offset of the end of the line i is on, and NextLine the first
   offset of the line after it. *)
PROCEDURE LineEnd (s: ByteArr.ByteArray; i: INTEGER): INTEGER;
BEGIN
    WHILE ~IsEol(Byte(s, i)) & (i < s.Length(s)) DO INC(i) END;

    RETURN i
END LineEnd;


PROCEDURE NextLine (s: ByteArr.ByteArray; i: INTEGER): INTEGER;
BEGIN
    i := LineEnd(s, i);
    IF Byte(s, i) = 0DH THEN INC(i) END;
    IF Byte(s, i) = 0AH THEN INC(i) END;

    RETURN i
END NextLine;


(* TokInt - the decimal number that starts at or after i, with `after` left
   past it so that a keyword followed by several numbers can be read in one
   go.  A field that is not a number is answered as 0, which is also what a
   scanner wants of a field that is absent: no caller here can do anything with
   a number it could not read. *)
PROCEDURE TokInt (s: ByteArr.ByteArray; i: INTEGER;
                  VAR after: INTEGER): INTEGER;
VAR
    v, c, sign: INTEGER;

BEGIN
    i := SkipSpace(s, i);
    sign := 1;
    c := Byte(s, i);
    IF c = ORD("-") THEN
        sign := -1; INC(i); c := Byte(s, i)
    ELSIF c = ORD("+") THEN
        INC(i); c := Byte(s, i)
    END;
    v := 0;
    WHILE (c >= ORD("0")) & (c <= ORD("9")) DO
        v := v * 10 + (c - ORD("0"));
        INC(i);
        c := Byte(s, i)
    END;
    after := i;

    RETURN v * sign
END TokInt;


(* LE16 and LE32 - a little-endian number out of a binary header. *)
PROCEDURE LE16 (s: ByteArr.ByteArray; i: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    v := Byte(s, i) + Byte(s, i + 1) * 100H;

    RETURN v
END LE16;


PROCEDURE LE32 (s: ByteArr.ByteArray; i: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    v := Byte(s, i) + Byte(s, i + 1) * 100H + Byte(s, i + 2) * 10000H +
         Byte(s, i + 3) * 1000000H;

    RETURN v
END LE32;


(* RowBytes* - the bytes one row of a w-pixel-wide bitmap occupies.  Never
   zero, so that a glyph the file drew with no width still has an address.

   A row is packed and not padded: a store keeps no glyph padding, so a row of
   `w` pixels is (w + 7) DIV 8 bytes, whatever every format it was read from
   thought a row was.*)
PROCEDURE RowBytes* (w: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := (w + 7) DIV 8;
    IF res < 1 THEN res := 1 END;

    RETURN res
END RowBytes;


(*============================================================================
   the index
   ==========================================================================*)

(* Signed32 - the value Get32 built, read back as the signed 32-bit number it
   was written from.

   ByteArr.Get32 zero-extends and says so: it builds the value by repeated
   multiply-and-add, so on a 64-bit target it is never negative, and a -1 put
   into the index comes back as 4294967295.  Every field of a glyph is read
   through here, which is what lets the two that carry a sign - a glyph's x and
   y offsets, negative for anything that reaches left of its origin or hangs
   below the baseline - arrive as they were written.

   The sign is taken from the top 16 bits rather than from bit 31, because
   100000000H does not fit an INTEGER on the 32-bit target this module is also
   built for: the high word is sign-extended on its own and then scaled. *)
PROCEDURE Signed32 (v: INTEGER): INTEGER;
VAR
    lo, hi, r: INTEGER;

BEGIN
    lo := v MOD 10000H;
    hi := (v DIV 10000H) MOD 10000H;
    IF hi >= 8000H THEN hi := hi - 10000H END;
    r := hi * 10000H + lo;

    RETURN r
END Signed32;


PROCEDURE Field (st: Store; k, f: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    v := Signed32(st.idx.Get32(st.idx, k * Slot + f * Word));

    RETURN v
END Field;


PROCEDURE SetField (st: Store; k, f, v: INTEGER);
BEGIN
    st.idx.Put32(st.idx, k * Slot + f * Word, v)
END SetField;


(* Add - one glyph to the end of the index.

   The length is set before the fields are written and not after: Put32 checks
   that what it is about to write lies inside the array, so a record has to
   exist before it can be filled.  SetLength zeroes what it opens, so a field
   this forgets to write reads as 0 rather than as whatever the block held. *)
PROCEDURE Add (st: Store; cp, off, w, h, x, y: INTEGER);
BEGIN
    st.idx.SetLength(st.idx, (st.n + 1) * Slot);
    SetField(st, st.n, Fcp, cp);
    SetField(st, st.n, Foff, off);
    SetField(st, st.n, Fw, w);
    SetField(st, st.n, Fh, h);
    SetField(st, st.n, Fx, x);
    SetField(st, st.n, Fy, y);
    INC(st.n)
END Add;


PROCEDURE Swap (st: Store; a, b: INTEGER);
VAR
    f, u, v: INTEGER;

BEGIN
    f := 0;
    WHILE f < TuiFld DO
        u := Field(st, a, f);
        v := Field(st, b, f);
        SetField(st, a, f, v);
        SetField(st, b, f, u);
        INC(f)
    END
END Swap;


(* Sort - the index by code point.

   An insertion sort, and not for want of a better one: BDF and HEX files are
   written in code point order and a PSF2 table nearly always is, so on every
   file that is actually a font this makes one comparison per glyph and no
   swaps at all.  The quadratic case is a file deliberately written backwards,
   and it costs one pass over a store the size of a font, once. *)
PROCEDURE Sort (st: Store);
VAR
    i, j: INTEGER;

BEGIN
    i := 1;
    WHILE i < st.n DO
        j := i;
        WHILE (j > 0) & (Field(st, j - 1, Fcp) > Field(st, j, Fcp)) DO
            Swap(st, j - 1, j);
            DEC(j)
        END;
        INC(i)
    END
END Sort;


(* Find - the index slot of a code point, or -1. *)
PROCEDURE Find (st: Store; cp: INTEGER): INTEGER;
VAR
    lo, hi, mid, res: INTEGER;

BEGIN
    lo := 0; hi := st.n - 1; res := -1;
    WHILE lo <= hi DO
        mid := (lo + hi) DIV 2;
        IF Field(st, mid, Fcp) = cp THEN
            res := mid;
            lo := hi + 1
        ELSIF Field(st, mid, Fcp) < cp THEN
            lo := mid + 1
        ELSE
            hi := mid - 1
        END
    END;

    RETURN res
END Find;


(*============================================================================
   PCF

   The compiled form of BDF.  What it costs a reader is that the format is not
   one layout but a family: every table begins with a format word of its own,
   and that word - not the file header - decides the byte order, the glyph
   padding and the bit order of everything after it.  The four numbers are
   carried through every access below.
   ==========================================================================*)

(* RevBits - a byte with its bits the other way round.

   A PCF whose bitmap table does not set bit 3 keeps the leftmost pixel of a
   row in the least significant bit, and turning one of those into what the
   store holds - where it is always the most significant - is this.  Every
   file this was measured against sets the bit; the other order is read
   because the flag exists, not because a font has been seen with it. *)
PROCEDURE RevBits (b: INTEGER): INTEGER;
VAR
    r, k: INTEGER;

BEGIN
    r := 0;
    k := 0;
    WHILE k < 8 DO
        r := r * 2 + b MOD 2;
        b := b DIV 2;
        INC(k)
    END;

    RETURN r
END RevBits;


(* Num16 and Num32 - a number out of a PCF table, in the byte order that
   table's own format word declares: bit 2 of it set means the most
   significant byte comes first.  The format word itself is never read this
   way.  It is always little-endian, which is what makes it readable at all -
   the reader has to have it before it can know how to read anything else. *)
PROCEDURE Num16 (s: ByteArr.ByteArray; i, fmt: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    IF fmt MOD 8 >= 4 THEN
        v := Byte(s, i) * 100H + Byte(s, i + 1)
    ELSE
        v := Byte(s, i) + Byte(s, i + 1) * 100H
    END;

    RETURN v
END Num16;


PROCEDURE Num32 (s: ByteArr.ByteArray; i, fmt: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    IF fmt MOD 8 >= 4 THEN
        v := Byte(s, i) * 1000000H + Byte(s, i + 1) * 10000H +
             Byte(s, i + 2) * 100H + Byte(s, i + 3)
    ELSE
        v := Byte(s, i) + Byte(s, i + 1) * 100H + Byte(s, i + 2) * 10000H +
             Byte(s, i + 3) * 1000000H
    END;

    RETURN v
END Num32;


(* Sign16 - a 16-bit number read back as the signed one it was written from.
   A glyph's left side bearing is negative as soon as it reaches left of its
   origin, which is every italic and every accent. *)
PROCEDURE Sign16 (v: INTEGER): INTEGER;
VAR
    r: INTEGER;

BEGIN
    r := v;
    IF r >= 8000H THEN r := r - 10000H END;

    RETURN r
END Sign16;


(* PCFTable - where a table is, and what its own format word says.

   The table of contents is little-endian throughout, whatever byte order the
   tables that follow it are in, and each entry is a type, a format, a size
   and an offset.  A type's top bit is a byte-swap flag and is masked off
   before the comparison. *)
PROCEDURE PCFTable (s: ByteArr.ByteArray; ttype: INTEGER;
                    VAR off, fmt: INTEGER): BOOLEAN;
VAR
    n, i, tp: INTEGER;
    ok: BOOLEAN;

BEGIN
    off := 0; fmt := 0;
    ok := FALSE;
    n := LE32(s, 4);
    IF (n > 0) & (n < 64) & (8 + n * 16 <= s.Length(s)) THEN
        i := 0;
        WHILE (i < n) & ~ok DO
            tp := LE32(s, 8 + i * 16) MOD 1000H;
            IF tp = ttype THEN
                off := LE32(s, 8 + i * 16 + 12);
                ok := (off > 0) & (off + 8 <= s.Length(s));
                IF ok THEN fmt := LE32(s, off) ELSE off := 0 END
            END;
            INC(i)
        END
    END;

    RETURN ok
END PCFTable;


(* PCFMetric - one glyph's ink box, out of the metrics table.  The compressed
   layout keeps five bytes a glyph and the plain one six 16-bit numbers; the
   fields wanted are the same five either way, and the sixth - the attributes
   - is dropped by the compressed writer because it is always zero. *)
PROCEDURE PCFMetric (s: ByteArr.ByteArray; mOff, mFmt, g: INTEGER;
                     lite: BOOLEAN;
                     VAR lsb, rsb, adv, asc, desc: INTEGER);
VAR
    k: INTEGER;

BEGIN
    IF lite THEN
        k := mOff + 6 + 5 * g;
        lsb  := Byte(s, k) - 80H;
        rsb  := Byte(s, k + 1) - 80H;
        adv  := Byte(s, k + 2) - 80H;
        asc  := Byte(s, k + 3) - 80H;
        desc := Byte(s, k + 4) - 80H
    ELSE
        k := mOff + 8 + 12 * g;
        lsb  := Sign16(Num16(s, k, mFmt));
        rsb  := Sign16(Num16(s, k + 2, mFmt));
        adv  := Sign16(Num16(s, k + 4, mFmt));
        asc  := Sign16(Num16(s, k + 6, mFmt));
        desc := Sign16(Num16(s, k + 8, mFmt))
    END
END PCFMetric;


(* PCFCell - how tall the cell is and where the baseline sits in it.

   The numbers are in the accelerators, and there are two tables of them: the
   old one and the BDF one, which the reference reader prefers when a file has
   both.  Nothing else in a store comes from either, so a file with neither is
   drawn from the tallest ink box it does have rather than refused. *)
PROCEDURE PCFCell (s: ByteArr.ByteArray; VAR ascent, descent: INTEGER): BOOLEAN;
VAR
    off, fmt: INTEGER;
    ok: BOOLEAN;

BEGIN
    ascent := 0; descent := 0;
    ok := PCFTable(s, pcfAccelerators, off, fmt);
    IF ~ok THEN
        ok := PCFTable(s, pcfBDFAccelerators, off, fmt)
    END;
    IF ok THEN
        (* Eight flag bytes, then fontAscent and fontDescent as 32-bit
           numbers and maxOverlap; the bounds follow and are not wanted. *)
        ascent := Num32(s, off + 12, fmt);
        descent := Num32(s, off + 16, fmt);
        ok := (ascent > 0) & (descent >= 0) & (ascent + descent <= MaxCellDim)
    END;

    RETURN ok
END PCFCell;


(* LoadPCF - the whole font.

   Three tables are wanted and a file without any of them is refused rather
   than read as an empty font: the metrics, the bitmaps and the encoding.

   The encoding is PCF's own two-level grid - an entry is a glyph number, or
   0FFFFH for a code point the font has not drawn - and walking it row by row,
   and within a row column by column, is what puts the glyphs into the index
   in code point order.  Find's binary search depends on that order, which is
   why there is no Sort at the foot of this the way there is in every loader
   above.

   The bitmap of a glyph is `h` rows of `srcRow` bytes, where srcRow is the
   glyph padding's idea of a row; the store keeps rows of RowBytes(w), so the
   rows are re-laid one at a time rather than copied whole.  A file that ends
   early leaves zeroes rather than trapping: Byte reads past the end as zero,
   so a truncated glyph is blank and not fatal. *)
PROCEDURE LoadPCF (st: Store): BOOLEAN;
VAR
    mOff, mFmt, bOff, bFmt, eOff, eFmt: INTEGER;
    n, i, k, grid, pad, cols, rows, firstCol, firstRow: INTEGER;
    lsb, rsb, adv, asc, desc, w, h: INTEGER;
    srcRow, rowBytes, off, dataOff, goff, row, col, b: INTEGER;
    cp, maxW, maxAsc, maxDesc, ascent, descent: INTEGER;
    lite, bitMsb, ok: BOOLEAN;

BEGIN
    ok := FALSE;
    IF PCFTable(st.src, pcfMetrics, mOff, mFmt) &
       PCFTable(st.src, pcfBitmaps, bOff, bFmt) &
       PCFTable(st.src, pcfEncodings, eOff, eFmt) THEN

        lite := mFmt MOD 200H >= 100H;
        IF lite THEN
            n := Num16(st.src, mOff + 4, mFmt)
        ELSE
            n := Num32(st.src, mOff + 4, mFmt)
        END;

        (* There is one bitmap to a metric, and a file where that is not so
           has offsets that cannot be trusted for anything. *)
        IF (n > 0) & (n <= MaxGlyphs) &
           (Num32(st.src, bOff + 4, bFmt) = n) THEN
            pad := 1;
            k := bFmt MOD 4;
            WHILE k > 0 DO
                pad := pad * 2;
                DEC(k)
            END;
            bitMsb := bFmt MOD 16 >= 8;
            dataOff := bOff + 8 + 4 * n + 16;

            firstCol := Num16(st.src, eOff + 4, eFmt);
            cols := Num16(st.src, eOff + 6, eFmt) - firstCol + 1;
            firstRow := Num16(st.src, eOff + 8, eFmt);
            rows := Num16(st.src, eOff + 10, eFmt) - firstRow + 1;

            IF (cols > 0) & (cols <= 256) & (rows > 0) &
               (eOff + 14 + 2 * cols * rows <= st.src.Length(st.src)) THEN
                maxW := 0; maxAsc := 0; maxDesc := 0;
                i := 0;
                WHILE i < cols * rows DO
                    grid := Num16(st.src, eOff + 14 + 2 * i, eFmt);
                    IF (grid # pcfNoSuchChar) & (grid < n) THEN
                        PCFMetric(st.src, mOff, mFmt, grid, lite,
                                  lsb, rsb, adv, asc, desc);
                        w := rsb - lsb;
                        h := asc + desc;
                        (* A code point the grid can name: the column is the
                           low byte of it and the row the high one. *)
                        cp := (firstRow + i DIV cols) * 100H + firstCol +
                              i MOD cols;
                        IF (w >= 0) & (h >= 0) & (w <= MaxCellDim) &
                           (h <= MaxCellDim) THEN
                            goff := Num32(st.src, bOff + 8 + 4 * grid, bFmt);
                            srcRow := ((w + 8 * pad - 1) DIV (8 * pad)) * pad;
                            rowBytes := RowBytes(w);
                            off := st.bits.Length(st.bits);
                            row := 0;
                            WHILE row < h DO
                                col := 0;
                                WHILE col < rowBytes DO
                                    b := Byte(st.src, dataOff + goff +
                                              row * srcRow + col);
                                    IF ~bitMsb THEN b := RevBits(b) END;
                                    st.bits.Append8(st.bits, b);
                                    INC(col)
                                END;
                                INC(row)
                            END;
                            Add(st, cp, off, w, h, lsb, -desc);
                            IF adv > maxW THEN maxW := adv END;
                            IF asc > maxAsc THEN maxAsc := asc END;
                            IF desc > maxDesc THEN maxDesc := desc END
                        END
                    END;
                    INC(i)
                END;

                IF maxW < 1 THEN maxW := 1 END;
                IF ~PCFCell(st.src, ascent, descent) THEN
                    ascent := maxAsc;
                    descent := maxDesc
                END;
                st.cellW := maxW;
                st.cellH := ascent + descent;
                st.ascent := ascent;
                ok := st.n > 0
            END
        END
    END;

    RETURN ok
END LoadPCF;


(*============================================================================
   the bitmaps

   A glyph's bitmap is stored as its ink box: `RowBytes(w)` bytes to a row, `h`
   rows, the top row first.  Every format already writes rows that way, so the
   only work is that BDF and HEX write them as hex and PSF as bytes.
   ==========================================================================*)

(* AppendHex - one row of hex digits into the bitmaps, as bytes.  A digit that
   is not one ends the row early, which is what a truncated file ends with, and
   the rest of the row is left blank rather than the file being refused. *)
PROCEDURE AppendHex (st: Store; s: ByteArr.ByteArray; VAR i: INTEGER;
                     rowBytes: INTEGER);
VAR
    k, hi, lo: INTEGER;

BEGIN
    k := 0;
    WHILE k < rowBytes DO
        hi := HexVal(Byte(s, i));
        lo := 0;
        IF hi >= 0 THEN
            INC(i);
            lo := HexVal(Byte(s, i));
            IF lo < 0 THEN lo := 0 ELSE INC(i) END
        ELSE
            hi := 0
        END;
        st.bits.Append8(st.bits, hi * 16 + lo);
        INC(k)
    END
END AppendHex;


(* AppendRaw - bytes copied straight across, for PSF. *)
PROCEDURE AppendRaw (st: Store; s: ByteArr.ByteArray; VAR i: INTEGER;
                     len: INTEGER);
VAR
    k: INTEGER;

BEGIN
    k := 0;
    WHILE k < len DO
        st.bits.Append8(st.bits, Byte(s, i));
        INC(i);
        INC(k)
    END
END AppendRaw;


(*============================================================================
   BDF
   ==========================================================================*)

(* BDFHeader - the font-wide numbers.

   `ascent` and `descent` come from FONT_ASCENT and FONT_DESCENT when the file
   has them, and otherwise from FONTBOUNDINGBOX, whose x and y are the bottom
   left of the ink relative to the baseline: the box reaches from y to y + h,
   so the row above the baseline is y + h and the room below it is -y. *)
PROCEDURE BDFHeader (st: Store; VAR ascent, descent: INTEGER);
VAR
    i, n, boxW, boxH, boxX, boxY, after: INTEGER;
    done: BOOLEAN;

BEGIN
    ascent := 0; descent := 0;
    n := st.src.Length(st.src);
    i := 0;
    after := 0;
    done := FALSE;
    WHILE (i < n) & ~done DO
        i := SkipSpace(st.src, i);
        IF AtWord(st.src, i, "ENDPROPERTIES") THEN
            done := TRUE
        ELSIF Kw(st.src, i, "FONTBOUNDINGBOX", after) THEN
            boxW := TokInt(st.src, after, after);
            boxH := TokInt(st.src, after, after);
            boxX := TokInt(st.src, after, after);
            boxY := TokInt(st.src, after, after);
            IF (boxH > 0) & (boxH <= MaxCellDim) & (ascent <= 0) THEN
                ascent := boxH + boxY;
                descent := -boxY
            END;
            i := NextLine(st.src, i)
        ELSIF Kw(st.src, i, "FONT_ASCENT", after) THEN
            ascent := TokInt(st.src, after, after);
            i := NextLine(st.src, i)
        ELSIF Kw(st.src, i, "FONT_DESCENT", after) THEN
            descent := TokInt(st.src, after, after);
            i := NextLine(st.src, i)
        ELSIF AtWord(st.src, i, "CHARS") THEN
            done := TRUE
        ELSE
            i := NextLine(st.src, i)
        END
    END;
    IF ascent <= 0 THEN ascent := 1 END;
    IF descent < 0 THEN descent := 0 END
END BDFHeader;


(* BDFGlyph - one STARTCHAR ... ENDCHAR block.  `i` is left past the ENDCHAR
   whether or not the block became a glyph, and `maxDWidth` is raised to the
   widest advance seen.

   A block becomes a glyph when it has a code point, a box and its rows.  An
   ENCODING of -1 is a glyph the font has drawn but given no code point to:
   there is nothing to look it up by, so its block is read and dropped. *)
PROCEDURE BDFGlyph (st: Store; VAR i: INTEGER; VAR maxDWidth: INTEGER);
VAR
    n, cp, dw, w, h, x, y, got, off, after: INTEGER;
    hasBox, inBitmap, done: BOOLEAN;

BEGIN
    n := st.src.Length(st.src);
    cp := -1; dw := 0; w := 0; h := 0; x := 0; y := 0; got := 0; off := 0;
    after := 0;
    hasBox := FALSE; inBitmap := FALSE; done := FALSE;
    WHILE (i < n) & ~done DO
        i := SkipSpace(st.src, i);
        IF inBitmap & (got < h) & ~AtWord(st.src, i, "ENDCHAR") THEN
            AppendHex(st, st.src, i, RowBytes(w));
            INC(got);
            i := NextLine(st.src, i)
        ELSE
            inBitmap := FALSE;
            IF Kw(st.src, i, "ENCODING", after) THEN
                cp := TokInt(st.src, after, after)
            ELSIF Kw(st.src, i, "DWIDTH", after) THEN
                dw := TokInt(st.src, after, after)
            ELSIF Kw(st.src, i, "BBX", after) THEN
                w := TokInt(st.src, after, after);
                h := TokInt(st.src, after, after);
                x := TokInt(st.src, after, after);
                y := TokInt(st.src, after, after);
                hasBox := (w >= 0) & (h >= 0) & (w <= MaxCellDim) &
                          (h <= MaxCellDim)
            ELSIF AtWord(st.src, i, "BITMAP") THEN
                (* No advance here: the `NextLine` at the foot of this loop
                   moves past the BITMAP line and lands on the first row of
                   data, which is what `inBitmap` then starts reading.  Doing
                   it here as well skipped a row of every glyph in the font,
                   and a glyph one row short of its own BBX is one this drops
                   at its ENDCHAR - which is a font of no glyphs at all. *)
                IF hasBox & (cp >= 0) THEN
                    off := st.bits.Length(st.bits);
                    inBitmap := TRUE
                END
            ELSIF AtWord(st.src, i, "ENDCHAR") THEN
                (* `got >= h` and not `got > 0`: a glyph the file drew with no
                   height at all - a space - has nothing to read and is still a
                   glyph, and one whose rows were cut short by the end of the
                   file is not. *)
                IF hasBox & (cp >= 0) & (got >= h) THEN
                    Add(st, cp, off, w, h, x, y)
                END;
                done := TRUE
            END;
            IF ~done THEN i := NextLine(st.src, i) END
        END
    END;
    IF dw > maxDWidth THEN maxDWidth := dw END
END BDFGlyph;


PROCEDURE LoadBDF (st: Store): BOOLEAN;
VAR
    i, n, ascent, descent, maxDWidth: INTEGER;

BEGIN
    BDFHeader(st, ascent, descent);
    maxDWidth := 0;
    n := st.src.Length(st.src);
    i := SkipSpace(st.src, 0);
    WHILE i < n DO
        WHILE (i < n) & ~AtWord(st.src, i, "STARTCHAR") DO
            i := NextLine(st.src, i)
        END;
        IF i < n THEN
            i := NextLine(st.src, i);
            BDFGlyph(st, i, maxDWidth)
        END
    END;
    IF maxDWidth < 1 THEN maxDWidth := 1 END;
    st.cellW := maxDWidth;
    st.cellH := ascent + descent;
    st.ascent := ascent;
    Sort(st);

    RETURN st.n > 0
END LoadBDF;


(*============================================================================
   GNU Unifont HEX

   One line to a glyph: the code point in hex, a colon, then the rows of the
   glyph as hex digits, two digits to an 8-pixel row and one row after another
   with nothing between them.

   The width is not in the file and cannot be: 16 hex digits is 8 rows of 8
   pixels and 32 is 16 rows of 8, and a file of 16-pixel-wide glyphs would need
   64 digits for 16 rows of 16 - the same 64 that 8 pixels wide and 32 rows
   would.  So the reading here is 8 pixels wide, always, and a file whose
   glyphs are 16 wide is refused rather than drawn skewed.  What that costs is
   nothing for the files this was written against: unscii's glyphs are 8 wide,
   and the one line among them that is not is blank.

   The cell's height is the data length most of the lines share, so a file with
   a handful of taller glyphs keeps the height of the rest and the tall ones
   are left out rather than stretching the cell every glyph is drawn in.
   ==========================================================================*)

(* HexLine - is the line at i a CODEPOINT:data line, and how many hex digits
   does the data have?  -1 when it is not one.  `dataOfs` is left at the first
   digit of the data. *)
PROCEDURE HexLine (s: ByteArr.ByteArray; i: INTEGER; VAR cp: INTEGER;
                   VAR dataOfs: INTEGER): INTEGER;
VAR
    k, d, digits, res: INTEGER;
    seenColon: BOOLEAN;

BEGIN
    cp := 0; dataOfs := i; res := -1;
    k := i;
    d := 0;
    seenColon := FALSE;
    WHILE (d < 8) & (HexVal(Byte(s, k)) >= 0) DO
        cp := cp * 16 + HexVal(Byte(s, k));
        INC(k);
        INC(d)
    END;
    IF (d >= 4) & (Byte(s, k) = ORD(":")) THEN
        seenColon := TRUE;
        INC(k)
    END;
    IF seenColon THEN
        digits := 0;
        WHILE HexVal(Byte(s, k)) >= 0 DO
            INC(k);
            INC(digits)
        END;
        IF (digits > 0) & IsEol(Byte(s, k)) THEN
            res := digits;
            dataOfs := k - digits
        END
    END;

    RETURN res
END HexLine;


PROCEDURE LoadHex (st: Store): BOOLEAN;
VAR
    i, n, digits, cp, dataOfs, base, best, k, off, bytes: INTEGER;
    lens, counts: ARRAY MaxLens OF INTEGER;
    nLens: INTEGER;

BEGIN
    n := st.src.Length(st.src);

    (* Which data length most of the lines have. *)
    nLens := 0; best := 0; base := 0;
    i := 0;
    WHILE i < n DO
        i := SkipSpace(st.src, i);
        digits := HexLine(st.src, i, cp, dataOfs);
        IF digits > 0 THEN
            k := 0;
            WHILE (k < nLens) & (lens[k] # digits) DO INC(k) END;
            IF (k = nLens) & (nLens < MaxLens) THEN
                lens[nLens] := digits;
                counts[nLens] := 0;
                INC(nLens)
            END;
            IF k < nLens THEN
                INC(counts[k]);
                IF counts[k] > best THEN
                    best := counts[k];
                    base := digits
                END
            END
        END;
        i := NextLine(st.src, i)
    END;

    IF base > 0 THEN
        i := 0;
        WHILE i < n DO
            i := SkipSpace(st.src, i);
            digits := HexLine(st.src, i, cp, dataOfs);
            IF digits = base THEN
                off := st.bits.Length(st.bits);
                bytes := base DIV 2;
                AppendHex(st, st.src, dataOfs, bytes);
                Add(st, cp, off, 8, bytes, 0, 0)
            END;
            i := NextLine(st.src, i)
        END
    END;

    st.cellW := 8;
    st.cellH := base DIV 2;
    (* The whole cell is the ink box, so the baseline is its bottom row: these
       formats carry no descent of their own and put descenders inside the same
       cell. *)
    st.ascent := st.cellH;
    Sort(st);

    RETURN st.n > 0
END LoadHex;


(*============================================================================
   PSF

   The glyph area is a run of fixed-size glyphs, whole bytes to a row, so a
   glyph is a whole number of bytes and needs no padding of its own.

   Where there is no table there is no mapping from a glyph to a code point at
   all - the order is the font's own, which for the console fonts these are is
   code page 437.  Without a table this reads glyph n as code point n, which is
   right for the ASCII range every one of them agrees on and wrong above it.  A
   file with a table - every PSF2, and the PSF1s written by the tools in use
   now - is read exactly.
   ==========================================================================*)

(* TableEntry - the code points of one glyph out of a PSF2 Unicode table, into
   `cp`, and the offset just past the entry.  An entry is the UTF-8 of one or
   more code points, several of which a font maps to the same glyph; only the
   first is kept, because a glyph index can be searched by one code point and
   not by a set.  The separator is 0FFH, which is not a byte of any UTF-8
   sequence. *)
PROCEDURE TableEntry (s: ByteArr.ByteArray; i: INTEGER;
                      VAR cp: INTEGER): INTEGER;
VAR
    buf: ARRAY EntryMax OF CHAR;
    k, v, got: INTEGER;

BEGIN
    cp := -1;
    k := 0;
    WHILE (Byte(s, i) # 0FFH) & (Byte(s, i) # 0) & (k < EntryMax - 1) DO
        buf[k] := CHR(Byte(s, i));
        INC(k);
        INC(i)
    END;
    buf[k] := 0X;
    IF Byte(s, i) = 0FFH THEN INC(i) END;
    IF k > 0 THEN
        v := 0;
        got := Font.Next(buf, 0, -1, v);
        IF got > 0 THEN cp := v END
    END;

    RETURN i
END TableEntry;


(* LoadPSF1 - the old header: magic 36 04, a mode byte, the size of a glyph in
   bytes, and then the glyphs.

   The width is 8 and the height is the whole of the size, which is right for
   every PSF1 that matters and wrong for the one variant that is 9 wide, where
   the size is twice the height.  Nothing in the header says which it is - the
   9-wide files are told apart by the size being even, and so is every file
   whose height is even.  Rather than guess at half the fonts, this reads 8
   wide and the height the file gives. *)
PROCEDURE LoadPSF1 (st: Store): BOOLEAN;
VAR
    mode, charsize, nglyph, i, g, cp: INTEGER;
    hasTable: BOOLEAN;

BEGIN
    mode := Byte(st.src, 2);
    charsize := Byte(st.src, 3);
    nglyph := 256;
    IF mode MOD 2 = PSF1_512 THEN nglyph := 512 END;
    hasTable := (mode DIV PSF1_TABLE) MOD 2 = 1;

    IF (charsize > 0) & (charsize <= MaxCellDim) THEN
        i := 4;
        g := 0;
        WHILE g < nglyph DO
            AppendRaw(st, st.src, i, charsize);
            INC(g)
        END;
        st.cellW := 8;
        st.cellH := charsize;
        st.ascent := charsize;

        (* The glyphs are read in file order whatever the mapping is, so the
           store is filled once and the code points are applied afterwards;
           without a table they are the glyph's own position. *)
        g := 0;
        WHILE g < nglyph DO
            IF hasTable THEN
                cp := LE16(st.src, 4 + nglyph * charsize + g * 2);
                IF cp = 0FFFFH THEN cp := -1 END
            ELSE
                cp := g
            END;
            IF cp >= 0 THEN
                Add(st, cp, g * charsize, st.cellW, st.cellH, 0, 0)
            END;
            INC(g)
        END;
        Sort(st)
    END;

    RETURN st.n > 0
END LoadPSF1;


(* LoadPSF2 - the header is 32 bytes and little-endian throughout: the size of
   the header, the flags, how many glyphs, how many bytes each one takes in the
   file, then the height and the width.  The bitmaps start at the end of the
   header and the Unicode table at the end of the bitmaps. *)
PROCEDURE LoadPSF2 (st: Store): BOOLEAN;
VAR
    headersize, flags, nglyph, bpg, height, width: INTEGER;
    rowBytes, glyphBytes, pad, i, g, off, cp: INTEGER;
    hasTable: BOOLEAN;

BEGIN
    headersize := LE32(st.src, 8);
    flags := LE32(st.src, 12);
    nglyph := LE32(st.src, 16);
    bpg := LE32(st.src, 20);
    height := LE32(st.src, 24);
    width := LE32(st.src, 28);
    hasTable := flags MOD 2 = PSF2_TABLE;

    IF (headersize >= 32) & (nglyph > 0) & (bpg > 0) & (width > 0) &
       (width <= MaxCellDim) & (height > 0) & (height <= MaxCellDim) THEN
        rowBytes := (width + 7) DIV 8;
        glyphBytes := rowBytes * height;
        IF bpg >= glyphBytes THEN
            (* A glyph takes `bpg` bytes in the file and `glyphBytes` of them
               are its bitmap; the rest is padding a file is free to carry, and
               stepping by bpg rather than by glyphBytes is what keeps the
               glyphs in step with the table. *)
            pad := bpg - glyphBytes;
            i := headersize;
            g := 0;
            WHILE g < nglyph DO
                AppendRaw(st, st.src, i, glyphBytes);
                i := i + pad;
                INC(g)
            END;
            st.cellW := rowBytes * 8;
            st.cellH := height;
            st.ascent := height;

            i := headersize + nglyph * bpg;
            g := 0;
            WHILE g < nglyph DO
                off := g * glyphBytes;
                IF hasTable THEN
                    i := TableEntry(st.src, i, cp)
                ELSE
                    cp := g
                END;
                IF cp >= 0 THEN
                    Add(st, cp, off, st.cellW, st.cellH, 0, 0)
                END;
                INC(g)
            END;
            Sort(st)
        END
    END;

    RETURN st.n > 0
END LoadPSF2;


(*============================================================================
   what a caller uses
   ==========================================================================*)

PROCEDURE Sniff (s: ByteArr.ByteArray): INTEGER;
VAR
    fmt, i, cp, dataOfs: INTEGER;

BEGIN
    fmt := fmtUnknown;
    IF AtWord(s, 0, "STARTFONT") THEN
        fmt := fmtBDF
    ELSIF (Byte(s, 0) = 72H) & (Byte(s, 1) = 0B5H) & (Byte(s, 2) = 4AH) &
          (Byte(s, 3) = 86H) THEN
        fmt := fmtPSF2
    ELSIF (Byte(s, 0) = 36H) & (Byte(s, 1) = 4H) THEN
        fmt := fmtPSF1
    ELSIF (Byte(s, 0) = 1) & (Byte(s, 1) = ORD("f")) &
          (Byte(s, 2) = ORD("c")) & (Byte(s, 3) = ORD("p")) THEN
        fmt := fmtPCF
    ELSE
        i := SkipSpace(s, 0);
        IF HexLine(s, i, cp, dataOfs) > 0 THEN fmt := fmtHex END
    END;

    RETURN fmt
END Sniff;


(* Release - give a store back.  Declared before Load, which calls it on the
   failing path: a procedure has to be known before it is named. *)
PROCEDURE Release* (VAR st: Store);
BEGIN
    IF st # NIL THEN
        st.bits.Done(st.bits);
        st.idx.Done(st.idx);
        st.src.Done(st.src);
        st := NIL
    END
END Release;


(* Load - read a font file into a store.  NIL and FALSE when the file cannot be
   read, is in none of the formats above, or turns out to hold no glyph at all.
   A store that was built and then found wanting is given back here, so a
   caller has nothing to free on the failing path. *)
PROCEDURE Load* (path: ARRAY OF CHAR; VAR st: Store): BOOLEAN;
VAR
    src: ByteArr.ByteArray;
    s: Store;
    ok: BOOLEAN;

BEGIN
    st := NIL;
    ok := FALSE;
    src := ByteArr.CreateFromFile(path);
    IF src # NIL THEN
        NEW(s);
        s.src := src;
        s.bits := ByteArr.Create(0);
        s.idx := ByteArr.Create(0);
        s.n := 0;
        s.cellW := 0; s.cellH := 0; s.ascent := 0;
        s.format := Sniff(src);
        IF s.format = fmtBDF THEN
            ok := LoadBDF(s)
        ELSIF s.format = fmtHex THEN
            ok := LoadHex(s)
        ELSIF s.format = fmtPSF1 THEN
            ok := LoadPSF1(s)
        ELSIF s.format = fmtPSF2 THEN
            ok := LoadPSF2(s)
        ELSIF s.format = fmtPCF THEN
            ok := LoadPCF(s)
        END;
        IF ok THEN
            st := s
        ELSE
            Release(s)
        END
    END;

    RETURN ok
END Load;


(* Count - how many glyphs the file yielded.  A program that lists fonts wants
   this: "Terminus 8x16, 1356 glyphs" is worth more to a reader than a name. *)
PROCEDURE Count* (st: Store): INTEGER;
VAR
    n: INTEGER;

BEGIN
    n := 0;
    IF st # NIL THEN n := st.n END;

    RETURN n
END Count;


(* Metric - the cell the store's glyphs are drawn in. *)
PROCEDURE Metric* (st: Store; VAR w, h: INTEGER);
BEGIN
    w := 0; h := 0;
    IF st # NIL THEN
        w := st.cellW;
        h := st.cellH
    END
END Metric;


(* Ascent - how many rows down the cell the baseline sits.

   The cell is `Ascent` rows of ink above the baseline and `CellH - Ascent`
   below it, and a glyph is drawn at `Ascent - asc` rows down.  It is the
   face's own ascent and not the tallest glyph's, which is why a caller that
   writes a font out - a generator turning a .pcf into a module - has to be
   able to ask for it: the number cannot be recovered from the glyphs. *)
PROCEDURE Ascent* (st: Store): INTEGER;
VAR
    n: INTEGER;
BEGIN
    n := 0;
    IF st # NIL THEN n := st.ascent END;

    RETURN n
END Ascent;


(* FromTable - a store out of tables a module carries, rather than out of a
   file.  This is what a generated font module is for: the font is in the
   program and needs no file beside it, and a program that has a file beside
   it can still be given that file instead.

     codes[k]        the k-th glyph's code point, in ascending order
     box[k * 4 + n]  its left side bearing, right side bearing, ascent and
                     descent - the ink box against the origin, which is what
                     a file's metrics hold too
     bits            every glyph's bitmap, one bit to a pixel, rows packed,
                     the glyphs one after another in the same order

   Nothing is sorted here.  A generated table is in code point order already -
   that is the generator's promise and its reason for existing - and the order
   is what Find's binary search needs. *)
PROCEDURE FromTable* (codes: ARRAY OF INTEGER; box: ARRAY OF INTEGER;
                      bits: ARRAY OF BYTE;
                      cellW, cellH, ascent: INTEGER;
                      VAR st: Store): BOOLEAN;
VAR
    s: Store;
    n, k, w, h, off, p, bytes: INTEGER;
    ok: BOOLEAN;

BEGIN
    st := NIL;
    ok := FALSE;
    n := LEN(codes);
    IF (n > 0) & (LEN(box) >= n * 4) & (cellW > 0) & (cellH > 0) &
       (ascent > 0) & (ascent <= cellH) THEN
        NEW(s);
        s.src := ByteArr.Create(0);
        s.bits := ByteArr.Create(0);
        s.idx := ByteArr.Create(0);
        s.n := 0;
        s.cellW := cellW;
        s.cellH := cellH;
        s.ascent := ascent;
        s.format := fmtModule;
        off := 0;
        k := 0;
        WHILE k < n DO
            w := box[k * 4 + 1] - box[k * 4];
            h := box[k * 4 + 2] + box[k * 4 + 3];
            bytes := RowBytes(w) * h;
            p := 0;
            WHILE (p < bytes) & (off + p < LEN(bits)) DO
                s.bits.Append8(s.bits, bits[off + p]);
                INC(p)
            END;
            Add(s, codes[k], off, w, h, box[k * 4], -box[k * 4 + 3]);
            off := off + bytes;
            INC(k)
        END;
        ok := s.n > 0;
        IF ok THEN st := s ELSE Release(s) END
    END;

    RETURN ok
END FromTable;


(* Paint - one code point, as the cell Font asked for.  This is a PaintFn,
   and Font is handed SYSTEM.VAL(INTEGER, st) to give back here.

   The cell Font asks for is the one Metric reported, so a glyph that does
   not fit is one the file drew outside its own font-wide box; what fits is
   drawn and the rest dropped, rather than the whole glyph being refused for
   the sake of a pixel of an accent.  A code point the file has no glyph for is
   FALSE, which is what leaves Font its own tofu. *)
PROCEDURE Paint* (ctxAdr, cp, cellW, cellH, bufAdr: INTEGER): BOOLEAN;
VAR
    st: Store;
    k, rowBytes, row, col, v, dx, dy, src, bit: INTEGER;
    ok: BOOLEAN;

BEGIN
    k := 0;
    WHILE k < cellW * cellH DO
        SYSTEM.PUT8(bufAdr + k, 0);
        INC(k)
    END;
    ok := FALSE;
    st := SYSTEM.VAL(Store, ctxAdr);
    IF st # NIL THEN
        k := Find(st, cp);
        IF k >= 0 THEN
            ok := TRUE;
            rowBytes := RowBytes(Field(st, k, Fw));
            (* The top row of the ink box, as a row of the cell: the baseline
               is `ascent` rows down, the box's own y is its bottom relative to
               the baseline, and the box is `h` rows tall. *)
            dy := st.ascent - Field(st, k, Fy) - Field(st, k, Fh);
            row := 0;
            WHILE row < Field(st, k, Fh) DO
                IF (dy + row >= 0) & (dy + row < cellH) THEN
                    col := 0;
                    WHILE col < Field(st, k, Fw) DO
                        dx := Field(st, k, Fx) + col;
                        IF (dx >= 0) & (dx < cellW) THEN
                            src := Field(st, k, Foff) + row * rowBytes +
                                   col DIV 8;
                            v := st.bits.Get8(st.bits, src);
                            (* the leftmost pixel of a row is the most
                               significant bit of its first byte *)
                            bit := 7 - col MOD 8;
                            WHILE bit > 0 DO
                                v := v DIV 2;
                                DEC(bit)
                            END;
                            IF v MOD 2 = 1 THEN
                                SYSTEM.PUT8(bufAdr + (dy + row) * cellW + dx,
                                            0FFH)
                            END
                        END;
                        INC(col)
                    END
                END;
                INC(row)
            END
        END
    END;

    RETURN ok
END Paint;


(*============================================================================
   walking a store

   The renderer asks a store for one glyph at a time, by code point, and never
   needs to know how many there are or in what order they lie.  A caller that
   writes a store out does need both, so the index is readable here and not
   only through Find and Paint.  samples/microui/Pcf2Mod.mod is that caller:
   it turns a font file into the Oberon-07 module that carries the same font
   inside a program.
   ==========================================================================*)

(* Glyphs* - how many glyphs the store holds. *)
PROCEDURE Glyphs* (st: Store): INTEGER;
BEGIN
    RETURN st.n
END Glyphs;


(* Glyph* - one glyph by its slot.  Slots run from 0 to Glyphs - 1 and are in
   code point order, which is the order Find searches in and the order a font
   written out wants its glyphs in.

   The four numbers are the ink box against the origin on the baseline: the
   ink is `rsb - lsb` wide and `asc + desc` tall, and its top row lies
   `ascent - asc` rows down the cell.  `ofs` is where the ink begins in the
   bitmap stream, `asc + desc` rows of RowBytes(rsb - lsb) bytes each.

   A slot outside the range answers a glyph of nothing rather than reading the
   index from the far side of its start. *)
PROCEDURE Glyph* (st: Store; i: INTEGER;
                  VAR cp, lsb, rsb, asc, desc, ofs: INTEGER);
BEGIN
    IF (i >= 0) & (i < st.n) THEN
        cp := Field(st, i, Fcp);
        ofs := Field(st, i, Foff);
        lsb := Field(st, i, Fx);
        rsb := lsb + Field(st, i, Fw);
        (* The index keeps the descent as the negated bottom edge, which is
           what Paint wants; a box against the baseline is what a caller
           writing one out wants, so it is undone here. *)
        desc := -Field(st, i, Fy);
        asc := Field(st, i, Fh) - desc
    ELSE
        cp := -1; ofs := 0; lsb := 0; rsb := 0; asc := 0; desc := 0
    END
END Glyph;


(* Ink* - copy a glyph's bitmap bytes out: `n` of them, from `ofs` in the
   bitmap stream.  A range past the end of the stream reads as zero, so a
   short stream leaves the rest of the caller's buffer alone rather than
   trapping.
   Result: how many bytes were copied, which is `n` or the size of `dst`. *)
PROCEDURE Ink* (st: Store; ofs, n: INTEGER; VAR dst: ARRAY OF BYTE): INTEGER;
VAR
    i, len: INTEGER;

BEGIN
    IF n > LEN(dst) THEN n := LEN(dst) END;
    len := st.bits.Length(st.bits);
    i := 0;
    WHILE i < n DO
        IF (ofs + i >= 0) & (ofs + i < len) THEN
            dst[i] := st.bits.Get8(st.bits, ofs + i)
        ELSE
            dst[i] := 0
        END;
        INC(i)
    END;

    RETURN n
END Ink;


END FontFile.
