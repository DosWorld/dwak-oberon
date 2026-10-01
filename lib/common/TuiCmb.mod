MODULE TuiCmb;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A combo box: a one-row face that shows the chosen item, and a drop-down of
   the items below it while it is open.

   It owns no items.  The owner hands it two procedures at creation - one that
   answers how many there are and one that fills a buffer with the i-th - and
   the widget reads through them every time it needs either, so the list can
   change under it and there is nothing here to keep in step.  That also means a
   count is never cached: every use re-reads it, which is why nothing has to
   tell this widget that its data moved.

   Each callback takes the widget as its first argument, and it has to be
   written that way at the call site: a procedure-typed record field has no
   implicit receiver in this dialect, so the widget passes itself.  That is the
   same shape the compiler's own parser uses for its callback slot, and it is
   what lets the callback reach the widget it belongs to.

   The two callbacks are called with the widget and nothing else, so on their own
   they cannot see the record their owner built them in.  The environment is what
   closes that gap: the owner hands one pointer to Create, the widget keeps it
   and never looks inside it, and a callback reads it back as self.env and casts
   it to whatever its owner put there.  The cast is the owner's business; this is
   the one field here the widget itself never dereferences.

   It is typed TuiWidg.Widget because that is the framework's one base pointer -
   a pointer to anything at all would need SYSTEM.PTR, which this dialect does
   not have - and because what a combo box reads is normally a list, which is
   one.  An owner whose data is not a widget extends TuiWidg.WidgetDesc, whose
   record is deliberately data only.  Reading it back is a type guard, the
   idiom the rest of this dialect uses for a base pointer:

       IF self.env IS TuiList.ListBox THEN
           src := self.env(TuiList.ListBox);
           ...
       END

   IS answers FALSE for NIL, so a box whose environment was never set declines
   rather than traps - the same thing NItems promises for a callback that was
   never set.

   Because the environment travels with the widget, one pair of callbacks serves
   any number of boxes: an owner with two combos over two different lists hands
   the same two procedures to both and lets the environment say which list.

   The drop-down stays inside the window.  Nothing here draws past the widget's
   own rectangle deliberately, and the framework does the rest: a canvas clips
   every cell written to it, so a box that reaches the window's last row is cut
   there by construction, with no overlay and no change to Tui.  The window is
   sized so that six items fit; a shorter one cuts them, which is a cosmetic
   cut and never a trap.

   That choice has one consequence, stated rather than hidden: the desktop gets
   the first look at every event, so F6 and dragging stay live while the box is
   open.  The application closes it when the focus leaves, which is the only
   thing the framework offers in place of a pop-up that owns the input. *)

IMPORT TuiCanv, Events, Strings, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST
    MAXVISIBLE = 6;                 (* item rows the box shows at once *)
    FRAME = 2;                      (* rows its frame takes, top and bottom *)
    BARCOLS = 1;                    (* columns its scrollbar takes *)

TYPE

    ComboBox* = POINTER TO ComboBoxDesc;

    (* The two the owner supplies.  Both take the widget, because a
       procedure-typed field is called with its receiver written out. *)
    CountProc* = PROCEDURE (self: ComboBox): INTEGER;
    ItemProc*  = PROCEDURE (self: ComboBox; idx: INTEGER;
                            VAR dst: ARRAY OF CHAR);

    ComboBoxDesc* = RECORD (TuiWidg.WidgetDesc)

        (* The owner's, handed back to both callbacks and never read here.  It
           is exported so an owner can re-point a box at another source, which
           is safe precisely because nothing in this module looks at it. *)
        env*: TuiWidg.Widget;

        sel*: INTEGER;              (* which of the owner's items is chosen *)
        open*: BOOLEAN;             (* the drop-down is down *)
        item: INTEGER;              (* the row the highlight is on *)
        top: INTEGER;               (* the drop-down's first visible row *)
        saved: INTEGER;             (* what a cancel puts back *)
        cmd*: INTEGER;              (* the id the owner is told when it commits,
                                       handed to the window that owns it *)

        (* Read afresh at every use - the owner's list is not ours to keep. *)
        GetItemsCount*: CountProc;
        GetItem*:       ItemProc;

        (* The window that owns it.  A host of NIL is a box nobody owns but its
           maker - a dialog's - and it is then up to that maker to place it,
           paint it and free it. *)
        host: TuiWin.Window;

        draw*:     PROCEDURE (self: ComboBox; target: TuiCanv.Canvas);
        DrawDrop*: PROCEDURE (self: ComboBox; target: TuiCanv.Canvas);
        onEvent*:  PROCEDURE (self: ComboBox; VAR e: Events.Event): BOOLEAN;
        Select*:   PROCEDURE (self: ComboBox; i: INTEGER);
        Open*:     PROCEDURE (self: ComboBox);
        Close*:    PROCEDURE (self: ComboBox);
        SetPos*:   PROCEDURE (self: ComboBox; x, y: INTEGER)
    END;


(* How many items the owner says it has.  A widget whose callbacks were never
   set answers none rather than trapping, and a negative answer is read as none
   so that the clamping below has one shape. *)
PROCEDURE NItems (self: ComboBox): INTEGER;
VAR n: INTEGER;
BEGIN
    n := 0;
    IF self.GetItemsCount # NIL THEN
        n := self.GetItemsCount(self)
    END;
    IF n < 0 THEN n := 0 END;
    RETURN n
END NItems;


(* The i-th item's text.  An index outside the owner's range answers an empty
   string, so a caller with a stale index has nothing to test. *)
PROCEDURE ItemText (self: ComboBox; i: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN
    dst[0] := 0X;
    IF (self.GetItem # NIL) & (i >= 0) & (i < NItems(self)) THEN
        self.GetItem(self, i, dst)
    END
END ItemText;


PROCEDURE ClampSel (self: ComboBox);
VAR n: INTEGER;
BEGIN
    n := NItems(self);
    IF self.sel > n - 1 THEN self.sel := n - 1 END;
    IF self.sel < 0 THEN self.sel := 0 END
END ClampSel;


(* Item rows there is room for, and never fewer than one: a box with no row at
   all would have nowhere to draw its frame from. *)
PROCEDURE Visible (self: ComboBox): INTEGER;
VAR r: INTEGER;
BEGIN
    r := NItems(self);
    IF r > MAXVISIBLE THEN r := MAXVISIBLE END;
    IF r < 1 THEN r := 1 END;
    RETURN r
END Visible;


(* Keep the highlighted row on show, by TuiList' double clamp - which is also what
   makes the view follow the highlight rather than the other way round. *)
PROCEDURE EnsureTop (self: ComboBox; rows: INTEGER);
VAR n: INTEGER;
BEGIN
    n := NItems(self);
    IF self.item < self.top THEN
        self.top := self.item
    END;
    IF self.item >= self.top + rows THEN
        self.top := self.item - rows + 1
    END;
    IF self.top > n - rows THEN
        self.top := n - rows
    END;
    IF self.top < 0 THEN self.top := 0 END
END EnsureTop;


(* The bar's size and where it starts.  Both divisions are inside the one branch
   that has a denominator, so neither can be zero. *)
PROCEDURE Thumb (self: ComboBox; VAR size, ofs: INTEGER);
VAR rows, n: INTEGER;
BEGIN
    n := NItems(self);
    rows := Visible(self);
    IF n <= rows THEN
        size := rows;
        ofs := 0
    ELSE
        size := rows * rows DIV n;
        IF size < 1 THEN size := 1 END;
        ofs := self.top * (rows - size) DIV (n - rows);
        IF ofs > rows - size THEN ofs := rows - size END;
        IF ofs < 0 THEN ofs := 0 END
    END
END Thumb;


(* The pair the face is drawn in.  Open is a selection in progress and takes the
   loudest of the three; focused and closed takes the idle one, which is what
   says which widget the arrows are on without a status line. *)
PROCEDURE FaceAttr (self: ComboBox): INTEGER;
VAR a: INTEGER;
BEGIN
    IF self.open THEN
        a := TuiTheme.Attr(TuiTheme.ComboSel)
    ELSIF self.focused THEN
        a := TuiTheme.Attr(TuiTheme.ComboSelIdle)
    ELSE
        a := TuiTheme.Attr(TuiTheme.Combo)
    END;
    RETURN a
END FaceAttr;


(* The face: one row, the chosen item clipped to the cell before the arrow, and
   the arrow itself - pointing down when there is something to open and up when
   there is something to put away. *)
PROCEDURE draw (self: ComboBox; target: TuiCanv.Canvas);
VAR a, w: INTEGER; s: ARRAY 64 OF CHAR; ch: TuiCanv.Char;
BEGIN
    IF self.visible THEN
        ClampSel(self);
        a := FaceAttr(self);
        w := self.width;
        target.Fill(target, self.x, self.y, w, 1, " ", a);
        ItemText(self, self.sel, s);
        (* THE CANVAS'S OWN TEXT PRIMITIVE, and not a loop over the bytes.  One
           byte is one cell in every page but one - which is why a byte loop was
           right here for as long as the tree had one page - and on the UTF-8
           page a character is one to four of them.  The loop this replaces drew
           each byte through CharOf, so a two-byte letter came out as two cells
           of somebody else's alphabet: the item is drawn as mojibake while the
           list beside it, which already goes through Print, is drawn correctly.
           Print is where the page is read and the two cases are told apart, so
           the decision is made in one place and this is not a second copy of it.

           The clip is kept and is by bytes, as a list clips a row: a byte string
           is never shorter than the cells it makes, so a clip at w-1 bytes can
           only leave the face short of its end and never write past it. *)
        IF Strings.Length(s) > w - 1 THEN s[w - 1] := 0X END;
        target.Print(target, self.x, self.y, s, a);
        IF w >= 2 THEN
            IF self.open THEN
                ch := TuiCanv.ARROW_UP
            ELSE
                ch := TuiCanv.ARROW_DOWN
            END;
            target.Put(target, self.x + w - 1, self.y, ch, a)
        END
    END
END draw;


(* The box, drawn over the rows below the face and into the same canvas - which
   is what makes it a drop-down that cannot escape its window.  The owner draws
   this after everything else in the window, and within one canvas that order is
   the z-order.

   The frame goes first and the rows are filled over it, so a box taller than
   the rows it has leaves the frame's colour behind rather than whatever was on
   the desk. *)
PROCEDURE DrawDrop (self: ComboBox; target: TuiCanv.Canvas);
VAR
    fa, a, sa, ba, n, rows, tw, i, idx, ab, size, ofs: INTEGER;
    s: ARRAY 64 OF CHAR;
BEGIN
    IF self.visible & self.open THEN
        n := NItems(self);
        rows := Visible(self);
        fa := TuiTheme.Attr(TuiTheme.ComboFrame);
        a := TuiTheme.Attr(TuiTheme.ComboList);
        sa := TuiTheme.Attr(TuiTheme.ComboListSel);
        ba := TuiTheme.Attr(TuiTheme.ComboBar);
        target.Frame(target, self.x, self.y + 1, self.width, rows + FRAME,
                     fa, FALSE);
        tw := self.width - 2;
        IF n > MAXVISIBLE THEN DEC(tw, BARCOLS) END;
        IF tw < 1 THEN tw := 1 END;
        FOR i := 0 TO rows - 1 DO
            idx := self.top + i;
            IF idx < n THEN
                IF idx = self.item THEN ab := sa ELSE ab := a END;
                target.Fill(target, self.x + 1, self.y + 2 + i,
                            self.width - 2, 1, " ", ab);
                ItemText(self, idx, s);
                (* the same correction as the face: Print reads the page and
                   decodes, a byte loop cannot.  The clip is by bytes for the
                   same reason - see draw above. *)
                IF Strings.Length(s) > tw THEN s[tw] := 0X END;
                target.Print(target, self.x + 1, self.y + 2 + i, s, ab)
            END
        END;
        IF n > MAXVISIBLE THEN
            Thumb(self, size, ofs);
            FOR i := 0 TO rows - 1 DO
                IF (i >= ofs) & (i < ofs + size) THEN
                    target.Put(target, self.x + self.width - 2,
                               self.y + 2 + i, TuiCanv.BLOCK, ba)
                ELSE
                    target.Put(target, self.x + self.width - 2,
                               self.y + 2 + i, TuiCanv.SHADE_LIGHT, ba)
                END
            END
        END
    END
END DrawDrop;


(* Which item row a point is on, or -1 for anything else - the frame, the bar's
   column, the face, or outside the box. *)
PROCEDURE RowAt (self: ComboBox; x, y: INTEGER): INTEGER;
VAR i, n, rows: INTEGER;
BEGIN
    i := -1;
    n := NItems(self);
    rows := Visible(self);
    IF (x >= self.x + 1) & (x <= self.x + self.width - 2) &
       (y >= self.y + 2) & (y <= self.y + rows + 1) THEN
        i := self.top + y - self.y - 2;
        IF i > n - 1 THEN i := -1 END
    END;
    RETURN i
END RowAt;


(* Open on the chosen item, remembering what to put back if this is cancelled.
   A box that opens on nothing - the highlight at the top and the view scrolled
   to wherever the chosen item is - would be a box the user has to hunt in. *)
PROCEDURE Open (self: ComboBox);
BEGIN
    ClampSel(self);
    self.saved := self.sel;
    self.item := self.sel;
    self.open := TRUE;
    EnsureTop(self, Visible(self))
END Open;


PROCEDURE Close (self: ComboBox);
BEGIN
    self.open := FALSE
END Close;


(* Two states, and the difference between them is the whole of the modality
   available here.

   Closed: a press on the face opens it whether or not it has the focus - a
   click is the choice, the rule every widget here follows - while the keys that
   open it are gated on the focus, because a key has to be aimed at something.
   Everything else is declined, and declining is free: a closed box passed over
   in a walk costs one event kind test.

   Open: it takes everything, as a dialog does, and that is deliberate.  The
   desktop has already had its look, so this is the only way a drop-down can be
   modal at all - and it is exactly the case it must be modal in, because
   TuiList.onEvent has no focus test of its own and a list behind an open box
   would otherwise take the very arrows the box is walking with.

   A commit is Enter and a press on an item row, and both leave the id for the
   owner to read.  A cancel is Esc and a press anywhere else, and both put back
   what the box opened on.  Keying the highlight, and scrolling with it, is
   neither: nothing has happened yet. *)
PROCEDURE onEvent (self: ComboBox; VAR e: Events.Event): BOOLEAN;
VAR hit: BOOLEAN; n, rows, i: INTEGER;
BEGIN
    hit := FALSE;
    IF self.open THEN
        hit := TRUE;
        rows := Visible(self);
        n := NItems(self);
        IF e.kind = Events.KEYBOARD THEN
            IF Events.IsKey(e, Events.K_ESC) THEN
                self.sel := self.saved;
                self.open := FALSE
            ELSIF Events.IsKey(e, Events.K_ENTER) THEN
                (* the highlight is what is being chosen, and it is not sel
                   until this line: moving it is not choosing it *)
                self.sel := self.item;
                self.open := FALSE;
                TuiWin.Notify(self.host, self, self.cmd)
            ELSIF Events.IsKey(e, Events.K_UP) THEN
                DEC(self.item);
                IF self.item < 0 THEN self.item := 0 END
            ELSIF Events.IsKey(e, Events.K_DOWN) THEN
                INC(self.item);
                IF self.item > n - 1 THEN self.item := n - 1 END
            ELSIF Events.IsKey(e, Events.K_HOME) THEN
                self.item := 0
            ELSIF Events.IsKey(e, Events.K_END) THEN
                self.item := n - 1
            ELSIF Events.IsKey(e, Events.K_PGUP) THEN
                DEC(self.item, rows);
                IF self.item < 0 THEN self.item := 0 END
            ELSIF Events.IsKey(e, Events.K_PGDN) THEN
                INC(self.item, rows);
                IF self.item > n - 1 THEN self.item := n - 1 END
            END;
            EnsureTop(self, rows)
        ELSIF e.kind = Events.MOUSE THEN
            IF Events.IsPress(e) THEN
                i := RowAt(self, e.x, e.y);
                IF i >= 0 THEN
                    self.item := i;
                    self.sel := i;
                    TuiWin.Notify(self.host, self, self.cmd)
                ELSE
                    self.sel := self.saved
                END;
                self.open := FALSE
            END
        END
    ELSIF Events.IsPress(e) & TuiWidg.Inside(self, e.x, e.y) THEN
        Open(self);
        hit := TRUE
    ELSIF self.focused THEN
        IF Events.IsKey(e, Events.K_SPACE) OR Events.IsKey(e, Events.K_DOWN) OR
           Events.IsKey(e, Events.K_ENTER) THEN
            Open(self);
            hit := TRUE
        END
    END;
    IF hit THEN
        e.kind := Events.NONE
    END;
    RETURN hit
END onEvent;


(* The two ways in for a router that does not know what kind of widget this is:
   take an event, and take the keyboard on or off.  Both are declared for
   TuiWidg.Widget, which is what a window's ring holds, and both narrow back to
   a box before doing anything - the guard on the type, the cast for the fields.

   focused is set and never hot: a box is drawn hot from its own open flag, which
   is what says a pull-down is down, and the keyboard being on it is a different
   thing that must not make it look open. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR c: ComboBox;
BEGIN
    IF w IS ComboBox THEN
        c := w(ComboBox);
        c.focused := on
    END
END Take;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR c: ComboBox; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS ComboBox THEN
        c := w(ComboBox);
        r := c.onEvent(c, e)
    END;
    RETURN r
END Handle;


(* Choose without firing anything: this is how the owner puts the box in step
   with what it stands for, which is not the user choosing and must not come
   back as a command. *)
PROCEDURE Select (self: ComboBox; i: INTEGER);
BEGIN
    self.sel := i;
    ClampSel(self)
END Select;


PROCEDURE SetPos (self: ComboBox; x, y: INTEGER);
BEGIN
    self.x := x;
    self.y := y
END SetPos;


(* Give the box back.  The callbacks belong to the owner and the items were
   never ours, so this is one line - and it stands before Create for the reason
   it does everywhere else here: Create binds it into the record's Done field,
   and a procedure has to be declared before it is used. *)
PROCEDURE DoneComboBox (self: Oberon.Object);
VAR c: ComboBox;
BEGIN
    c := self(ComboBox);
    DISPOSE(c)
END DoneComboBox;


(* Where it draws itself, for a window that paints what it owns: the face, and
   then the drop-down over the rows below it when it is down.

   The two calls in one adapter are the z-order the owner used to write out by
   hand.  A canvas is written cell by cell and what is drawn later is on top, so
   the box must be drawn after the face and before whatever the window owns after
   this widget - which is what ownership (creation) order gives, because the box
   was created after the rows it covers.  DrawDrop is gated on open itself, so
   nothing is drawn while the box is shut. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR c: ComboBox;
BEGIN
    IF w IS ComboBox THEN
        c := w(ComboBox);
        c.draw(c, target);
        c.DrawDrop(c, target)
    END
END Paint;


(* The environment is a parameter and not a field the owner sets afterwards,
   because the callbacks arrive here with it: a box that could be created with
   callbacks and no environment would have a window in which they answer for
   nothing.  It stands before them for the same reason it is asked for first -
   it is the context they are read in. *)
PROCEDURE Create* (x, y, w: INTEGER; env: TuiWidg.Widget;
                   getCount: CountProc; getItem: ItemProc;
                   cmd: INTEGER; host: TuiWin.Window): ComboBox;
VAR c: ComboBox;
BEGIN
    ASSERT(w >= 3);
    NEW(c);
    c.x := x;
    c.y := y;
    c.width := w;
    c.height := 1;
    c.visible := TRUE;
    c.focused := FALSE;
    c.canvas := NIL;
    c.env := env;
    c.sel := 0;
    c.open := FALSE;
    c.item := 0;
    c.top := 0;
    c.saved := 0;
    c.cmd := cmd;
    c.lastCmd := 0;
    c.host := host;
    c.GetItemsCount := getCount;
    c.GetItem := getItem;
    c.draw := draw;
    c.DrawDrop := DrawDrop;
    c.onEvent := onEvent;
    c.handler := Handle;
    c.taker := Take;
    c.painter := Paint;
    c.onCommand := NIL;                 (* a box fires ids, it does not take them *)
    c.Select := Select;
    c.Open := Open;
    c.Close := Close;
    c.SetPos := SetPos;
    c.Done := DoneComboBox;
    TuiWin.Own(host, c);
    RETURN c
END Create;

END TuiCmb.
