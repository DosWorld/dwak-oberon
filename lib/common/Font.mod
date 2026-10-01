(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   Font - the glyph table the renderer draws text from.

   MuAtlas is a fixed picture: 96 drawn glyphs, and every byte that is not one
   of them clamped to the empty box at 127.  That is faithful to microui's own
   renderer - the C is `mu_min((unsigned char) *p, 127)` - and it is also the
   wall this module removes.  Unicode has some 150000 assigned code points and
   no fixed picture holds them, so the picture here is made at run time: a heap
   image holding the generated 128x128 atlas as its first rows, and a grid of
   cells behind it filled one cell at a time, on demand, by whatever glyph
   painter the host registers.

   One image and one index space.  The generated atlas's pixels are copied in
   and its table entries are copied over, so indices 1..133 keep exactly the
   meaning they have in MuAtlas - 1..4 the icons, 5 the white pixel, 6..133 the
   ASCII glyphs - and MuRender goes on addressing a single table.  A code point
   the base atlas has no glyph for is rasterised into the first free cell and
   gets a table entry of its own, past 133.

   Monospace is what makes measurement cheap and stable.  A cell has a fixed
   width, so its glyph advances by that width whether or not its ink has been
   rasterised yet, and a string measures the same before it is drawn as after.
   The base atlas is not monospace - its rectangles are as wide as their ink,
   a space is 2 pixels and `#` is 7 - and that is why an advance is always read
   from the glyph's own rectangle rather than computed from the cell: the two
   kinds of glyph then sit in one table and neither has to know of the other.

   The provider.  PaintFn is the whole of the extension point: given a code
   point and a cell size, fill a buffer with 0..255 coverage, or answer FALSE
   and get the empty box.  lib/Windows/MuHost fills it from GDI, which is any
   installed face at any size; lib/common/FontFile fills it from a bitmap
   font file, which is the same fonts on every target.  A host that registers
   nothing keeps the generated atlas alone, which is what this port drew before
   this module existed, pixel for pixel.

   Portability.  Nothing here names an operating system.  The image and the
   cell scratch buffer come from Heap and are given back by Done.
*)
MODULE Font;

IMPORT SYSTEM, MuAtlas, Heap;


CONST
    (* The generated atlas is the floor: its pixels go into the first rows of
       the image and its table entries into the first slots of Rects. *)
    BaseW = MuAtlas.Width;
    BaseH = MuAtlas.Height;

    (* The generated atlas's share of Rects: what an icon id is bounded by, and
       the first table entry a cell may take. *)
    BaseRects* = MuAtlas.MaxRects;

    (* The table of glyph rectangles - one to a base entry and one to each cell
       filled afterwards.  A fixed array, because MuRender addresses it by
       index.  Past this many distinct code points a new one keeps the empty
       box instead of the table growing. *)
    MaxRects* = 1024;

    (* How much heap the image may take.  The cell decides how many of those
       entries the image can actually hold: a 9x18 cell leaves room for three
       thousand, so there the table is the limit, while an 18x40 one leaves
       room for seven hundred, so there the image is.  Either way a character
       past the limit draws the empty box rather than the image growing
       without bound. *)
    ImageBudget = 512 * 1024;

    (* The cell when no painter is registered.  Nothing is rasterised then, so
       only the height is ever read, and 17 is what the generated atlas's own
       glyphs are tall: a line of text stays the 18 pixels it always was. *)
    NoCellW = 6;
    NoCellH = 17;

    (* What a code point draws when nothing can paint it.  microui's own
       `mu_min(chr, 127)`, and the box the generated atlas keeps there. *)
    Tofu = MuAtlas.FontBase + 127;


TYPE
    (* MuAtlas.Rect itself and not a second ARRAY 4 OF INTEGER that looks like
       it: two arrays of the same shape declared apart are two types to this
       compiler and neither assigns to the other, and the base table is copied
       over wholesale at Init. *)
    Rect* = MuAtlas.Rect;

    (* A glyph painter: fill the cellW x cellH bytes at bufAdr with coverage,
       0 for transparent and 255 for opaque, the ink already placed inside the
       cell - or answer FALSE for a code point this font has no glyph for.
       ctxAdr is whatever the registration was given (a device context, a
       loaded font) and is handed back unchanged. *)
    PaintFn* = PROCEDURE (ctxAdr, cp, cellW, cellH, bufAdr: INTEGER): BOOLEAN;


VAR
    paint: PaintFn;
    ctxAdr: INTEGER;

    (* The image: AtlasW bytes to a row, AtlasH rows of coverage.  It lives on
       the heap, so Coverage is the only door into it and the address is not
       handed out. *)
    img: INTEGER;
    imgSize: INTEGER;
    AtlasW*, AtlasH*: INTEGER;

    (* The cell a painter works in, and the height of a line of text. *)
    CellW*, CellH*: INTEGER;
    LineHeight*: INTEGER;

    (* Glyph rectangles.  0 is unused - microui's id 0 means "none" - 1..133
       come from the generated atlas, and nRects is the first free one. *)
    Rects*: ARRAY MaxRects OF Rect;
    nRects*: INTEGER;

    (* Cells of the grid that have been used, how many there is room for, and
       how many fit in a row of the image. *)
    slot: INTEGER;
    maxSlots: INTEGER;
    cellsPerRow: INTEGER;

    (* The code point of every cell that has been filled, sorted, each beside
       its entry in Rects.  Sorted and searched rather than hashed: a lookup is
       eleven comparisons, filling it is one insert per new character, and a
       table that runs out refuses quietly instead of hiding a glyph behind a
       probe sequence. *)
    cacheCp: ARRAY MaxRects OF INTEGER;
    cacheRect: ARRAY MaxRects OF INTEGER;
    nCache: INTEGER;

    (* One cell, laid out by a painter before it is copied into the image. *)
    cell: INTEGER;


(*============================================================================
   the image
   ==========================================================================*)

(* Coverage - the alpha of one pixel of the image, at a linear index.  The
   caller computes that index from a rectangle this module made, so it is
   inside the image by construction and is not tested again here: this runs
   once per pixel of every glyph. *)
PROCEDURE Coverage* (i: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    SYSTEM.GET8(img + i, v);

    RETURN v
END Coverage;


(*============================================================================
   the cache
   ==========================================================================*)

(* Find - the cache slot holding a code point, or -1. *)
PROCEDURE Find (cp: INTEGER): INTEGER;
VAR
    lo, hi, mid, res: INTEGER;

BEGIN
    lo := 0; hi := nCache - 1; res := -1;
    WHILE lo <= hi DO
        mid := (lo + hi) DIV 2;
        IF cacheCp[mid] = cp THEN
            res := mid;
            lo := hi + 1
        ELSIF cacheCp[mid] < cp THEN
            lo := mid + 1
        ELSE
            hi := mid - 1
        END
    END;

    RETURN res
END Find;


(* Remember - record what a code point draws.  The table is kept sorted, so a
   new character shifts the tail up by one; that happens once per character
   and a lookup then costs eleven comparisons.  A full table drops the entry
   rather than the glyph: the next frame looks the code point up, misses, and
   rasterises it again, which costs a cell only if there is room for one. *)
PROCEDURE Remember (cp, r: INTEGER);
VAR
    i: INTEGER;

BEGIN
    IF nCache < MaxRects THEN
        i := nCache;
        WHILE (i > 0) & (cacheCp[i - 1] > cp) DO
            cacheCp[i] := cacheCp[i - 1];
            cacheRect[i] := cacheRect[i - 1];
            DEC(i)
        END;
        cacheCp[i] := cp;
        cacheRect[i] := r;
        INC(nCache)
    END
END Remember;


(*============================================================================
   glyphs
   ==========================================================================*)

(* Render - rasterise a code point into the next free cell, or answer the
   empty box.  The cell is laid out in a scratch buffer and copied into the
   image only once the painter has said it has a glyph: a painter that fails
   neither takes a cell nor leaves a table entry behind. *)
PROCEDURE Render (cp: INTEGER): INTEGER;
VAR
    sx, sy, x, y, v, r: INTEGER;

BEGIN
    r := Tofu;
    IF (paint # NIL) & (slot < maxSlots) & (nRects < MaxRects) THEN
        sx := (slot MOD cellsPerRow) * CellW;
        sy := BaseH + (slot DIV cellsPerRow) * CellH;
        IF paint(ctxAdr, cp, CellW, CellH, cell) THEN
            y := 0;
            WHILE y < CellH DO
                x := 0;
                WHILE x < CellW DO
                    SYSTEM.GET8(cell + y * CellW + x, v);
                    SYSTEM.PUT8(img + (sy + y) * AtlasW + (sx + x), v);
                    INC(x)
                END;
                INC(y)
            END;
            Rects[nRects][0] := sx;
            Rects[nRects][1] := sy;
            Rects[nRects][2] := CellW;
            Rects[nRects][3] := CellH;
            r := nRects;
            INC(nRects);
            INC(slot)
        END
    END;
    Remember(cp, r);

    RETURN r
END Render;


(* Glyph - the table entry a code point draws as.  ASCII with no painter is
   answered straight from the generated atlas and is not cached at all: those
   entries never change, and caching them would fill the table with the
   characters a program uses most. *)
PROCEDURE Glyph* (cp: INTEGER): INTEGER;
VAR
    i, r: INTEGER;

BEGIN
    IF (paint = NIL) & (cp >= 0) & (cp < 80H) THEN
        r := MuAtlas.FontBase + cp
    ELSE
        i := Find(cp);
        IF i >= 0 THEN r := cacheRect[i] ELSE r := Render(cp) END
    END;

    RETURN r
END Glyph;


(*============================================================================
   UTF-8

   The one decoder in the port.  MuRender measures and draws text through it,
   so a string cannot measure by one reading of its bytes and draw by another -
   which is what happened when the two call sites each walked the bytes
   themselves.
   ==========================================================================*)

(* Next - the code point at ofs, and how many bytes it took.  `len` is a count
   of bytes from ofs, as microui's own callbacks use it, or negative for the
   rest of the string.  Zero is returned at the end.  A sequence that is not a
   character - truncated, overlong, a lone continuation byte, half a surrogate
   pair - yields U+FFFD and consumes one byte, so a caller always moves on. *)
PROCEDURE Next* (str: ARRAY OF CHAR; ofs, len: INTEGER; VAR cp: INTEGER): INTEGER;
VAR
    b, need, i, v, stop, res: INTEGER;
    bad: BOOLEAN;

BEGIN
    IF len < 0 THEN stop := LENGTH(str) ELSE stop := ofs + len END;
    res := 1;
    cp := 0FFFDH;
    IF (ofs < 0) OR (ofs >= stop) OR (ofs >= LENGTH(str)) THEN
        res := 0
    ELSE
        b := ORD(str[ofs]);
        IF b < 80H THEN
            cp := b
        ELSE
            need := 0; v := 0;
            IF (b >= 0C2H) & (b <= 0DFH) THEN
                need := 2; v := b - 0C0H
            ELSIF (b >= 0E0H) & (b <= 0EFH) THEN
                need := 3; v := b - 0E0H
            ELSIF (b >= 0F0H) & (b <= 0F4H) THEN
                need := 4; v := b - 0F0H
            END;
            (* 0C0H, 0C1H and 0F5H.. open nothing: the first two would only
               ever encode a character that fits in one byte, the rest are
               past the last plane *)
            bad := need = 0;
            IF ~bad THEN
                IF ofs + need > stop THEN
                    bad := TRUE
                ELSE
                    i := 1;
                    WHILE (i < need) & ~bad DO
                        b := ORD(str[ofs + i]);
                        IF (b < 80H) OR (b > 0BFH) THEN
                            bad := TRUE
                        ELSE
                            v := v * 40H + (b - 80H);
                            INC(i)
                        END
                    END
                END
            END;
            IF bad THEN
                cp := 0FFFDH
            ELSIF ((need = 2) & (v < 80H)) OR ((need = 3) & (v < 800H)) OR
                  ((need = 4) & (v < 10000H)) OR
                  ((v >= 0D800H) & (v <= 0DFFFH)) OR (v > 10FFFFH) THEN
                cp := 0FFFDH
            ELSE
                cp := v;
                res := need
            END
        END
    END;

    RETURN res
END Next;


(*============================================================================
   the font
   ==========================================================================*)

(* Ready - is there an image to draw from?  A host that wants a font of its
   own registers one before it renders; MuRender asks this so that a program
   which never does still draws the generated atlas. *)
PROCEDURE Ready* (): BOOLEAN;
VAR
    res: BOOLEAN;

BEGIN
    res := img # 0;

    RETURN res
END Ready;


(* Done - give the image and the scratch cell back.  Init makes both, and a
   second Init calls this first, so this is the only place they return; a host
   calls it when its window is gone, and a program with no window when it has
   drawn its last frame. *)
PROCEDURE Done*;
BEGIN
    IF img # 0 THEN
        Heap.Free(img);
        img := 0
    END;
    IF cell # 0 THEN
        Heap.Free(cell);
        cell := 0
    END;
    imgSize := 0;
    nRects := 0;
    nCache := 0;
    slot := 0;
    maxSlots := 0;
    cellsPerRow := 1;
    paint := NIL;
    ctxAdr := 0;
    AtlasW := BaseW;
    AtlasH := BaseH;
    CellW := NoCellW;
    CellH := NoCellH;
    LineHeight := NoCellH + 1
END Done;


(* Init - make the image and set the cell.  Repeated calls replace what is
   there, which is what changing the font at run time comes to: the grid is
   laid out from the cell, so a new cell means a new image.

   A painter of NIL, or a cell of zero or less, means no provider: the
   generated atlas alone, at its own height.  A cell that does not fit the
   budget at all - one taller than the room below the base rows - is refused,
   and the module is left with no font rather than with an image too large to
   allocate. *)
PROCEDURE Init* (p: PaintFn; ctx: INTEGER; cellW, cellH: INTEGER): BOOLEAN;
VAR
    avail, rows, y, x, i: INTEGER;
    ok: BOOLEAN;

BEGIN
    Done;
    IF (p = NIL) OR (cellW <= 0) OR (cellH <= 0) THEN
        paint := NIL;
        ctxAdr := 0;
        CellW := NoCellW;
        CellH := NoCellH;
        ok := TRUE
    ELSE
        paint := p;
        ctxAdr := ctx;
        CellW := cellW;
        CellH := cellH;
        ok := TRUE
    END;
    LineHeight := CellH + 1;

    (* The image is AtlasW wide.  The generated atlas is 128 and needs every
       one of those columns; a wider cell widens the image with it. *)
    AtlasW := BaseW;
    IF CellW > AtlasW THEN AtlasW := CellW END;
    cellsPerRow := AtlasW DIV CellW;
    IF cellsPerRow < 1 THEN cellsPerRow := 1 END;

    (* How many cells the budget leaves room for, below the base rows. *)
    avail := (ImageBudget DIV AtlasW) - BaseH;
    IF paint = NIL THEN
        maxSlots := 0
    ELSIF avail < CellH THEN
        ok := FALSE
    ELSE
        maxSlots := (avail DIV CellH) * cellsPerRow;
        IF maxSlots > MaxRects - BaseRects THEN
            maxSlots := MaxRects - BaseRects
        END
    END;
    rows := (maxSlots + cellsPerRow - 1) DIV cellsPerRow;
    IF rows < 1 THEN rows := 1 END;

    IF ~ok THEN
        (* Nothing can be drawn through this cell.  Leave the module in the
           state Done leaves behind - no painter, the generated atlas at its
           own size - so that a caller which ignores the answer still draws
           rather than reading an image that was never made. *)
        paint := NIL;
        ctxAdr := 0;
        maxSlots := 0;
        AtlasW := BaseW;
        CellW := NoCellW;
        CellH := NoCellH;
        LineHeight := NoCellH + 1;
        rows := 1
    END;
    AtlasH := BaseH + rows * CellH;
    imgSize := AtlasW * AtlasH;

    img := Heap.Alloc(imgSize);
    IF paint # NIL THEN cell := Heap.Alloc(CellW * CellH) END;

    (* A cell that was never painted has to read as transparent, so the whole
       image starts at zero and the atlas is laid over it.  The stride
       differs - the atlas is 128 to a row and the image may be wider - so the
       copy is a row at a time. *)
    i := 0;
    WHILE i < imgSize DO
        SYSTEM.PUT8(img + i, 0);
        INC(i)
    END;
    y := 0;
    WHILE y < BaseH DO
        x := 0;
        WHILE x < BaseW DO
            i := MuAtlas.Pixels[y * BaseW + x];
            SYSTEM.PUT8(img + y * AtlasW + x, i);
            INC(x)
        END;
        INC(y)
    END;

    i := 0;
    WHILE i < BaseRects DO
        Rects[i] := MuAtlas.Rects[i];
        INC(i)
    END;
    nRects := BaseRects;

    RETURN ok
END Init;


END Font.
