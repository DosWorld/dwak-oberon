MODULE TuiList;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A list box: a column of rows, one of them selected, scrolled by the arrow
   keys and scrolled to show the selection.

   The selection is one set of rows and it is drawn one way, exactly as a
   table's is.  sel is the row the cursor is on, with anchor the other end of a
   range the Shift key grows and a plain arrow collapses - the shape a text
   area's selection already has - and the marks are rows ticked one at a time
   with Space or with a click that carries Ctrl, which survive the cursor moving
   away from them.  Chosen is the two together and it is the whole of what the
   picture shows: every chosen row carries a star in the mark column, whether a
   Shift spanned it or a Space ticked it, and no other row carries one.  A row
   with a star is therefore a chosen row and a chosen row is a row with a star,
   which is what lets an owner reading Chosen and a user reading the screen agree
   about the same list.  IsMarked is the half that was ticked by hand and nmarks
   how many; nothing is drawn from either, and a list made single-row answers no
   to both and refuses the gestures that would make a mark.

   A list is single-row until its owner says otherwise, so a list that never asks
   for marks is drawn exactly as a list was before there were any: the mark
   column is a column the list has only while it is multi, and until then the
   text begins at the widget's own first cell and nothing here takes a cell of
   its own.  Single-row, the cursor's own pair is the selection, since the one
   row it stands on is the one row chosen.

   A mark is one byte per row and lives in a second ByteArr, grown by Add
   beside the item storage.  A list is not bounded the way a table is - a
   table's rows are an answer to a callback and its marks are a fixed array -
   so the ceiling on a list's marks is its storage's and not a constant's.

   A list fires no ids, and this does not change that: a mark is a choice like
   the cursor is, and the owner reads what was chosen - Chosen, IsMarked,
   nmarks - when its own command runs, or on every frame in Layout.

   Typing finds a row.  A printable character with neither Ctrl nor Alt held is
   taken by the list and the cursor goes to the first row whose text begins with
   what has been typed since the last key the list used for something else - so
   the search is a run of letters and any other key ends it.  Pressing the same
   letter again does not lengthen the search; it walks to the next row that
   begins with the same prefix, which is the way a list of names is read.

   The character typed is a code point and the row's text is bytes, so the one
   is encoded into the other before they are compared: a Cyrillic letter is two
   bytes of UTF-8, and a search for one is a search for those two.  Which is
   what makes the search work on a list of names that are not ASCII - the file
   dialog's listing is one - without the row and the search being two different
   kinds of text.  The fold is the ASCII one, so a search finds the case it was
   typed in.

   Nothing is drawn for the search and no id is fired for it, for the same two
   reasons: the row the cursor lands on is the whole of what it says, and the
   cursor moving is exactly what a list already reports by not reporting
   anything.  FindStr is what an owner that wants the prefix - on a status line,
   say - reads, and it is the only way the search is visible apart from the
   cursor itself.

   The search is a run of letters and not a timed prefix.  Every list box in the
   interface this one is written in the manner of forgets what was typed after a
   pause, and this one cannot: there is no clock in this layer, and a widget
   that read one would be a widget whose behaviour a dump could not repeat - the
   same reason nothing else here is measured in seconds.  The rule that replaces
   it is the one the keyboard already has: a key the list uses for something
   else ends the search, and there is nothing else a key can be here.

   The items live in a ByteArr, one 64 byte slot each - the same container the
   canvas uses, and no second one.  A slot is zeroed by SetLength, the text goes
   in with PutStr and comes back out with GetStr, so nothing here keeps a pointer
   into the item storage.

   PutStr insists that the text and its terminator fit in what is left of the
   array, so an item longer than a slot has to be cut down before it is stored.
   Strings.Copy does that: it stops at LEN(dst) - 1 and terminates.

   The geometry is in cells of whatever canvas the list draws into, and draw
   takes that canvas as a parameter - a list inside a window draws into the
   window's own canvas, not into the desktop.

   The scrollbar is the one thing here that takes the mouse for longer than a
   single event.  A press on the thumb holds it until the button comes up, and a
   press on the track either side of it moves a page; taking hold of the thumb
   is the same shape as the desktop taking hold of a window - the offset from
   the top of the thumb is kept, so the thumb does not jump under the pointer,
   and the press that begins it is told from the movement that follows by the
   event itself, which carries what the event before it left down.  The bar
   moves the view and not the selection, so dragging it can carry the selected
   row off the screen, which is what the arrows are for.

   The pair the selected row is drawn in depends on whether the list has the
   focus: one whose window the desktop is not routing keys to draws it in
   ListSelIdle.  Focus is the application's to give - the framework has no
   notion of what lives inside a window - so this module only reads it. *)

IMPORT ByteArr, TuiCanv, Events, Strings, TuiPage, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST

    ITEMLEN = 64;                   (* bytes one item takes, its 0X included *)
    BARCOLS = 1;                    (* columns the scrollbar takes when it is shown *)
    MARKCOL = 1;                    (* the column the mark cell takes, and a
                                       column the list has only while it is
                                       multi *)
    MARK_ON = "*";                  (* what a chosen row shows in it *)
    MAXFIND* = 16;                  (* characters a search holds, its 0X too.  A
                                       row's text is cut to a slot when it is
                                       added, so a prefix longer than this one
                                       has stopped being a prefix and starts
                                       again - see FindTyped *)

TYPE

    ListBox* = POINTER TO ListBoxDesc;

    ListBoxDesc* = RECORD (TuiWidg.WidgetDesc)
        items: ByteArr.ByteArray;

        (* One byte per row, and never more of them than the item storage has
           slots: a mark is a fact about a row, and the rows are what Add makes.
           It is kept beside the items because it is the thing that is parallel
           to them - the whole of the mark column is this array and one FOR
           loop, and nothing else in the record grew for the sake of a mark. *)
        marks: ByteArr.ByteArray;

        count*, sel*, top*: INTEGER;

        (* The other end of the range the cursor grew from.  A plain move brings
           it along, which is what collapses the range onto one row; a move with
           Shift held leaves it where it was, which is what grows one. *)
        anchor*: INTEGER;

        (* Several rows may be chosen at once.  A list that may not answers no
           to IsMarked, refuses Space and refuses the Ctrl click, and gives up
           the marks it has when it is told so - the setting is the owner's, and
           turning it off is the owner saying the marks mean nothing now.  It is
           also what the mark column is drawn for: single-row, there is no such
           column and the text starts where it always did. *)
        multi*: BOOLEAN;
        nmarks*: INTEGER;

        (* The scrollbar: whether its thumb is being held, and how far down the
           thumb the pointer took hold.  Whether a mouse event is a press is not
           kept here - the event carries it. *)
        grabbing: BOOLEAN;
        grabDY: INTEGER;

        (* What has been typed towards a search, and how much of it there is.
           The buffer is the search: an empty one is a list that is not being
           searched, and there is no second flag saying so.  The buffer holds
           BYTES, because that is what a row is made of, so the character that
           was typed last is kept beside it as a code point: the rule that
           "again" means the same character twice is a rule about characters,
           and the bytes of one are not a way to ask it. *)
        find: ARRAY MAXFIND OF CHAR;
        nfind: INTEGER;
        findcp: INTEGER;

        (* The window that owns it.  A host of NIL is a list nobody owns but
           its maker - a dialog's - and it is then up to that maker to place it,
           paint it and free it. *)
        host: TuiWin.Window;

        draw*:    PROCEDURE (self: ListBox; target: TuiCanv.Canvas);
        onEvent*: PROCEDURE (self: ListBox; VAR e: Events.Event): BOOLEAN;
        Add*:     PROCEDURE (self: ListBox; text: ARRAY OF CHAR);
        Clear*:   PROCEDURE (self: ListBox);
        Get*:     PROCEDURE (self: ListBox; i: INTEGER; VAR text: ARRAY OF CHAR);
        Count*:   PROCEDURE (self: ListBox): INTEGER;
        Select*:  PROCEDURE (self: ListBox; i: INTEGER);
        IsMarked*:   PROCEDURE (self: ListBox; row: INTEGER): BOOLEAN;
        Chosen*:     PROCEDURE (self: ListBox; row: INTEGER): BOOLEAN;
        Mark*:       PROCEDURE (self: ListBox; row: INTEGER;
                                on: BOOLEAN): BOOLEAN;
        ClearMarks*: PROCEDURE (self: ListBox);
        SetMulti*:   PROCEDURE (self: ListBox; on: BOOLEAN);
        FindStr*:    PROCEDURE (self: ListBox; VAR dst: ARRAY OF CHAR)
    END;


PROCEDURE Rows (self: ListBox): INTEGER;
VAR r: INTEGER;
BEGIN
    r := self.height;
    IF r < 1 THEN r := 1 END;
    RETURN r
END Rows;


(* Whether the list is longer than it is tall, and so needs a scrollbar. *)
PROCEDURE Scrolled (self: ListBox): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := self.count > self.height;
    RETURN r
END Scrolled;


(* The thumb: how many rows of the track it takes, and which row it starts on.
   Drawing it and hit testing it have to agree on both, so they are worked out
   here and nowhere else.

   The thumb is the list's visible share of itself, and it travels over the
   track's free length - from the top of the track to its bottom - as the list
   travels over its own, from the first row to the last.  Mapping one range onto
   the other is what puts the thumb at the very bottom when the list is scrolled
   to its very end and at the very top when it is not scrolled at all; taking a
   plain proportion of top to count instead leaves it a row short at one end or
   the other, which reads as a bar that will not reach the end of its track.

   A list that is not scrolled has a thumb as tall as the track, which is also
   what keeps this total: both divisions are guarded, so short lists - where the
   denominators would be zero - take the branch that does not divide. *)
PROCEDURE Thumb (self: ListBox; VAR size, offset: INTEGER);
VAR rows: INTEGER;
BEGIN
    rows := Rows(self);
    IF self.count <= rows THEN
        size := rows;
        offset := 0
    ELSE
        size := rows * rows DIV self.count;
        IF size < 1 THEN size := 1 END;
        offset := self.top * (rows - size) DIV (self.count - rows);
        IF offset > rows - size THEN offset := rows - size END;
        IF offset < 0 THEN offset := 0 END
    END
END Thumb;


(* Put the thumb's top at row thumbTop of the track, and the list's top where
   that comes to.  This is the exact inverse of what Thumb does with top, which
   is what a drag of the thumb needs on every step.

   The selection is deliberately left alone.  A scrollbar scrolls, it does not
   choose: dragging it past the selected row takes the highlight off the screen
   rather than dragging it along, and the arrows bring it back. *)
PROCEDURE ScrollTo (self: ListBox; thumbTop: INTEGER);
VAR rows, size, off, t: INTEGER;
BEGIN
    rows := Rows(self);
    Thumb(self, size, off);
    IF thumbTop < 0 THEN thumbTop := 0 END;
    IF thumbTop > rows - size THEN thumbTop := rows - size END;
    IF thumbTop < 0 THEN thumbTop := 0 END;
    IF rows - size > 0 THEN
        t := thumbTop * (self.count - rows) DIV (rows - size)
    ELSE
        t := 0                            (* nothing is scrolled: there is no track *)
    END;
    IF t > self.count - rows THEN t := self.count - rows END;
    IF t < 0 THEN t := 0 END;
    self.top := t
END ScrollTo;


(* Move top so that sel is one of the rows on show. *)
PROCEDURE EnsureTop (self: ListBox);
VAR rows: INTEGER;
BEGIN
    rows := Rows(self);
    IF self.sel < self.top THEN
        self.top := self.sel
    END;
    IF self.sel >= self.top + rows THEN
        self.top := self.sel - rows + 1
    END;
    IF self.top > self.count - rows THEN
        self.top := self.count - rows
    END;
    IF self.top < 0 THEN
        self.top := 0
    END
END EnsureTop;


PROCEDURE Add (self: ListBox; text: ARRAY OF CHAR);
VAR buf: ARRAY ITEMLEN OF CHAR;
BEGIN
    Strings.Copy(text, buf);            (* cut to a slot, terminator included *)
    self.items.SetLength(self.items, (self.count + 1) * ITEMLEN);
    self.items.PutStr(self.items, self.count * ITEMLEN, buf);
    (* the mark slot for the new row, unmarked.  It grows with the items and by
       one byte where they grow by a slot, so the two are the same length in
       rows and neither can be indexed past the other. *)
    self.marks.SetLength(self.marks, self.count + 1);
    self.marks.Put8(self.marks, self.count, 0);
    INC(self.count);
    IF self.count = 1 THEN
        self.sel := 0
    END;
    EnsureTop(self)
END Add;


PROCEDURE Clear (self: ListBox);
BEGIN
    self.items.SetLength(self.items, 0);
    self.marks.SetLength(self.marks, 0);
    self.count := 0;
    self.sel := 0;
    self.top := 0;
    self.anchor := 0;
    self.nmarks := 0;
    self.nfind := 0;                    (* a search is about rows that are gone *)
    self.find[0] := 0X;
    self.grabbing := FALSE              (* there is nothing left to hold on to *)
END Clear;


PROCEDURE Get (self: ListBox; i: INTEGER; VAR text: ARRAY OF CHAR);
BEGIN
    IF (i >= 0) & (i < self.count) THEN
        self.items.GetStr(self.items, i * ITEMLEN, text)
    ELSE
        text[0] := 0X
    END
END Get;


PROCEDURE Count (self: ListBox): INTEGER;
VAR n: INTEGER;
BEGIN
    n := self.count;
    RETURN n
END Count;


(* Move the cursor to a row and keep it on show.  An empty list selects
   nothing, which is what sel 0 means there: draw shows no highlight.  keep says
   whether the anchor comes along: a plain move collapses the range onto the
   cursor, and a move with Shift held grows it from wherever the anchor is. *)
PROCEDURE SetSel (self: ListBox; i: INTEGER; keep: BOOLEAN);
VAR n: INTEGER;
BEGIN
    n := i;
    IF n < 0 THEN n := 0 END;
    IF n > self.count - 1 THEN n := self.count - 1 END;
    IF n < 0 THEN n := 0 END;
    self.sel := n;
    (* keep is what holds the other end of a range where it was, and a range is
       a selection of several rows - so a list that has not been told it may hold
       several does not grow one.  The setting off means one row, and that is
       true here and not only in what is drawn: without the second test a
       Shift+arrow would spread the selection over the whole stretch and Chosen
       would answer for every row of it, on a list nobody has asked to be
       multi-row.  It is tested here rather than where the arrows are read, so
       that every caller is held to it and not only the keyboard. *)
    IF ~(keep & self.multi) THEN self.anchor := n END;
    EnsureTop(self)
END SetSel;


PROCEDURE Select (self: ListBox; i: INTEGER);
BEGIN
    SetSel(self, i, FALSE)
END Select;


PROCEDURE IsMarked* (self: ListBox; row: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (row >= 0) & (row < self.count) &
         (self.marks.Get8(self.marks, row) # 0);
    RETURN r
END IsMarked;


(* Whether the row is inside the range the cursor and the anchor span. *)
PROCEDURE InRange (self: ListBox; row: INTEGER): BOOLEAN;
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
   an empty list is empty, so a list with nothing in it chooses nothing. *)
PROCEDURE Chosen* (self: ListBox; row: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (self.count > 0) & InRange(self, row);
    IF ~r THEN r := IsMarked(self, row) END;
    RETURN r
END Chosen;


(* Mark a row or unmark it, and say whether anything changed.  A list that is not
   multi refuses, and so does a row the list has no slot for. *)
PROCEDURE Mark* (self: ListBox; row: INTEGER; on: BOOLEAN): BOOLEAN;
VAR changed: BOOLEAN;
BEGIN
    changed := FALSE;
    IF self.multi & (row >= 0) & (row < self.count) &
       (IsMarked(self, row) # on) THEN
        IF on THEN
            self.marks.Put8(self.marks, row, 1);
            INC(self.nmarks)
        ELSE
            self.marks.Put8(self.marks, row, 0);
            DEC(self.nmarks)
        END;
        changed := TRUE
    END;
    RETURN changed
END Mark;


PROCEDURE ClearMarks* (self: ListBox);
BEGIN
    IF self.count > 0 THEN
        self.marks.Fill8(self.marks, 0, self.count, 0)
    END;
    self.nmarks := 0
END ClearMarks;


(* The setting.  Turning it off gives up the marks there are, because a mark the
   owner is no longer being told about is a mark nothing can act on, and one left
   set would make a list turned back on come back wearing marks nobody made. *)
PROCEDURE SetMulti* (self: ListBox; on: BOOLEAN);
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


(* ---------------------------------------------------------------------------
   The search.  Everything here is about the buffer and the cursor, and nothing
   about the picture: a search the user cannot see is the row it lands on.
   --------------------------------------------------------------------------- *)


PROCEDURE FindReset (self: ListBox);
BEGIN
    self.nfind := 0;
    self.findcp := 0;
    self.find[0] := 0X
END FindReset;


(* Whether s begins with the first n characters of p.  Case does not matter: a
   user types a name the way they say it, and a list that insisted on the
   capital it was built with would refuse the search the first time it was
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
   that begins with it - or, when the character is the one before it, to the
   next such row after the cursor, which is how a letter pressed again walks
   through the rows that share a first letter instead of standing still on the
   first of them.

   The cursor is *set* and not marked: a search is a reach, like an arrow is, so
   it collapses a range and leaves the marks.  That is the one rule a list and a
   table both keep about the selection, and the search is not an exception to it.

   A search that matches nothing leaves the cursor where it was and keeps the
   character: the next letter may match, and a list that gave the prefix back on
   every miss would be a list that could not be searched for a name whose first
   two letters are rare. *)
(* The typed character, as a code point, joined to the search.

   The search buffer holds bytes because a row holds bytes, and a character is
   not always one of them: on the Windows console a Cyrillic letter arrives as
   the one code point it is and is two bytes of UTF-8, which is what a row's
   name is made of.  So the character is turned into the page's bytes here and
   it is the bytes that are kept, which is what makes Prefix a byte comparison
   and still the right one.

   TuiPage.BytesOf IS THAT CONVERSION and it is not Charset.Encode.  On the
   Windows console the page is UTF-8 and the two are the same call; on DOS the
   page is 866 and the character in the event is one byte of it, so encoding it
   as a code point would put two bytes where the rows hold one and the search
   would fail on exactly the letters it exists for.  See TuiPage.BytesOf. *)
PROCEDURE FindTyped (self: ListBox; cp: INTEGER): BOOLEAN;
VAR i, from, n: INTEGER; hit, again: BOOLEAN; s: ARRAY ITEMLEN OF CHAR;
    b: ARRAY 5 OF CHAR;
BEGIN
    i := 0;
    b[0] := 0X;
    n := TuiPage.BytesOf(cp, b, i);
    b[i] := 0X;
    (* A character that encodes to nothing - which cannot come from a keyboard -
       is dropped rather than searched for, so that no empty run is added to the
       prefix and the next letter typed continues the search it belongs to. *)
    again := (n > 0) & (self.nfind > 0) & (self.findcp = cp);
    IF (n > 0) & ~again THEN
        IF self.nfind + n > MAXFIND - 1 THEN
            self.nfind := 0             (* longer than any prefix can be useful *)
        END;
        FOR i := 0 TO n - 1 DO
            self.find[self.nfind] := b[i];
            INC(self.nfind)
        END;
        self.find[self.nfind] := 0X;
        self.findcp := cp
    END;
    IF n = 0 THEN
        FindReset(self)                 (* nothing was added: start again *)
    END;
    from := 0;
    IF again THEN from := self.sel + 1 END;
    i := from;
    hit := FALSE;
    WHILE (i < self.count) & ~hit DO
        Get(self, i, s);
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
PROCEDURE FindStr (self: ListBox; VAR dst: ARRAY OF CHAR);
BEGIN
    Strings.Copy(self.find, dst)
END FindStr;


PROCEDURE draw (self: ListBox; target: TuiCanv.Canvas);
VAR
    i, rows, shown, w, tw, a, bar, track, x0: INTEGER;
    la, sa, ba: INTEGER;                (* the three pairs, read once per frame *)
    line: ARRAY ITEMLEN OF CHAR;
BEGIN
    la := TuiTheme.Attr(TuiTheme.List);
    (* The cursor's row is drawn in the pair the list's focus deserves.  The
       keyboard's window is the one whose arrows move, and this is what says so
       inside the list and not only in the frame around it.  The cursor is where
       the keyboard is and not a second selection, so it is this one row that
       takes the pair and never the range: what is chosen is said by the star in
       the mark column, which is written for every chosen row alike and for no
       other - a row a Shift spanned and a row a Space ticked carry the same one.
       Single-row there is no such column, and this pair is then the whole of
       what says which row is the selection. *)
    IF self.focused THEN
        sa := TuiTheme.Attr(TuiTheme.ListSel)
    ELSE
        sa := TuiTheme.Attr(TuiTheme.ListSelIdle)
    END;
    ba := TuiTheme.Attr(TuiTheme.ListBar);
    rows := Rows(self);
    w := self.width;
    (* Where the text begins and how much of it there is room for.  Both are the
       same cell narrower while the list is multi, because the mark column is
       the widget's first cell then and the text begins one along. *)
    x0 := self.x;
    IF self.multi THEN INC(x0, MARKCOL) END;
    IF Scrolled(self) THEN
        tw := w - BARCOLS
    ELSE
        tw := w
    END;
    IF self.multi THEN DEC(tw, MARKCOL) END;
    IF tw < 0 THEN tw := 0 END;
    IF tw > ITEMLEN - 1 THEN tw := ITEMLEN - 1 END;

    shown := self.count - self.top;
    IF shown > rows THEN shown := rows END;
    IF shown < 0 THEN shown := 0 END;

    FOR i := 0 TO rows - 1 DO
        IF i < shown THEN
            self.Get(self, self.top + i, line);
            IF self.top + i = self.sel THEN
                a := sa
            ELSE
                a := la
            END
        ELSE
            line[0] := 0X;
            a := la
        END;
        target.Fill(target, self.x, self.y + i, w, 1, " ", a);
        IF i < shown THEN
            (* the mark cell: the row has already been filled with blanks, so an
               unchosen row is the space that is there and only a chosen one is
               written at all.  Chosen and not IsMarked, because the star is the
               selection and not the ticks alone: this is the cell the owner's
               Chosen is read off, and the two have to name the same rows. *)
            IF self.multi & Chosen(self, self.top + i) THEN
                target.Put(target, self.x, self.y + i, MARK_ON, a)
            END;
            IF Strings.Length(line) > tw THEN line[tw] := 0X END;
            target.Print(target, x0, self.y + i, line, a)
        END
    END;

    IF Scrolled(self) THEN
        (* the track is a light shade and the thumb a solid block; where each of
           them goes is Thumb's business, so that a press on the bar lands on
           what the drawing put there *)
        Thumb(self, bar, track);
        FOR i := 0 TO rows - 1 DO
            IF (i >= track) & (i < track + bar) THEN
                target.Put(target, self.x + w - 1, self.y + i, TuiCanv.BLOCK, ba)
            ELSE
                target.Put(target, self.x + w - 1, self.y + i, TuiCanv.SHADE_LIGHT,
                           ba)
            END
        END
    END
END draw;


PROCEDURE onEvent (self: ListBox; VAR e: Events.Event): BOOLEAN;
VAR
    handled, keep, changed: BOOLEAN;
    rows, size, off, row, findCh: INTEGER;
BEGIN
    handled := FALSE;
    (* Shift does not change the scancode - it is a bit of the event and not part
       of the code - so the test for it has to be *inside* one arm.  Two arms for
       the same key would make the second dead code, and the first is the one
       that would run.  Ctrl is excluded so that Ctrl+Shift+arrow is not a range,
       which is the rule a text area's selection already follows. *)
    keep := e.shift & ~e.ctrl;
    (* The keys are the window's to hand out, and it hands them to the widget the
       keyboard is on.  A list that took them regardless would answer for every
       window whose ring it stands in and take the arrows away from the widget the
       walk is on - the file box, whose first ring entry is the list of drives, is
       exactly that window.  The kind is tested beside the focus, as a table tests
       it: the keys below are keyboard events and nothing else may reach them.  A
       press is not gated either way: the pointer is what says which widget a
       press means. *)
    IF self.focused & (e.kind = Events.KEYBOARD) THEN
        (* What this key is for the search, or 0 for a key that is not part of
           one: a printable character with neither Ctrl nor Alt held, which is
           the whole test - there is no such thing as a scancode that is a
           letter here, the character code is the letter.

           THE CHARACTER IS A CODE POINT AND NOT A BYTE.  A Cyrillic letter is
           one character and two bytes of UTF-8, and the low byte of it on its
           own is a control code - 041FH ends in 1FH, which is below the Space
           this test starts at - so a byte test refuses to search for the letter
           at all, and where it does not refuse it searches for the wrong one.
           The event carries the code point in ch, which is what the console
           body fills in from the wide key record; a producer that has only a
           byte - the DOS body, whose keyboard answers in the code page the
           screen is drawn in - leaves ch at 0 and is read from key, where one
           byte a character is the whole of the character.

           The keys this widget uses for something else are decided by the arms
           below, Space among them, which is a character by this test and a mark
           by the arm that takes it.  Everything that is left ends the search,
           and that is done here and not in each arm: a key the widget does not
           use at all - Tab, Enter, Esc, a Ctrl chord - has no arm to be reset
           in, and those keys end a search exactly as an arrow does. *)
        findCh := 0;
        IF ~e.ctrl & ~e.alt THEN
            IF e.ch >= 20H THEN
                findCh := e.ch
            ELSIF (e.ch = 0) & (e.key >= 20H) & (e.key < 100H) THEN
                findCh := e.key
            END
        END;
        IF findCh = 0 THEN
            FindReset(self)
        END;
        IF Events.IsKey(e, Events.K_UP) THEN
            SetSel(self, self.sel - 1, keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_DOWN) THEN
            SetSel(self, self.sel + 1, keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_HOME) THEN
            SetSel(self, 0, keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_END) THEN
            SetSel(self, self.count - 1, keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_PGUP) THEN
            SetSel(self, self.sel - Rows(self), keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_PGDN) THEN
            SetSel(self, self.sel + Rows(self), keep);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_SPACE) & self.multi &
              (self.sel < self.count) THEN
            (* a mark is not the cursor, and this arm is the only one that says
               so: the six above are reaches and this is a mark on the row the
               cursor is already standing on.  Ins is the file dialog's second
               way to mark a row and is not offered here - a list is a column of
               rows and has no insert gesture to confuse it with.

               Mark answers whether anything changed and the answer is thrown
               away: a list fires no ids, so there is nobody to tell, and what
               the owner reads is the state rather than the change.  It is taken
               into a variable because the dialect has no way to call a function
               as a statement. *)
            FindReset(self);        (* a Space that marked is not a Space typed *)
            changed := Mark(self, self.sel, ~IsMarked(self, self.sel));
            handled := TRUE
        ELSIF findCh # 0 THEN
            (* A character, and the search.  It stands last because it is what
               is left: the arms above are the keys and this is everything else
               with a letter in it.  A Space reaches here only when the arm
               above declined it - a list that holds one row has no mark to
               make, and a name may hold a space. *)
            handled := FindTyped(self, findCh)
        END
    END;
    IF ~handled & (e.kind = Events.MOUSE) THEN
        rows := Rows(self);
        IF self.grabbing THEN
            (* The bar has the pointer until the button comes up and follows it
               anywhere, on or off the track - where ScrollTo's clamp pins the
               thumb at the end and holds it there.  Any event with the button
               still down keeps the hold, a movement no less than a press. *)
            IF Events.IsClick(e) THEN
                ScrollTo(self, e.y - self.y - self.grabDY)
            ELSE
                self.grabbing := FALSE
            END;
            handled := TRUE
        ELSIF Events.IsPress(e) & Scrolled(self) &
              (e.x = self.x + self.width - 1) &
              (e.y >= self.y) & (e.y < self.y + rows) THEN
            (* A press on the bar - the moment the button went down, not the
               movement that follows it.  On the thumb it takes hold of it; on
               the track either side of it, it moves a page.  The bar is tested
               before the rows are, because the bar column is inside the list and
               a press on it must not also select whichever row it happens to be
               level with.

               A page here moves the view and not the selection, exactly as the
               thumb and the track do in a table: a scrollbar scrolls, it does
               not choose.  Choosing the row a page away is what the PgUp and
               PgDn keys are for, and a list that did it from the pointer as well
               would be clearing a selection nobody asked it to touch - the ticks
               are what survive a move of the cursor, and a bar is not a
               cursor. *)
            Thumb(self, size, off);
            row := e.y - self.y;
            IF (row >= off) & (row < off + size) THEN
                self.grabbing := TRUE;
                self.grabDY := row - off
            ELSIF row < off THEN
                ScrollTo(self, off - rows)
            ELSE
                ScrollTo(self, off + rows)
            END;
            handled := TRUE
        ELSIF Events.IsPress(e) & TuiWidg.Inside(self, e.x, e.y) THEN
            (* A click on the rows.  Below the last one there is no row to
               select, and taking the last instead would be a lie about where
               the pointer was.  A movement with the button already down is not
               a click either: dragging across a list would otherwise re-select
               a row at every step of the drag.

               A click that carries Ctrl marks the row instead of moving the
               cursor onto it, which is the one gesture that can mark a row the
               user has not scrolled to.  It is the same split a table makes, and
               it is gated on the setting like everything else here: a list that
               is single-row cannot be marked, by the pointer or by the key. *)
            row := self.top + e.y - self.y;
            IF row < self.count THEN
                IF e.ctrl & self.multi THEN
                    changed := Mark(self, row, ~IsMarked(self, row))
                ELSE
                    self.Select(self, row)
                END
            END;
            handled := TRUE
        END
    END;
    IF handled THEN
        e.kind := Events.NONE            (* taken: nobody further down sees it *)
    END;
    RETURN handled
END onEvent;


(* The two ways in for a router that does not know what kind of widget this is:
   take an event, and take the keyboard on or off.  Both are declared for
   TuiWidg.Widget, which is what a window's ring holds, and both narrow back to
   a list before doing anything - the guard on the type, the cast for the fields.

   focused is also what draws the current row in the pair a selection is drawn
   in, so a list whose window does not have the keyboard shows the row it is on
   the way it shows it while nobody is looking at it. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR l: ListBox;
BEGIN
    IF w IS ListBox THEN
        l := w(ListBox);
        l.focused := on
    END
END Take;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR l: ListBox; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS ListBox THEN
        l := w(ListBox);
        r := l.onEvent(l, e)
    END;
    RETURN r
END Handle;


(* Give the list back: the two arrays first, then the record.  A list owns both
   its item storage and its marks, so freeing the record alone would leave the
   ByteArrays behind - which is why this is not a bare DISPOSE.

   It takes `Oberon.Object` and guards down because it is what goes into the
   inherited `Done` field, whose declared type is `PROCEDURE (self: Object)`.
   Dispose, the second name this class used to carry for the same act, is gone:
   Oberon.mod has the rule. *)
PROCEDURE DoneListBox (self: Oberon.Object);
VAR l: ListBox;
BEGIN
    l := self(ListBox);
    l.items.Done(l.items);
    l.marks.Done(l.marks);
    DISPOSE(l)
END DoneListBox;


(* Where it draws itself, for a window that paints what it owns. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR l: ListBox;
BEGIN
    IF w IS ListBox THEN
        l := w(ListBox);
        l.draw(l, target)
    END
END Paint;


(* A list of the window host, which takes it from here: it is painted with
   everything else that window owns and given back when the window is.  A host of
   NIL is a list nobody owns but its maker - a dialog's - and it is then up to
   that maker to place it, paint it and free it, as before. *)
PROCEDURE Create* (x, y, w, h: INTEGER; host: TuiWin.Window): ListBox;
VAR l: ListBox;
BEGIN
    ASSERT((w > 0) & (h > 0));
    NEW(l);
    l.x := x;
    l.y := y;
    l.width := w;
    l.height := h;
    l.visible := TRUE;
    l.focused := FALSE;
    l.canvas := NIL;
    l.items := ByteArr.Create(0);
    l.marks := ByteArr.Create(0);
    l.count := 0;
    l.sel := 0;
    l.top := 0;
    l.anchor := 0;
    (* single-row until the owner says otherwise, which is what keeps a list
       that never asks for marks the picture it has always been *)
    l.multi := FALSE;
    l.nmarks := 0;
    l.nfind := 0;
    l.findcp := 0;
    l.find[0] := 0X;
    l.grabbing := FALSE;
    l.grabDY := 0;
    l.lastCmd := 0;
    l.host := host;
    l.draw := draw;
    l.onEvent := onEvent;
    l.handler := Handle;
    l.taker := Take;
    l.painter := Paint;
    l.onCommand := NIL;                 (* a list fires no ids: it chooses, and
                                           the owner reads what it chose *)
    l.Add := Add;
    l.Clear := Clear;
    l.Get := Get;
    l.Count := Count;
    l.Select := Select;
    l.IsMarked := IsMarked;
    l.Chosen := Chosen;
    l.Mark := Mark;
    l.ClearMarks := ClearMarks;
    l.SetMulti := SetMulti;
    l.FindStr := FindStr;
    l.Done := DoneListBox;
    TuiWin.Own(host, l);
    RETURN l
END Create;

END TuiList.
