MODULE MuHeadless;

(* A frame drawn without a window.

   MuHost.Run is the only way to put a microui window on a screen, and that is
   right for a program a person is meant to use.  It is the wrong way to find
   out whether a program that was GENERATED draws what it was supposed to: a
   check that has to put a window on somebody's screen is not a check anybody
   can run, and a window that is never opened cannot be photographed.

   So this is the second door, and it is deliberately a narrow one.  It takes
   the same frame procedure MuHost takes, runs it the same number of times,
   replays the command list the same way MuHost's own BuildFrame does, and then
   reports what landed in the framebuffer instead of blitting it: a PPM for a
   person to look at and a hash for a script to compare.  Nothing here knows
   what a form is - the frame procedure is the caller's, and it still owes the
   frame contract (Microui.BeginFrame first, Microui.EndFrame last), because it
   is the same procedure MuHost would have called.

   Why RenderPasses is 2 and not 1, and it is not a matter of taste: microui
   answers a hit test from the ROOT the PREVIOUS frame ended with, so a frame
   that follows a mouse position the library has not yet seen draws the control
   under the cursor in its calm state and only the frame after that shows it
   hovered.  One pass would therefore photograph a picture that depends on
   nothing at all, and two make the picture the one a second frame would show.
   BeginFrame rewinds the command list, the text arena and the root list, so
   only the last pass survives - which is the point. *)

IMPORT Clipboard, MuBase, Microui, MuRender, Files, Strings;

CONST
    (* The same seed and the same recurrence the designer's own windowless
       renderer uses, so that a hash printed by a generated module and a hash
       printed by the designer are the same kind of number and can be compared
       at all.  MixPix is Designer's, and it is a recurrence and not FNV on
       purpose: INTEGER is 32 bits on win32, so a plain multiply overflows
       there and the two targets would hash one picture differently. *)
    HashSeed = 7;
    PixChunk = 3072;
    RenderPasses = 2;

TYPE
    FrameProc* = PROCEDURE (ctx: Microui.Context);

VAR
    f: Files.File;
    pixN: INTEGER;
    pixbuf: ARRAY PixChunk OF BYTE;

PROCEDURE MixPix (VAR h: INTEGER; v: INTEGER);
BEGIN
    h := ((h MOD 16384) * 65599 + (h DIV 16384) + v + 1) MOD 2147483647
END MixPix;


(* Flush and PpmByte - the body goes out a buffer at a time.  WriteByte buffers
   too, but a quarter of a million calls for one 320x200 picture is a quarter of
   a million calls. *)
PROCEDURE Flush;
VAR
    n: INTEGER;

BEGIN
    IF pixN > 0 THEN
        n := Files.BlockWrite(f, pixbuf, pixN);
        pixN := 0
    END
END Flush;


PROCEDURE PpmByte (b: INTEGER);
BEGIN
    IF pixN >= PixChunk - 3 THEN Flush END;
    pixbuf[pixN] := b;
    INC(pixN)
END PpmByte;


(* PpmHeader - the three lines of a binary PPM.  They end in a bare LF: the file
   is read by other programs and CR is not part of the format.  Files.WriteLine
   always writes CRLF, which is what a .frm wants and what this does not. *)
PROCEDURE PpmHeader (w, h: INTEGER);
VAR
    s: ARRAY 24 OF CHAR;
    n: INTEGER;

BEGIN
    n := Files.Write(f, "P6");
    n := Files.WriteByte(f, 10);
    Strings.FromInt(w, s);
    n := Files.Write(f, s);
    n := Files.WriteByte(f, 32);
    Strings.FromInt(h, s);
    n := Files.Write(f, s);
    n := Files.WriteByte(f, 10);
    n := Files.Write(f, "255");
    n := Files.WriteByte(f, 10)
END PpmHeader;


(* Render - the whole of it.  `hash` comes back with the hash of the frame
   whatever else happens, because the number is what a script compares and the
   file is only what a person looks at; the answer says whether the file was
   written.

   The return path is unconditional and that is the one thing worth knowing
   here: whatever kind of window this program would have opened, this door never
   opens one, so nothing has to be closed and MuRender.Done is called on the way
   out. *)
PROCEDURE Render* (ctx: Microui.Context; frame: FrameProc; path: ARRAY OF CHAR;
                   w, h: INTEGER; VAR hash: INTEGER): BOOLEAN;
VAR
    ok: BOOLEAN;
    back: MuBase.Color;
    pass, p, x, y, n: INTEGER;

BEGIN
    hash := HashSeed;
    ok := FALSE;

    MuRender.Init(w, h);
    ctx.textWidth  := MuRender.TextWidth;
    ctx.textHeight := MuRender.TextHeight;
    ctx.drawFrame  := MuRender.DrawFrame;

    (* A picture of a frame with no mouse in it has to be a picture of a frame
       with no motion in it, so the cursor is put at the origin in both halves
       of the library's own position pair.  Anything else would make the hash
       depend on where the real pointer happened to be. *)
    MuBase.MakeVec2(ctx.mousePos, 0, 0);
    MuBase.MakeVec2(ctx.lastMousePos, 0, 0);
    ctx.mouseDown := 0;
    ctx.mousePressed := 0;

    (* The clipboard, refreshed around the frame the way MuHost.BuildFrame does
       it.  A host hands the library what the platform holds before the frame
       and publishes what the frame asked for after it, and this is a host: a
       windowless run whose frame procedure copies or pastes would otherwise be
       the one host where the mirror never moved and the keys did nothing.

       It costs the picture nothing.  The context's clipboard is read by a text
       box and by nothing else, so a frame that pastes nothing draws the same
       bytes whether the mirror moved or not - and that is why the pictures this
       module is compared by are unaffected by the call. *)
    pass := 0;
    WHILE pass < RenderPasses DO
        Clipboard.Get(ctx.clip);
        frame(ctx);
        IF ctx.clipReq # Microui.ClipNone THEN
            Clipboard.Put(ctx.clip);
            ctx.clipReq := Microui.ClipNone
        END;
        INC(pass)
    END;

    (* The order is MuHost.BuildFrame's: the frame procedure fills the command
       list, and only then is that list replayed. *)
    MuBase.MakeColor(back, 32, 32, 32, 255);
    MuRender.Clear(back);
    MuRender.ProcessCommands(ctx);

    n := HashSeed;
    y := 0;
    WHILE y < h DO
        x := 0;
        WHILE x < w DO
            p := MuRender.GetPixel(x, y);
            MixPix(n, (p DIV 10000H) MOD 100H);
            MixPix(n, (p DIV 100H) MOD 100H);
            MixPix(n, p MOD 100H);
            INC(x)
        END;
        INC(y)
    END;
    hash := n;

    ok := Files.ReWrite(f, path);
    IF ok THEN
        pixN := 0;
        PpmHeader(w, h);
        y := 0;
        WHILE y < h DO
            x := 0;
            WHILE x < w DO
                p := MuRender.GetPixel(x, y);
                PpmByte((p DIV 10000H) MOD 100H);
                PpmByte((p DIV 100H) MOD 100H);
                PpmByte(p MOD 100H);
                INC(x)
            END;
            INC(y)
        END;
        Flush;
        ok := Files.Ok(f)
    END;
    Files.Close(f);
    MuRender.Done;

    RETURN ok
END Render;

END MuHeadless.
