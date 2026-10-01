MODULE TuiFld;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A one line text field: some text, a caret and a selection.

   The text is in the record - what a field holds is fixed and small, so there
   is nothing to allocate and nothing to free, which is what keeps the invariant
   that no frame allocates.  The caret is an index into it and the selection is
   the run between the caret and the anchor, the anchor being where a selection
   began; the two are equal when nothing is selected, so "is anything selected"
   is one comparison, and choosing a run backwards needs no second kind of state.

   The caret is drawn as a selection of one cell, in the same pair, and it does
   not blink: the framework draws a whole frame at a time and holds no timer, so
   a blinking caret would be the one thing on the screen that needed something to
   happen in order to happen.  What it does instead is take the pair the
   keyboard's selection takes - bright when the field has the focus, quiet when
   it does not - so where typing would go is visible whether or not the field is
   the one being typed into.

   A field takes a key only when it has the focus, and even then it does not take
   Tab, Enter or Esc: those belong to whatever put the field on the screen, which
   for a dialog is what moves to the buttons and what answers it.  A field inside
   a dialog is offered every key and every click before the buttons are.

   The four clipboard keys are here - Ctrl+A, Ctrl+C, Ctrl+X, Ctrl+V - and what
   they reach is Clipboard: this program's own copy always, the system clipboard
   where the target has one.  Copying nothing copies nothing, so a stray Ctrl+C
   does not clear what was copied before it.

   The text is cut to what the field holds: typing past the end does nothing, and
   a paste longer than the field keeps what fits.  A drag with the button held
   chooses a run, and the view scrolls to keep the caret on show - so a drag does
   not run out of cells - but holding the pointer past the edge does not scroll
   by itself, because nothing arrives to make it: the input layer reports the
   pointer only when it moves.

   THE TEXT IS BYTES AND THE FIELD IS CELLS, and on a page where a character is
   more than one byte the two are different counts.  The text is whatever page
   TuiPage names - UTF-8 on the Windows host, 866 under DOS - the caret, first
   and len are byte indices into it, and a column on the screen is a cell.  A
   Russian name is two bytes to the letter, so a caret moved one byte at a time
   lands in the middle of a letter: it draws the letter after it as if it were
   the one under the caret, and Backspace deletes half of two.  Every walk over
   the text therefore steps a character, through NextByte and PrevByte below, and
   the two counts are converted only where a byte has to become a column (CellOf)
   or a column a byte (ByteAt).  On a one-byte page both helpers are the
   arithmetic that was here before, so nothing a DOS or an ASCII field does
   moves.

   What a key carries is a code point and not a byte, and what the keyboard
   sends is what the page must spell: typing is InsertCp, which encodes the code
   point into the page and refuses one the page cannot spell rather than writing
   a byte that means another letter.  A page that is one byte wide refuses
   everything over 0FFH the same way, which is why a Russian name cannot be
   typed into the DOS field and can be on Windows. *)

IMPORT TuiCanv, Charset, Clipboard, Events, Strings, TuiPage, TuiTheme,
       TuiWidg, TuiWin, Oberon;

CONST
    MAXTEXT* = 64;                  (* bytes the text takes, its 0X included *)

TYPE

    Field* = POINTER TO FieldDesc;

    FieldDesc* = RECORD (TuiWidg.WidgetDesc)
        text: ARRAY MAXTEXT OF CHAR;
        len: INTEGER;               (* bytes of it, the 0X not counted *)
        caret: INTEGER;             (* the byte the next character goes at *)
        anchor: INTEGER;            (* the other end of the selection *)
        first: INTEGER;             (* the byte the leftmost cell shows *)
        dragging: BOOLEAN;          (* the pointer is choosing a run *)

        (* The window that owns it.  A host of NIL is a field nobody owns but
           its maker - a dialog's - and it is then up to that maker to place it,
           paint it and free it. *)
        host: TuiWin.Window;

        draw*:    PROCEDURE (self: Field; target: TuiCanv.Canvas);
        onEvent*: PROCEDURE (self: Field; VAR e: Events.Event): BOOLEAN;
        SetText*: PROCEDURE (self: Field; s: ARRAY OF CHAR);
        GetText*: PROCEDURE (self: Field; VAR s: ARRAY OF CHAR);
        Clear*:   PROCEDURE (self: Field)
    END;


(* The low end of the selection.  The caret is where the keyboard is and the
   anchor is where the run began; a selection made backwards has the anchor
   above the caret, which is why neither end can be read off one field. *)
PROCEDURE SelFrom (self: Field): INTEGER;
VAR i: INTEGER;
BEGIN
    i := self.caret;
    IF self.anchor < i THEN i := self.anchor END;
    RETURN i
END SelFrom;


PROCEDURE SelTo (self: Field): INTEGER;
VAR i: INTEGER;
BEGIN
    i := self.caret;
    IF self.anchor > i THEN i := self.anchor END;
    RETURN i
END SelTo;


PROCEDURE Selected (self: Field): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := self.caret # self.anchor;
    RETURN r
END Selected;


(* The byte after the character that begins at i, and the byte at which the
   character before i begins.  These two are the whole of what makes a
   multi-byte page safe: every walk over the text steps through them, so a caret
   is always on the first byte of a character and a deletion always takes a whole
   one.  On a page that is one byte to the character both are the identity -
   NextByte adds one, PrevByte takes one off - which is what every caller did
   before, so 437 and 866 fields behave exactly as they did.

   NextByte asks the page's own Decode how long the character is rather than
   counting continuation bytes itself: Decode is the one place that knows the
   encoding and refuses a malformed sequence as one U+FFFD of length one, so a
   text with a bad byte in it still walks - the alternative is a walker that
   stops dead or one that runs past the end.

   PrevByte cannot ask that question backwards, so it walks back over
   continuation bytes (10xxxxxx) to the lead byte that starts the character.  A
   malformed tail stops at the byte it started from rather than at zero, which is
   the honest answer: it is not known to be part of anything. *)
PROCEDURE NextByte (s: ARRAY OF CHAR; i, len: INTEGER): INTEGER;
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
END NextByte;


PROCEDURE PrevByte (s: ARRAY OF CHAR; i: INTEGER): INTEGER;
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
END PrevByte;


(* The character that begins at byte i, as a canvas cell holds it: a code point.

   The two pages answer this in two different ways and the difference is not
   cosmetic.  Decode on UTF-8 gives the code point itself, and a cell holds a
   code point, so that is the whole of it.  On a byte page the byte is the page's
   own and CharOf is what turns it into the character that page draws - the same
   call the drawing loop made inline before there was a second page.

   CharOf IS NOT THE UTF-8 ANSWER, and calling it there is what this probe found:
   CharOf takes a BYTE and looks it up in the text page, so handing it the code
   point U+041F looks up the entry at 1055 in a two-hundred-and-fifty-six entry
   table and draws whatever that answered - a field of Russian letters came out
   as a row of blanks, because every lookup past the table answered the same
   thing.  A code point is not a byte and only one of the two calls knows it. *)
PROCEDURE CharAt (s: ARRAY OF CHAR; i: INTEGER): TuiCanv.Char;
VAR cp, n: INTEGER; ch: TuiCanv.Char;
BEGIN
    IF TuiPage.Text() = Charset.PageUtf8 THEN
        Charset.Decode(s, i, Charset.PageUtf8, cp, n);
        ch := WCHR(cp)
    ELSE
        ch := TuiCanv.CharOf(ORD(s[i]))
    END;
    RETURN ch
END CharAt;


(* Which cell the byte b is drawn in: how many characters begin before it.  This
   is the byte-to-column half of the conversion, and it is asked by the one thing
   that compares a caret against cells - the scroll. *)
PROCEDURE CellOf (s: ARRAY OF CHAR; b, len: INTEGER): INTEGER;
VAR i, n: INTEGER;
BEGIN
    IF b > len THEN b := len END;       (* a walk that is handed a byte past the
                                           end would otherwise never finish *)
    i := 0; n := 0;
    WHILE i < b DO
        i := NextByte(s, i, len);
        INC(n)
    END;
    RETURN n
END CellOf;


(* The byte k cells after the byte from, which is the column-to-byte half: a
   click at a column is a byte index into the text, and on a multi-byte page it
   is not the column itself. *)
PROCEDURE ByteAt (s: ARRAY OF CHAR; from, k, len: INTEGER): INTEGER;
VAR i, j: INTEGER;
BEGIN
    i := from; j := 0;
    WHILE (j < k) & (i < len) DO
        i := NextByte(s, i, len);
        INC(j)
    END;
    RETURN i
END ByteAt;


(* Scroll the text so that the caret is one of the cells on show.  A field shows
   width cells of it, so a caret past the right edge takes the view with it and
   one before the left edge brings it back; this is the only thing that ever
   moves the text.

   The width is cells and the caret is a byte, so both are counted in cells here
   and the view is walked forward by the difference - moving first by that many
   BYTES is what would land it inside a character.  The answer is the same on a
   one-byte page, where the difference is the count. *)
PROCEDURE EnsureFirst (self: Field);
VAR w, fc, cc: INTEGER;
BEGIN
    w := self.width;
    IF w < 1 THEN w := 1 END;
    fc := CellOf(self.text, self.first, self.len);
    cc := CellOf(self.text, self.caret, self.len);
    IF cc < fc THEN
        self.first := self.caret
    ELSIF cc > fc + w - 1 THEN
        WHILE fc < cc - w + 1 DO
            self.first := NextByte(self.text, self.first, self.len);
            INC(fc)
        END
    END;
    IF self.first > self.len THEN self.first := self.len END;
    IF self.first < 0 THEN self.first := 0 END
END EnsureFirst;


(* Move the caret inside the text.  With keep the anchor stays where it is and
   the selection grows or shrinks; without it there is no selection afterwards
   and the anchor follows the caret. *)
PROCEDURE SetCaret (self: Field; i: INTEGER; keep: BOOLEAN);
BEGIN
    IF i < 0 THEN i := 0 END;
    IF i > self.len THEN i := self.len END;
    self.caret := i;
    IF ~keep THEN self.anchor := i END;
    EnsureFirst(self)
END SetCaret;


(* Drop n characters at pos and leave the caret there with nothing selected,
   which is what every deletion comes to: one character from Backspace, one from
   Delete, or a whole run that something typed or pasted is about to replace. *)
PROCEDURE DeleteAt (self: Field; pos, n: INTEGER);
BEGIN
    IF (pos >= 0) & (n > 0) & (pos < self.len) THEN
        Strings.Delete(self.text, pos, n);
        self.len := Strings.Length(self.text);
        SetCaret(self, pos, FALSE)
    END
END DeleteAt;


(* Put src into the text at pos, and answer how many characters went in: all of
   them when there is room, and what fits when there is not, which is what a
   paste longer than the field comes to.

   Written out rather than left to Strings.Insert because the caller needs that
   number - the caret goes just past what was inserted - and Insert answers only
   whether everything fitted.  The tail moves first and from the right, so the
   copy never walks over what it has not moved yet. *)
PROCEDURE InsertAt (self: Field; pos: INTEGER; src: ARRAY OF CHAR): INTEGER;
VAR n, room, i: INTEGER;
BEGIN
    n := Strings.Length(src);
    room := MAXTEXT - 1 - self.len;
    IF n > room THEN n := room END;
    IF n < 0 THEN n := 0 END;
    IF n > 0 THEN
        i := self.len;
        WHILE i > pos DO
            DEC(i);
            self.text[i + n] := self.text[i]
        END;
        FOR i := 0 TO n - 1 DO
            self.text[pos + i] := src[i]
        END;
        INC(self.len, n);
        self.text[self.len] := 0X
    END;
    RETURN n
END InsertAt;


(* One typed character at the caret, over the selection when there is one.  A
   field that is full takes nothing more and the caret stays where it was.

   What arrives is a code point, because that is what a keyboard carries and
   what the event record holds, and what the text holds is bytes of the page -
   so the character is encoded into the page first and it is those bytes that go
   in.  On UTF-8 that is two bytes for a Cyrillic letter; on 866 it is one, and a
   code point the page has no byte for is not typed at all.  Neither half of that
   is decided here: TuiPage.BytesOf is the one rule for it, and the note there
   says why the conversion is not Charset.Encode - the two agree on the wide page
   and answer different questions on a byte one.  Refusing it is the point: the
   alternative is CHR(cp), which writes the low byte and puts a different letter
   on the screen from the one that was typed.

   What is written is the whole character or nothing of it, so the write is
   measured before it happens - the room is checked against the encoded length
   rather than letting InsertAt cut, which would leave half a sequence at the end
   of a full field and turn the character into a replacement mark. *)
PROCEDURE InsertCp (self: Field; cp: INTEGER);
VAR one: ARRAY 8 OF CHAR; n, k: INTEGER;
BEGIN
    k := 0;
    one[0] := 0X;
    n := TuiPage.BytesOf(cp, one, k);
    IF n > 0 THEN
        IF Selected(self) THEN
            DeleteAt(self, SelFrom(self), SelTo(self) - SelFrom(self))
        END;
        IF n <= MAXTEXT - 1 - self.len THEN
            one[n] := 0X;
            k := InsertAt(self, self.caret, one);
            SetCaret(self, self.caret + k, FALSE)
        END
    END
END InsertCp;


(* The selection to the clipboard.  Nothing selected copies nothing - the
   clipboard is not emptied by a Ctrl+C that carries no run, which is what a
   word processor does too.  The caret and the selection are left alone, so the
   run stays where it is and can be pasted over itself.

   The copy is terminated by hand: CopyRange moves the characters and writes no
   terminator of its own, so without the one written here the clipboard would
   read on into whatever the buffer held before - and a shorter run copied after
   a longer one is exactly when that shows.

   Which half of Clipboard is used is the text page's business.  A UTF-8 text
   page holds UTF-8 already, so the run goes out through Put, which carries
   UTF-8 and is what puts a Russian name on the Windows clipboard as a Russian
   name; a byte page holds bytes, and PutScreen is the pair that says what page
   they are in and turns them into UTF-8 on the way out.  The field is handed
   back the same way in Paste, so a copy and a paste inside one page round-trip.
   The two are not interchangeable: PutScreen reads the run as 866, so handing a
   Cyrillic name from a UTF-8 field to it would put the letters of its bytes on
   the clipboard instead. *)
PROCEDURE Copy (self: Field);
VAR s: ARRAY MAXTEXT OF CHAR; n: INTEGER;
BEGIN
    IF Selected(self) THEN
        n := SelTo(self) - SelFrom(self);
        Strings.CopyRange(self.text, s, SelFrom(self), 0, n);
        s[n] := 0X;
        IF TuiPage.Text() = Charset.PageUtf8 THEN
            Clipboard.Put(s)
        ELSE
            Clipboard.PutScreen(s)
        END
    END
END Copy;


(* Shorten s to at most n bytes, cutting at a character of the text page - a
   paste longer than the room left in the field keeps what fits, and what fits is
   a whole number of characters.  A cut at the byte would leave the lead byte of
   a letter with no continuation behind it, and that draws as a replacement mark
   where the letter was. *)
PROCEDURE CutTo (VAR s: ARRAY OF CHAR; n: INTEGER);
VAR i, j, len: INTEGER;
BEGIN
    IF n < 0 THEN n := 0 END;
    len := Strings.Length(s);
    i := 0; j := 0;
    WHILE (i < len) & (i <= n) DO
        i := NextByte(s, i, len);
        IF i <= n THEN j := i END
    END;
    s[j] := 0X
END CutTo;


(* The clipboard into the text at the caret, over the selection when there is
   one.  An empty clipboard changes nothing.

   Only the first line of what is on the clipboard goes in.  A field is one line
   and cannot hold a block, so a break is where this widget stops reading - and
   the cut belongs here rather than in the platform layer, because a text area
   wants the whole block from the same call.  Both breaks are cut at, CR LF and a
   lone LF, since the DOS clipboard writes the pair and TuiText writes the
   single byte. *)
PROCEDURE Paste (self: Field);
VAR s: ARRAY Clipboard.MAXCLIP OF CHAR; n, i: INTEGER;
BEGIN
    IF TuiPage.Text() = Charset.PageUtf8 THEN
        Clipboard.Get(s)                (* UTF-8 in, UTF-8 text: no conversion *)
    ELSE
        Clipboard.GetScreen(s)          (* the page's own bytes, as before *)
    END;
    i := 0;
    WHILE (s[i] # 0X) & (s[i] # 0DX) & (s[i] # 0AX) DO INC(i) END;
    s[i] := 0X;
    IF Strings.Length(s) > 0 THEN
        IF Selected(self) THEN
            DeleteAt(self, SelFrom(self), SelTo(self) - SelFrom(self))
        END;
        CutTo(s, MAXTEXT - 1 - self.len);
        n := InsertAt(self, self.caret, s);
        SetCaret(self, self.caret + n, FALSE)
    END
END Paste;


PROCEDURE draw (self: Field; target: TuiCanv.Canvas);
VAR
    a, sa, w, col, i, lo, hi, b, cc: INTEGER;
    ch: TuiCanv.Char;
BEGIN
    IF self.visible THEN
        a := TuiTheme.Attr(TuiTheme.Field);
        IF self.focused THEN
            sa := TuiTheme.Attr(TuiTheme.FieldSel)
        ELSE
            sa := TuiTheme.Attr(TuiTheme.FieldSelIdle)
        END;
        w := self.width;
        IF w > MAXTEXT - 1 - self.first THEN w := MAXTEXT - 1 - self.first END;
        IF w < 0 THEN w := 0 END;
        lo := SelFrom(self);
        hi := SelTo(self);
        (* The text is bytes and the field is cells, so the two indices come
           apart here: i is the byte the next character begins at and col is the
           cell it goes in.  The step is a character, through NextByte, so a
           Cyrillic name - two bytes to the letter - draws one cell to the letter
           and not the two letters its bytes spell in the page.

           Everything that compares a caret against a position still compares
           bytes (lo, hi and self.caret), because that is what a caret is; only
           the cell it is drawn at is a cell.

           The two halves of that are why the loop below never asks whether i is
           the caret and asks whether COL is.  Past the last character i stops
           advancing - there is no next character to step to - so every cell from
           there to the end of the field carries the same i, and a byte test
           would call every one of them the caret and draw the whole tail in the
           selection pair.  On an empty field that is the entire band.  The cell
           the caret is on is counted once here instead, and it is the first cell
           past the text only when the caret really is at the end of it. *)
        cc := CellOf(self.text, self.caret, self.len) - CellOf(self.text, self.first, self.len);
        IF (cc < 0) OR (cc >= w) THEN cc := -1 END;
        i := self.first;
        FOR col := 0 TO w - 1 DO
            IF i < self.len THEN
                ch := CharAt(self.text, i)
            ELSE
                ch := " "
            END;
            (* The caret is the selection when there is no selection: the cell it
               sits on is drawn in the same pair, which is what makes the two one
               slot and one rule rather than two of each. *)
            IF (i >= lo) & (i < hi) THEN
                b := sa
            ELSIF (lo = hi) & (col = cc) THEN
                b := sa
            ELSE
                b := a
            END;
            target.Put(target, self.x + col, self.y, ch, b);
            IF i < self.len THEN
                i := NextByte(self.text, i, self.len)
            END
        END
    END
END draw;


(* Word navigation for Ctrl+Left and Ctrl+Right, the rule TuiText applies on
   one line: a word is a maximal run of non-blanks, Right lands on the first
   character of the next word or at the end of the text, Left on the first
   character of the word the caret is in or of the previous one, and the two are
   exact inverses at a word start.  There is no line to cross here. *)

PROCEDURE WordRight (self: Field; keep: BOOLEAN);
VAR c: INTEGER;
BEGIN
    c := self.caret;
    IF c < self.len THEN
        WHILE (c < self.len) & (self.text[c] # " ") DO INC(c) END;
        WHILE (c < self.len) & (self.text[c] = " ") DO INC(c) END
    END;
    SetCaret(self, c, keep)
END WordRight;


PROCEDURE WordLeft (self: Field; keep: BOOLEAN);
VAR c: INTEGER;
BEGIN
    c := self.caret;
    WHILE (c > 0) & (self.text[c - 1] = " ") DO DEC(c) END;
    WHILE (c > 0) & (self.text[c - 1] # " ") DO DEC(c) END;
    SetCaret(self, c, keep)
END WordLeft;


(* The byte a click at screen column x lands on.  The field shows cells and the
   text is bytes, so the column is walked from first a character at a time - and
   a click left of the field start walks back the same way, which is what
   first + (x - self.x) came to before and what the caret's own clamp then made
   of it.  The caret that SetCaret puts here is a byte, and it is a character's
   first byte, so Backspace after a click takes a whole letter. *)
PROCEDURE ClickByte (self: Field; x: INTEGER): INTEGER;
VAR b, k: INTEGER;
BEGIN
    b := x - self.x;
    IF b < 0 THEN
        k := self.first;
        WHILE (b < 0) & (k > 0) DO
            k := PrevByte(self.text, k);
            INC(b)
        END;
        b := k
    ELSE
        b := ByteAt(self.text, self.first, b, self.len)
    END;
    RETURN b
END ClickByte;


PROCEDURE onEvent (self: Field; VAR e: Events.Event): BOOLEAN;
VAR handled: BOOLEAN; p: INTEGER;
BEGIN
    handled := FALSE;
    IF e.kind = Events.KEYBOARD THEN
        (* What the user typed, asked once, and 0 for every key that made no
           character.  Which half of the event that is depends on the producer
           and not on the page - see Events.Char, which is the one place that
           knows - so the arms below test this and not e.key, whose low byte
           refuses П and admits я as an O. *)
        p := Events.Char(e);
        IF self.focused THEN
            handled := TRUE;
            (* The Ctrl+arrow arms stand before the plain ones: a Ctrl+Left
               carries the same scan code as a Left and a character of zero, so
               the plain arm would take it, and IsCtrlScan - the flag and the
               scan code - is the test that tells them apart.  IsCtrl is for the
               letters, which carry a code of their own. *)
            IF Events.IsCtrlScan(e, Events.K_LEFT) THEN
                WordLeft(self, e.shift)
            ELSIF Events.IsCtrlScan(e, Events.K_RIGHT) THEN
                WordRight(self, e.shift)
            (* An arrow moves a character and not a byte: on a multi-byte page
               caret + 1 is the second byte of the letter the caret is on, and
               the caret would then sit inside a character - drawn where the
               next letter is and deleting half of both when a key arrives. *)
            ELSIF Events.IsKey(e, Events.K_LEFT) THEN
                IF ~e.shift & Selected(self) THEN
                    SetCaret(self, SelFrom(self), FALSE)
                ELSE
                    SetCaret(self, PrevByte(self.text, self.caret), e.shift)
                END
            ELSIF Events.IsKey(e, Events.K_RIGHT) THEN
                IF ~e.shift & Selected(self) THEN
                    SetCaret(self, SelTo(self), FALSE)
                ELSE
                    SetCaret(self, NextByte(self.text, self.caret, self.len), e.shift)
                END
            ELSIF Events.IsKey(e, Events.K_HOME) THEN
                SetCaret(self, 0, e.shift)
            ELSIF Events.IsKey(e, Events.K_END) THEN
                SetCaret(self, self.len, e.shift)
            (* Backspace and Delete take a whole character, which is one byte on
               a byte page and as many as the page gives it on UTF-8.  The two
               are written as the run between the caret and the far end of that
               character, so the count comes from the same walk the caret
               moves by and the two cannot come to disagree. *)
            ELSIF Events.IsKey(e, Events.K_BACK) THEN
                IF Selected(self) THEN
                    DeleteAt(self, SelFrom(self), SelTo(self) - SelFrom(self))
                ELSE
                    p := PrevByte(self.text, self.caret);
                    DeleteAt(self, p, self.caret - p)
                END
            ELSIF Events.IsKey(e, Events.K_DEL) THEN
                IF Selected(self) THEN
                    DeleteAt(self, SelFrom(self), SelTo(self) - SelFrom(self))
                ELSE
                    DeleteAt(self, self.caret,
                             NextByte(self.text, self.caret, self.len) - self.caret)
                END
            ELSIF Events.IsCtrl(e, Events.CTRL_A) THEN
                self.anchor := 0;
                SetCaret(self, self.len, TRUE)
            ELSIF Events.IsCtrl(e, Events.CTRL_C) THEN
                Copy(self)
            ELSIF Events.IsCtrl(e, Events.CTRL_X) THEN
                Copy(self);
                IF Selected(self) THEN
                    DeleteAt(self, SelFrom(self), SelTo(self) - SelFrom(self))
                END
            ELSIF Events.IsCtrl(e, Events.CTRL_V) THEN
                Paste(self)
            ELSIF ~e.ctrl & ~e.alt & (p > 0) THEN
                (* p is the character the key made, in the page's own terms: a
                   code point above ASCII on a wide page, and the page's own byte
                   on a byte page, where the byte IS the character.  InsertCp
                   encodes it into the page either way, and refuses a character
                   the page cannot spell rather than writing its low byte. *)
                InsertCp(self, p)
            ELSE
                (* Not ours: Tab, Enter and Esc, which belong to the dialog that
                   put the field here, and anything else this does not know. *)
                handled := FALSE
            END
        END
    ELSIF e.kind = Events.MOUSE THEN
        IF self.dragging THEN
            (* The field holds the pointer until the button comes back up and
               follows it anywhere, on or off the field - the same shape as the
               list's thumb, and what lets a run be chosen past the edge. *)
            IF Events.IsClick(e) THEN
                SetCaret(self, ClickByte(self, e.x), TRUE)
            ELSE
                self.dragging := FALSE
            END;
            handled := TRUE
        ELSIF Events.IsPress(e) & TuiWidg.Inside(self, e.x, e.y) THEN
            (* The press is both ends of the selection - the run begins empty -
               and where the pointer goes from here stretches it.  A press past
               the end of the text puts the caret at the end of it. *)
            SetCaret(self, ClickByte(self, e.x), FALSE);
            self.dragging := TRUE;
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
   a field before doing anything - the guard on the type, the cast for the
   fields.  A field says the keyboard is on it with focused, and that flag is
   what draws the caret, so the walk is visible on the screen and not only in
   what a key does. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR f: Field;
BEGIN
    IF w IS Field THEN
        f := w(Field);
        f.focused := on
    END
END Take;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR f: Field; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS Field THEN
        f := w(Field);
        r := f.onEvent(f, e)
    END;
    RETURN r
END Handle;


PROCEDURE SetText (self: Field; s: ARRAY OF CHAR);
BEGIN
    Strings.Copy(s, self.text);
    self.len := Strings.Length(self.text);
    SetCaret(self, self.len, FALSE)
END SetText;


PROCEDURE GetText (self: Field; VAR s: ARRAY OF CHAR);
BEGIN
    Strings.Copy(self.text, s)
END GetText;


PROCEDURE Clear (self: Field);
BEGIN
    self.text[0] := 0X;
    self.len := 0;
    self.caret := 0;
    self.anchor := 0;
    self.first := 0;
    self.dragging := FALSE
END Clear;


(* A field owns nothing but its record: the text is in it, and the clipboard is
   the module's. *)
PROCEDURE DoneField (self: Oberon.Object);
VAR f: Field;
BEGIN
    f := self(Field);
    DISPOSE(f)
END DoneField;


(* Where it draws itself, for a window that paints what it owns. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR f: Field;
BEGIN
    IF w IS Field THEN
        f := w(Field);
        f.draw(f, target)
    END
END Paint;


(* A field of the window host, which takes it from here: it is painted with
   everything else that window owns and given back when the window is.  A host of
   NIL is a field nobody owns but its maker - a dialog's - and it is then up to
   that maker to place it, paint it and free it, as before. *)
PROCEDURE Create* (x, y, w: INTEGER; host: TuiWin.Window): Field;
VAR f: Field;
BEGIN
    ASSERT(w > 0);
    NEW(f);
    f.x := x;
    f.y := y;
    f.width := w;
    f.height := 1;                      (* a field is one line, always *)
    f.visible := TRUE;
    f.focused := FALSE;
    f.canvas := NIL;                    (* it draws where it is put *)
    f.text[0] := 0X;
    f.len := 0;
    f.caret := 0;
    f.anchor := 0;
    f.first := 0;
    f.dragging := FALSE;
    f.lastCmd := 0;
    f.host := host;
    f.draw := draw;
    f.onEvent := onEvent;
    f.handler := Handle;
    f.taker := Take;
    f.painter := Paint;
    f.onCommand := NIL;                 (* a field fires no ids: the owner reads
                                           its text when it wants to *)
    f.SetText := SetText;
    f.GetText := GetText;
    f.Clear := Clear;
    f.Done := DoneField;
    TuiWin.Own(host, f);
    RETURN f
END Create;

END TuiFld.
