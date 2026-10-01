(* Microui - an immediate-mode UI library.

   A port of rxi's microui 2.02 (https://github.com/rxi/microui, MIT licence)
   to Oberon-07.  This is the whole of microui.c: the context, the command
   list, the container and tree-node pools, the layout stack and every
   control.  Nothing here knows what a window is or how a pixel reaches the
   screen - text is measured through two callbacks and a frame is drawn
   through a third, and a separate renderer supplies them.

   What the port had to change
   ---------------------------
   Oberon-07 is a smaller language than C, and four things show:

   * A C pointer walking a byte list is an index here.  Commands live in a
     fixed array and a JUMP command holds the index to continue at, so
     mu_next_command becomes NextCommand, and a text command's string is an
     offset and a length into an arena instead of bytes appended after the
     command.
   * A procedure may not return a record, so mu_rect/mu_vec2/mu_color and
     every function returning one write through a leading VAR parameter.
   * RETURN is only legal as the last statement of a body, so every early
     return in the C is an IF with the remaining work in its ELSE arm.
   * There are no default arguments, so microui.h's convenience macros are
     procedures with their arguments already filled in: Button, Slider,
     Number, Header, BeginTreeNode, BeginWindow and BeginPanel.

   A C string with an explicit length - `(str, len)`, or a pointer into the
   middle of one - is an Oberon string with an offset and a length,
   `(str, ofs, len)`, where a negative len means "as far as the terminating
   zero".  That is how a substring reaches the text-width callback and how
   mu_draw_text's length argument is spelled.

   mu_begin and mu_end are BeginFrame and EndFrame: `Begin` and `End` on
   their own would be keywords.

   There are no assertions.  microui's `expect` calls abort(); a broken frame
   here pushes what it can and drops the rest, and the command list has one
   scratch slot past its end so that a frame overrunning it cannot walk off
   the array.
*)
MODULE Microui;

IMPORT SYSTEM, MuBase;


CONST
    (* sizes, from microui.h *)
    RootListSize*       = 32;
    ContainerStackSize* = 32;
    ClipStackSize*      = 32;
    IdStackSize*        = 32;
    LayoutStackSize*    = 16;
    ContainerPoolSize*  = 48;
    TreeNodePoolSize*   = 48;
    MaxWidths*          = 16;
    MaxFmt*             = 127;

    (* The C command list is one 256 KB pool of bytes with a text command's
       string stored inside it.  Here a command is a fixed record and the
       strings live in an arena of their own - the same arrangement with the
       two pieces named. *)
    CommandListSize = 4096;
    TextArenaSize   = 65536;

    (* The buffer the number formatters work in, and the one a context keeps
       for a number being edited.  It is a size and not LENGTH(buf): on an
       ARRAY OF CHAR, LENGTH is the length of the string in it, not how much
       it can hold - so a formatter that asked LENGTH would think a buffer
       holding "" was zero bytes long. *)
    FmtBufSize = MaxFmt;

    (* how much typed input a context accumulates in one frame *)
    InputTextSize = 32;

    (* what LayoutSetNext was told to do with the rectangle *)
    Relative = 1;
    Absolute = 2;

    (* The index meaning "there is none".  Command slots, container slots and
       stack entries are all indices.  A container holds NoIndex in head and
       tail until it has been filled in, and that is also how head tells a
       root container from a nested one - the test C spells as a non-NULL
       pointer. *)
    NoIndex* = -1;

    (* C's %.3g and %.2f, the two formats microui.h names. *)
    RealFmt   = "%.3g";
    SliderFmt = "%.2f";

    (* One drawn string is at most this long; longer ones are truncated. *)
    MaxDrawText = 512;

    (* What ContextDesc.clipReq says a frame did with the clipboard.  The
       library hands the text to the host through the context and lets the host
       make the system call, because a clipboard is a platform service and this
       module is not: a host refreshes `clip` before a frame and publishes it
       after one, which is the arrangement inputText already has for text
       arriving from the keyboard. *)
    ClipNone* = 0;
    ClipCopy* = 1;
    ClipCut*  = 2;

    (* Bytes a copy can take, and the most a paste can insert.  It is the
       ceiling Clipboard.MAXCLIP sets in lib/common/Clipboard.mod - one number
       in two modules, and the smaller of the two is what a round trip through
       a host can carry.  A field's own buffer is usually tighter still, and a
       paste longer than it is cut, not refused. *)
    ClipSize* = 256;

    (* The undo a text box keeps.  One stack for the library rather than one per
       field, because a caret is only ever in the field that has the focus and
       the buffer belongs to the caller - so what can be undone is always the
       focused field's own history and never two fields' at once.  A field that
       is given the focus elsewhere is forgotten with it; see the clear in
       TextboxRaw.

       UndoMax is the most a snapshot holds.  It is twice ClipSize, which is the
       library's ceiling on a copy or a paste, so an edit the framework itself
       allows is always one that can be taken back - and it is above the largest
       buffer any consumer here declares (the designer's path field, 260 bytes),
       so that field's undo is not quietly switched off either.  A field larger
       still loses its undo rather than being restored from a truncated copy;
       see PushUndo.  The cost of the number is UndoRec's own size, once, in a
       Context that is heap-allocated. *)
    UndoMax = 512;
    UndoLevels = 8;

    (* What a snapshot was taken for, which decides whether the next edit is the
       same run of them.  Typing joins typing and erasing joins erasing, so that
       Ctrl+Z after a word takes the word and not the letter, which is what
       every editor does; anything else - a paste, a cut - is a step of its own,
       and any move of the caret ends the run. *)
    UndoNone = 0;
    UndoType = 1;
    UndoErase = 2;


TYPE
    Context* = POINTER TO ContextDesc;

    (* A text buffer of a known size, for the number formatters.  A fixed
       array type rather than an open one, because only a fixed array can be
       asked how long it is. *)
    FmtBuf* = ARRAY FmtBufSize OF CHAR;

    (* The three callbacks.  Each takes the context, as in C, though our
       renderer has no use for it. *)
    TextWidthFn*  = PROCEDURE (ctx: Context; font: INTEGER;
                               str: ARRAY OF CHAR; ofs, len: INTEGER): INTEGER;
    TextHeightFn* = PROCEDURE (ctx: Context; font: INTEGER): INTEGER;
    DrawFrameFn*  = PROCEDURE (ctx: Context; rect: MuBase.Rect;
                               colorid: INTEGER);

    PoolItem* = RECORD
        id*: MuBase.Id;
        lastUpdate*: INTEGER
    END;

    (* One entry of the command list.  Which fields mean anything depends on
       typ; C's union is flattened out, which costs a few bytes per command
       and saves every access a cast. *)
    Command* = RECORD
        typ*:    INTEGER;
        dst*:    INTEGER;         (* CmdJump: where to continue *)
        rect*:   MuBase.Rect;     (* CmdClip, CmdRect, CmdIcon *)
        color*:  MuBase.Color;    (* CmdRect, CmdText, CmdIcon *)
        pos*:    MuBase.Vec2;     (* CmdText *)
        font*:   INTEGER;         (* CmdText *)
        id*:     INTEGER;         (* CmdIcon *)
        strOfs*: INTEGER;         (* CmdText: into the context's text arena *)
        strLen*: INTEGER
    END;

    Layout* = RECORD
        body*:     MuBase.Rect;
        next*:     MuBase.Rect;
        position*: MuBase.Vec2;
        size*:     MuBase.Vec2;
        max*:      MuBase.Vec2;
        widths*:   ARRAY MaxWidths OF INTEGER;
        items*, itemIndex*, nextRow*, nextType*, indent*: INTEGER
    END;
    LayoutPtr = POINTER TO Layout;

    Container* = RECORD
        head*, tail*: INTEGER;      (* command indices, NoIndex when unset *)
        rect*, body*: MuBase.Rect;
        contentSize*: MuBase.Vec2;
        scroll*:      MuBase.Vec2;
        zindex*:      INTEGER;
        open*:        BOOLEAN
    END;

    (* One state of the focused field, taken before an edit changes it.  The
       whole buffer is copied and not the difference: undoing a difference means
       every edit carrying its own inverse - an insertion recording where and how
       long, a deletion recording the text it took - and there are six places
       here that edit, several of which do two of those at once.  A copy is one
       loop and is right for all of them, and the six places then differ only in
       what they tell PushUndo they are doing. *)
    UndoRec = RECORD
        id*:     MuBase.Id;             (* the field it was taken from *)
        text*:   ARRAY UndoMax OF CHAR;
        len*:    INTEGER;
        caret*:  INTEGER;
        anchor*: INTEGER;
        kind*:   INTEGER                (* UndoType, UndoErase or UndoNone *)
    END;

    Style* = RECORD
        font*:          INTEGER;
        size*:          MuBase.Vec2;
        padding*:       INTEGER;
        spacing*:       INTEGER;
        indent*:        INTEGER;
        titleHeight*:   INTEGER;
        scrollbarSize*: INTEGER;
        thumbSize*:     INTEGER;
        colors*:        ARRAY MuBase.ColorMax OF MuBase.Color;
        (* What each of those fills is painted with besides the fill itself:
           the frame, the two halves of a 3D bevel, the ink, the shadow, the
           caret.  One Part per colour index, so the hovered and the focused
           fill of a control have Parts of their own and a theme may say that
           a button's hovered bevel is not its resting one.

           SeedParts derives all of these from `colors` and is what both
           SetDefaultStyle and a theme call, so the two can never disagree
           about what "the default frame" means.  See MuBase.Part. *)
        parts*:         ARRAY MuBase.PartMax OF MuBase.Part
    END;

    ContextDesc* = RECORD
        (* callbacks *)
        textWidth*:  TextWidthFn;
        textHeight*: TextHeightFn;
        drawFrame*:  DrawFrameFn;

        (* core state.  In C `style` points at a swappable style; here it is
           the style, there being nothing to swap it with. *)
        style*:        Style;
        hover*, focus*, lastId*: MuBase.Id;
        lastRect*:     MuBase.Rect;
        lastZindex*:   INTEGER;
        updatedFocus*: INTEGER;
        frame*:        INTEGER;
        hoverRoot*, nextHoverRoot*, scrollTarget*: INTEGER;

        numberEditBuf*: FmtBuf;
        numberEdit*:    MuBase.Id;

        (* the command list, and the strings its text commands point at *)
        commands*:  ARRAY CommandListSize + 1 OF Command;
        cmdIdx*:    INTEGER;
        textArena*: ARRAY TextArenaSize OF CHAR;
        textIdx*:   INTEGER;

        (* stacks *)
        rootIdx*:   INTEGER;
        rootItems*: ARRAY RootListSize OF INTEGER;
        contIdx*:   INTEGER;
        contItems*: ARRAY ContainerStackSize OF INTEGER;
        clipIdx*:   INTEGER;
        clipItems*: ARRAY ClipStackSize OF MuBase.Rect;
        idIdx*:     INTEGER;
        idItems*:   ARRAY IdStackSize OF MuBase.Id;
        layIdx*:    INTEGER;
        layItems*:  ARRAY LayoutStackSize OF Layout;

        (* retained state pools *)
        containerPool*: ARRAY ContainerPoolSize OF PoolItem;
        containers*:    ARRAY ContainerPoolSize OF Container;
        treenodePool*:  ARRAY TreeNodePoolSize OF PoolItem;

        (* input state *)
        mousePos*, lastMousePos*: MuBase.Vec2;
        mouseDelta*, scrollDelta*: MuBase.Vec2;
        mouseDown*, mousePressed*: INTEGER;
        keyDown*, keyPressed*:     INTEGER;
        inputText*: ARRAY InputTextSize OF CHAR;

        (* The clipboard, reaching the library and leaving it the same way the
           keyboard does.  `clip` is what a paste inserts and what a copy or a
           cut leaves behind; clipReq names what the frame did with it, so that
           the host can publish it.  Nothing here names a platform service: the
           library allocates nothing and calls nothing, and a host with no
           clipboard at all simply never refreshes `clip` and never reads
           clipReq, which leaves a field that copies into its own memory. *)
        clip*:    ARRAY ClipSize OF CHAR;
        clipReq*: INTEGER;

        (* The caret, and the run it is one end of, in the one field that has
           focus - the only place a caret can be, since the buffer belongs to
           the caller.  What is kept is a byte offset into whichever buffer
           editId names: it is put at the end of that buffer when the focus
           moves there, and re-clamped every frame, because a caller may
           rewrite its buffer under it - NumberTextbox does so on every frame
           it edits. *)
        editId*: MuBase.Id;
        caret*, anchor*: INTEGER;

        (* The field whose text the pointer is dragging, or 0.

           A drag has to keep extending after the pointer has left the box -
           that is what dragging means, and it is how a run longer than the box
           is selected at all - so a field remembers that it is the one being
           dragged instead of asking whether the pointer is still over it. *)
        dragId*: MuBase.Id;

        (* The focused field's history, oldest first, undoN being how many
           snapshots are on it.  See UndoRec and PushUndo. *)
        undo*:  ARRAY UndoLevels OF UndoRec;
        undoN*: INTEGER
    END;


VAR
    (* microui's unclipped_rect: a clip rectangle so large that intersecting
       with it changes nothing. *)
    unclippedRect: MuBase.Rect;

    (* A one-element array to hand to Row when the widths are to be left
       alone: the parameter is required, and is never read. *)
    unusedWidths: ARRAY 1 OF INTEGER;


(*============================================================================
   small helpers
   ==========================================================================*)

(* Has - is the option bit set?  `opt` is an INTEGER holding a set of
   MuBase.Opt* bits, the way C's `int opt` does, so it is turned into a SET to
   be tested.  This is what `opt & MU_OPT_X` becomes. *)
PROCEDURE Has* (opt, bit: INTEGER): BOOLEAN;
VAR
    res: BOOLEAN;

BEGIN
    res := (BITS(opt) * BITS(bit)) # {};

    RETURN res
END Has;


(* Trunc - a REAL to an INTEGER the way a C cast does it, towards zero. *)
PROCEDURE Trunc (x: REAL): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF x < 0.0 THEN res := -FLOOR(-x) ELSE res := FLOOR(x) END;

    RETURN res
END Trunc;


(*============================================================================
   numbers, as text
   ==========================================================================*)

PROCEDURE Put (VAR dst: FmtBuf; VAR pos: INTEGER; ch: CHAR);
BEGIN
    IF pos < FmtBufSize - 1 THEN dst[pos] := ch; INC(pos) END;
    dst[pos] := 0X
END Put;


(* EmitInt - `n` in decimal, at least `width` digits, zero-padded. *)
PROCEDURE EmitInt (VAR dst: FmtBuf; VAR pos: INTEGER; n, width: INTEGER);
VAR
    buf: ARRAY 24 OF CHAR;
    i, k: INTEGER;

BEGIN
    k := 0;
    IF n = 0 THEN
        buf[0] := "0"; k := 1
    ELSE
        WHILE (n > 0) & (k < 24) DO
            buf[k] := CHR(n MOD 10 + ORD("0"));
            n := n DIV 10;
            INC(k)
        END
    END;
    WHILE k < width DO buf[k] := "0"; INC(k) END;
    i := k;
    WHILE i > 0 DO
        DEC(i);
        Put(dst, pos, buf[i])
    END
END EmitInt;


PROCEDURE StripZeros (VAR s: FmtBuf);
VAR
    n: INTEGER;
    sawZero: BOOLEAN;

BEGIN
    n := 0;
    WHILE (n < FmtBufSize) & (s[n] # 0X) DO INC(n) END;
    sawZero := FALSE;
    WHILE (n > 0) & (s[n - 1] = "0") DO DEC(n); sawZero := TRUE END;
    IF sawZero & (n > 0) & (s[n - 1] = ".") THEN DEC(n) END;
    s[n] := 0X
END StripZeros;


PROCEDURE FmtExp (VAR dst: FmtBuf; x: REAL; prec: INTEGER);
VAR
    tmp: FmtBuf;
    pos, e, k: INTEGER;
    neg: BOOLEAN;
    v, m: REAL;

BEGIN
    neg := FALSE;
    v := x;
    IF v < 0.0 THEN neg := TRUE; v := -v END;
    e := 0;
    IF v > 0.0 THEN
        WHILE v >= 10.0 DO v := v / 10.0; INC(e) END;
        WHILE v < 1.0 DO v := v * 10.0; DEC(e) END
    END;
    m := v;
    pos := 0;
    tmp[0] := 0X;
    IF neg THEN Put(tmp, pos, "-") END;
    EmitInt(tmp, pos, FLOOR(m), 1);
    IF prec > 0 THEN
        Put(tmp, pos, ".");
        EmitInt(tmp, pos, Trunc((m - FLT(FLOOR(m))) * 10.0), 1)
    END;
    StripZeros(tmp);
    pos := 0;
    dst[0] := 0X;
    k := 0;
    WHILE (k < FmtBufSize) & (tmp[k] # 0X) DO
        Put(dst, pos, tmp[k]); INC(k)
    END;
    Put(dst, pos, "e");
    IF e < 0 THEN
        Put(dst, pos, "-"); e := -e
    ELSE
        Put(dst, pos, "+")
    END;
    EmitInt(dst, pos, e, 2)
END FmtExp;


PROCEDURE FmtFixed (VAR dst: FmtBuf; x: REAL; prec: INTEGER);
VAR
    pos, scale, i, ip, fp: INTEGER;
    neg: BOOLEAN;
    v: REAL;

BEGIN
    IF prec < 0 THEN prec := 0 END;
    IF prec > 9 THEN prec := 9 END;
    neg := FALSE;
    v := x;
    IF v < 0.0 THEN neg := TRUE; v := -v END;
    scale := 1;
    FOR i := 1 TO prec DO scale := scale * 10 END;

    pos := 0;
    dst[0] := 0X;
    IF v > 1.0E15 THEN
        (* too large to scale and round inside an INTEGER *)
        FmtExp(dst, x, prec)
    ELSE
        ip := FLOOR(v);
        fp := 0;
        IF prec > 0 THEN
            fp := Trunc((v - FLT(ip)) * FLT(scale) + 0.5);
            IF fp >= scale THEN INC(ip); fp := fp - scale END
        ELSIF v - FLT(ip) >= 0.5 THEN
            INC(ip)
        END;
        IF neg & ((ip # 0) OR (fp # 0)) THEN Put(dst, pos, "-") END;
        EmitInt(dst, pos, ip, 1);
        IF prec > 0 THEN
            Put(dst, pos, ".");
            EmitInt(dst, pos, fp, prec)
        END
    END
END FmtFixed;


(* FmtG - C's %g: `prec` significant digits, trailing zeros removed, and the
   exponent form once the exponent falls outside -4 .. prec. *)
PROCEDURE FmtG (VAR dst: FmtBuf; x: REAL; prec: INTEGER);
VAR
    tmp: FmtBuf;
    e, k: INTEGER;
    v: REAL;

BEGIN
    IF prec < 1 THEN prec := 1 END;
    v := x;
    IF v < 0.0 THEN v := -v END;
    IF v = 0.0 THEN
        k := 0;
        IF x < 0.0 THEN dst[0] := "-"; k := 1 END;
        dst[k] := "0"; dst[k + 1] := 0X
    ELSE
        e := 0;
        WHILE v >= 10.0 DO v := v / 10.0; INC(e) END;
        WHILE v < 1.0 DO v := v * 10.0; DEC(e) END;
        IF (e < -4) OR (e >= prec) THEN
            FmtExp(dst, x, prec - 1)
        ELSE
            FmtFixed(tmp, x, prec - 1 - e);
            StripZeros(tmp);
            k := 0;
            WHILE (k < FmtBufSize) & (tmp[k] # 0X) DO
                dst[k] := tmp[k]; INC(k)
            END;
            dst[k] := 0X
        END
    END
END FmtG;


(* FmtReal - the printf subset microui's format strings use: an optional
   precision and one of f, e or g.  Anything else is read as %g. *)
PROCEDURE FmtReal (VAR dst: FmtBuf; fmt: ARRAY OF CHAR; x: REAL);
VAR
    i, prec, conv: INTEGER;
    done: BOOLEAN;

BEGIN
    prec := 6; conv := ORD("g");
    i := 0; done := FALSE;
    WHILE (i < LENGTH(fmt)) & (fmt[i] # 0X) & ~done DO
        IF fmt[i] = "%" THEN
            INC(i);
            WHILE (i < LENGTH(fmt)) & (fmt[i] # 0X) &
                  ((fmt[i] = "-") OR (fmt[i] = "+") OR (fmt[i] = " ") OR
                   (fmt[i] = "0") OR (fmt[i] = "#") OR
                   ((fmt[i] >= "0") & (fmt[i] <= "9"))) DO
                INC(i)
            END;
            IF (i < LENGTH(fmt)) & (fmt[i] = ".") THEN
                INC(i); prec := 0;
                WHILE (i < LENGTH(fmt)) & (fmt[i] >= "0") & (fmt[i] <= "9") DO
                    prec := prec * 10 + (ORD(fmt[i]) - ORD("0")); INC(i)
                END
            END;
            IF i < LENGTH(fmt) THEN conv := ORD(fmt[i]) END;
            done := TRUE
        ELSE
            INC(i)
        END
    END;
    IF conv = ORD("f") THEN
        FmtFixed(dst, x, prec)
    ELSIF conv = ORD("e") THEN
        FmtExp(dst, x, prec)
    ELSE
        FmtG(dst, x, prec)
    END
END FmtReal;


(* ParseReal - C's strtod, as much of it as a number box can hold: a sign,
   digits, a point, digits and an exponent.  What it cannot read is worth
   zero, which is what microui does with strtod's answer anyway. *)
PROCEDURE ParseReal* (s: ARRAY OF CHAR; VAR v: REAL);
VAR
    i, n, ex, k: INTEGER;
    neg, exneg, any: BOOLEAN;
    scale: REAL;

BEGIN
    i := 0; n := LENGTH(s); v := 0.0;
    WHILE (i < n) & ((s[i] = " ") OR (s[i] = 09X)) DO INC(i) END;
    neg := FALSE;
    IF (i < n) & ((s[i] = "-") OR (s[i] = "+")) THEN
        neg := s[i] = "-"; INC(i)
    END;
    any := FALSE;
    WHILE (i < n) & (s[i] >= "0") & (s[i] <= "9") DO
        v := v * 10.0 + FLT(ORD(s[i]) - ORD("0")); INC(i); any := TRUE
    END;
    IF (i < n) & (s[i] = ".") THEN
        INC(i); scale := 0.1;
        WHILE (i < n) & (s[i] >= "0") & (s[i] <= "9") DO
            v := v + FLT(ORD(s[i]) - ORD("0")) * scale;
            scale := scale / 10.0; INC(i); any := TRUE
        END
    END;
    IF any & (i < n) & ((s[i] = "e") OR (s[i] = "E")) THEN
        INC(i); exneg := FALSE;
        IF (i < n) & ((s[i] = "-") OR (s[i] = "+")) THEN
            exneg := s[i] = "-"; INC(i)
        END;
        ex := 0;
        WHILE (i < n) & (s[i] >= "0") & (s[i] <= "9") DO
            ex := ex * 10 + (ORD(s[i]) - ORD("0")); INC(i)
        END;
        FOR k := 1 TO ex DO
            IF exneg THEN v := v / 10.0 ELSE v := v * 10.0 END
        END
    END;
    IF neg THEN v := -v END
END ParseReal;


(*============================================================================
   hashing and identifiers
   ==========================================================================*)

PROCEDURE HashStr (VAR h: MuBase.Id; s: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < LENGTH(s)) & (s[i] # 0X) DO
        MuBase.HashByte(h, ORD(s[i])); INC(i)
    END
END HashStr;


(* HashAdr - hash the address a control is identified by.  C hashes
   sizeof(pointer) bytes at the address of the variable that names the
   control, which comes to the same thing, and the port hashes the address
   itself: the caller passes SYSTEM.ADR of its own variable, so a slider stays
   the same slider from one frame to the next. *)
PROCEDURE HashAdr (VAR h: MuBase.Id; adr: INTEGER);
VAR
    i: INTEGER;
    x: INTEGER;

BEGIN
    x := adr;
    FOR i := 1 TO 8 DO
        MuBase.HashByte(h, x MOD 256);
        x := x DIV 256
    END
END HashAdr;


PROCEDURE IdFrom (ctx: Context; VAR h: MuBase.Id);
BEGIN
    IF ctx.idIdx > 0 THEN
        h := ctx.idItems[ctx.idIdx - 1]
    ELSE
        h := MuBase.HashInitial
    END
END IdFrom;


PROCEDURE GetIdStr* (ctx: Context; str: ARRAY OF CHAR): MuBase.Id;
VAR
    h: MuBase.Id;

BEGIN
    IdFrom(ctx, h);
    HashStr(h, str);
    ctx.lastId := h;

    RETURN h
END GetIdStr;


PROCEDURE GetIdAdr* (ctx: Context; adr: INTEGER): MuBase.Id;
VAR
    h: MuBase.Id;

BEGIN
    IdFrom(ctx, h);
    HashAdr(h, adr);
    ctx.lastId := h;

    RETURN h
END GetIdAdr;


PROCEDURE PushIdStr* (ctx: Context; str: ARRAY OF CHAR);
VAR
    id: MuBase.Id;

BEGIN
    id := GetIdStr(ctx, str);
    IF ctx.idIdx < IdStackSize THEN
        ctx.idItems[ctx.idIdx] := id;
        INC(ctx.idIdx)
    ELSE
        ctx.idItems[IdStackSize - 1] := id
    END
END PushIdStr;


PROCEDURE PushIdAdr* (ctx: Context; adr: INTEGER);
VAR
    id: MuBase.Id;

BEGIN
    id := GetIdAdr(ctx, adr);
    IF ctx.idIdx < IdStackSize THEN
        ctx.idItems[ctx.idIdx] := id;
        INC(ctx.idIdx)
    ELSE
        ctx.idItems[IdStackSize - 1] := id
    END
END PushIdAdr;


PROCEDURE PopId* (ctx: Context);
BEGIN
    IF ctx.idIdx > 0 THEN DEC(ctx.idIdx) END
END PopId;


(*============================================================================
   the pools of retained items
   ==========================================================================*)

PROCEDURE PoolInit (ctx: Context; VAR items: ARRAY OF PoolItem;
                    len: INTEGER; id: MuBase.Id): INTEGER;
VAR
    i, n, f: INTEGER;

BEGIN
    n := -1; f := ctx.frame;
    FOR i := 0 TO len - 1 DO
        IF items[i].lastUpdate < f THEN
            f := items[i].lastUpdate; n := i
        END
    END;
    (* C aborts when every slot was touched this frame, i.e. the pool is too
       small for the frame.  Reusing slot 0 loses one container and leaves the
       rest of the frame drawable. *)
    IF n < 0 THEN n := 0 END;
    items[n].id := id;
    items[n].lastUpdate := ctx.frame;

    RETURN n
END PoolInit;


PROCEDURE PoolGet (ctx: Context; VAR items: ARRAY OF PoolItem;
                   len: INTEGER; id: MuBase.Id): INTEGER;
VAR
    i, res: INTEGER;

BEGIN
    res := NoIndex;
    FOR i := 0 TO len - 1 DO
        IF (res = NoIndex) & (items[i].id = id) THEN res := i END
    END;

    RETURN res
END PoolGet;


PROCEDURE PoolUpdate (ctx: Context; VAR items: ARRAY OF PoolItem; idx: INTEGER);
BEGIN
    items[idx].lastUpdate := ctx.frame
END PoolUpdate;


(*============================================================================
   the command list
   ==========================================================================*)

(* PushCommand - one entry of the list.  When the list is full the command
   goes into the scratch slot past its end: that slot is never walked, so the
   write is harmless, and the frame loses one command instead of the array. *)
PROCEDURE PushCommand (ctx: Context; typ: INTEGER): INTEGER;
VAR
    i: INTEGER;

BEGIN
    IF ctx.cmdIdx < CommandListSize THEN
        i := ctx.cmdIdx;
        INC(ctx.cmdIdx)
    ELSE
        i := CommandListSize
    END;
    ctx.commands[i].typ := typ;
    ctx.commands[i].dst := NoIndex;

    RETURN i
END PushCommand;


(* NextCommand - walk the list in draw order, following the jump commands that
   thread the root containers together.  Pass cmd = NoIndex to start a frame;
   on return cmd is the index of the next command to draw, or cmdIdx once the
   list is finished, and the result says which. *)
PROCEDURE NextCommand* (ctx: Context; VAR cmd: INTEGER): BOOLEAN;
VAR
    i: INTEGER;
    found: BOOLEAN;

BEGIN
    IF cmd < 0 THEN i := 0 ELSE i := cmd + 1 END;
    found := FALSE;
    WHILE ~found & (i # ctx.cmdIdx) DO
        IF ctx.commands[i].typ = MuBase.CmdJump THEN
            i := ctx.commands[i].dst
        ELSE
            found := TRUE
        END
    END;
    cmd := i;

    RETURN found
END NextCommand;


(* StoreText - copy at most `len` characters of str, from `ofs`, into the text
   arena and record in the command at `idx` where they went.  A frame that
   fills the arena keeps what went in first and truncates what comes after. *)
PROCEDURE StoreText (ctx: Context; idx: INTEGER; str: ARRAY OF CHAR;
                     ofs, len: INTEGER);
VAR
    n, i: INTEGER;

BEGIN
    IF len < 0 THEN
        n := 0;
        WHILE (ofs + n < LENGTH(str)) & (str[ofs + n] # 0X) DO INC(n) END
    ELSE
        n := len
    END;
    IF ofs + n > LENGTH(str) THEN n := LENGTH(str) - ofs END;
    IF n > MaxDrawText THEN n := MaxDrawText END;
    IF ctx.textIdx + n > TextArenaSize - 1 THEN
        n := TextArenaSize - 1 - ctx.textIdx;
        IF n < 0 THEN n := 0 END
    END;
    ctx.commands[idx].strOfs := ctx.textIdx;
    i := 0;
    WHILE i < n DO
        ctx.textArena[ctx.textIdx] := str[ofs + i];
        INC(ctx.textIdx); INC(i)
    END;
    ctx.commands[idx].strLen := n;
    ctx.textArena[ctx.textIdx] := 0X
END StoreText;


(*============================================================================
   clipping, and drawing into the command list
   ==========================================================================*)

PROCEDURE GetClipRect* (ctx: Context; VAR r: MuBase.Rect);
BEGIN
    IF ctx.clipIdx > 0 THEN
        r := ctx.clipItems[ctx.clipIdx - 1]
    ELSE
        r := unclippedRect
    END
END GetClipRect;


PROCEDURE PushClipRect* (ctx: Context; rect: MuBase.Rect);
VAR
    last, r: MuBase.Rect;

BEGIN
    GetClipRect(ctx, last);
    MuBase.IntersectRects(r, rect, last);
    (* A frame nested past the stack's depth overwrites its topmost entry
       rather than walking off the array.  The pushes and pops still balance,
       so only the one lost level is wrong. *)
    IF ctx.clipIdx < ClipStackSize THEN
        ctx.clipItems[ctx.clipIdx] := r;
        INC(ctx.clipIdx)
    ELSE
        ctx.clipItems[ClipStackSize - 1] := r
    END
END PushClipRect;


PROCEDURE PopClipRect* (ctx: Context);
BEGIN
    IF ctx.clipIdx > 0 THEN DEC(ctx.clipIdx) END
END PopClipRect;


(* CheckClip - is r wholly inside the current clip rectangle (MuBase.ClipNone),
   wholly outside it (MuBase.ClipAll), or across its edge (MuBase.ClipPart)? *)
PROCEDURE CheckClip* (ctx: Context; r: MuBase.Rect): INTEGER;
VAR
    cr: MuBase.Rect;
    res: INTEGER;

BEGIN
    IF ctx.clipIdx = 0 THEN
        res := MuBase.ClipAll
    ELSE
        GetClipRect(ctx, cr);
        IF (r.x > cr.x + cr.w) OR (r.x + r.w < cr.x) OR
           (r.y > cr.y + cr.h) OR (r.y + r.h < cr.y) THEN
            res := MuBase.ClipAll
        ELSIF (r.x >= cr.x) & (r.x + r.w <= cr.x + cr.w) &
              (r.y >= cr.y) & (r.y + r.h <= cr.y + cr.h) THEN
            res := MuBase.ClipNone
        ELSE
            res := MuBase.ClipPart
        END
    END;

    RETURN res
END CheckClip;


PROCEDURE SetClip* (ctx: Context; rect: MuBase.Rect);
VAR
    i: INTEGER;

BEGIN
    i := PushCommand(ctx, MuBase.CmdClip);
    ctx.commands[i].rect := rect
END SetClip;


PROCEDURE DrawRect* (ctx: Context; rect: MuBase.Rect; color: MuBase.Color);
VAR
    cr, r: MuBase.Rect;
    i: INTEGER;

BEGIN
    GetClipRect(ctx, cr);
    MuBase.IntersectRects(r, rect, cr);
    IF (r.w > 0) & (r.h > 0) THEN
        i := PushCommand(ctx, MuBase.CmdRect);
        ctx.commands[i].rect := r;
        ctx.commands[i].color := color
    END
END DrawRect;


PROCEDURE DrawBox* (ctx: Context; rect: MuBase.Rect; color: MuBase.Color);
VAR
    r: MuBase.Rect;

BEGIN
    MuBase.MakeRect(r, rect.x + 1, rect.y, rect.w - 2, 1);
    DrawRect(ctx, r, color);
    MuBase.MakeRect(r, rect.x + 1, rect.y + rect.h - 1, rect.w - 2, 1);
    DrawRect(ctx, r, color);
    MuBase.MakeRect(r, rect.x, rect.y, 1, rect.h);
    DrawRect(ctx, r, color);
    MuBase.MakeRect(r, rect.x + rect.w - 1, rect.y, 1, rect.h);
    DrawRect(ctx, r, color)
END DrawBox;


PROCEDURE DrawText* (ctx: Context; font: INTEGER; str: ARRAY OF CHAR;
                     ofs, len: INTEGER; pos: MuBase.Vec2; color: MuBase.Color);
VAR
    rect: MuBase.Rect;
    clipped: INTEGER;
    i, n: INTEGER;

BEGIN
    IF len < 0 THEN
        n := 0;
        WHILE (ofs + n < LENGTH(str)) & (str[ofs + n] # 0X) DO INC(n) END
    ELSE
        n := len
    END;
    MuBase.MakeRect(rect, pos.x, pos.y,
                    ctx.textWidth(ctx, font, str, ofs, n),
                    ctx.textHeight(ctx, font));
    clipped := CheckClip(ctx, rect);
    IF clipped # MuBase.ClipAll THEN
        IF clipped = MuBase.ClipPart THEN
            GetClipRect(ctx, rect);
            SetClip(ctx, rect)
        END;
        (* rect is not read again below, so it may hold the clip rectangle *)
        i := PushCommand(ctx, MuBase.CmdText);
        StoreText(ctx, i, str, ofs, n);
        ctx.commands[i].pos := pos;
        ctx.commands[i].color := color;
        ctx.commands[i].font := font;
        IF clipped # MuBase.ClipNone THEN SetClip(ctx, unclippedRect) END
    END
END DrawText;


PROCEDURE DrawIcon* (ctx: Context; id: INTEGER; rect: MuBase.Rect;
                     color: MuBase.Color);
VAR
    clipped: INTEGER;
    cr: MuBase.Rect;
    i: INTEGER;

BEGIN
    clipped := CheckClip(ctx, rect);
    IF clipped # MuBase.ClipAll THEN
        IF clipped = MuBase.ClipPart THEN
            GetClipRect(ctx, cr);
            SetClip(ctx, cr)
        END;
        i := PushCommand(ctx, MuBase.CmdIcon);
        ctx.commands[i].id := id;
        ctx.commands[i].rect := rect;
        ctx.commands[i].color := color;
        IF clipped # MuBase.ClipNone THEN SetClip(ctx, unclippedRect) END
    END
END DrawIcon;


(*============================================================================
   the context
   ==========================================================================*)

(* SeedParts - derive every Part from the fills.

   This is the one place that says what an unthemed control is painted with,
   and both SetDefaultStyle and MuTheme go through it, so a theme that names
   three colours and a theme that names all of them agree about the rest.
   Exported for that second caller: a theme lays its fills over the style and
   then asks for this, rather than deriving the nuances itself and eventually
   disagreeing with the library about what a default frame is.

   The frame is microui's own rule, carried over unchanged: every fill is
   framed in ColorBorder, except the ones microui drew flat - a title bar and
   both halves of a scrollbar - which are framed in nothing.  Everything a
   Part can add beyond a frame - a bevel, a drop shadow, a caret - starts
   transparent, so a program that names no Part at all draws exactly the
   pixels it drew before Parts existed.  The ink is the program's text
   colour, with the two exceptions that are inks rather than fills: a title
   bar's caption, which is ColorTitleText, and a selection, which is drawn in
   the colour of the field it inverted. *)
PROCEDURE SeedParts* (VAR s: Style);
VAR
    i: INTEGER;

BEGIN
    FOR i := 0 TO MuBase.PartMax - 1 DO
        MuBase.MakeColor(s.parts[i].border, 0, 0, 0, 0);
        MuBase.MakeColor(s.parts[i].light, 0, 0, 0, 0);
        MuBase.MakeColor(s.parts[i].dark, 0, 0, 0, 0);
        s.parts[i].text := s.colors[MuBase.ColorText];
        MuBase.MakeColor(s.parts[i].shadow, 0, 0, 0, 0);
        MuBase.MakeColor(s.parts[i].caret, 0, 0, 0, 0)
    END;

    FOR i := 0 TO MuBase.ColorScrollThumb DO
        s.parts[i].border := s.colors[MuBase.ColorBorder]
    END;
    s.parts[MuBase.ColorText].border.a := 0;
    s.parts[MuBase.ColorBorder].border.a := 0;
    s.parts[MuBase.ColorTitleBG].border.a := 0;
    s.parts[MuBase.ColorScrollBase].border.a := 0;
    s.parts[MuBase.ColorScrollThumb].border.a := 0;

    (* the title bar and everything on it is captioned in ColorTitleText *)
    s.parts[MuBase.ColorTitleBG].text := s.colors[MuBase.ColorTitleText];
    s.parts[MuBase.ColorTitleBtn].text := s.colors[MuBase.ColorTitleText];
    s.parts[MuBase.ColorTitleBtnHover].text := s.colors[MuBase.ColorTitleText];
    s.parts[MuBase.ColorTitleBtnFocus].text := s.colors[MuBase.ColorTitleText];

    s.parts[MuBase.ColorSelect].text := s.colors[MuBase.ColorBase]
END SeedParts;


PROCEDURE SetDefaultStyle (VAR s: Style);
VAR
    i: INTEGER;

BEGIN
    s.font := 0;
    s.size.x := 68; s.size.y := 10;
    s.padding := 5;
    s.spacing := 4;
    s.indent := 24;
    s.titleHeight := 24;
    s.scrollbarSize := 12;
    s.thumbSize := 8;
    FOR i := 0 TO MuBase.ColorMax - 1 DO
        MuBase.MakeColor(s.colors[i], 0, 0, 0, 0)
    END;
    MuBase.MakeColor(s.colors[0], 230, 230, 230, 255);  (* text *)
    MuBase.MakeColor(s.colors[1], 25, 25, 25, 255);     (* border *)
    MuBase.MakeColor(s.colors[2], 50, 50, 50, 255);     (* window bg *)
    MuBase.MakeColor(s.colors[3], 25, 25, 25, 255);     (* title bg *)
    MuBase.MakeColor(s.colors[4], 240, 240, 240, 255);  (* title text *)
    MuBase.MakeColor(s.colors[5], 0, 0, 0, 0);          (* panel bg *)
    MuBase.MakeColor(s.colors[6], 75, 75, 75, 255);     (* button *)
    MuBase.MakeColor(s.colors[7], 95, 95, 95, 255);     (* button hover *)
    MuBase.MakeColor(s.colors[8], 115, 115, 115, 255);  (* button focus *)
    MuBase.MakeColor(s.colors[9], 30, 30, 30, 255);     (* base *)
    MuBase.MakeColor(s.colors[10], 35, 35, 35, 255);    (* base hover *)
    MuBase.MakeColor(s.colors[11], 40, 40, 40, 255);    (* base focus *)
    MuBase.MakeColor(s.colors[12], 43, 43, 43, 255);    (* scroll base *)
    MuBase.MakeColor(s.colors[13], 30, 30, 30, 255);    (* scroll thumb *)

    (* The eight that microui has no slot for are transparent by default -
       see MuBase.  Two of them are not: a popup's body is what a popup was
       already drawn in, and a selection is the inverse of the text on it, so
       both have a colour before any theme names one. *)
    MuBase.MakeColor(s.colors[MuBase.ColorTitleBtn], 0, 0, 0, 0);
    MuBase.MakeColor(s.colors[MuBase.ColorTitleBtnHover], 0, 0, 0, 0);
    MuBase.MakeColor(s.colors[MuBase.ColorTitleBtnFocus], 0, 0, 0, 0);
    MuBase.MakeColor(s.colors[MuBase.ColorGrip], 0, 0, 0, 0);
    MuBase.MakeColor(s.colors[MuBase.ColorSelect], 230, 230, 230, 255);
    MuBase.MakeColor(s.colors[MuBase.ColorScrollThumbHover], 0, 0, 0, 0);
    MuBase.MakeColor(s.colors[MuBase.ColorScrollThumbFocus], 0, 0, 0, 0);
    MuBase.MakeColor(s.colors[MuBase.ColorPopupBG], 50, 50, 50, 255);

    SeedParts(s)
END SetDefaultStyle;


(* The default draw_frame: what a control calls to be drawn.

   mu_draw_control_frame's four rectangles are still here, and they are still
   what an unthemed program gets: the fill, and one pixel of ColorBorder
   around it unless the frame is one of the three microui draws flat.  What
   is new is that the frame is asked of the fill's Part instead of being the
   same colour for every control in the program, and that a Part may ask for
   three more rectangles - a drop shadow under the fill, and a two-tone bevel
   around it.

   The order is fixed, because the later rectangles sit outside the earlier
   ones and each has to leave the last one visible:

       shadow   at rect + (1, 1), drawn first, so the fill covers all of it
                but the strip along its right and bottom
       fill     at rect
       bevel    at rect grown by 1: light on the top and left, dark on the
                bottom and right
       border   at rect grown by 1 when there is no bevel, and by 2 when
                there is, so that the bevel is not painted over

   A Part is free to name any of the four and not the others; each is skipped
   when its alpha is zero.  See MuBase.Part. *)
PROCEDURE DefaultFrame* (ctx: Context; rect: MuBase.Rect; colorid: INTEGER);
VAR
    p: MuBase.Part;
    e, r: MuBase.Rect;

BEGIN
    IF (colorid < 0) OR (colorid >= MuBase.ColorMax) THEN
        (* not a colour: nothing to draw, and nothing to complain about *)
    ELSE
        p := ctx.style.parts[colorid];

        IF p.shadow.a # 0 THEN
            r := rect;
            r.x := r.x + 1;
            r.y := r.y + 1;
            DrawRect(ctx, r, p.shadow)
        END;

        DrawRect(ctx, rect, ctx.style.colors[colorid]);

        IF (p.light.a # 0) OR (p.dark.a # 0) THEN
            MuBase.ExpandRect(e, rect, 1);
            IF p.light.a # 0 THEN
                MuBase.MakeRect(r, e.x, e.y, e.w, 1);
                DrawRect(ctx, r, p.light);
                MuBase.MakeRect(r, e.x, e.y, 1, e.h);
                DrawRect(ctx, r, p.light)
            END;
            IF p.dark.a # 0 THEN
                MuBase.MakeRect(r, e.x, e.y + e.h - 1, e.w, 1);
                DrawRect(ctx, r, p.dark);
                MuBase.MakeRect(r, e.x + e.w - 1, e.y, 1, e.h);
                DrawRect(ctx, r, p.dark)
            END;
            IF p.border.a # 0 THEN
                MuBase.ExpandRect(e, rect, 2);
                DrawBox(ctx, e, p.border)
            END
        ELSIF p.border.a # 0 THEN
            MuBase.ExpandRect(e, rect, 1);
            DrawBox(ctx, e, p.border)
        END
    END
END DefaultFrame;


(* Ink - the colour anything drawn ON the fill colorid is drawn in: a
   caption, a tick, an icon, a field's own text.  A Part that names no text
   colour has the program's, which is what every one of them starts as. *)
PROCEDURE Ink (ctx: Context; colorid: INTEGER; VAR c: MuBase.Color);
BEGIN
    IF (colorid >= 0) & (colorid < MuBase.ColorMax) &
       (ctx.style.parts[colorid].text.a # 0) THEN
        c := ctx.style.parts[colorid].text
    ELSE
        c := ctx.style.colors[colorid]
    END
END Ink;


(* Shade - the colour index to paint a control's state in.  A theme names a
   hovered or focused fill only when the system it imitates has one; an
   unfilled slot means "this control does not change", not "draw nothing",
   so the resting index stands in for it. *)
PROCEDURE Shade (ctx: Context; id, fallback: INTEGER): INTEGER;
VAR
    r: INTEGER;

BEGIN
    r := fallback;
    IF ctx.style.colors[id].a # 0 THEN r := id END;
    RETURN r
END Shade;


(* Visible - whether a Part would paint anything at all.  The two things a
   theme turns on rather than recolours - a title bar's close box and a
   window's resize grip - are drawn only when it answers TRUE, which is how
   they are invisible on a program that names no theme. *)
PROCEDURE Visible (ctx: Context; colorid: INTEGER): BOOLEAN;
VAR
    p: MuBase.Part;
    r: BOOLEAN;

BEGIN
    p := ctx.style.parts[colorid];
    r := (ctx.style.colors[colorid].a # 0) OR (p.border.a # 0) OR
         (p.light.a # 0) OR (p.dark.a # 0) OR (p.shadow.a # 0);
    RETURN r
END Visible;


PROCEDURE Init* (ctx: Context);
VAR
    i: INTEGER;

BEGIN
    (* C memsets the context.  New does not promise zeroed memory, so every
       field that could be read before it is written is set here. *)
    ctx.textWidth := NIL;
    ctx.textHeight := NIL;
    ctx.drawFrame := DefaultFrame;
    SetDefaultStyle(ctx.style);
    ctx.hover := 0; ctx.focus := 0; ctx.lastId := 0;
    MuBase.MakeRect(ctx.lastRect, 0, 0, 0, 0);
    ctx.lastZindex := 0;
    ctx.updatedFocus := 0;
    ctx.frame := 0;
    ctx.hoverRoot := NoIndex; ctx.nextHoverRoot := NoIndex;
    ctx.scrollTarget := NoIndex;
    ctx.numberEditBuf[0] := 0X;
    ctx.numberEdit := 0;
    ctx.cmdIdx := 0;
    ctx.textIdx := 0;
    ctx.rootIdx := 0; ctx.contIdx := 0;
    ctx.clipIdx := 0; ctx.idIdx := 0; ctx.layIdx := 0;
    FOR i := 0 TO CommandListSize DO ctx.commands[i].typ := 0 END;
    FOR i := 0 TO ContainerPoolSize - 1 DO
        ctx.containerPool[i].id := 0;
        ctx.containerPool[i].lastUpdate := 0;
        ctx.containers[i].head := NoIndex;
        ctx.containers[i].tail := NoIndex;
        MuBase.MakeRect(ctx.containers[i].rect, 0, 0, 0, 0);
        MuBase.MakeRect(ctx.containers[i].body, 0, 0, 0, 0);
        MuBase.MakeVec2(ctx.containers[i].contentSize, 0, 0);
        MuBase.MakeVec2(ctx.containers[i].scroll, 0, 0);
        ctx.containers[i].zindex := 0;
        ctx.containers[i].open := FALSE
    END;
    FOR i := 0 TO TreeNodePoolSize - 1 DO
        ctx.treenodePool[i].id := 0;
        ctx.treenodePool[i].lastUpdate := 0
    END;
    MuBase.MakeVec2(ctx.mousePos, 0, 0);
    MuBase.MakeVec2(ctx.lastMousePos, 0, 0);
    MuBase.MakeVec2(ctx.mouseDelta, 0, 0);
    MuBase.MakeVec2(ctx.scrollDelta, 0, 0);
    ctx.mouseDown := 0; ctx.mousePressed := 0;
    ctx.keyDown := 0; ctx.keyPressed := 0;
    ctx.inputText[0] := 0X;
    (* The editing state.  None of this is a promise New makes, and each one is
       read before it is written: a host reads clipReq after the very first
       frame to decide whether to publish the clipboard, and a stray value
       there would put whatever happens to be in `clip` on the machine's
       clipboard - so the five are set here rather than left to the heap. *)
    ctx.clip[0] := 0X;
    ctx.clipReq := ClipNone;
    ctx.editId := 0;
    ctx.caret := 0; ctx.anchor := 0;
    ctx.dragId := 0;
    ctx.undoN := 0
END Init;


PROCEDURE BeginFrame* (ctx: Context);
BEGIN
    ctx.cmdIdx := 0;
    ctx.textIdx := 0;
    ctx.rootIdx := 0;
    ctx.scrollTarget := NoIndex;
    ctx.hoverRoot := ctx.nextHoverRoot;
    ctx.nextHoverRoot := NoIndex;
    ctx.mouseDelta.x := ctx.mousePos.x - ctx.lastMousePos.x;
    ctx.mouseDelta.y := ctx.mousePos.y - ctx.lastMousePos.y;
    INC(ctx.frame)
END BeginFrame;


PROCEDURE SetFocus* (ctx: Context; id: MuBase.Id);
BEGIN
    ctx.focus := id;
    ctx.updatedFocus := 1
END SetFocus;


PROCEDURE BringToFront* (ctx: Context; cntIdx: INTEGER);
BEGIN
    INC(ctx.lastZindex);
    ctx.containers[cntIdx].zindex := ctx.lastZindex
END BringToFront;


(* The root containers are drawn in z order, so they are sorted by zindex
   before the jump commands are set.  C calls qsort; an insertion sort suits
   32 entries and needs no comparison callback. *)
PROCEDURE SortRoots (ctx: Context);
VAR
    i, j, key: INTEGER;

BEGIN
    FOR i := 1 TO ctx.rootIdx - 1 DO
        key := ctx.rootItems[i];
        j := i - 1;
        WHILE (j >= 0) &
              (ctx.containers[ctx.rootItems[j]].zindex >
               ctx.containers[key].zindex) DO
            ctx.rootItems[j + 1] := ctx.rootItems[j];
            DEC(j)
        END;
        ctx.rootItems[j + 1] := key
    END
END SortRoots;


PROCEDURE EndFrame* (ctx: Context);
VAR
    i, n, cntIdx, prevIdx: INTEGER;

BEGIN
    (* handle scroll input *)
    IF ctx.scrollTarget # NoIndex THEN
        ctx.containers[ctx.scrollTarget].scroll.x :=
            ctx.containers[ctx.scrollTarget].scroll.x + ctx.scrollDelta.x;
        ctx.containers[ctx.scrollTarget].scroll.y :=
            ctx.containers[ctx.scrollTarget].scroll.y + ctx.scrollDelta.y
    END;

    (* unset focus if the focused control was not touched this frame *)
    IF ctx.updatedFocus = 0 THEN ctx.focus := 0 END;
    ctx.updatedFocus := 0;

    (* bring the hover root to front if the mouse was pressed *)
    IF (ctx.mousePressed # 0) & (ctx.nextHoverRoot # NoIndex) &
       (ctx.containers[ctx.nextHoverRoot].zindex < ctx.lastZindex) &
       (ctx.containers[ctx.nextHoverRoot].zindex >= 0) THEN
        BringToFront(ctx, ctx.nextHoverRoot)
    END;

    (* reset input state *)
    ctx.keyPressed := 0;
    ctx.inputText[0] := 0X;
    ctx.mousePressed := 0;
    MuBase.MakeVec2(ctx.scrollDelta, 0, 0);
    ctx.lastMousePos := ctx.mousePos;

    SortRoots(ctx);

    (* Set the root containers' jump commands.  The first command of the list
       belongs to whichever container was created first, and after the sort it
       is repurposed as the entry point leading to the lowest-z root; each
       container's tail then leads to the next, and the last tail leads to the
       end of the list. *)
    n := ctx.rootIdx;
    FOR i := 0 TO n - 1 DO
        cntIdx := ctx.rootItems[i];
        IF i = 0 THEN
            ctx.commands[0].dst := ctx.containers[cntIdx].head + 1
        ELSE
            prevIdx := ctx.rootItems[i - 1];
            ctx.commands[ctx.containers[prevIdx].tail].dst :=
                ctx.containers[cntIdx].head + 1
        END;
        IF i = n - 1 THEN
            ctx.commands[ctx.containers[cntIdx].tail].dst := ctx.cmdIdx
        END
    END
END EndFrame;


(*============================================================================
   input
   ==========================================================================*)

PROCEDURE InputMouseMove* (ctx: Context; x, y: INTEGER);
BEGIN
    MuBase.MakeVec2(ctx.mousePos, x, y)
END InputMouseMove;


PROCEDURE InputMouseDown* (ctx: Context; x, y, btn: INTEGER);
BEGIN
    InputMouseMove(ctx, x, y);
    (* set union, spelled the way the matching Up call spells the
       difference.  Adding the integers instead carries into the next bit:
       two MouseLeft presses, or the auto-repeat of a held key, set a bit
       nobody pressed. *)
    ctx.mouseDown := ORD(BITS(ctx.mouseDown) + BITS(btn));
    ctx.mousePressed := ORD(BITS(ctx.mousePressed) + BITS(btn))
END InputMouseDown;


PROCEDURE InputMouseUp* (ctx: Context; x, y, btn: INTEGER);
BEGIN
    InputMouseMove(ctx, x, y);
    ctx.mouseDown := ORD(BITS(ctx.mouseDown) - BITS(btn))
END InputMouseUp;


PROCEDURE InputScroll* (ctx: Context; x, y: INTEGER);
BEGIN
    ctx.scrollDelta.x := ctx.scrollDelta.x + x;
    ctx.scrollDelta.y := ctx.scrollDelta.y + y
END InputScroll;


PROCEDURE InputKeyDown* (ctx: Context; key: INTEGER);
BEGIN
    ctx.keyPressed := ORD(BITS(ctx.keyPressed) + BITS(key));
    ctx.keyDown := ORD(BITS(ctx.keyDown) + BITS(key))
END InputKeyDown;


PROCEDURE InputKeyUp* (ctx: Context; key: INTEGER);
BEGIN
    ctx.keyDown := ORD(BITS(ctx.keyDown) - BITS(key))
END InputKeyUp;


PROCEDURE InputText* (ctx: Context; text: ARRAY OF CHAR);
VAR
    len, i: INTEGER;

BEGIN
    len := 0;
    WHILE (len < InputTextSize - 1) & (ctx.inputText[len] # 0X) DO
        INC(len)
    END;
    i := 0;
    WHILE (len < InputTextSize - 1) & (i < LENGTH(text)) &
          (text[i] # 0X) DO
        ctx.inputText[len] := text[i];
        INC(len); INC(i)
    END;
    (* Text is UTF-8, so a character is one to four bytes and the buffer can
       fill in the middle of one.  A lead byte at the end is a character that
       did not arrive whole: drop it rather than keep half of it. *)
    WHILE (len > 0) & (ORD(ctx.inputText[len - 1]) >= 0C0H) DO
        DEC(len)
    END;
    ctx.inputText[len] := 0X
END InputText;


(*============================================================================
   layout
   ==========================================================================*)

PROCEDURE CurLayout (ctx: Context): LayoutPtr;
VAR
    a: INTEGER;

BEGIN
    a := SYSTEM.ADR(ctx.layItems[ctx.layIdx - 1]);

    RETURN SYSTEM.VAL(LayoutPtr, a)
END CurLayout;


PROCEDURE Row (ctx: Context; items, height: INTEGER; useWidths: BOOLEAN;
               VAR widths: ARRAY OF INTEGER);
VAR
    lay: LayoutPtr;
    i: INTEGER;

BEGIN
    lay := CurLayout(ctx);
    IF useWidths THEN
        (* `widths` holds one entry per item, as in C *)
        i := 0;
        WHILE (i < items) & (i < MaxWidths) DO
            lay.widths[i] := widths[i]; INC(i)
        END
    END;
    lay.items := items;
    lay.position.x := lay.indent;
    lay.position.y := lay.nextRow;
    lay.size.y := height;
    lay.itemIndex := 0
END Row;


PROCEDURE LayoutRow* (ctx: Context; items, height: INTEGER;
                      VAR widths: ARRAY OF INTEGER);
BEGIN
    Row(ctx, items, height, TRUE, widths)
END LayoutRow;


(* LayoutRowKeep - start another row of the same shape, keeping the widths the
   current row was given.  This is what C does by passing NULL. *)
PROCEDURE LayoutRowKeep (ctx: Context; items, height: INTEGER);
BEGIN
    Row(ctx, items, height, FALSE, unusedWidths)
END LayoutRowKeep;


(* LayoutRow1 - the single-item row microui asks for constantly. *)
PROCEDURE LayoutRow1 (ctx: Context; w, height: INTEGER);
VAR
    a: ARRAY 1 OF INTEGER;

BEGIN
    a[0] := w;
    Row(ctx, 1, height, TRUE, a)
END LayoutRow1;


PROCEDURE PushLayout (ctx: Context; body: MuBase.Rect; scroll: MuBase.Vec2);
VAR
    lay: Layout;

BEGIN
    lay.body.x := body.x - scroll.x;
    lay.body.y := body.y - scroll.y;
    lay.body.w := body.w;
    lay.body.h := body.h;
    MuBase.MakeVec2(lay.max, -1000000H, -1000000H);
    MuBase.MakeVec2(lay.position, 0, 0);
    MuBase.MakeVec2(lay.size, 0, 0);
    MuBase.MakeRect(lay.next, 0, 0, 0, 0);
    lay.items := 0; lay.itemIndex := 0; lay.nextRow := 0;
    lay.nextType := 0; lay.indent := 0;
    (* A full stack overwrites the last layout instead of growing, where C's
       push() asserts and aborts.  The difference is the one to know about: an
       unbalanced begin/end pair does not stop a program here, it lays the rest
       of the frame out wrong.  C also asserts at the top of mu_end that all
       four stack depths are back to zero; there is nothing to hang that on
       here, so a change to a control wants ctx.layIdx watched from EndFrame. *)
    IF ctx.layIdx < LayoutStackSize THEN
        ctx.layItems[ctx.layIdx] := lay;
        INC(ctx.layIdx)
    ELSE
        ctx.layItems[LayoutStackSize - 1] := lay
    END;
    LayoutRow1(ctx, 0, 0)
END PushLayout;


PROCEDURE LayoutNext* (ctx: Context; VAR res: MuBase.Rect);
VAR
    lay: LayoutPtr;
    absolute: BOOLEAN;

BEGIN
    lay := CurLayout(ctx);
    absolute := FALSE;
    IF lay.nextType # 0 THEN
        res := lay.next;
        absolute := lay.nextType = Absolute;
        lay.nextType := 0
    ELSE
        (* the row is full: begin it again with the same shape *)
        IF lay.itemIndex = lay.items THEN
            LayoutRowKeep(ctx, lay.items, lay.size.y);
            lay := CurLayout(ctx)
        END;
        res.x := lay.position.x;
        res.y := lay.position.y;
        IF lay.items > 0 THEN
            res.w := lay.widths[lay.itemIndex]
        ELSE
            res.w := lay.size.x
        END;
        res.h := lay.size.y;
        IF res.w = 0 THEN res.w := ctx.style.size.x + ctx.style.padding * 2 END;
        IF res.h = 0 THEN res.h := ctx.style.size.y + ctx.style.padding * 2 END;
        IF res.w < 0 THEN res.w := res.w + lay.body.w - res.x + 1 END;
        IF res.h < 0 THEN res.h := res.h + lay.body.h - res.y + 1 END;
        INC(lay.itemIndex)
    END;

    IF absolute THEN
        (* a rectangle placed by LayoutSetNext with relative = FALSE is used
           as given: no advance, no body offset *)
        ctx.lastRect := res
    ELSE
        lay.position.x := lay.position.x + res.w + ctx.style.spacing;
        lay.nextRow := MuBase.Max(lay.nextRow, res.y + res.h + ctx.style.spacing);
        res.x := res.x + lay.body.x;
        res.y := res.y + lay.body.y;
        lay.max.x := MuBase.Max(lay.max.x, res.x + res.w);
        lay.max.y := MuBase.Max(lay.max.y, res.y + res.h);
        ctx.lastRect := res
    END
END LayoutNext;


PROCEDURE LayoutBeginColumn* (ctx: Context);
VAR
    r: MuBase.Rect;
    z: MuBase.Vec2;

BEGIN
    LayoutNext(ctx, r);
    MuBase.MakeVec2(z, 0, 0);
    PushLayout(ctx, r, z)
END LayoutBeginColumn;


PROCEDURE LayoutEndColumn* (ctx: Context);
VAR
    a, b: LayoutPtr;

BEGIN
    b := CurLayout(ctx);
    DEC(ctx.layIdx);
    a := CurLayout(ctx);
    a.position.x := MuBase.Max(a.position.x, b.position.x + b.body.x - a.body.x);
    a.nextRow := MuBase.Max(a.nextRow, b.nextRow + b.body.y - a.body.y);
    a.max.x := MuBase.Max(a.max.x, b.max.x);
    a.max.y := MuBase.Max(a.max.y, b.max.y)
END LayoutEndColumn;


PROCEDURE LayoutWidth* (ctx: Context; width: INTEGER);
VAR
    lay: LayoutPtr;

BEGIN
    lay := CurLayout(ctx);
    lay.size.x := width
END LayoutWidth;


PROCEDURE LayoutHeight* (ctx: Context; height: INTEGER);
VAR
    lay: LayoutPtr;

BEGIN
    lay := CurLayout(ctx);
    lay.size.y := height
END LayoutHeight;


PROCEDURE LayoutSetNext* (ctx: Context; r: MuBase.Rect; relative: BOOLEAN);
VAR
    lay: LayoutPtr;

BEGIN
    lay := CurLayout(ctx);
    lay.next := r;
    IF relative THEN lay.nextType := Relative ELSE lay.nextType := Absolute END
END LayoutSetNext;


(*============================================================================
   controls
   ==========================================================================*)

PROCEDURE CurrentContainer* (ctx: Context): INTEGER;
BEGIN
    RETURN ctx.contItems[ctx.contIdx - 1]
END CurrentContainer;


(* InHoverRoot - are we drawing inside the container the mouse is over?
   Walking up the stack stops at a root container, which is the one whose head
   command has been filled in. *)
PROCEDURE InHoverRoot (ctx: Context): BOOLEAN;
VAR
    i: INTEGER;
    res, stop: BOOLEAN;

BEGIN
    i := ctx.contIdx;
    res := FALSE; stop := FALSE;
    WHILE (i > 0) & ~res & ~stop DO
        DEC(i);
        IF ctx.contItems[i] = ctx.hoverRoot THEN
            res := TRUE
        ELSIF ctx.containers[ctx.contItems[i]].head # NoIndex THEN
            stop := TRUE
        END
    END;

    RETURN res
END InHoverRoot;


PROCEDURE MouseOver* (ctx: Context; rect: MuBase.Rect): BOOLEAN;
VAR
    cr: MuBase.Rect;
    res: BOOLEAN;

BEGIN
    GetClipRect(ctx, cr);
    res := MuBase.Overlaps(rect, ctx.mousePos) &
           MuBase.Overlaps(cr, ctx.mousePos) &
           InHoverRoot(ctx);

    RETURN res
END MouseOver;


PROCEDURE DrawControlFrame* (ctx: Context; id: MuBase.Id; rect: MuBase.Rect;
                             colorid, opt: INTEGER);
BEGIN
    IF ~Has(opt, MuBase.OptNoFrame) THEN
        IF ctx.focus = id THEN
            colorid := colorid + 2
        ELSIF ctx.hover = id THEN
            colorid := colorid + 1
        END;
        ctx.drawFrame(ctx, rect, colorid)
    END
END DrawControlFrame;


PROCEDURE DrawControlText* (ctx: Context; str: ARRAY OF CHAR; rect: MuBase.Rect;
                            colorid, opt: INTEGER);
VAR
    pos: MuBase.Vec2;
    font, tw: INTEGER;
    c: MuBase.Color;

BEGIN
    font := ctx.style.font;
    tw := ctx.textWidth(ctx, font, str, 0, -1);
    PushClipRect(ctx, rect);
    pos.y := rect.y + (rect.h - ctx.textHeight(ctx, font)) DIV 2;
    IF Has(opt, MuBase.OptAlignCenter) THEN
        pos.x := rect.x + (rect.w - tw) DIV 2
    ELSIF Has(opt, MuBase.OptAlignRight) THEN
        pos.x := rect.x + rect.w - tw - ctx.style.padding
    ELSE
        pos.x := rect.x + ctx.style.padding
    END;
    Ink(ctx, colorid, c);
    DrawText(ctx, font, str, 0, -1, pos, c);
    PopClipRect(ctx)
END DrawControlText;


PROCEDURE UpdateControl* (ctx: Context; id: MuBase.Id; rect: MuBase.Rect;
                          opt: INTEGER);
VAR
    mouseover: BOOLEAN;

BEGIN
    mouseover := MouseOver(ctx, rect);
    IF ctx.focus = id THEN ctx.updatedFocus := 1 END;
    IF ~Has(opt, MuBase.OptNoInteract) THEN
        IF mouseover & (ctx.mouseDown = 0) THEN ctx.hover := id END;
        IF ctx.focus = id THEN
            IF (ctx.mousePressed # 0) & ~mouseover THEN SetFocus(ctx, 0) END;
            IF (ctx.mouseDown = 0) & ~Has(opt, MuBase.OptHoldFocus) THEN
                SetFocus(ctx, 0)
            END
        END;
        IF ctx.hover = id THEN
            IF ctx.mousePressed # 0 THEN
                SetFocus(ctx, id)
            ELSIF ~mouseover THEN
                ctx.hover := 0
            END
        END
    END
END UpdateControl;


(*============================================================================
   containers
   ==========================================================================*)

PROCEDURE GetContainer (ctx: Context; id: MuBase.Id; opt: INTEGER): INTEGER;
VAR
    idx: INTEGER;

BEGIN
    idx := PoolGet(ctx, ctx.containerPool, ContainerPoolSize, id);
    IF idx >= 0 THEN
        IF ctx.containers[idx].open OR ~Has(opt, MuBase.OptClosed) THEN
            PoolUpdate(ctx, ctx.containerPool, idx)
        END
    ELSIF Has(opt, MuBase.OptClosed) THEN
        idx := NoIndex
    ELSE
        idx := PoolInit(ctx, ctx.containerPool, ContainerPoolSize, id);
        ctx.containers[idx].head := NoIndex;
        ctx.containers[idx].tail := NoIndex;
        MuBase.MakeRect(ctx.containers[idx].rect, 0, 0, 0, 0);
        MuBase.MakeRect(ctx.containers[idx].body, 0, 0, 0, 0);
        MuBase.MakeVec2(ctx.containers[idx].contentSize, 0, 0);
        MuBase.MakeVec2(ctx.containers[idx].scroll, 0, 0);
        ctx.containers[idx].zindex := 0;
        ctx.containers[idx].open := TRUE;
        BringToFront(ctx, idx)
    END;

    RETURN idx
END GetContainer;


PROCEDURE GetContainerByName* (ctx: Context; name: ARRAY OF CHAR): INTEGER;
VAR
    id: MuBase.Id;

BEGIN
    id := GetIdStr(ctx, name);

    RETURN GetContainer(ctx, id, 0)
END GetContainerByName;


PROCEDURE PopContainer (ctx: Context);
VAR
    cnt: INTEGER;
    lay: LayoutPtr;

BEGIN
    cnt := CurrentContainer(ctx);
    lay := CurLayout(ctx);
    ctx.containers[cnt].contentSize.x := lay.max.x - lay.body.x;
    ctx.containers[cnt].contentSize.y := lay.max.y - lay.body.y;
    DEC(ctx.contIdx);
    DEC(ctx.layIdx);
    PopId(ctx)
END PopContainer;


PROCEDURE BeginRootContainer (ctx: Context; cntIdx: INTEGER);
VAR
    i: INTEGER;

BEGIN
    IF ctx.contIdx < ContainerStackSize THEN
        ctx.contItems[ctx.contIdx] := cntIdx;
        INC(ctx.contIdx)
    ELSE
        ctx.contItems[ContainerStackSize - 1] := cntIdx
    END;
    (* A root past the end of the root list is simply left out of it: its
       commands are then unreachable, which is better than overwriting the
       array. *)
    IF ctx.rootIdx < RootListSize THEN
        ctx.rootItems[ctx.rootIdx] := cntIdx;
        INC(ctx.rootIdx)
    END;
    i := PushCommand(ctx, MuBase.CmdJump);
    ctx.containers[cntIdx].head := i;
    IF MuBase.Overlaps(ctx.containers[cntIdx].rect, ctx.mousePos) &
       ((ctx.nextHoverRoot = NoIndex) OR
        (ctx.containers[cntIdx].zindex >
         ctx.containers[ctx.nextHoverRoot].zindex)) THEN
        ctx.nextHoverRoot := cntIdx
    END;
    (* clipping is reset here, so that a root container begun inside another
       one is not clipped to it *)
    IF ctx.clipIdx < ClipStackSize THEN
        ctx.clipItems[ctx.clipIdx] := unclippedRect;
        INC(ctx.clipIdx)
    ELSE
        ctx.clipItems[ClipStackSize - 1] := unclippedRect
    END
END BeginRootContainer;


PROCEDURE EndRootContainer (ctx: Context);
VAR
    cnt, i: INTEGER;

BEGIN
    cnt := CurrentContainer(ctx);
    i := PushCommand(ctx, MuBase.CmdJump);
    ctx.containers[cnt].tail := i;
    ctx.commands[ctx.containers[cnt].head].dst := ctx.cmdIdx;
    PopClipRect(ctx);
    PopContainer(ctx)
END EndRootContainer;


(*============================================================================
   text
   ==========================================================================*)

PROCEDURE Text* (ctx: Context; text: ARRAY OF CHAR);
VAR
    r: MuBase.Rect;
    pos: MuBase.Vec2;
    color: MuBase.Color;
    p, start, stop, word, w, font, n: INTEGER;
    inner, outer: BOOLEAN;

BEGIN
    font := ctx.style.font;
    Ink(ctx, MuBase.ColorText, color);
    n := LENGTH(text);
    LayoutBeginColumn(ctx);
    LayoutRow1(ctx, -1, ctx.textHeight(ctx, font));
    p := 0;
    REPEAT
        LayoutNext(ctx, r);
        w := 0;
        start := p; stop := p;
        inner := TRUE;
        REPEAT
            word := p;
            WHILE (p < n) & (text[p] # 0X) & (text[p] # " ") & (text[p] # 0AX) DO
                INC(p)
            END;
            w := w + ctx.textWidth(ctx, font, text, word, p - word);
            IF (w > r.w) & (stop # start) THEN
                (* this word does not fit and the line is not empty: leave it
                   for the next line *)
                inner := FALSE
            ELSE
                w := w + ctx.textWidth(ctx, font, text, p, 1);
                stop := p;
                INC(p);
                IF (stop >= n) OR (text[stop] = 0X) OR (text[stop] = 0AX) THEN
                    inner := FALSE
                END
            END
        UNTIL ~inner;
        MuBase.MakeVec2(pos, r.x, r.y);
        DrawText(ctx, font, text, start, stop - start, pos, color);
        p := stop + 1;
        outer := (stop < n) & (text[stop] # 0X)
    UNTIL ~outer;
    LayoutEndColumn(ctx)
END Text;


PROCEDURE Label* (ctx: Context; text: ARRAY OF CHAR);
VAR
    r: MuBase.Rect;

BEGIN
    LayoutNext(ctx, r);
    DrawControlText(ctx, text, r, MuBase.ColorText, 0)
END Label;


(*============================================================================
   basic controls
   ==========================================================================*)

PROCEDURE ButtonEx* (ctx: Context; label: ARRAY OF CHAR;
                     icon, opt: INTEGER): INTEGER;
VAR
    id: MuBase.Id;
    r: MuBase.Rect;
    iconKey: INTEGER;
    color: MuBase.Color;
    res: INTEGER;

BEGIN
    res := 0;
    IF label[0] # 0X THEN
        id := GetIdStr(ctx, label)
    ELSE
        iconKey := icon;
        id := GetIdAdr(ctx, SYSTEM.ADR(iconKey))
    END;
    LayoutNext(ctx, r);
    UpdateControl(ctx, id, r, opt);
    IF (ctx.mousePressed = MuBase.MouseLeft) & (ctx.focus = id) THEN
        res := res + MuBase.ResSubmit
    END;
    DrawControlFrame(ctx, id, r, MuBase.ColorButton, opt);
    IF label[0] # 0X THEN
        DrawControlText(ctx, label, r, MuBase.ColorButton, opt)
    END;
    IF icon # 0 THEN
        Ink(ctx, MuBase.ColorButton, color);
        DrawIcon(ctx, icon, r, color)
    END;

    RETURN res
END ButtonEx;


PROCEDURE Button* (ctx: Context; label: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN ButtonEx(ctx, label, 0, MuBase.OptAlignCenter)
END Button;


PROCEDURE Checkbox* (ctx: Context; label: ARRAY OF CHAR;
                     VAR state: BOOLEAN): INTEGER;
VAR
    id: MuBase.Id;
    r, box: MuBase.Rect;
    color: MuBase.Color;
    res: INTEGER;

BEGIN
    res := 0;
    id := GetIdAdr(ctx, SYSTEM.ADR(state));
    LayoutNext(ctx, r);
    MuBase.MakeRect(box, r.x, r.y, r.h, r.h);
    UpdateControl(ctx, id, r, 0);
    IF (ctx.mousePressed = MuBase.MouseLeft) & (ctx.focus = id) THEN
        res := res + MuBase.ResChange;
        state := ~state
    END;
    DrawControlFrame(ctx, id, box, MuBase.ColorBase, 0);
    IF state THEN
        Ink(ctx, MuBase.ColorBase, color);
        DrawIcon(ctx, MuBase.IconCheck, box, color)
    END;
    MuBase.MakeRect(r, r.x + box.w, r.y, r.w - box.w, r.h);
    DrawControlText(ctx, label, r, MuBase.ColorText, 0);

    RETURN res
END Checkbox;


(* ---------------------------------------------------------------------------
   the text a field edits

   A field owns no storage: the buffer is the caller's and the caret is in the
   context.  What is here is what both need and neither can keep - the steps
   over whole characters, and the two ways bytes leave a buffer and arrive in
   one.

   A UTF-8 string is a sequence of bytes in which 80H..0BFH continues the
   character before it and anything else begins one.  That is what makes the
   encoding self-synchronising and these walks possible from either end; it is
   also why a caret is a byte offset here and not an index.  The Backspace this
   port has always had made the same test; it is a helper now because a caret
   that moves, a paste that is cut short and a copy that is cut short all need
   it.
*)

(* The start of the character before position i, which is where a caret that
   steps left lands. *)
PROCEDURE PrevChar (buf: ARRAY OF CHAR; i: INTEGER): INTEGER;
VAR j: INTEGER;
BEGIN
    j := i - 1;
    WHILE (j > 0) & (ORD(buf[j]) >= 80H) & (ORD(buf[j]) < 0C0H) DO DEC(j) END;

    RETURN j
END PrevChar;


(* The start of the character after position i, which is where a caret that
   steps right lands and where a Delete stops. *)
PROCEDURE NextChar (buf: ARRAY OF CHAR; i, len: INTEGER): INTEGER;
VAR j: INTEGER;
BEGIN
    j := i + 1;
    WHILE (j < len) & (ORD(buf[j]) >= 80H) & (ORD(buf[j]) < 0C0H) DO INC(j) END;

    RETURN j
END NextChar;


(* The longest length at or below n that does not end in the middle of a
   character.  The byte at s[n] is the one that would have followed, so if that
   byte continues a character the cut has to move back - the test the old
   backspace made, read on the far side of the same boundary. *)
PROCEDURE Whole (s: ARRAY OF CHAR; n: INTEGER): INTEGER;
VAR r: INTEGER;
BEGIN
    r := n;
    WHILE (r > 0) & (r < LENGTH(s)) & (ORD(s[r]) >= 80H) & (ORD(s[r]) < 0C0H) DO
        DEC(r)
    END;

    RETURN r
END Whole;


(* The code point of the character beginning at i.  Only the marks below need
   it: everything else about a word is decided by the byte.  The buffer is
   well-formed wherever a caret can stand, so a lead byte's continuations are
   there to be read. *)
PROCEDURE CodePoint (buf: ARRAY OF CHAR; i: INTEGER): INTEGER;
VAR
    c, cp: INTEGER;

BEGIN
    c := ORD(buf[i]);
    IF c < 0E0H THEN
        cp := (c - 0C0H) * 40H + (ORD(buf[i + 1]) - 80H)
    ELSIF c < 0F0H THEN
        cp := (c - 0E0H) * 1000H + (ORD(buf[i + 1]) - 80H) * 40H +
              (ORD(buf[i + 2]) - 80H)
    ELSE
        cp := (c - 0F0H) * 40000H + (ORD(buf[i + 1]) - 80H) * 1000H +
              (ORD(buf[i + 2]) - 80H) * 40H + (ORD(buf[i + 3]) - 80H)
    END;

    RETURN cp
END CodePoint;


(* Whether the character beginning at i is part of a word, which is what a
   Ctrl+arrow and a Ctrl+Backspace have to agree about.

   An ASCII letter, a digit or an underscore is one.  Anything outside ASCII is
   one as well, and that is a decision rather than an oversight: the only
   non-ASCII a buffer holds is text somebody typed, and this module has no table
   to ask which of those characters are letters - so counting every Cyrillic
   letter as one is worth counting an em dash as one, while the alternative is a
   Ctrl+arrow that cannot cross a Russian word at all.  The marks named here are
   the exceptions, being punctuation in the languages this port is used with and
   otherwise glueing two words into one. *)
PROCEDURE IsWord (buf: ARRAY OF CHAR; i: INTEGER): BOOLEAN;
VAR
    c, cp: INTEGER;
    w: BOOLEAN;

BEGIN
    c := ORD(buf[i]);
    IF c < 80H THEN
        w := ((c >= ORD("0")) & (c <= ORD("9"))) OR
             ((c >= ORD("A")) & (c <= ORD("Z"))) OR
             ((c >= ORD("a")) & (c <= ORD("z"))) OR (c = ORD("_"))
    ELSE
        cp := CodePoint(buf, i);
        w := TRUE;
        IF (cp = 0A0H) OR (cp = 0ABH) OR (cp = 0BBH) OR
           ((cp >= 2010H) & (cp <= 2015H)) OR
           ((cp >= 2018H) & (cp <= 201DH)) OR (cp = 2026H) THEN
            w := FALSE
        END
    END;

    RETURN w
END IsWord;


(* The beginning of the word before position i, which is where Ctrl+Left goes:
   back over whatever separates this word from the one before, and then over
   that word.  A caret in the middle of a word therefore lands on that word's
   own beginning, as it does in a Windows edit control.  Called only with i > 0,
   which is what keeps the walk off the byte before the buffer. *)
PROCEDURE WordLeft (buf: ARRAY OF CHAR; i: INTEGER): INTEGER;
VAR j: INTEGER;

BEGIN
    j := i;
    WHILE (j > 0) & ~IsWord(buf, PrevChar(buf, j)) DO j := PrevChar(buf, j) END;
    WHILE (j > 0) & IsWord(buf, PrevChar(buf, j)) DO j := PrevChar(buf, j) END;

    RETURN j
END WordLeft;


(* The beginning of the word after position i, which is where Ctrl+Right goes:
   out of this word and then over the space or the punctuation behind it. *)
PROCEDURE WordRight (buf: ARRAY OF CHAR; i, len: INTEGER): INTEGER;
VAR j: INTEGER;

BEGIN
    j := i;
    WHILE (j < len) & IsWord(buf, j) DO j := NextChar(buf, j, len) END;
    WHILE (j < len) & ~IsWord(buf, j) DO j := NextChar(buf, j, len) END;

    RETURN j
END WordRight;


(* Remove buf[lo..hi-1] and close the gap.  Byte by byte, because a bare array
   assignment is not a statement in this language. *)
PROCEDURE DeleteRun (VAR buf: ARRAY OF CHAR; VAR len: INTEGER; lo, hi: INTEGER);
VAR
    i, n: INTEGER;

BEGIN
    n := hi - lo;
    i := lo;
    WHILE i + n < len DO
        buf[i] := buf[i + n];
        INC(i)
    END;
    len := len - n;
    buf[len] := 0X
END DeleteRun;


(* Put s[0..n-1] into buf at `at`, pushing the tail right, and answer how much
   of it went in: less than n when the buffer is nearly full, and the cut is
   backed off to a character boundary as it was when the byte came from the
   keyboard.  `at` is a caret, and so already sits on a boundary. *)
PROCEDURE InsertRun (VAR buf: ARRAY OF CHAR; bufsz: INTEGER; VAR len: INTEGER;
                     at: INTEGER; s: ARRAY OF CHAR; n: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
    IF n > bufsz - len - 1 THEN n := bufsz - len - 1 END;
    n := Whole(s, n);
    IF n > 0 THEN
        i := len;
        WHILE i > at DO
            DEC(i);
            buf[i + n] := buf[i]
        END;
        i := 0;
        WHILE i < n DO
            buf[at + i] := s[i];
            INC(i)
        END;
        len := len + n;
        buf[len] := 0X
    END;

    RETURN n
END InsertRun;


(* A copy, and the first half of a cut: the run into the context, which is
   where the host will look for it.  The terminator is written because
   everything that reads a buffer here reads it as a string, and the run is cut
   to the same two ceilings a paste is - the one a buffer sets and the one
   ClipSize sets - so that what goes out can come back in. *)
PROCEDURE ClipTake (ctx: Context; buf: ARRAY OF CHAR; lo, hi: INTEGER);
VAR
    i, n: INTEGER;

BEGIN
    n := hi - lo;
    IF n > ClipSize - 1 THEN n := ClipSize - 1 END;
    (* The boundary is looked for at the far end of the run, which is at `lo`
       bytes into the buffer and not at 0: asking about offset `n` instead
       reads a byte of whatever precedes the run - or, when the run is the
       whole buffer, past it - and a cut made there takes the last character in
       half.  Rearranging the difference keeps the answer an offset from `lo`. *)
    n := Whole(buf, lo + n) - lo;
    i := 0;
    WHILE i < n DO
        ctx.clip[i] := buf[lo + i];
        INC(i)
    END;
    ctx.clip[n] := 0X
END ClipTake;


(* The two ends of the run in order - and therefore whether there is a run at
   all, since they are equal when the caret and the anchor are in the same
   place.  Every phase of a frame's editing moves one of them, so this is
   called once before each phase and once more before the frame is drawn: a
   Backspace takes the run away, and the pair read before it would draw a
   selection that is no longer there. *)
PROCEDURE Sel (ctx: Context; VAR lo, hi: INTEGER);
BEGIN
    lo := MuBase.Min(ctx.caret, ctx.anchor);
    hi := MuBase.Max(ctx.caret, ctx.anchor)
END Sel;


(* A snapshot of the focused field, taken before an edit changes it.  Nothing
   is pushed once the field is longer than a snapshot can hold: the stack is
   emptied instead, because a truncated copy would restore a buffer with its
   tail cut off, and an undo that loses text is worse than one that does
   nothing. *)
PROCEDURE PushUndo (ctx: Context; buf: ARRAY OF CHAR; id: MuBase.Id;
                    kind: INTEGER);
VAR
    i, n, k: INTEGER;
    join: BOOLEAN;

BEGIN
    n := 0;
    WHILE (n < LENGTH(buf)) & (buf[n] # 0X) DO INC(n) END;
    IF n >= UndoMax THEN
        ctx.undoN := 0
    ELSE
        (* An edit that continues the run the top snapshot was taken for joins
           it rather than pushing another, so that a word typed is one step back
           and not one a letter.  A kind of UndoNone never joins and is never
           joined, which is what makes a paste a step of its own. *)
        join := FALSE;
        IF (kind # UndoNone) & (ctx.undoN > 0) THEN
            join := (ctx.undo[ctx.undoN - 1].kind = kind) &
                    (ctx.undo[ctx.undoN - 1].id = id)
        END;
        IF ~join THEN
            (* Full: the oldest step is the one that goes. *)
            IF ctx.undoN = UndoLevels THEN
                i := 1;
                WHILE i < UndoLevels DO
                    ctx.undo[i - 1] := ctx.undo[i];
                    INC(i)
                END;
                ctx.undoN := UndoLevels - 1
            END;
            k := ctx.undoN;
            ctx.undo[k].id := id;
            i := 0;
            WHILE i < n DO
                ctx.undo[k].text[i] := buf[i];
                INC(i)
            END;
            ctx.undo[k].text[n] := 0X;
            ctx.undo[k].len := n;
            ctx.undo[k].caret := ctx.caret;
            ctx.undo[k].anchor := ctx.anchor;
            ctx.undo[k].kind := kind;
            ctx.undoN := k + 1
        END
    END
END PushUndo;


(* The end of a run: the next edit starts a new step back instead of joining
   the last one.  Every move of the caret does this, because a run of typing
   with an arrow in the middle of it is two edits and not one. *)
PROCEDURE SealUndo (ctx: Context);
BEGIN
    IF ctx.undoN > 0 THEN
        ctx.undo[ctx.undoN - 1].kind := UndoNone
    END
END SealUndo;


(* One step back, answering whether there was one.  The snapshot has to belong
   to the field that has the focus, which is the field the stack was cleared for
   when it took it.  The caret and the run come back with the text, so a step
   back over a cut gives back the cut's selection as well. *)
PROCEDURE UndoOne (ctx: Context; VAR buf: ARRAY OF CHAR; bufsz: INTEGER;
                   VAR len: INTEGER): BOOLEAN;
VAR
    i, n: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    IF (ctx.undoN > 0) & (ctx.undo[ctx.undoN - 1].id = ctx.editId) THEN
        DEC(ctx.undoN);
        n := ctx.undo[ctx.undoN].len;
        IF n > bufsz - 1 THEN n := bufsz - 1 END;
        ok := TRUE;
        i := 0;
        WHILE i < n DO
            buf[i] := ctx.undo[ctx.undoN].text[i];
            INC(i)
        END;
        buf[n] := 0X;
        len := n;
        ctx.caret := ctx.undo[ctx.undoN].caret;
        ctx.anchor := ctx.undo[ctx.undoN].anchor;
        IF ctx.caret > len THEN ctx.caret := len END;
        IF ctx.anchor > len THEN ctx.anchor := len END
    END;

    RETURN ok
END UndoOne;


(* Where the text of a field starts on the screen, for a given caret.  A field
   that fits is right-aligned in its box, and one that does not follows the
   caret - the caret is kept inside the box and the text slides under it, in
   either direction, because a value longer than the box is why: without this
   the caret of a long field is a cursor nobody can see, and the middle of one
   cannot be edited at all.

   It is a procedure because two places have to agree about it to the pixel:
   the drawing, which puts the glyphs there, and the hit-testing, which has to
   answer which character the pointer is over.  Two copies of this arithmetic
   would be two answers, and a click would land one character off the moment
   they drifted.  The caret is passed in rather than read, because the draw
   wants the caret the frame ended with and the hit-test the one it started
   with - what the user aimed at is what was on the screen when they pressed. *)
PROCEDURE TextOrigin (ctx: Context; buf: ARRAY OF CHAR; r: MuBase.Rect;
                      len, caret: INTEGER): INTEGER;
VAR
    tx, caretX, limit: INTEGER;

BEGIN
    tx := r.x + MuBase.Min(r.w - ctx.style.padding -
                           ctx.textWidth(ctx, ctx.style.font, buf, 0, len) - 1,
                           ctx.style.padding);
    limit := r.x + r.w - ctx.style.padding;
    caretX := tx + ctx.textWidth(ctx, ctx.style.font, buf, 0, caret);
    IF caretX > limit THEN
        tx := tx - (caretX - limit)
    ELSIF caretX < r.x + ctx.style.padding THEN
        tx := tx + (r.x + ctx.style.padding - caretX)
    END;

    RETURN tx
END TextOrigin;


(* Which byte offset of buf the screen column x means, given where the text
   starts.  Every character is asked about separately and the pointer is placed
   on the side of its middle it fell on, so the answer is always the start of a
   character and never the middle of one - a Cyrillic letter is two bytes, and
   a caret between them is a caret in no text at all.  The walk is over
   characters and the width is asked of the font, so a face whose letters are
   not all one size hit-tests correctly; a monospaced face would be measured
   right by it too, for the same reason. *)
PROCEDURE OffsetAtX (ctx: Context; buf: ARRAY OF CHAR; len, textx, x: INTEGER): INTEGER;
VAR
    i, j, cx, w, at: INTEGER;
    found: BOOLEAN;

BEGIN
    i := 0; cx := textx; at := 0; found := FALSE;
    WHILE (i < len) & ~found DO
        j := NextChar(buf, i, len);
        w := ctx.textWidth(ctx, ctx.style.font, buf, i, j - i);
        IF x < cx + (w + 1) DIV 2 THEN
            found := TRUE
        ELSE
            cx := cx + w;
            at := j;
            i := j
        END
    END;

    RETURN at
END OffsetAtX;


PROCEDURE TextboxRaw* (ctx: Context; VAR buf: ARRAY OF CHAR; bufsz: INTEGER;
                       id: MuBase.Id; r: MuBase.Rect; opt: INTEGER): INTEGER;
VAR
    res, len, n, texth, textx, texty: INTEGER;
    lo, hi, p, moved, shift, ctrl, caretX, selX: INTEGER;
    ok: BOOLEAN;
    color, selInk, caretInk: MuBase.Color;
    font: INTEGER;
    pos: MuBase.Vec2;
    cr, sr: MuBase.Rect;

BEGIN
    res := 0;
    UpdateControl(ctx, id, r, opt + MuBase.OptHoldFocus);

    IF ctx.focus = id THEN
        len := 0;
        WHILE (len < bufsz) & (buf[len] # 0X) DO INC(len) END;

        (* A field that has just taken the focus takes the caret at the end of
           what it holds, which is where a textbox with no caret of its own had
           it always.  From then on the two ends are clamped every frame,
           because the buffer is the caller's and may be shorter than it was
           when they were placed: NumberTextbox rewrites its own on every frame
           it edits, and an inspector field is refilled from the model. *)
        IF ctx.editId # id THEN
            ctx.editId := id;
            ctx.caret := len;
            ctx.anchor := len;
            (* The history is the field's, and the field it belonged to is not
               this one any more. *)
            ctx.undoN := 0
        END;
        IF ctx.caret > len THEN ctx.caret := len END;
        IF ctx.anchor > len THEN ctx.anchor := len END;

        (* Shift is held rather than pressed, so it is read from keyDown: a run
           grows for as long as the arrow repeats under it.  It is read here,
           before the pointer, because both the arrows and a press ask it the
           same question - does this move the far end of the run or start a new
           one. *)
        shift := 0;
        IF Has(ctx.keyDown, MuBase.KeyShift) THEN shift := 1 END;
        (* Ctrl is read here too, and for the same reason: the arrows, Backspace
           and Delete all ask it whether they move by a character or by a
           word. *)
        ctrl := 0;
        IF Has(ctx.keyDown, MuBase.KeyCtrl) THEN ctrl := 1 END;

        (* The pointer.  A press inside the box puts the caret where it was
           pressed, which is the one thing no key can say, and a drag carries
           the near end of the run along with it.

           The origin is asked for before the editing rather than after it, so
           that the character the pointer is over is the character that was
           under it when the button went down: the text slides under the caret,
           and the pixels a press was aimed at are the ones the last frame
           drew. *)
        textx := TextOrigin(ctx, buf, r, len, ctx.caret);
        IF Has(ctx.mouseDown, MuBase.MouseLeft) THEN
            IF ctx.dragId = id THEN
                ctx.caret := OffsetAtX(ctx, buf, len, textx, ctx.mousePos.x);
                SealUndo(ctx)
            ELSIF Has(ctx.mousePressed, MuBase.MouseLeft) & MouseOver(ctx, r) THEN
                p := OffsetAtX(ctx, buf, len, textx, ctx.mousePos.x);
                ctx.caret := p;
                IF shift = 0 THEN ctx.anchor := p END;
                ctx.dragId := id;
                SealUndo(ctx)
            END
        ELSIF ctx.dragId = id THEN
            (* The button came back up: the pointer's last word is taken, in
               case it moved and the move was folded into this same message
               batch, and the field gives the drag up. *)
            ctx.caret := OffsetAtX(ctx, buf, len, textx, ctx.mousePos.x);
            ctx.dragId := 0
        END;
        Sel(ctx, lo, hi);

        (* Typed text first, because it is what the frame is for, and it
           replaces the run - which is what every editor does with a letter
           typed over a selection.  The room left for it is measured after the
           run has gone, so that replacing a long selection with a long paste
           needs no more room than the paste itself. *)
        n := 0;
        WHILE (n < LENGTH(ctx.inputText)) & (ctx.inputText[n] # 0X) DO INC(n) END;
        IF n > 0 THEN
            PushUndo(ctx, buf, id, UndoType);
            IF lo # hi THEN
                DeleteRun(buf, len, lo, hi);
                ctx.caret := lo; ctx.anchor := lo
            END;
            moved := InsertRun(buf, bufsz, len, ctx.caret, ctx.inputText, n);
            IF moved > 0 THEN
                ctx.caret := ctx.caret + moved;
                ctx.anchor := ctx.caret;
                res := res + MuBase.ResChange
            END
        END;
        Sel(ctx, lo, hi);

        (* The clipboard, which is what the four control letters are for.  The
           library fills `clip` and says what it did; publishing it is the
           host's, because a clipboard is a platform service and this module is
           not - see ClipNone. *)
        IF Has(ctx.keyDown, MuBase.KeyCtrl) THEN
            IF Has(ctx.keyPressed, MuBase.KeyA) THEN
                ctx.anchor := 0;
                ctx.caret := len;
                SealUndo(ctx)
            END;
            (* Ctrl+Z takes the last edit back.  There is no redo to go with it:
               a stack that has been popped has nothing to push back, and an undo
               that can be undone is a second stack this field has no room for. *)
            IF Has(ctx.keyPressed, MuBase.KeyZ) THEN
                ok := UndoOne(ctx, buf, bufsz, len);
                SealUndo(ctx);
                IF ok THEN res := res + MuBase.ResChange END
            END;
            IF Has(ctx.keyPressed, MuBase.KeyC) & (lo # hi) THEN
                ClipTake(ctx, buf, lo, hi);
                ctx.clipReq := ClipCopy
            END;
            IF Has(ctx.keyPressed, MuBase.KeyX) & (lo # hi) THEN
                PushUndo(ctx, buf, id, UndoNone);
                ClipTake(ctx, buf, lo, hi);
                ctx.clipReq := ClipCut;
                DeleteRun(buf, len, lo, hi);
                ctx.caret := lo; ctx.anchor := lo;
                res := res + MuBase.ResChange
            END;
            IF Has(ctx.keyPressed, MuBase.KeyV) THEN
                n := 0;
                WHILE (n < LENGTH(ctx.clip)) & (ctx.clip[n] # 0X) DO INC(n) END;
                IF n > 0 THEN
                    PushUndo(ctx, buf, id, UndoNone);
                    IF lo # hi THEN
                        DeleteRun(buf, len, lo, hi);
                        ctx.caret := lo; ctx.anchor := lo
                    END;
                    moved := InsertRun(buf, bufsz, len, ctx.caret, ctx.clip, n);
                    IF moved > 0 THEN
                        ctx.caret := ctx.caret + moved;
                        ctx.anchor := ctx.caret;
                        res := res + MuBase.ResChange
                    END
                END
            END
        END;
        Sel(ctx, lo, hi);

        (* Backspace and Delete take the run when there is one and one
           character when there is not - a character, not a byte. *)
        IF Has(ctx.keyPressed, MuBase.KeyBackspace) THEN
            IF lo # hi THEN
                PushUndo(ctx, buf, id, UndoErase);
                DeleteRun(buf, len, lo, hi);
                ctx.caret := lo
            ELSIF ctx.caret > 0 THEN
                IF ctrl # 0 THEN
                    p := WordLeft(buf, ctx.caret)
                ELSE
                    p := PrevChar(buf, ctx.caret)
                END;
                PushUndo(ctx, buf, id, UndoErase);
                DeleteRun(buf, len, p, ctx.caret);
                ctx.caret := p
            END;
            ctx.anchor := ctx.caret;
            res := res + MuBase.ResChange
        END;
        IF Has(ctx.keyPressed, MuBase.KeyDelete) THEN
            IF lo # hi THEN
                PushUndo(ctx, buf, id, UndoErase);
                DeleteRun(buf, len, lo, hi);
                ctx.caret := lo
            ELSIF ctx.caret < len THEN
                IF ctrl # 0 THEN
                    p := WordRight(buf, ctx.caret, len)
                ELSE
                    p := NextChar(buf, ctx.caret, len)
                END;
                PushUndo(ctx, buf, id, UndoErase);
                DeleteRun(buf, len, ctx.caret, p)
            END;
            ctx.anchor := ctx.caret;
            res := res + MuBase.ResChange
        END;

        (* The arrows.  An arrow without Shift drops the run and puts the caret
           at the end of it that it was heading for, which is what makes a
           selection replaced by one keystroke; with Shift it moves the end the
           caret is and leaves the anchor where it is. *)
        IF Has(ctx.keyPressed, MuBase.KeyLeft) THEN
            IF (lo # hi) & (shift = 0) THEN
                ctx.caret := lo
            ELSIF ctrl # 0 THEN
                ctx.caret := WordLeft(buf, ctx.caret)
            ELSIF ctx.caret > 0 THEN
                ctx.caret := PrevChar(buf, ctx.caret)
            END;
            IF shift = 0 THEN ctx.anchor := ctx.caret END;
            SealUndo(ctx)
        END;
        IF Has(ctx.keyPressed, MuBase.KeyRight) THEN
            IF (lo # hi) & (shift = 0) THEN
                ctx.caret := hi
            ELSIF ctrl # 0 THEN
                ctx.caret := WordRight(buf, ctx.caret, len)
            ELSIF ctx.caret < len THEN
                ctx.caret := NextChar(buf, ctx.caret, len)
            END;
            IF shift = 0 THEN ctx.anchor := ctx.caret END;
            SealUndo(ctx)
        END;
        IF Has(ctx.keyPressed, MuBase.KeyHome) THEN
            ctx.caret := 0;
            IF shift = 0 THEN ctx.anchor := 0 END;
            SealUndo(ctx)
        END;
        IF Has(ctx.keyPressed, MuBase.KeyEnd) THEN
            ctx.caret := len;
            IF shift = 0 THEN ctx.anchor := len END;
            SealUndo(ctx)
        END;

        (* Return gives the field up, as it always did, and the next focus
           opens at the end again rather than at whatever was selected. *)
        IF Has(ctx.keyPressed, MuBase.KeyReturn) THEN
            ctx.editId := 0;
            ctx.undoN := 0;             (* the field has given the focus up *)
            SetFocus(ctx, 0);
            res := res + MuBase.ResSubmit
        END;
        Sel(ctx, lo, hi)
    END;

    DrawControlFrame(ctx, id, r, MuBase.ColorBase, opt);
    IF ctx.focus = id THEN
        Ink(ctx, MuBase.ColorBase, color);
        caretInk := ctx.style.parts[MuBase.ColorBase].caret;
        IF caretInk.a = 0 THEN caretInk := color END;
        Ink(ctx, MuBase.ColorSelect, selInk);
        font := ctx.style.font;
        (* The same origin the hit-testing asked for, and for the same reason
           it is one procedure: what is drawn and what a click means have to be
           the same measurement.  Here the caret is the one the frame ended
           with, so the box has already slid to wherever the editing left it. *)
        texth := ctx.textHeight(ctx, font);
        textx := TextOrigin(ctx, buf, r, len, ctx.caret);
        texty := r.y + (r.h - texth) DIV 2;
        caretX := textx + ctx.textWidth(ctx, font, buf, 0, ctx.caret);

        PushClipRect(ctx, r);
        IF lo # hi THEN
            (* The run is drawn inverted: ColorSelect behind the glyphs and
               that slot's own text colour where they were.  The two default
               to the pair a field already had - the program's text behind and
               the base's ink on top - so a program that names neither sees
               the inversion it always saw, and a theme that names them gets
               the highlight colour of the system it is imitating. *)
            selX := textx + ctx.textWidth(ctx, font, buf, 0, lo);
            MuBase.MakeRect(sr, selX, texty,
                ctx.textWidth(ctx, font, buf, lo, hi - lo), texth);
            ctx.drawFrame(ctx, sr, MuBase.ColorSelect);
            MuBase.MakeVec2(pos, textx, texty);
            DrawText(ctx, font, buf, 0, lo, pos, color);
            MuBase.MakeVec2(pos, selX, texty);
            DrawText(ctx, font, buf, lo, hi - lo, pos, selInk);
            IF hi < len THEN
                MuBase.MakeVec2(pos, selX + sr.w, texty);
                DrawText(ctx, font, buf, hi, -1, pos, color)
            END
        ELSE
            MuBase.MakeVec2(pos, textx, texty);
            DrawText(ctx, font, buf, 0, len, pos, color)
        END;
        MuBase.MakeRect(cr, caretX, texty, 1, texth);
        DrawRect(ctx, cr, caretInk);
        PopClipRect(ctx)
    ELSE
        DrawControlText(ctx, buf, r, MuBase.ColorBase, opt)
    END;

    RETURN res
END TextboxRaw;


(* TextboxEx - `bufsz` is how much the buffer can hold, as in C's
   mu_textbox(ctx, buf, bufsz).  It has to be given: LENGTH(buf) would be the
   length of the text already in it, which for an empty box is zero. *)
PROCEDURE TextboxEx* (ctx: Context; VAR buf: ARRAY OF CHAR; bufsz: INTEGER;
                      opt: INTEGER): INTEGER;
VAR
    id: MuBase.Id;
    r: MuBase.Rect;

BEGIN
    id := GetIdAdr(ctx, SYSTEM.ADR(buf[0]));
    LayoutNext(ctx, r);

    RETURN TextboxRaw(ctx, buf, bufsz, id, r, opt)
END TextboxEx;


PROCEDURE Textbox* (ctx: Context; VAR buf: ARRAY OF CHAR;
                    bufsz: INTEGER): INTEGER;
BEGIN
    RETURN TextboxEx(ctx, buf, bufsz, 0)
END Textbox;


(* NumberTextbox - a slider or a number shown as an editable field while shift
   is held as it is clicked.  Answers TRUE while the field is being edited, in
   which case the caller draws nothing else. *)
PROCEDURE NumberTextbox (ctx: Context; VAR value: REAL;
                         r: MuBase.Rect; id: MuBase.Id): BOOLEAN;
VAR
    res, editing: INTEGER;

BEGIN
    editing := 0;
    IF (ctx.mousePressed = MuBase.MouseLeft) &
       Has(ctx.keyDown, MuBase.KeyShift) & (ctx.hover = id) THEN
        ctx.numberEdit := id;
        FmtReal(ctx.numberEditBuf, RealFmt, value)
    END;
    IF ctx.numberEdit = id THEN
        res := TextboxRaw(ctx, ctx.numberEditBuf, MaxFmt, id, r, 0);
        IF Has(res, MuBase.ResSubmit) OR (ctx.focus # id) THEN
            ParseReal(ctx.numberEditBuf, value);
            ctx.numberEdit := 0
        ELSE
            editing := 1
        END
    END;

    RETURN editing # 0
END NumberTextbox;


PROCEDURE SliderEx* (ctx: Context; VAR value: REAL; low, high, step: REAL;
                     fmt: ARRAY OF CHAR; opt: INTEGER): INTEGER;
VAR
    buf: FmtBuf;
    thumb, base: MuBase.Rect;
    id: MuBase.Id;
    x, w, res: INTEGER;
    last, v: REAL;

BEGIN
    res := 0;
    last := value; v := last;
    id := GetIdAdr(ctx, SYSTEM.ADR(value));
    LayoutNext(ctx, base);

    IF NumberTextbox(ctx, v, base, id) THEN
        res := 0
    ELSE
        UpdateControl(ctx, id, base, opt);

        IF (ctx.focus = id) &
           ((ctx.mouseDown + ctx.mousePressed) = MuBase.MouseLeft) THEN
            v := low + FLT(ctx.mousePos.x - base.x) * (high - low) / FLT(base.w);
            IF step # 0.0 THEN
                v := FLT(Trunc((v + step / 2.0) / step)) * step
            END
        END;
        v := MuBase.ClampReal(v, low, high);
        value := v;
        IF last # v THEN res := res + MuBase.ResChange END;

        DrawControlFrame(ctx, id, base, MuBase.ColorBase, opt);
        w := ctx.style.thumbSize;
        x := Trunc((v - low) * FLT(base.w - w) / (high - low));
        MuBase.MakeRect(thumb, base.x + x, base.y, w, base.h);
        DrawControlFrame(ctx, id, thumb, MuBase.ColorButton, opt);
        FmtReal(buf, fmt, v);
        DrawControlText(ctx, buf, base, MuBase.ColorBase, opt)
    END;

    RETURN res
END SliderEx;


PROCEDURE Slider* (ctx: Context; VAR value: REAL; low, high: REAL): INTEGER;
BEGIN
    RETURN SliderEx(ctx, value, low, high, 0.0, SliderFmt, MuBase.OptAlignCenter)
END Slider;


PROCEDURE NumberEx* (ctx: Context; VAR value: REAL; step: REAL;
                     fmt: ARRAY OF CHAR; opt: INTEGER): INTEGER;
VAR
    buf: FmtBuf;
    base: MuBase.Rect;
    id: MuBase.Id;
    res: INTEGER;
    last: REAL;

BEGIN
    res := 0;
    id := GetIdAdr(ctx, SYSTEM.ADR(value));
    LayoutNext(ctx, base);
    last := value;

    IF NumberTextbox(ctx, value, base, id) THEN
        res := 0
    ELSE
        UpdateControl(ctx, id, base, opt);
        IF (ctx.focus = id) & (ctx.mouseDown = MuBase.MouseLeft) THEN
            value := value + FLT(ctx.mouseDelta.x) * step
        END;
        IF value # last THEN res := res + MuBase.ResChange END;
        DrawControlFrame(ctx, id, base, MuBase.ColorBase, opt);
        FmtReal(buf, fmt, value);
        DrawControlText(ctx, buf, base, MuBase.ColorBase, opt)
    END;

    RETURN res
END NumberEx;


PROCEDURE Number* (ctx: Context; VAR value: REAL; step: REAL): INTEGER;
BEGIN
    RETURN NumberEx(ctx, value, step, SliderFmt, MuBase.OptAlignCenter)
END Number;


(* HeaderBody - the body shared by a header and a tree node.  A tree node
   keeps its expanded state in the tree-node pool, keyed by the label's id. *)
PROCEDURE HeaderBody (ctx: Context; label: ARRAY OF CHAR;
                      istreenode: BOOLEAN; opt: INTEGER): INTEGER;
VAR
    r, ir: MuBase.Rect;
    id: MuBase.Id;
    idx, res: INTEGER;
    active, expanded: BOOLEAN;
    color: MuBase.Color;

BEGIN
    id := GetIdStr(ctx, label);
    idx := PoolGet(ctx, ctx.treenodePool, TreeNodePoolSize, id);
    LayoutRow1(ctx, -1, 0);

    active := idx >= 0;
    IF Has(opt, MuBase.OptExpanded) THEN
        expanded := ~active
    ELSE
        expanded := active
    END;
    LayoutNext(ctx, r);
    UpdateControl(ctx, id, r, 0);
    active := active # ((ctx.mousePressed = MuBase.MouseLeft) & (ctx.focus = id));

    IF idx >= 0 THEN
        IF active THEN
            PoolUpdate(ctx, ctx.treenodePool, idx)
        ELSE
            ctx.treenodePool[idx].id := 0;
            ctx.treenodePool[idx].lastUpdate := 0
        END
    ELSIF active THEN
        idx := PoolInit(ctx, ctx.treenodePool, TreeNodePoolSize, id)
    END;

    IF istreenode THEN
        IF ctx.hover = id THEN
            ctx.drawFrame(ctx, r, MuBase.ColorButtonHover)
        END
    ELSE
        DrawControlFrame(ctx, id, r, MuBase.ColorButton, 0)
    END;
    (* the ink is asked for once, above the branch that draws with it: a
       collapsed node draws the other icon and must not read a colour the
       expanded branch was the only one to set *)
    Ink(ctx, MuBase.ColorButton, color);
    IF expanded THEN
        MuBase.MakeRect(ir, r.x, r.y, r.h, r.h);
        DrawIcon(ctx, MuBase.IconExpanded, ir, color)
    ELSE
        MuBase.MakeRect(ir, r.x, r.y, r.h, r.h);
        DrawIcon(ctx, MuBase.IconCollapsed, ir, color)
    END;
    r.x := r.x + r.h - ctx.style.padding;
    r.w := r.w - r.h + ctx.style.padding;
    DrawControlText(ctx, label, r, MuBase.ColorText, 0);

    IF expanded THEN
        res := MuBase.ResActive
    ELSE
        res := 0
    END;

    RETURN res
END HeaderBody;


PROCEDURE HeaderEx* (ctx: Context; label: ARRAY OF CHAR; opt: INTEGER): INTEGER;
BEGIN
    RETURN HeaderBody(ctx, label, FALSE, opt)
END HeaderEx;


PROCEDURE Header* (ctx: Context; label: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN HeaderBody(ctx, label, FALSE, 0)
END Header;


PROCEDURE BeginTreeNodeEx* (ctx: Context; label: ARRAY OF CHAR;
                            opt: INTEGER): INTEGER;
VAR
    res: INTEGER;
    lay: LayoutPtr;

BEGIN
    res := HeaderBody(ctx, label, TRUE, opt);
    IF Has(res, MuBase.ResActive) THEN
        lay := CurLayout(ctx);
        lay.indent := lay.indent + ctx.style.indent;
        ctx.idItems[ctx.idIdx] := ctx.lastId;
        INC(ctx.idIdx)
    END;

    RETURN res
END BeginTreeNodeEx;


PROCEDURE BeginTreeNode* (ctx: Context; label: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN BeginTreeNodeEx(ctx, label, 0)
END BeginTreeNode;


PROCEDURE EndTreeNode* (ctx: Context);
VAR
    lay: LayoutPtr;

BEGIN
    lay := CurLayout(ctx);
    lay.indent := lay.indent - ctx.style.indent;
    PopId(ctx)
END EndTreeNode;


(*============================================================================
   scrollbars
   ==========================================================================*)

(* Scrollbar - one scrollbar.  The C original is a macro invoked twice with
   the axes swapped; here `vertical` says which way round it is.  `csy` is the
   content size along the scrolling axis, and `bh` the body's extent along
   it. *)
PROCEDURE Scrollbar (ctx: Context; cntIdx: INTEGER; VAR body: MuBase.Rect;
                     csy: INTEGER; vertical: BOOLEAN);
VAR
    base, thumb: MuBase.Rect;
    id: MuBase.Id;
    bh, maxscroll, sc: INTEGER;

BEGIN
    IF vertical THEN bh := body.h ELSE bh := body.w END;
    maxscroll := csy - bh;
    IF (maxscroll > 0) & (bh > 0) THEN
        IF vertical THEN
            id := GetIdStr(ctx, "!scrollbary")
        ELSE
            id := GetIdStr(ctx, "!scrollbarx")
        END;
        base := body;
        IF vertical THEN
            base.x := body.x + body.w;
            base.w := ctx.style.scrollbarSize
        ELSE
            base.y := body.y + body.h;
            base.h := ctx.style.scrollbarSize
        END;
        UpdateControl(ctx, id, base, 0);
        IF (ctx.focus = id) & (ctx.mouseDown = MuBase.MouseLeft) THEN
            IF vertical THEN
                ctx.containers[cntIdx].scroll.y :=
                    ctx.containers[cntIdx].scroll.y +
                    ctx.mouseDelta.y * csy DIV base.h
            ELSE
                ctx.containers[cntIdx].scroll.x :=
                    ctx.containers[cntIdx].scroll.x +
                    ctx.mouseDelta.x * csy DIV base.w
            END
        END;
        IF vertical THEN
            ctx.containers[cntIdx].scroll.y :=
                MuBase.Clamp(ctx.containers[cntIdx].scroll.y, 0, maxscroll)
        ELSE
            ctx.containers[cntIdx].scroll.x :=
                MuBase.Clamp(ctx.containers[cntIdx].scroll.x, 0, maxscroll)
        END;
        ctx.drawFrame(ctx, base, MuBase.ColorScrollBase);
        thumb := base;
        IF vertical THEN
            thumb.h := MuBase.Max(ctx.style.thumbSize, base.h * bh DIV csy);
            thumb.y := thumb.y + ctx.containers[cntIdx].scroll.y *
                       (base.h - thumb.h) DIV maxscroll
        ELSE
            thumb.w := MuBase.Max(ctx.style.thumbSize, base.w * bh DIV csy);
            thumb.x := thumb.x + ctx.containers[cntIdx].scroll.x *
                       (base.w - thumb.w) DIV maxscroll
        END;
        sc := MuBase.ColorScrollThumb;
        IF ctx.focus = id THEN
            sc := Shade(ctx, MuBase.ColorScrollThumbFocus, sc)
        ELSIF MouseOver(ctx, thumb) THEN
            sc := Shade(ctx, MuBase.ColorScrollThumbHover, sc)
        END;
        ctx.drawFrame(ctx, thumb, sc);
        IF MouseOver(ctx, body) THEN ctx.scrollTarget := cntIdx END
    ELSE
        IF vertical THEN
            ctx.containers[cntIdx].scroll.y := 0
        ELSE
            ctx.containers[cntIdx].scroll.x := 0
        END
    END
END Scrollbar;


PROCEDURE Scrollbars (ctx: Context; cntIdx: INTEGER; VAR body: MuBase.Rect);
VAR
    sz, csx, csy: INTEGER;

BEGIN
    sz := ctx.style.scrollbarSize;
    csx := ctx.containers[cntIdx].contentSize.x + ctx.style.padding * 2;
    csy := ctx.containers[cntIdx].contentSize.y + ctx.style.padding * 2;
    PushClipRect(ctx, body);
    IF csy > ctx.containers[cntIdx].body.h THEN body.w := body.w - sz END;
    IF csx > ctx.containers[cntIdx].body.w THEN body.h := body.h - sz END;
    Scrollbar(ctx, cntIdx, body, csy, TRUE);
    Scrollbar(ctx, cntIdx, body, csx, FALSE);
    PopClipRect(ctx)
END Scrollbars;


PROCEDURE PushContainerBody (ctx: Context; cntIdx: INTEGER;
                             body: MuBase.Rect; opt: INTEGER);
VAR
    b, padded: MuBase.Rect;

BEGIN
    (* the scrollbars take width and height off their own copy of the body,
       so that the container keeps the rectangle it was given *)
    b := body;
    IF ~Has(opt, MuBase.OptNoScroll) THEN Scrollbars(ctx, cntIdx, b) END;
    MuBase.ExpandRect(padded, b, -ctx.style.padding);
    PushLayout(ctx, padded, ctx.containers[cntIdx].scroll);
    ctx.containers[cntIdx].body := b
END PushContainerBody;


(*============================================================================
   windows, popups and panels
   ==========================================================================*)

PROCEDURE BeginWindowEx* (ctx: Context; title: ARRAY OF CHAR;
                          rect: MuBase.Rect; opt: INTEGER): INTEGER;
VAR
    body, tr, r, wr: MuBase.Rect;
    id, tid: MuBase.Id;
    cntIdx, sz, res: INTEGER;
    c: MuBase.Color;
    lay: LayoutPtr;

BEGIN
    res := 0;
    id := GetIdStr(ctx, title);
    cntIdx := GetContainer(ctx, id, opt);
    IF (cntIdx # NoIndex) & ctx.containers[cntIdx].open THEN
        ctx.idItems[ctx.idIdx] := id;
        INC(ctx.idIdx);

        IF ctx.containers[cntIdx].rect.w = 0 THEN
            ctx.containers[cntIdx].rect := rect
        END;
        BeginRootContainer(ctx, cntIdx);
        (* the window's rectangle as it now stands - the title bar may have
           moved it since the frame began *)
        wr := ctx.containers[cntIdx].rect;
        body := wr;

        (* Draw the frame.  A popup is a window with no title, no resize and
           no close, and a dropdown's list is the commonest one there is; it
           gets a body colour of its own so that a theme can frame a menu
           differently from the window the menu came out of.  The two default
           to the same colour. *)
        IF ~Has(opt, MuBase.OptNoFrame) THEN
            IF Has(opt, MuBase.OptPopup) THEN
                ctx.drawFrame(ctx, wr, MuBase.ColorPopupBG)
            ELSE
                ctx.drawFrame(ctx, wr, MuBase.ColorWindowBG)
            END
        END;

        (* title bar *)
        IF ~Has(opt, MuBase.OptNoTitle) THEN
            tr := wr;
            tr.h := ctx.style.titleHeight;
            ctx.drawFrame(ctx, tr, MuBase.ColorTitleBG);

            tid := GetIdStr(ctx, "!title");
            UpdateControl(ctx, tid, tr, opt);
            DrawControlText(ctx, title, tr, MuBase.ColorTitleBG, opt);
            IF (tid = ctx.focus) & (ctx.mouseDown = MuBase.MouseLeft) THEN
                ctx.containers[cntIdx].rect.x :=
                    ctx.containers[cntIdx].rect.x + ctx.mouseDelta.x;
                ctx.containers[cntIdx].rect.y :=
                    ctx.containers[cntIdx].rect.y + ctx.mouseDelta.y
            END;
            body.y := body.y + tr.h;
            body.h := body.h - tr.h;

            (* close button *)
            IF ~Has(opt, MuBase.OptNoClose) THEN
                tid := GetIdStr(ctx, "!close");
                MuBase.MakeRect(r, tr.x + tr.w - tr.h, tr.y, tr.h, tr.h);
                tr.w := tr.w - r.w;
                (* Updated before it is drawn, so the box shows the state the
                   pointer is in THIS frame rather than the last one's.  The
                   click test below reads the same focus this set. *)
                UpdateControl(ctx, tid, r, opt);
                IF Visible(ctx, MuBase.ColorTitleBtn) THEN
                    DrawControlFrame(ctx, tid, r, MuBase.ColorTitleBtn, 0)
                END;
                Ink(ctx, MuBase.ColorTitleBtn, c);
                DrawIcon(ctx, MuBase.IconClose, r, c);
                IF (ctx.mousePressed = MuBase.MouseLeft) & (tid = ctx.focus) THEN
                    ctx.containers[cntIdx].open := FALSE
                END
            END
        END;

        PushContainerBody(ctx, cntIdx, body, opt);

        (* resize handle *)
        IF ~Has(opt, MuBase.OptNoResize) THEN
            sz := ctx.style.titleHeight;
            tid := GetIdStr(ctx, "!resize");
            MuBase.MakeRect(r, wr.x + wr.w - sz, wr.y + wr.h - sz, sz, sz);
            UpdateControl(ctx, tid, r, opt);
            (* The grip is drawn only when a theme gives it a colour; on an
               unthemed program it is the invisible target it always was. *)
            IF Visible(ctx, MuBase.ColorGrip) THEN
                DrawControlFrame(ctx, tid, r, MuBase.ColorGrip, 0)
            END;
            IF (tid = ctx.focus) & (ctx.mouseDown = MuBase.MouseLeft) THEN
                ctx.containers[cntIdx].rect.w :=
                    MuBase.Max(96, ctx.containers[cntIdx].rect.w + ctx.mouseDelta.x);
                ctx.containers[cntIdx].rect.h :=
                    MuBase.Max(64, ctx.containers[cntIdx].rect.h + ctx.mouseDelta.y)
            END
        END;

        (* resize to the content size *)
        IF Has(opt, MuBase.OptAutoSize) THEN
            lay := CurLayout(ctx);
            ctx.containers[cntIdx].rect.w :=
                ctx.containers[cntIdx].contentSize.x +
                (ctx.containers[cntIdx].rect.w - lay.body.w);
            ctx.containers[cntIdx].rect.h :=
                ctx.containers[cntIdx].contentSize.y +
                (ctx.containers[cntIdx].rect.h - lay.body.h)
        END;

        (* a popup closes when a click lands outside it *)
        IF Has(opt, MuBase.OptPopup) & (ctx.mousePressed # 0) &
           (ctx.hoverRoot # cntIdx) THEN
            ctx.containers[cntIdx].open := FALSE
        END;

        PushClipRect(ctx, ctx.containers[cntIdx].body);
        res := MuBase.ResActive
    END;

    RETURN res
END BeginWindowEx;


PROCEDURE BeginWindow* (ctx: Context; title: ARRAY OF CHAR;
                        rect: MuBase.Rect): INTEGER;
BEGIN
    RETURN BeginWindowEx(ctx, title, rect, 0)
END BeginWindow;


PROCEDURE EndWindow* (ctx: Context);
BEGIN
    PopClipRect(ctx);
    EndRootContainer(ctx)
END EndWindow;


PROCEDURE OpenPopup* (ctx: Context; name: ARRAY OF CHAR);
VAR
    cntIdx: INTEGER;

BEGIN
    cntIdx := GetContainerByName(ctx, name);
    ctx.hoverRoot := cntIdx;
    ctx.nextHoverRoot := cntIdx;
    MuBase.MakeRect(ctx.containers[cntIdx].rect,
                    ctx.mousePos.x, ctx.mousePos.y, 1, 1);
    ctx.containers[cntIdx].open := TRUE;
    BringToFront(ctx, cntIdx)
END OpenPopup;


PROCEDURE BeginPopup* (ctx: Context; name: ARRAY OF CHAR): INTEGER;
VAR
    r: MuBase.Rect;
    opt: INTEGER;

BEGIN
    opt := MuBase.OptPopup + MuBase.OptAutoSize + MuBase.OptNoResize +
           MuBase.OptNoScroll + MuBase.OptNoTitle + MuBase.OptClosed;
    MuBase.MakeRect(r, 0, 0, 0, 0);

    RETURN BeginWindowEx(ctx, name, r, opt)
END BeginPopup;


PROCEDURE EndPopup* (ctx: Context);
BEGIN
    EndWindow(ctx)
END EndPopup;


PROCEDURE BeginPanelEx* (ctx: Context; name: ARRAY OF CHAR; opt: INTEGER);
VAR
    cntIdx: INTEGER;
    r: MuBase.Rect;

BEGIN
    PushIdStr(ctx, name);
    cntIdx := GetContainer(ctx, ctx.lastId, opt);
    LayoutNext(ctx, r);
    IF cntIdx # NoIndex THEN
        ctx.containers[cntIdx].rect := r;
        IF ~Has(opt, MuBase.OptNoFrame) THEN
            ctx.drawFrame(ctx, ctx.containers[cntIdx].rect, MuBase.ColorPanelBG)
        END;
        ctx.contItems[ctx.contIdx] := cntIdx;
        INC(ctx.contIdx);
        PushContainerBody(ctx, cntIdx, ctx.containers[cntIdx].rect, opt);
        PushClipRect(ctx, ctx.containers[cntIdx].body)
    END
END BeginPanelEx;


PROCEDURE BeginPanel* (ctx: Context; name: ARRAY OF CHAR);
BEGIN
    BeginPanelEx(ctx, name, 0)
END BeginPanel;


PROCEDURE EndPanel* (ctx: Context);
BEGIN
    PopClipRect(ctx);
    PopContainer(ctx)
END EndPanel;


BEGIN
    MuBase.MakeRect(unclippedRect, 0, 0, 1000000H, 1000000H);
    unusedWidths[0] := 0
END Microui.
