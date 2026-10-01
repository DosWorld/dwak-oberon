MODULE TuiHelp;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A window showing one article of a QuickHelp database.

   TuiHelp.Open(file, topic, page) puts an article on the desk, in a window of
   its own: not a modal one, and not one the application has to look after.  The
   window is a document - the box on its title row, Alt+F4 and Esc all close
   it, it is moved and resized like any other window of the desk, and the
   article is laid out again into whatever room the window has.  Any number of
   them can be up at once and each one has its own article, its own scroll
   position, its own current link, its own selection and its own history of the
   articles it came through.

   `topic` is an article's name, a context name, or a run of words to search
   for.  An empty one, and one that names nothing, both open the database's
   first article - so a caller who only has a file name gets the beginning of
   the help and not an error.  A file that cannot be read is not an article and
   cannot be shown, so that one is reported the way a failure is reported on
   this desk: a modal box with the file's name in it, which the user answers
   and the application hears nothing about.

   `page` is the code page the file's bytes are in, and it is not optional
   because there is no way to read it off the bytes.  A `.hlp` holds single
   bytes and no statement of what they mean, and the two pages the QuickHelp
   tools here write - 437 by default, 866 when `-cp` asks for it - agree only
   below 80H.  `Charset.Page437` is therefore what a caller who knows nothing
   about the file should say, because it is the page the format was written in
   and the page every database in this tree is in except the ones a converter
   was told to write otherwise.  Saying nothing and hoping is what the page
   parameter replaces: the wrong page does not fail, it draws the wrong
   letters, which is the one kind of mistake a reader has no way to notice.

   The window is READ ONLY, in the strongest sense the word has here.  Nothing
   a user can do to it changes a byte of the article: no key that edits, no
   paste, and no gesture that writes.  The caret below is a place to read from,
   not a place to write at, and there is no key that puts a character in it.
   What the user can do is look, move, and take a copy out - and a copy is the
   only thing that ever leaves the window.

   What is drawn is the database's own text.  Its links are drawn where the
   database put them, walked with Tab and Shift+Tab, and followed with Enter or
   with a click; the link the window is on is drawn in the window's own link
   pair, and the arrows the format frames a link with are part of the text and
   are drawn with it.  Its bold, italic and underlined runs are drawn
   differently from the text around them; see StyleAttr for where the three
   come from and which of them this window's pair can tell apart.  Its lines
   are scrolled by the two bars at the right and the bottom of the window, and
   by the keys below.  A run of the article is selected with the mouse or with
   the keyboard and copied to the clipboard with Ctrl+C.

   The window draws on colours of its own and takes none from the theme: the
   page is black, the caret on it is a white block, and a theme the reader
   switches to repaints the desk around this window and not the article in it.
   The pairs are in the CONST section; the reason they are here and not in
   TuiTheme is argued there.

   The keys are these:

     arrows                move the caret a cell or a line, and the view with
                           it; a link the caret lands on is lit
     PgUp, PgDn            move it a screen less one line
     Home, End             the ends of the line it is on
     Ctrl+Home, Ctrl+End   the ends of the article
     Shift+ any of those   the same move, growing the selection instead of
                           replacing it
     Ctrl+A                the whole article
     Ctrl+C, Ctrl+X        the selection, to the clipboard
     Tab, Shift+Tab        the next and the previous link, which the view follows
     Enter                 the link the window is on - the lit one
     Backspace             the article the window came from
     Esc                   close the window

   Ctrl+X copies and does not cut, which is worth saying because the muscle
   memory that reaches for it expects a cut.  A viewer that cannot write cannot
   cut - there is nothing for a cut to leave behind and nothing to paste back
   into - so the key is not refused and not ignored; it is the copy it can
   honestly be, and the article is the same afterwards as it was before.

   Tab and the arrows are two ways of walking the same page for two different
   purposes - one to follow what the writer pointed at, one to read and select
   what the writer wrote - and they are coupled in one direction only.  Tab
   walks the links and leaves the caret where it was, so a reader can visit
   every link of an article without losing their place in its text.  The arrows
   move the caret, and a caret that lands on a link makes that link the window's
   one, so the run under the caret is lit exactly as it is when the mouse passes
   over it; a caret that lands on ordinary text leaves the link alone, and the
   one the reader was last on stays lit.  This is why the caret wins the cell it
   stands on: the link it is on is drawn around it, and the reader can see both
   where the arrows are and what they are pointing at.

   Four marks can stand on one cell, and the order they win in is the order
   they are worth to a reader:

     the selection   whenever there is one - it is what Ctrl+C is about to
                     take, so it is the one mark that must not be hidden
     the caret       a white block on the cell the arrows have reached.  It
                     wins over a link, because a reader who cannot see where
                     the arrows have got to has lost the answer to "where am
                     I"; a link is a whole run of cells and gives up one of
                     them without being any harder to see
     the link        the run the window is on - from Tab, from a click, or
                     from a caret that has been arrowed onto it
     the body        everything else, with the format's three styles over it

   Only a window that has the keyboard draws a caret.  A caret says "the keys
   come here", and a window the keys are not going to would be saying
   something untrue.

   Three things are worth stating plainly, because each is a decision and not a
   property of the format:

   - The file is not held open.  QHReader reads a database whole and closes the
     handle before it parses it - the format addresses its parts by offset into
     the image and none of them can be reached without all of it - so there is
     nothing to keep open.  What is held is one decoded image of the file, in
     memory, and it is held ONCE for every window showing that file: `dbs`
     below is a registry of four, a window takes a reference when it opens an
     article and gives it back when it closes, and the image goes back to the
     allocator when the last window on it does.  Ten windows on one file are
     one image of it.  A caller who cannot pay for the image at all should not
     open a window on the file; there is no way to read this format a piece at
     a time, and inventing one is a change to QHReader and not to this module.

   - An article is decoded once, when the window opens it, into the window's
     own byte array, and again when the window moves to another article.
     Nothing is decoded per frame: a frame walks the records of the article
     already in hand and touches no compressed text at all.  A window therefore
     costs what the article it shows costs, and not what the database costs.

   - A window that has been closed is kept and used again rather than made
     afresh.  The desk never reclaims a slot - Tui.CreateWindow has no way to
     take a window off it - so a session that opened an article per link would
     run out of desk; a closed help window holds nothing but its own record,
     because the article and the image behind it were given back the moment it
     closed, and it is exactly the thing to put the next article in.
*)

IMPORT SYSTEM, Strings, ByteArr, Arrays, Charset, Events, TuiCanv, TuiPage,
       TuiWidg, TuiWin, Tui, TuiDlg, Clipboard, QHReader, Oberon;

CONST

    (* The images held at once, one per distinct file.  Four is what a desk can
       plausibly want: the application's own help, a second one, and room to
       look at both again after a detour.  A fifth distinct file is read into a
       fifth image - the registry is what it costs, not what may be read - and
       a window already showing one of the four holds its own reference to it
       and keeps it alive whatever the registry does. *)
    MAXDB = 4;

    (* The windows this module keeps track of, for the two things it does with
       them: reuse one that was closed, and find the one a close is about.  It
       is room for this module's bookkeeping and not a bound on the desk - a
       help window wants most of the screen, and a desk of thirty-two holds far
       fewer of them.  A window made when this is full is an ordinary window
       like any other; it is only the reuse that is lost. *)
    MAXWINS = 8;

    MAXHIST = 16;                       (* how far back Backspace walks *)
    TITLEMAX = 128;                     (* as much of a name as the title gets *)
    PATHSIZE = 260;                     (* ... and of a file name as we keep it *)
    STYLES = 256;                       (* the styles array of a line *)

    (* The byte map of one line: one entry per cell and one past the last of
       them.  A cell's bytes are the ones from its own entry up to the next, so
       a line of n cells is described by n + 1 entries and the last of them is
       the sentinel saying where the line's text ends.

       One entry more than STYLES is not symmetry for its own sake.  A line
       record counts its text in a BYTE, so the format allows 254 bytes at the
       very most (QHReader.MAX_LINE has the reasoning) and a line of 254
       one-byte cells is the longest that can exist - STYLES would have held
       the map of any such line.  The extra entry costs four bytes on a 32-bit
       target and makes the sentinel unarguable rather than argued. *)
    CELLMAX = STYLES + 1;

    (* The two bars, one cell each: the vertical one down the last column, the
       horizontal one along the last row and into the corner, which belongs to
       it.  The theme's own note about the corner - TuiTheme.TextAreaBar has it
       - says the corner is the horizontal bar's last cell, and this is that. *)
    TRACK = 1;

    (* The colours this window draws in, and the reason they are here and not
       taken from TuiTheme.

       Every other widget of this framework is a part of a form and wears the
       application's colours; a theme is the application saying what those are,
       and a switch repaints the lot.  This window is not a part of a form.  It
       is a page being read - the one thing on the desk that came from outside
       the application, written by somebody else, in a format that says nothing
       about colour - and the reader asked for it plainly: the background
       black, and a caret that can be seen on it.

       A pair taken from the theme cannot give that.  TuiTheme's default area
       is White on Blue and its second is Black on White, so a caret white
       enough to read on the first is the whole of the body on the second, and
       a background forced black under the second's black foreground would draw
       nothing at all.  These five pairs are therefore the window's own and
       stay put across a theme switch, which is also what a page ought to do.

       Reading them: fg is the bright end and bg the dark end of each pair.

         BODY    a light grey page - the DOS text colour, and the one a white
                 block shows against
         CARET   the body turned round, which is a white block with the
                 character still legible in it
         SEL     the selection, and the link the window is on, which the theme
                 would have drawn in its own selection pair
         SELIDLE the same when the window has not the keyboard: quieter, so a
                 reader can see at a glance which of several help windows the
                 keys are going to
         BAR     the two scrollbars, whose blocks are the body's own colour on
                 the same black

       What this pair cannot tell apart is worth saying, because the format has
       three styles and a cell has two colours.  StyleAttr derives bold, italic
       and underline from the body's pair, and on a light grey on black it has
       this much room: bold and italic both come out as the bright end, so a
       bold run and an italic run look alike, and underline comes out as the
       body turned round, which is the selection's own pair.  An underline
       under a selection is therefore not visible as an underline.  Underline
       is the rarest of the three in the databases this reads and the other two
       are always brighter than the text around them, which is the whole of
       what a reader asks of formatting; the alternative - keeping the theme's
       pair and losing the black page - was not what was asked for. *)
    BODY_FG = TuiCanv.LightGray;
    BODY_BG = TuiCanv.Black;
    LINK_FG = TuiCanv.Yellow;
    LINK_BG = TuiCanv.Black;
    CARET_FG = TuiCanv.Black;
    CARET_BG = TuiCanv.White;
    SEL_FG = TuiCanv.Black;
    SEL_BG = TuiCanv.LightGray;
    SELIDLE_FG = TuiCanv.Black;
    SELIDLE_BG = TuiCanv.DarkGray;
    BAR_FG = TuiCanv.LightGray;
    BAR_BG = TuiCanv.Black;

    (* What a page key is worth, in lines: a screen less one, so that a reader
       can see where the last screen ended. *)
    OVERLAP = 1;

    (* The line break a copied selection is joined with.  It is two characters
       and not the one a line of the article is ended by, because the
       destination is the system clipboard and CR LF is what the clipboard's
       own convention says a line break is; a single-line field of this
       framework copies a single line and has no separator to choose. *)
    CR = 0DX;
    LF = 0AX;

    (* The id the error box's one button fires.  It is this module's and not
       the application's: the box is answered by the desk and its id travels to
       the application like any other command, which is a command it has no
       case for and does nothing about. *)
    OKID = 1;

    (* TuiDlg' own message line, which is the widest error text that fits. *)
    MSGLEN = 44;


TYPE

    (* One decoded database, shared by every window showing it. *)
    Db = POINTER TO DbDesc;
    DbDesc = RECORD
        r:    QHReader.Reader;
        path: ARRAY PATHSIZE OF CHAR;   (* ... and the name it was opened by *)
        page: INTEGER;                  (* the code page those bytes are in *)
        uses: INTEGER                   (* how many windows are on it *)
    END;

    (* One window: the database it shows, the article on show, and everything
       that article is drawn, walked and selected with.  All of it is private -
       a caller opens an article and closes a window, and there is nothing
       between the two that it has any business in. *)
    Win = POINTER TO WinDesc;
    WinDesc = RECORD (TuiWidg.WidgetDesc)
        db:     Db;                     (* the image this window is on *)
        host:   TuiWin.Window;
        topic:  INTEGER;                (* the article on show *)
        name:   ARRAY TITLEMAX OF CHAR; (* what it is called, for the title *)

        raw:    ByteArr.ByteArray;      (* that article, decoded, whole *)
        nraw:   INTEGER;
        index:  Arrays.List;            (* where each drawn line begins in it *)
        nline:  INTEGER;                (* how many drawn lines there are *)
        maxw:   INTEGER;                (* the widest of them, in cells *)

        cw, ch: INTEGER;                (* the room the body has now *)
        ox, oy: INTEGER;                (* what it is scrolled to *)

        cur:    INTEGER;                (* the line the current link is on, or -1 *)
        curl:   INTEGER;                (* ... and which link of that line *)
        nlink:  INTEGER;                (* how many links the loaded line has *)
        links:  QHReader.Links;
        styles: QHReader.Styles;

        (* The loaded line as the reader sees it, which is NOT the same thing
           as the loaded line as the file holds it.

           A cell of this window is one character, and a CHARACTER IS NOT
           ALWAYS ONE BYTE.  On the three pages that were here before
           Charset.PageUtf8 it was - 437, 866 and Unicode-as-Latin-1 all spend
           one byte on one character - and the two could be, and were, the same
           number: a column of the window was a byte offset into the line, and
           every array in this record was indexed by it.  On UTF-8 they are not
           the same number, and the whole of this round is the two being told
           apart.

           So a loaded line is held twice over.  `cells` is it as code points,
           one per cell, which is what a canvas cell holds and what the
           clipboard's UTF-8 is made from; `cellByte` is where each cell begins
           in the line's bytes, with one entry past the last cell holding the
           line's length, so that a cell's bytes are cellByte[c] up to
           cellByte[c + 1].  `ncell` is how many cells there are.

           `styles` and `links` come back from QHReader in BYTE columns - the
           file writes them that way and the format has no other way to write
           them - and are turned into CELL columns as the line is read, which
           is what every reader above this point wants.  That turn is the
           identity on a page of one byte to a character, and it is why no
           drawing, no link and no selection moved when this arrived. *)
        cells:  ARRAY STYLES OF INTEGER;
        cellByte: ARRAY CELLMAX OF INTEGER;
        ncell:  INTEGER;                (* how many cells the loaded line has *)

        (* The selection, and the caret it grows from.  The anchor is where the
           selection was begun and does not move while it is being made; the
           caret is the end that moves.  sel says an anchor is set at all -
           which is not the same as there being a selection, since a press sets
           both to one cell and selects nothing until the caret leaves it. *)
        caretL, caretC: INTEGER;
        anchL, anchC:   INTEGER;
        sel:      BOOLEAN;
        wantC:    INTEGER;              (* the column the caret wants when the
                                           line it lands on is too short - what
                                           makes Shift+Down past a short line
                                           and back up again keep its column *)
        dragging: BOOLEAN;              (* a press that may become a selection *)
        plink:    INTEGER;              (* the link the press landed on, or -1 *)
        plinkL:   INTEGER;              (* ... and the line it was on *)

        hist:   ARRAY MAXHIST OF INTEGER;
        nhist:  INTEGER;

        bar:    INTEGER;                (* which thumb a drag holds: 0, 1, 2 *)
        grabD:  INTEGER                 (* ... and how far along it it took hold *)
    END;


VAR
    dbs:  ARRAY MAXDB OF Db;
    wins: ARRAY MAXWINS OF Win;
    nwin: INTEGER;
    err:  TuiDlg.Dialog;               (* the box a bad file name raises *)


(* --- the images ----------------------------------------------------------- *)

(* Take a reference to the image of `path` read in page `page`, reading it if
   no window holds one yet, and answer NIL when the file cannot be read as a
   database.  A reader that fails to open holds nothing - QHReader.Open gives
   its own image back before it answers - so a failure here costs the caller
   nothing but the answer.

   An image is held per file AND per page, and not per file alone.  A .hlp
   records no page of its own - the format was written before the question had
   an answer - so the page is the caller's to name, and two callers naming two
   pages for one file are describing the same bytes as two different articles.
   Answering the second with the first one's reading is a silently wrong
   answer, and it is wrong twice: the window is drawn in a page nobody asked
   for, and the search inside it reads that page too.  So the page is part of
   what names an image, MAXDB counts readings rather than files, and a file
   asked for in two pages is two images.

   A program whose page is one constant - which is every program that has
   one, and is what a command line setting a page per file looks like from
   here - sees none of this: its second open finds the first one's image and
   is the same reading as it. *)
PROCEDURE Acquire (path: ARRAY OF CHAR; page: INTEGER): Db;
VAR d: Db; i, free: INTEGER; found: BOOLEAN;
BEGIN
    d := NIL;
    found := FALSE;
    free := -1;
    i := 0;
    WHILE ~found & (i < MAXDB) DO
        IF dbs[i] = NIL THEN
            IF free < 0 THEN free := i END
        ELSIF Strings.Equal(dbs[i].path, path) & (dbs[i].page = page) THEN
            d := dbs[i];
            found := TRUE
        END;
        INC(i)
    END;
    IF ~found THEN
        NEW(d);
        d.r := QHReader.Create();
        Strings.Copy(path, d.path);
        d.page := page;
        d.uses := 0;
        IF ~d.r.Open(d.r, path) THEN
            d.r.Done(d.r);
            d := NIL
        ELSIF free >= 0 THEN
            dbs[free] := d
        END
    END;
    IF d # NIL THEN
        INC(d.uses)
    END;
    RETURN d
END Acquire;


(* Give one reference back, and the image itself when that was the last of
   them.  A window calls this once, when it closes or when it is given back,
   and it never holds a reference across that. *)
PROCEDURE Release (VAR d: Db);
VAR i: INTEGER;
BEGIN
    IF d # NIL THEN
        DEC(d.uses);
        IF d.uses <= 0 THEN
            i := 0;
            WHILE i < MAXDB DO
                IF dbs[i] = d THEN dbs[i] := NIL END;
                INC(i)
            END;
            d.r.Done(d.r);
            d.r := NIL
        END;
        d := NIL
    END
END Release;


(* --- the attributes a line is drawn in ------------------------------------ *)

(* The attribute a run of text with this style byte is drawn in, given the pair
   the body is drawn in.

   The format has three emphasis styles and a cell has one foreground and one
   background, so the three are the body's own pair, altered:

     bold       the foreground made bright, if it was not already; if it was,
                the pair is turned round, because there is nothing brighter in
                the pair to spend on it
     italic     the foreground to its other half - bright from normal, normal
                from bright
     underline  the pair turned round

   The arithmetic needs the foreground to move two ways and a pair of two
   colours has only two ends, so whichever way the pair is written one of the
   three takes the end the other is not using and two of them come out alike.
   This window's pair - a light grey on black, whose foreground is not yet
   bright - collides bold with italic, and both come out bright.  A pair whose
   foreground is already bright collides bold with underline instead, which is
   where the theme's own default area, White on Blue, puts it.  There is no
   pair that keeps all three apart, and what a reader asks of formatting is
   that a run differ from the text around it - which every one of them does.
   What is *not* done is to drop a style the pair cannot express. *)
PROCEDURE StyleAttr (style, plain: INTEGER): INTEGER;
VAR fg, bg: INTEGER;
BEGIN
    fg := plain MOD 16;
    bg := (plain DIV 16) MOD 8;         (* bit 7 of the byte is blink, not a colour *)
    IF style MOD 2 = 1 THEN                             (* bold *)
        IF fg < 8 THEN
            fg := fg + 8
        ELSE
            fg := (plain DIV 16) MOD 8;
            bg := plain MOD 16
        END
    END;
    IF (style DIV 2) MOD 2 = 1 THEN                     (* italic *)
        IF fg < 8 THEN fg := fg + 8 ELSE fg := fg - 8 END
    END;
    IF (style DIV 4) MOD 2 = 1 THEN                     (* underline *)
        fg := (plain DIV 16) MOD 8;
        bg := plain MOD 16
    END;
    RETURN TuiCanv.Attr(fg, bg)
END StyleAttr;


(* The two ends of the selection in reading order: the earlier one first.
   Everything that reads a selection goes through here, so "which way round did
   the user drag" is answered in one place. *)
PROCEDURE SelOrder (self: Win; VAR fl, fc, tl, tc: INTEGER);
BEGIN
    IF (self.anchL < self.caretL) OR
       ((self.anchL = self.caretL) & (self.anchC <= self.caretC)) THEN
        fl := self.anchL; fc := self.anchC;
        tl := self.caretL; tc := self.caretC
    ELSE
        fl := self.caretL; fc := self.caretC;
        tl := self.anchL; tc := self.anchC
    END
END SelOrder;


(* Whether anything is actually selected.  An anchor set on the cell the caret
   is on is a press and not a selection, and draws nothing - which is what
   makes a click that does not move a click. *)
PROCEDURE HasSel (self: Win): BOOLEAN;
BEGIN
    RETURN self.sel & ((self.anchL # self.caretL) OR (self.anchC # self.caretC))
END HasSel;


(* Whether one cell of one line is inside the selection.  The start is included
   and the end is not, so a selection of no length covers nothing and one that
   ends at a line's column zero does not spill onto that line. *)
PROCEDURE IsSelected (self: Win; li, col: INTEGER): BOOLEAN;
VAR fl, fc, tl, tc: INTEGER;
    r: BOOLEAN;
BEGIN
    r := FALSE;
    IF HasSel(self) THEN
        SelOrder(self, fl, fc, tl, tc);
        IF (li > fl) & (li < tl) THEN
            r := TRUE                   (* a line with both ends above it *)
        ELSIF fl = tl THEN
            r := (li = fl) & (col >= fc) & (col < tc)
        ELSIF li = fl THEN
            r := col >= fc              (* from the anchor to the line's end *)
        ELSIF li = tl THEN
            r := col < tc               (* from the line's start to the caret *)
        END
    END;
    RETURN r
END IsSelected;


(* Whether one cell of one line is inside the link the window is on.  Both
   ends of a link are 1-based over the characters of its line and inclusive,
   and the cell is a 0-based column of the same line. *)
PROCEDURE IsCurrent (self: Win; li, col: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (li = self.cur) & (self.curl >= 0) & (self.curl < self.nlink) &
         (col >= self.links[self.curl].first - 1) &
         (col <= self.links[self.curl].last - 1);
    RETURN r
END IsCurrent;

PROCEDURE IsLink (self: Win; li, col: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (* (li = self.cur) & *) (self.curl >= 0) & (self.curl < self.nlink) &
         (col >= self.links[li].first - 1) &
         (col <= self.links[li].last - 1);
    RETURN r
END IsLink;

(* Whether one cell of one line is the caret - the single cell the window draws
   as a block, and the answer to "where did the arrows go".  A window without
   the keyboard has no caret to draw: the keys are not coming to it, and a
   block on the page would be saying they were. *)
PROCEDURE IsCaret (self: Win; li, col: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := self.focused & (li = self.caretL) & (col = self.caretC);
    RETURN r
END IsCaret;


(* The attribute one cell of one line is drawn in: the body's pair altered by
   the character's style, unless the cell is marked.  Three marks can stand on
   one cell and the order they are tried in is the order the header comment
   gives them.

   The selection wins over the caret, which is TuiText' own rule: a caret is
   the moving end of the selection, and drawing it inside a run that is already
   picked out would put a second highlight on one cell of it and take the
   reader's eye off the run.  The caret wins over the link, and that is where
   this window parts company with the rule it started from - the link the
   window is on used to be drawn in the theme's selection pair, which is the
   caret's own pair here, so a caret that landed on a link would have been
   drawn in the pair the link was already in and would have disappeared on
   exactly the cell a reader most wants to see it on.  A link is a run of
   cells; giving up one of them to a block that says where the arrows are
   costs the reader nothing, because the format's own angle brackets still
   frame the link and the rest of the run is still drawn in the link's pair. *)
PROCEDURE AttrAt (self: Win; li, col, body, live, idle, cur, link: INTEGER): INTEGER;
VAR a, hl: INTEGER;
BEGIN
    IF (col >= 0) & (col < STYLES) THEN
        a := StyleAttr(self.styles[col], body)
    ELSE
        a := body
    END;
    IF self.focused THEN hl := live ELSE hl := idle END;
    IF IsSelected(self, li, col) THEN
        a := hl
    ELSIF IsCaret(self, li, col) THEN
        a := cur
    ELSIF IsCurrent(self, li, col) THEN
        a := hl
    ELSIF IsLink(self, li, col) THEN
        a := link
    END;
    RETURN a
END AttrAt;


(* --- one window's article ------------------------------------------------- *)

(* Decode the tl bytes at tp of the article into cells, and record where each
   of them begins.

   THE ONE PLACE A LINE'S BYTES BECOME CHARACTERS, and the whole of why this
   window can read a page of variable width.  Every reader of the line above
   this point works in cells; every one below it, and the file itself, works in
   bytes; and this is the seam.  Charset.Decode is the reading that knows a
   page may take more than one byte to a character - it answers one code point
   per byte on 437, 866 and Unicode, and walks a lead byte and its
   continuations as one character on UTF-8.

   The line is copied into a local first, and the bytes past its end are set to
   zero.  That is not tidying.  Decode reads up to four bytes for one character
   and asks whether the ones behind a lead are continuations, and bytes of the
   article past the end of this line are the beginning of the NEXT record -
   they would answer yes and the last character of every line would be decoded
   out of the line after it.  A zero is never a continuation, so a character
   cut off by the end of the line comes out as the replacement character, which
   is the honest answer.

   The article is a ByteArray and not a string, which is why the copy exists at
   all: Decode reads an ARRAY OF CHAR, and the bytes of the file are reached a
   call at a time.  The copy is one line long and it is made once per line per
   frame - LoadLine is the funnel every drawing, link walk and selection goes
   through - so it costs what reading the line already cost. *)
PROCEDURE SplitCells (self: Win; tp, tl: INTEGER);
VAR buf: ARRAY STYLES OF CHAR; i, n, cp, len: INTEGER;
BEGIN
    (* The format counts a line's text in a byte and allows 254 of them, so
       this never fires; it is here because a bound that is only true because
       of a fact recorded in another module is a bound worth writing down. *)
    IF tl > STYLES THEN tl := STYLES END;
    IF tl < 0 THEN tl := 0 END;

    i := 0;
    WHILE i < tl DO
        buf[i] := CHR(self.raw.Get8(self.raw, tp + i));
        INC(i)
    END;
    WHILE i < STYLES DO
        buf[i] := 0X;                   (* see the last paragraph above *)
        INC(i)
    END;

    n := 0;
    i := 0;
    WHILE (i < tl) & (n < STYLES) DO
        self.cellByte[n] := i;
        Charset.Decode(buf, i, self.db.page, cp, len);
        self.cells[n] := cp;
        i := i + len;
        INC(n)
    END;
    self.cellByte[n] := tl;             (* the sentinel: one past the last cell *)
    self.ncell := n
END SplitCells;


(* The cell a byte of the loaded line falls in.  For a page of one byte to a
   character that is the byte itself, which is the identity and is why the one
   caller of this - the link walk, wanting the cell a link begins on - did not
   have to change when the cell stopped being a byte.

   A walk and not a search: a line is 254 bytes at the very most and this is
   called once per link the window is sent to, not once per cell drawn. *)
PROCEDURE CellOf (self: Win; b: INTEGER): INTEGER;
VAR c: INTEGER;
BEGIN
    c := 0;
    WHILE (c < self.ncell) & (self.cellByte[c + 1] <= b) DO
        INC(c)
    END;
    RETURN c
END CellOf;


(* The line has just been read: its text lies at tp for tl bytes, its styles
   describe those bytes and it carries nlink links, both in byte columns.
   Decode the text and turn the other two into cell columns.

   The styles are turned round IN PLACE and forwards, which is safe for a
   reason worth stating: a cell begins at or after the column of its own index,
   so cellByte[c] >= c and the entry being read is never one that has already
   been written.  A backward loop would read what it had just clobbered.

   A cell wears the style of its FIRST byte.  A run that begins in the middle
   of a character is a thing the file can say and a reader cannot show - one
   cell, one pair of colours - and the first byte is the one that decides what
   the character is, so it is the one that decides how it is drawn.

   Links are converted rather than re-indexed: first and last are 1-based and
   inclusive over BYTES in the file's own terms, and both ends move to the cell
   holding them.  A link that ends inside a character therefore ends on that
   character's cell, which is the only cell it could end on. *)
PROCEDURE IndexLine (self: Win; tp, tl, nlink: INTEGER);
VAR c, f, l: INTEGER;
BEGIN
    SplitCells(self, tp, tl);

    c := 0;
    WHILE c < self.ncell DO
        self.styles[c] := self.styles[self.cellByte[c]];
        INC(c)
    END;

    c := 0;
    WHILE c < nlink DO
        f := self.links[c].first;
        l := self.links[c].last;
        IF f < 1 THEN f := 1 END;
        IF l > tl THEN l := tl END;
        IF l < f THEN l := f END;
        self.links[c].first := CellOf(self, f - 1) + 1;
        self.links[c].last := CellOf(self, l - 1) + 1;
        INC(c)
    END
END IndexLine;


(* Read the line at index li: its text and its attributes.  The answer is how
   many links it carries, and self.links and self.styles are left describing
   it - which is what every caller wants, since a line is drawn, walked for a
   link and selected over all in one turn, and reading it again for each of the
   three would decode the same attribute block three times.

   The line is left in cells as well, by IndexLine - and that is the same
   bargain: a line that is drawn is also asked about links and selected over,
   and all three read the decoded line rather than decoding it again.

   A line whose record cannot be read leaves no links at all rather than the
   links of the line before it, which is the one thing a stale answer would
   cost: a walk that found a link the line does not have.  It leaves the CELLS
   of the line before it for the same reason and at the same time - the guard
   below is one test and both answers follow from it. *)
PROCEDURE LoadLine (self: Win; li: INTEGER; VAR tp, tl: INTEGER): INTEGER;
VAR p, ap, al, k, adr: INTEGER;
BEGIN
    tp := 0;
    tl := 0;
    k := 0;
    IF (li >= 0) & (li < self.nline) & (self.raw # NIL) THEN
        (* A list moves bytes and not values: Get answers with the address the
           element lies at, and the offset is read back through it. *)
        adr := self.index.Get(self.index, li);
        SYSTEM.GET(adr, p);
        IF self.db.r.Line(self.db.r, self.raw, self.nraw, p, tp, tl, ap, al) THEN
            k := self.db.r.Attrs(self.db.r, self.raw, tp, tl, ap, al,
                                 self.styles, self.links);
            IndexLine(self, tp, tl, k)
        END
    END;
    self.nlink := k;
    RETURN k
END LoadLine;


(* How many characters the line at li has, 0 for one there is not.  It reads
   the line, so self.links describes it afterwards - which is why a caller that
   needs both takes the answer and then looks at the links, the way LinkAt and
   the mouse handler do.

   A CHARACTER AND NOT A BYTE, which is what makes this the one place a caller
   has to be told.  The two were the same number while the whole article was
   read a byte to a character, and they are not the same number on a page that
   spends more than one byte on one - which is exactly the case this window was
   re-read for.  self.ncell is the answer and tl is not, and the ncell a line
   an out-of-range index leaves behind is the one of the line before it, so the
   guard answers nought itself rather than reading it. *)
PROCEDURE LineLen (self: Win; li: INTEGER): INTEGER;
VAR tp, tl, k, n: INTEGER;
BEGIN
    IF (li < 0) OR (li >= self.nline) THEN
        n := 0
    ELSE
        k := LoadLine(self, li, tp, tl);
        n := self.ncell
    END;
    RETURN n
END LineLen;


(* --- the code page -------------------------------------------------------- *)

(* THE ARTICLE'S BYTES ARE NOT THE PROGRAM'S BYTES, and this is where the two
   are told apart.

   A .hlp file is a DOS file of the sixteen-bit era: a name, a title and every
   character of the text are single bytes, and which glyph a byte stands for
   depends on the code page the file was written in.  The QuickHelp tools in
   this tree write 437 by default and 866 when asked (`-cp`), and the database
   the samples show, `qbasic.hlp`, is the 1996 original - 437.

   Which page that is cannot be guessed from the bytes, so it is a parameter of
   `Open` and it is remembered on the image, because it belongs to the FILE and
   not to the window or to the program: two windows on one file read the same
   bytes the same way, and the program's own text setting has nothing to say
   about them.  TuiPage's header calls this out as one of the three places
   where the screen's page and the program's text page come apart.

   Everything below converts ONCE, on the way in or on the way out, and never
   twice - and since the article's text is decoded as it is loaded, the one
   conversion that matters is now the one on the way IN:

     - in, in SplitCells, reached from LoadLine: the bytes of a line become the
       cells every reader above works in, and that is the whole of what the
       window does with the article's characters.  A drawn cell is a code point
       and a copied cell is a code point, and neither end converts again.
     - out to the screen, in DrawLine: nothing is converted, because a canvas
       cell holds a code point already.  It is written with Put and NOT with
       Print, and that is not a preference: Print's argument is a string of the
       program's own bytes and every character of it goes through CharOf, so a
       code point handed to Print is converted a second time and lands on a
       different glyph than the one the file meant.
     - out to the clipboard, in LineText: nothing is converted either.  A cell
       becomes its UTF-8, which is what Clipboard carries on every target, and
       the copy is handed to Clipboard.Put.  It used to leave through the
       SCREEN's page, by way of PutScreen and the procedure that did the
       conversion, and that is the one road out of this window that this round
       closed - Copy's own note says what was wrong with it.
     - and in, in Locate: the topic a caller passes is a string of the
       program's own text, so it is converted into the article's page before
       it is compared with anything the file holds.  A name in the file is in
       the file's page and a name typed by a reader is in the program's, and a
       search that compares the two unconverted matches nothing above ASCII.
       This one is still a byte-to-byte conversion and not a decode, because
       what it is compared against is the file's own bytes - the index the
       reader answers with is built from them - and not the decoded line. *)


(* A string of the program's own text, as the same string in the article's
   page.  A character that page has not got becomes '?', which cannot match
   anything - the honest answer, since the file cannot be holding it. *)
PROCEDURE FileText (s: ARRAY OF CHAR; page: INTEGER; VAR dst: ARRAY OF CHAR);
VAR i, b: INTEGER;
    stop: BOOLEAN;
BEGIN
    i := 0;
    stop := FALSE;
    WHILE ~stop & (i < LEN(s)) & (i < LEN(dst) - 1) DO
        IF s[i] = 0X THEN
            stop := TRUE
        ELSE
            b := Charset.ByteOn(TuiPage.OfText(ORD(s[i])), page);
            IF b < 0 THEN b := ORD("?") END;
            dst[i] := CHR(b);
            INC(i)
        END
    END;
    dst[i] := 0X
END FileText;


(* cnt cells of line li from cell from, appended to a as UTF-8 from the index
   i is at, which is left past them.  The caller ends the string itself, since
   the whole point of the index is that several lines go into one buffer, and
   it has already brought the run inside the line and measured it with
   Charset.Width - so there is nothing to answer here and this is a procedure.

   from IS A CELL AND NOT A BYTE.  The two were the same number while every
   character of every page took one byte to write, and the loop here reads
   self.cells - the decoded line - rather than the raw bytes, so the two are
   told apart by what is being indexed and not by a convention. *)
PROCEDURE LineText (self: Win; li, from, cnt: INTEGER; VAR a: ARRAY OF CHAR;
                   VAR i: INTEGER);
VAR tp, tl, k, c: INTEGER;
BEGIN
    k := LoadLine(self, li, tp, tl);
    c := 0;
    WHILE c < cnt DO
        k := Charset.Encode(self.cells[from + c], a, i);
        INC(c)
    END
END LineText;


(* Keep the two offsets inside the article.  It is called after everything that
   moves either of them and by nothing else, so there is one place where the
   article's edges are, and a frame never draws past them. *)
PROCEDURE Clamp (self: Win);
BEGIN
    IF (self.maxw > self.cw) & (self.ox > self.maxw - self.cw) THEN
        self.ox := self.maxw - self.cw
    END;
    IF self.maxw <= self.cw THEN
        self.ox := 0
    END;
    IF self.oy > self.nline - self.ch THEN
        self.oy := self.nline - self.ch
    END;
    IF self.ox < 0 THEN self.ox := 0 END;
    IF self.oy < 0 THEN self.oy := 0 END
END Clamp;


(* Bring both ends of the selection inside the article, whatever the article
   has become.  The caret is clamped to its own line's length; an anchor is
   never moved by anything but a press or the first Shift, so its column is
   already a column of its own line and only its line needs watching. *)
PROCEDURE ClampCaret (self: Win);
VAR n: INTEGER;
BEGIN
    IF self.nline <= 0 THEN
        self.caretL := 0; self.caretC := 0;
        self.anchL := 0;  self.anchC := 0
    ELSE
        IF self.caretL < 0 THEN self.caretL := 0 END;
        IF self.caretL > self.nline - 1 THEN self.caretL := self.nline - 1 END;
        n := LineLen(self, self.caretL);
        IF self.caretC > n THEN self.caretC := n END;
        IF self.caretC < 0 THEN self.caretC := 0 END;
        IF self.anchL < 0 THEN self.anchL := 0 END;
        IF self.anchL > self.nline - 1 THEN self.anchL := self.nline - 1 END;
        n := LineLen(self, self.anchL);
        IF self.anchC > n THEN self.anchC := n END;
        IF self.anchC < 0 THEN self.anchC := 0 END
    END
END ClampCaret;


(* The room the body has, from the widget's own rectangle.  The two bars are
   always reserved, whether or not the article needs them: a viewer that grew
   and shrank them as the article required would put the text in a different
   place from one article to the next, and the bars are the only thing on the
   window that says how much of it there is. *)
PROCEDURE Geometry (self: Win);
BEGIN
    self.cw := self.width - TRACK;
    self.ch := self.height - TRACK;
    IF self.cw < 1 THEN self.cw := 1 END;
    IF self.ch < 1 THEN self.ch := 1 END;
    Clamp(self)
END Geometry;


(* Give the article and the image back.  This is what a close does, and it is
   why a closed help window costs almost nothing: what is left of it is its
   own record and the window it sits in, and the article it was showing is not
   in either. *)
PROCEDURE Unload (self: Win);
BEGIN
    IF self.index # NIL THEN
        self.index.Done(self.index);
        self.index := NIL
    END;
    IF self.raw # NIL THEN
        self.raw.Done(self.raw);
        self.raw := NIL
    END;
    Release(self.db);
    self.topic := 0;
    self.name[0] := 0X;
    self.nraw := 0;
    self.nline := 0;
    self.maxw := 0;
    self.ox := 0;
    self.oy := 0;
    self.cur := -1;
    self.curl := 0;
    self.nlink := 0;
    self.caretL := 0; self.caretC := 0;
    self.anchL := 0;  self.anchC := 0;
    self.sel := FALSE;
    self.wantC := 0;
    self.dragging := FALSE;
    self.plink := -1;
    self.plinkL := 0;
    self.nhist := 0;
    self.bar := 0;
    self.grabD := 0
END Unload;


(* Make the article `topic` the one on show.  The article already in hand goes
   first, so the two are never both held, and the record index is built in the
   same walk that measures the widest line - a frame reads the index and never
   the article's bytes, and the horizontal bar reads the width and never the
   lines.

   THE WIDTH IS IN CELLS.  It used to be the widest line's byte count, which
   was the same number as its cell count for as long as a character took one
   byte to write; it is the cell count now, which is why the walk decodes each
   line as it passes - SplitCells is the only thing in the module that knows
   how many characters a line of bytes holds, and there is no cheaper way to
   ask it.  The decode is thrown away except for its count; a line is decoded
   again when it is read, and the two decodes are of the same bytes and agree.

   The history is deliberately not this procedure's: a window that opened
   afresh and a window that followed a link both land here, and only the second
   has anywhere to have come from.  The selection is this procedure's, though,
   and goes with the article it was made in. *)
PROCEDURE Load (self: Win; topic: INTEGER);
VAR n, p, start, tp, tl, ap, al: INTEGER;
    more: BOOLEAN;
BEGIN
    IF self.index # NIL THEN
        self.index.Done(self.index);
        self.index := NIL
    END;
    IF self.raw # NIL THEN
        self.raw.Done(self.raw);
        self.raw := NIL
    END;
    self.topic := topic;
    self.nline := 0;
    self.maxw := 0;
    self.nlink := 0;
    self.cur := -1;
    self.curl := 0;
    self.ox := 0;
    self.oy := 0;
    self.caretL := 0; self.caretC := 0;
    self.anchL := 0;  self.anchC := 0;
    self.sel := FALSE;
    self.wantC := 0;
    self.dragging := FALSE;
    self.plink := -1;
    self.plinkL := 0;
    self.bar := 0;
    self.raw := ByteArr.Create(0);
    self.index := Arrays.CreateList(SYSTEM.SIZE(INTEGER));
    n := self.db.r.Raw(self.db.r, topic, self.raw);
    self.nraw := n;
    IF n > 0 THEN
        p := 0;
        more := TRUE;
        WHILE more DO
            (* the record's own offset, taken before Line walks past it: Line
               leaves pos at the start of the following record, so the index
               has to be written from the value the call was given.

               Add copies in from an address, so what is handed to it is the
               address of this local and not the offset itself - the offset is
               the value that is stored, and a list that took it for an address
               would read the offset's worth of bytes from wherever it pointed.
               The address has to lie outside the list for the same reason: the
               list may reallocate its own storage while the copy is being made. *)
            start := p;
            more := self.db.r.Line(self.db.r, self.raw, n, p, tp, tl, ap, al);
            IF more & ~self.db.r.IsCommand(self.db.r, self.raw, tp, tl) THEN
                self.index.Add(self.index, SYSTEM.ADR(start));
                INC(self.nline);
                SplitCells(self, tp, tl);
                IF self.ncell > self.maxw THEN self.maxw := self.ncell END
            END
        END
    END;
    IF ~self.db.r.Name(self.db.r, topic, self.name) THEN
        self.db.r.DbName(self.db.r, self.name)
    END;
    IF (self.host # NIL) & (Strings.Length(self.name) > 0) THEN
        self.host.SetTitle(self.host, self.name)
    END;
    Geometry(self)
END Load;


(* --- links ---------------------------------------------------------------- *)

PROCEDURE Push (self: Win; topic: INTEGER);
BEGIN
    IF self.nhist < MAXHIST THEN
        self.hist[self.nhist] := topic;
        INC(self.nhist)
    END
END Push;


(* The first link of the lines from (fromLi, fromK) to the end, or FALSE when
   there is none.  The walk reads each line as it goes, so what it leaves in
   self.links is the line it stopped on - which is the line the caller is about
   to draw and follow. *)
PROCEDURE SeekFwd (self: Win; fromLi, fromK: INTEGER;
                   VAR rli, rk: INTEGER): BOOLEAN;
VAR li, n, tp, tl: INTEGER;
    hit: BOOLEAN;
BEGIN
    hit := FALSE;
    rli := -1;
    rk := -1;
    li := fromLi;
    WHILE ~hit & (li < self.nline) DO
        n := LoadLine(self, li, tp, tl);
        IF fromK < n THEN
            rli := li;
            rk := fromK;
            hit := TRUE
        END;
        INC(li);
        fromK := 0
    END;
    RETURN hit
END SeekFwd;


(* The last link of the lines from (fromLi, fromK) back to the first, or FALSE
   when there is none.  A line is entered with fromK, which for every line but
   the first is past its end - and past its end means its last link, which is
   what walking a document backwards wants. *)
PROCEDURE SeekBack (self: Win; fromLi, fromK: INTEGER;
                    VAR rli, rk: INTEGER): BOOLEAN;
VAR li, k, n, tp, tl: INTEGER;
    hit: BOOLEAN;
BEGIN
    hit := FALSE;
    rli := -1;
    rk := -1;
    li := fromLi;
    k := fromK;
    WHILE ~hit & (li >= 0) DO
        n := LoadLine(self, li, tp, tl);
        IF k >= n THEN k := n - 1 END;
        IF k >= 0 THEN
            rli := li;
            rk := k;
            hit := TRUE
        END;
        DEC(li);
        k := STYLES                    (* past the end of any line *)
    END;
    RETURN hit
END SeekBack;


(* Bring one cell of one line inside the body, moving each offset as little as
   it can: a line already on screen is not moved at all, and a cell off the
   right edge comes in at the right edge rather than at the left. *)
PROCEDURE BringIntoView (self: Win; li, col: INTEGER);
BEGIN
    IF li < self.oy THEN
        self.oy := li
    ELSIF li >= self.oy + self.ch THEN
        self.oy := li - self.ch + 1
    END;
    IF col < self.ox THEN
        self.ox := col
    ELSIF col >= self.ox + self.cw THEN
        self.ox := col - self.cw + 1
    END;
    Clamp(self)
END BringIntoView;


(* Move to the next link in the direction asked for and bring it into view.
   The walk starts after the link the window is on, so Tab visits the links of
   an article in the order they are drawn, and it wraps to the first one at the
   end - the one thing a keyboard needs and a document cannot supply.  The
   horizontal position is brought in on the link's first character, which is
   the left end of what the reader wants to read.

   The caret and the selection are deliberately not touched: this moves the
   reader's place in the links, and the selection is the reader's place in the
   text. *)
PROCEDURE NextLink (self: Win; dir: INTEGER);
VAR li, k: INTEGER;
    hit: BOOLEAN;
BEGIN
    hit := FALSE;
    IF self.nline > 0 THEN
        IF (self.cur < 0) OR (self.cur >= self.nline) THEN
            self.cur := 0;
            self.curl := -1
        END;
        IF dir >= 0 THEN
            hit := SeekFwd(self, self.cur, self.curl + 1, li, k);
            IF ~hit THEN
                hit := SeekFwd(self, 0, 0, li, k)
            END
        ELSE
            hit := SeekBack(self, self.cur, self.curl - 1, li, k);
            IF ~hit THEN
                hit := SeekBack(self, self.nline - 1, STYLES, li, k)
            END
        END;
        IF hit THEN
            self.cur := li;
            self.curl := k;
            BringIntoView(self, li, self.links[k].first - 1)
        END
    END
END NextLink;


(* The number of the link covering a cell of a line, or -1.  It leaves the line
   read, so self.links describes the line the answer is about. *)
PROCEDURE LinkAt (self: Win; li, col: INTEGER): INTEGER;
VAR n, tp, tl, k: INTEGER;
BEGIN
    n := LoadLine(self, li, tp, tl);
    k := 0;
    WHILE (k < n) & ~((col >= self.links[k].first - 1) &
                      (col <= self.links[k].last - 1)) DO
        INC(k)
    END;
    IF k >= n THEN k := -1 END;
    RETURN k
END LinkAt;


(* The caret has just stopped moving: if it is standing on a link, that link
   becomes the window's.

   This is what a reader who never touches the mouse needs, and it is the whole
   of the coupling in that direction.  Tab walks the links and leaves the caret
   where it was, so a reader can visit every link of an article without losing
   their place in the text; the arrows move the caret, and whatever link it
   lands on is lit exactly as it is when the mouse passes over one.  A caret on
   ordinary text leaves the link alone - the one the reader was last on stays
   lit - which is what the mouse does when it leaves a run too.

   It is a procedure of its own, and it is called by both movers, because the
   caret has exactly two of them and they do not share a line: CaretTo is the
   caret being *told* where to be (Home, End, a click, an article opening) and
   MoveCaret is the caret being *stepped* (the four arrows and the two page
   keys).  A version of this that lived in CaretTo alone would be invisible to
   every arrow key, which is the one case it exists for. *)
PROCEDURE SyncLink (self: Win);
VAR k: INTEGER;
BEGIN
    k := LinkAt(self, self.caretL, self.caretC);
    IF k >= 0 THEN
        self.cur := self.caretL;
        self.curl := k
    END
END SyncLink;


(* Go where a link points.  A link whose target is not an article of this
   database - the history command, a command for another database, or a name
   that answers to nothing, all of which Resolve leaves as -1 - is drawn and
   walked like any other and opens nothing, which is the honest answer: the
   file says there is a link and this viewer cannot say where it goes. *)
PROCEDURE Follow (self: Win; li, k: INTEGER): BOOLEAN;
VAR t, tp, tl: INTEGER;
    ok: BOOLEAN;
BEGIN
    ok := FALSE;
    t := -1;
    IF (li >= 0) & (k >= 0) THEN
        IF LoadLine(self, li, tp, tl) > k THEN
            t := self.links[k].topic
        END
    END;
    IF (t >= 0) & (t < self.db.r.Topics(self.db.r)) THEN
        Push(self, self.topic);
        Load(self, t);
        ok := TRUE
    END;
    RETURN ok
END Follow;


(* Back the way the window came, one article at a time.  The history is the
   window's own: two windows on one database that followed the same link twice
   each have their own trail, and closing one does not shorten the other's. *)
PROCEDURE Back (self: Win): BOOLEAN;
VAR ok: BOOLEAN;
BEGIN
    ok := FALSE;
    IF self.nhist > 0 THEN
        DEC(self.nhist);
        Load(self, self.hist[self.nhist]);
        ok := TRUE
    END;
    RETURN ok
END Back;


(* --- the two bars --------------------------------------------------------- *)

(* How tall the thumb is over a track of `cells` for a content of `count`
   cells, and which cell of the track it starts on.  This is TuiTbl' own
   arithmetic, written the same way and here rather than called from there
   because the two widgets have nothing else to do with each other - and
   written the same way so that a reader who has learned one bar has learned
   both.  A view that shows everything takes the branch that does not divide;
   the divisions are the reason it exists. *)
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


(* Where the view starts when the top of the thumb is put at cell thumbTop.
   The exact inverse of what Thumb does with top, which is what dragging a
   thumb needs at every step. *)
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
        t := 0                          (* nothing is scrolled: no track *)
    END;
    IF t > count - cells THEN t := count - cells END;
    IF t < 0 THEN t := 0 END;
    RETURN t
END ScrollTo;


(* Which cell of the vertical bar the point is on, 0 being the top one. *)
PROCEDURE OnVBar (self: Win; x, y: INTEGER; VAR cell: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (x = self.x + self.width - TRACK) & (y >= self.y) & (y < self.y + self.ch);
    IF r THEN cell := y - self.y END;
    RETURN r
END OnVBar;


(* ... and of the horizontal bar, 0 being the leftmost.  Its track runs one
   cell past the body, into the corner where the two bars meet. *)
PROCEDURE OnHBar (self: Win; x, y: INTEGER; VAR cell: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (y = self.y + self.height - TRACK) &
         (x >= self.x) & (x < self.x + self.cw + 1);
    IF r THEN cell := x - self.x END;
    RETURN r
END OnHBar;


PROCEDURE DrawVBar (self: Win; target: TuiCanv.Canvas; a: INTEGER);
VAR i, size, off: INTEGER;
BEGIN
    Thumb(self.nline, self.ch, self.oy, size, off);
    FOR i := 0 TO self.ch - 1 DO
        IF (i >= off) & (i < off + size) THEN
            target.Put(target, self.x + self.width - TRACK, self.y + i,
                       TuiCanv.BLOCK, a)
        ELSE
            target.Put(target, self.x + self.width - TRACK, self.y + i,
                       TuiCanv.SHADE_LIGHT, a)
        END
    END
END DrawVBar;


PROCEDURE DrawHBar (self: Win; target: TuiCanv.Canvas; a: INTEGER);
VAR i, size, off, n: INTEGER;
BEGIN
    n := self.cw + TRACK;               (* ... and the corner is its last cell *)

    (* The bar is n cells long but only cw of them have article under them: the
       last one is the corner the vertical bar's foot stands on.  Thumb is asked
       how much of the article is on show, which is cw and not n - the same cw
       Clamp bounds ox by, so the two agree on where the end of the line is.
       Asked about n, it calls a line one cell wider than the view fully
       visible, and the reader is shown a last character the window cut off. *)
    Thumb(self.maxw, self.cw, self.ox, size, off);
    FOR i := 0 TO n - 1 DO
        IF (i >= off) & (i < off + size) THEN
            target.Put(target, self.x + i, self.y + self.height - TRACK,
                       TuiCanv.BLOCK, a)
        ELSE
            target.Put(target, self.x + i, self.y + self.height - TRACK,
                       TuiCanv.SHADE_LIGHT, a)
        END
    END
END DrawHBar;


(* --- drawing -------------------------------------------------------------- *)

(* One line of the article into one row of the body.  The row is cleared to the
   body's pair first, so a line shorter than the window leaves nothing of an
   earlier frame behind it, and the text is then printed in runs: a run is as
   long as the attribute does not change, and a line with no formatting, no
   link and no selection on it is one run and one call. *)
PROCEDURE DrawLine (self: Win; target: TuiCanv.Canvas; li, row: INTEGER;
                    body, live, idle, cur, link: INTEGER);
VAR tp, tl, i, col, a, k: INTEGER;
BEGIN
    target.Fill(target, self.x, row, self.cw, 1, " ", body);
    k := LoadLine(self, li, tp, tl);      (* the links it leaves are not drawn *)
    i := 0;
    WHILE i < self.cw DO
        col := self.ox + i;
        IF col >= self.ncell THEN
            i := self.cw                  (* past the end of the line *)
        ELSE
            a := AttrAt(self, li, col, body, live, idle, cur, link);
            (* A cell at a time, and NOT a run through Print.  Print's argument
               is a string of the PROGRAM's own bytes and it converts every
               character of it, so a code point put through it would be read as
               a byte of the program's text page and land on whatever glyph
               that page has there - the article drawn twice through two
               different tables.  And a code point above 0FFH cannot be put in
               a string at all: every one of them would be cut to its low byte
               on the way into the buffer and the run would come out as the
               wrong glyphs even though the conversion was right.

               The cell itself used to be read out of the file here, one byte
               at a time through Charset.PointOf.  It is read out of the loaded
               line now, which is the same character on a page of one byte to a
               character and the right one on a page of more - the decode
               happened once, in SplitCells, and this is one of the two places
               that reads its answer.  col and self.ox + i are cell indices and
               the comparison above is against ncell, so a window scrolled past
               the end of the line stops where it stopped before. *)
            WHILE (i < self.cw) & (self.ox + i < self.ncell) &
                  (AttrAt(self, li, self.ox + i, body, live, idle, cur, link) = a) DO
                target.Put(target, self.x + i, row,
                           WCHR(self.cells[self.ox + i]), a);
                INC(i)
            END
        END
    END;
    (* The caret on a cell no run reached.  The runs above stop where the line's
       text stops, and the cells between there and the edge of the window were
       laid down by the Fill as one blank each and never asked an attribute
       about - so a caret past the end of its line is drawn by nobody.  That is
       not a corner: it is where the caret starts, because an article opens on
       its first line and Load puts the caret at the first cell of it, and the
       first line of this database's first article is empty.  One cell, drawn
       as a blank in the caret's pair, and only when the runs did not already
       take it - the column is at or past the line's end, which is exactly the
       test the run loop stops on. *)
    col := self.caretC;
    IF IsCaret(self, li, col) & (col >= self.ncell) &
       (col >= self.ox) & (col < self.ox + self.cw) THEN
        target.Fill(target, self.x + col - self.ox, row, 1, 1, " ", cur)
    END
END DrawLine;


PROCEDURE draw (self: Win; target: TuiCanv.Canvas);
VAR i, li, body, live, idle, cur, bar, link: INTEGER;
BEGIN
    body := TuiCanv.Attr(BODY_FG, BODY_BG);
    live := TuiCanv.Attr(SEL_FG, SEL_BG);
    idle := TuiCanv.Attr(SELIDLE_FG, SELIDLE_BG);
    cur  := TuiCanv.Attr(CARET_FG, CARET_BG);
    bar  := TuiCanv.Attr(BAR_FG, BAR_BG);
    link := TuiCanv.Attr(LINK_FG, LINK_BG);
    FOR i := 0 TO self.ch - 1 DO
        li := self.oy + i;
        IF li < self.nline THEN
            DrawLine(self, target, li, self.y + i, body, live, idle, cur, link)
        ELSE
            target.Fill(target, self.x, self.y + i, self.cw, 1, " ", body)
        END
    END;
    DrawVBar(self, target, bar);
    DrawHBar(self, target, bar)
END draw;


PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR self: Win;
BEGIN
    IF w IS Win THEN
        self := w(Win);
        draw(self, target)
    END
END Paint;


(* --- the selection -------------------------------------------------------- *)

(* Put the caret here, and let it say which link the window is on.  One of the
   caret's two movers; SyncLink is above and carries the reason. *)
PROCEDURE CaretTo (self: Win; li, col: INTEGER);
BEGIN
    self.caretL := li;
    self.caretC := col;
    self.wantC := col;
    SyncLink(self)
END CaretTo;


(* Plant the anchor where the caret is, if this is the first key of a
   selection.  Called by every extending move and by nothing else, which is why
   a bare arrow with no Shift cannot begin one. *)
PROCEDURE BeginSel (self: Win; extend: BOOLEAN);
BEGIN
    IF extend & ~self.sel THEN
        self.anchL := self.caretL;
        self.anchC := self.caretC;
        self.sel := TRUE
    END
END BeginSel;


(* The caret by so many lines and so many cells.  A horizontal step that runs
   off an end carries into the neighbouring line - left from a line's first
   character lands on the last of the one above - which is what makes a
   selection able to cross a line at all without a key that exists only for
   that.

   A vertical step takes the column the caret *wants* rather than the one it
   has, and clamps it to the line it lands on.  That is what makes a block of
   text selectable: Shift+Down three lines over a short one, and back up,
   returns to the column the selection started at rather than to wherever the
   short line cut it to. *)
PROCEDURE MoveCaret (self: Win; dli, dcol: INTEGER; extend: BOOLEAN);
VAR n: INTEGER;
BEGIN
    BeginSel(self, extend);
    IF dli # 0 THEN
        self.caretL := self.caretL + dli;
        IF self.caretL < 0 THEN self.caretL := 0 END;
        IF self.caretL > self.nline - 1 THEN self.caretL := self.nline - 1 END;
        IF self.caretL < 0 THEN self.caretL := 0 END;
        self.caretC := self.wantC;
        n := LineLen(self, self.caretL);
        IF self.caretC > n THEN self.caretC := n END
    END;
    IF dcol # 0 THEN
        self.caretC := self.caretC + dcol;
        IF self.caretC < 0 THEN
            IF self.caretL > 0 THEN
                DEC(self.caretL);
                self.caretC := LineLen(self, self.caretL)
            ELSE
                self.caretC := 0
            END
        ELSE
            n := LineLen(self, self.caretL);
            IF self.caretC > n THEN
                IF self.caretL < self.nline - 1 THEN
                    INC(self.caretL);
                    self.caretC := 0
                ELSE
                    self.caretC := n
                END
            END
        END;
        self.wantC := self.caretC
    END;
    SyncLink(self)                       (* the caret's other mover - see above *)
END MoveCaret;


(* One of the eight moving keys, with or without Shift.  A plain move that ends
   a selection collapses it to the end the key points away from and moves no
   further - which is what every editor does, and what makes the arrow after a
   drag land where the reader expects rather than one cell past it. *)
PROCEDURE CaretKey (self: Win; VAR e: Events.Event; extend: BOOLEAN): BOOLEAN;
VAR fl, fc, tl, tc, page, n, was: INTEGER;
    took: BOOLEAN;
BEGIN
    took := TRUE;
    page := self.ch - OVERLAP;
    IF page < 1 THEN page := 1 END;
    IF ~extend & HasSel(self) THEN
        SelOrder(self, fl, fc, tl, tc);
        IF (e.scan = Events.K_UP) OR (e.scan = Events.K_LEFT) OR
           (e.scan = Events.K_PGUP) OR (e.scan = Events.K_HOME) THEN
            CaretTo(self, fl, fc)
        ELSE
            CaretTo(self, tl, tc)
        END;
        self.sel := FALSE
    ELSIF e.scan = Events.K_LEFT THEN
        MoveCaret(self, 0, -1, extend)
    ELSIF e.scan = Events.K_RIGHT THEN
        MoveCaret(self, 0, 1, extend)
    ELSIF e.scan = Events.K_UP THEN
        MoveCaret(self, -1, 0, extend)
    ELSIF e.scan = Events.K_DOWN THEN
        MoveCaret(self, 1, 0, extend)
    ELSIF (e.scan = Events.K_PGUP) OR (e.scan = Events.K_PGDN) THEN
        (* A page key moves a page of the *view*, and only the two ends of the
           article are exceptions.  The caret goes a screen's worth of lines and
           the article moves behind it by the same amount, so the caret keeps
           the row it had and the screen the reader was reading is replaced by
           the next one.  Letting the view follow the caret the way an arrow
           does - just far enough to keep it in sight - would leave the view
           exactly where it was whenever the move landed inside it, which from
           the top of an article is every page key there is. *)
        was := self.caretL;
        IF e.scan = Events.K_PGUP THEN
            MoveCaret(self, -page, 0, extend)
        ELSE
            MoveCaret(self, page, 0, extend)
        END;
        self.oy := self.oy + (self.caretL - was);
        Clamp(self)
    ELSIF e.scan = Events.K_HOME THEN
        BeginSel(self, extend);
        IF e.ctrl THEN
            CaretTo(self, 0, 0)
        ELSE
            CaretTo(self, self.caretL, 0)
        END
    ELSIF e.scan = Events.K_END THEN
        BeginSel(self, extend);
        IF e.ctrl THEN
            n := self.nline - 1;
            IF n < 0 THEN n := 0 END;
            CaretTo(self, n, LineLen(self, n))
        ELSE
            CaretTo(self, self.caretL, LineLen(self, self.caretL))
        END
    ELSE
        took := FALSE
    END;
    IF took THEN
        ClampCaret(self);
        BringIntoView(self, self.caretL, self.caretC)
    END;
    RETURN took
END CaretKey;


PROCEDURE SelectAll (self: Win);
VAR n: INTEGER;
BEGIN
    IF self.nline > 0 THEN
        n := self.nline - 1;
        self.anchL := 0;   self.anchC := 0;
        self.sel := TRUE;
        CaretTo(self, n, LineLen(self, n));
        ClampCaret(self);
        BringIntoView(self, self.caretL, self.caretC)
    END
END SelectAll;


(* The selection as one string, the lines joined with CR LF, put on the
   clipboard.

   It is built in Clipboard's own buffer size and cut at a LINE BOUNDARY, by
   measuring the next line before a byte of it is written rather than by
   filling the buffer and asking afterwards: a buffer filled to its limit with
   half a line in it would paste as a different text.  A line that does not fit
   in what is left stops the copy where it stands, and the lines already in the
   buffer are what goes on the clipboard - losing them would be the worse half
   of the same mistake.

   THE MEASURE IS IN BYTES AND THE LINE IS IN CELLS, and those are two numbers
   since the article stopped being read a byte to a character.  Charset.Width
   answers how many bytes one cell takes, so the line's bytes are added up
   before the line is written, and the two loops below are the reason no
   intermediate buffer is needed at all: the measure and the write walk the
   same cells in the same order.

   THE CLIPBOARD'S UTF-8 PAIR AND NOT THE SCREEN'S PAGE.  It used to go out
   through PutScreen, which is written against the page the SCREEN is in - so
   what was copied was what the reader could see, and a character the screen
   had not got left as the '?' the reader was looking at.  That is the wrong
   bargain twice over: the reader is copying the ARTICLE, not the picture of
   it, and on a host whose screen is a wide one every character above 0FFH is
   a candidate for that '?', which is the whole alphabet of a Russian article.
   Put carries the characters themselves, as UTF-8, on every target - which is
   also what makes this the same text whoever reads it next.

   This is the only thing in the module that writes anywhere outside it, and
   what it writes is a copy - the article is not touched.  It is what both
   Ctrl+C and Ctrl+X reach, since a viewer that cannot write has no cut to
   offer and the honest answer to the key is the copy. *)
PROCEDURE Copy (self: Win);
VAR
    dst: ARRAY Clipboard.MAXCLIP OF CHAR;
    fl, fc, tl, tc, li, n, from, last, cnt, k, nb, i, room: INTEGER;
    first, stop: BOOLEAN;
BEGIN
    IF HasSel(self) THEN
        SelOrder(self, fl, fc, tl, tc);
        i := 0;
        dst[0] := 0X;
        first := TRUE;
        stop := FALSE;
        li := fl;
        WHILE ~stop & (li <= tl) DO
            n := LineLen(self, li);
            from := 0;
            last := n;
            IF li = fl THEN from := fc END;
            IF li = tl THEN last := tc END;
            IF last > n THEN last := n END;
            IF from > last THEN from := last END;
            cnt := last - from;

            nb := 0;
            k := 0;
            WHILE k < cnt DO
                nb := nb + Charset.Width(self.cells[from + k]);
                INC(k)
            END;

            room := Clipboard.MAXCLIP - 1 - i - nb;
            IF ~first THEN room := room - 2 END;   (* the CR LF between lines *)
            IF room < 0 THEN
                stop := TRUE
            ELSE
                IF ~first THEN
                    dst[i] := CR; INC(i);
                    dst[i] := LF; INC(i)
                END;
                LineText(self, li, from, cnt, dst, i);
                dst[i] := 0X;
                first := FALSE;
                INC(li)
            END
        END;
        Clipboard.Put(dst)
    END
END Copy;


(* --- the keyboard --------------------------------------------------------- *)

(* What the keys do.  Esc is asked first and answers the whole of the event:
   the desk's own close, so the box on the title row and this key are one road
   and not two - the window is asked, and told through onClosed, which is where
   the article is given back.  Nothing below touches this record's article
   after that, and the value that comes back is the close's own answer.

   Everything else is a view of the article and a choice of what to take out of
   it.  Nothing here is a choice *in* it: there is no key that writes. *)
PROCEDURE Keys (self: Win; VAR e: Events.Event): BOOLEAN;
VAR took: BOOLEAN;
BEGIN
    took := TRUE;
    IF e.scan = Events.K_ESC THEN
        took := Tui.Close(self.host)
    ELSIF Events.IsCtrl(e, Events.CTRL_C) OR Events.IsCtrl(e, Events.CTRL_X) THEN
        Copy(self)
    ELSIF Events.IsCtrl(e, Events.CTRL_A) THEN
        SelectAll(self)
    ELSIF (e.scan = Events.K_LEFT) OR (e.scan = Events.K_RIGHT) OR
          (e.scan = Events.K_UP) OR (e.scan = Events.K_DOWN) OR
          (e.scan = Events.K_PGUP) OR (e.scan = Events.K_PGDN) OR
          (e.scan = Events.K_HOME) OR (e.scan = Events.K_END) THEN
        took := CaretKey(self, e, e.shift)
    ELSIF e.scan = Events.K_TAB THEN
        IF e.shift THEN NextLink(self, -1) ELSE NextLink(self, 1) END
    ELSIF e.scan = Events.K_ENTER THEN
        (* One rule: Enter follows the link the window is on, and that is the
           one the reader can see lit.  The caret put it there when the caret
           moved onto a link, Tab put it there when the reader walked the
           links, and the mouse put it there when it passed over one - so
           whichever way the reader pointed at a link, Enter follows that one
           and nothing here has to choose between them. *)
        IF Follow(self, self.cur, self.curl) THEN END
    ELSIF e.scan = Events.K_BACK THEN
        IF Back(self) THEN END
    ELSE
        took := FALSE
    END;
    RETURN took
END Keys;


(* The wheel, which scrolls the article the way the bars do - a notch is worth
   three lines, and with Shift it is the horizontal that moves.

   This arm is here for a producer that sends one, and today none does: the
   desk routes MOUSE and KEYBOARD through Tui.Send and nothing else, and the
   console body of the input layer never makes a wheel.  It is four lines and
   it is the truth about what this widget does with a wheel, so it is written
   here rather than left to be guessed at; a desk that routes WHEEL, or a
   window body that produces one, gets a viewer that already knows what to do
   with it. *)
PROCEDURE Wheel (self: Win; VAR e: Events.Event): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := TRUE;
    IF e.shift THEN
        self.ox := self.ox + e.wheel
    ELSE
        self.oy := self.oy + e.wheel * 3
    END;
    Clamp(self);
    RETURN r
END Wheel;


(* --- the mouse ------------------------------------------------------------ *)

(* One mouse event, over the body or over either bar.

   The two thumbs are held the way TuiTbl holds its own: a press takes the
   thumb and the hold follows the pointer anywhere, on the track or off it,
   until the button comes back up, and a press on the track either side of the
   thumb moves a page.

   In the body a press begins a selection - anchor and caret on the cell under
   the pointer, which selects nothing until the pointer moves - and the hold
   drags the caret after it.  A press that comes back up on the cell it went
   down on is a click, and a click on a link follows it: that is the whole of
   the difference between selecting a link's text and going where it points,
   and it is the difference every text viewer draws.  A pointer merely moving
   over a link makes it the current one, which is how the user finds out that
   it is there - and CaretTo does the same two lines for the caret, so the
   reader who never touches the mouse finds links the same way. *)
PROCEDURE Mouse (self: Win; VAR e: Events.Event): BOOLEAN;
VAR cell, size, off, li, col, k, n: INTEGER;
    took: BOOLEAN;
BEGIN
    took := TRUE;
    IF self.bar # 0 THEN
        IF Events.IsClick(e) THEN
            IF self.bar = 1 THEN
                self.oy := ScrollTo(self.nline, self.ch,
                                    e.y - self.y - self.grabD)
            ELSE
                self.ox := ScrollTo(self.maxw, self.cw + TRACK,
                                    e.x - self.x - self.grabD)
            END
        ELSE
            self.bar := 0
        END;
        Clamp(self)
    ELSIF self.dragging THEN
        IF Events.IsClick(e) THEN
            li := self.oy + (e.y - self.y);
            col := self.ox + (e.x - self.x);
            IF (li >= 0) & (li < self.nline) THEN
                IF col < 0 THEN col := 0 END;
                n := LineLen(self, li);
                IF col > n THEN col := n END;
                CaretTo(self, li, col)
            END
        ELSE
            self.dragging := FALSE;
            (* nothing moved: it was a click, and a click on a link follows it *)
            IF (self.plink >= 0) & (self.caretL = self.anchL) &
               (self.caretC = self.anchC) THEN
                IF Follow(self, self.plinkL, self.plink) THEN END
            END
        END
    ELSIF Events.IsPress(e) & OnVBar(self, e.x, e.y, cell) THEN
        Thumb(self.nline, self.ch, self.oy, size, off);
        IF (cell >= off) & (cell < off + size) THEN
            self.bar := 1;
            self.grabD := cell - off
        ELSIF cell < off THEN
            self.oy := self.oy - self.ch
        ELSE
            self.oy := self.oy + self.ch
        END;
        Clamp(self)
    ELSIF Events.IsPress(e) & OnHBar(self, e.x, e.y, cell) THEN
        Thumb(self.maxw, self.cw + TRACK, self.ox, size, off);
        IF (cell >= off) & (cell < off + size) THEN
            self.bar := 2;
            self.grabD := cell - off
        ELSIF cell < off THEN
            self.ox := self.ox - self.cw
        ELSE
            self.ox := self.ox + self.cw
        END;
        Clamp(self)
    ELSIF OnVBar(self, e.x, e.y, cell) OR OnHBar(self, e.x, e.y, cell) THEN
        took := TRUE                     (* a pass over a bar is the widget's *)
    ELSE
        (* the body *)
        li := self.oy + (e.y - self.y);
        col := self.ox + (e.x - self.x);
        IF (li >= 0) & (li < self.nline) THEN
            n := LineLen(self, li);
            IF col < 0 THEN col := 0 END;
            IF col > n THEN col := n END;
            k := LinkAt(self, li, col);
            IF Events.IsPress(e) THEN
                CaretTo(self, li, col);
                self.anchL := li;
                self.anchC := col;
                self.sel := TRUE;
                self.dragging := TRUE;
                self.plinkL := li;
                self.plink := k
            END;
            IF k >= 0 THEN
                self.cur := li;
                self.curl := k
            END
        ELSIF Events.IsPress(e) THEN
            (* past the last line: a drag that selects nothing yet, but that
               the widget still owns until the button comes back up *)
            self.dragging := TRUE;
            self.plink := -1;
            self.plinkL := 0
        END
    END;
    RETURN took
END Mouse;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR self: Win;
    took: BOOLEAN;
BEGIN
    took := FALSE;
    IF w IS Win THEN
        self := w(Win);
        IF (e.kind = Events.MOUSE) & ((self.bar # 0) OR self.dragging) THEN
            (* a hold that has wandered off the widget is still the widget's,
               or letting go outside it would leave a thumb held, or a
               selection half made, for ever *)
            took := Mouse(self, e)
        ELSIF (e.kind = Events.KEYBOARD) & self.focused THEN
            took := Keys(self, e)
        ELSIF (e.kind = Events.WHEEL) & self.focused THEN
            took := Wheel(self, e)
        ELSIF TuiWidg.Inside(w, e.x, e.y) THEN
            took := Mouse(self, e)
        END;
        (* The desk reads the kind to know whether anything is left of the
           event, so a widget that took it has to say so.  The framework's own
           widgets do this at the end of their handlers and this is the same
           assignment in the same place. *)
        IF took THEN e.kind := Events.NONE END
    END;
    RETURN took
END Handle;


(* The keyboard on and off, which is the desk's way of saying that this window
   is the one the user is typing into.  It is also what draws the mark in the
   live pair rather than the idle one - both the link's and the selection's:
   the flag is read at draw time and nothing is repainted here, because the
   frame this arrives in is the frame the desk is about to draw. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR self: Win;
BEGIN
    IF w IS Win THEN
        self := w(Win);
        self.focused := on
    END
END Take;


PROCEDURE Resized (w: TuiWidg.Widget; cw, ch: INTEGER);
VAR self: Win;
BEGIN
    IF w IS Win THEN
        self := w(Win);
        (* the window's canvas less its two frames: the widget sits inside
           them, and the two bars are inside the widget.  This is the whole of
           what a resize does here - the article is measured in cells and the
           frame that draws it reads this rectangle at every cell, so there is
           nothing to lay out again and nothing to remember *)
        self.x := 1;
        self.y := 1;
        self.width := cw - 2;
        self.height := ch - 2;
        Geometry(self)
    END
END Resized;


(* --- the window's own life ------------------------------------------------ *)

(* Told when a window has gone.  It is the moment the article and the image are
   given back, and giving them back here rather than at the turn's end is what
   makes a closed help window cost nothing while it waits to be used again. *)
PROCEDURE Closed (w: TuiWin.Window);
VAR self: Win;
    i: INTEGER;
BEGIN
    i := 0;
    WHILE i < nwin DO
        IF (wins[i] # NIL) & (wins[i].host = w) THEN
            self := wins[i];
            Unload(self)
        END;
        INC(i)
    END
END Closed;


(* The widget given back for good, which happens when the desk goes: Tui.Done
   gives every window back and every widget a window owns with it.  The article
   has usually been given back already - by the close that took the window off
   the show - and this is the second half of the same act for the windows that
   were still up.

   It takes `Oberon.Object` and guards down because it is what goes into the
   inherited `Done` field, whose declared type is `PROCEDURE (self: Object)`.
   Dispose, the second name this widget used to carry for the same act, is gone
   - Oberon.mod has the rule. *)
PROCEDURE DoneWin (self: Oberon.Object);
VAR v: Win;
    i, n: INTEGER;
BEGIN
    v := self(Win);
    Unload(v);
    (* and out of the list this module keeps, so that a window made later
       is not handed a record that has been given back.  The list is packed
       rather than left with a hole, because the order is the order they
       were made and nothing depends on the index being stable *)
    n := 0;
    FOR i := 0 TO nwin - 1 DO
        IF wins[i] = v THEN
            wins[i] := NIL
        END;
        IF wins[i] # NIL THEN
            wins[n] := wins[i];
            INC(n)
        END
    END;
    nwin := n;
    DISPOSE(v)
END DoneWin;


PROCEDURE Create (host: TuiWin.Window): Win;
VAR v: Win;
BEGIN
    NEW(v);
    v.x := 1;
    v.y := 1;
    v.width := 0;
    v.height := 0;
    v.visible := TRUE;
    v.focused := FALSE;
    v.canvas := NIL;
    v.id := 0;
    v.data := 0;
    v.lastCmd := 0;
    v.db := NIL;
    v.host := host;
    v.topic := 0;
    v.name[0] := 0X;
    v.raw := NIL;
    v.nraw := 0;
    v.index := NIL;
    v.nline := 0;
    v.maxw := 0;
    v.ox := 0;
    v.oy := 0;
    v.cur := -1;
    v.curl := 0;
    v.nlink := 0;
    v.caretL := 0; v.caretC := 0;
    v.anchL := 0;  v.anchC := 0;
    v.sel := FALSE;
    v.wantC := 0;
    v.dragging := FALSE;
    v.plink := -1;
    v.plinkL := 0;
    v.nhist := 0;
    v.bar := 0;
    v.grabD := 0;
    v.handler := Handle;
    v.taker := Take;
    v.painter := Paint;
    v.resizer := Resized;
    v.onCommand := NIL;
    v.Done := DoneWin;
    TuiWin.Own(host, v);
    Resized(v, host.width, host.height);
    RETURN v
END Create;


(* --- the box a bad file name raises --------------------------------------- *)

(* Report a file that cannot be shown.  It is a modal box and not an article
   because there is nothing to open and nothing to say about it beyond its
   name; the desk opens it, the user answers it, and its id reaches the
   application's command handler, which has no case for it and does nothing -
   so a help window that could not be opened costs the application nothing.

   Two things reach here and they are not the same failure, which is why the
   line above the name is the caller's: a file that could not be read at all,
   and a file that read perfectly well and holds no readable text.  The second
   is not a nicety - QHReader opens it, answers every question about its
   header, index and context names, and answers nothing at all for Text, Raw,
   Find and Name, because the header's attribute bit 1 says its topics were
   never compressed.  A window opened on one of those is a blank page with the
   database's own name on it, which reads as an article that happens to be
   empty and not as a file that is locked - so it is reported here instead.

   The tail of the name is shown rather than its head: a path cut short at 43
   characters loses the file's own name, which is the one part of it the user
   can do something about. *)
PROCEDURE Err (lead, path: ARRAY OF CHAR);
VAR s: ARRAY MSGLEN OF CHAR;
    n: INTEGER;
BEGIN
    IF err = NIL THEN
        err := TuiDlg.Create("Help");
        IF err.AddButton(err, "OK", OKID, TRUE) > 0 THEN END
    END;
    n := Strings.Length(path);
    IF n > MSGLEN - 1 THEN
        Strings.Extract(path, n - (MSGLEN - 1), MSGLEN - 1, s)
    ELSE
        Strings.Copy(path, s)
    END;
    err.SetText(err, lead, s);
    Tui.SetDialog(err)
END Err;


(* --- what a caller uses --------------------------------------------------- *)

(* Whether two strings are equal with case ignored.  A context name is written
   the way the database's author wrote it and a caller may have it from
   anywhere, so the comparison is the loose one; a topic name is matched by
   Find, which has its own rule. *)
PROCEDURE EqFold (a, b: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
    ca, cb: CHAR;
    same: BOOLEAN;
BEGIN
    same := TRUE;
    i := 0;
    WHILE same & (a[i] # 0X) & (b[i] # 0X) DO
        ca := a[i];
        cb := b[i];
        IF (ca >= "A") & (ca <= "Z") THEN ca := CHR(ORD(ca) + 32) END;
        IF (cb >= "A") & (cb <= "Z") THEN cb := CHR(ORD(cb) + 32) END;
        IF ca # cb THEN same := FALSE END;
        INC(i)
    END;
    IF a[i] # b[i] THEN same := FALSE END;
    RETURN same
END EqFold;


(* Find the article `topic` names, or 0 for the database's first one.

   Four questions, in the order that costs the user least: the name outright;
   a context name, which is what a caller who has one from somewhere else is
   most likely to have and which Find deliberately does not look at; every word
   of the argument occurring in a name, which is the "space separated keywords"
   a caller may pass instead of a name; and nothing, which is the first
   article. *)
(* Which article a caller's topic names, -1 naming none.

   THE TOPIC COMES IN AS THE PROGRAM'S TEXT AND IS COMPARED AS THE FILE'S.
   Every name this reader holds - an article's title, a context name, a word of
   the dictionary - is a string of bytes in the page the file was written in,
   and the topic is a string of the program's own.  On a host whose text page
   is 866 and a file written in 437 the two are the same only below 80H, so a
   search that compared them as they stand would find nothing a reader typed
   above ASCII - and would find it silently, by answering "the first article",
   which is what a topic that names nothing gets.  So the topic is converted
   once, here, into the file's page, and everything below it is one page
   against one page.

   It is converted for the three ways of naming an article and not for one of
   them: the exact title, the context name, and the all-words search are three
   answers to the same question and would be a strange thing to hold to
   different spellings of it. *)
PROCEDURE Locate (r: QHReader.Reader; topic: ARRAY OF CHAR; page: INTEGER): INTEGER;
VAR t, i: INTEGER;
    needle, name: ARRAY TITLEMAX OF CHAR;
    found: BOOLEAN;
BEGIN
    t := -1;
    FileText(topic, page, needle);
    IF Strings.Length(needle) > 0 THEN
        t := r.Find(r, needle, QHReader.Exact);
        (* The names are the second place a topic can be named and the first
           place that is indexed, so a name the titles did not answer is looked
           for here.  QHReader does this comparison itself for a link target,
           and it folds case unless the header says the contexts are case
           sensitive - but it keeps that lookup to itself, so a caller looking
           a name up has to make the same rule here.  Folding for a file that
           declares its names case sensitive is the one thing that must not
           happen: `INDEX` and `index` are two names in such a file, and a fold
           would hand back whichever of them the section holds first. *)
        IF (t < 0) & ~r.Sensitive(r) THEN
            i := 0;
            found := FALSE;
            WHILE ~found & (i < r.Contexts(r)) DO
                r.ContextName(r, i, name);
                IF EqFold(name, needle) THEN
                    t := r.ContextTopic(r, i);
                    found := TRUE
                END;
                INC(i)
            END
        END;
        IF t < 0 THEN
            t := r.Find(r, needle, QHReader.AllWords)
        END
    END;
    IF (t < 0) OR (t >= r.Topics(r)) THEN
        t := 0
    END;
    RETURN t
END Locate;


PROCEDURE Open* (file, topic: ARRAY OF CHAR; page: INTEGER);
VAR d: Db;
    v: Win;
    host: TuiWin.Window;
    t, i, free, x, y, w, h: INTEGER;
BEGIN
    d := Acquire(file, page);
    IF d = NIL THEN
        Err("The help file could not be read:", file)
    ELSIF d.r.Locked(d.r) THEN
        (* The file opened and holds nothing to show.  See Err for why this is
           a box and not a window.  The reference on the image is not given
           back here and does not need to be: nothing was put in a window, and
           the registry holds the image for the next caller, which may be a
           program that only wants the header. *)
        Err("The help file's text is locked:", file)
    ELSE
        t := Locate(d.r, topic, d.page);
        (* a window that was closed and not given back is put to use again
           before a new one is made: the desk keeps a closed window on it for
           ever, so a session that opened an article per link would run out of
           desk.  What a closed one holds is its own record and nothing else -
           the article and the image behind it went back when it closed - and
           the reference taken just above is exactly what it needs to begin
           again *)
        free := -1;
        i := 0;
        WHILE (free < 0) & (i < nwin) DO
            IF (wins[i] # NIL) & wins[i].host.closed THEN
                free := i
            END;
            INC(i)
        END;
        IF free >= 0 THEN
            v := wins[free]
        ELSE
            (* A new one, most of the screen and a little down and across from
               the last, so that two of them are two and not one.  The size is
               a request: the desk brings it inside the screen it has. *)
            w := 76;
            h := 20;
            x := 2 + (nwin MOD 5) * 2;
            y := 1 + (nwin MOD 5);
            host := Tui.CreateWindow(x, y, w, h, "");
            v := Create(host);
            TuiWin.AddWidget(host, v);
            (* the box on the title row, and the tell that gives the article
               back.  A help window is the thing that box is for: it holds no
               work of the user's, so closing it asks nothing. *)
            host.closeBox := TRUE;
            host.onClosed := Closed;
            IF nwin < MAXWINS THEN
                wins[nwin] := v;
                INC(nwin)
            END
        END;
        (* The reference taken above is put on the record here and not in the
           branch that made it, because a window that was made has no image at
           all - Create leaves the field NIL and this is the one line that
           fills it, whichever of the two branches the window came from. *)
        v.db := d;
        Load(v, t);
        (* Shown last, and shown even when it was never off: this is what puts
           the keyboard on the widget - the desk tells the widget it has the
           keyboard when the focus moves, and a window made and filled in one
           turn has had no focus change to hear about *)
        Tui.Show(v.host)
    END
END Open;


(* Give back everything this module holds: the images no window is on any more,
   and the error box.  A caller runs it after Tui.Done, which is what gives the
   windows and the widgets back; what is left here is what outlived them. *)
PROCEDURE Done*;
VAR i: INTEGER;
BEGIN
    i := 0;
    WHILE i < MAXDB DO
        IF dbs[i] # NIL THEN
            dbs[i].r.Done(dbs[i].r);
            dbs[i].r := NIL;
            dbs[i] := NIL
        END;
        INC(i)
    END;
    IF err # NIL THEN
        err.Done(err);
        err := NIL
    END
END Done;


END TuiHelp.
