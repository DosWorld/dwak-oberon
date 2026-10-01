MODULE TuiChk;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A checkbox: a bracketed mark and a label, an id it carries, and the state
   the mark shows.

   It is the button's shape with a different body - a draw, an onEvent, a cmd it
   never fires itself - and its mark is what says what it is: [X] for the one
   that is set and [ ] for the one that is not, which on a text screen is a
   checkbox exactly as brackets around a label are a button.

   Two things set it, and they are one action: Space while it has the keyboard,
   and a click on it.  A click does not ask for the keyboard first - choosing a
   box with the mouse is choosing it, and a box that had to be focused before it
   could be clicked would say so by nothing at all.

   Its width follows from its label, as a button's does, so the row cannot get
   out of step with the text in it - and the text is the only thing the caller
   gives it.

   Colours come from TuiTheme at the moment of drawing: the box the keyboard is on
   is drawn in the hot pair and the rest in the plain one, so which of several
   widgets a Space would reach is visible in the widget itself. *)

IMPORT TuiCanv, Events, Strings, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST
    MAXLABEL = 24;                  (* bytes a label takes, its 0X included *)
    MARK = 3;                       (* "[", the mark itself and "]" *)
    GAP = 1;                        (* the column between "]" and the text *)

TYPE

    CheckBox* = POINTER TO CheckBoxDesc;

    CheckBoxDesc* = RECORD (TuiWidg.WidgetDesc)
        label: ARRAY MAXLABEL OF CHAR;
        checked*: BOOLEAN;          (* what the mark shows *)
        cmd*: INTEGER;              (* the id the owner is told when it changes,
                                       handed to the window that owns it *)
        (* The window that owns it.  A host of NIL is a box nobody owns but its
           maker - a dialog's - and it is then up to that maker to place it,
           paint it and free it. *)
        host: TuiWin.Window;

        draw*:     PROCEDURE (self: CheckBox; target: TuiCanv.Canvas);
        onEvent*:  PROCEDURE (self: CheckBox; VAR e: Events.Event): BOOLEAN;
        SetLabel*: PROCEDURE (self: CheckBox; label: ARRAY OF CHAR);
        SetPos*:   PROCEDURE (self: CheckBox; x, y: INTEGER);
        SetChecked*: PROCEDURE (self: CheckBox; on: BOOLEAN);
        IsChecked*:  PROCEDURE (self: CheckBox): BOOLEAN
    END;


(* The pair this box is drawn with.  Focus is the whole of the decision here:
   a checkbox is set or it is not, and neither state is a selection that wants a
   colour of its own - what the pair says is whether this is the one a Space
   would reach. *)
PROCEDURE Attr (self: CheckBox): INTEGER;
VAR a: INTEGER;
BEGIN
    IF self.focused THEN
        a := TuiTheme.Attr(TuiTheme.CheckHot)
    ELSE
        a := TuiTheme.Attr(TuiTheme.Check)
    END;
    RETURN a
END Attr;


(* The row is filled first, so that a label shorter than the rectangle leaves
   the pair this box is drawn in behind it rather than the cells of whatever was
   there before - the same reason a button fills its row. *)
PROCEDURE draw (self: CheckBox; target: TuiCanv.Canvas);
VAR a: INTEGER;
BEGIN
    a := Attr(self);
    target.Fill(target, self.x, self.y, self.width, 1, " ", a);
    target.Put(target, self.x, self.y, "[", a);
    IF self.checked THEN
        target.Put(target, self.x + 1, self.y, "X", a)
    ELSE
        target.Put(target, self.x + 1, self.y, " ", a)
    END;
    target.Put(target, self.x + 2, self.y, "]", a);
    target.Print(target, self.x + MARK + GAP, self.y, self.label, a)
END draw;


(* Space toggles it while it has the keyboard; a click toggles it whether or not
   it has, because the click is the choice.  One action with two ways of asking
   for it, which is why the work is in one place.

   The press that answers is the one the button went down on and not a movement
   that carried a button already down across the box - a drag that ends on a
   checkbox must not set it, the same rule a button and the menu bar follow. *)
PROCEDURE onEvent (self: CheckBox; VAR e: Events.Event): BOOLEAN;
VAR hit: BOOLEAN;
BEGIN
    hit := self.focused & Events.IsKey(e, Events.K_SPACE);
    IF ~hit THEN
        hit := Events.IsPress(e) & TuiWidg.Inside(self, e.x, e.y)
    END;
    IF hit THEN
        self.checked := ~self.checked;
        TuiWin.Notify(self.host, self, self.cmd);
        e.kind := Events.NONE
    END;
    RETURN hit
END onEvent;


(* The two ways in for a router that does not know what kind of widget this is:
   take an event, and take the keyboard on or off.  Both are declared for
   TuiWidg.Widget, which is what a window's ring holds, and both narrow back to
   a checkbox before doing anything - the guard on the type, the cast for the
   fields.  A checkbox says the keyboard is on it with focused, and Space is the
   key it answers to once it is. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR c: CheckBox;
BEGIN
    IF w IS CheckBox THEN
        c := w(CheckBox);
        c.focused := on
    END
END Take;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR c: CheckBox; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS CheckBox THEN
        c := w(CheckBox);
        r := c.onEvent(c, e)
    END;
    RETURN r
END Handle;


PROCEDURE SetLabel (self: CheckBox; label: ARRAY OF CHAR);
BEGIN
    Strings.Copy(label, self.label);
    self.width := Strings.Length(self.label) + MARK + GAP
END SetLabel;


PROCEDURE SetPos (self: CheckBox; x, y: INTEGER);
BEGIN
    self.x := x;
    self.y := y
END SetPos;


(* Set the state without firing anything.  This is how the owner puts the box in
   step with what it stands for - a window that is already on the desk, a mode
   that was already on - which is not the user changing it and must not come
   back as a command. *)
PROCEDURE SetChecked (self: CheckBox; on: BOOLEAN);
BEGIN
    self.checked := on
END SetChecked;


PROCEDURE IsChecked (self: CheckBox): BOOLEAN;
VAR b: BOOLEAN;
BEGIN
    b := self.checked;
    RETURN b
END IsChecked;


(* Give the box back.  A checkbox is a leaf: there is nothing in it that has to
   be freed first, so this is one line - and it stands before the adapters and
   Create for the reason Create is not last here: Create binds this into the
   inherited Done field, and a procedure has to be declared before it is
   used. *)
PROCEDURE DoneCheckBox (self: Oberon.Object);
VAR c: CheckBox;
BEGIN
    c := self(CheckBox);
    DISPOSE(c)
END DoneCheckBox;


(* Where it draws itself, for a window that paints what it owns. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR c: CheckBox;
BEGIN
    IF w IS CheckBox THEN
        c := w(CheckBox);
        c.draw(c, target)
    END
END Paint;


(* A checkbox of the window host, which takes it from here: it is painted with
   everything else that window owns and given back when the window is.  A host of
   NIL is a box nobody owns but its maker - a dialog's - and it is then up to
   that maker to place it, paint it and free it, as before. *)
PROCEDURE Create* (label: ARRAY OF CHAR; cmd: INTEGER;
                   host: TuiWin.Window): CheckBox;
VAR c: CheckBox;
BEGIN
    NEW(c);
    c.x := 0;
    c.y := 0;
    c.width := 0;
    c.height := 1;
    c.visible := TRUE;
    c.focused := FALSE;
    c.canvas := NIL;
    c.checked := FALSE;
    c.cmd := cmd;
    c.lastCmd := 0;
    c.host := host;
    c.draw := draw;
    c.onEvent := onEvent;
    c.handler := Handle;
    c.taker := Take;
    c.painter := Paint;
    c.onCommand := NIL;                 (* a box fires ids, it does not take them *)
    c.SetLabel := SetLabel;
    c.SetPos := SetPos;
    c.SetChecked := SetChecked;
    c.IsChecked := IsChecked;
    c.Done := DoneCheckBox;
    SetLabel(c, label);
    TuiWin.Own(host, c);
    RETURN c
END Create;

END TuiChk.
