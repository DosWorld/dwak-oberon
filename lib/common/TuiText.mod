MODULE TuiText;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A multi-line text area: a field with rows.

   It is TuiFld one axis over.  The caret is a (line, column) pair instead of a
   single offset, the view scrolls on two axes instead of one, and a selection
   spans lines instead of running along one.  TuiFld cannot be widened into this
   - its Create hard-codes a height of one, its draw uses only the y it was
   given, and every editing helper is private - so the duplication here is
   deliberate rather than an oversight.  TuiFld itself is not touched: TuiDlg
   uses it, and a dialog appears in dumps that are the sample's regression
   anchor.

   The text is one flat run of bytes in a ByteArr, one line after another,
   each ending with a 0AX, and the only other state is a table of where each
   line begins.  So the number of lines and the length of a line are the
   storage's limits and not the widget's: what it holds is what the text needs
   and what ByteArr.MaxBytes allows, which is about 32 MB and so is not a
   limit anybody reaches by typing.  A line's length is the distance between
   two table entries and is not stored at all, and the table is rebuilt from
   the text in one pass after every change rather than edited in place: it is
   derived state, and a pass is both simpler and exactly right.

   Inserting and deleting move the tail of the text, one Move a block, and the
   offsets they use are read before the change.  That is what the storage costs
   and what it buys: a break is one byte, and the text is one contiguous run
   per block, so the search is one pass of repne scasb over it rather than a
   call a line.

   Navigation, selection, copying and searching are always allowed.  The one
   thing readOnly refuses is a change to the text - and it refuses by declining
   the key rather than by taking it and doing nothing, so a Backspace at the top
   of a read-only area still reaches whatever is behind it.  That is why onEvent
   has TuiRadio' shape (hit starts false, each arm that acted sets it) and not
   TuiFld' (which claims every key and gives back the ones it does not want):
   the claim-first shape cannot decline a key it has already claimed.

   The find line is a mode of this widget and not a window and not a second
   widget object.  While it is up the area draws it on its own last row, gives
   it one fewer text row to make room, and takes every key.  That is the same
   modality TuiDlg uses, and the only one the framework has; a separate object
   would have to be positioned, shown and hidden by the owner, which would mean
   the owner knowing when a search begins.

   The search is two scans of the flat text - forward from the caret to the end,
   and then from the top to the caret for the wrap - and not a walk of one call
   a line.  The first character of the query is looked for by ByteArr.FindByte,
   which is a repne scasb a block, and only where it stands are the rest of the
   query's bytes compared; so a one-character query is one instruction a block,
   and a longer one costs a compare a candidate.  It is still line-scoped, and
   the reason needs no bound: a query cannot hold a terminator - the find line
   takes only keys from 20H up - so a match can never run across a break, since
   the break's own byte stops it.  The price is stated rather than hidden: a
   query that spans a line break is not found.

   Both bars are there and both are indicators, not controls: a press on one is
   a caret position, not a scroll.  The horizontal bar takes the widget's own
   last row and the vertical one its last column, so the corner cell belongs to
   the horizontal bar, which is why it runs the full width.  A line wider than
   the box is also reached with the arrow keys, since the view follows the
   caret - the bar says where you are, not where to go.

   The undo history is a list of whole-document states rather than a log of
   operations, and a state is now the text itself: sized at run time, so it is
   exactly as long as the document was, and packed back to back with the other
   states in one ByteArr whose entries are the lengths.  Where a state begins
   is the sum of the lengths before it, so there is no directory to keep in
   step, and dropping the oldest is a move of the ones behind it - in place,
   downwards, into the space the oldest occupied.  One step is taken per edit
   and never per keystroke of a run: typing a word is as many steps as it has
   characters.  That is the simplest exact rule, and the price is stated rather
   than hidden - Ctrl+Z in the middle of a word takes back one character. *)

IMPORT ByteArr, TuiCanv, Charset, Clipboard, Events, Strings, SYSTEM,
       TuiPage, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST
    FINDLEN  = 24;                  (* BYTES the find query holds *)
    FINDPFX  = 6;                   (* the "Find: " the line opens with - its
                                       length in bytes and its width in cells at
                                       once, the six being ASCII *)
    BARCOLS  = 1;                   (* columns the scrollbar takes *)
    BARROWS  = 1;                   (* rows the other one takes *)
    UNDO     = 8;                   (* states the undo history holds *)
    SEP      = 0AX;                 (* the byte that ends a line *)

TYPE

    TextArea* = POINTER TO TextAreaDesc;

    (* One whole editing state: where it lies in the history array, how long
       its text is, and everything that says where the user is in it.  The text
       is not in here - it is a run of bytes in the history's own array, at the
       sum of the lengths before it.  want is part of a state - a caret restored
       without the column it was aiming at would resume a vertical move
       somewhere else.

       rev is the state's text as a number: the live text carries a counter that
       every change moves, and a state remembers the counter's value when it was
       taken, so two texts are the same exactly when their numbers are.  That is
       what lets Push decide whether anything changed without comparing the two
       texts byte by byte - which it would otherwise do on every event, mouse
       moves included. *)
    Snapshot = RECORD
        nline, cline, ccol, aline, acol, top, col0, want: INTEGER;
        tlen, rev: INTEGER
    END;

    TextAreaDesc* = RECORD (TuiWidg.WidgetDesc)
        text: ByteArr.ByteArray;  (* the document: line 0AX line 0AX ... *)
        offs: ByteArr.ByteArray;  (* where each line begins, and the end *)
        hist: ByteArr.ByteArray;  (* the states' texts, back to back *)
        snap: ARRAY UNDO OF Snapshot;
        nline*: INTEGER;            (* lines held; never less than one *)
        (* THE CARET AND BOTH ENDS OF THE SELECTION ARE BYTES into the store and
           always on the first byte of a character; col0 and want are CELLS of
           the screen.  The two are different counts the moment the page makes a
           character more than one byte, and which of them a number is decides
           what may be done with it - so the units are said here rather than
           discovered at a call site.  See the byte-and-cell block below. *)
        cline*, ccol*: INTEGER;     (* the caret, in bytes *)
        want: INTEGER;              (* the column Up and Down aim at, in cells *)
        aline*, acol*: INTEGER;     (* the other end of the selection, in bytes *)
        top*, col0*: INTEGER;       (* row origin, and the column origin - cells *)
        readOnly*: BOOLEAN;         (* the user may not change the text *)
        finding*: BOOLEAN;          (* the find line is up *)
        (* The query, in BYTES - so on a wide page it holds half as many letters
           as FINDLEN says.  A byte search over UTF-8 text is the right search,
           which is why this is left as bytes rather than made a record. *)
        fq: ARRAY FINDLEN OF CHAR;  (* what is being looked for *)
        miss*: BOOLEAN;             (* the last Enter found nothing *)
        dragging: BOOLEAN;          (* the pointer is choosing a block *)
        rev: INTEGER;               (* the live text's number *)
        nhist, cur: INTEGER;        (* how many states are filled, which is live *)
        (* The window that owns it.  A host of NIL is an area nobody owns but
           its maker - a dialog's - and it is then up to that maker to place it,
           paint it and free it. *)
        host: TuiWin.Window;

        draw*:        PROCEDURE (self: TextArea; target: TuiCanv.Canvas);
        onEvent*:     PROCEDURE (self: TextArea; VAR e: Events.Event): BOOLEAN;
        SetText*:     PROCEDURE (self: TextArea; s: ARRAY OF CHAR);
        GetLine*:     PROCEDURE (self: TextArea; i: INTEGER;
                                 VAR dst: ARRAY OF CHAR);
        AddLine*:     PROCEDURE (self: TextArea; s: ARRAY OF CHAR): INTEGER;
        Select*:      PROCEDURE (self: TextArea; l, c: INTEGER);
        SetReadOnly*: PROCEDURE (self: TextArea; flag: BOOLEAN);
        SetPos*:      PROCEDURE (self: TextArea; x, y: INTEGER)
    END;


(* Where line li begins in the text, out of the offset table.  The table holds
   one entry more than there are lines: the start of every line and, one past
   the last, the end of the text - so a line's own end is the next entry less
   its terminator, and no length has to be stored anywhere. *)
PROCEDURE LineStart (self: TextArea; li: INTEGER): INTEGER;
BEGIN
    RETURN self.offs.Get32(self.offs, li * 4)
END LineStart;


(* How long line li is.  Nothing is cached and nothing has to be: the two
   entries the answer is made of are in the table already. *)
PROCEDURE LineLen (self: TextArea; li: INTEGER): INTEGER;
VAR a, b: INTEGER;
BEGIN
    a := 0; b := 0;
    IF (li >= 0) & (li < self.nline) THEN
        a := LineStart(self, li);
        b := LineStart(self, li + 1)
    END;
    RETURN b - a - 1
END LineLen;


(* The text offset of a cell.  Every operation that used to be about a line's
   own array is about a place in the flat text, and this is the one conversion
   between them. *)
PROCEDURE At (self: TextArea; li, col: INTEGER): INTEGER;
BEGIN
    RETURN LineStart(self, li) + col
END At;


(* The offset table rebuilt from the text: one FindByte a line - a repne scasb
   a block - and one 32-bit store an entry.  Every change to the text calls
   this, and a full pass is cheap enough to be the only way the table is ever
   written, which is what keeps it from drifting out of step with the text.

   What is looked for is SEP and not a zero: a line is ended by 0AX, so the
   text may hold no zero byte at all, and a byte that is not there cannot be
   found.

   The table holds one entry more than there are lines - the start of each line
   and, one past the last, the end of the text - so a line's end is the next
   entry and no length is stored anywhere.  The count is what makes the entries
   come out right: a terminator that something follows ends a line and begins
   the next one, and the terminator that ends the text ends the last line and
   begins nothing, so it is the one that writes no entry and is the reason the
   count is the number of terminators bar that one. *)
PROCEDURE Reindex (self: TextArea);
VAR i, k, n, at: INTEGER;
BEGIN
    n := self.text.Length(self.text);
    self.offs.SetLength(self.offs, 8);
    self.offs.Put32(self.offs, 0, 0);
    self.offs.Put32(self.offs, 4, n);
    k := 1;
    i := 0;
    WHILE i < n DO
        at := self.text.FindByte(self.text, i, ORD(SEP));
        IF at < 0 THEN
            i := n
        ELSE
            IF at + 1 < n THEN
                self.offs.SetLength(self.offs, (k + 1) * 4);
                self.offs.Put32(self.offs, k * 4, at + 1);
                INC(k)
            END;
            i := at + 1
        END
    END;
    self.offs.SetLength(self.offs, (k + 1) * 4);
    self.offs.Put32(self.offs, k * 4, n);
    self.nline := k
END Reindex;


(* The character at a cell, a blank when the cell is past the end of its line.
   The byte is read straight from the address rather than through Get8: the
   word walks below ask this once a character, and a call and a bounds test
   apiece would cost more than the compare they feed. *)
PROCEDURE GetCh (self: TextArea; li, col: INTEGER): CHAR;
VAR ch: CHAR;
BEGIN
    ch := " ";
    IF (li >= 0) & (li < self.nline) & (col >= 0) & (col < LineLen(self, li)) THEN
        SYSTEM.GET(self.text.Adr(self.text, At(self, li, col)), ch)
    END;
    RETURN ch
END GetCh;


(* ---- Bytes and cells ------------------------------------------------------

   THE TEXT IS BYTES AND A COLUMN ON THE SCREEN IS A CELL, and on a page where a
   character is more than one byte the two are different counts.  The text is
   whatever page TuiPage names - UTF-8 on the Windows host, 866 under DOS - and
   the caret, the two ends of the selection and the view's own origin are byte
   indices into it.  Keeping them bytes is deliberate: every operation that
   changes the text - insert, delete, split, join, the search - goes on working
   on bytes exactly as it did, and only the three places that were using a byte
   count as a count of CELLS are converted.  Those three are the drawing, the
   horizontal scroll and the click.

   This is TuiFld's arrangement, copied rather than invented.  The one thing
   that differs is the view origin: there it is a byte and here it is a cell,
   because a column is shared by every line of a multi-line area and a byte
   offset into one line is not an offset into the next.

   On a one-byte page every helper below is the arithmetic that was here
   before, so nothing a DOS or an ASCII area draws or does moves. *)

(* One byte of the store by flat offset.  The drawing used to read a run of them
   at a time through the block address, which is why it asked RunLen and Adr; a
   cell is now a character, and a character is not a fixed number of bytes, so
   the walk is one character at a time and the block read has nothing left to
   save.  The cost is stated rather than hidden: a screen of text is now a
   Decode a character on a wide page, against a byte copy apiece before. *)
PROCEDURE RawByte (self: TextArea; at: INTEGER): CHAR;
VAR c: CHAR;
BEGIN
    c := 0X;
    IF (at >= 0) & (at < self.text.Length(self.text)) THEN
        SYSTEM.GET(self.text.Adr(self.text, at), c)
    END;
    RETURN c
END RawByte;


(* How long the character at at is, and what its code point is.

   Charset.Decode is what knows, and it reads an array, so one character is
   copied to it rather than the UTF-8 lengths being written out again here: a
   second copy of that arithmetic is a second thing to keep right, and TuiFld
   made the same call for the same reason.  A copy that runs off the end of the
   text is truncated, and Decode answers a broken sequence for it - which is
   exactly what a line ending inside a character is. *)
PROCEDURE DecodeAt (self: TextArea; at: INTEGER; VAR cp, len: INTEGER);
VAR i, n: INTEGER; buf: ARRAY 8 OF CHAR;
BEGIN
    n := self.text.Length(self.text) - at;
    IF n > 4 THEN n := 4 END;
    IF n < 0 THEN n := 0 END;
    i := 0;
    WHILE i < 8 DO buf[i] := 0X; INC(i) END;
    i := 0;
    WHILE i < n DO buf[i] := RawByte(self, at + i); INC(i) END;
    Charset.Decode(buf, 0, TuiPage.Text(), cp, len)
END DecodeAt;


(* How many bytes the character at at takes.  A lead byte under 80H is one byte
   on every page, so the common case - which is every character of every dump
   this sample draws - never reaches the copy. *)
PROCEDURE CharLen (self: TextArea; at: INTEGER): INTEGER;
VAR cp, n: INTEGER;
BEGIN
    n := 1;
    IF (ORD(RawByte(self, at)) >= 80H) &
       (TuiPage.Text() = Charset.PageUtf8) THEN
        DecodeAt(self, at, cp, n)
    END;
    RETURN n
END CharLen;


(* Whether the byte at at is a continuation byte - the second or later byte of a
   character.  Written once because two things ask it: the walk to the left, and
   the rule that a caret never stands on one.  80H..0BFH is asked as two
   comparisons because this dialect has no bitwise AND on an ordinal, which is
   how Charset asks it too. *)
PROCEDURE Continuation (self: TextArea; at: INTEGER): BOOLEAN;
VAR b: INTEGER; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF TuiPage.Text() = Charset.PageUtf8 THEN
        b := ORD(RawByte(self, at));
        r := (b >= 80H) & (b < 0C0H)
    END;
    RETURN r
END Continuation;


(* The character that begins at at, as a canvas cell holds it: a code point.

   CharOf IS NOT THE UTF-8 ANSWER, and calling it there is the trap TuiFld's own
   comment records - it takes a BYTE and looks it up in the text page, so
   handing it a code point reads past the end of a two-hundred-and-fifty-six
   entry table and draws whatever that answered.  A code point is not a byte and
   only one of the two calls knows it. *)
PROCEDURE CharAt (self: TextArea; at: INTEGER): TuiCanv.Char;
VAR cp, n: INTEGER; ch: TuiCanv.Char;
BEGIN
    IF TuiPage.Text() # Charset.PageUtf8 THEN
        ch := TuiCanv.CharOf(ORD(RawByte(self, at)))
    ELSIF ORD(RawByte(self, at)) < 80H THEN
        ch := WCHR(ORD(RawByte(self, at)))
    ELSE
        DecodeAt(self, at, cp, n);
        ch := WCHR(cp)
    END;
    RETURN ch
END CharAt;


(* The cells that come before byte b of line li: how many characters begin
   before it.  This is the byte-to-column half, and it is asked wherever the
   caret has to be compared with a column - the scroll, the click, the thumb. *)
PROCEDURE CellOf (self: TextArea; li, b: INTEGER): INTEGER;
VAR len, i, n: INTEGER;
BEGIN
    len := LineLen(self, li);
    IF b > len THEN b := len END;
    IF b < 0 THEN b := 0 END;
    i := 0; n := 0;
    WHILE i < b DO
        INC(i, CharLen(self, At(self, li, i)));
        INC(n)
    END;
    RETURN n
END CellOf;


(* And the other way: the byte that stands at cell c of line li.  A cell past
   the end of the line answers the line's end, which is what a click past the
   text has always meant. *)
PROCEDURE ByteOf (self: TextArea; li, c: INTEGER): INTEGER;
VAR len, i, n: INTEGER;
BEGIN
    len := LineLen(self, li);
    i := 0; n := 0;
    WHILE (n < c) & (i < len) DO
        INC(i, CharLen(self, At(self, li, i)));
        INC(n)
    END;
    RETURN i
END ByteOf;


(* One character to the right within a line.  The walk to the left cannot ask
   Decode the question backwards, so PrevByte goes back over the continuation
   bytes instead - the same test, read the other way.  A byte page has no
   continuation bytes and both are the arithmetic of one. *)
PROCEDURE NextByte (self: TextArea; li, c: INTEGER): INTEGER;
BEGIN
    IF c < LineLen(self, li) THEN
        INC(c, CharLen(self, At(self, li, c)))
    END;
    RETURN c
END NextByte;


PROCEDURE PrevByte (self: TextArea; li, c: INTEGER): INTEGER;
BEGIN
    IF c > 0 THEN
        DEC(c);
        WHILE (c > 0) & Continuation(self, At(self, li, c)) DO DEC(c) END
    END;
    RETURN c
END PrevByte;


(* The same two questions once more, over a plain character array - the find
   line's own buffer, which is not the text store and cannot be read by address.
   A query is typed as code points like any other text, so on a wide page it
   holds the bytes of them and one byte is not one cell there either. *)
PROCEDURE BufLen (s: ARRAY OF CHAR; i: INTEGER): INTEGER;
VAR cp, n: INTEGER;
BEGIN
    n := 1;
    IF (ORD(s[i]) >= 80H) & (TuiPage.Text() = Charset.PageUtf8) THEN
        Charset.Decode(s, i, TuiPage.Text(), cp, n)
    END;
    RETURN n
END BufLen;


PROCEDURE BufChar (s: ARRAY OF CHAR; i: INTEGER): TuiCanv.Char;
VAR cp, n: INTEGER; ch: TuiCanv.Char;
BEGIN
    IF TuiPage.Text() # Charset.PageUtf8 THEN
        ch := TuiCanv.CharOf(ORD(s[i]))
    ELSIF ORD(s[i]) < 80H THEN
        ch := WCHR(ORD(s[i]))
    ELSE
        Charset.Decode(s, i, TuiPage.Text(), cp, n);
        ch := WCHR(cp)
    END;
    RETURN ch
END BufChar;


(* And how many cells the first b bytes of it take. *)
PROCEDURE BufCells (s: ARRAY OF CHAR; b: INTEGER): INTEGER;
VAR i, n: INTEGER;
BEGIN
    i := 0; n := 0;
    WHILE (i < b) & (s[i] # 0X) DO
        INC(i, BufLen(s, i));
        INC(n)
    END;
    RETURN n
END BufCells;


(* The longest line, which is what the width axis asks about - the vertical bar
   asks how many lines there are, and this is the same question on the other
   axis.  Nothing is cached, and one pass over the offset table is what it
   costs.

   In CELLS and not in bytes.  This is the extent the horizontal bar is drawn
   against and the width a line has to beat to bring that bar up, and a column
   is a cell: a line of twenty Russian letters is forty bytes and twenty
   columns, so asking the bytes would put a bar under a line that fits. *)
PROCEDURE MaxCells (self: TextArea): INTEGER;
VAR i, m, w: INTEGER;
BEGIN
    m := 0;
    FOR i := 0 TO self.nline - 1 DO
        w := CellOf(self, i, LineLen(self, i));
        IF w > m THEN m := w END
    END;
    RETURN m
END MaxCells;


(* The three quantities that depend on one another - the rows of text, the
   columns of text, and whether there is a horizontal bar - worked out in one
   place, so the view, the drawing and the click arithmetic cannot disagree
   about them.  That is the same reason TextW has always been one definition.

   The circle is real: the horizontal bar takes a row, the rows set the vertical
   bar's column, the columns decide whether a line is too wide, and that decides
   the bar.  It is broken by asking the question once in the world without the
   bar, which is sound because a line too wide for the wider view is certainly
   too wide for the narrower one.  World B is then the same arithmetic against
   one row fewer. *)
PROCEDURE Metrics (self: TextArea; VAR rows, tw: INTEGER; VAR hbar: BOOLEAN);
VAR h: INTEGER;
BEGIN
    h := self.height;
    IF self.finding THEN DEC(h) END;
    IF h < 1 THEN h := 1 END;
    tw := self.width;                       (* world A: no horizontal bar *)
    IF self.nline > h THEN DEC(tw, BARCOLS) END;
    IF tw < 1 THEN tw := 1 END;
    hbar := MaxCells(self) > tw;
    IF hbar THEN
        rows := h - BARROWS;                (* world B: the bar is there *)
        IF rows < 1 THEN rows := 1 END;
        tw := self.width;
        IF self.nline > rows THEN DEC(tw, BARCOLS) END;
        IF tw < 1 THEN tw := 1 END
    ELSE
        rows := h
    END
END Metrics;


(* The rows the text itself shows.  One fewer while the find line is up and one
   fewer again while the horizontal bar is, because both take a row of the
   widget - and it has to be the same number the bar, the view and the click
   arithmetic use, or the bar would be lying by one row.  That is why opening
   and closing the find line both re-run the view. *)
PROCEDURE Rows (self: TextArea): INTEGER;
VAR r, tw: INTEGER; hbar: BOOLEAN;
BEGIN
    Metrics(self, r, tw, hbar);
    RETURN r
END Rows;


PROCEDURE Scrolled (self: TextArea): BOOLEAN;
VAR rows, tw: INTEGER; hbar, r: BOOLEAN;
BEGIN
    Metrics(self, rows, tw, hbar);
    r := self.nline > rows;
    RETURN r
END Scrolled;


(* Whether the horizontal bar is up, which is the same question Metrics answers
   and the one the drawing asks. *)
PROCEDURE HScrolled (self: TextArea): BOOLEAN;
VAR rows, tw: INTEGER; hbar: BOOLEAN;
BEGIN
    Metrics(self, rows, tw, hbar);
    RETURN hbar
END HScrolled;


(* The bar's size and where it starts, copied from TuiList - and both divisions
   inside the one branch that has a denominator, so neither can be zero. *)
PROCEDURE Thumb (self: TextArea; VAR size, ofs: INTEGER);
VAR rows: INTEGER;
BEGIN
    rows := Rows(self);
    IF self.nline <= rows THEN
        size := rows;
        ofs := 0
    ELSE
        size := rows * rows DIV self.nline;
        IF size < 1 THEN size := 1 END;
        ofs := self.top * (rows - size) DIV (self.nline - rows);
        IF ofs > rows - size THEN ofs := rows - size END;
        IF ofs < 0 THEN ofs := 0 END
    END
END Thumb;


(* Keep the caret's line on show, by TuiList' double clamp - which is also what
   makes an area shorter than its box safe, since the second test floors a
   negative count. *)
PROCEDURE EnsureTop (self: TextArea);
VAR rows: INTEGER;
BEGIN
    rows := Rows(self);
    IF self.cline < self.top THEN
        self.top := self.cline
    END;
    IF self.cline >= self.top + rows THEN
        self.top := self.cline - rows + 1
    END;
    IF self.top > self.nline - rows THEN
        self.top := self.nline - rows
    END;
    IF self.top < 0 THEN
        self.top := 0
    END
END EnsureTop;


(* The columns the text itself shows: the width less the bar's column when there
   is a bar.  One definition, used by the view, by the drawing and by the click
   arithmetic, so none of them can disagree about where the text ends. *)
PROCEDURE TextW (self: TextArea): INTEGER;
VAR w, rows: INTEGER; hbar: BOOLEAN;
BEGIN
    Metrics(self, rows, w, hbar);
    RETURN w
END TextW;


(* The horizontal bar's thumb: Thumb with the axes swapped - the track is the
   columns of text, the extent is the longest line, and the origin is col0.
   Both divisions sit inside the branch that has a denominator, so neither can
   be zero: ext > tw >= 1 makes ext at least 2 and ext - tw at least 1. *)
PROCEDURE HThumb (self: TextArea; VAR size, ofs: INTEGER);
VAR tw, ext: INTEGER;
BEGIN
    tw := TextW(self);
    ext := MaxCells(self);
    IF ext <= tw THEN
        size := tw;
        ofs := 0
    ELSE
        size := tw * tw DIV ext;
        IF size < 1 THEN size := 1 END;
        ofs := self.col0 * (tw - size) DIV (ext - tw);
        IF ofs > tw - size THEN ofs := tw - size END;
        IF ofs < 0 THEN ofs := 0 END
    END
END HThumb;


(* The horizontal view, which is TuiFld.EnsureFirst's rule on the other axis.

   The caret is a byte and col0 is a CELL, so the two are brought together here
   rather than compared across.  That difference is the reason this is not the
   three lines TuiFld's own version is: there the text is a string and the view
   origin is a byte into the same string, while here one column is shared by
   every line and a byte offset into this one would be a different column on the
   next. *)
PROCEDURE EnsureCol (self: TextArea);
VAR w, cc, last: INTEGER;
BEGIN
    w := TextW(self);
    cc := CellOf(self, self.cline, self.ccol);
    last := CellOf(self, self.cline, LineLen(self, self.cline));
    IF cc < self.col0 THEN
        self.col0 := cc
    END;
    IF cc > self.col0 + w - 1 THEN
        self.col0 := cc - w + 1
    END;
    IF self.col0 > last THEN
        self.col0 := last
    END;
    IF self.col0 < 0 THEN
        self.col0 := 0
    END
END EnsureCol;


(* The two ends of the selection, ordered so that (fl, fc) is never after
   (tl, tc).  One comparison, written once: every block operation is then
   one-directional, which is one shape to get right instead of four. *)
PROCEDURE SelOrder (self: TextArea; VAR fl, fc, tl, tc: INTEGER);
VAR swap: BOOLEAN;
BEGIN
    swap := (self.aline > self.cline) OR
            ((self.aline = self.cline) & (self.acol > self.ccol));
    IF swap THEN
        fl := self.cline; fc := self.ccol;
        tl := self.aline; tc := self.acol
    ELSE
        fl := self.aline; fc := self.acol;
        tl := self.cline; tc := self.ccol
    END
END SelOrder;


PROCEDURE Selected (self: TextArea): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (self.aline # self.cline) OR (self.acol # self.ccol);
    RETURN r
END Selected;


(* Put the caret at (l, c) or as near as the text allows, bring both views to
   it, and move the other end of the selection onto it unless keep is set -
   which is what makes shift one boolean rather than four extra procedures.  It
   never writes want: that is MoveCol's business, and keeping the two apart is
   what lets a vertical move hold the column it asked for while an edit
   replaces it. *)
PROCEDURE SetCaret (self: TextArea; l, c: INTEGER; keep: BOOLEAN);
VAR len: INTEGER;
BEGIN
    IF l > self.nline - 1 THEN l := self.nline - 1 END;
    IF l < 0 THEN l := 0 END;
    len := LineLen(self, l);
    IF c > len THEN c := len END;
    IF c < 0 THEN c := 0 END;
    (* A caret never stands inside a character.  On a page where a letter is two
       bytes a caller that counted bytes - Select, SetPos, a restored snapshot -
       can land between them, and a caret drawn there marks the wrong letter and
       a Backspace from it would take half of one.  Stepping back to the
       character's first byte is what makes every one of those callers safe
       without each of them converting; on a byte page this loop never turns. *)
    WHILE (c > 0) & Continuation(self, At(self, l, c)) DO DEC(c) END;
    self.cline := l;
    self.ccol := c;
    IF ~keep THEN
        self.aline := l;
        self.acol := c
    END;
    EnsureTop(self);
    EnsureCol(self)
END SetCaret;


(* A horizontal move, which is what remembers the column a later vertical move
   aims at.  Left at the start of a line and Right at its end cross to the
   neighbouring line, the way a text editor does: a caret that stopped dead at
   every line end would make a run of Rights useless for moving through the
   text. *)
PROCEDURE MoveCol (self: TextArea; c: INTEGER; keep: BOOLEAN);
BEGIN
    IF c < 0 THEN
        IF self.cline > 0 THEN
            SetCaret(self, self.cline - 1, LineLen(self, self.cline - 1), keep)
        END
    ELSIF c > LineLen(self, self.cline) THEN
        IF self.cline < self.nline - 1 THEN
            SetCaret(self, self.cline + 1, 0, keep)
        END
    ELSE
        SetCaret(self, self.cline, c, keep)
    END;
    self.want := CellOf(self, self.cline, self.ccol)
END MoveCol;


(* A vertical move: to the line and to the remembered column, clamped to what
   that line holds - and the remembered column is not forgotten, so walking
   down past a short line and back up returns to the column you left.  That is
   the whole reason want exists, and it is one integer. *)
PROCEDURE MoveLine (self: TextArea; d: INTEGER; keep: BOOLEAN);
VAR l: INTEGER;
BEGIN
    l := self.cline + d;
    IF l > self.nline - 1 THEN l := self.nline - 1 END;
    IF l < 0 THEN l := 0 END;
    (* want is a CELL, and this is the one place it becomes a byte.  A line of
       twenty Russian letters is forty bytes and twenty cells, so aiming the
       remembered column at the byte of it would land the caret in the middle of
       a letter, or past the end of a line it fits in. *)
    SetCaret(self, l, ByteOf(self, l, self.want), keep)
END MoveLine;


(* A step of one CHARACTER for the arrow keys, keeping the line crossing Left
   and Right have always had: at the start of a line the answer is the -1 that
   carries MoveCol to the line above, and at its end the LineLen + 1 that carries
   it to the line below.  The byte either side of the caret is asked for rather
   than ccol - 1 and ccol + 1 being handed over, because on a wide page those two
   land inside a letter and the caret would then have to be pulled back out of
   it. *)
PROCEDURE StepLeft (self: TextArea): INTEGER;
VAR c: INTEGER;
BEGIN
    c := -1;
    IF self.ccol > 0 THEN c := PrevByte(self, self.cline, self.ccol) END;
    RETURN c
END StepLeft;


PROCEDURE StepRight (self: TextArea): INTEGER;
VAR c, len: INTEGER;
BEGIN
    len := LineLen(self, self.cline);
    c := len + 1;
    IF self.ccol < len THEN c := NextByte(self, self.cline, self.ccol) END;
    RETURN c
END StepRight;


(* Word navigation for Ctrl+Left and Ctrl+Right.  A word is a maximal run of
   non-blanks.  Right leaves a word at its end, crosses whatever blanks follow it
   and lands on the first character of the next one - or at the end of the line
   when there is none, and on the next line when the caret is already there.
   Left lands on the first character of the word the caret is in, or of the
   previous word when it is already at a start, and on the previous line's end
   at the start of a line.  So the walk crosses lines at both ends and needs no
   special case at either.

   The two are exact inverses at a word start, which is the property worth
   having: Ctrl+Right and then Ctrl+Left comes back to where it was.  A caret
   left in the middle of a word does not return there - it cannot, since a word
   has one start and the walk moves between starts - and that is the same
   bargain every editor makes. *)

PROCEDURE WordRight (self: TextArea; keep: BOOLEAN);
VAR l, c, len: INTEGER;
BEGIN
    l := self.cline;
    len := LineLen(self, l);
    c := self.ccol;
    IF c >= len THEN
        IF l < self.nline - 1 THEN
            l := l + 1;
            c := 0
        END
    ELSE
        WHILE (c < len) & (GetCh(self, l, c) # " ") DO INC(c) END;
        WHILE (c < len) & (GetCh(self, l, c) = " ") DO INC(c) END
    END;
    SetCaret(self, l, c, keep);
    self.want := CellOf(self, self.cline, self.ccol)
END WordRight;


PROCEDURE WordLeft (self: TextArea; keep: BOOLEAN);
VAR l, c: INTEGER;
BEGIN
    l := self.cline;
    c := self.ccol;
    IF c <= 0 THEN
        IF l > 0 THEN
            l := l - 1;
            c := LineLen(self, l)
        END
    ELSE
        WHILE (c > 0) & (GetCh(self, l, c - 1) = " ") DO DEC(c) END;
        WHILE (c > 0) & (GetCh(self, l, c - 1) # " ") DO DEC(c) END
    END;
    SetCaret(self, l, c, keep);
    self.want := CellOf(self, self.cline, self.ccol)
END WordLeft;


(* The two things the text itself is changed by.  Both take a text offset and a
   count, both are one Move and one length change whatever the count is, and
   neither touches the offset table: a caller may make several of them - building
   a whole document out of a string, say - and reindexes once, when the text it
   was building is the text it meant.  rev moves with the bytes, which is what
   the history reads instead of comparing texts. *)

(* n bytes at srcAdr put into the text at at, and the text grown to hold them.
   The tail moves to the higher address from its end, so every byte is read
   before it is written, and the new bytes go in last, once there is nothing
   left to read. *)
PROCEDURE InsMem (self: TextArea; at, srcAdr, n: INTEGER);
VAR m: INTEGER;
BEGIN
    IF n > 0 THEN
        m := self.text.Length(self.text) - at;
        self.text.SetLength(self.text, self.text.Length(self.text) + n);
        self.text.Move(self.text, at + n, at, m);
        self.text.CopyMem(self.text, at, srcAdr, n);
        INC(self.rev)
    END
END InsMem;


(* n bytes taken out of the text at at.  The tail slides down over them and the
   text is shortened after the move and not before, so nothing the move reads
   has been cut off. *)
PROCEDURE DelMem (self: TextArea; at, n: INTEGER);
VAR m: INTEGER;
BEGIN
    IF n > 0 THEN
        m := self.text.Length(self.text) - at - n;
        self.text.Move(self.text, at, at + n, m);
        self.text.SetLength(self.text, self.text.Length(self.text) - n);
        INC(self.rev)
    END
END DelMem;


(* One character put into the text at at.  It stands between the two above and
   the line operations because a great deal of this file is one character: a
   keystroke, a break, the terminator of a new line. *)
PROCEDURE InsCh (self: TextArea; at: INTEGER; ch: CHAR);
VAR one: ARRAY 1 OF CHAR;
BEGIN
    one[0] := ch;
    InsMem(self, at, SYSTEM.ADR(one), 1)
END InsCh;


(* The line operations.  Each is one of the two primitives above and one
   reindex, and each reads the offsets it needs before it changes anything -
   which is why they are written one change apiece rather than as a sequence of
   smaller steps that would have to re-read a table that no longer describes
   the text. *)

(* Put src into line li at pos and answer how many characters went in.  All of
   them do: there is no line length left to fill, so nothing is dropped and the
   answer is the caller's own count.  It answers rather than just acting because
   InsertChar's caret arithmetic is the count it has just put in. *)
PROCEDURE InsertAt (self: TextArea; li, pos: INTEGER;
                    src: ARRAY OF CHAR): INTEGER;
VAR len, n: INTEGER;
BEGIN
    n := 0;
    IF (li >= 0) & (li < self.nline) THEN
        len := LineLen(self, li);
        IF pos > len THEN pos := len END;
        IF pos < 0 THEN pos := 0 END;
        n := Strings.Length(src);
        IF n > 0 THEN
            InsMem(self, At(self, li, pos), SYSTEM.ADR(src), n);
            Reindex(self)
        END
    END;
    RETURN n
END InsertAt;


(* Take n characters out of line li at pos.  The caret is not moved: every
   caller here manages it, and a primitive that moved it would be wrong for
   half of them. *)
PROCEDURE DeleteAt (self: TextArea; li, pos, n: INTEGER);
VAR len: INTEGER;
BEGIN
    IF (li >= 0) & (li < self.nline) THEN
        len := LineLen(self, li);
        IF pos < 0 THEN pos := 0 END;
        IF pos + n > len THEN n := len - pos END;
        IF (n > 0) & (pos < len) THEN
            DelMem(self, At(self, li, pos), n);
            Reindex(self)
        END
    END
END DeleteAt;


(* Drop line li, keeping at least one line.  The line goes with its own
   terminator, so everything after it moves up by the whole line. *)
PROCEDURE DropLine (self: TextArea; li: INTEGER);
BEGIN
    IF (self.nline > 1) & (li >= 0) & (li < self.nline) THEN
        DelMem(self, At(self, li, 0), LineLen(self, li) + 1);
        Reindex(self)
    END
END DropLine;


(* Append line a+1 to line a: the terminator that ends line a goes, and what
   followed it moves up against the line.  Nothing can fail to fit - the joint
   is one line however long the two were - so Backspace and Delete at a line
   end always act, and there is nothing to answer. *)
PROCEDURE Join (self: TextArea; a: INTEGER);
BEGIN
    IF (a >= 0) & (a < self.nline - 1) THEN
        DelMem(self, At(self, a, LineLen(self, a)), 1);
        Reindex(self)
    END
END Join;


(* Put a line break at pos: the head keeps the line and the tail becomes the
   next one.  One byte is added and the tail of the text moves; no text is lost
   and no line can be too long to hold the rest, so Enter works anywhere. *)
PROCEDURE SplitLine (self: TextArea; li, pos: INTEGER);
VAR len: INTEGER;
BEGIN
    IF (li >= 0) & (li < self.nline) THEN
        len := LineLen(self, li);
        IF pos > len THEN pos := len END;
        IF pos < 0 THEN pos := 0 END;
        InsCh(self, At(self, li, pos), SEP);
        Reindex(self)
    END
END SplitLine;


(* Delete the selection and leave the caret where it began, with nothing
   selected.

   A block that spans lines is one cut of the flat text: from the first end to
   the second.  The terminators in between go with the lines they ended - the
   one that ends the first line is inside the cut - and the one that ends the
   last line is not, so the two remaining pieces are one line by construction.
   The seam is not joined by a second operation and cannot be cut short by a
   length, which is what the old one-line-at-a-time version had to do when the
   two halves did not fit in one line between them. *)
PROCEDURE DeleteSel (self: TextArea);
VAR fl, fc, tl, tc, n: INTEGER;
BEGIN
    IF Selected(self) THEN
        SelOrder(self, fl, fc, tl, tc);
        n := At(self, tl, tc) - At(self, fl, fc);
        IF n > 0 THEN
            DelMem(self, At(self, fl, fc), n);
            Reindex(self)
        END;
        SetCaret(self, fl, fc, FALSE);
        self.want := CellOf(self, self.cline, self.ccol)
    END
END DeleteSel;


(* The selection as one string, the lines joined with SEP, put on the clipboard.
   Copying nothing copies nothing.

   A line's characters come out of the flat store by CopyTo - one move a block -
   and not a character at a time: the run is contiguous inside a block and the
   next block is not beside it, and that call is the one that knows it.

   The whole is built in Clipboard's own buffer size and cut at a LINE BOUNDARY,
   by testing the room before appending rather than after: Strings.Append fills
   to its limit and then answers FALSE, so a test made afterwards would leave
   half a line in the buffer and a paste of it would be a different text. *)
PROCEDURE Copy (self: TextArea);
VAR
    sep: ARRAY 2 OF CHAR;
    a, dst: ARRAY Clipboard.MAXCLIP OF CHAR;
    fl, fc, tl, tc, li, from, last, cnt, n, room: INTEGER;
    first: BOOLEAN;
    more: BOOLEAN;
BEGIN
    IF Selected(self) THEN
        SelOrder(self, fl, fc, tl, tc);
        sep[0] := SEP;
        sep[1] := 0X;
        dst[0] := 0X;
        first := TRUE;
        li := fl;
        WHILE li <= tl DO
            n := LineLen(self, li);
            from := 0;
            last := n;
            IF li = fl THEN from := fc END;
            IF li = tl THEN last := tc END;
            IF last > n THEN last := n END;
            IF from > last THEN from := last END;
            cnt := last - from;
            IF cnt > LEN(a) - 1 THEN
                (* a line longer than the clipboard is not copied at all, and
                   what came before it stands: a line cut in the middle would
                   come back as a different text, which is the one thing the
                   room test below exists to prevent.  A line is no longer
                   bounded by a length of its own, so this is reachable now and
                   was not before. *)
                li := tl + 1
            ELSE
                IF cnt > 0 THEN
                    self.text.CopyTo(self.text, At(self, li, from), cnt,
                                     SYSTEM.ADR(a))
                END;
                a[cnt] := 0X;
                room := Clipboard.MAXCLIP - 1 - Strings.Length(dst) - cnt;
                IF ~first THEN DEC(room) END;
                IF room < 0 THEN
                    li := tl + 1
                ELSE
                    IF ~first THEN
                        more := Strings.Append(sep, dst)
                    END;
                    more := Strings.Append(a, dst);
                    first := FALSE;
                    INC(li)
                END
            END
        END;
        (* Which half of Clipboard is used is the text page's business, and it
           is the same rule TuiFld follows.  A UTF-8 text page holds UTF-8
           already, so the run goes out through Put, which carries UTF-8 and is
           what puts a Russian line on the Windows clipboard as a Russian line;
           a byte page holds the screen's own bytes, and PutScreen is the pair
           that says what page they are in and turns them into UTF-8 on the way
           out.  The two are not interchangeable: PutScreen reads the run as
           866, so a Cyrillic line copied out of a UTF-8 area by it reaches the
           clipboard as the letters of its bytes - measured, twelve bytes of
           Привет became thirty-three bytes of somebody else's text. *)
        IF TuiPage.Text() = Charset.PageUtf8 THEN
            Clipboard.Put(dst)
        ELSE
            Clipboard.PutScreen(dst)
        END
    END
END Copy;


(* One character at the caret, over the selection when there is one.

   It is now the whole of what typing does: a line has no length that fills, so
   the branch that used to open a new line when the old one was full - and the
   one that declined when there was no line left to open - are both gone, and
   with them the only way a keystroke could be dropped. *)
(* The key gives a CODE POINT and not a byte.  On the UTF-8 page it is encoded,
   so a Russian letter goes into the store as the two bytes it is, and on a byte
   page as the one byte of it, which is what TuiPage.BytesOf answers - see it for
   why that and not Charset.Encode.  A character the page cannot spell is refused
   rather than written as its low byte, which is the point: CHR throws the top of
   the code point away, so an area that typed it would put a different letter
   than the one that was pressed.

   This is TuiFld.InsertCp, and the reason it is a copy of it rather than a call
   into it is that the two hold their text differently - a string there, this
   store here - and the conversion is three lines that both of them have to have
   anyway. *)
PROCEDURE InsertChar (self: TextArea; cp: INTEGER);
VAR one: ARRAY 8 OF CHAR; n, k: INTEGER;
BEGIN
    k := 0;
    one[0] := 0X;
    n := TuiPage.BytesOf(cp, one, k);
    IF n > 0 THEN
        IF Selected(self) THEN
            DeleteSel(self)
        END;
        one[n] := 0X;
        k := InsertAt(self, self.cline, self.ccol, one);
        SetCaret(self, self.cline, self.ccol + k, FALSE);
        self.want := CellOf(self, self.cline, self.ccol)
    END
END InsertChar;


(* The clipboard's text into the area, over the selection when there is one.
   Breaks in it become line breaks: the first piece replaces the selection on
   the line the caret is on and each later one begins a new line.  A CR LF pair
   is one break, since that is what the DOS clipboard's own text uses, and a
   lone CR or LF is one too.

   A piece goes in as one run and not a character at a time: with no line length
   to fill, typing the same characters and inserting them together give the same
   text, and one insert is one pass over the offset table instead of one a
   character.  A zero byte is dropped - it is the store's own terminator, so
   pasting one would end the line it landed in and put a break there that
   nothing typed could make. *)
PROCEDURE Paste (self: TextArea): BOOLEAN;
VAR
    buf, t: ARRAY Clipboard.MAXCLIP OF CHAR;
    i, total, pi, got: INTEGER;
    first, any: BOOLEAN;
BEGIN
    (* The page's own pair, as in Copy: a UTF-8 area wants the UTF-8 that is on
       the clipboard and not the screen's reading of it, which turns every
       Russian letter into a question mark. *)
    IF TuiPage.Text() = Charset.PageUtf8 THEN
        Clipboard.Get(buf)
    ELSE
        Clipboard.GetScreen(buf)
    END;
    total := Strings.Length(buf);
    any := FALSE;
    IF total > 0 THEN
        any := TRUE;
        DeleteSel(self);
        i := 0;
        first := TRUE;
        WHILE i < total DO
            pi := 0;
            t[0] := 0X;
            WHILE (i < total) & (buf[i] # 0AX) & (buf[i] # 0DX) DO
                IF (buf[i] # 0X) & (pi < LEN(t) - 1) THEN
                    t[pi] := buf[i];
                    INC(pi);
                    t[pi] := 0X
                END;
                INC(i)
            END;
            IF (i < total) & (buf[i] = 0DX) THEN INC(i) END;
            IF (i < total) & (buf[i] = 0AX) THEN INC(i) END;
            IF ~first THEN
                SplitLine(self, self.cline, self.ccol);
                SetCaret(self, self.cline + 1, 0, FALSE)
            END;
            (* the count it answers is not wanted here: a line has no length to
               fill, so every character of the piece went in, and pi is that
               count already *)
            got := InsertAt(self, self.cline, self.ccol, t);
            SetCaret(self, self.cline, self.ccol + pi, FALSE);
            first := FALSE
        END;
        self.want := CellOf(self, self.cline, self.ccol)
    END;
    RETURN any
END Paste;


(* Which line a text offset is in: the last table entry that is not past it.  A
   search answers with an offset and a caret is a (line, column) pair, so this
   is where the two meet. *)
PROCEDURE LineOf (self: TextArea; at: INTEGER): INTEGER;
VAR li: INTEGER;
BEGIN
    li := 0;
    WHILE (li < self.nline - 1) & (LineStart(self, li + 1) <= at) DO
        INC(li)
    END;
    RETURN li
END LineOf;


(* Whether the query stands at a text offset.  Only the bytes are compared, and
   the query's own length is the bound, so this reads past a line's terminator
   only when the query has got that far - which it never has, since a query
   cannot contain one.  The byte is read by address rather than through Get8:
   the two are the same byte, and this is a compare a candidate, where a call
   and a bounds test apiece would be the whole of the cost. *)
PROCEDURE MatchAt (self: TextArea; at, n: INTEGER): BOOLEAN;
VAR i: INTEGER; same: BOOLEAN; ch: CHAR;
BEGIN
    same := TRUE;
    i := 0;
    WHILE same & (i < n) DO
        SYSTEM.GET(self.text.Adr(self.text, at + i), ch);
        same := ch = self.fq[i];
        INC(i)
    END;
    RETURN same
END MatchAt;


(* Where the query first stands between at and upto, as a text offset or -1.
   The first character is looked for by FindByte and only where it stands are
   the rest of the query's bytes compared, so a one-character query is one
   instruction a block and a longer one costs a compare a candidate - and not a
   copy of every line it walks past, which is what the old search paid.

   upto is the range and not the line: a query cannot contain the terminator,
   as the find line takes only keys from 20H up, so a match can never run across
   a break - the break's own byte stops it.  That is what keeps the search
   line-scoped with no line awareness in it at all. *)
PROCEDURE ScanFrom (self: TextArea; at, upto, n: INTEGER): INTEGER;
VAR res, i: INTEGER; more: BOOLEAN;
BEGIN
    res := -1;
    i := at;
    more := TRUE;
    WHILE more & (res < 0) DO
        i := self.text.FindByte(self.text, i, ORD(self.fq[0]));
        IF (i < 0) OR (i + n > upto) THEN
            more := FALSE
        ELSIF MatchAt(self, i, n) THEN
            res := i
        ELSE
            INC(i)
        END
    END;
    RETURN res
END ScanFrom;


(* Search forward from the caret and wrap at the end, turning the first match
   into the selection: the other end at its start and the caret at its end, with
   keep set so the anchor just written survives.  Forward from the caret and not
   from the top, so a second Enter finds the next one rather than the same one
   again - one key, a different answer each time.

   Two scans and not a walk of the lines: forward from the caret to the end of
   the text, and then from the top to the caret, which is the same order the
   line-by-line search walked in - the lines above the caret and then the head
   of its own.

   An empty query is not searched: a search for nothing would stand everywhere. *)
PROCEDURE Find (self: TextArea);
VAR at, n, r: INTEGER; found: BOOLEAN;
BEGIN
    n := Strings.Length(self.fq);
    found := FALSE;
    at := -1;
    IF n > 0 THEN
        at := ScanFrom(self, At(self, self.cline, self.ccol),
                       self.text.Length(self.text), n);
        IF at < 0 THEN
            at := ScanFrom(self, 0, At(self, self.cline, self.ccol), n)
        END;
        found := at >= 0
    END;
    IF found THEN
        r := LineOf(self, at);
        self.aline := r;
        self.acol := at - LineStart(self, r);
        SetCaret(self, r, self.acol + n, TRUE);
        self.want := CellOf(self, self.cline, self.ccol);
        self.miss := FALSE
    ELSE
        self.miss := n > 0
    END
END Find;


(* Answers whether it acted, so the key can be declined when it did not: a
   Backspace nobody acted on must reach whatever is behind the widget.
   Backspace at the very top of the text is that case - there is nothing before
   the caret to take - and it declines for the same reason, rather than claiming
   a key it did nothing with. *)
PROCEDURE Backspace (self: TextArea): BOOLEAN;
VAR ok: BOOLEAN; k: INTEGER;
BEGIN
    ok := FALSE;
    IF Selected(self) THEN
        DeleteSel(self);
        ok := TRUE
    ELSIF self.ccol > 0 THEN
        (* One CHARACTER and not one byte: half a letter left behind is not a
           deletion anybody asked for. *)
        k := PrevByte(self, self.cline, self.ccol);
        DeleteAt(self, self.cline, k, self.ccol - k);
        SetCaret(self, self.cline, k, FALSE);
        ok := TRUE
    ELSIF self.cline > 0 THEN
        Join(self, self.cline - 1);
        SetCaret(self, self.cline - 1, LineLen(self, self.cline - 1), FALSE);
        ok := TRUE
    END;
    self.want := CellOf(self, self.cline, self.ccol);
    RETURN ok
END Backspace;


PROCEDURE Del (self: TextArea): BOOLEAN;
VAR ok: BOOLEAN; k: INTEGER;
BEGIN
    ok := FALSE;
    IF Selected(self) THEN
        DeleteSel(self);
        ok := TRUE
    ELSIF self.ccol < LineLen(self, self.cline) THEN
        k := NextByte(self, self.cline, self.ccol) - self.ccol;
        DeleteAt(self, self.cline, self.ccol, k);
        ok := TRUE
    ELSIF self.cline < self.nline - 1 THEN
        Join(self, self.cline);
        ok := TRUE
    END;
    self.want := CellOf(self, self.cline, self.ccol);
    RETURN ok
END Del;


(* Where a click lands, clamped rather than refused - which is what lets a drag
   run past the end of a line and past the end of the text. *)
PROCEDURE SetCell (self: TextArea; x, y: INTEGER; keep: BOOLEAN);
VAR li, col, row, rows: INTEGER;
BEGIN
    (* A press on the horizontal bar is not a press on a text row: it joins the
       last one, rather than scrolling the view to a line that was never under
       the pointer.  The bar is an indicator and not a control, so there is no
       hit test to write - only this clamp, which is what the vertical bar's
       absence of one costs nothing for, since a column clamp cannot scroll a
       view sideways past what is drawn. *)
    rows := Rows(self);
    row := y - self.y;
    IF row > rows - 1 THEN row := rows - 1 END;
    IF row < 0 THEN row := 0 END;
    li := self.top + row;
    IF li > self.nline - 1 THEN li := self.nline - 1 END;
    IF li < 0 THEN li := 0 END;
    (* x is a cell on the screen and the caret is a byte, so the click becomes a
       byte here and not before: col0 is a cell and what was clicked is a cell,
       and doing the arithmetic in bytes is what put the caret on the wrong
       letter the moment a name held one that took two of them. *)
    col := self.col0 + x - self.x;
    IF col < 0 THEN col := 0 END;
    col := ByteOf(self, li, col);
    IF col > LineLen(self, li) THEN col := LineLen(self, li) END;
    SetCaret(self, li, col, keep);
    self.want := CellOf(self, self.cline, self.ccol)
END SetCell;


(* The undo history, which is a list of whole-document states packed back to
   back in one array.

   A state is the text and nothing else: where the state's own array begins is
   the sum of the lengths of the states before it, so the directory is those
   lengths and there is no second thing to keep in step.  Dropping the oldest
   is a move of the states behind it, downwards, into the space the oldest
   occupied - the destination of each begins where the one before it ended and
   ends before the source of the next begins, so the moves can be made in
   place, oldest first, and nothing has to be copied aside.

   A step is pushed in exactly one place - the end of onEvent's common path, so
   no arm has to remember to do it - and only when the text actually differs
   from the state the history is standing on.  It is the text and not the caret
   that is compared, which is what keeps a run of arrow keys from becoming a
   run of undo steps: moving about is not an edit. *)

(* Where state k's text begins: the sum of the lengths before it, which is at
   most eight additions. *)
PROCEDURE HStart (self: TextArea; k: INTEGER): INTEGER;
VAR i, at: INTEGER;
BEGIN
    at := 0;
    FOR i := 0 TO k - 1 DO
        INC(at, self.snap[i].tlen)
    END;
    RETURN at
END HStart;


(* The live state into slot k.  The text is copied to where the lengths put it
   and the slot's own tlen is what later reads it back, so what lies past it is
   dead bytes rather than anything that has to be kept in step - which is also
   why the array is only ever grown here and never shortened: a slot rewritten
   shorter leaves a tail nobody reads. *)
PROCEDURE Save (self: TextArea; k: INTEGER);
VAR at: INTEGER;
BEGIN
    at := HStart(self, k);
    self.snap[k].tlen := self.text.Length(self.text);
    IF at + self.snap[k].tlen > self.hist.Length(self.hist) THEN
        self.hist.SetLength(self.hist, at + self.snap[k].tlen)
    END;
    IF self.snap[k].tlen > 0 THEN
        self.hist.Copy(self.hist, at, self.text, 0, self.snap[k].tlen)
    END;
    self.snap[k].rev := self.rev;
    self.snap[k].nline := self.nline;
    self.snap[k].cline := self.cline;
    self.snap[k].ccol := self.ccol;
    self.snap[k].aline := self.aline;
    self.snap[k].acol := self.acol;
    self.snap[k].top := self.top;
    self.snap[k].col0 := self.col0;
    self.snap[k].want := self.want
END Save;


(* The state in slot k made live again.  Its text goes back into the text array
   and the offset table is rebuilt from it rather than restored - the table is
   derived state and a pass is cheaper than storing eight more of them. *)
PROCEDURE Restore (self: TextArea; k: INTEGER);
VAR at, n: INTEGER;
BEGIN
    at := HStart(self, k);
    n := self.snap[k].tlen;
    self.text.SetLength(self.text, n);
    IF n > 0 THEN
        self.text.Copy(self.text, 0, self.hist, at, n)
    END;
    self.nline := self.snap[k].nline;
    self.cline := self.snap[k].cline;
    self.ccol := self.snap[k].ccol;
    self.aline := self.snap[k].aline;
    self.acol := self.snap[k].acol;
    self.top := self.snap[k].top;
    self.col0 := self.snap[k].col0;
    self.want := self.snap[k].want;
    self.rev := self.snap[k].rev;
    Reindex(self);
    EnsureTop(self);
    EnsureCol(self)
END Restore;


(* Drop the oldest state when the history is full, by moving every slot down
   one.  The lengths are read out first, because they are what says where each
   slot's text lies and the slots themselves are being overwritten as the move
   goes - and the move is made from the oldest end, so each destination ends
   before the source of the slot after it begins.

   Every source is the destination plus the length of the state being dropped:
   the pack closes the hole the oldest state leaves, and every state behind it
   moves up by exactly that much.  So the offset is one number and not a
   running sum, and it is the same for all of them. *)
PROCEDURE ShiftDown (self: TextArea);
VAR k, at, from, n: INTEGER; len: ARRAY UNDO OF INTEGER;
BEGIN
    FOR k := 0 TO UNDO - 1 DO
        len[k] := self.snap[k].tlen
    END;
    at := 0;
    FOR k := 1 TO UNDO - 1 DO
        from := at + len[0];
        n := len[k];
        IF n > 0 THEN
            self.hist.Move(self.hist, at, from, n)
        END;
        self.snap[k - 1] := self.snap[k];
        INC(at, n)
    END;
    self.snap[UNDO - 1].tlen := 0
END ShiftDown;


(* The one push site.  nhist is where a new state would go, so setting it to
   cur + 1 is what throws the redoable states away: an edit made after an undo
   forks the history, and the branch that was being replayed is gone. *)
PROCEDURE Push (self: TextArea);
BEGIN
    IF self.rev # self.snap[self.cur].rev THEN
        self.nhist := self.cur + 1;
        IF self.nhist = UNDO THEN
            ShiftDown(self);
            DEC(self.nhist)
        END;
        Save(self, self.nhist);
        INC(self.nhist);
        self.cur := self.nhist - 1
    END
END Push;


(* Whether Ctrl+Z and Ctrl+Y acted.  They answer rather than assume, because
   the arm sets hit from the answer: at either end of the history there is
   nothing to move to, and a key that did nothing has to reach whatever is
   behind the area. *)
PROCEDURE Undo (self: TextArea): BOOLEAN;
VAR acted: BOOLEAN;
BEGIN
    acted := self.cur > 0;
    IF acted THEN
        DEC(self.cur);
        Restore(self, self.cur)
    END;
    RETURN acted
END Undo;


PROCEDURE Redo (self: TextArea): BOOLEAN;
VAR acted: BOOLEAN;
BEGIN
    acted := self.cur < self.nhist - 1;
    IF acted THEN
        INC(self.cur);
        Restore(self, self.cur)
    END;
    RETURN acted
END Redo;


(* The find line is modal: it takes every key it is given, and every event that
   is not a key as well.

   The ctrl test comes first and it has to - Ctrl+A arrives with 001H where a
   letter's own code would be, so a printable test made first would append an
   "A" to the query and then go looking for it.  Being the first arm of an
   IF/ELSIF chain, the ctrl arm cannot fall through to the character arm
   either.

   Backspace edits the query and never the document, which is why the readOnly
   guards of the text keys have no counterpart here: looking for something does
   not change the text, and neither does saying what to look for.

   The character arm is also what keeps a terminator out of the query, which is
   the one thing the line-scoped search leans on: no query can hold a 0AX
   because Events.Char answers 0 for every key that made no character, and the
   arm asks it rather than e.key. *)
PROCEDURE FindKey (self: TextArea; VAR e: Events.Event): BOOLEAN;
VAR hit: BOOLEAN; n, m, p: INTEGER;
BEGIN
    hit := TRUE;
    IF e.kind = Events.KEYBOARD THEN
        IF e.ctrl THEN
            (* The key that opened it closes it, which is what makes the find
               line a mode rather than a place to get stuck in. *)
            IF Events.IsCtrl(e, Events.CTRL_F) THEN
                self.finding := FALSE;
                self.miss := FALSE;
                EnsureTop(self)
            ELSIF Events.IsCtrl(e, Events.CTRL_A) THEN
                Strings.Copy("", self.fq);
                self.miss := FALSE
            END
        ELSIF Events.IsKey(e, Events.K_ESC) THEN
            self.finding := FALSE;
            self.miss := FALSE;
            EnsureTop(self)
        ELSIF Events.IsKey(e, Events.K_ENTER) THEN
            Find(self)
        ELSIF Events.IsKey(e, Events.K_BACK) THEN
            (* One CHARACTER out of the query, for the same reason the
               document's own Backspace takes one: half a Russian letter left
               behind is not a query anybody typed. *)
            n := Strings.Length(self.fq);
            IF n > 0 THEN
                DEC(n);
                IF TuiPage.Text() = Charset.PageUtf8 THEN
                    WHILE (n > 0) & (ORD(self.fq[n]) >= 80H) &
                          (ORD(self.fq[n]) < 0C0H) DO
                        DEC(n)
                    END
                END;
                Strings.Delete(self.fq, n, Strings.Length(self.fq) - n);
                self.miss := FALSE
            END
        ELSE
            (* What the key made, asked once and in the page's own terms - see
               Events.Char, the one place that knows which half of the event
               holds it.  On a console the character arrives whole in e.ch and
               e.key is only its low byte, so a query built from e.key refuses
               the letters whose low byte is under 20H and admits the rest as
               whatever their low byte spells.

               The query is text like any other, so the character's CODE POINT
               is encoded into it and a Russian letter takes the two bytes it
               is.  CHR here would put a different letter in the query than the
               one that was typed - and then find it, which is worse than not
               finding anything.

               FINDLEN counts BYTES, so a query in Russian holds half as many
               letters as one in English.  That is the field's own size and it
               is left alone rather than doubled: the reserve is checked before
               anything is written, so a query that has run out declines the
               key instead of running off the end of the array. *)
            p := Events.Char(e);
            IF ~e.ctrl & ~e.alt & (p > 0) THEN
                n := Strings.Length(self.fq);
                m := 0;
                IF TuiPage.Text() = Charset.PageUtf8 THEN
                    IF n <= FINDLEN - 5 THEN
                        m := Charset.Encode(p, self.fq, n)
                    END
                ELSIF (p < 100H) & (n < FINDLEN - 1) THEN
                    self.fq[n] := CHR(p);
                    INC(n);
                    m := 1
                END;
                IF m > 0 THEN
                    self.fq[n] := 0X;
                    self.miss := FALSE
                END
            END
        END
    END;
    IF hit THEN
        e.kind := Events.NONE
    END;
    RETURN hit
END FindKey;


(* The text rows, the selection, the caret, the bar, and - while it is up - the
   find line, on the widget's own last row and in the area's own body pair, so
   it reads as a strip that can be typed into.  A failed search is drawn text rather than a
   status line: a widget cannot reach the application's status line and must
   not, and drawn text is what a dump shows. *)
PROCEDURE draw (self: TextArea; target: TuiCanv.Canvas);
VAR
    a, sa, ba, w, tw, rows, row, li, col, len, b, q, size, ofs: INTEGER;
    from, at, p, abs, caretCell, n: INTEGER;
    fl, fc, tl, tc: INTEGER;
    ch: TuiCanv.Char;              (* the character a cell is drawn with *)
    hasSel, sel, caretHere, selTail, hbar: BOOLEAN;
    findbuf: ARRAY FINDLEN + 24 OF CHAR;
    more: BOOLEAN;
BEGIN
    IF self.visible THEN
        a := TuiTheme.Attr(TuiTheme.TextArea);
        IF self.focused THEN
            sa := TuiTheme.Attr(TuiTheme.TextAreaSel)
        ELSE
            sa := TuiTheme.Attr(TuiTheme.TextAreaSelIdle)
        END;
        ba := TuiTheme.Attr(TuiTheme.TextAreaBar);
        w := self.width;
        rows := Rows(self);
        tw := TextW(self);
        hbar := HScrolled(self);
        hasSel := Selected(self);
        SelOrder(self, fl, fc, tl, tc);
        target.Fill(target, self.x, self.y, w, self.height, " ", a);
        FOR row := 0 TO rows - 1 DO
            li := self.top + row;
            IF li < self.nline THEN
                len := LineLen(self, li);
                (* from IS A CELL, abs IS A BYTE OF THE LINE and at is that byte
                   as an ADDRESS in the store, and the three are turned into one
                   another here instead of a byte count being used as a column
                   all the way across.  Two numbers are needed and not one: the
                   selection and the caret are line-relative bytes, because
                   that is what LineLen and every byte offset in this file have
                   always been, while CharAt and CharLen read the store by
                   address.  p is the cell on the screen, abs the byte in the
                   line, at the address of that byte, and the row advances by
                   one character and not by one of any of them. *)
                from := self.col0;
                abs := ByteOf(self, li, from);      (* clamped to the line's end *)
                at := At(self, li, abs);
                (* Where the caret's own cell is, asked once a row rather than
                   once a cell.  -1 is no caret on this row, which is what every
                   row but one gets and what a row with a selection gets too. *)
                caretCell := -1;
                IF (li = self.cline) & ~hasSel THEN
                    caretCell := CellOf(self, li, self.ccol)
                END;
                p := 0;
                WHILE (p < tw) & (abs < len) DO
                    ch := CharAt(self, at);
                    sel := FALSE;
                    IF hasSel THEN
                        sel := ((li > fl) OR ((li = fl) & (abs >= fc))) &
                               ((li < tl) OR ((li = tl) & (abs < tc)))
                    END;
                    caretHere := (li = self.cline) & (abs = self.ccol);
                    IF sel OR (caretHere & ~hasSel) THEN
                        b := sa
                    ELSE
                        b := a
                    END;
                    target.Put(target, self.x + p, self.y + row, ch, b);
                    n := CharLen(self, at);
                    INC(at, n);
                    INC(abs, n);
                    INC(p)
                END;
                (* Past the end of the line the cell is a blank, and the
                   selection is the same for every one of them: both tests that
                   mention the column are settled by the column being at or
                   past the line's end - fc is never past the end of the line
                   the selection starts in, nor tc past the end of the line it
                   ends in - so the row is asked once and not a cell at a time.
                   The column the two tests are made at is the line's own end;
                   a line wider than the view leaves no blank cell at all, and
                   then this is worked out and never used. *)
                selTail := hasSel &
                           (((li > fl) OR ((li = fl) & (len >= fc))) &
                            ((li < tl) OR ((li = tl) & (len < tc))));
                WHILE p < tw DO
                    IF selTail OR (caretCell = from + p) THEN
                        b := sa
                    ELSE
                        b := a
                    END;
                    target.Put(target, self.x + p, self.y + row, " ", b);
                    INC(p)
                END
            END
        END;
        IF Scrolled(self) THEN
            Thumb(self, size, ofs);
            FOR row := 0 TO rows - 1 DO
                IF (row >= ofs) & (row < ofs + size) THEN
                    target.Put(target, self.x + w - 1, self.y + row,
                               TuiCanv.BLOCK, ba)
                ELSE
                    target.Put(target, self.x + w - 1, self.y + row,
                               TuiCanv.SHADE_LIGHT, ba)
                END
            END
        END;
        (* The horizontal bar is the widget's own last row and runs its whole
           width: the vertical bar stops a row short of it, so the corner cell
           is left for this one, and filling it is what keeps the corner from
           being a hole in the frame. *)
        IF hbar THEN
            HThumb(self, size, ofs);
            row := self.height - 1;
            FOR col := 0 TO w - 1 DO
                IF (col >= ofs) & (col < ofs + size) THEN
                    target.Put(target, self.x + col, self.y + row,
                               TuiCanv.BLOCK, ba)
                ELSE
                    target.Put(target, self.x + col, self.y + row,
                               TuiCanv.SHADE_LIGHT, ba)
                END
            END
        END;
        (* The find line sits above the bar when there is one, since the bar's
           row is not the text's to give. *)
        IF self.finding THEN
            row := self.height - 1;
            IF hbar THEN DEC(row, BARROWS) END;
            Strings.Copy("Find: ", findbuf);
            more := Strings.Append(self.fq, findbuf);
            IF self.miss THEN
                more := Strings.Append("  (not found)", findbuf)
            END;
            target.Fill(target, self.x, self.y + row, w, 1, " ", a);
            col := 0;                            (* the byte of the buffer *)
            p := 0;                              (* and the cell of the row *)
            WHILE (p < tw) & (col < LEN(findbuf) - 1) & (findbuf[col] # 0X) DO
                target.Put(target, self.x + p, self.y + row,
                           BufChar(findbuf, col), a);
                INC(col, BufLen(findbuf, col));
                INC(p)
            END;
            (* The caret sits where the next character would go, so its cell is
               the width of what was typed into the query - the prompt and the
               query, and NOT the "  (not found)" tail a failed search appends
               behind them, which is drawn text and not something to type over.
               A query in Russian is twice as many bytes as cells, which is the
               whole reason this is BufCells and not Strings.Length. *)
            q := BufCells(findbuf, FINDPFX + Strings.Length(self.fq));
            IF q < tw THEN
                target.Put(target, self.x + q, self.y + row, " ", sa)
            END
        END
    END
END draw;


(* TuiRadio' shape and not TuiFld': hit starts false and only an arm that acted
   sets it, so a read-only area declines the keys it must not take instead of
   claiming them and doing nothing.  Which widget ends up with a key nobody
   took is the application's business, and it cannot decide that if the widget
   has already swallowed the event. *)
PROCEDURE onEvent (self: TextArea; VAR e: Events.Event): BOOLEAN;
VAR hit: BOOLEAN; fl, fc, tl, tc, p: INTEGER;
BEGIN
    hit := FALSE;
    IF self.finding THEN
        hit := FindKey(self, e)
    ELSIF e.kind = Events.KEYBOARD THEN
        IF self.focused THEN
            (* The two Ctrl+arrow arms stand before the plain ones on purpose:
               a Ctrl+Left carries the very same scan code as a Left and a
               character of zero, so the plain arm below would take it, and
               IsCtrlScan - which reads the flag and the scan code - is the only
               test that tells the two apart.  IsCtrl is for the letters, which
               do have a code of their own to be named by. *)
            IF Events.IsCtrlScan(e, Events.K_LEFT) THEN
                hit := TRUE;
                WordLeft(self, e.shift)
            ELSIF Events.IsCtrlScan(e, Events.K_RIGHT) THEN
                hit := TRUE;
                WordRight(self, e.shift)
            ELSIF Events.IsKey(e, Events.K_LEFT) THEN
                hit := TRUE;
                IF ~e.shift & Selected(self) THEN
                    SelOrder(self, fl, fc, tl, tc);
                    SetCaret(self, fl, fc, FALSE);
                    self.want := CellOf(self, self.cline, self.ccol)
                ELSE
                    MoveCol(self, StepLeft(self), e.shift)
                END
            ELSIF Events.IsKey(e, Events.K_RIGHT) THEN
                hit := TRUE;
                IF ~e.shift & Selected(self) THEN
                    SelOrder(self, fl, fc, tl, tc);
                    SetCaret(self, tl, tc, FALSE);
                    self.want := CellOf(self, self.cline, self.ccol)
                ELSE
                    MoveCol(self, StepRight(self), e.shift)
                END
            ELSIF Events.IsKey(e, Events.K_UP) THEN
                hit := TRUE;
                MoveLine(self, -1, e.shift)
            ELSIF Events.IsKey(e, Events.K_DOWN) THEN
                hit := TRUE;
                MoveLine(self, 1, e.shift)
            ELSIF Events.IsKey(e, Events.K_HOME) THEN
                hit := TRUE;
                SetCaret(self, self.cline, 0, e.shift);
                self.want := 0
            ELSIF Events.IsKey(e, Events.K_END) THEN
                hit := TRUE;
                SetCaret(self, self.cline, LineLen(self, self.cline), e.shift);
                self.want := CellOf(self, self.cline, self.ccol)
            ELSIF Events.IsKey(e, Events.K_PGUP) THEN
                hit := TRUE;
                MoveLine(self, -Rows(self), e.shift)
            ELSIF Events.IsKey(e, Events.K_PGDN) THEN
                hit := TRUE;
                MoveLine(self, Rows(self), e.shift)
            ELSIF Events.IsCtrl(e, Events.CTRL_A) THEN
                hit := TRUE;
                self.aline := 0;
                self.acol := 0;
                SetCaret(self, self.nline - 1, LineLen(self, self.nline - 1),
                         TRUE);
                self.want := CellOf(self, self.cline, self.ccol)
            ELSIF Events.IsCtrl(e, Events.CTRL_F) THEN
                hit := TRUE;
                self.finding := TRUE;
                self.fq[0] := 0X;
                self.miss := FALSE;
                EnsureTop(self)
            ELSIF Events.IsCtrl(e, Events.CTRL_C) THEN
                hit := TRUE;
                Copy(self)
            ELSIF ~self.readOnly & Events.IsKey(e, Events.K_BACK) THEN
                hit := Backspace(self)
            ELSIF ~self.readOnly & Events.IsKey(e, Events.K_DEL) THEN
                hit := Del(self)
            ELSIF ~self.readOnly & Events.IsKey(e, Events.K_ENTER) THEN
                IF Selected(self) THEN
                    DeleteSel(self)
                END;
                SplitLine(self, self.cline, self.ccol);
                SetCaret(self, self.cline + 1, 0, FALSE);
                self.want := 0;
                hit := TRUE
            ELSIF ~self.readOnly & Events.IsCtrl(e, Events.CTRL_X) THEN
                hit := TRUE;
                IF Selected(self) THEN
                    Copy(self);
                    DeleteSel(self)
                END
            ELSIF ~self.readOnly & Events.IsCtrl(e, Events.CTRL_V) THEN
                hit := Paste(self)
            ELSIF ~self.readOnly & Events.IsCtrl(e, Events.CTRL_Z) THEN
                hit := Undo(self)
            ELSIF ~self.readOnly & Events.IsCtrl(e, Events.CTRL_Y) THEN
                hit := Redo(self)
            ELSE
                (* What the key made, asked once and in the page's own terms -
                   see Events.Char, the one place that knows which half of the
                   event holds it.  On a console the character arrives whole in
                   e.ch and e.key is only its low byte, so a test of e.key
                   refuses the letters whose low byte is under 20H (A to P of
                   the Russian block) and admits the rest as whatever their low
                   byte spells - я goes in as an O.  A byte page is unaffected:
                   there the byte IS the character, and Events.Char hands back
                   that byte.

                   The code point and not CHR of it, so a Russian letter takes
                   the two bytes it is; InsertCp refuses a character the page
                   cannot spell rather than writing its low byte. *)
                p := Events.Char(e);
                IF ~self.readOnly & ~e.ctrl & ~e.alt & (p > 0) THEN
                    hit := TRUE;
                    InsertChar(self, p)
                END
            END
        END
    ELSIF e.kind = Events.MOUSE THEN
        (* the drag latch holds the pointer until the button comes back up, and
           follows it anywhere - on the widget or off it - so a run can be
           dragged past the end of a line.  There is no focus test: a click is
           the choice, and choosing a block is not modifying it. *)
        IF self.dragging THEN
            IF Events.IsClick(e) THEN
                hit := TRUE;
                SetCell(self, e.x, e.y, TRUE)
            ELSE
                self.dragging := FALSE
            END
        ELSIF Events.IsPress(e) & TuiWidg.Inside(self, e.x, e.y) THEN
            hit := TRUE;
            SetCell(self, e.x, e.y, FALSE);
            self.dragging := TRUE
        END
    END;
    (* The one push site, on the way out of every arm, so no arm has to know the
       history exists.  Push decides for itself whether anything changed, which
       is also why it can be called when nothing was hit at all: a read-only
       area declined every arm, and a navigation key changed no text. *)
    Push(self);
    IF hit THEN
        e.kind := Events.NONE
    END;
    RETURN hit
END onEvent;


(* The two ways in for a router that does not know what kind of widget this is:
   take an event, and take the keyboard on or off.  Both are declared for
   TuiWidg.Widget, which is what a window's ring holds, and both narrow back to
   an area before doing anything - the guard on the type, the cast for the
   fields.

   focused is what draws the caret, and the caret is the whole of what the walk
   is for here: the arrows are the area's own keys, and a plain Left or Right
   reaches it now that the ring is walked with Tab and nothing else. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR t: TextArea;
BEGIN
    IF w IS TextArea THEN
        t := w(TextArea);
        t.focused := on
    END
END Take;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR t: TextArea; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS TextArea THEN
        t := w(TextArea);
        r := t.onEvent(t, e)
    END;
    RETURN r
END Handle;


(* Split s on its breaks and make one line of each piece.  Works in either
   mode: the flag restricts the user, not the owner, and an owner that could
   not fill a read-only area could never show anything in one.

   The text is built first and the table made from it once at the end, which is
   why the characters go in through the primitive that does not reindex: a pass
   a character would be a pass a character over the whole document.  Nothing is
   dropped any more - the pieces are as long as they are - and a text longer
   than the store can hold is the store's own limit and not a line's. *)
PROCEDURE SetText (self: TextArea; s: ARRAY OF CHAR);
VAR i, n: INTEGER; ch: CHAR;
BEGIN
    (* One empty line, and its terminator is SEP and not a zero: the whole of
       what follows hangs on that byte, since a character is put in before the
       last byte of the text and a break after it.  A zero here leaves a zero
       inside the text with the first break, and every reader of it - the table,
       the lines - then ends the document at that point. *)
    self.text.SetLength(self.text, 1);
    self.text.Put8(self.text, 0, ORD(SEP));
    n := Strings.Length(s);
    i := 0;
    WHILE i < n DO
        ch := s[i];
        IF (ch = 0AX) OR (ch = 0DX) THEN
            (* A break adds a terminator at the end: the line just finished has
               its own already, and the one added ends the empty line after it *)
            InsCh(self, self.text.Length(self.text), SEP);
            IF ch = 0DX THEN INC(i) END;
            IF (i < n) & (s[i] = 0AX) THEN INC(i) END
        ELSE
            InsCh(self, self.text.Length(self.text) - 1, ch);
            INC(i)
        END
    END;
    INC(self.rev);
    Reindex(self);
    self.cline := 0;
    self.ccol := 0;
    self.want := 0;
    self.aline := 0;
    self.acol := 0;
    self.top := 0;
    self.col0 := 0;
    self.finding := FALSE;
    self.miss := FALSE;
    (* What the owner puts in is the baseline, not an edit: the history starts
       again here, so Ctrl+Z after a fill cannot empty the area the owner
       just filled. *)
    self.nhist := 1;
    self.cur := 0;
    Save(self, 0)
END SetText;


(* One line of the text.  The copy is by address and the length is the line's
   own, computed from the two table entries - not GetStr, which is the store's
   asciiz reader and would run past this line's end and into the next, since the
   byte that ends a line here is 0AX and the text need hold no zero at all. *)
PROCEDURE GetLine (self: TextArea; i: INTEGER; VAR dst: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
    IF (i >= 0) & (i < self.nline) THEN
        n := LineLen(self, i);
        IF n > LEN(dst) - 1 THEN n := LEN(dst) - 1 END;
        IF n < 0 THEN n := 0 END;
        IF n > 0 THEN
            self.text.CopyTo(self.text, LineStart(self, i), n, SYSTEM.ADR(dst))
        END;
        dst[n] := 0X
    ELSE
        Strings.Copy("", dst)
    END
END GetLine;


(* One line added at the end, and the index it went to.  There is no -1 any
   more: the store grows, so a caller that adds a line gets a line - and the
   one thing a caller could do nothing about is gone.

   The history is pushed here, and this is the second push site - the first is
   the end of onEvent's common path.  The rule the two of them keep is that the
   history is never behind the live text: an edit made by an event is caught
   where every event is caught, and an edit made by the application through this
   routine - which no event will ever see - has to be caught here.  Without it
   the next edit folded the added line into its own step, and one Ctrl+Z then
   took back the application's lines together with the user's edit. *)
PROCEDURE AddLine (self: TextArea; s: ARRAY OF CHAR): INTEGER;
VAR k, n: INTEGER;
BEGIN
    k := self.nline;
    n := Strings.Length(s);
    (* The terminator of the new line first, then its text: the line that was
       last keeps its own terminator and the new one begins empty after it. *)
    InsCh(self, self.text.Length(self.text), SEP);
    IF n > 0 THEN
        InsMem(self, self.text.Length(self.text) - 1, SYSTEM.ADR(s), n)
    END;
    Reindex(self);
    Push(self);
    RETURN k
END AddLine;


(* The caret to (l, c) with the selection left running from where it was, which
   is what the name says and what the anchor is for.  Collapsing the anchor -
   which is what this did - made the routine a second spelling of a caret move
   and left no way at all to select from an application. *)
PROCEDURE Select (self: TextArea; l, c: INTEGER);
BEGIN
    SetCaret(self, l, c, TRUE);
    self.want := CellOf(self, self.cline, self.ccol)
END Select;


PROCEDURE SetReadOnly (self: TextArea; flag: BOOLEAN);
BEGIN
    self.readOnly := flag
END SetReadOnly;


PROCEDURE SetPos (self: TextArea; x, y: INTEGER);
BEGIN
    self.x := x;
    self.y := y
END SetPos;


(* Give the area back.  The text, its offset table and the undo history are
   three arrays of the heap, so each is given back before the record is.

   It takes `Oberon.Object` and guards down because it is what goes into the
   inherited `Done` field, whose declared type is `PROCEDURE (self: Object)`.
   The clearing of the three fields is kept: a destructor cannot be called
   twice, but a caller that reaches this through the field of a record it is
   still holding should find nothing to free rather than a dangling one. *)
PROCEDURE DoneTextArea (self: Oberon.Object);
VAR t: TextArea;
BEGIN
    t := self(TextArea);
    IF t.text # NIL THEN
        t.text.Done(t.text);
        t.text := NIL
    END;
    IF t.offs # NIL THEN
        t.offs.Done(t.offs);
        t.offs := NIL
    END;
    IF t.hist # NIL THEN
        t.hist.Done(t.hist);
        t.hist := NIL
    END;
    DISPOSE(t)
END DoneTextArea;


(* Where it draws itself, for a window that paints what it owns. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR t: TextArea;
BEGIN
    IF w IS TextArea THEN
        t := w(TextArea);
        t.draw(t, target)
    END
END Paint;


(* An area of the window host, which takes it from here: it is painted with
   everything else that window owns and given back when the window is.  A host of
   NIL is an area nobody owns but its maker - a dialog's - and it is then up to
   that maker to place it, paint it and free it, as before. *)
PROCEDURE Create* (x, y, w, h: INTEGER; readOnly: BOOLEAN;
                   host: TuiWin.Window): TextArea;
VAR t: TextArea;
BEGIN
    ASSERT((w > 0) & (h > 0));
    NEW(t);
    t.x := x;
    t.y := y;
    t.width := w;
    t.height := h;
    t.visible := TRUE;
    t.focused := FALSE;
    t.canvas := NIL;
    t.text := ByteArr.Create(1);
    t.text.Put8(t.text, 0, ORD(SEP));   (* one empty line, terminated *)
    t.offs := ByteArr.Create(8);
    t.hist := ByteArr.Create(0);
    t.nline := 1;
    t.cline := 0;
    t.ccol := 0;
    t.want := 0;
    t.aline := 0;
    t.acol := 0;
    t.top := 0;
    t.col0 := 0;
    t.readOnly := readOnly;
    t.finding := FALSE;
    t.fq[0] := 0X;
    t.miss := FALSE;
    t.dragging := FALSE;
    t.rev := 0;
    t.nhist := 1;
    t.cur := 0;
    Reindex(t);
    Save(t, 0);
    t.lastCmd := 0;
    t.host := host;
    t.draw := draw;
    t.onEvent := onEvent;
    t.handler := Handle;
    t.taker := Take;
    t.painter := Paint;
    t.onCommand := NIL;                 (* an area fires no ids: the owner reads
                                           its text when it wants to *)
    t.SetText := SetText;
    t.GetLine := GetLine;
    t.AddLine := AddLine;
    t.Select := Select;
    t.SetReadOnly := SetReadOnly;
    t.SetPos := SetPos;
    t.Done := DoneTextArea;
    TuiWin.Own(host, t);
    RETURN t
END Create;

END TuiText.
