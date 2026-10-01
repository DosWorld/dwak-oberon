MODULE TuiDate;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A date field: a strip of text in YYYY-MM-DD, a [ >> ] button beside it, and a
   calendar in a window of its own that the button puts up next to the field.

   The value is a Calendar.Date and the text is DateFmt's.  Nothing here turns a
   date into digits or digits into a date on its own: the strip is written with
   DateFmt.Format, what is typed into it is read with DateFmt.Parse, the year in
   the pop-up's own field is the first four characters of the same Format, and
   even a day number in the grid is the day part of the text Format writes for
   that date.  A date the parser refuses leaves the value alone and the strip is
   written again from the value, so the two can never disagree.

   The calendar is a window, and that is the whole of how it can be "next to"
   the field, outside the window the field is in, and over whatever it covers.
   A widget knows only its window's coordinates, so it cannot place anything on
   the desk by itself - which is why Create takes the window the widget sits in.
   The window the calendar goes in is made here, by the widget, and handed to
   the desk with Tui.SetPopup; the desk paints it over everything and offers it
   every event first, and the widget takes it down again.  Being the one window
   the desk holds outside its z-order is what makes it modal without a dialogue
   box's machinery: see Tui.SetPopup.

   The pop-up is filled from this widget's own draw, which the application
   already calls once a frame for every widget it owns.  The frame and the title
   are TuiWin.Draw's, because the desk is what holds the window and calls it;
   everything inside is drawn here.  That is what keeps a theme switch and a
   resize right with no application code and no new desk method.

   The calendar's cursor is one Calendar.Date - the day the highlight is on - and
   the month on show is that date's month.  There is no second month or year
   beside it, so stepping the month moves the date and nothing can drift out of
   step.  A day is picked by moving that cursor; Enter, a click on the day and
   [ OK ] all commit, and Esc, [Cancel] and a press outside the calendar all
   leave the value exactly as it was.

   The names of months and weekdays and the day a week starts on come from
   Locale, read at the moment of drawing, so a program that changes its locale
   sees the new one on the next frame with nothing rebuilt.  A name longer than
   its column is cut where it is drawn; the table holds full names.
*)

IMPORT TuiBtns, Calendar, TuiCanv, DateFmt, Events, TuiFld, Locale, Strings,
       TuiTheme, Tui, TuiWidg, TuiWin, Oberon;

CONST

    BTNGAP = 1;                     (* columns between the field and the button *)

    (* The pop-up window.  Its client area is what is inside the frame, rows 1
       to POPH - 2 of the canvas, and the four bands below are laid out in it:

           row 1          [<] month [>]                     [year]
           row 3          Mo Tu We Th Fr Sa Su
           rows 4..9      the six weeks
           row 11         2026-09-27          [ OK ] [Cancel]                *)
    POPW = 32;
    POPH = 14;
    POPCLIENTW = POPW - 2;
    POPCLIENTH = POPH - 2;

    HDRY = 1;                       (* the month arrows and the year field *)
    LARROWX = 2;                    (* "[<]" *)
    RARROWX = 19;                   (* "[>]" *)
    ARROWW = 3;
    MONX = 6;                       (* the month's name, and the room it has *)
    MONW = 12;
    YEARX = 24;                     (* the typed year, in a field of its own *)
    YEARW = 6;

    GRIDX = 2;                      (* the seven columns of four cells *)
    CELLW = 4;
    NCOLS = 7;
    NROWS = 6;
    WDAY_Y = 3;                     (* the weekday header *)
    DAY_Y = 4;                      (* the first week *)

    FOOTY = 11;                     (* the cursor's date, and the two answers *)
    DATEX = 2;
    OKX = 13;                       (* "[ OK ]" - TuiBtns' own width for "OK" *)
    OKW = 6;
    CANX = 20;                      (* "[Cancel]" *)
    CANW = 10;

    PICKERSEL = 1;                  (* the calendar's stop in the pop-up's ring.

                                       The year field is the first stop, so a
                                       press in its cells is offered to it
                                       before the grid - which is the whole of
                                       how the two share one rectangle - and
                                       the calendar is the second, so it is the
                                       one the keyboard is on when the pop-up
                                       opens and the one Tab comes back to. *)
    TOPROW = 1;                     (* row 0 of the desk is the menu bar *)

TYPE

    (* The two point at each other: the picker drives the widget it belongs to
       and the widget holds the picker.  A pointer type may name its base
       record before that record is declared, as long as both are in the same
       scope, which is what lets the pair be written in either order. *)
    Picker = POINTER TO PickerDesc;

    DateInput* = POINTER TO DateInputDesc;

    DateInputDesc* = RECORD (TuiWidg.WidgetDesc)
        (* the strip, the button, and the window the widget was built in *)
        field: TuiFld.Field;
        btn: TuiBtns.Button;
        host: TuiWin.Window;

        (* the calendar: its window, what draws and drives it, and the field
           the year is typed into *)
        popup: TuiWin.Window;
        picker: Picker;
        yearF: TuiFld.Field;

        (* where the highlight is.  The month on show is this date's month. *)
        cur: Calendar.Date;

        (* the value, as the owner asked for it: a Calendar.Date and nothing
           else.  Everything the widget shows is derived from it, and it is
           written only by SetValue and by a commit. *)
        value*: Calendar.Date;

        draw*:     PROCEDURE (self: DateInput; target: TuiCanv.Canvas);
        onEvent*:  PROCEDURE (self: DateInput; VAR e: Events.Event): BOOLEAN;
        SetValue*: PROCEDURE (self: DateInput; date: Calendar.Date);
        GetValue*: PROCEDURE (self: DateInput; VAR date: Calendar.Date);
        SetPos*:   PROCEDURE (self: DateInput; x, y: INTEGER)
    END;

    PickerDesc = RECORD (TuiWidg.WidgetDesc)
        owner: DateInput;
        draw:    PROCEDURE (self: Picker; target: TuiCanv.Canvas);
        onEvent: PROCEDURE (self: Picker; VAR e: Events.Event): BOOLEAN
    END;

    (* The calendar under the date.  It owns nothing but the back-pointer it
       was made with, so its destructor is one line - but it has one, because
       a widget with an unbound Done field is a trap waiting for the first
       caller that reaches it through the base type. *)


(* Whether a date is the first the calendar has, and the last.  The steps below
   stop at these rather than running off an end: the year a date carries is four
   characters wide, and a date that walked past 9999 would be one DateFmt
   refuses to write. *)
PROCEDURE AtFirst (d: Calendar.Date): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (d.year = 1) & (d.month = 1) & (d.day = 1);
    RETURN r
END AtFirst;


PROCEDURE AtLast (d: Calendar.Date): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (d.year = 9999) & (d.month = 12) & (d.day = 31);
    RETURN r
END AtLast;


(* Bring a date inside the calendar: a year the text can hold, a month 1..12 and
   a day the month actually has.  A value arrives from outside this widget, so
   it can be anything at all, and everything below draws from the calendar -
   this is where a date that is not one is made sensible instead of being drawn
   as a hole in the grid. *)
PROCEDURE ClampDate (VAR d: Calendar.Date);
BEGIN
    IF d.year < 1 THEN d.year := 1 END;
    IF d.year > 9999 THEN d.year := 9999 END;
    IF d.month < 1 THEN d.month := 1 END;
    IF d.month > 12 THEN d.month := 12 END;
    IF d.day < 1 THEN d.day := 1 END;
    IF d.day > Calendar.DaysIn(d.year, d.month) THEN
        d.day := Calendar.DaysIn(d.year, d.month)
    END
END ClampDate;


(* Move a date by whole days, carrying into the month and the year.  A backward
   step is a WHILE and not a FOR, because this dialect has no FOR with a step. *)
PROCEDURE AddDays (VAR d: Calendar.Date; n: INTEGER);
VAR k: INTEGER;
BEGIN
    k := n;
    WHILE (k > 0) & ~AtLast(d) DO
        INC(d.day);
        IF d.day > Calendar.DaysIn(d.year, d.month) THEN
            d.day := 1;
            INC(d.month);
            IF d.month > 12 THEN
                d.month := 1;
                INC(d.year)
            END
        END;
        DEC(k)
    END;
    WHILE (k < 0) & ~AtFirst(d) DO
        DEC(d.day);
        IF d.day < 1 THEN
            DEC(d.month);
            IF d.month < 1 THEN
                d.month := 12;
                DEC(d.year)
            END;
            d.day := Calendar.DaysIn(d.year, d.month)
        END;
        INC(k)
    END
END AddDays;


(* Move a date by whole months, keeping the day where it can be kept: the 31st
   of a month that has thirty becomes the 30th, and the 31st of January stepped
   a month forward is the 28th or 29th of February.  Nothing is remembered about
   the day that was, because the calendar the user is looking at shows the day
   the cursor is on and not the day it once was. *)
PROCEDURE AddMonths (VAR d: Calendar.Date; n: INTEGER);
VAR k: INTEGER;
BEGIN
    k := n;
    WHILE (k > 0) & ~AtLast(d) DO
        INC(d.month);
        IF d.month > 12 THEN
            d.month := 1;
            INC(d.year)
        END;
        DEC(k)
    END;
    WHILE (k < 0) & ~AtFirst(d) DO
        DEC(d.month);
        IF d.month < 1 THEN
            d.month := 12;
            DEC(d.year)
        END;
        INC(k)
    END;
    ClampDate(d)
END AddMonths;


PROCEDURE SetYearOf (VAR d: Calendar.Date; y: INTEGER);
BEGIN
    IF y < 1 THEN y := 1 END;
    IF y > 9999 THEN y := 9999 END;
    d.year := y;
    ClampDate(d)
END SetYearOf;


(* src cut to at most n characters and terminated.  What a name longer than its
   column is drawn through. *)
PROCEDURE Cut (src: ARRAY OF CHAR; n: INTEGER; VAR dst: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
    i := 0;
    WHILE (i < n) & (i < LEN(src)) & (i < LEN(dst) - 1) & (src[i] # 0X) DO
        dst[i] := src[i];
        INC(i)
    END;
    IF i < LEN(dst) THEN
        dst[i] := 0X
    END
END Cut;


(* The year field's text: the first four characters of the date's own text.

   Deliberately that and not a number written out here: the year a date carries
   is the text DateFmt writes for it, and this widget has no arithmetic of its
   own that turns a number into digits. *)
PROCEDURE SyncYear (self: DateInput);
VAR buf: ARRAY 16 OF CHAR; y: ARRAY 8 OF CHAR;
BEGIN
    DateFmt.Format(self.cur, buf);
    y[0] := buf[0];
    y[1] := buf[1];
    y[2] := buf[2];
    y[3] := buf[3];
    y[4] := 0X;
    self.yearF.SetText(self.yearF, y)
END SyncYear;


(* The strip shows the value.  Every path that changes the value, and every path
   that refuses a typed one, ends here - which is why the text can never be left
   saying something the value does not. *)
PROCEDURE SyncValue (self: DateInput);
VAR buf: ARRAY 16 OF CHAR;
BEGIN
    DateFmt.Format(self.value, buf);
    self.field.SetText(self.field, buf)
END SyncValue;


(* Take the pop-up down and give the keyboard back to the window the widget
   lives in.

   That window was the active one all along - the pop-up is not in the desk's
   z-order and never took it - so marking its ring again is all it takes for the
   field to draw its caret as the keyboard's once more.  Focus is what does the
   marking, and the window's own Focus is the call that does it. *)
PROCEDURE Close (self: DateInput);
BEGIN
    self.popup.visible := FALSE;
    self.popup.Focus(self.popup, FALSE);
    Tui.SetPopup(NIL);
    IF self.host.visible THEN
        self.host.Focus(self.host, TRUE)
    END
END Close;


PROCEDURE Commit (self: DateInput);
BEGIN
    self.value := self.cur;
    SyncValue(self);
    Close(self)
END Commit;


PROCEDURE Cancel (self: DateInput);
BEGIN
    SyncValue(self);                (* the value it already had, written again *)
    Close(self)
END Cancel;


(* What was typed into the year field becomes the cursor's year.  Text the
   reader refuses, and a year the four characters cannot hold, leave the date
   alone - and the field is written again from the date either way, so it always
   shows the year in force rather than what was typed. *)
PROCEDURE ApplyYear (self: DateInput);
VAR s: ARRAY 16 OF CHAR; y: INTEGER; ok: BOOLEAN;
BEGIN
    self.yearF.GetText(self.yearF, s);
    ok := Strings.ToInt(s, y);
    IF ok & (y >= 1) & (y <= 9999) THEN
        SetYearOf(self.cur, y)
    END;
    SyncYear(self)
END ApplyYear;


PROCEDURE StepDay (self: DateInput; n: INTEGER);
BEGIN
    AddDays(self.cur, n);
    SyncYear(self)
END StepDay;


PROCEDURE StepMonth (self: DateInput; n: INTEGER);
BEGIN
    AddMonths(self.cur, n);
    SyncYear(self)
END StepMonth;


PROCEDURE StepYear (self: DateInput; n: INTEGER);
BEGIN
    SetYearOf(self.cur, self.cur.year + n);
    SyncYear(self)
END StepYear;


PROCEDURE FirstDay (self: DateInput);
BEGIN
    self.cur.day := 1;
    SyncYear(self)
END FirstDay;


PROCEDURE LastDay (self: DateInput);
BEGIN
    self.cur.day := Calendar.DaysIn(self.cur.year, self.cur.month);
    SyncYear(self)
END LastDay;


(* A day of the grid, which is also the answer: picking a day is what a calendar
   is for, so a click on one commits rather than waiting for [ OK ]. *)
PROCEDURE PickDay (self: DateInput; d: INTEGER);
BEGIN
    self.cur.day := d;
    Commit(self)
END PickDay;


(* Put the calendar up beside the field.

   The field's own cell is window-local, so the desk cell comes from the window
   the widget was built in plus the widget's own place in it.  The pop-up goes
   under the field when there is room for it below and above it when there is
   not, and is then brought inside the desk - the menu bar at the top and the
   status line at the bottom are the desk's own rows and are never covered. *)
PROCEDURE Open (self: DateInput);
VAR px, py, c, r: INTEGER;
BEGIN
    self.cur := self.value;
    ClampDate(self.cur);
    SyncYear(self);
    (* the keyboard is not in the strip any more, so its caret is not drawn as
       the keyboard's while the calendar has it; Close marks the ring again *)
    self.field.focused := FALSE;

    c := Tui.Cols();
    r := Tui.Rows();
    px := self.host.x + self.x;
    py := self.host.y + self.y + 1;
    IF py + POPH > r - 1 THEN
        py := self.host.y + self.y - POPH
    END;
    IF px > c - POPW THEN px := c - POPW END;
    IF px < 0 THEN px := 0 END;
    IF py > r - 1 - POPH THEN py := r - 1 - POPH END;
    IF py < TOPROW THEN py := TOPROW END;

    self.popup.Move(self.popup, px, py);
    self.popup.visible := TRUE;
    TuiWin.SetRing(self.popup, PICKERSEL);
    self.popup.Focus(self.popup, TRUE);
    Tui.SetPopup(self.popup)
END Open;


(* Draw a house button - the brackets TuiBtns draws and the pair it uses - into
   a canvas this module owns.  The footer's two answers are drawn here rather
   than being TuiBtns: they are inside the calendar's own window, they are
   offered no event of their own (the picker hit tests them), and a widget that
   is never in a ring has no keyboard state worth carrying. *)
PROCEDURE FrameButton (target: TuiCanv.Canvas; x, y: INTEGER;
                       label: ARRAY OF CHAR; attr: INTEGER);
VAR n: INTEGER;
BEGIN
    n := Strings.Length(label) + 4;
    target.Fill(target, x, y, n, 1, " ", attr);
    target.Put(target, x, y, "[", attr);
    target.Put(target, x + n - 1, y, "]", attr);
    target.Print(target, x + 2, y, label, attr)
END FrameButton;


(* The calendar: the month and the two arrows that step it, the year's own
   field, the weekday header, the six weeks and the footer.

   Everything is read at the moment of drawing - the pairs from TuiTheme, the
   names and the week's first day from Locale - so a theme switch or a locale
   change is one frame away and nothing has to be told. *)
PROCEDURE PickerDraw (self: Picker; target: TuiCanv.Canvas);
VAR
    o: DateInput;
    i, col, x, y, d, n, first, start, dim, a, sa, b: INTEGER;
    mtx: ARRAY 24 OF CHAR;          (* what DateFmt writes *)
    mbuf: ARRAY 16 OF CHAR;         (* a name, cut to the room there is *)
    dbuf: ARRAY 4 OF CHAR;          (* a day number *)
    nm: ARRAY Locale.DAYLEN OF CHAR;
    tmp: Calendar.Date;
BEGIN
    o := self.owner;
    a := TuiTheme.Attr(TuiTheme.List);
    IF self.focused THEN
        sa := TuiTheme.Attr(TuiTheme.ListSel)
    ELSE
        sa := TuiTheme.Attr(TuiTheme.ListSelIdle)
    END;

    (* the calendar's own surface: the frame's pair is what is behind it, and a
       grid that is the same colour as the box around it does not read as a
       panel *)
    target.Fill(target, self.x, self.y, self.width, self.height, " ", a);

    dim := Calendar.DaysIn(o.cur.year, o.cur.month);

    (* the two month arrows and the month's name *)
    target.Fill(target, LARROWX, HDRY, ARROWW, 1, " ", TuiTheme.Attr(TuiTheme.Button));
    target.Put(target, LARROWX, HDRY, "[", TuiTheme.Attr(TuiTheme.Button));
    target.Put(target, LARROWX + 1, HDRY, TuiCanv.ARROW_LEFT,
               TuiTheme.Attr(TuiTheme.Button));
    target.Put(target, LARROWX + 2, HDRY, "]", TuiTheme.Attr(TuiTheme.Button));
    target.Fill(target, RARROWX, HDRY, ARROWW, 1, " ", TuiTheme.Attr(TuiTheme.Button));
    target.Put(target, RARROWX, HDRY, "[", TuiTheme.Attr(TuiTheme.Button));
    target.Put(target, RARROWX + 1, HDRY, TuiCanv.ARROW_RIGHT,
               TuiTheme.Attr(TuiTheme.Button));
    target.Put(target, RARROWX + 2, HDRY, "]", TuiTheme.Attr(TuiTheme.Button));

    Locale.Month(o.cur.month, nm);
    Cut(nm, MONW, mbuf);
    n := Strings.Length(mbuf);
    target.Fill(target, MONX, HDRY, MONW, 1, " ", a);
    target.Print(target, MONX + (MONW - n) DIV 2, HDRY, mbuf, a);

    (* The weekday header.  Which name stands in the first column is the
       locale's decision: the table counts from Monday, so a week that starts on
       Sunday starts six places along it. *)
    IF Locale.MondayFirst() THEN start := 0 ELSE start := 6 END;
    FOR col := 0 TO NCOLS - 1 DO
        Locale.Day((start + col) MOD 7, nm);
        Cut(nm, 3, mbuf);
        n := Strings.Length(mbuf);
        x := GRIDX + col * CELLW;
        target.Fill(target, x, WDAY_Y, CELLW, 1, " ", a);
        target.Print(target, x + (CELLW - n + 1) DIV 2, WDAY_Y, mbuf, a)
    END;

    (* The six weeks.  The column of the 1st is its weekday counted from the
       week's own first day; the cells before it and after the last day belong
       to the months either side and are drawn as a shade rather than as a
       number, because this is a month and not a run of days. *)
    first := (Calendar.DayOfWeek(o.cur.year, o.cur.month, 1) - start + 7) MOD 7;
    d := 1 - first;
    FOR i := 0 TO NROWS - 1 DO
        y := DAY_Y + i;
        FOR col := 0 TO NCOLS - 1 DO
            x := GRIDX + col * CELLW;
            IF (d >= 1) & (d <= dim) THEN
                (* The cell's number is the day part of the text DateFmt writes
                   for that date, so even here nothing turns a date into digits
                   of its own.  The leading zero is dropped: a calendar shows 7,
                   not 07.  The date is one this month has, so Format's own
                   check cannot fire. *)
                tmp := o.cur;
                tmp.day := d;
                DateFmt.Format(tmp, mtx);
                IF mtx[8] = "0" THEN
                    dbuf[0] := mtx[9];
                    dbuf[1] := 0X
                ELSE
                    dbuf[0] := mtx[8];
                    dbuf[1] := mtx[9];
                    dbuf[2] := 0X
                END;
                n := Strings.Length(dbuf);
                IF d = o.cur.day THEN b := sa ELSE b := a END;
                target.Fill(target, x, y, CELLW, 1, " ", b);
                target.Print(target, x + (CELLW - n + 1) DIV 2, y, dbuf, b)
            ELSE
                target.Fill(target, x, y, CELLW, 1, TuiCanv.SHADE_LIGHT, a)
            END;
            INC(d)
        END
    END;

    (* the footer: the day the cursor is on, written by the same Format the
       strip is written by, and the two answers *)
    DateFmt.Format(o.cur, mtx);
    target.Fill(target, DATEX, FOOTY, 10, 1, " ", a);
    target.Print(target, DATEX, FOOTY, mtx, a);
    FrameButton(target, OKX, FOOTY, "OK", TuiTheme.Attr(TuiTheme.ButtonDefault));
    FrameButton(target, CANX, FOOTY, "Cancel", TuiTheme.Attr(TuiTheme.Button))
END PickerDraw;


PROCEDURE PickerEvent (self: Picker; VAR e: Events.Event): BOOLEAN;
VAR
    o: DateInput; handled: BOOLEAN;
    col, row, d, first, start, dim: INTEGER;
BEGIN
    o := self.owner;
    handled := FALSE;

    IF e.kind = Events.KEYBOARD THEN
        IF self.focused THEN
            handled := TRUE;
            (* The shifted arms stand first: a Shift+PgUp carries the same scan
               code as a PgUp, so the plain arm would take it. *)
            IF Events.IsKey(e, Events.K_PGUP) & e.shift THEN
                StepYear(o, -1)
            ELSIF Events.IsKey(e, Events.K_PGDN) & e.shift THEN
                StepYear(o, 1)
            ELSIF Events.IsKey(e, Events.K_PGUP) THEN
                StepMonth(o, -1)
            ELSIF Events.IsKey(e, Events.K_PGDN) THEN
                StepMonth(o, 1)
            ELSIF Events.IsKey(e, Events.K_LEFT) THEN
                StepDay(o, -1)
            ELSIF Events.IsKey(e, Events.K_RIGHT) THEN
                StepDay(o, 1)
            ELSIF Events.IsKey(e, Events.K_UP) THEN
                StepDay(o, -7)
            ELSIF Events.IsKey(e, Events.K_DOWN) THEN
                StepDay(o, 7)
            ELSIF Events.IsKey(e, Events.K_HOME) THEN
                FirstDay(o)
            ELSIF Events.IsKey(e, Events.K_END) THEN
                LastDay(o)
            ELSIF Events.IsKey(e, Events.K_ENTER) THEN
                Commit(o)
            ELSIF Events.IsKey(e, Events.K_ESC) THEN
                Cancel(o)
            ELSE
                handled := FALSE             (* Tab: the ring walks to the year *)
            END
        ELSIF o.yearF.focused THEN
            (* The year field declines Enter and Esc - they belong to whatever
               put the field there, and what put it there is this calendar.  It
               is offered the event first, being first in the ring, so these two
               arms are reached exactly when the year field has the keyboard. *)
            IF Events.IsKey(e, Events.K_ENTER) THEN
                ApplyYear(o);
                handled := TRUE
            ELSIF Events.IsKey(e, Events.K_ESC) THEN
                Cancel(o);
                handled := TRUE
            END
        END

    ELSIF e.kind = Events.MOUSE THEN
        IF Events.IsPress(e) & TuiWidg.Inside(self, e.x, e.y) THEN
            (* A press inside the calendar is taken whatever it landed on, so
               that a click in the blank cells around the grid cannot reach the
               window behind. *)
            handled := TRUE;
            IF (e.y = HDRY) & (e.x >= LARROWX) & (e.x < LARROWX + ARROWW) THEN
                StepMonth(o, -1)
            ELSIF (e.y = HDRY) & (e.x >= RARROWX) & (e.x < RARROWX + ARROWW) THEN
                StepMonth(o, 1)
            ELSIF (e.y = FOOTY) & (e.x >= OKX) & (e.x < OKX + OKW) THEN
                Commit(o)
            ELSIF (e.y = FOOTY) & (e.x >= CANX) & (e.x < CANX + CANW) THEN
                Cancel(o)
            ELSIF (e.y >= DAY_Y) & (e.y < DAY_Y + NROWS) &
                  (e.x >= GRIDX) & (e.x < GRIDX + NCOLS * CELLW) THEN
                col := (e.x - GRIDX) DIV CELLW;
                row := e.y - DAY_Y;
                IF Locale.MondayFirst() THEN start := 0 ELSE start := 6 END;
                first := (Calendar.DayOfWeek(o.cur.year, o.cur.month, 1)
                          - start + 7) MOD 7;
                d := 1 - first + row * NCOLS + col;
                dim := Calendar.DaysIn(o.cur.year, o.cur.month);
                IF (d >= 1) & (d <= dim) THEN
                    PickDay(o, d)
                END
            END
        ELSIF Events.IsPress(e) THEN
            (* A press that came down outside the calendar - on the desk, or on
               the pop-up's own frame.  That is the way out with the mouse, and
               it answers what Esc answers: the value is left as it was. *)
            Cancel(o);
            handled := TRUE
        END
    END;

    IF handled THEN
        e.kind := Events.NONE
    END;
    RETURN handled
END PickerEvent;


(* The two ways in for the pop-up's ring, which holds TuiWidg.Widget and does
   not know what kind of widget this is. *)
PROCEDURE PickerTake (w: TuiWidg.Widget; on: BOOLEAN);
VAR p: Picker;
BEGIN
    IF w IS Picker THEN
        p := w(Picker);
        p.focused := on
    END
END PickerTake;


PROCEDURE PickerHandle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR p: Picker; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS Picker THEN
        p := w(Picker);
        r := p.onEvent(p, e)
    END;
    RETURN r
END PickerHandle;


PROCEDURE draw (self: DateInput; target: TuiCanv.Canvas);
BEGIN
    IF self.visible THEN
        self.field.draw(self.field, target);
        self.btn.draw(self.btn, target);

        (* The pop-up's frame and its title are TuiWin.Draw's - the desk calls
           that, because the desk is what holds the window.  What is inside is
           this widget's, and the one place this widget is drawn is here, so
           the calendar is painted from here.  Nothing clears a canvas between
           frames, which is why the window is refreshed first. *)
        IF self.popup.visible THEN
            self.popup.Refresh(self.popup);
            self.picker.draw(self.picker, self.popup.canvas);
            self.yearF.draw(self.yearF, self.popup.canvas)
        END
    END
END draw;


PROCEDURE onEvent (self: DateInput; VAR e: Events.Event): BOOLEAN;
VAR handled: BOOLEAN; s: ARRAY 32 OF CHAR; d: Calendar.Date; ok: BOOLEAN;
BEGIN
    handled := FALSE;
    IF e.kind = Events.KEYBOARD THEN
        IF self.focused THEN
            IF Events.IsKey(e, Events.K_ENTER) THEN
                (* Enter reads what is in the strip.  Text DateFmt refuses
                   leaves the value where it was, and the strip is written
                   again from the value either way - so a mistyped date is
                   undone by the Enter that tried to take it. *)
                self.field.GetText(self.field, s);
                ok := DateFmt.Parse(s, d);
                IF ok THEN
                    (* Clamped even though Parse has already been through it.
                       This is the one way into value that does not come from a
                       keystroke this widget handled, and the rule ClampDate
                       exists for is that everything drawn from the calendar has
                       been through it - a rule with an exception in it is a
                       rule nobody can rely on. *)
                    ClampDate(d);
                    self.value := d
                END;
                SyncValue(self);
                handled := TRUE
            ELSIF Events.IsKey(e, Events.K_DOWN) THEN
                Open(self);
                handled := TRUE
            ELSE
                (* everything else, typing included.  Tab is declined by the
                   field itself, so the window's ring still walks. *)
                handled := self.field.onEvent(self.field, e)
            END
        END
    ELSIF e.kind = Events.MOUSE THEN
        IF self.btn.onEvent(self.btn, e) THEN
            Open(self);
            handled := TRUE
        ELSIF self.field.onEvent(self.field, e) THEN
            handled := TRUE
        END
    END;
    IF handled THEN
        e.kind := Events.NONE
    END;
    RETURN handled
END onEvent;


(* focused is set with the strip's own flag, because that flag is also what
   draws the caret: a widget whose keyboard is elsewhere must not show a caret
   that reads as the one typing would go to. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR d: DateInput;
BEGIN
    IF w IS DateInput THEN
        d := w(DateInput);
        d.focused := on;
        d.field.focused := on
    END
END Take;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR d: DateInput; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS DateInput THEN
        d := w(DateInput);
        r := d.onEvent(d, e)
    END;
    RETURN r
END Handle;


PROCEDURE SetValue (self: DateInput; date: Calendar.Date);
BEGIN
    self.value := date;
    ClampDate(self.value);
    SyncValue(self)
END SetValue;


PROCEDURE GetValue (self: DateInput; VAR date: Calendar.Date);
BEGIN
    date := self.value
END GetValue;


PROCEDURE SetPos (self: DateInput; x, y: INTEGER);
BEGIN
    self.x := x;
    self.y := y;
    self.field.x := x;
    self.field.y := y;
    self.field.width := self.width - self.btn.width - BTNGAP;
    self.btn.SetPos(self.btn, x + self.width - self.btn.width, y)
END SetPos;


PROCEDURE DonePicker (self: Oberon.Object);
VAR p: Picker;
BEGIN
    p := self(Picker);
    DISPOSE(p)
END DonePicker;


(* Give the widget back: the pop-up window with its canvas, then what lives in
   it, then the strip and the button, then the record.

   It takes `Oberon.Object` and guards down because it is what goes into the
   inherited `Done` field, whose declared type is `PROCEDURE (self: Object)`;
   Dispose, the second name this class used to carry for the same act, is gone
   - Oberon.mod has the rule.  Everything it frees is freed by the same means:
   the widgets by their own inherited field, the picker by its. *)
PROCEDURE DoneDateInput (self: Oberon.Object);
VAR d: DateInput;
BEGIN
    d := self(DateInput);
    IF d.popup.visible THEN
        Tui.SetPopup(NIL)
    END;
    Oberon.Done(d.popup);
    Oberon.Done(d.yearF);
    Oberon.Done(d.picker);
    Oberon.Done(d.field);
    Oberon.Done(d.btn);
    DISPOSE(d)
END DoneDateInput;


(* Where it draws itself, for a window that paints what it owns. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR d: DateInput;
BEGIN
    IF w IS DateInput THEN
        d := w(DateInput);
        d.draw(d, target)
    END
END Paint;


(* The host is asked for last and the date before it, because the date is what
   the widget is about and the window is where it is to live. *)
PROCEDURE Create* (x, y, w, h: INTEGER; date: Calendar.Date;
                   host: TuiWin.Window): DateInput;
VAR d: DateInput; p: Picker;
BEGIN
    ASSERT(host # NIL);
    NEW(d);
    d.x := x;
    d.y := y;
    d.width := w;
    d.height := h;
    d.visible := TRUE;
    d.focused := FALSE;
    d.canvas := NIL;
    d.host := host;

    d.field := TuiFld.Create(x, y, w, NIL);
    d.btn := TuiBtns.Create(">>", 0, FALSE, NIL);
    ASSERT(w > d.btn.width + BTNGAP);
    d.btn.SetPos(d.btn, x + w - d.btn.width, y);
    d.field.width := w - d.btn.width - BTNGAP;

    d.value := date;
    ClampDate(d.value);
    d.cur := d.value;

    d.yearF := TuiFld.Create(YEARX, HDRY, YEARW, NIL);

    NEW(p);
    p.owner := d;
    TuiWidg.SetRect(p, 1, 1, POPCLIENTW, POPCLIENTH);
    p.visible := TRUE;
    p.focused := FALSE;
    p.canvas := NIL;
    p.draw := PickerDraw;
    p.onEvent := PickerEvent;
    p.handler := PickerHandle;
    p.taker := PickerTake;
    p.Done := DonePicker;
    d.picker := p;

    (* The pop-up window: made here, filled from draw above, and never added to
       the desk.  Its title is what Windows draws on its top line. *)
    d.popup := TuiWin.Create(0, 0, POPW, POPH, "Date");
    d.popup.visible := FALSE;
    TuiWin.AddWidget(d.popup, d.yearF);
    TuiWin.AddWidget(d.popup, d.picker);
    TuiWin.SetRing(d.popup, PICKERSEL);

    d.lastCmd := 0;
    d.draw := draw;
    d.onEvent := onEvent;
    d.handler := Handle;
    d.taker := Take;
    d.painter := Paint;
    d.onCommand := NIL;                 (* it commits through its own field and
                                           button, and fires no ids *)
    d.SetValue := SetValue;
    d.GetValue := GetValue;
    d.SetPos := SetPos;
    d.Done := DoneDateInput;

    TuiWin.Own(host, d);
    SyncValue(d);
    SyncYear(d);
    RETURN d
END Create;

END TuiDate.
