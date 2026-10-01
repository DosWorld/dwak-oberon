MODULE TuiTbl;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A table: a grid of cells the widget does not own.

   The owner answers four questions and the table asks them.  How many columns
   there are; what one column is called, how wide it should be and how its values
   are set; how many rows there are; and what the text of one cell is.  Nothing
   here holds a row, a cell or a copy of either - a
   table is a window onto data that stays where it was - so a table is never
   stale: an owner that changes a cell shows the new one on the next frame
   without telling anybody anything.

   That is what makes the three notifications worth having and worth reading
   carefully.  They are not how a change reaches the screen; a change reaches the
   screen by itself.  They are how a change reaches the table's own state, which
   is the part of this that is the table's and not the owner's: which row the
   cursor is on, which rows are marked, how far the view is scrolled.  A row that
   has gone leaves a cursor and a mark pointing past the end, and that is what
   RowsChanged puts right.  An owner that never calls any of them is still
   correct and still current.  RowChanged is the narrow one: the data of one row
   changed and nothing else did, so no cursor, mark or scroll needs putting
   right - the row is drawn afresh on the next frame either way - and what it is
   for is an owner that wants the row it just changed brought into sight.

   The fourth question is asked once.  A column's width is read when the table
   first draws and again only when the owner says the definitions have changed,
   because after that a width is not the owner's: it is the table's, and the
   mouse can drag it.  Asking afresh every frame would take the width back out of
   the hand that moved it one frame later, which is the whole reason the answer
   is remembered.

   Each column is followed by a cell of its own, and that cell is the handle a
   width is dragged by.  There has to be one: a boundary between two columns is
   either the last cell of one or the first cell of the next, both of them hold
   text, and a press on either would have to guess which was meant.  A cell that
   belongs to neither column can only mean one thing, and it doubles as the
   divider that makes a row of titles readable.

   Two things are frozen.  The header stays where it is while the rows scroll
   under it - the reason a header is drawn at all is to say what the column below
   it holds, and a header that scrolled away would stop saying it exactly when
   the table got long enough for it to matter.  And the mark column stays where
   it is while the columns scroll under the pointer: a mark is a fact about a
   row, and a row that is half scrolled off is still the row the mark is about.

   The colours are not this module's to choose and it chooses none of them: the
   strip, the field, the cursor row, that row in a window without the keyboard
   and the two bars are slots in TuiTheme like everything else's, so a theme
   switch repaints the table with the rest of the interface and the second theme
   draws it as a monochrome table.  What is here is only which slot a cell is
   drawn in - and in the coloured theme those five slots are FoxPro for MS-DOS's
   Browse window, which is what a table of this kind looked like when the
   interface this one is written in the manner of was in use.

   The selection is one set of rows and it is drawn one way.  sel is the row the
   cursor is on, with anchor the other end of a range the Shift key grows and a
   plain arrow collapses - the shape a text area's selection already has - and
   the marks are rows ticked one at a time with Space or with a click that
   carries Ctrl, which survive the cursor moving away from them.  Chosen is the
   two together and it is the whole of what the picture shows: every chosen row
   carries a star in the mark column, whether a Shift spanned it or a Space
   ticked it, and no other row carries one.  A row with a star is therefore a
   chosen row and a chosen row is a row with a star, which is what lets an owner
   reading Chosen and a user reading the screen agree about the same table.
   IsMarked is the half that was ticked by hand and nmarks how many; nothing is
   drawn from either, and a table made single-row answers no to both and refuses
   the gestures that would make a mark.  A single-row table has no mark column
   at all: there the cursor's own pair is the selection, as it is in every
   single-row list.

   The table fires ids and takes none: onCommand is NIL, like a list's, since a
   table chooses and the owner reads what it chose.  Two ids go out, because one
   could not say enough.  cmd is the selection moving, a mark changing, or a
   width finishing its drag.  headCmd is a click on a column header, with selCol
   naming the column, and it is a separate id for the one thing an owner does
   with it - sorting - which a cursor move must not be mistaken for.

   The ids go out through TuiWin.Notify rather than into lastCmd, which is what
   a widget that has a window to hand to fires through.  Both ids can be in one
   event here, and one field cannot hold two.

   Typing finds a row, exactly as it does in a list: a printable character with
   neither Ctrl nor Alt held is taken by the table and the cursor goes to the
   first row whose cell in the *current* column begins with what has been typed,
   and pressing the same letter again walks to the next such row.  The current
   column is the one Enter would open an editor on - the column the header last
   chose, or the first - because a table has no cursor among its columns and
   that is the only reading of "the column the user is in" this widget has.

   The search is a run of letters: any other key ends it, and the run is what
   the prefix is rather than a prefix a clock would forget.  Nothing is drawn
   for it and no id of its own is fired for it - the cursor lands on a row, and
   that is a selection moving, which is what cmd already says.  FindStr is the
   prefix, for an owner that wants to show it. *)

IMPORT TuiCanv, Charset, Clipboard, Events, Strings, TuiPage, TuiTheme, TuiWidg, TuiWin,
       Oberon;

CONST

    (* The most columns a table holds.  A table's shape is the owner's answer to
       a question and not something discovered while it runs: ColsChanged is what
       re-reads it, and a number that moved without that call would be a number
       the cache could not keep up with. *)
    MAXCOLS* = 16;
    MAXCOLNAME = 33;                (* bytes a column title takes, its 0X too *)

    (* The most rows a table keeps a mark for.  The data itself is the owner's
       and may be longer: the rows past this are drawn and scrolled like any
       other, and simply cannot be marked. *)
    MAXROWS* = 512;

    MINCOLW = 3;                    (* the narrowest a column may be dragged to *)
    MARKCOL = 1;                    (* columns a mark cell takes, in a table that
                                       may hold marks at all *)
    TRACK = 1;                      (* cells a scrollbar takes, one way or the
                                       other - a column, or a row *)
    CELLLEN = 128;                  (* bytes one cell's text takes, its 0X too *)
    MAXFIND* = 16;                  (* characters a search holds, its 0X too.  A
                                       prefix longer than this one has stopped
                                       being a prefix and starts again *)

    HEADROWS = 2;                   (* the widget's own rows: the header and the
                                       rule under it *)
    HGAP = 1;                       (* the cell between two columns *)

TYPE

    Table* = POINTER TO TableDesc;

    (* The four questions.  A column's width is what the owner would like it to
       be; the table clamps it, and the mouse may change it afterwards, so Width
       is what answers what it is now.  `right` is how the column's *values* are
       set - against the right end of the strip, or against the left - and it is
       asked once per column and remembered: the mouse changing a width does not
       change an alignment.  Titles are not a question: a title is always set
       against the left end, whatever the column's values do, because a row of
       titles that each obeyed its own column's alignment reads as ragged and a
       reader scans titles down their first letter and not their last. *)
    ColsProc*    = PROCEDURE (self: Table): INTEGER;
    ColDescProc* = PROCEDURE (self: Table; i: INTEGER; VAR title: ARRAY OF CHAR;
                              VAR width: INTEGER; VAR right: BOOLEAN);
    RowsProc*    = PROCEDURE (self: Table): INTEGER;
    CellProc*    = PROCEDURE (self: Table; row, col: INTEGER;
                              VAR dst: ARRAY OF CHAR);

    (* The two questions an *editable* table asks, and the whole of the setting.
       Editable says whether a cell may be written at all; SetCell is handed the
       new text when an edit is committed.  A table given neither is a table with
       no editor - Enter does what it always did and the owner's data is the
       widget's to read and never to write - and that is why they are a separate
       act from SetSource rather than two more parameters of it: what a table is
       *about* is its columns and its rows, and these two are a permission. *)
    EditProc*    = PROCEDURE (self: Table; row, col: INTEGER): BOOLEAN;
    SetProc*     = PROCEDURE (self: Table; row, col: INTEGER; s: ARRAY OF CHAR);

    TableDesc* = RECORD (TuiWidg.WidgetDesc)

        (* The four questions.  NIL answers nothing: a table with no RowsProc has
           no rows and one with no ColsProc has no columns, which is what a table
           made and never given a source shows. *)
        Cols*:     ColsProc;
        ColDesc*:  ColDescProc;
        RowsProc*: RowsProc;
        Cell*:     CellProc;

        (* The environment the owner's callbacks narrow back to.  The cast is the
           owner's business; this is the one field here the table itself never
           dereferences - it only carries it back, which is what a widget in a
           module that may not name the owner's record can do.  An owner whose
           data is its own module's state passes whatever it likes and never
           reads it back. *)
        env*: TuiWidg.Widget;

        (* The permission to write, given by SetEdit and by nothing else.  Both
           NIL is a read-only table, which is what every table was before there
           was an editor and what a table made and never told still is. *)
        Editable*: EditProc;
        SetCell*:  SetProc;

        (* The columns, read once and kept.  loaded says whether they have been
           read at all: a table whose source is set before its first frame reads
           them on that frame, and one whose owner has changed the definitions
           behind its back is told with ColsChanged rather than asked again. *)
        ncol: INTEGER;
        widths: ARRAY MAXCOLS OF INTEGER;
        rights: ARRAY MAXCOLS OF BOOLEAN;
        titles: ARRAY MAXCOLS, MAXCOLNAME OF CHAR;
        loaded: BOOLEAN;

        (* Where the view is.  sel is the cursor row, anchor the other end of the
           range the cursor grew from, top the first data row on show and left
           the first cell of the row on show.  selCol is the column the last
           click on the header chose, -1 for none. *)
        sel*, anchor*, top*: INTEGER;
        left*: INTEGER;
        selCol*: INTEGER;

        (* Several rows may be chosen at once.  A table that may not answers no
           to IsMarked, refuses Space and refuses the Ctrl click, and gives up
           the marks it has when it is told so - the setting is the owner's, and
           turning it off is the owner saying the marks mean nothing now.  It is
           also what the mark column is drawn for: single-row, there is no such
           column and the text begins at the widget's own first cell. *)
        multi*: BOOLEAN;
        marks: ARRAY MAXROWS OF BOOLEAN;
        nmarks*: INTEGER;

        (* What has been typed towards a search, and how much of it there is.
           The buffer is the search: an empty one is a table that is not being
           searched, and there is no second flag saying so.

           THE BUFFER HOLDS UTF-8 AND findcp IS THE CHARACTER THAT PUT THE LAST
           BYTE IN IT.  One character is not one byte above ASCII - a Cyrillic
           letter is two or three - so "is this the same letter as the last one"
           cannot be asked of the last byte: the second byte of и is B8H and the
           second byte of its own first byte is nothing at all.  The code point
           the user typed is kept beside the buffer and is what the repeat test
           compares, exactly as a list's search does. *)
        find: ARRAY MAXFIND OF CHAR;
        nfind: INTEGER;
        findcp: INTEGER;

        (* The editor, up or not.  It is a mode of this widget and not a second
           object: the cell it is in is the cursor's cell and the column is
           ecol, so nothing has to be kept in step with the cursor and there is
           nothing to dispose of when the table is.  ebuf is the text as it is
           being typed and the cell's own value until it commits; ecaret is where
           the next character goes, efirst the index the cell's left end shows -
           the same view-on-a-window a field has, and for the same reason, a
           value longer than its column.  echanged says a character was typed,
           which is what makes Enter on an untouched cell no edit at all.

           eanchor is the other end of the selection, the pattern TuiFld calls
           anchor and for the same reason: the caret is where the keyboard is and
           the anchor is where the run began, so a selection made backwards has
           the anchor above the caret and neither end can be read off one field.
           The two being equal is "nothing is selected" - there is no third flag
           saying so, and BeginEdit sets both to the end of the text. *)
        editing: BOOLEAN;
        ecol: INTEGER;
        ebuf: ARRAY CELLLEN OF CHAR;
        elen: INTEGER;
        ecaret: INTEGER;
        eanchor: INTEGER;
        efirst: INTEGER;
        echanged: BOOLEAN;

        (* A width being dragged.  rcol is the column whose handle was taken hold
           of and grabDX how far along that handle the pointer took hold - without
           it the boundary would jump under the pointer on the first move.
           resizing is the hold itself, and it lasts until an event arrives that
           is not a click.

           vgrab and grabDY are the same hold for the vertical bar's thumb, and
           hgrab and grabDH the same for the horizontal bar's.  They are separate
           fields and not one, because the drags mean different things - one
           changes a width the table owns, the others move a view - and because
           only one of them is ever live: a pointer that took hold of a handle is
           not also holding the thumb of a bar in another column, and the two bars
           are in different rows.

           grabDH is measured from the left end of the horizontal bar's track and
           grabDX from the boundary of a column, so the two cannot be one field
           even though both count cells along x: the same pointer position means a
           different number in each, and a drag that started on the thumb would
           jump if the other's offset were reused. *)
        resizing: BOOLEAN;
        rcol, grabDX: INTEGER;
        vgrab: BOOLEAN;
        grabDY: INTEGER;
        hgrab: BOOLEAN;
        grabDH: INTEGER;

        cmd*, headCmd*: INTEGER;    (* the ids it fires, fired through Notify *)
        host: TuiWin.Window;

        SetSource*:   PROCEDURE (self: Table; ncols: ColsProc;
                                 coldesc: ColDescProc; nrows: RowsProc;
                                 cell: CellProc);
        Width*:       PROCEDURE (self: Table; i: INTEGER): INTEGER;
        ColAt*:       PROCEDURE (self: Table; x: INTEGER): INTEGER;
        IsMarked*:    PROCEDURE (self: Table; row: INTEGER): BOOLEAN;
        Chosen*:      PROCEDURE (self: Table; row: INTEGER): BOOLEAN;
        Mark*:        PROCEDURE (self: Table; row: INTEGER;
                                 on: BOOLEAN): BOOLEAN;
        ClearMarks*:  PROCEDURE (self: Table);
        SetMulti*:    PROCEDURE (self: Table; on: BOOLEAN);
        Select*:      PROCEDURE (self: Table; row: INTEGER);
        SetEdit*:     PROCEDURE (self: Table; editable: EditProc; setcell: SetProc);
        BeginEdit*:   PROCEDURE (self: Table): BOOLEAN;
        EndEdit*:     PROCEDURE (self: Table; commit: BOOLEAN);
        Editing*:     PROCEDURE (self: Table): BOOLEAN;
        RowChanged*:  PROCEDURE (self: Table; row: INTEGER);
        RowsChanged*: PROCEDURE (self: Table);
        ColsChanged*: PROCEDURE (self: Table);
        FindStr*:     PROCEDURE (self: Table; VAR dst: ARRAY OF CHAR);
        draw*:        PROCEDURE (self: Table; target: TuiCanv.Canvas);
        onEvent*:     PROCEDURE (self: Table; VAR e: Events.Event): BOOLEAN
    END;


(* The owner's row count, clamped to what the table keeps a mark for and to
   nothing below zero.  The data may be longer than MAXROWS - the rows past it
   are drawn and scrolled like any other and simply cannot be marked - but a
   count that is negative or enormous must not reach an index.  Range checking is
   off in this build, so an unclamped count is a silent write past the end. *)
PROCEDURE NData (self: Table): INTEGER;
VAR n: INTEGER;
BEGIN
    n := 0;
    IF self.RowsProc # NIL THEN
        n := self.RowsProc(self)
    END;
    IF n < 0 THEN n := 0 END;
    IF n > MAXROWS THEN n := MAXROWS END;
    RETURN n
END NData;


(* How many data rows fit between the header and the bottom of the widget, less
   the row the horizontal bar takes when there is one.  This is the table's own
   number and not the owner's, and the two are named apart on purpose: a table
   that wired its scrollbar to the owner's count would be a table with one page
   and no bar. *)
PROCEDURE Visible (self: Table; hbar: BOOLEAN): INTEGER;
VAR r: INTEGER;
BEGIN
    r := self.height - HEADROWS;
    IF hbar THEN DEC(r, TRACK) END;
    IF r < 0 THEN r := 0 END;
    RETURN r
END Visible;


(* How many columns the mark cell takes: one while the table may hold more than
   one chosen row, and none at all while it may not.  A table that cannot be
   marked has no column for a mark, which is what a list does too - the two
   widgets draw the same picture of the same state, and the cell a single-row
   table used to leave blank down its left edge is given back to the columns.
   Geometry that is measured from the body's left end asks this and not the
   constant, since the constant is what the column costs when it is there. *)
PROCEDURE MarkCol (self: Table): INTEGER;
VAR m: INTEGER;
BEGIN
    m := 0;
    IF self.multi THEN m := MARKCOL END;
    RETURN m
END MarkCol;


(* Whether each bar is needed, given the other.  The two decide each other - the
   vertical bar takes a column the columns may not have had to spare, and the
   horizontal one takes a row the rows may not have - so one pass is not enough.

   A second pass is, and that is what this is.  The question is whether the
   content fits in a direction *after* the other bar has taken its cell, and the
   answer can only turn a no into a yes: taking away a row cannot make the rows
   fit less well, and taking away a column cannot make the columns fit less well.
   So the first pass guesses from the room available with no bar at all, and the
   fix-ups afterwards can only add the bar the guess was too optimistic to
   predict. *)
PROCEDURE Bars (self: Table; nrows, total: INTEGER;
                VAR vbar, hbar: BOOLEAN);
VAR bw, r1: INTEGER;
BEGIN
    vbar := nrows > Visible(self, FALSE);
    bw := self.width - MarkCol(self);
    IF vbar THEN DEC(bw, TRACK) END;
    IF bw < 0 THEN bw := 0 END;
    hbar := total > bw;
    IF hbar THEN
        r1 := Visible(self, TRUE);
        IF nrows > r1 THEN vbar := TRUE END
    END;
    (* the column the vertical bar takes may be the column the columns needed *)
    bw := self.width - MarkCol(self);
    IF vbar THEN DEC(bw, TRACK) END;
    IF bw < 0 THEN bw := 0 END;
    IF total > bw THEN hbar := TRUE END
END Bars;


(* The width one column is drawn at.  The clamp is applied when the definitions
   are read and on every step of a drag, so this is the width and not a request. *)
PROCEDURE ColWidth (self: Table; i: INTEGER): INTEGER;
VAR w: INTEGER;
BEGIN
    w := MINCOLW;
    IF (i >= 0) & (i < self.ncol) THEN
        w := self.widths[i]
    END;
    RETURN w
END ColWidth;


(* The cell a column starts at, counted from the left end of the body - the mark
   column and the scroll are not in it.  Every column is followed by its handle,
   which is why a column is one cell further along than the widths before it add
   up to. *)
PROCEDURE ColX (self: Table; i: INTEGER): INTEGER;
VAR x, k: INTEGER;
BEGIN
    x := 0;
    k := 0;
    WHILE k < i DO
        INC(x, ColWidth(self, k) + HGAP);
        INC(k)
    END;
    RETURN x
END ColX;


(* The cells the columns take, handles included.  Every column has a handle after
   it - the last one's is the one dragged to size it - but the run stops at the
   last column's own end, so the final handle is not counted. *)
PROCEDURE Total (self: Table): INTEGER;
VAR t, k: INTEGER;
BEGIN
    t := 0;
    k := 0;
    WHILE k < self.ncol DO
        INC(t, ColWidth(self, k) + HGAP);
        INC(k)
    END;
    IF t > 0 THEN DEC(t, HGAP) END;
    RETURN t
END Total;


(* Read the owner's definitions into the cache.  The title is cut to what a slot
   holds and the width is clamped up to MINCOLW - a column too narrow to hold its
   own handle could not be dragged, and one of no width at all would make two
   columns' handles land on the same cell. *)
PROCEDURE Load (self: Table);
VAR
    i, n, w: INTEGER;
    t: ARRAY MAXCOLNAME OF CHAR;
    r: BOOLEAN;
BEGIN
    n := 0;
    IF self.Cols # NIL THEN
        n := self.Cols(self)
    END;
    IF n < 0 THEN n := 0 END;
    IF n > MAXCOLS THEN n := MAXCOLS END;
    self.ncol := n;
    i := 0;
    WHILE i < n DO
        t[0] := 0X;
        w := MINCOLW;
        r := FALSE;
        IF self.ColDesc # NIL THEN
            self.ColDesc(self, i, t, w, r)
        END;
        IF w < MINCOLW THEN w := MINCOLW END;
        Strings.Copy(t, self.titles[i]);
        self.widths[i] := w;
        self.rights[i] := r;
        INC(i)
    END;
    IF self.selCol >= n THEN self.selCol := n - 1 END;
    self.loaded := TRUE
END Load;


PROCEDURE Ensure (self: Table);
BEGIN
    IF ~self.loaded THEN Load(self) END
END Ensure;


(* The four callbacks are handed over in one call rather than one at a time,
   because they are one answer: a column count without a description of a column
   is not half a source, it is a table that would be drawn wrong.  Setting them
   is also what says the definitions have changed, so the cache is dropped here
   and read again on the next frame - and a width being dragged is let go of,
   because the column it was holding is about to be a different width and may not
   be there at all.  A horizontal thumb being held is let go of with it and for
   the same reason: the track it was taken hold of along is made of those same
   columns. *)
PROCEDURE SetSource* (self: Table; ncols: ColsProc; coldesc: ColDescProc;
                      nrows: RowsProc; cell: CellProc);
BEGIN
    self.Cols := ncols;
    self.ColDesc := coldesc;
    self.RowsProc := nrows;
    self.Cell := cell;
    self.loaded := FALSE;
    self.resizing := FALSE;
    self.hgrab := FALSE;
    (* an edit is a cell of the columns that were just replaced, and so is a
       search - the prefix is over the contents of the column EditCol names, and
       that is one of the things being replaced.  Written out and not called:
       FindReset is declared below with the rest of the search *)
    self.editing := FALSE;
    self.nfind := 0;
    self.find[0] := 0X;
    self.findcp := 0
END SetSource;


PROCEDURE Width* (self: Table; i: INTEGER): INTEGER;
VAR w: INTEGER;
BEGIN
    Ensure(self);
    w := ColWidth(self, i);
    RETURN w
END Width;


(* Which column a cell of the body is over, -1 for none.  A cell on a handle is
   -1: a handle belongs to the two columns it separates and to neither of them,
   which is what makes it a place a width is taken hold of rather than a place a
   cell is.  x is counted from the left end of the body, scroll included, so a
   caller with a desktop cell subtracts the widget's own corner and adds left. *)
PROCEDURE ColAt* (self: Table; x: INTEGER): INTEGER;
VAR k, found: INTEGER;
BEGIN
    Ensure(self);
    found := -1;
    k := 0;
    WHILE (k < self.ncol) & (found < 0) DO
        IF (x >= ColX(self, k)) & (x < ColX(self, k) + ColWidth(self, k)) THEN
            found := k
        END;
        INC(k)
    END;
    RETURN found
END ColAt;


(* The handle at x, named by the column it sizes: the handle after column k is k.
   -1 is not a handle - it is the cell before the first column, and there is
   nothing to its left to widen. *)
PROCEDURE HandleAt (self: Table; x: INTEGER): INTEGER;
VAR k, found: INTEGER;
BEGIN
    found := -1;
    k := 0;
    WHILE (k < self.ncol) & (found < 0) DO
        IF x = ColX(self, k) + ColWidth(self, k) THEN
            found := k
        END;
        INC(k)
    END;
    RETURN found
END HandleAt;


PROCEDURE IsMarked* (self: Table; row: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (row >= 0) & (row < MAXROWS) & self.marks[row];
    RETURN r
END IsMarked;


(* Whether the row is inside the range the cursor and the anchor span. *)
PROCEDURE InRange (self: Table; row: INTEGER): BOOLEAN;
VAR lo, hi: INTEGER; r: BOOLEAN;
BEGIN
    lo := self.sel;
    hi := self.anchor;
    IF lo > hi THEN
        lo := self.anchor;
        hi := self.sel
    END;
    r := (row >= lo) & (row <= hi);
    RETURN r
END InRange;


(* Whether the row is one of the chosen ones: inside the range the cursor and
   the anchor span, or ticked in the mark set.  This is the selection, and it is
   also the whole of what is drawn as one - the star in the mark column is
   written for exactly this answer and for nothing else, so that what an owner
   reads here and what a user sees on the screen are the same rows.  The range of
   a table with no rows is empty, so a table with nothing in it chooses nothing. *)
PROCEDURE Chosen* (self: Table; row: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (NData(self) > 0) & InRange(self, row);
    IF ~r THEN r := IsMarked(self, row) END;
    RETURN r
END Chosen;


PROCEDURE Recount (self: Table);
VAR i, n: INTEGER;
BEGIN
    n := 0;
    FOR i := 0 TO MAXROWS - 1 DO
        IF self.marks[i] THEN INC(n) END
    END;
    self.nmarks := n
END Recount;


(* Mark a row or unmark it, and say whether anything changed.  A table that is
   not multi refuses, and so does a row the table has no mark for. *)
PROCEDURE Mark* (self: Table; row: INTEGER; on: BOOLEAN): BOOLEAN;
VAR changed: BOOLEAN;
BEGIN
    changed := FALSE;
    IF self.multi & (row >= 0) & (row < MAXROWS) & (row < NData(self)) &
       (self.marks[row] # on) THEN
        self.marks[row] := on;
        IF on THEN
            INC(self.nmarks)
        ELSE
            DEC(self.nmarks)
        END;
        changed := TRUE
    END;
    RETURN changed
END Mark;


PROCEDURE ClearMarks* (self: Table);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO MAXROWS - 1 DO
        self.marks[i] := FALSE
    END;
    self.nmarks := 0
END ClearMarks;


(* The setting.  Turning it off gives up the marks there are, because a mark the
   owner is no longer being told about is a mark nothing can act on, and one left
   set would make a table turned back on come back wearing marks nobody made. *)
PROCEDURE SetMulti* (self: Table; on: BOOLEAN);
BEGIN
    self.multi := on;
    IF ~on THEN
        ClearMarks(self);
        (* the range goes with the marks.  Turning the setting off means one
           row, and an anchor left where a Shift put it would go on drawing the
           selection over several - a selection the widget has just been told it
           may not hold, and one Chosen would go on answering for. *)
        self.anchor := self.sel
    END
END SetMulti;


(* Move the cursor to a row and keep it on show.  keep says whether the anchor
   moves with it: a plain move collapses the range onto the cursor, and the
   anchor is what a Shift move grows it from. *)
PROCEDURE SetSel (self: Table; row: INTEGER; keep: BOOLEAN);
VAR n, r, rows: INTEGER; vbar, hbar: BOOLEAN;
BEGIN
    n := NData(self);
    r := row;
    IF r > n - 1 THEN r := n - 1 END;
    IF r < 0 THEN r := 0 END;
    self.sel := r;
    (* keep is what holds the other end of a range where it was, and a range is
       a selection of several rows - so a table that has not been told it may
       hold several does not grow one.  The setting off means one row, here and
       not only in what is drawn: without the second test a Shift+arrow would
       spread the selection over the whole stretch and Chosen would answer for
       every row of it.  Tested here rather than where the arrows are read, so
       that every caller is held to it and not only the keyboard. *)
    IF ~(keep & self.multi) THEN self.anchor := r END;
    Bars(self, n, Total(self), vbar, hbar);
    rows := Visible(self, hbar);
    IF self.sel < self.top THEN
        self.top := self.sel
    END;
    IF self.sel >= self.top + rows THEN
        self.top := self.sel - rows + 1
    END;
    IF self.top > n - rows THEN self.top := n - rows END;
    IF self.top < 0 THEN self.top := 0 END
END SetSel;


PROCEDURE Select* (self: Table; row: INTEGER);
BEGIN
    SetSel(self, row, FALSE)
END Select;


(* One row's contents have changed.  Nothing about the view moves: the row is
   still the row it was, the table holds no copy of the text to update, and the
   next frame draws whatever the owner now answers.  What this is for is an owner
   that wants the row it changed brought into sight. *)
PROCEDURE RowChanged* (self: Table; row: INTEGER);
BEGIN
    IF (row >= 0) & (row = self.sel) THEN
        SetSel(self, self.sel, TRUE)
    END
END RowChanged;


(* The rows are not what they were: the count moved, or the data was rebuilt.
   Everything the table held about a row is put back in range - the cursor, the
   anchor, and the marks on rows that are no longer there - and the view is
   scrolled to the cursor. *)
PROCEDURE RowsChanged* (self: Table);
VAR n, i: INTEGER;
BEGIN
    n := NData(self);
    i := n;
    WHILE i < MAXROWS DO
        self.marks[i] := FALSE;
        INC(i)
    END;
    Recount(self);
    (* the row being edited may be one of the ones that are gone *)
    self.editing := FALSE;
    self.sel := 0;
    self.anchor := 0;
    self.top := 0;
    SetSel(self, 0, TRUE);
    IF self.left > Total(self) THEN self.left := 0 END;
    IF self.left < 0 THEN self.left := 0 END
END RowsChanged;


(* The column definitions are not what they were.  The cache is dropped and read
   again at once, so a caller may ask Width straight afterwards and be answered
   with the new one; a width being dragged is let go of, because the column it
   was holding is about to be a different width and may not be there at all.

   A horizontal thumb being held is let go of for the same reason: the track it
   was taken hold of along is about to be a different length, so how far along it
   the pointer took hold no longer means what it did.  A width and a track are
   the two things a pointer can be holding here and both are made of the columns
   this call says have changed. *)
PROCEDURE ColsChanged* (self: Table);
BEGIN
    self.resizing := FALSE;
    self.hgrab := FALSE;
    self.loaded := FALSE;
    (* and an edit is a cell of the columns that are about to be read again *)
    self.editing := FALSE;
    (* and so is a search: it is a prefix over the contents of one column, and
       which column that is - EditCol - is one of the things being read again.
       A prefix left standing would go on being extended against a column nobody
       chose.  FindReset is written out here rather than called because it is
       declared below with the rest of the search, and a table's columns are
       re-read from this end of the module - Clear does the same for a list. *)
    self.nfind := 0;
    self.find[0] := 0X;
    self.findcp := 0;
    Load(self)
END ColsChanged;


(* One cell's text.  A cell the owner answers nothing for is an empty string,
   which is what a table with a hole in it shows. *)
PROCEDURE GetCell (self: Table; row, col: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN
    dst[0] := 0X;
    IF self.Cell # NIL THEN
        self.Cell(self, row, col, dst)
    END
END GetCell;


(* n characters of src from position from, into dst, terminated. *)
PROCEDURE CutFrom (src: ARRAY OF CHAR; from, n: INTEGER; VAR dst: ARRAY OF CHAR);
VAR i, m: INTEGER;
BEGIN
    m := n;
    IF m > LEN(dst) - 1 THEN m := LEN(dst) - 1 END;
    i := 0;
    WHILE (i < m) & (from + i < LEN(src)) & (src[from + i] # 0X) DO
        dst[i] := src[from + i];
        INC(i)
    END;
    dst[i] := 0X
END CutFrom;


(* ---------------------------------------------------------------------------
   The cell editor.  A grid is a grid because a cell can be written in place,
   and everything below is that one ability: the cursor's cell becomes a small
   one-line editor, the keys go to it while it is up, and its text leaves through
   the owner's SetCell when the edit commits - the table itself still holds no
   data and writes none.
   --------------------------------------------------------------------------- *)


(* The width of the body: the widget's cells less the mark column and the column
   the vertical bar takes when it is drawn.  This is draw's own arithmetic, and
   it is asked here rather than written a second time because the two bars decide
   each other - a body wide enough loses the vertical bar and gains a cell back -
   and two copies of that rule would drift apart. *)
PROCEDURE BodyW (self: Table): INTEGER;
VAR n, tot, bw: INTEGER; vbar, hbar: BOOLEAN;
BEGIN
    n := NData(self);
    tot := Total(self);
    Bars(self, n, tot, vbar, hbar);
    bw := self.width - MarkCol(self);
    IF vbar THEN DEC(bw, TRACK) END;
    IF bw < 0 THEN bw := 0 END;
    RETURN bw
END BodyW;


(* The byte after the character that begins at i, and the byte at which the
   character before i begins.  These two are the whole of what makes a
   multi-byte page safe: every walk over the cell's text steps through them, so a
   caret is always on the first byte of a character and a deletion always takes a
   whole one.  On a page that is one byte to the character both are the identity
   - NextByte adds one, PrevByte takes one off - which is what every caller did
   before, so 437 and 866 tables behave exactly as they did.

   NextByte asks the page's own Decode how long the character is rather than
   counting continuation bytes itself: Decode is the one place that knows the
   encoding and refuses a malformed sequence as one U+FFFD of length one, so a
   text with a bad byte in it still walks - the alternative is a walker that
   stops dead or one that runs past the end.

   PrevByte cannot ask that question backwards, so it walks back over
   continuation bytes (10xxxxxx) to the lead byte that starts the character.  A
   malformed tail stops at the byte it started from rather than at zero, which is
   the honest answer: it is not known to be part of anything.

   This is TuiFld's pair of the same names, and the reason they are copied rather
   than called is that the field's work on its own store and these on the cell's
   buffer - the same division InsertChar is a copy for. *)
PROCEDURE ENextByte (s: ARRAY OF CHAR; i, len: INTEGER): INTEGER;
VAR cp, n: INTEGER;
BEGIN
    IF i < len THEN
        IF TuiPage.Text() = Charset.PageUtf8 THEN
            Charset.Decode(s, i, Charset.PageUtf8, cp, n)
        ELSE
            n := 1
        END;
        IF n < 1 THEN n := 1 END;
        INC(i, n);
        IF i > len THEN i := len END
    END;
    RETURN i
END ENextByte;


PROCEDURE EPrevByte (s: ARRAY OF CHAR; i: INTEGER): INTEGER;
BEGIN
    IF i > 0 THEN
        DEC(i);
        IF TuiPage.Text() = Charset.PageUtf8 THEN
            (* 80H..0BFH is what a continuation byte is, asked as two comparisons
               because this dialect has no bitwise AND on a character's ordinal:
               Charset's own decoding loop asks it the same way. *)
            WHILE (i > 0) & (ORD(s[i]) >= 80H) & (ORD(s[i]) < 0C0H) DO DEC(i) END
        END
    END;
    RETURN i
END EPrevByte;


(* The character that begins at byte i, as a canvas cell holds it: a code point.

   The two pages answer this in two different ways and the difference is not
   cosmetic.  Decode on UTF-8 gives the code point itself, and a cell holds a
   code point, so that is the whole of it.  On a byte page the byte is the page's
   own and CharOf is what turns it into the character that page draws.

   CharOf IS NOT THE UTF-8 ANSWER: it takes a BYTE and looks it up in the text
   page, so handing it a code point above 0FFH looks up an entry the table has
   not got.  This is TuiFld.CharAt, and the drawing loop below is the caller that
   used to make exactly that mistake. *)
PROCEDURE ECharAt (s: ARRAY OF CHAR; i: INTEGER): TuiCanv.Char;
VAR cp, n: INTEGER; ch: TuiCanv.Char;
BEGIN
    IF TuiPage.Text() = Charset.PageUtf8 THEN
        Charset.Decode(s, i, Charset.PageUtf8, cp, n);
        ch := WCHR(cp)
    ELSE
        ch := TuiCanv.CharOf(ORD(s[i]))
    END;
    RETURN ch
END ECharAt;


(* Which cell the byte b is drawn in: how many characters begin before it.  This
   is the byte-to-column half of the conversion, and it is asked by the one thing
   that compares a caret against cells - the scroll. *)
PROCEDURE ECellOf (s: ARRAY OF CHAR; b, len: INTEGER): INTEGER;
VAR i, n: INTEGER;
BEGIN
    IF b > len THEN b := len END;       (* a walk that is handed a byte past the
                                           end would otherwise never finish *)
    i := 0; n := 0;
    WHILE i < b DO
        i := ENextByte(s, i, len);
        INC(n)
    END;
    RETURN n
END ECellOf;


(* The column an edit is in.  The table has no cursor among the columns - the two
   arrows scroll the view by cells, and selCol is the column a click on the
   header chose - so the column edited is the chosen one, and the first column
   when no click has chosen any.  That is the honest reading of a table with no
   column cursor, and it is why clicking a header before pressing Enter is worth
   doing. *)
PROCEDURE EditCol (self: Table): INTEGER;
VAR k: INTEGER;
BEGIN
    k := 0;
    IF (self.selCol >= 0) & (self.selCol < self.ncol) THEN k := self.selCol END;
    RETURN k
END EditCol;


(* The low end of the selection, and the high end.  The caret is where the
   keyboard is and the anchor is where the run began, so a selection made
   backwards has the anchor above the caret and neither end can be read off one
   field.  The two being equal means nothing is selected, which is why there is
   no third flag saying so. *)
PROCEDURE ESelFrom (self: Table): INTEGER;
VAR i: INTEGER;
BEGIN
    i := self.ecaret;
    IF self.eanchor < i THEN i := self.eanchor END;
    RETURN i
END ESelFrom;


PROCEDURE ESelTo (self: Table): INTEGER;
VAR i: INTEGER;
BEGIN
    i := self.ecaret;
    IF self.eanchor > i THEN i := self.eanchor END;
    RETURN i
END ESelTo;


PROCEDURE ESelected (self: Table): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := self.ecaret # self.eanchor;
    RETURN r
END ESelected;


(* Move the caret inside the text.  With keep the anchor stays where it is and
   the selection grows or shrinks; without it there is no selection afterwards
   and the anchor follows the caret.

   The cell's own view of the text is not touched here.  It is settled in
   EditDraw, which is the one place that knows how wide the column on show is -
   the same division the field makes, where the caret never has to know its own
   width because EnsureFirst is called from the one place that does. *)
PROCEDURE ESetCaret (self: Table; i: INTEGER; keep: BOOLEAN);
BEGIN
    IF i < 0 THEN i := 0 END;
    IF i > self.elen THEN i := self.elen END;
    self.ecaret := i;
    IF ~keep THEN self.eanchor := i END
END ESetCaret;


(* n characters at pos, gone, the ones after them moved up, and the caret left
   at pos with nothing selected.  This is what every deletion comes to: one
   character from Backspace, one from Delete, or the whole run that a character,
   a paste or a cut is about to replace.

   n is cut to what is there rather than trusted, so a caller that worked the
   count out from a selection that has since shrunk cannot walk off the end. *)
PROCEDURE EDelRun (self: Table; pos, n: INTEGER);
VAR i: INTEGER;
BEGIN
    IF (pos >= 0) & (n > 0) & (pos < self.elen) THEN
        IF n > self.elen - pos THEN n := self.elen - pos END;
        i := pos;
        WHILE i < self.elen - n DO
            self.ebuf[i] := self.ebuf[i + n];
            INC(i)
        END;
        DEC(self.elen, n);
        self.ebuf[self.elen] := 0X;
        self.echanged := TRUE;
        ESetCaret(self, pos, FALSE)
    END
END EDelRun;


(* src into the buffer at the caret, over the selection when there is one, and
   the caret past what went in.  Answers how many characters were taken: all of
   them when there is room and what fits when there is not, because CELLLEN - 1
   characters is the whole of what a cell can hold and a paste longer than that
   is cut rather than refused.

   The tail moves first and from the right, so the copy never walks over what it
   has not moved yet.  Written out rather than left to Strings.Insert because
   the caller needs the count - the caret goes just past what was inserted. *)
PROCEDURE EInsRun (self: Table; src: ARRAY OF CHAR): INTEGER;
VAR n, room, i: INTEGER;
BEGIN
    IF ESelected(self) THEN
        EDelRun(self, ESelFrom(self), ESelTo(self) - ESelFrom(self))
    END;
    n := Strings.Length(src);
    room := CELLLEN - 1 - self.elen;
    IF n > room THEN n := room END;
    IF n < 0 THEN n := 0 END;
    IF n > 0 THEN
        i := self.elen;
        WHILE i > self.ecaret DO
            DEC(i);
            self.ebuf[i + n] := self.ebuf[i]
        END;
        FOR i := 0 TO n - 1 DO
            self.ebuf[self.ecaret + i] := src[i]
        END;
        INC(self.elen, n);
        self.ebuf[self.elen] := 0X;
        self.echanged := TRUE;
        ESetCaret(self, self.ecaret + n, FALSE)
    END;
    RETURN n
END EInsRun;


(* A character into the buffer at the caret, over the selection when there is
   one, as a CODE POINT - the number the keyboard made and not a byte of it.  The
   page turns it into the bytes it is, and the one place that knows how is
   TuiPage.BytesOf - see it for why the conversion is not Charset.Encode, which
   agrees on the wide page and is the wrong question on a byte one.  CHR(cp)
   here would write the low byte and put a different letter in the cell than the
   one that was typed - and then commit it.  This is TuiFld.InsertCp, and the
   reason it is a copy of it rather than a call into it is that the two hold
   their text differently, a string there and this buffer here.

   A character the page cannot spell is not written at all.  Refusing it is the
   point: the alternative is CHR(cp), which writes the low byte.

   What is written is the whole character or nothing of it, so the write is
   measured before it happens - the room is checked against the encoded length
   rather than letting EInsRun cut, which would leave half a sequence at the end
   of a full cell and turn the character into a replacement mark.  The selection
   goes first so that replacing a run is not refused for the length of the run
   being replaced.

   One cell of CELLLEN is held back for the terminating 0X, so a cell is at most
   CELLLEN - 1 bytes and the text is always a string. *)
PROCEDURE EInsCp (self: Table; cp: INTEGER);
VAR one: ARRAY 8 OF CHAR; n, k: INTEGER;
BEGIN
    k := 0;
    one[0] := 0X;
    n := TuiPage.BytesOf(cp, one, k);
    IF n > 0 THEN
        IF ESelected(self) THEN
            EDelRun(self, ESelFrom(self), ESelTo(self) - ESelFrom(self))
        END;
        IF n <= CELLLEN - 1 - self.elen THEN
            one[n] := 0X;
            k := EInsRun(self, one)
        END
    END
END EInsCp;


(* The selection to the clipboard.  Nothing selected copies nothing - the
   clipboard is not emptied by a Ctrl+C that carries no run, which is what a word
   processor does too.  The caret and the selection are left alone, so the run
   stays where it is and can be pasted over itself.

   The copy is terminated by hand: CopyRange moves the characters and writes no
   terminator of its own, so without the one written here the clipboard would
   read on into whatever the buffer held before - and a shorter run copied after
   a longer one is exactly when that shows. *)
PROCEDURE ECopy (self: Table);
VAR s: ARRAY CELLLEN OF CHAR; n: INTEGER;
BEGIN
    IF ESelected(self) THEN
        n := ESelTo(self) - ESelFrom(self);
        Strings.CopyRange(self.ebuf, s, ESelFrom(self), 0, n);
        s[n] := 0X;
        (* Which half of Clipboard is used is the text page's business, and it
           is the same rule TuiFld and TuiText follow.  A UTF-8 text page holds
           UTF-8 already, so the run goes out through Put; a byte page holds the
           screen's own bytes, and PutScreen is the pair that says what page
           they are in and turns them into UTF-8 on the way out.  The two are
           not interchangeable: PutScreen reads the run as 866, so a Russian
           value copied out of a UTF-8 cell by it reaches the clipboard as the
           letters of its bytes. *)
        IF TuiPage.Text() = Charset.PageUtf8 THEN
            Clipboard.Put(s)
        ELSE
            Clipboard.PutScreen(s)
        END
    END
END ECopy;


(* The clipboard's text into the cell at the caret, over the selection when there
   is one.  An empty clipboard changes nothing.

   Only the first line of what is on the clipboard goes in.  A cell is one line
   and cannot hold a block, so a break is where this stops reading - and the cut
   belongs here rather than in the platform layer, because a text area wants the
   whole block from the same call.  Both breaks are cut at, CR LF and a lone LF,
   since the DOS clipboard writes the pair and TuiText writes the single byte.
   The loop is bounded by the buffer as well, so a clipboard that answered
   without a terminator cannot run away. *)
PROCEDURE EPaste (self: Table);
VAR s: ARRAY Clipboard.MAXCLIP OF CHAR; n, i: INTEGER;
BEGIN
    (* The page's own pair, as in ECopy: a UTF-8 cell wants the UTF-8 that is on
       the clipboard and not the screen's reading of it, which turns every
       Russian letter into a question mark. *)
    IF TuiPage.Text() = Charset.PageUtf8 THEN
        Clipboard.Get(s)
    ELSE
        Clipboard.GetScreen(s)
    END;
    i := 0;
    WHILE (i < LEN(s) - 1) & (s[i] # 0X) & (s[i] # 0DX) & (s[i] # 0AX) DO
        INC(i)
    END;
    s[i] := 0X;
    IF Strings.Length(s) > 0 THEN
        n := EInsRun(self, s)
    END
END EPaste;


(* Slide the cell's view so that the caret is inside w cells of it - the pattern
   TuiFld calls EnsureFirst, and what makes a value longer than its column
   editable at all. *)
PROCEDURE EShow (self: Table; w: INTEGER);
VAR fc, cc: INTEGER;
BEGIN
    IF w < 1 THEN w := 1 END;
    (* The width is cells and the caret is a byte, so both are counted in cells
       here and the view is walked forward by the difference - moving first by
       that many BYTES is what would land it inside a character.  The answer is
       the same on a one-byte page, where the difference is the count. *)
    fc := ECellOf(self.ebuf, self.efirst, self.elen);
    cc := ECellOf(self.ebuf, self.ecaret, self.elen);
    IF cc < fc THEN
        self.efirst := self.ecaret
    ELSIF cc > fc + w - 1 THEN
        WHILE fc < cc - w + 1 DO
            self.efirst := ENextByte(self.ebuf, self.efirst, self.elen);
            INC(fc)
        END
    END;
    IF self.efirst > self.elen THEN self.efirst := self.elen END;
    IF self.efirst < 0 THEN self.efirst := 0 END
END EShow;


(* Where the edited cell is on the canvas: x0..x1 across, clipped to the body,
   and y the row it lies on.  FALSE when no part of it is on show - which the
   cursor's row cannot be, because SetSel keeps it in view, but a table whose
   owner called RowsChanged with the editor up is in exactly that state for the
   frame after it, and a cell that is not there must not be drawn or hit. *)
PROCEDURE EditRect (self: Table; VAR x0, x1, y: INTEGER): BOOLEAN;
VAR bx0, bx1, cx, w: INTEGER; ok: BOOLEAN;
BEGIN
    ok := FALSE;
    bx0 := self.x + MarkCol(self);
    bx1 := bx0 + BodyW(self) - 1;
    cx := bx0 + ColX(self, self.ecol) - self.left;
    w := ColWidth(self, self.ecol);
    x0 := cx;
    x1 := cx + w - 1;
    IF x0 < bx0 THEN x0 := bx0 END;
    IF x1 > bx1 THEN x1 := bx1 END;
    y := self.y + HEADROWS + (self.sel - self.top);
    IF (x0 <= x1) & (y >= self.y + HEADROWS) & (y < self.y + self.height) THEN
        ok := TRUE
    END;
    RETURN ok
END EditRect;


(* Is (x, y) inside the edited cell?  A press there is the editor's and is taken;
   a press anywhere else ends the edit and is then the table's, in the ordinary
   way - which is why clicking another row saves the text and moves the cursor in
   one gesture, the way a grid does. *)
PROCEDURE EditHit (self: Table; x, y: INTEGER): BOOLEAN;
VAR x0, x1, yy: INTEGER; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF EditRect(self, x0, x1, yy) THEN
        r := (y = yy) & (x >= x0) & (x <= x1)
    END;
    RETURN r
END EditHit;


(* The editor on the canvas: the cell filled in the editor's pair so that the
   value underneath it is gone, the text from efirst on, and the caret as the one
   cell it stands on with that pair's two colours swapped - the same inversion
   the mouse pointer is drawn with, and the reason the editor needs no second
   theme slot for it.

   A selected run is drawn by that same inversion and needs no third slot
   either: the selected cells are put in the swapped pair and the rest in the
   normal one, so a run reads as a band of reversed cells with the caret at one
   end of it - which is what a run looks like wherever this toolkit draws one.
   The caret is drawn after the text and so wins where the two meet, which is
   the one cell they can share.

   The text is laid out from the cell's left end whatever the column's alignment
   is.  A right-set column is set right again the moment the edit commits; a
   caret in a right-set strip would have to be placed from the right end and
   would move under the user's hands on every keystroke.  One rule while the
   editor is up, and the owner's alignment the rest of the time. *)
PROCEDURE EditDraw (self: Table; target: TuiCanv.Canvas);
VAR x0, x1, y, i, col, cw, a, ac, lo, hi, cc: INTEGER; ch: TuiCanv.Char;
BEGIN
    IF self.editing & EditRect(self, x0, x1, y) THEN
        cw := x1 - x0 + 1;
        EShow(self, cw);
        a := TuiTheme.Attr(TuiTheme.TableEdit);
        ac := (a MOD 16) * 16 + (a DIV 16);
        target.Fill(target, x0, y, cw, 1, " ", a);
        lo := ESelFrom(self);
        hi := ESelTo(self);
        (* The text is bytes and the cell is cells, so the two indices come apart
           here: i is the byte the next character begins at and col is the cell
           it goes in.  The step is a character, through ENextByte, so a Russian
           value - two bytes to the letter - draws one cell to the letter and not
           the two letters its bytes spell in the page.

           Everything that compares a caret against a position still compares
           bytes (lo, hi and self.ecaret), because that is what a caret is; only
           the cell it is drawn at is a cell.

           The two halves of that are why the loop below never asks whether i is
           the caret and asks whether COL is.  Past the last character i stops
           advancing - there is no next character to step to - so every cell from
           there to the right edge carries the same i, and a byte test would call
           every one of them the caret and draw the whole tail in the selection
           pair.  On an empty cell that is the entire strip. *)
        cc := ECellOf(self.ebuf, self.ecaret, self.elen) -
              ECellOf(self.ebuf, self.efirst, self.elen);
        IF (cc < 0) OR (cc >= cw) THEN cc := -1 END;
        i := self.efirst;
        FOR col := 0 TO cw - 1 DO
            IF i < self.elen THEN
                ch := ECharAt(self.ebuf, i)
            ELSE
                ch := " "
            END;
            IF (i >= lo) & (i < hi) THEN
                target.Put(target, x0 + col, y, ch, ac)
            ELSE
                target.Put(target, x0 + col, y, ch, a)
            END;
            IF i < self.elen THEN
                i := ENextByte(self.ebuf, i, self.elen)
            END
        END;
        (* The caret is drawn after the text and so wins where the two meet,
           which is the one cell they can share. *)
        IF cc >= 0 THEN
            ch := " ";
            IF self.ecaret < self.elen THEN
                ch := ECharAt(self.ebuf, self.ecaret)
            END;
            target.Put(target, x0 + cc, y, ch, ac)
        END
    END
END EditDraw;


(* Whether a cell may be written, and where the new text goes.  Setting either to
   NIL takes the editor away and drops an edit that is up: the permission is the
   caller's and it has just said the answer is no. *)
PROCEDURE SetEdit* (self: Table; editable: EditProc; setcell: SetProc);
BEGIN
    self.Editable := editable;
    self.SetCell := setcell;
    self.editing := FALSE
END SetEdit;


(* Start editing the cursor's cell.  Answers FALSE and changes nothing when there
   is nothing to edit - no permission, no columns, no such row, or the owner's
   Editable said no - and the caller then leaves the event alone.  That is what
   keeps every read-only table behaving exactly as it did before there was an
   editor, and it is why the Enter arm in onEvent tests the answer rather than
   setting handled and hoping.

   Beginning an edit scrolls the columns if the whole cell is not in sight, and
   fires nothing: a view that moved is not a choice that was made.  The id comes
   when the text commits. *)
PROCEDURE BeginEdit* (self: Table): BOOLEAN;
VAR ok: BOOLEAN; bw, k, x, w: INTEGER;
BEGIN
    ok := FALSE;
    Ensure(self);
    IF ~self.editing & (self.Editable # NIL) & (self.SetCell # NIL) &
       (self.ncol > 0) & (self.sel >= 0) & (self.sel < NData(self)) THEN
        k := EditCol(self);
        IF self.Editable(self, self.sel, k) THEN
            self.ecol := k;
            GetCell(self, self.sel, k, self.ebuf);
            self.elen := Strings.Length(self.ebuf);
            self.ecaret := self.elen;
            self.eanchor := self.elen;  (* nothing is selected to begin with *)
            self.efirst := 0;
            self.echanged := FALSE;
            bw := BodyW(self);
            x := ColX(self, k);
            w := ColWidth(self, k);
            IF x < self.left THEN
                self.left := x
            ELSIF x + w > self.left + bw THEN
                self.left := x + w - bw
            END;
            IF self.left < 0 THEN self.left := 0 END;
            self.editing := TRUE;
            ok := TRUE
        END
    END;
    RETURN ok
END BeginEdit;


(* The end of an edit.  commit says where the text goes: Enter keeps it, and so
   does every key that means "somewhere else" - see EditKey; Esc throws it away.

   Committing writes through the owner's SetCell and fires the table's own id, so
   an owner handles a new value exactly as it handles a new selection, with no
   second road to learn.  Nothing is written and nothing is fired when no
   character was typed: pressing Enter on a cell and changing nothing is not a
   change, and an owner that marks its row dirty on the id would otherwise be
   told about every cursor that passed through. *)
PROCEDURE EndEdit* (self: Table; commit: BOOLEAN);
BEGIN
    IF self.editing THEN
        self.editing := FALSE;
        IF commit & self.echanged & (self.SetCell # NIL) THEN
            self.SetCell(self, self.sel, self.ecol, self.ebuf);
            TuiWin.Notify(self.host, self, self.cmd)
        END
    END
END EndEdit;


(* Is the cell editor up?  A dialog that means to ask before a value changes, or
   to hold something off while one is being typed, asks here. *)
PROCEDURE Editing* (self: Table): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := self.editing;
    RETURN r
END Editing;


(* A key while the editor is up.  TRUE when the editor took it; FALSE when the
   key is not the editor's - and in that second case the edit has *already* been
   committed, so the key falls through to the table's own arm and the cursor or
   the view moves where it always moved.

   That is why an arrow out of a cell, a Tab and a Page Down all keep the text
   without a word about it: an edit is the cell's value, and a user who presses a
   key that means "somewhere else" has not said to give it up.  Esc is the one
   key that does say so.

   Space is a character here and not the mark toggle, and the two horizontal
   arrows move the caret and not the view: while an editor is up its keys are the
   editor's.

   The four control chords are the editor's too, the same four and the same
   meaning as in a field and in a text area: Ctrl+A takes the whole cell, Ctrl+C
   puts the run on the clipboard, Ctrl+X takes it there and leaves the cell
   shorter, Ctrl+V pours the clipboard in at the caret.  Everything else with
   Ctrl or Alt held is *not* the editor's and commits on its way past, which is
   what keeps a window's own accelerators - Ctrl+S to save, Alt+F for a menu -
   working while a cell is being written in.

   A run is drawn by an arrow with Shift held, exactly as in a field: the anchor
   stays where it was and the caret moves, and an arrow without Shift leaves no
   run behind.  Home and End obey Shift the same way. *)
PROCEDURE EditKey (self: Table; VAR e: Events.Event): BOOLEAN;
VAR handled: BOOLEAN; p, i: INTEGER;
BEGIN
    handled := TRUE;
    IF Events.IsKey(e, Events.K_ENTER) THEN
        EndEdit(self, TRUE)
    ELSIF Events.IsKey(e, Events.K_ESC) THEN
        EndEdit(self, FALSE)
    ELSIF Events.IsKey(e, Events.K_BACK) THEN
        (* One CHARACTER out of the cell and not one byte of it: half a Russian
           letter left behind is not a value anybody typed, and the two bytes
           would then draw as two cells of the page's own spelling. *)
        IF ESelected(self) THEN
            EDelRun(self, ESelFrom(self), ESelTo(self) - ESelFrom(self))
        ELSIF self.ecaret > 0 THEN
            i := EPrevByte(self.ebuf, self.ecaret);
            EDelRun(self, i, self.ecaret - i)
        END
    ELSIF Events.IsKey(e, Events.K_DEL) THEN
        IF ESelected(self) THEN
            EDelRun(self, ESelFrom(self), ESelTo(self) - ESelFrom(self))
        ELSE
            EDelRun(self, self.ecaret,
                    ENextByte(self.ebuf, self.ecaret, self.elen) - self.ecaret)
        END
    ELSIF Events.IsKey(e, Events.K_LEFT) THEN
        ESetCaret(self, EPrevByte(self.ebuf, self.ecaret), e.shift)
    ELSIF Events.IsKey(e, Events.K_RIGHT) THEN
        ESetCaret(self, ENextByte(self.ebuf, self.ecaret, self.elen), e.shift)
    ELSIF Events.IsKey(e, Events.K_HOME) THEN
        ESetCaret(self, 0, e.shift)
    ELSIF Events.IsKey(e, Events.K_END) THEN
        ESetCaret(self, self.elen, e.shift)
    ELSIF Events.IsCtrl(e, Events.CTRL_A) THEN
        self.eanchor := 0;
        ESetCaret(self, self.elen, TRUE)
    ELSIF Events.IsCtrl(e, Events.CTRL_C) THEN
        ECopy(self)
    ELSIF Events.IsCtrl(e, Events.CTRL_X) THEN
        ECopy(self);
        IF ESelected(self) THEN
            EDelRun(self, ESelFrom(self), ESelTo(self) - ESelFrom(self))
        END
    ELSIF Events.IsCtrl(e, Events.CTRL_V) THEN
        EPaste(self)
    ELSE
        (* What the key made, asked once and in the page's own terms - see
           Events.Char, the one place that knows which half of the event holds
           it.  On a console the character arrives whole in e.ch and e.key is
           only its low byte, so a test of e.key refuses the letters whose low
           byte is under 20H (A to P of the Russian block) and admits the rest as
           whatever their low byte spells - я would go in as an O.  A byte page
           is unaffected: there the byte IS the character, and Events.Char hands
           back that byte. *)
        p := Events.Char(e);
        IF ~e.ctrl & ~e.alt & (p > 0) THEN
            EInsCp(self, p)
        ELSE
            EndEdit(self, TRUE);
            handled := FALSE
        END
    END;
    RETURN handled
END EditKey;


(* One strip of a row: w cells at cx, clipped to the range x0..x1 and cut to what
   is left of it.

   The cut is made here and not left to the canvas.  A canvas clips at its own
   edge, which is the whole window, so a column that reached past the table would
   be drawn over the scrollbar or over whatever stands beside it.  The two places
   a strip can be short are its two ends - a column scrolled half off the left of
   the body, and one that runs past the right - and both are the same arithmetic:
   fill what is visible, then print the part of the text that falls inside it.
   Right-aligned text is placed from the strip's right end before the cut, so a
   strip whose left end is hidden loses nothing off the words. *)
PROCEDURE PutCell (target: TuiCanv.Canvas; x0, x1, y, cx, w: INTEGER;
                   s: ARRAY OF CHAR; right: BOOLEAN; attr: INTEGER);
VAR vx, ve, len, tx, p, q: INTEGER; part: ARRAY CELLLEN OF CHAR;
BEGIN
    vx := cx;
    IF vx < x0 THEN vx := x0 END;
    ve := cx + w - 1;
    IF ve > x1 THEN ve := x1 END;
    IF (w > 0) & (vx <= ve) THEN
        target.Fill(target, vx, y, ve - vx + 1, 1, " ", attr);
        len := Strings.Length(s);
        IF len > w THEN len := w END;
        IF right THEN
            tx := cx + w - len
        ELSE
            tx := cx
        END;
        p := tx;
        IF p < vx THEN p := vx END;
        q := tx + len - 1;
        IF q > ve THEN q := ve END;
        IF (len > 0) & (p <= q) THEN
            CutFrom(s, p - tx, q - p + 1, part);
            target.Print(target, p, y, part, attr)
        END
    END
END PutCell;


(* One character in a field of its own width: PutCell for the case PutCell
   cannot take, which is a character of the canvas rather than a byte string.

   The column handles are what needs it.  A handle is a box-drawing character,
   and a box-drawing character is a code point now - the divider is 2502H - so
   there is no byte to put in a one-character string any more.  It used to be
   built as ch[0] := TuiCanv.SL_V; ch[1] := 0X and handed to PutCell, which was
   right while a canvas cell was a byte and is not right now.

   The clipping is PutCell's, unchanged and for the same reason: a column may be
   scrolled half out of the strip, so the field is cut to the part of it the
   strip has room for and the character is drawn only if it is inside that part.
   The text is always at the field's left end, so there is no alignment here. *)
PROCEDURE PutChar (target: TuiCanv.Canvas; x0, x1, y, cx, w: INTEGER;
                   ch: TuiCanv.Char; attr: INTEGER);
VAR vx, ve: INTEGER;
BEGIN
    vx := cx;
    IF vx < x0 THEN vx := x0 END;
    ve := cx + w - 1;
    IF ve > x1 THEN ve := x1 END;
    IF (w > 0) & (vx <= ve) THEN
        target.Fill(target, vx, y, ve - vx + 1, 1, " ", attr);
        IF (cx >= vx) & (cx <= ve) THEN
            target.Put(target, cx, y, ch, attr)
        END
    END
END PutChar;


(* The header: the frozen strip the column titles sit on, drawn from left like
   the rows below it, with the handle after each column drawn as a cell of the
   strip.  The handle is drawn in the header's own pair, so it reads as a place
   in the strip rather than a gap in it, and it is the one cell a press means a
   width rather than a column.

   Every title is set against its left end and the column's alignment is not
   consulted - the `FALSE` below is deliberate and not a value that was dropped.
   A column of numbers is right-aligned because its last digit is what a reader
   compares down the column; a title has no last digit, and a strip of titles
   each obeying its own column's alignment is ragged at both ends with no gain.
   The alignment is the owner's answer about the cells, and it stays that. *)
PROCEDURE DrawHead (self: Table; target: TuiCanv.Canvas; x0, x1: INTEGER);
VAR
    k, cx, w, a, ta, hx: INTEGER;
    s: ARRAY MAXCOLNAME OF CHAR;
    ch: ARRAY 2 OF CHAR;
BEGIN
    ta := TuiTheme.Attr(TuiTheme.TableHead);
    target.Fill(target, self.x, self.y, self.width, 1, " ", ta);
    k := 0;
    WHILE k < self.ncol DO
        cx := x0 + ColX(self, k) - self.left;
        w := ColWidth(self, k);
        Strings.Copy(self.titles[k], s);
        IF k = self.selCol THEN
            a := TuiTheme.Attr(TuiTheme.TableHeadSel)
        ELSE
            a := ta
        END;
        PutCell(target, x0, x1, self.y, cx, w, s, FALSE, a);
        hx := cx + w;
        PutChar(target, x0, x1, self.y, hx, HGAP, TuiCanv.SL_V, ta);
        INC(k)
    END
END DrawHead;


(* One data row, and the mark cell that belongs to it.  The mark column is drawn
   whether or not there is a row under it, so the column reads as a column and
   not as something that stops where the data does - and the handle after each
   column is drawn here for the same reason and not only in the header: a rule
   that stood in the header and nowhere else left the titles as one highlighted
   band with dividers in it and the rows below as an undivided field, which reads
   as two things rather than as one table.  The whole column, title and cells
   alike, is bounded on its right by a rule, and the horizontal rule under the
   header is the one line that crosses them.

   The pair is the cursor's and not the range's.  The cursor is where the
   keyboard is and not a second selection: it takes the selection pair on the one
   row it stands on, so a user can always see where an arrow would go - and the
   star in the mark column is what says a row is chosen, written from Chosen and
   from nothing else, so that a row spanned by a Shift and a row ticked with a
   Space both carry one and no other row does.  What the picture shows as chosen
   is therefore exactly what the owner reads as chosen.  A single-row table has
   no mark column to write a star in, and there the pair on the cursor row is the
   whole of what says which row is the selection.

   The handle is drawn in the row's own pair rather than in a colour of its own,
   which is what the header does with it too: the rule is a cell of the row it
   bounds, so a cursor drawn across a row draws across its rules as well. *)
PROCEDURE DrawRow (self: Table; target: TuiCanv.Canvas; row, y: INTEGER;
                   x0, x1: INTEGER);
VAR
    k, cx, w, hx, a: INTEGER;
    s: ARRAY CELLLEN OF CHAR;
    ch: ARRAY 2 OF CHAR;
BEGIN
    IF row = self.sel THEN
        IF self.focused THEN
            a := TuiTheme.Attr(TuiTheme.TableRowSel)
        ELSE
            a := TuiTheme.Attr(TuiTheme.TableRowSelIdle)
        END
    ELSE
        a := TuiTheme.Attr(TuiTheme.TableBody)
    END;
    target.Fill(target, self.x, y, self.width, 1, " ", a);
    (* the mark cell exists only where the column does; without the setting there
       is no cell of it, and the first column has already been given the one it
       used to leave empty *)
    IF self.multi THEN
        IF Chosen(self, row) THEN ch[0] := "*" ELSE ch[0] := " " END;
        ch[1] := 0X;
        PutCell(target, self.x, self.x, y, self.x, MARKCOL, ch, FALSE, a)
    END;
    k := 0;
    WHILE k < self.ncol DO
        cx := x0 + ColX(self, k) - self.left;
        w := ColWidth(self, k);
        GetCell(self, row, k, s);
        PutCell(target, x0, x1, y, cx, w, s, self.rights[k], a);
        hx := cx + w;
        PutChar(target, x0, x1, y, hx, HGAP, TuiCanv.SL_V, a);
        INC(k)
    END
END DrawRow;


(* How tall the thumb is on a track of n cells, and which cell it starts on.  The
   thumb is the view's share of the content, travelling over the track's free
   length as the view travels over its own - from the first row to the last -
   which is what puts it at the very end of the track when the view is at the
   very end of the content.  A plain proportion of top to count leaves it a cell
   short at one end, which reads as a bar that will not reach the end.  Both
   divisions are guarded, so a view that shows everything - where the denominator
   would be zero - takes the branch that does not divide. *)
PROCEDURE Thumb (count, cells, top: INTEGER; VAR size, offset: INTEGER);
BEGIN
    IF count <= cells THEN
        size := cells;
        offset := 0
    ELSE
        size := cells * cells DIV count;
        IF size < 1 THEN size := 1 END;
        offset := top * (cells - size) DIV (count - cells);
        IF offset > cells - size THEN offset := cells - size END
    END;
    IF offset < 0 THEN offset := 0 END;
    IF size < 0 THEN size := 0 END
END Thumb;


(* Put the top of the thumb at cell thumbTop of the track, and the view's top
   where that comes to.  This is the exact inverse of what Thumb does with top,
   which is what dragging the thumb needs on every step.  The selection is
   deliberately left alone: a scrollbar scrolls, it does not choose. *)
PROCEDURE ScrollTo (count, cells, thumbTop: INTEGER): INTEGER;
VAR size, off, t: INTEGER;
BEGIN
    Thumb(count, cells, 0, size, off);
    IF thumbTop < 0 THEN thumbTop := 0 END;
    IF thumbTop > cells - size THEN thumbTop := cells - size END;
    IF thumbTop < 0 THEN thumbTop := 0 END;
    IF cells - size > 0 THEN
        t := thumbTop * (count - cells) DIV (cells - size)
    ELSE
        t := 0                            (* nothing is scrolled: no track *)
    END;
    IF t > count - cells THEN t := count - cells END;
    IF t < 0 THEN t := 0 END;
    RETURN t
END ScrollTo;


(* The vertical bar, down the widget's last column and over the data rows only,
   so it stops where the header begins and never covers it. *)
PROCEDURE DrawVBar (self: Table; target: TuiCanv.Canvas; count, cells: INTEGER);
VAR i, size, off: INTEGER; a: INTEGER;
BEGIN
    a := TuiTheme.Attr(TuiTheme.TableBar);
    Thumb(count, cells, self.top, size, off);
    FOR i := 0 TO cells - 1 DO
        IF (i >= off) & (i < off + size) THEN
            target.Put(target, self.x + self.width - 1, self.y + HEADROWS + i,
                       TuiCanv.BLOCK, a)
        ELSE
            target.Put(target, self.x + self.width - 1, self.y + HEADROWS + i,
                       TuiCanv.SHADE_LIGHT, a)
        END
    END
END DrawVBar;


(* The horizontal bar, along the widget's last row and over the body only, so it
   starts where the mark column ends and stops where the vertical bar's column
   begins. *)
PROCEDURE DrawHBar (self: Table; target: TuiCanv.Canvas; x0, cells: INTEGER);
VAR i, size, off, a: INTEGER;
BEGIN
    a := TuiTheme.Attr(TuiTheme.TableBar);
    Thumb(Total(self), cells, self.left, size, off);
    FOR i := 0 TO cells - 1 DO
        IF (i >= off) & (i < off + size) THEN
            target.Put(target, x0 + i, self.y + self.height - 1,
                       TuiCanv.BLOCK, a)
        ELSE
            target.Put(target, x0 + i, self.y + self.height - 1,
                       TuiCanv.SHADE_LIGHT, a)
        END
    END
END DrawHBar;


PROCEDURE draw (self: Table; target: TuiCanv.Canvas);
VAR
    n, tot, rows, bw, i, y, x1: INTEGER;
    vbar, hbar: BOOLEAN;
BEGIN
    Ensure(self);
    n := NData(self);
    tot := Total(self);
    Bars(self, n, tot, vbar, hbar);
    rows := Visible(self, hbar);
    bw := self.width - MarkCol(self);
    IF vbar THEN DEC(bw, TRACK) END;
    IF bw < 0 THEN bw := 0 END;
    (* the body ends where the vertical bar's column starts, or at the widget's
       own last cell when there is no bar *)
    x1 := self.x + self.width - 1;
    IF vbar THEN DEC(x1, TRACK) END;

    DrawHead(self, target, self.x + MarkCol(self), x1);
    IF self.height > 1 THEN
        target.HLine(target, self.x, self.y + 1, self.width, TuiCanv.SL_H,
                     TuiTheme.Attr(TuiTheme.TableHead))
    END;
    FOR i := 0 TO rows - 1 DO
        y := self.y + HEADROWS + i;
        IF self.top + i < n THEN
            DrawRow(self, target, self.top + i, y, self.x + MarkCol(self), x1)
        ELSE
            (* past the last row: the surface, so a short table does not show
               whatever the frame put there *)
            target.Fill(target, self.x, y, self.width, 1, " ",
                        TuiTheme.Attr(TuiTheme.TableBody))
        END
    END;
    IF vbar THEN DrawVBar(self, target, n, rows) END;
    IF hbar THEN
        (* The bar's own row is not a data row, so nothing above has painted it -
           and the two cells of it the bar does not cover, the one under the mark
           column and the one under the vertical bar, would otherwise still show
           whatever was in the window's canvas. *)
        target.Fill(target, self.x, self.y + self.height - 1, self.width, 1, " ",
                    TuiTheme.Attr(TuiTheme.TableBody));
        DrawHBar(self, target, self.x + MarkCol(self), bw)
    END;
    (* Last, because it is a cell drawn over the row it belongs to and not part of
       it: the cell underneath was set by DrawRow a moment ago and the editor's
       own pair is what replaces it. *)
    EditDraw(self, target)
END draw;


(* ---------------------------------------------------------------------------
   The search.  Everything here is about the buffer and the cursor, and nothing
   about the picture: a search the user cannot see is the row it lands on.
   --------------------------------------------------------------------------- *)


PROCEDURE FindReset (self: Table);
BEGIN
    self.nfind := 0;
    self.find[0] := 0X;
    self.findcp := 0
END FindReset;


(* Whether s begins with the first n characters of p.  Case does not matter: a
   user types a name the way they say it, and a table that insisted on the
   capital its data was built with would refuse the search the first time it was
   wanted.  Strings.Cap is the portable spelling of the fold - the same module
   the rest of this file already goes through for its text. *)
PROCEDURE Prefix (s, p: ARRAY OF CHAR; n: INTEGER): BOOLEAN;
VAR ok: BOOLEAN; i: INTEGER; a, b: CHAR;
BEGIN
    ok := TRUE;
    i := 0;
    WHILE ok & (i < n) DO
        a := s[i];
        b := p[i];
        Strings.Cap(a);
        Strings.Cap(b);
        IF (s[i] = 0X) OR (a # b) THEN
            ok := FALSE
        ELSE
            INC(i)
        END
    END;
    RETURN ok
END Prefix;


(* One character typed: the prefix grows and the cursor goes to the first row
   whose cell in the current column begins with it - or, when the character is
   the one before it, to the next such row after the cursor, which is how a
   letter pressed again walks through the rows that share a first letter instead
   of standing still on the first of them.

   The column is EditCol's - the one a header click chose, or the first - and
   it is asked rather than carried, so a table whose header was clicked while a
   search was running searches where the user last pointed.

   The cursor is *set* and not marked: a search is a reach, like an arrow is, so
   it collapses a range and leaves the marks.  The id is not fired here; it comes
   from onEvent's own tail, which fires cmd for every road that moved the cursor,
   and this is one of them.

   A search that matches nothing leaves the cursor where it was and keeps the
   character: the next letter may match, and a table that gave the prefix back on
   every miss would be a table that could not be searched for a name whose first
   two letters are rare.

   THE BUFFER HOLDS THE PAGE'S BYTES, which is what the column's own text is
   made of, so one key press appends however many bytes the character has there
   and the prefix the comparison runs against stays a byte string.  Writing the
   low byte of the character instead, as this did, appends half a letter: the
   search then matches nothing, or matches a name that begins with somebody
   else's letter.  TuiPage.BytesOf is that conversion and it is not
   Charset.Encode - on the Windows console the page is UTF-8 and the two agree,
   on DOS the character is one byte of 866 already; see TuiPage.BytesOf.  The
   answer is how many bytes were written - 0 for a character that is not one,
   which cannot arrive here because the arm above tests for it. *)
PROCEDURE FindTyped (self: Table; cp: INTEGER): BOOLEAN;
VAR i, from, k, n: INTEGER; hit, again: BOOLEAN; s: ARRAY CELLLEN OF CHAR;
    b: ARRAY 5 OF CHAR;
BEGIN
    i := 0;
    b[0] := 0X;
    n := TuiPage.BytesOf(cp, b, i);
    b[i] := 0X;
    (* The repeat test is the code point the last press carried and not the last
       byte of the buffer: a two-byte letter put two bytes there, and a second
       press of the *same* letter is a walk to the next row rather than another
       byte appended. *)
    again := (n > 0) & (self.nfind > 0) & (self.findcp = cp);
    IF (n > 0) & ~again THEN
        IF self.nfind + n >= MAXFIND - 1 THEN
            self.nfind := 0             (* longer than any prefix can be useful *)
        END;
        FOR i := 0 TO n - 1 DO
            self.find[self.nfind] := b[i];
            INC(self.nfind)
        END;
        self.find[self.nfind] := 0X;
        self.findcp := cp
    END;
    (* A code point that is not a character is not a search either - it retires
       the one that was running rather than extending it with nothing. *)
    IF n = 0 THEN
        FindReset(self)
    END;
    from := 0;
    IF again THEN from := self.sel + 1 END;
    k := EditCol(self);
    i := from;
    hit := FALSE;
    WHILE (i < NData(self)) & ~hit DO
        GetCell(self, i, k, s);
        IF Prefix(s, self.find, self.nfind) THEN
            hit := TRUE
        ELSE
            INC(i)
        END
    END;
    IF hit THEN
        SetSel(self, i, FALSE)
    END;
    RETURN TRUE
END FindTyped;


(* What has been typed, for an owner that wants to show it.  It is the whole of
   what a search is from outside this module: there is no state to read that the
   cursor does not already say. *)
PROCEDURE FindStr (self: Table; VAR dst: ARRAY OF CHAR);
BEGIN
    Strings.Copy(self.find, dst)
END FindStr;


(* Take a press in the header.  A handle first - a cell that belongs to two
   columns and so can only mean a width - and then a title, which chooses the
   column and fires headCmd.  A press on the mark column's cell of the header,
   where the table has one, is the table's and means nothing yet.

   x is the widget's own cell, the same one HeadDrag is handed, and the two must
   agree: grabDX is the distance from the pointer to the boundary it took hold
   of, HeadDrag subtracts it to find the width, and a press measured in one space
   and carried in the other would put the offset out by the mark column and the
   inset - which is a boundary that jumps two cells to the right on the first
   movement and then follows the pointer honestly, the hardest kind of fault to
   read off a picture.  So the conversion to the body's columns happens here,
   once, where the two columns are looked up, and nowhere else. *)
PROCEDURE HeadPress (self: Table; x: INTEGER);
VAR k, cx, b: INTEGER;
BEGIN
    b := x - (self.x + MarkCol(self)) + self.left;
    k := HandleAt(self, b);
    IF k >= 0 THEN
        self.resizing := TRUE;
        self.rcol := k;
        cx := self.x + MarkCol(self) + ColX(self, k) + ColWidth(self, k) - self.left;
        self.grabDX := x - cx
    ELSE
        k := ColAt(self, b);
        IF k >= 0 THEN
            self.selCol := k;
            TuiWin.Notify(self.host, self, self.headCmd)
        END
    END
END HeadPress;


(* Carry a width drag one step.  The boundary is put where the pointer is less
   the offset it took hold at, so the boundary stays under the pointer instead of
   jumping to it on the first move. *)
PROCEDURE HeadDrag (self: Table; x: INTEGER);
VAR cx, w: INTEGER;
BEGIN
    cx := self.x + MarkCol(self) + ColX(self, self.rcol) - self.left;
    w := x - self.grabDX - cx;
    IF w < MINCOLW THEN w := MINCOLW END;
    IF w > self.width THEN w := self.width END;
    self.widths[self.rcol] := w
END HeadDrag;


(* A press in the body: the row under it, or the horizontal bar - a page when the
   track is what was pressed and a hold when it was the thumb.  x0 is the track's
   first cell and not the widget's: the mark column, where the table has one,
   stands to its left and the columns scroll behind it, so the bar is the one part
   of the body that does not begin at self.x. *)
PROCEDURE BodyPress (self: Table; VAR e: Events.Event; x0, rows, bw: INTEGER;
                     hbar: BOOLEAN);
VAR row, i, size, off: INTEGER;
BEGIN
    IF hbar & (e.y = self.y + self.height - 1) &
       (e.x >= x0) & (e.x < x0 + bw) THEN
        (* the horizontal bar, tested before the rows: the bar's row is inside
           the widget and a press on it must not also take a row *)
        Thumb(Total(self), bw, self.left, size, off);
        i := e.x - x0;
        IF (i >= off) & (i < off + size) THEN
            (* on the thumb itself: taken hold of, to be dragged by the
               continuation arm in onEvent.  grabDH is how far along the thumb the
               pointer took hold, measured from the track's left end - without it
               the thumb would jump so that its left end sat under the pointer on
               the first move, which is the same fault grabDX and grabDY exist to
               prevent.  Nothing moves here: a press that turns out to be a click
               and no more leaves the view exactly where it was. *)
            self.hgrab := TRUE;
            self.grabDH := i - off
        ELSIF i < off THEN
            self.left := ScrollTo(Total(self), bw, off - bw)
        ELSE
            self.left := ScrollTo(Total(self), bw, off + bw)
        END
    ELSIF (e.y >= self.y + HEADROWS) & (e.y <= self.y + HEADROWS + rows - 1) THEN
        row := self.top + e.y - (self.y + HEADROWS);
        IF row < NData(self) THEN
            IF e.ctrl & self.multi THEN
                IF Mark(self, row, ~IsMarked(self, row)) THEN
                    TuiWin.Notify(self.host, self, self.cmd)
                END
            ELSE
                (* No id here: the cursor moved, and the one place that says so
                   is the end of onEvent, for every road that moved it. *)
                SetSel(self, row, FALSE)
            END
        END
    END
END BodyPress;


PROCEDURE onEvent (self: Table; VAR e: Events.Event): BOOLEAN;
VAR
    handled, keep: BOOLEAN;
    n, tot, rows, bw, size, off, row, was, findCh: INTEGER;
    vbar, hbar: BOOLEAN;
BEGIN
    handled := FALSE;
    Ensure(self);

    (* An edit takes the event before anything else does.  It is a mode of this
       widget rather than a second object - the cell it is in is the cursor's
       cell - so it has to be the first thing asked, or the arms below would move
       the cursor out from under it.

       A key goes to the editor, which keeps what it wants and hands the rest
       back *having committed first*; a mouse press inside the cell is the
       editor's, and one anywhere else ends the edit and is then handled by the
       table in the ordinary way, so a click on another row saves the text and
       moves there in one gesture.  The event is consumed only when the editor
       really took it.

       There is no early way out of here - RETURN is legal only as the last
       statement of a body - so what the editor decided is left in handled and
       the two blocks below, which are guarded on it, do the rest.  Nothing is
       skipped that would have to be: the preamble under this only works out
       numbers, and the two ways the tail fires an id both test the cursor, which
       an editor does not move. *)
    IF self.editing THEN
        IF e.kind = Events.KEYBOARD THEN
            handled := EditKey(self, e)
        ELSIF (e.kind = Events.MOUSE) & Events.IsPress(e) THEN
            IF EditHit(self, e.x, e.y) THEN
                handled := TRUE
            ELSE
                EndEdit(self, TRUE)
            END
        END
    END;

    was := self.sel;
    n := NData(self);
    tot := Total(self);
    Bars(self, n, tot, vbar, hbar);
    rows := Visible(self, hbar);
    bw := self.width - MarkCol(self);
    IF vbar THEN DEC(bw, TRACK) END;
    IF bw < 0 THEN bw := 0 END;

    (* The keys are the window's to hand out, and it hands them to the widget the
       keyboard is on.  A table that took them regardless would answer for every
       window whose ring it stands in.  A press is not gated this way: the
       pointer is what says which widget a press means.

       ~handled is the editor: a key it declined has already committed, and the
       arm that knows the key - Tab, an arrow, a Page Down - is the one that must
       move the cursor, which is the whole reason EditKey does not swallow
       them. *)
    IF ~handled & self.focused & (e.kind = Events.KEYBOARD) THEN
        (* Shift does not change the scancode - it is a bit of the event and not
           part of the code - so the test for it has to be *inside* one arm.  Two
           arms for the same key would make the second dead code, and the first
           is the one that would run. *)
        keep := e.shift & ~e.ctrl;
        (* What this key is for the search, or 0 for a key that is not part of
           one: a printable character with neither Ctrl nor Alt held, which is the
           whole of what may be typed at a table.  Ctrl and Alt are held out
           because they make a keystroke a command - what a file dialog does with
           Ctrl+A, or a window with Alt+F - and a table that ate those would eat
           the accelerators of every window it stands in.

           THE CHARACTER IS A CODE POINT AND NOT A BYTE, and the difference is
           the whole point: a Cyrillic letter is one character and two bytes of
           UTF-8, and e.key is the LOW BYTE of it.  A byte test does one of two
           wrong things - 041FH, the П of a name in Russian, ends in 1FH, below
           the Space the test starts at, so the search never runs; and 044FH,
           which is я, ends in 4FH, which is the letter O, so the search runs
           after somebody else's letter and lands on the wrong row.  e.ch is the
           code point the console body fills in from the wide key record.  A
           producer that has only a byte - the DOS body, whose keyboard answers
           in the code page the screen is drawn in - leaves ch at 0 and is read
           from key, where one byte a character is the whole of the character. *)
        findCh := 0;
        IF ~e.ctrl & ~e.alt THEN
            IF e.ch >= 20H THEN
                findCh := e.ch
            ELSIF (e.ch = 0) & (e.key >= 20H) & (e.key < 100H) THEN
                findCh := e.key
            END
        END;
        IF findCh = 0 THEN
            FindReset(self)             (* anything else ends the search *)
        END;
        IF Events.IsKey(e, Events.K_UP) THEN
            SetSel(self, self.sel - 1, keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_DOWN) THEN
            SetSel(self, self.sel + 1, keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_PGUP) THEN
            SetSel(self, self.sel - rows, keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_PGDN) THEN
            SetSel(self, self.sel + rows, keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_HOME) THEN
            SetSel(self, 0, keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_END) THEN
            SetSel(self, n - 1, keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_LEFT) THEN
            (* the arrows scroll the columns: there is no cursor among them, and
               selCol is which column was clicked and not where a caret is *)
            DEC(self.left);
            IF self.left < 0 THEN self.left := 0 END;
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_RIGHT) THEN
            INC(self.left);
            IF self.left > tot - bw THEN self.left := tot - bw END;
            IF self.left < 0 THEN self.left := 0 END;
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_SPACE) & self.multi &
              (self.sel < n) THEN
            FindReset(self);            (* a Space that marked is not a Space typed *)
            IF Mark(self, self.sel, ~IsMarked(self, self.sel)) THEN
                TuiWin.Notify(self.host, self, self.cmd)
            END;
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_ENTER) THEN
            (* Enter opens the cell editor on the cursor's row and the column the
               header last chose - or the first column, for a table whose header
               has never been clicked.  The answer is what is assigned and not a
               word about it: a table that may not be written must *decline* the
               key, not swallow it, so that its Enter goes on to the window
               exactly as it always did.

               F2 is the other key a grid uses for this and it is not free here -
               it is a widget accelerator - and F11 is the Windows console's, so
               Enter is the one that is. *)
            handled := BeginEdit(self)
        ELSIF findCh # 0 THEN
            (* A character, and the search.  It stands last because it is what is
               left: the arms above are the keys and this is everything else with
               a letter in it.  A Space reaches here only when the arm above
               declined it - a table that holds several rows may have one to mark,
               and a cell may hold a space. *)
            handled := FindTyped(self, findCh)
        END
    END;

    IF ~handled & (e.kind = Events.MOUSE) THEN
        IF self.resizing THEN
            (* The handle has the pointer until the button comes up and follows
               it anywhere, on or off the handle - HeadDrag's clamp pins the
               column at the ends and holds it there.  Any event with the button
               still down keeps the hold, a movement no less than a press. *)
            IF Events.IsClick(e) THEN
                HeadDrag(self, e.x)
            ELSE
                self.resizing := FALSE;
                TuiWin.Notify(self.host, self, self.cmd)
            END;
            handled := TRUE
        ELSIF self.vgrab THEN
            (* The thumb of the vertical bar, held the way a column handle is:
               it follows the pointer anywhere, on or off the track, and
               ScrollTo's clamp pins it at the ends.  The selection is left alone
               - a scrollbar scrolls, it does not choose - and no id is fired: a
               view that moved is not a choice that was made. *)
            IF Events.IsClick(e) THEN
                self.top := ScrollTo(n, rows,
                                     e.y - (self.y + HEADROWS) - self.grabDY)
            ELSE
                self.vgrab := FALSE
            END;
            handled := TRUE
        ELSIF self.hgrab THEN
            (* The thumb of the horizontal bar, held exactly as the vertical one
               is: it follows the pointer anywhere, on or off the track, and
               ScrollTo's clamp pins it at the ends.  The offset is measured from
               the track's left end - which begins at the body's first cell and
               not at the widget's, because the mark column stands to the left of
               it and never scrolls - so the pointer's own x is reduced by both.
               As with the vertical bar, no id is fired and nothing is chosen: a
               view that moved is not a choice that was made. *)
            IF Events.IsClick(e) THEN
                self.left := ScrollTo(tot, bw,
                                      e.x - (self.x + MarkCol(self)) - self.grabDH)
            ELSE
                self.hgrab := FALSE
            END;
            handled := TRUE
        ELSIF Events.IsPress(e) & (e.y = self.y) &
              (e.x >= self.x) & (e.x <= self.x + self.width - 1) THEN
            (* The header row, whole: the mark column's cell of it is the table's
               too, and HeadPress declines it by finding no column there, which is
               what stops such a press falling through to whatever is behind. *)
            HeadPress(self, e.x);
            handled := TRUE
        ELSIF Events.IsPress(e) & vbar &
              (e.x = self.x + self.width - 1) &
              (e.y >= self.y + HEADROWS) & (e.y < self.y + HEADROWS + rows) THEN
            (* The vertical bar.  A press on the thumb takes hold of it and drags
               it; a press on the track either side moves a page and pages the
               selection with it, the way PgDn does.  The horizontal bar's arm is
               not here but in BodyPress, because its track lies in the body's
               bottom row rather than in a column of its own.  Whether a mouse
               event is a press is not kept in a field - the event carries it. *)
            Thumb(n, rows, self.top, size, off);
            row := e.y - (self.y + HEADROWS);
            IF (row >= off) & (row < off + size) THEN
                self.vgrab := TRUE;
                self.grabDY := row - off
            ELSIF row < off THEN
                SetSel(self, self.sel - rows, self.sel # self.anchor)
            ELSE
                SetSel(self, self.sel + rows, self.sel # self.anchor)
            END;
            handled := TRUE
        ELSIF Events.IsPress(e) & TuiWidg.Inside(self, e.x, e.y) THEN
            BodyPress(self, e, self.x + MarkCol(self), rows, bw, hbar);
            handled := TRUE
        END
    END;

    (* The id, in one place, for every road that moved the cursor: the six keys,
       a press on a row, and a press on the vertical bar's track, which pages the
       selection exactly as PgDn does.  What it is *not* fired for is a view that
       moved without choosing - the two arrows that scroll the columns, a drag of
       either thumb, a press on the horizontal bar's track - and that is the whole
       of the difference between a scrollbar and a list: one moves the window over
       the data, the other says which row the user means.  The marks are not here
       either; a mark is not the cursor, and the two arms that set one fire for
       themselves. *)
    IF handled & (self.sel # was) THEN
        TuiWin.Notify(self.host, self, self.cmd)
    END;

    IF handled THEN
        e.kind := Events.NONE            (* taken: nobody further down sees it *)
    END;
    RETURN handled
END onEvent;


(* The two ways in for a router that does not know what kind of widget this is:
   take an event, and take the keyboard on or off.  Both are declared for
   TuiWidg.Widget, which is what a window's ring holds, and both narrow back to a
   table before doing anything - the guard on the type, the cast for the fields.

   focused is also what draws the cursor row in the pair a selection is drawn in,
   so a table whose window does not have the keyboard shows the row it is on the
   way it shows it while nobody is looking at it. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR t: Table;
BEGIN
    IF w IS Table THEN
        t := w(Table);
        (* An edit does not survive the keyboard leaving - the keys that would
           have ended it are the router's now.  It is dropped rather than
           committed because EndEdit fires an id, and this call can be made from
           outside a Send (ClearRing, RemoveWidget), where the window has nothing
           to drain the queue with and an id left in it would wait for the next
           event that finds it.  The ordinary roads out of an editor - Enter, Tab,
           an arrow, a click elsewhere - all commit, and this one is a window
           being taken apart.

           Only the *loss* of the keyboard ends an edit, and that test is not a
           refinement but the whole of whether an editor can be up at all: the
           window marks its ring at the end of every Send, so the widget holding
           the keyboard is handed the keyboard again after every event it
           handled - including the Enter that opened the editor.  Ending the edit
           on every call took it away in the same event that began it, and the
           editor was never drawn. *)
        IF t.focused & ~on THEN
            EndEdit(t, FALSE)
        END;
        t.focused := on
    END
END Take;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR t: Table; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS Table THEN
        t := w(Table);
        r := t.onEvent(t, e)
    END;
    RETURN r
END Handle;


(* Where it draws itself, for a window that paints what it owns. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR t: Table;
BEGIN
    IF w IS Table THEN
        t := w(Table);
        t.draw(t, target)
    END
END Paint;


PROCEDURE DoneTable (self: Oberon.Object);
VAR t: Table;
BEGIN
    t := self(Table);
    DISPOSE(t)
END DoneTable;


(* A table of the window host, which takes it from here: it is painted with
   everything else that window owns and given back when the window is.  A host of
   NIL is a table nobody owns but its maker.

   h is asserted to be at least HEADROWS + 2: the header, the rule under it, and
   two rows to put data in.  A table shorter than that could still be drawn, but
   every one of its four gestures would be a gesture on a row that is not there,
   and the assertion is the honest way to say so - clamping the height instead
   would give a table that silently does nothing. *)
PROCEDURE Create* (x, y, w, h: INTEGER; multi: BOOLEAN; cmd, headCmd: INTEGER;
                   env: TuiWidg.Widget; host: TuiWin.Window): Table;
VAR t: Table;
BEGIN
    ASSERT((w > MARKCOL + MINCOLW) & (h >= HEADROWS + 2));
    NEW(t);
    t.x := x;
    t.y := y;
    t.width := w;
    t.height := h;
    t.visible := TRUE;
    t.focused := FALSE;
    t.canvas := NIL;
    t.Cols := NIL;
    t.ColDesc := NIL;
    t.RowsProc := NIL;
    t.Cell := NIL;
    t.env := env;
    t.Editable := NIL;
    t.SetCell := NIL;
    t.ncol := 0;
    t.loaded := FALSE;
    t.sel := 0;
    t.anchor := 0;
    t.top := 0;
    t.left := 0;
    t.selCol := -1;
    t.multi := multi;
    t.nmarks := 0;
    t.editing := FALSE;
    t.ecol := 0;
    t.ebuf[0] := 0X;
    t.elen := 0;
    t.ecaret := 0;
    t.efirst := 0;
    t.echanged := FALSE;
    t.resizing := FALSE;
    t.rcol := 0;
    t.grabDX := 0;
    t.vgrab := FALSE;
    t.grabDY := 0;
    t.hgrab := FALSE;
    t.grabDH := 0;
    t.nfind := 0;
    t.find[0] := 0X;
    t.findcp := 0;
    t.cmd := cmd;
    t.headCmd := headCmd;
    t.lastCmd := 0;
    t.host := host;
    t.draw := draw;
    t.onEvent := onEvent;
    t.handler := Handle;
    t.taker := Take;
    t.painter := Paint;
    t.onCommand := NIL;                 (* a table fires ids, it takes none *)
    t.SetSource := SetSource;
    t.Width := Width;
    t.ColAt := ColAt;
    t.IsMarked := IsMarked;
    t.Chosen := Chosen;
    t.Mark := Mark;
    t.ClearMarks := ClearMarks;
    t.SetMulti := SetMulti;
    t.Select := Select;
    t.SetEdit := SetEdit;
    t.BeginEdit := BeginEdit;
    t.EndEdit := EndEdit;
    t.Editing := Editing;
    t.RowChanged := RowChanged;
    t.RowsChanged := RowsChanged;
    t.ColsChanged := ColsChanged;
    t.FindStr := FindStr;
    t.Done := DoneTable;
    TuiWin.Own(host, t);
    RETURN t
END Create;

END TuiTbl.
