(* MuRender - the software rasteriser the microui port draws through.

   A port of rxi's microui 2.02 (https://github.com/rxi/microui, MIT licence)
   to Oberon-07.  microui's own demo renders with OpenGL, which no target here
   has.  This module keeps the four things the demo's renderer.c provides - a
   clear, a clip rectangle, a rectangle, a run of text and an icon - but draws
   them into a plain 32-bit framebuffer, which each host then pushes to a
   window of its own.

   Portability is the point.  Nothing here names an operating system: the
   framebuffer is memory, the glyphs come from Font, and drawing ends when
   ProcessCommands has walked the command list.  A host - lib/Windows/MuHost
   for win32 and win64, one more per target after that - owns the window,
   turns its messages into Microui's input calls and blits Address() when a
   frame is done.

   Colours.  microui's mu_Color is r, g, b and an alpha, and the original
   hands all four to OpenGL, which blends.  Here a pixel is one 32-bit word,
   0x00RRGGBB, which is what a 32-bit BI_RGB DIB wants on the Windows side and
   what a plain XImage wants on the X11 one, and the blending is done in this
   module: a glyph's coverage is multiplied by the colour's own alpha and the
   source is mixed into the destination by that.  Alpha only ever comes from
   the atlas, so an opaque rectangle - which is nearly all of the command list
   - is written straight in with no arithmetic.
*)
MODULE MuRender;

IMPORT SYSTEM, Heap, MuBase, Font, Microui;


CONST
    (* The framebuffer is not a fixed array any more.  A host that resizes its
       window hands Init the new client area and is given a buffer of exactly
       that size, the old one having been given back first, so the window is
       drawn whole at whatever size the user dragged it to.  It was one static
       array of MaxWidth x MaxHeight pixels, and a window grown past that was
       drawn in its top-left corner with the rest of it never painted - which
       is what made a maximised window look frozen.

       The ceiling is Heap's and not this module's: one chunk is the largest
       single allocation this tree can make and a pixel is four bytes of it, so
       a client of more than MaxPixels pixels is drawn in its top-left corner
       after all.  On the 32- and 64-bit targets that is 4 194 302 pixels - a
       1920 x 1080 window fits, a 4K one does not.  The other answer would be
       Heap's own assert, which no host survives. *)
    MaxPixels = Heap.MaxPayload DIV 4;

    (* The height of a line of text is not fixed here.  It used to be 18,
       because the generated atlas's glyphs are 17 tall and the reference
       renderer answers 18 for them; with a font of the host's own choosing the
       leading has to grow with the glyphs or a large font would overlap its
       own next line, and every layout in microui takes the line height from
       TextHeight below.  Font keeps the number - `CellH + 1`, which is the
       same 18 while no font is registered. *)

    (* The longest run of text one command may carry.  microui truncates at
       MaxDrawText, so this is slack rather than a limit that is ever met. *)
    MaxDrawRun = 1024;


VAR
    (* The framebuffer: the address of a chunk of heap, one 32-bit word a
       pixel, top row first, Width of them to a row.  Reach it through Get and
       Put; a host reaches it through Address.  A pixel is four bytes and has
       to stay that wide - the host is handed this address and describes it to
       the system as a bitmap, so an eight byte element would put four zero
       bytes between every pixel and its neighbour and a row of Width pixels
       would come to twice the stride the host declares.  Four bytes is what a
       CARD32 is on every target, which is how the fixed array it replaced
       said the same thing.

       cap is how many pixels the chunk holds, which is not the live area: a
       window that shrank gives nothing back, and one that grew asks for a
       chunk of the next class up.  Zero means nothing is allocated. *)
    pix, cap: INTEGER;

    (* The live drawing area. *)
    Width*, Height*: INTEGER;

    (* The clip rectangle the command list last asked for. *)
    clip: MuBase.Rect;


(*============================================================================
   pixels
   ==========================================================================*)

(* Mix - one colour component of a source over a destination, both 0..255, by
   a coverage a.  C's arithmetic, x * 255, is done at the end so that a fully
   covered pixel comes out exactly as the source. *)
PROCEDURE Mix (d, s, a: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF a <= 0 THEN
        res := d
    ELSIF a >= 255 THEN
        res := s
    ELSE
        res := (s * a + d * (255 - a) + 127) DIV 255
    END;

    RETURN res
END Mix;


(* BlendPixel - a pixel of the source over a pixel of the destination.  Both
   are packed 0x00RRGGBB. *)
PROCEDURE BlendPixel (dst, src, a: INTEGER): INTEGER;
VAR
    r, g, b, res: INTEGER;

BEGIN
    IF a <= 0 THEN
        res := dst
    ELSIF a >= 255 THEN
        res := src
    ELSE
        r := Mix((dst DIV 10000H) MOD 100H, (src DIV 10000H) MOD 100H, a);
        g := Mix((dst DIV 100H) MOD 100H, (src DIV 100H) MOD 100H, a);
        b := Mix(dst MOD 100H, src MOD 100H, a);
        res := (r * 10000H) + (g * 100H) + b
    END;

    RETURN res
END BlendPixel;


(* Get, Put - the only doors into a framebuffer pixel.  The pixel is a CARD32
   and the drawing code works in INTEGERs, and this dialect assigns neither to
   the other in either direction, so the two have to meet somewhere; SYSTEM's
   GET32 and PUT32 are where, rather than SYSTEM.VAL, which wants a designator
   and will not take the expression a caller has just computed. *)
PROCEDURE Get (i: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    SYSTEM.GET32(pix + i * 4, v);

    RETURN v
END Get;


PROCEDURE Put (i, v: INTEGER);
BEGIN
    SYSTEM.PUT32(pix + i * 4, v)
END Put;


(* Pack - a mu_Color as a framebuffer pixel.  Its alpha is handled by whoever
   draws, because at full coverage it makes no difference. *)
PROCEDURE Pack (color: MuBase.Color): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := (color.r * 10000H) + (color.g * 100H) + color.b;

    RETURN res
END Pack;


(* Half - C's integer division truncates towards zero.  Oberon's DIV rounds
   towards minus infinity, so a negative difference has to be routed round it.
   Here it only ever decides where an icon sits inside a rectangle that is
   narrower than the icon, which is rare but not impossible.  The subtraction
   is right under either reading of DIV for a positive argument. *)
PROCEDURE Half (d: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF d < 0 THEN
        res := -((-d) DIV 2)
    ELSE
        res := d DIV 2
    END;

    RETURN res
END Half;


(*============================================================================
   rectangles
   ==========================================================================*)

(* Trim - intersect r with the clip rectangle and with the framebuffer, so that
   a fill loop may run over the result without testing anything per pixel.  A
   rectangle that comes out empty has w or h zero and both loops skip it. *)
PROCEDURE Trim (VAR r: MuBase.Rect);
VAR
    x0, y0, x1, y1: INTEGER;

BEGIN
    x0 := r.x;
    y0 := r.y;
    x1 := r.x + r.w;
    y1 := r.y + r.h;
    IF x0 < clip.x THEN x0 := clip.x END;
    IF y0 < clip.y THEN y0 := clip.y END;
    IF x1 > clip.x + clip.w THEN x1 := clip.x + clip.w END;
    IF y1 > clip.y + clip.h THEN y1 := clip.y + clip.h END;
    IF x0 < 0 THEN x0 := 0 END;
    IF y0 < 0 THEN y0 := 0 END;
    IF x1 > Width THEN x1 := Width END;
    IF y1 > Height THEN y1 := Height END;
    IF x1 < x0 THEN x1 := x0 END;
    IF y1 < y0 THEN y1 := y0 END;
    r.x := x0; r.y := y0; r.w := x1 - x0; r.h := y1 - y0
END Trim;


PROCEDURE Clear* (color: MuBase.Color);
VAR
    v, i, n: INTEGER;

BEGIN
    v := Pack(color);
    n := Width * Height;
    i := 0;
    WHILE i < n DO
        Put(i, v);
        INC(i)
    END;
    (* The clip is left as it was: r_clear runs before the command list, and
       the first clip command of the frame sets it. *)
END Clear;


PROCEDURE SetClipRect* (rect: MuBase.Rect);
BEGIN
    clip := rect;
    (* microui's unclipped rectangle is millions of pixels wide, and a clip
       command carries whatever the geometry produced - both are trimmed to
       the framebuffer here rather than on every pixel. *)
    IF clip.x < 0 THEN
        clip.w := clip.w + clip.x;
        clip.x := 0
    END;
    IF clip.y < 0 THEN
        clip.h := clip.h + clip.y;
        clip.y := 0
    END;
    IF clip.x + clip.w > Width THEN clip.w := Width - clip.x END;
    IF clip.y + clip.h > Height THEN clip.h := Height - clip.y END;
    IF clip.w < 0 THEN clip.w := 0 END;
    IF clip.h < 0 THEN clip.h := 0 END
END SetClipRect;


PROCEDURE DrawRect* (rect: MuBase.Rect; color: MuBase.Color);
VAR
    r: MuBase.Rect;
    v, a, x, y: INTEGER;
    row: INTEGER;

BEGIN
    r := rect;
    Trim(r);
    IF (r.w > 0) & (r.h > 0) THEN
        v := Pack(color);
        a := color.a;
        y := r.y;
        WHILE y < r.y + r.h DO
            row := y * Width + r.x;
            IF a >= 255 THEN
                x := 0;
                WHILE x < r.w DO
                    Put(row + x, v);
                    INC(x)
                END
            ELSE
                x := 0;
                WHILE x < r.w DO
                    Put(row + x, BlendPixel(Get(row + x), v, a));
                    INC(x)
                END
            END;
            INC(y)
        END
    END
END DrawRect;


(*============================================================================
   glyphs

   One atlas entry is an alpha mask: the pixel says how much of it there is.
   A glyph is drawn at its own size, one destination pixel a source pixel, and
   an icon is centred inside the rectangle it was given.
   ==========================================================================*)

(* GlyphWidth - how far the pen moves after a glyph.  Read from the glyph's own
   rectangle rather than computed from a cell, because the table holds two
   kinds of entry: the generated atlas's, whose rectangles are as wide as their
   ink - a space is 2 pixels and `#` is 7 - and a font's, whose rectangles are
   all one cell wide.  One rule measures both. *)
PROCEDURE GlyphWidth (idx: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := Font.Rects[idx][2];

    RETURN res
END GlyphWidth;


PROCEDURE DrawGlyph (idx, dx, dy: INTEGER; color: MuBase.Color);
VAR
    src: Font.Rect;
    x0, y0, x1, y1, sx0, sy0, sx, sy, x, y, a, v: INTEGER;
    row: INTEGER;

BEGIN
    src := Font.Rects[idx];
    IF (src[2] > 0) & (src[3] > 0) THEN
        x0 := dx; y0 := dy; x1 := dx + src[2]; y1 := dy + src[3];
        IF x0 < clip.x THEN x0 := clip.x END;
        IF y0 < clip.y THEN y0 := clip.y END;
        IF x1 > clip.x + clip.w THEN x1 := clip.x + clip.w END;
        IF y1 > clip.y + clip.h THEN y1 := clip.y + clip.h END;
        IF x0 < 0 THEN x0 := 0 END;
        IF y0 < 0 THEN y0 := 0 END;
        IF x1 > Width THEN x1 := Width END;
        IF y1 > Height THEN y1 := Height END;
        IF (x1 > x0) & (y1 > y0) THEN
            sx0 := src[0] + (x0 - dx);
            sy0 := src[1] + (y0 - dy);
            v := Pack(color);
            y := y0; sy := sy0;
            WHILE y < y1 DO
                x := x0; sx := sx0;
                row := y * Width;
                WHILE x < x1 DO
                    (* the image is 8-bit coverage; the colour's own alpha
                       scales it, so a translucent label stays translucent *)
                    a := (Font.Coverage(sy * Font.AtlasW + sx) * color.a) DIV 255;
                    IF a # 0 THEN
                        Put(row + x, BlendPixel(Get(row + x), v, a))
                    END;
                    INC(x); INC(sx)
                END;
                INC(y); INC(sy)
            END
        END
    END
END DrawGlyph;


(* RunLength - how many bytes of a run are to be read.  microui passes a count,
   or a negative number for "to the end of the buffer", which is what its own
   callbacks take. *)
PROCEDURE RunLength (str: ARRAY OF CHAR; ofs, len: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF len < 0 THEN res := LENGTH(str) - ofs ELSE res := len END;
    IF res < 0 THEN res := 0 END;
    IF res > MaxDrawRun THEN res := MaxDrawRun END;

    RETURN res
END RunLength;


(* DrawTextRun - a run of text, one character at a time.

   The bytes are read through Font.Next, which is the port's only UTF-8
   decoder, and each code point is asked of Font for the table entry it
   draws as.  Measuring and drawing go through the same two calls, so a string
   cannot be laid out by one reading of its bytes and painted by another - and
   a malformed sequence costs one byte and draws one box rather than stopping
   the run or looping on it. *)
PROCEDURE DrawTextRun (str: ARRAY OF CHAR; ofs, len, x, y: INTEGER;
                       color: MuBase.Color);
VAR
    i, n, k, cp, idx, cx: INTEGER;

BEGIN
    n := RunLength(str, ofs, len);
    cx := x;
    i := 0;
    WHILE i < n DO
        k := Font.Next(str, ofs + i, n - i, cp);
        IF k <= 0 THEN
            i := n
        ELSE
            idx := Font.Glyph(cp);
            DrawGlyph(idx, cx, y, color);
            cx := cx + GlyphWidth(idx);
            i := i + k
        END
    END
END DrawTextRun;


PROCEDURE DrawText* (str: ARRAY OF CHAR; ofs, len, x, y: INTEGER;
                     color: MuBase.Color);
BEGIN
    DrawTextRun(str, ofs, len, x, y, color)
END DrawText;


PROCEDURE DrawIcon* (id: INTEGER; rect: MuBase.Rect; color: MuBase.Color);
VAR
    src: Font.Rect;

BEGIN
    IF (id >= 0) & (id < Font.BaseRects) THEN
        src := Font.Rects[id];
        DrawGlyph(id, rect.x + Half(rect.w - src[2]),
                        rect.y + Half(rect.h - src[3]), color)
    END
END DrawIcon;


(*============================================================================
   the callbacks microui asks for, and the command list
   ==========================================================================*)

PROCEDURE TextWidth* (ctx: Microui.Context; font: INTEGER;
                      str: ARRAY OF CHAR; ofs, len: INTEGER): INTEGER;
VAR
    i, n, k, cp, res: INTEGER;

BEGIN
    n := RunLength(str, ofs, len);
    res := 0;
    i := 0;
    WHILE i < n DO
        k := Font.Next(str, ofs + i, n - i, cp);
        IF k <= 0 THEN
            i := n
        ELSE
            res := res + GlyphWidth(Font.Glyph(cp));
            i := i + k
        END
    END;

    RETURN res
END TextWidth;


PROCEDURE TextHeight* (ctx: Microui.Context; font: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := Font.LineHeight;

    RETURN res
END TextHeight;


(* DrawFrame - what a host puts in ctx.drawFrame.

   This used to be a second copy of the library's own frame painter, kept in
   step with it by hand; it is now the same procedure.  There is one thing a
   frame is - a fill, a shadow, a bevel and a border, each of them asked of
   the fill's Part - and the renderer is one of its two callers, not a second
   place that decides what a control looks like.  The core still cannot draw:
   the callback exists because Microui knows what a frame is and nothing
   about putting pixels on a surface, and Microui.DefaultFrame only appends
   commands to the list that this module later walks. *)
PROCEDURE DrawFrame* (ctx: Microui.Context; rect: MuBase.Rect;
                      colorid: INTEGER);
BEGIN
    Microui.DefaultFrame(ctx, rect, colorid)
END DrawFrame;


(* ProcessCommands - draw one frame's command list.  This is main.c's loop:
   clipping, rectangles, text and icons, in the order the library emitted
   them.  The jump commands are not seen here; NextCommand follows them. *)
PROCEDURE ProcessCommands* (ctx: Microui.Context);
VAR
    c: INTEGER;

BEGIN
    c := Microui.NoIndex;
    WHILE Microui.NextCommand(ctx, c) DO
        CASE ctx.commands[c].typ OF
            MuBase.CmdClip:
                SetClipRect(ctx.commands[c].rect)
          | MuBase.CmdRect:
                DrawRect(ctx.commands[c].rect, ctx.commands[c].color)
          | MuBase.CmdText:
                DrawTextRun(ctx.textArena, ctx.commands[c].strOfs,
                            ctx.commands[c].strLen,
                            ctx.commands[c].pos.x, ctx.commands[c].pos.y,
                            ctx.commands[c].color)
          | MuBase.CmdIcon:
                DrawIcon(ctx.commands[c].id, ctx.commands[c].rect,
                         ctx.commands[c].color)
        END
    END
END ProcessCommands;


(*============================================================================
   the framebuffer
   ==========================================================================*)

(* Init - set the live drawing area, and make the framebuffer hold it.  A host
   calls it once with the client size of its window and again with the new size
   every time the window is resized, so it is called with a size it already has
   as often as with one it has not.

   The buffer is asked of Heap and is exactly w * h pixels.  Growing it means
   giving the old chunk back first - a chunk is a fixed class and Usable() would
   keep answering the old one - and the new pixels are zeroed here, because a
   host may blit what it finds before it has drawn a frame.  A window that
   shrank keeps the chunk it has: Width and Height are what drawing is clipped
   to, so the extra pixels cost nothing but the memory, and a window dragged
   back and forth would otherwise ask the allocator for the same chunk on every
   step of the drag.

   The font is made sure of here too.  A host that wants a font of its own
   registers it before this and will have done so already; a program that never
   registers one - every target but Windows, today - keeps the generated atlas,
   which is exactly what this module drew before Font existed.  Asking is
   what makes the line height sound: unwatched, it would still be zero when the
   first layout asks for it. *)
PROCEDURE Init* (w, h: INTEGER);
VAR
    ok: BOOLEAN;
    n, i: INTEGER;

BEGIN
    ok := Font.Ready();
    IF ~ok THEN ok := Font.Init(NIL, 0, 0, 0) END;

    (* A minimised window is nothing in one of the two directions, and an area
       of nothing has no pixel to write to, so a side is never below one.  The
       other end is Heap's ceiling: a client past it is drawn in its top-left
       corner rather than bringing the host down. *)
    IF w < 1 THEN w := 1 END;
    IF h < 1 THEN h := 1 END;
    IF w * h > MaxPixels THEN
        h := MaxPixels DIV w;
        IF h < 1 THEN h := 1 END
    END;

    n := w * h;
    IF n > cap THEN
        IF pix # 0 THEN Heap.Free(pix) END;
        pix := Heap.Alloc(n * 4);
        cap := n;
        i := 0;
        WHILE i < n DO
            Put(i, 0);
            INC(i)
        END
    END;

    Width := w;
    Height := h;
    MuBase.MakeRect(clip, 0, 0, w, h)
END Init;


(* Done - give the framebuffer back.  Init makes it and every later call
   keeps it or grows it, so this is the only place the memory is returned.  A
   host calls it when its window is gone; a program that never had a window - a
   test that renders a frame into a file, say - calls it itself when it is
   finished.  Address() is not valid afterwards until the next Init. *)
PROCEDURE Done*;
BEGIN
    IF pix # 0 THEN
        Heap.Free(pix);
        pix := 0;
        cap := 0
    END;
    Width := 0;
    Height := 0;
    MuBase.MakeRect(clip, 0, 0, 0, 0)
END Done;


(* Address - where the pixels are, for a host about to hand them to a window.
   One 32-bit word a pixel - see the comment on the framebuffer - the first row
   first, Width of them to a row, Stride() bytes between rows. *)
PROCEDURE Address* (): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := pix;

    RETURN res
END Address;


(* Stride - how many bytes there are in a framebuffer row.  Two hosts want it
   in bytes and one in pixels, so both are here. *)
PROCEDURE Stride* (): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := Width * 4;

    RETURN res
END Stride;


(* GetPixel - one pixel, 0x00RRGGBB, for a host that has to read back rather
   than write, and for a test that wants to know what was drawn. *)
PROCEDURE GetPixel* (x, y: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF (x >= 0) & (x < Width) & (y >= 0) & (y < Height) THEN
        res := Get(y * Width + x)
    ELSE
        res := 0
    END;

    RETURN res
END GetPixel;


END MuRender.
