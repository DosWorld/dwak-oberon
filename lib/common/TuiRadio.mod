MODULE TuiRadio;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A radio group: one item per row, the chosen one marked, and an id it carries.

   (o) for the item that is chosen and ( ) for the rest - the shape a radio
   group has everywhere, and one a text screen can draw as plainly as it draws
   a bracketed button.

   The group is deliberately not a scrolling widget.  It is a choice between a
   few things whose number is known when the program is written, so its height
   is its item count and the record holds the items itself; a choice that needs
   a scrollbar is a list, and TuiList is the widget for that.

   Up and Down move the choice while the group has the keyboard; a click on a
   row chooses that row.  Either way the id the owner reads is the one the group
   hands to its window, and the group fires nothing by itself - the same rule the
   buttons and the checkbox keep, so that one place in the application decides
   what a choice means.

   The group widens to the longest label it holds, so a row cannot be drawn past
   the rectangle a press is hit-tested against.

   A group may carry a caption, drawn on the row *above* its rectangle: a column
   of bare words - "(o) Selection", "( ) Scroll" - does not say what is being
   chosen between, and the caption is where that is said.  Putting it above
   rather than inside is what keeps the change small: y, width, height, Inside
   and the row arithmetic in onEvent are all untouched, and height stays the
   item count.  The price is that the caption is drawn outside the rectangle, so
   a group that carries one must sit at y >= 1 inside a canvas - row 0 of a
   window's canvas is the frame - and a press on the caption is taken by
   CaptionHit rather than by Inside.  A caption click chooses nothing: it is the
   group saying it has the mouse, and k comes out -1, which the item test
   declines by itself. *)

IMPORT TuiCanv, Events, Strings, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST
    MAXITEM = 8;                    (* items a group holds *)
    ITEMLEN = 24;                   (* bytes one item takes, its 0X included *)
    LBLEN = 24;                     (* and one the caption takes, its 0X too *)
    MARK = 3;                       (* "(", the mark itself and ")" *)
    GAP = 1;                        (* the column between ")" and the text *)

TYPE

    RadioGroup* = POINTER TO RadioGroupDesc;

    RadioGroupDesc* = RECORD (TuiWidg.WidgetDesc)
        items: ARRAY MAXITEM OF ARRAY ITEMLEN OF CHAR;
        label: ARRAY LBLEN OF CHAR; (* the caption, on the row above *)
        nitem*, sel*: INTEGER;      (* how many there are, and which is chosen *)
        cmd*: INTEGER;              (* the id a change hands to the window *)
        (* The window that owns it.  A host of NIL is a group nobody owns but
           its maker - a dialog's - and it is then up to that maker to place it,
           paint it and free it. *)
        host: TuiWin.Window;

        draw*:    PROCEDURE (self: RadioGroup; target: TuiCanv.Canvas);
        onEvent*: PROCEDURE (self: RadioGroup; VAR e: Events.Event): BOOLEAN;
        AddItem*: PROCEDURE (self: RadioGroup; label: ARRAY OF CHAR): INTEGER;
        Select*:  PROCEDURE (self: RadioGroup; i: INTEGER);
        SetLabel*: PROCEDURE (self: RadioGroup; label: ARRAY OF CHAR);
        SetPos*:  PROCEDURE (self: RadioGroup; x, y: INTEGER)
    END;


PROCEDURE Attr (self: RadioGroup): INTEGER;
VAR a: INTEGER;
BEGIN
    IF self.focused THEN
        a := TuiTheme.Attr(TuiTheme.RadioHot)
    ELSE
        a := TuiTheme.Attr(TuiTheme.Radio)
    END;
    RETURN a
END Attr;


(* Whether a cell is on the caption row this group draws, which is one row above
   its rectangle and so outside what Inside answers for.  A group with no
   caption has no such row: an empty label is not a caption that happens to be
   blank, it is the absence of one, and a press there belongs to whatever is
   behind. *)
PROCEDURE CaptionHit (self: RadioGroup; x, y: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (self.label[0] # 0X) & (y = self.y - 1) &
         (x >= self.x) & (x < self.x + self.width);
    RETURN r
END CaptionHit;


(* One item per row, the chosen one's mark an "o" and the rest a space - which
   is the whole difference between them, and the reason a group reads as one
   choice among several rather than as several boxes.

   The caption goes in the same pair as the items, so a group with the keyboard
   is hot as a block rather than as a column of marks under a heading that says
   nothing about whose it is.  It is filled across the group's width for the
   same reason the item rows are. *)
PROCEDURE draw (self: RadioGroup; target: TuiCanv.Canvas);
VAR a, k, y: INTEGER;
BEGIN
    a := Attr(self);
    IF (self.label[0] # 0X) & (self.y > 0) THEN
        target.Fill(target, self.x, self.y - 1, self.width, 1, " ", a);
        target.Print(target, self.x, self.y - 1, self.label, a)
    END;
    FOR k := 0 TO self.nitem - 1 DO
        y := self.y + k;
        target.Fill(target, self.x, y, self.width, 1, " ", a);
        target.Put(target, self.x, y, "(", a);
        IF k = self.sel THEN
            target.Put(target, self.x + 1, y, "o", a)
        ELSE
            target.Put(target, self.x + 1, y, " ", a)
        END;
        target.Put(target, self.x + 2, y, ")", a);
        target.Print(target, self.x + MARK + GAP, y, self.items[k], a)
    END
END draw;


(* The arrow keys move the choice while the group has the keyboard, and a click
   on a row chooses that row - the click being a cell, it says which row without
   anything having to be focused first.

   A click on the row that is already chosen is taken and changes nothing: the
   click is still the group's, and a press answered by doing nothing is very
   different from a press nobody answered, which would fall through to whatever
   is behind the widget.  The arrows do not run off either end; a group is not a
   ring.

   A click on the caption is taken the same way, and for the same reason - the
   caption is part of the group even though it is drawn outside the rectangle.
   It cannot choose anything, because k comes out -1 and the item test refuses
   it, which is what makes the caption the one row of the group that is a place
   to put the mouse rather than a choice to make with it. *)
PROCEDURE onEvent (self: RadioGroup; VAR e: Events.Event): BOOLEAN;
VAR hit: BOOLEAN; k: INTEGER;
BEGIN
    hit := FALSE;
    IF self.focused THEN
        IF Events.IsKey(e, Events.K_UP) THEN
            hit := TRUE;
            IF self.sel > 0 THEN
                DEC(self.sel);
                TuiWin.Notify(self.host, self, self.cmd)
            END
        ELSIF Events.IsKey(e, Events.K_DOWN) THEN
            hit := TRUE;
            IF self.sel < self.nitem - 1 THEN
                INC(self.sel);
                TuiWin.Notify(self.host, self, self.cmd)
            END
        END
    END;
    IF ~hit THEN
        hit := Events.IsPress(e) &
               (TuiWidg.Inside(self, e.x, e.y) OR CaptionHit(self, e.x, e.y));
        IF hit THEN
            k := e.y - self.y;
            IF (k >= 0) & (k < self.nitem) & (k # self.sel) THEN
                self.sel := k;
                TuiWin.Notify(self.host, self, self.cmd)
            END
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
   a group before doing anything - the guard on the type, the cast for the
   fields.  A group says the keyboard is on it with focused, and Up and Down are
   the keys it answers to once it is. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR g: RadioGroup;
BEGIN
    IF w IS RadioGroup THEN
        g := w(RadioGroup);
        g.focused := on
    END
END Take;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR g: RadioGroup; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS RadioGroup THEN
        g := w(RadioGroup);
        r := g.onEvent(g, e)
    END;
    RETURN r
END Handle;


(* One item, and the index it went to - or -1 when the group is full, which is
   the one answer a caller can do nothing about. *)
PROCEDURE AddItem (self: RadioGroup; label: ARRAY OF CHAR): INTEGER;
VAR k, n: INTEGER;
BEGIN
    k := -1;
    IF self.nitem < MAXITEM THEN
        k := self.nitem;
        Strings.Copy(label, self.items[k]);
        INC(self.nitem);
        self.height := self.nitem;
        n := Strings.Length(self.items[k]) + MARK + GAP;
        IF n > self.width THEN
            self.width := n
        END
    END;
    RETURN k
END AddItem;


(* Choose an item without firing anything - how the owner puts the group in step
   with the state it stands for.  An index outside the items leaves the choice
   alone, because there is no row it could mean. *)
PROCEDURE Select (self: RadioGroup; i: INTEGER);
BEGIN
    IF (i >= 0) & (i < self.nitem) THEN
        self.sel := i
    END
END Select;


(* What the group is a choice between, drawn on the row above it.

   The caption is copied and nothing else: unlike the checkbox's SetLabel this
   one does not widen the group, because the caption is not what a press is
   hit-tested against and a group whose width followed it would have its items
   filled to a width they do not use.  So SetLabel and AddItem do not care in
   which order they are called, and an empty caption is a group that has
   none. *)
PROCEDURE SetLabel (self: RadioGroup; label: ARRAY OF CHAR);
BEGIN
    Strings.Copy(label, self.label)
END SetLabel;


PROCEDURE SetPos (self: RadioGroup; x, y: INTEGER);
BEGIN
    self.x := x;
    self.y := y
END SetPos;


(* Give the group back.  The items are in the record itself, so there is nothing
   else to free - which is the whole reason the group is not a list.  It stands
   before the adapters and Create for the reason Create is not last here:
   Create binds this into the
   inherited Done field, and a procedure has to be declared before it is used. *)
PROCEDURE DoneRadioGroup (self: Oberon.Object);
VAR r: RadioGroup;
BEGIN
    r := self(RadioGroup);
    DISPOSE(r)
END DoneRadioGroup;


(* Where it draws itself, for a window that paints what it owns. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR g: RadioGroup;
BEGIN
    IF w IS RadioGroup THEN
        g := w(RadioGroup);
        g.draw(g, target)
    END
END Paint;


(* A group of the window host, which takes it from here: it is painted with
   everything else that window owns and given back when the window is.  A host of
   NIL is a group nobody owns but its maker - a dialog's - and it is then up to
   that maker to place it, paint it and free it, as before. *)
PROCEDURE Create* (cmd: INTEGER; host: TuiWin.Window): RadioGroup;
VAR g: RadioGroup;
BEGIN
    NEW(g);
    g.x := 0;
    g.y := 0;
    g.width := 0;
    g.height := 0;
    g.visible := TRUE;
    g.focused := FALSE;
    g.canvas := NIL;
    g.label[0] := 0X;
    g.nitem := 0;
    g.sel := 0;
    g.cmd := cmd;
    g.lastCmd := 0;
    g.host := host;
    g.draw := draw;
    g.onEvent := onEvent;
    g.handler := Handle;
    g.taker := Take;
    g.painter := Paint;
    g.onCommand := NIL;                 (* a group fires ids, it does not take them *)
    g.AddItem := AddItem;
    g.Select := Select;
    g.SetLabel := SetLabel;
    g.SetPos := SetPos;
    g.Done := DoneRadioGroup;
    TuiWin.Own(host, g);
    RETURN g
END Create;

END TuiRadio.
