MODULE TuiDlg;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A modal box: a title, two lines of message, a field if it has one, and a row
   of buttons.

   It is drawn straight onto the desktop rather than into a canvas of its own,
   and that is the one thing about it that differs from a window.  A window has
   a canvas because it moves, is covered and is uncovered, and the canvas is
   where its pixels survive all three; a dialog is on top of everything, is
   never covered, and exists for as long as it takes to answer it - so the
   pixels have nowhere to survive to and a canvas would be one more thing to
   free.  Its x and y, and its buttons' x and y, are therefore desktop cells,
   which is also what a click carries, so no coordinate has to be translated.

   It is modal: onEvent answers TRUE for every event it is given, including the
   ones it does nothing with, and Tui hands it every event before anything else
   sees one.  That is what keeps a keystroke from reaching the window behind it,
   and it is why Esc closes the dialog instead of quitting the program.

   A dialog that has a field is one that asks a question, and the field is the
   row between the message and the buttons.  The keyboard starts in it - a dialog
   that asks something wants the answer typed - and Tab moves it between the
   field and the row of buttons, which is the only thing that decides which of
   the two a key goes to.  The buttons are drawn hot only while the row has the
   keyboard, so which of the two is listening can be seen rather than remembered.
   An event is offered to the field before the buttons even so, because the field
   takes only what happens inside it and the two cannot fight over a click.

   The dialog owns its field exactly as it owns its buttons, and frees both in
   Done.  What it does not do is clear the field: the text is the caller's, the
   way the message lines are, and an application that wants a prompt to start
   empty clears it.

   The command it fires is reported the way the menu reports one: the dialog
   puts the id in lastCmd and sets closed, and Tui - which holds the dialog -
   reads both and gives the id back to the application.  A dialog that Esc
   closed has no lastCmd, so the application can tell "cancelled" from the
   command a button carries by the id alone. *)

IMPORT TuiBtns, TuiCanv, Events, TuiFld, Strings, TuiTheme, TuiWidg, Oberon;

CONST

    MAXBTN = 4;                     (* buttons in the row *)
    MAXTITLE = 40;                  (* bytes the title takes, its 0X included *)
    LINELEN = 44;                   (* and a message line *)

    HEIGHT = 6;                     (* the box: the title on the top frame row,
                                       two message lines, the field row, the
                                       buttons and the bottom frame row.  A
                                       dialog without a field leaves the field
                                       row blank, which is what keeps a box that
                                       only reports something the shape it had
                                       before there were fields. *)
    MINW = 24;                      (* the narrowest box worth drawing *)
    FIELDW = 30;                    (* and the narrowest field worth typing
                                       into, which is also the narrowest box a
                                       dialog that asks something is drawn *)
    INDENT = 2;                     (* columns a message line starts in from *)
    MARGIN = 2;                     (* and the button row's own margin *)
    GAP = 2;                        (* columns between two buttons *)
    ROWBTN = 4;                     (* the row of the box the buttons sit on *)
    ROWFLD = 3;                     (* and the row the field sits on *)

TYPE

    Dialog* = POINTER TO DialogDesc;

    DialogDesc* = RECORD (TuiWidg.WidgetDesc)
        title: ARRAY MAXTITLE OF CHAR;
        line1, line2: ARRAY LINELEN OF CHAR;
        buttons: ARRAY MAXBTN OF TuiBtns.Button;
        nbtn: INTEGER;
        field*: TuiFld.Field;       (* what the dialog asks with, or NIL *)
        inField: BOOLEAN;           (* whether the field has the keyboard *)
        sel*: INTEGER;              (* the button the keyboard is on *)
        first: INTEGER;             (* the one the focus starts on *)
        closed*: BOOLEAN;           (* set when it has been answered; the id of
                                       the button that was taken is the base's
                                       own lastCmd *)

        draw*:      PROCEDURE (self: Dialog; target: TuiCanv.Canvas);
        onEvent*:   PROCEDURE (self: Dialog; VAR e: Events.Event): BOOLEAN;
        SetText*:   PROCEDURE (self: Dialog; line1, line2: ARRAY OF CHAR);
        AddButton*: PROCEDURE (self: Dialog; label: ARRAY OF CHAR; cmd: INTEGER;
                               isDefault: BOOLEAN): INTEGER;
        AddField*:  PROCEDURE (self: Dialog);
        SetFieldText*: PROCEDURE (self: Dialog; s: ARRAY OF CHAR);
        GetFieldText*: PROCEDURE (self: Dialog; VAR s: ARRAY OF CHAR);
        Open*:      PROCEDURE (self: Dialog);
        Place*:     PROCEDURE (self: Dialog; cols, rows: INTEGER)
    END;


(* The width of the whole button row: the buttons and the gaps between them. *)
PROCEDURE RowW (self: Dialog): INTEGER;
VAR i, w: INTEGER;
BEGIN
    w := 0;
    FOR i := 0 TO self.nbtn - 1 DO
        IF i > 0 THEN w := w + GAP END;
        w := w + self.buttons[i].width
    END;
    RETURN w
END RowW;


(* Mark the one button the keyboard is on.  The flag is on the button rather
   than asked of the dialog at draw time, because a button draws itself and is
   given nothing but the canvas.

   A dialog with a field marks none of them while the field has the keyboard:
   the hot button is the one Enter would take without being asked, and that is
   not true while the keyboard is somewhere else. *)
PROCEDURE Hot (self: Dialog);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO self.nbtn - 1 DO
        self.buttons[i].hot := (i = self.sel) & ~self.inField
    END
END Hot;


(* Give the keyboard to the field or back to the row of buttons.  The two flags
   are one decision and are set together - the field's own focused is what makes
   it take a key, the dialog's inField is what makes the dialog offer it one.

   The hot button is refreshed whichever way this goes, and by every call.  That
   is what keeps a dialog that was never given a field marking its default one:
   there is no keyboard to move, and the button Enter would take is still the
   button it was. *)
PROCEDURE InField (self: Dialog; yes: BOOLEAN);
VAR inIt: BOOLEAN;
BEGIN
    inIt := yes & (self.field # NIL);
    self.inField := inIt;
    IF self.field # NIL THEN
        self.field.focused := inIt
    END;
    Hot(self)
END InField;


(* Move the keyboard a step along the row, wrapping.  d is +1 or -1, and the
   sum is brought back into range by adding the count before taking the
   remainder, which is the one way to do it here: the dialect has no MOD that
   keeps a negative operand positive. *)
PROCEDURE Step (self: Dialog; d: INTEGER);
BEGIN
    IF self.nbtn > 0 THEN
        self.sel := (self.sel + d + self.nbtn) MOD self.nbtn;
        Hot(self)
    END
END Step;


(* Take the button i: its command is the dialog's answer, and the dialog is
   done.  Out of range - a dialog with no buttons - there is no command, so the
   answer is the same as Esc's. *)
PROCEDURE Fire (self: Dialog; i: INTEGER);
BEGIN
    self.lastCmd := 0;
    IF (i >= 0) & (i < self.nbtn) THEN
        self.lastCmd := self.buttons[i].cmd
    END;
    self.closed := TRUE
END Fire;


PROCEDURE draw (self: Dialog; target: TuiCanv.Canvas);
VAR a, ta, n, x, i: INTEGER; buf: ARRAY MAXTITLE OF CHAR;
BEGIN
    IF self.visible THEN
        a := TuiTheme.Attr(TuiTheme.Dialog);
        target.Fill(target, self.x, self.y, self.width, self.height, " ", a);
        target.Frame(target, self.x, self.y, self.width, self.height,
                     TuiTheme.Attr(TuiTheme.DialogFrame), TRUE);
        (* the title, centred on the top frame row and cut to what fits between
           the corners; its pair is the one that is not the frame's, so the
           strip reads as a tab rather than as a piece of the box *)
        ta := TuiTheme.Attr(TuiTheme.DialogText);
        Strings.Copy(self.title, buf);
        n := Strings.Length(buf);
        IF n > self.width - 4 THEN
            n := self.width - 4;
            IF n < 0 THEN n := 0 END;
            buf[n] := 0X
        END;
        IF n > 0 THEN
            x := (self.width - n) DIV 2;
            IF x > self.width - 1 - n THEN x := self.width - 1 - n END;
            IF x < 1 THEN x := 1 END;
            target.Fill(target, self.x + x - 1, self.y, n + 2, 1, " ", ta);
            target.Print(target, self.x + x, self.y, buf, ta)
        END;
        target.Print(target, self.x + INDENT, self.y + 1, self.line1, a);
        target.Print(target, self.x + INDENT, self.y + 2, self.line2, a);
        IF self.field # NIL THEN
            self.field.draw(self.field, target)
        END;
        FOR i := 0 TO self.nbtn - 1 DO
            self.buttons[i].draw(self.buttons[i], target)
        END
    END
END draw;


(* Every event is the dialog's.  The keys it knows move the focus or take a
   button; the rest it swallows without acting, which is what modal means.

   The field, if there is one, is offered an event first.  It takes what happens
   inside it and declines Tab, Enter and Esc, so offering it everything is safe:
   what it declines comes back here and is the dialog's own - Tab moves between
   the field and the row, and Enter and Esc answer the dialog from wherever the
   keyboard happens to be.

   Space is the second key a hot button carries, which is what TuiBtns already
   does for itself, and the arm here is what lets a dialog have it too: the
   button a dialog shows is a TuiBtns.Button and the dialog is the only thing
   that offers it a key, so without this arm the pair of them would answer Enter
   and not Space.  The field is offered the key first and takes it - a space is
   a character - which is what makes the two keys one rule rather than two: a
   Space is a space while the keyboard is in the field and the hot button while
   it is on the row, and no arm has to ask which. *)
PROCEDURE onEvent (self: Dialog; VAR e: Events.Event): BOOLEAN;
VAR i: INTEGER; handled: BOOLEAN;
BEGIN
    handled := FALSE;
    IF e.kind = Events.KEYBOARD THEN
        IF self.inField & (self.field # NIL) THEN
            handled := self.field.onEvent(self.field, e)
        END;
        IF ~handled THEN
            IF Events.IsKey(e, Events.K_LEFT) OR Events.IsKey(e, Events.K_UP) THEN
                Step(self, -1)
            ELSIF Events.IsKey(e, Events.K_RIGHT) OR Events.IsKey(e, Events.K_DOWN)
            THEN
                Step(self, 1)
            ELSIF Events.IsKey(e, Events.K_TAB) THEN
                IF self.field # NIL THEN
                    InField(self, ~self.inField)
                ELSE
                    Step(self, 1)
                END
            ELSIF Events.IsKey(e, Events.K_ENTER) OR
                  Events.IsKey(e, Events.K_SPACE) THEN
                Fire(self, self.sel)
            ELSIF Events.IsKey(e, Events.K_ESC) THEN
                Fire(self, -1)                      (* out: no command, just closed *)
            END
        END
    ELSIF e.kind = Events.MOUSE THEN
        (* A press and not a movement with the button already down, so a drag
           that began on the message and ended on the row does not fire the
           button it was released over. *)
        IF self.field # NIL THEN
            IF self.field.onEvent(self.field, e) THEN
                InField(self, TRUE)         (* typing goes where the click went *)
            END
        END;
        IF Events.IsPress(e) THEN
            FOR i := 0 TO self.nbtn - 1 DO
                IF self.buttons[i].onEvent(self.buttons[i], e) THEN
                    self.sel := i;
                    InField(self, FALSE);   (* the keyboard has left the field *)
                    Fire(self, i)
                END
            END
        END
    END;
    e.kind := Events.NONE;
    RETURN TRUE
END onEvent;


PROCEDURE SetText (self: Dialog; line1, line2: ARRAY OF CHAR);
BEGIN
    Strings.Copy(line1, self.line1);
    Strings.Copy(line2, self.line2)
END SetText;


(* A button at the end of the row, in the order they are added.  The first one
   added as the default is the one the focus starts on; a second is ignored,
   because a row cannot have two.  Answers the index, or -1 when the row is
   full. *)
PROCEDURE AddButton (self: Dialog; label: ARRAY OF CHAR; cmd: INTEGER;
                     isDefault: BOOLEAN): INTEGER;
VAR i: INTEGER;
BEGIN
    i := -1;
    IF self.nbtn < MAXBTN THEN
        i := self.nbtn;
        self.buttons[i] := TuiBtns.Create(label, cmd, isDefault, NIL);
        INC(self.nbtn);
        IF isDefault & (self.first < 0) THEN
            self.first := i
        END
    END;
    RETURN i
END AddButton;


(* Give the dialog a field to ask with: one row, at the left indent, as wide as
   the box can spare.  Its rectangle is set by Place, which is the only thing
   that knows how wide the box came out.

   A second call replaces the first field rather than adding one: a dialog asks
   one question, and the caller that asks another one already has the text it
   wants to keep.  The text is not carried over - a new field starts empty. *)
PROCEDURE AddField (self: Dialog);
BEGIN
    IF self.field # NIL THEN
        Oberon.Done(self.field)
    END;
    self.field := TuiFld.Create(0, 0, FIELDW, NIL);
    self.inField := FALSE
END AddField;


(* The text the dialog is asking for, and a way to set it.

   The application never names the field itself: what a dialog asks with is the
   dialog's business, and these two are the whole of what a caller needs - set
   it before opening the dialog, read it after the command comes back.  Both
   answer an empty string for a dialog that has no field, so a caller that asks
   one that never asked anything gets nothing rather than a crash. *)
PROCEDURE SetFieldText (self: Dialog; s: ARRAY OF CHAR);
BEGIN
    IF self.field # NIL THEN
        self.field.SetText(self.field, s)
    END
END SetFieldText;


PROCEDURE GetFieldText (self: Dialog; VAR s: ARRAY OF CHAR);
BEGIN
    IF self.field # NIL THEN
        self.field.GetText(self.field, s)
    ELSE
        s[0] := 0X
    END
END GetFieldText;


(* Centre the box on the desktop and lay the buttons out on their row.

   The size is worked out rather than given: it has to hold the title, the
   longer of the two message lines, the field if there is one and the whole
   button row, and it is the dialog that knows all of them.  A box that came out
   wider than the desktop is cut to it - the text would be clipped by the screen
   anyway, and a box whose right frame is off the edge has lost the frame that
   says where it ends. *)
PROCEDURE Place (self: Dialog; cols, rows: INTEGER);
VAR w, need, x, i: INTEGER;
BEGIN
    w := MINW;
    need := Strings.Length(self.title) + 4;
    IF need > w THEN w := need END;
    need := Strings.Length(self.line1) + 2 * INDENT;
    IF need > w THEN w := need END;
    need := Strings.Length(self.line2) + 2 * INDENT;
    IF need > w THEN w := need END;
    need := RowW(self) + 2 * MARGIN;
    IF need > w THEN w := need END;
    (* A box that asks something has to be wide enough for the field and the
       indent around it, or the question and the answer would be different
       widths. *)
    IF self.field # NIL THEN
        need := FIELDW + 2 * INDENT;
        IF need > w THEN w := need END
    END;
    IF w > cols THEN w := cols END;
    self.width := w;
    self.height := HEIGHT;
    self.x := (cols - w) DIV 2;
    self.y := (rows - HEIGHT) DIV 2;
    IF self.x < 0 THEN self.x := 0 END;
    IF self.y < 1 THEN self.y := 1 END;
    x := self.x + (self.width - RowW(self)) DIV 2;
    IF x < self.x + 1 THEN x := self.x + 1 END;
    FOR i := 0 TO self.nbtn - 1 DO
        self.buttons[i].SetPos(self.buttons[i], x, self.y + ROWBTN);
        x := x + self.buttons[i].width + GAP
    END;
    (* The field takes the box's interior on its row, from the same indent the
       message lines start at - so the question and the answer line up, and the
       text scrolls in a field that is narrower than it. *)
    IF self.field # NIL THEN
        w := self.width - 2 * INDENT;
        IF w < 1 THEN w := 1 END;
        TuiWidg.SetRect(self.field, self.x + INDENT, self.y + ROWFLD, w, 1)
    END
END Place;


(* Open it: the focus back where it starts, no command, and nothing from the
   last time left over.

   A dialog that asks something starts with the keyboard in the field, because
   that is what it was put on the screen for; the row of buttons is one Tab
   away, and the buttons are drawn cold until then. *)
PROCEDURE Open (self: Dialog);
BEGIN
    self.closed := FALSE;
    self.lastCmd := 0;
    self.sel := self.first;
    IF self.sel < 0 THEN self.sel := 0 END;
    IF self.sel > self.nbtn - 1 THEN self.sel := self.nbtn - 1 END;
    IF self.sel < 0 THEN self.sel := 0 END;
    InField(self, self.field # NIL)
END Open;


(* Give the dialog back: its field, its buttons, then the record.  A dialog
   is not a widget a window owns - it is drawn on the desk and freed by
   whoever made it - so this is reached as `Oberon.Done(d)`, through the
   inherited field, and not by a procedure of this module: a class has one
   destructor and Oberon.mod says why.

   It takes `Oberon.Object` and guards down because it is what goes into that
   field, whose declared type is `PROCEDURE (self: Object)`. *)
PROCEDURE DoneDialog (self: Oberon.Object);
VAR d: Dialog; i: INTEGER;
BEGIN
    d := self(Dialog);
    IF d.field # NIL THEN
        Oberon.Done(d.field);
        d.field := NIL
    END;
    FOR i := 0 TO d.nbtn - 1 DO
        IF d.buttons[i] # NIL THEN
            Oberon.Done(d.buttons[i])
        END;
        d.buttons[i] := NIL
    END;
    d.nbtn := 0;
    DISPOSE(d)
END DoneDialog;


PROCEDURE Create* (title: ARRAY OF CHAR): Dialog;
VAR d: Dialog; i: INTEGER;
BEGIN
    NEW(d);
    d.x := 0;
    d.y := 0;
    d.width := MINW;
    d.height := HEIGHT;
    d.visible := TRUE;
    d.focused := FALSE;
    d.canvas := NIL;                    (* a dialog has none, and draws on the desk *)
    Strings.Copy(title, d.title);
    d.line1[0] := 0X;
    d.line2[0] := 0X;
    FOR i := 0 TO MAXBTN - 1 DO
        d.buttons[i] := NIL
    END;
    d.nbtn := 0;
    d.field := NIL;                     (* until AddField gives it one *)
    d.inField := FALSE;
    d.sel := 0;
    d.first := -1;
    d.closed := FALSE;
    d.lastCmd := 0;
    d.draw := draw;
    d.onEvent := onEvent;
    d.SetText := SetText;
    d.AddButton := AddButton;
    d.AddField := AddField;
    d.SetFieldText := SetFieldText;
    d.GetFieldText := GetFieldText;
    d.Open := Open;
    d.Place := Place;
    d.Done := DoneDialog;
    RETURN d
END Create;

END TuiDlg.
