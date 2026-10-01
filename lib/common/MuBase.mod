(* MuBase - the value types, the constants and the geometry the microui port
   shares.

   A port of rxi's microui 2.02 (https://github.com/rxi/microui, MIT licence)
   to Oberon-07.  This module holds what microui.h declares in its enum and
   type blocks, so that the library core and the renderer both build on it
   without either importing the other:

       MuBase     types, constants, geometry      (this module)
       MuAtlas    the font atlas                  (generated)
       Microui    the library                     imports MuBase
       MuRender   the software renderer           imports all three
       MuHost     one per target                  imports MuBase and MuRender

   A note on shape.  The C original returns mu_Rect, mu_Vec2 and mu_Color by
   value, and calls mu_rect(...) inside expressions all over the place.  A
   procedure here may only return a basic type, so every one of those becomes
   a call that writes its result through a leading VAR parameter:

       mu_Rect r = mu_rect(x, y, w, h);        MakeRect(r, x, y, w, h)

   The result is the first parameter of every such procedure.
*)
MODULE MuBase;


CONST
    (* The microui release this is a port of. *)
    Version* = "2.02";

    (* What mu_check_clip answers.  The library uses 0 for "fully inside". *)
    ClipNone* = 0;
    ClipPart* = 1;
    ClipAll*  = 2;

    (* command types, as they appear in a Command's typ field *)
    CmdJump* = 1;
    CmdClip* = 2;
    CmdRect* = 3;
    CmdText* = 4;
    CmdIcon* = 5;

    (* style colours - the index mu_draw_control_frame offsets by 0, 1 or 2
       to pick the idle, hovered or focused shade of a control.

       Every one of these is a FILL.  What is painted besides the fill - the
       frame around it, the light and dark of a 3D bevel, the ink on it, the
       shadow it drops - is a Part, and there is one Part per colour below.
       See the Part record for what that means and PartMax for how many
       there are. *)
    ColorText*        = 0;
    ColorBorder*      = 1;
    ColorWindowBG*    = 2;
    ColorTitleBG*     = 3;
    ColorTitleText*   = 4;
    ColorPanelBG*     = 5;
    ColorButton*      = 6;
    ColorButtonHover* = 7;
    ColorButtonFocus* = 8;
    ColorBase*        = 9;
    ColorBaseHover*   = 10;
    ColorBaseFocus*   = 11;
    ColorScrollBase*  = 12;
    ColorScrollThumb* = 13;

    (* Beyond microui's own fourteen.  The C library draws a close box, a
       resize grip, a scrollbar thumb and a run of selected text out of the
       colours it already has - the title's text, nothing at all, the button's
       and the text's - so none of the four can be given a colour of its own
       without a slot that microui.h does not declare.  Each of these defaults
       to TRANSPARENT, which is how every one of them is invisible on an
       unthemed program: the pixels a program drew before these existed are
       the pixels it draws now.  A theme turns them on. *)
    ColorTitleBtn*         = 14;   (* a title bar's close box *)
    ColorTitleBtnHover*    = 15;
    ColorTitleBtnFocus*    = 16;
    ColorGrip*             = 17;   (* the resize grip in a window's corner *)
    ColorSelect*           = 18;   (* the run of text a field has selected *)
    ColorScrollThumbHover* = 19;   (* a scrollbar's thumb, under the pointer *)
    ColorScrollThumbFocus* = 20;   (* and while it is being dragged *)
    ColorPopupBG*          = 21;   (* a popup's body - a dropdown's list *)

    ColorMax*         = 22;
    PartMax*          = ColorMax;

    (* The six fields of a Part, in the order they are declared, so that a
       table-driven reader can walk them.  A theme names them in an .ini as
       the tail of a dotted key - `button.border` - and a program that prints
       a style back out walks 0 to PartFields-1 and asks PartField for each. *)
    PartBorder* = 0;
    PartLight*  = 1;
    PartDark*   = 2;
    PartText*   = 3;
    PartShadow* = 4;
    PartCaret*  = 5;
    PartFields* = 6;

    (* the four icons the library draws, as the atlas holds them.  They are
       glyph indices into MuAtlas rather than pictures, so the renderer needs
       no table of its own. *)
    IconClose*     = 1;
    IconCheck*     = 2;
    IconCollapsed* = 3;
    IconExpanded*  = 4;
    IconMax*       = 5;

    (* results returned by the controls *)
    ResActive* = 1;
    ResSubmit* = 2;
    ResChange* = 4;

    (* control options *)
    OptAlignCenter* = 1;
    OptAlignRight*  = 2;
    OptNoInteract*  = 4;
    OptNoFrame*     = 8;
    OptNoResize*    = 10H;
    OptNoScroll*    = 20H;
    OptNoClose*     = 40H;
    OptNoTitle*     = 80H;
    OptHoldFocus*   = 100H;
    OptAutoSize*    = 200H;
    OptPopup*       = 400H;
    OptClosed*      = 800H;
    OptExpanded*    = 1000H;

    (* mouse buttons, as the bits mu_input_mousedown takes *)
    MouseLeft*   = 1;
    MouseRight*  = 2;
    MouseMiddle* = 4;

    (* keys, as the bits mu_input_keydown takes.

       Shift, control, alt, backspace and return are the whole set microui
       itself knows.  Everything from KeyLeft down is an extension this tree
       needs and microui.h does not have: a form designer nudges a boundary
       with the arrows, deletes with Delete, and reaches New, Open, Save,
       Export, Copy, Paste, Cut and Undo as control letters, and not one of
       those is expressible as any of the five above.  A bit is a bit
       whatever it is called, so a context that never asks for one of these
       behaves exactly as it did before they existed. *)
    KeyShift*     = 1;
    KeyCtrl*      = 2;
    KeyAlt*       = 4;
    KeyBackspace* = 8;
    KeyReturn*    = 10H;

    (* the extension, from here down - not microui.h *)
    KeyLeft*      = 20H;
    KeyRight*     = 40H;
    KeyUp*        = 80H;
    KeyDown*      = 100H;
    KeyDelete*    = 200H;

    (* the control letters the designer binds: Cut, Export, New, Open, Save,
       Paste, Copy, redo, Undo.  The letter alone is reported, not the
       combination - control is a bit of its own in the same word, so a
       context that cares tests for both. *)
    KeyC*         = 400H;
    KeyE*         = 800H;
    KeyN*         = 1000H;
    KeyO*         = 2000H;
    KeyS*         = 4000H;
    KeyV*         = 8000H;
    KeyX*         = 10000H;
    KeyY*         = 20000H;
    KeyZ*         = 40000H;
    KeyA*         = 80000H;

    (* The two ends of a line, which a text field moves its caret to and a
       list scrolls to.  They are not letters and are not control codes: a
       keyboard has a key for each that types nothing, so like an arrow the
       key itself is the only name it has. *)
    KeyHome*      = 100000H;
    KeyEnd*       = 200000H;

    (* microui hashes identifiers with 32-bit FNV-1a, whose offset basis
       2166136261 and running product both live above 2^31.  An id is an
       INTEGER here, and on a 32-bit target that is a signed 32-bit integer,
       so neither fits.  The hash therefore keeps FNV's multiplier and takes
       every step modulo 2^31 - 1, a prime, with the offset basis reduced the
       same way.  Ids are stable for the life of a process, which is all they
       are for; they are not guaranteed to match a 32-bit build's or the C
       original's.

       On a 32-bit target the running product overflows before the MOD takes
       it and wraps silently, so a win32 build and a win64 build hash the same
       string to different ids.  That is harmless - an id is only ever
       compared against other ids from the same context - but it does mean the
       two builds cannot be diffed by their command lists. *)
    HashInitial* = 18652614;   (* 2166136261 MOD 7FFFFFFFH *)
    HashPrime*   = 16777619;
    HashMod*     = 7FFFFFFFH;  (* 2^31 - 1 *)


TYPE
    Id*    = INTEGER;          (* an identifier: a hash, never zero-tested *)
    Vec2*  = RECORD x*, y*: INTEGER END;
    Rect*  = RECORD x*, y*, w*, h*: INTEGER END;
    Color* = RECORD r*, g*, b*, a*: BYTE END;

    (* Part - what a control is painted with besides its fill.

       microui's own model stops at the fill.  A control names one colour
       index, the core offsets it by one or two for the hovered and focused
       states, and mu_draw_control_frame paints that rectangle and then a
       one-pixel border around it - one border colour, shared by every control
       in the program, and no way to say that a window's frame is not a
       button's.  This is the rest of it.

       There is one Part per colour index (PartMax of them), so the partition
       is the same one the fills already use: ColorButton, ColorButtonHover
       and ColorButtonFocus are three fills and three Parts, and a theme that
       wants a button's hovered bevel to differ from its resting one can say
       so.  A Part whose fields are all transparent paints nothing but the
       fill, which is the state every one of them starts in - so an unthemed
       program draws exactly what it drew before Parts existed.

       The five fields, in the order DefaultFrame paints them:

           shadow  a one-pixel drop shadow, drawn UNDER the fill, offset one
                   pixel down and right.  Only the far edge shows: the fill
                   covers the rest.  a = 0 draws none.
           light   the top and left of a one-pixel 3D bevel, drawn just
           dark    outside the fill; dark is its bottom and right.  Together
                   they are what makes a control look raised.  a = 0 draws
                   neither, and the bevel is skipped whole.
           border  a one-pixel frame drawn outside the bevel, or outside the
                   fill when there is no bevel.  a = 0 draws none - which is
                   how a scrollbar and a title bar stay flat.
           text    the ink of anything drawn on this fill: a caption, a tick,
                   an icon, a field's own text.  a = 0 falls back to
                   ColorText, so a control that is not given one keeps the
                   program's text colour.
           caret   a text field's insertion bar.  a = 0 means the text colour,
                   and on a control that has no caret the field is unused.

       A theme fills these in; nothing else needs to know they exist.  The
       geometry is fixed at one pixel because that is the whole of microui's
       idiom - it has no metric for a thicker frame, and a bevel two pixels
       wide would need one. *)
    Part* = RECORD
        border*: Color;
        light*:  Color;
        dark*:   Color;
        text*:   Color;
        shadow*: Color;
        caret*:  Color
    END;



(* ---------------------------------------------------------------------------
   construction - microui's mu_vec2, mu_rect and mu_color.  They carry Make in
   their names because a procedure may not share a type's name here.
*)

PROCEDURE MakeVec2* (VAR v: Vec2; x, y: INTEGER);
BEGIN
    v.x := x; v.y := y
END MakeVec2;


PROCEDURE MakeRect* (VAR r: Rect; x, y, w, h: INTEGER);
BEGIN
    r.x := x; r.y := y; r.w := w; r.h := h
END MakeRect;


PROCEDURE MakeColor* (VAR c: Color; r, g, b, a: INTEGER);
BEGIN
    c.r := r; c.g := g; c.b := b; c.a := a
END MakeColor;


(* ---------------------------------------------------------------------------
   hashing - one FNV-1a step, which is all the identifier hash needs.  The
   caller walks whatever it is hashing: the bytes of a string, or the bytes of
   an address.
*)

PROCEDURE HashByte* (VAR h: Id; b: INTEGER);
VAR
    x: Id;

BEGIN
    (* There is no XOR operator here, and no bitwise one either: BITS turns
       each operand into a SET and `/` on sets is the symmetric difference,
       which is exactly an exclusive or.  Both operands stay below 2^31, so
       the result does too. *)
    x := ORD(BITS(h) / BITS(b MOD 256));
    h := (x * HashPrime) MOD HashMod
END HashByte;


(* ---------------------------------------------------------------------------
   geometry
*)

PROCEDURE Min* (a, b: INTEGER): INTEGER;
VAR
    r: INTEGER;

BEGIN
    IF a < b THEN r := a ELSE r := b END;

    RETURN r
END Min;


PROCEDURE Max* (a, b: INTEGER): INTEGER;
VAR
    r: INTEGER;

BEGIN
    IF a > b THEN r := a ELSE r := b END;

    RETURN r
END Max;


PROCEDURE Clamp* (x, a, b: INTEGER): INTEGER;
VAR
    r: INTEGER;

BEGIN
    r := x;
    IF r < a THEN r := a END;
    IF r > b THEN r := b END;

    RETURN r
END Clamp;


PROCEDURE ClampReal* (x, a, b: REAL): REAL;
VAR
    r: REAL;

BEGIN
    r := x;
    IF r < a THEN r := a END;
    IF r > b THEN r := b END;

    RETURN r
END ClampReal;


PROCEDURE ExpandRect* (VAR res: Rect; r: Rect; n: INTEGER);
BEGIN
    res.x := r.x - n;     res.y := r.y - n;
    res.w := r.w + n * 2; res.h := r.h + n * 2
END ExpandRect;


(* PartField - one field of a Part, by the index above.  A field index that
   is not one reads as a transparent colour rather than as a trap: a reader
   walking a table it built itself should not be able to fall off the end of
   it. *)
PROCEDURE PartField* (p: Part; f: INTEGER; VAR c: Color);
BEGIN
    MakeColor(c, 0, 0, 0, 0);
    CASE f OF
        PartBorder: c := p.border
    |   PartLight:  c := p.light
    |   PartDark:   c := p.dark
    |   PartText:   c := p.text
    |   PartShadow: c := p.shadow
    |   PartCaret:  c := p.caret
    END
END PartField;


(* PartSet - write one field of a Part, by the same index. *)
PROCEDURE PartSet* (VAR p: Part; f: INTEGER; c: Color);
BEGIN
    CASE f OF
        PartBorder: p.border := c
    |   PartLight:  p.light := c
    |   PartDark:   p.dark := c
    |   PartText:   p.text := c
    |   PartShadow: p.shadow := c
    |   PartCaret:  p.caret := c
    END
END PartSet;


PROCEDURE IntersectRects* (VAR res: Rect; a, b: Rect);
VAR
    x1, y1, x2, y2: INTEGER;

BEGIN
    x1 := Max(a.x, b.x);
    y1 := Max(a.y, b.y);
    x2 := Min(a.x + a.w, b.x + b.w);
    y2 := Min(a.y + a.h, b.y + b.h);
    IF x2 < x1 THEN x2 := x1 END;
    IF y2 < y1 THEN y2 := y1 END;
    res.x := x1; res.y := y1; res.w := x2 - x1; res.h := y2 - y1
END IntersectRects;


(* Overlaps - is the point p inside r?  The half-open test is microui's: the
   right and bottom edges are outside. *)
PROCEDURE Overlaps* (r: Rect; p: Vec2): BOOLEAN;
VAR
    res: BOOLEAN;

BEGIN
    res := (p.x >= r.x) & (p.x < r.x + r.w) & (p.y >= r.y) & (p.y < r.y + r.h);

    RETURN res
END Overlaps;


(* RectIsEmpty - true when there is nothing to draw. *)
PROCEDURE RectIsEmpty* (r: Rect): BOOLEAN;
VAR
    res: BOOLEAN;

BEGIN
    res := (r.w <= 0) OR (r.h <= 0);

    RETURN res
END RectIsEmpty;


END MuBase.
