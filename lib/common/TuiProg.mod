MODULE TuiProg;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A progress bar: one row of cells, the first part of it filled and the rest
   not, so that how far something has got is a thing on the screen rather than a
   number on the status line.

   It is the one widget here with no event handling at all, and it has no
   onEvent field for that reason: there is nothing to do to a bar.  It shows
   what the owner sets and the owner reads nothing back, so a bar that could be
   clicked would be a slider, which is a different widget and not this one.

   Its whole meaning is its width, so it is placed and sized in one call rather
   than by a position and a width that have to be kept in step by hand.

   The value is a percentage and not a count.  A bar that held a count would
   have to know what it was counting, and the cell it fills is a fraction of the
   width whatever the owner's own scale is - which is what lets the same widget
   show a list position and a download. *)

IMPORT TuiCanv, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST
    FULL = 100;                     (* the whole of it, per cent *)

TYPE

    ProgressBar* = POINTER TO ProgressBarDesc;

    ProgressBarDesc* = RECORD (TuiWidg.WidgetDesc)
        percent*: INTEGER;          (* how full, 0 .. 100 *)
        (* The window that owns it.  A bar is drawn with everything else that
           window owns and is never offered an event, because it has no handler
           to offer one to - which is why it is owned and not in the ring. *)
        host: TuiWin.Window;

        draw*:     PROCEDURE (self: ProgressBar; target: TuiCanv.Canvas);
        SetRect*:  PROCEDURE (self: ProgressBar; x, y, w: INTEGER);
        SetValue*: PROCEDURE (self: ProgressBar; percent: INTEGER)
    END;


(* The filled part as a solid block and the rest as a shade of the same cell, so
   that the bar reads as one strip of which a part is reached rather than as two
   rows side by side.

   The count of filled cells is rounded down, which is what makes the two ends
   exact: nought per cent fills nothing at all and a hundred per cent fills every
   cell, with no width that answers otherwise.

   Both halves are read from TuiTheme here and now - a theme switch shows itself
   on the next frame with nothing being told, the same as everywhere else. *)
PROCEDURE draw (self: ProgressBar; target: TuiCanv.Canvas);
VAR n, f: INTEGER;
BEGIN
    n := self.width;
    f := n * self.percent DIV FULL;
    IF f > 0 THEN
        target.Fill(target, self.x, self.y, f, 1, TuiCanv.BLOCK,
                    TuiTheme.Attr(TuiTheme.Progress))
    END;
    IF f < n THEN
        target.Fill(target, self.x + f, self.y, n - f, 1, TuiCanv.SHADE_LIGHT,
                    TuiTheme.Attr(TuiTheme.ProgressEmpty))
    END
END draw;


PROCEDURE SetRect (self: ProgressBar; x, y, w: INTEGER);
BEGIN
    self.x := x;
    self.y := y;
    self.width := w;
    self.height := 1
END SetRect;


(* A value outside the range is brought into it rather than refused: what a bar
   shows is the owner's arithmetic, and a program that counted one item too many
   wants a full bar, not a trap. *)
PROCEDURE SetValue (self: ProgressBar; percent: INTEGER);
VAR p: INTEGER;
BEGIN
    p := percent;
    IF p < 0 THEN p := 0 END;
    IF p > FULL THEN p := FULL END;
    self.percent := p
END SetValue;


(* Give the bar back.  It holds nothing but its own record - so this is one
   line, and it stands before Create because Create binds it into the record's
   Done field, and a procedure has to be declared before it is used. *)
PROCEDURE DoneProgressBar (self: Oberon.Object);
VAR p: ProgressBar;
BEGIN
    p := self(ProgressBar);
    DISPOSE(p)
END DoneProgressBar;


(* Where it draws itself, for a window that paints what it owns. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR b: ProgressBar;
BEGIN
    IF w IS ProgressBar THEN
        b := w(ProgressBar);
        b.draw(b, target)
    END
END Paint;


(* The window it is in.  It has no geometry here: a bar is placed and sized in
   one call, so the owner sets the rectangle after it is made. *)
PROCEDURE Create* (host: TuiWin.Window): ProgressBar;
VAR b: ProgressBar;
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
    b.percent := 0;
    b.host := host;
    b.draw := draw;
    b.handler := NIL;                   (* there is nothing to do to a bar *)
    b.taker := NIL;
    b.painter := Paint;
    b.onCommand := NIL;
    b.SetRect := SetRect;
    b.SetValue := SetValue;
    b.Done := DoneProgressBar;
    TuiWin.Own(host, b);
    RETURN b
END Create;

END TuiProg.
