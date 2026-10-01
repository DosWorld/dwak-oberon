MODULE TuiBtns;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A button: a label in brackets, a command id, and two flags.

   It is the same shape as a list - a widget with a draw and an onEvent, called
   with an explicit self.  It carries an id in its cmd field and hands it to its
   window when it is hit, which is the whole of what firing is: the window that
   offered the event acts on the id, through its ring and then its own onCommand.
   A window that owns the button is therefore the only place the id has to be
   understood, and the application above it never sees it.

   A button has no canvas of its own.  It lives on whatever canvas the caller
   draws it into - the desktop, for the dialog - and its x and y are in that
   canvas's coordinates, so a row of buttons is placed by whoever knows where
   the box around them is.

   Its width is not something a caller sets: it follows from the label, so the
   row cannot get out of step with what the buttons say.  The brackets are as
   wide as the text between them, which is what makes a button read as one on a
   screen that has no other way to say it.

   Colours come from TuiTheme at the moment of drawing.  The button the keyboard
   is on is hot, the one the focus starts on is the default, and the rest are
   plain - three slots, and which one a button draws with is decided here. *)

IMPORT TuiCanv, Events, Strings, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST
    MAXLABEL = 16;                  (* bytes a label takes, its 0X included *)
    PAD = 1;                        (* columns between a bracket and the text *)

TYPE

    Button* = POINTER TO ButtonDesc;

    ButtonDesc* = RECORD (TuiWidg.WidgetDesc)
        label: ARRAY MAXLABEL OF CHAR;
        cmd*: INTEGER;              (* the id it fires, handed to its window *)
        default*: BOOLEAN;          (* the one the focus starts on *)
        hot*: BOOLEAN;              (* the one the keyboard is on *)
        (* The window that owns it, taken at Create, or NIL for a button that
           belongs to nobody - a dialog's, which the dialog paints and frees
           itself, exactly as it did before there was a host to name. *)
        host: TuiWin.Window;

        draw*:     PROCEDURE (self: Button; target: TuiCanv.Canvas);
        onEvent*:  PROCEDURE (self: Button; VAR e: Events.Event): BOOLEAN;
        SetLabel*: PROCEDURE (self: Button; label: ARRAY OF CHAR);
        SetPos*:   PROCEDURE (self: Button; x, y: INTEGER)
    END;


(* The pair this button is drawn with.  The keystroke's button wins over the
   default one, so the default keeps its colour only while the focus is
   somewhere else - which is the one moment the difference is worth showing. *)
PROCEDURE Attr (self: Button): INTEGER;
VAR a: INTEGER;
BEGIN
    IF self.hot THEN
        a := TuiTheme.Attr(TuiTheme.ButtonHot)
    ELSIF self.default THEN
        a := TuiTheme.Attr(TuiTheme.ButtonDefault)
    ELSE
        a := TuiTheme.Attr(TuiTheme.Button)
    END;
    RETURN a
END Attr;


PROCEDURE draw (self: Button; target: TuiCanv.Canvas);
VAR a: INTEGER;
BEGIN
    a := Attr(self);
    target.Fill(target, self.x, self.y, self.width, 1, " ", a);
    target.Put(target, self.x, self.y, "[", a);
    target.Put(target, self.x + self.width - 1, self.y, "]", a);
    target.Print(target, self.x + 1 + PAD, self.y, self.label, a)
END draw;


(* Whether this press was on the button, or this keystroke is one a button
   answers to while the keyboard is on it.

   A button takes what it answers for - the event comes back as NONE - so that
   nothing else can act on the same press; one that was not hit leaves the event
   alone for whatever is behind it, which for a dialog is nothing at all.

   The press that answers is the one the button went down on, not a movement
   that carried a button already down across it: a drag out of the dialog's
   message and over the row must not fire the button it ends on.

   The keyboard half is here for the sample's fifth window, which is the first
   place a button has stood outside a dialog.  A dialog answers Enter itself,
   because it is the thing that knows which of its buttons the keyboard is on -
   and it offers its buttons mouse events only, so nothing there can reach this
   arm and nothing there changes.  A button on its own has no dialog to do that,
   and without this arm the ring of the window it lives in would walk onto a
   widget that is drawn hot and answers nothing, which is a dead stop the arrows
   would have to be taught to step over.

   Enter and Space are the two keys a button has always answered to, and hot is
   what says the keyboard is on this one. *)
PROCEDURE onEvent (self: Button; VAR e: Events.Event): BOOLEAN;
VAR hit: BOOLEAN;
BEGIN
    hit := Events.IsPress(e) & TuiWidg.Inside(self, e.x, e.y);
    IF ~hit & self.hot THEN
        hit := Events.IsKey(e, Events.K_ENTER) OR Events.IsKey(e, Events.K_SPACE)
    END;
    IF hit THEN
        TuiWin.Notify(self.host, self, self.cmd);
        e.kind := Events.NONE
    END;
    RETURN hit
END onEvent;


(* The two ways in for a router that does not know what kind of widget this is:
   take an event, and take the keyboard on or off.  Both are declared for
   TuiWidg.Widget, which is what a window's ring holds, and both narrow back to
   a button before doing anything - the guard on the type, the cast for the
   fields.

   A button's word for "the keyboard is on me" is hot, because it is also what
   makes it draw hot; focused is set with it so that the flag means the same
   thing on every widget, and Take is the only place either is written for a
   button a window has taken on. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR b: Button;
BEGIN
    IF w IS Button THEN
        b := w(Button);
        b.focused := on;
        b.hot := on
    END
END Take;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR b: Button; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS Button THEN
        b := w(Button);
        r := b.onEvent(b, e)
    END;
    RETURN r
END Handle;


(* Give the button back.  A button owns nothing but itself, so this is one line
   - and it takes `Oberon.Object` and guards down because it is what goes into
   the inherited `Done` field, whose declared type is `PROCEDURE (self:
   Object)`.  A dialog frees its own buttons with `Oberon.Done`; a button in a
   window is given back by that window, through the same field. *)
PROCEDURE DoneButton (self: Oberon.Object);
VAR b: Button;
BEGIN
    b := self(Button);
    DISPOSE(b)
END DoneButton;


(* Where it draws itself, for a window that paints what it owns.  The target is
   the canvas of the window it is in, and its own x and y are read there - which
   is the same call the dialog makes when it paints its own buttons. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR b: Button;
BEGIN
    IF w IS Button THEN
        b := w(Button);
        b.draw(b, target)
    END
END Paint;


(* What it gives back when the window it is in goes.  A button owns nothing but
   itself, so this is Done; a widget that owns an array or a window of its own
   gives those back here first. *)
PROCEDURE SetLabel (self: Button; label: ARRAY OF CHAR);
BEGIN
    Strings.Copy(label, self.label);
    self.width := Strings.Length(self.label) + 2 * PAD + 2
END SetLabel;


PROCEDURE SetPos (self: Button; x, y: INTEGER);
BEGIN
    self.x := x;
    self.y := y
END SetPos;


(* A button of the window host, which takes it from here: it is painted with
   everything else that window owns and given back when the window is.  A host of
   NIL is a button nobody owns but its maker - a dialog's - and it is then up to
   that maker to place it, paint it and free it, as before. *)
PROCEDURE Create* (label: ARRAY OF CHAR; cmd: INTEGER; isDefault: BOOLEAN;
                   host: TuiWin.Window): Button;
VAR b: Button;
BEGIN
    NEW(b);
    b.x := 0;
    b.y := 0;
    b.width := 0;
    b.height := 1;
    b.visible := TRUE;
    b.focused := FALSE;
    b.canvas := NIL;
    b.lastCmd := 0;
    b.cmd := cmd;
    b.default := isDefault;
    b.hot := FALSE;
    b.host := host;
    b.draw := draw;
    b.onEvent := onEvent;
    b.handler := Handle;
    b.taker := Take;
    b.painter := Paint;
    b.onCommand := NIL;                 (* a button fires ids, it does not take them *)
    b.Done := DoneButton;
    b.SetLabel := SetLabel;
    b.SetPos := SetPos;
    SetLabel(b, label);
    TuiWin.Own(host, b);
    RETURN b
END Create;

END TuiBtns.
