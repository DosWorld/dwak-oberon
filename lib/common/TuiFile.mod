(*
    Public domain (The Unlicense)

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    A File Open / File Save dialog: a drive pane, a directory listing, a name
    field, a type (mask) field and a command row, in the shape the details view
    of every file manager has had since the first one.

    The one shape decision, and why.  This is a TuiWin.Window, not a
    TuiDlg.Dialog.  Tui has one modal slot and it holds a Dialog; a Dialog is
    six rows tall with two message lines, up to four buttons and one field, and
    its AddField replaces rather than adds.  A file dialog is twenty rows with
    two lists, two fields and four buttons, so it cannot be one - and TuiDlg'
    title, line1, line2, buttons and nbtn are private to it, so a module outside
    it cannot draw a box of its own out of the same parts either.  What is left
    is the framework's own pattern: a window the application makes, draws, and
    owns the keyboard of.  DemApp.Step is where that shows - while a file dialog
    is up it does not call Tui.Dispatch at all and hands the event here.

    The box's eight widgets are its window's ring, so the box routes nothing
    itself: the window offers a key to the widget the ring is on, offers a press
    to the widgets in the ring's order until one takes it, and walks the ring on
    Tab.  What is left here is the two things a window cannot know - what a
    button's command means, and what a key no widget wanted means on the stop
    the ring is on.  Enter is that second one, and it is the only key the box
    still reads the ring for.  No framework module is changed by this one, and
    no new widget is needed.

    The two nested questions - the new folder's name and the overwrite
    confirmation - are real TuiDlg boxes, which is what Tui's slot is for.  So
    the modal state is two levels deep and the application has to tell them
    apart: Asks answers whether one of ours is up, and while it is, Step calls
    Ask instead - which offers the event to Dispatch (that is what draws and
    feeds the slot, over everything), turns an Esc into the answer the dialog
    itself would not give, and reports whether that answer was the box's, since
    the overwrite question's Yes is one and its No is not.  This module never
    reaches into the desk, and Tui is never asked what our prompt was for.

    What a row shows.  A name, a size, the packed stamp and the attribute byte's
    letters.  A directory is given the word <DIR> where a file is given a size
    and nothing where a file is given a stamp: a folder's own date cannot be
    pinned the way a file's can, and this box is photographed and compared byte
    for byte, so a column that said "whenever this tree was made" would make
    every photograph of it worthless.

    What a caller says, and what it gets back.  Opt is the whole conversation.
    In: the title of the window, the directory to start in, a suggested name,
    the masks, whether the file must already exist (that is the whole difference
    between Open and Save) and whether more than one name may be taken.  Out:
    the directory the box ended in, the names, how many there are, and whether
    it was answered at all.  A caller that asked for one name reads Opt.name,
    which is names[0] by construction - the invariant is that an accepted answer
    always has nsel >= 1 and name = names[0], so a single-file caller never has
    to look at the array, and a caller that allowed several reads names[0..nsel-1].

    How several names are held.  The marks are a BOOLEAN per list row, inside
    the state record and indexed by the row the listing shows - so there is no
    allocation, no second list, and Marks is cleared by every re-read.  The
    answer is a fixed array in Opt.  Space and Ins mark the row the cursor is on,
    Ctrl+click marks the row the pointer is on, and a plain click clears every
    mark the way it does in every other file dialog.  Typing in the name field
    clears them too, which is what keeps "Enter in the field takes what is
    typed" true.  At most MaxSel names can be taken at once; marking more is
    refused with a message rather than cut short silently.  The row 0 that holds
    ".." is never markable, and in single mode (multi is FALSE) marks are not
    offered at all, so a caller that did not ask for them cannot see any.

    Those marks are the dialog's and not a list's.  TuiList can mark rows too -
    the round after this dialog was written gave it that - but a list marks any
    row it is told to, and the three rules above are rules about what a row of
    this listing means; so the mark cell is still painted here, over the row the
    list drew.  See PaintMarks for the whole of why.

    What takes what.  In single mode Enter or a click on a directory row goes
    into it, on ".." goes up and on a file row puts the name in the field and
    answers the box.  In multi mode a click only moves the cursor and reads the
    name into the field - what the box answers with is the marks - so a click
    never closes it by surprise; Enter is what takes.  In both modes Enter in
    the type field re-reads the listing and Enter in the name field takes what
    is typed.

    What may be taken hold of, and what may not.  The box is modal, so the desk
    is handed no events while it is up and the drag Windows would start on a
    title row is never begun - the title is a title and nothing more.  Moving is
    wanted anyway, so the application asks Grabs whether a press landed on that
    one row and offers that press, and no other, to Tui.Dispatch: the box is
    taken in hand by the same code that drags every other window on the desk, and
    it is centred again by Start the next time it opens.  The bottom right corner
    is deliberately not a grip - the whole layout is fixed numbers, so a resize
    would only misplace every widget in it - and Grabs answers for the title
    alone.

    Nothing here is Unix-specific.  The drive pane has one row on a machine that
    has no drives - Dirs.Drives answers "/" - and the same code walks it and
    switches to it, so the $IF stays in Dirs where it belongs.
*)

MODULE TuiFile;

IMPORT TuiBtns, TuiCanv, TuiDlg, Charset, Dirs, Events, TuiFld, Files, TuiList,
       Strings, TuiPage, TuiTheme, Tui, TuiWidg, TuiWin, Oberon;


CONST

    (* The room a caller's own text gets.  TitleMax is the window's own buffer
       size written out rather than named, because Windows keeps MAXTITLE
       private: a caller that filled a longer buffer would have it cut by the
       window anyway, and sizing the option to the window's limit is what makes
       that the caller's to see rather than a surprise. *)
    TitleMax = 40;
    PathMax  = 260;                     (* a directory *)
    NameMax  = 260;                     (* a base name *)
    MaskMax  = 260;                     (* a mask, as Dirs.MaskMax is sized *)
    MaxEnt   = 512;                     (* entries gathered from one directory *)
    MaxSel   = 32;                      (* names one answer may carry *)

    (* The box: 80x22 at (0, 1) - the whole width of the desk, directly under
       the menu bar, with the status line and one clear row below its bottom
       frame.  Every number below is in the window's own canvas coordinates, so
       nothing here depends on the desk's size and no arithmetic is done on it. *)
    WinX = 0;  WinY = 1;  WinW = 80;  WinH = 22;

    TOOL_Y   = 1;                       (* the toolbar row *)
    UP_X     = 2;                       (* [ Up ] *)
    MKDIR_X  = 11;                      (* [ New folder ] *)
    ROW_PATH = 2;                       (* the directory, as one line *)
    ROW_HEAD = 3;                       (* the column names, above the pane *)

    DRVBOX_X = 2;   DRVBOX_W = 14;      (* the drive pane's frame *)
    DRV_X = 3;      DRV_W = 12;
    FILEBOX_X = 17; FILEBOX_W = 62;     (* the listing's frame *)
    FILE_X = 18;    FILE_W = 60;

    BOX_TOP = 4;    BOX_H = 14;         (* both frames: rows 4..17 *)
    LST_Y = 5;      LST_H = 12;         (* twelve rows on show *)

    LBL_X = 2;                          (* the two labels, flush left.  The
                                           longer of them is "Files of type:",
                                           fourteen cells from x=2, so it ends
                                           at 15 *)
    FLD_X = 18;     FLD_W = 60;         (* and their fields, at the listing's own
                                           column and the same width, so the box
                                           reads down one edge *)
    FLDB_L = 17;    FLDB_R = 78;        (* the bracket either side of a field *)
    ROW_NAME = 18;
    ROW_TYPE = 19;
    PATHW = 78;                         (* a path cut to stop at the frame *)

    BTN_Y = 20;
    OK_X = 58;                          (* [ Open ] / [ Save ] *)
    CANCEL_X = 68;                      (* [ Cancel ], with the two cells the
                                           eight-wide [ Open ] leaves *)
    (* And where Cancel stands when the left button reads [ Choose ].  A button
       is its label plus two pads plus two brackets (TuiBtns.Create), so the
       folder mode's label is two cells wider than Open and Save and the two
       buttons would otherwise be drawn with their frames touching - which is
       the one picture in this box that reads as a fault rather than as a box.
       The two are set together, on every Start and not once: the sample owns
       one FD and opens it in each of the four modes in turn. *)
    CANCEL_DIR_X = 70;

    (* A row of the listing, in its 60 cells.  The mark column is first, so a
       mark is a cell of its own and can never land on a name. *)
    ROWLEN = 60;
    MCOL = 0;
    NCOL = 1;  NW = 26;                 (* the name, cut past this *)
    SCOL = 28; SW = 9;                  (* the size, right aligned *)
    DCOL = 38; DW = 14;                 (* DD-MM-YY HH:MM *)
    ACOL = 53; AW = 4;                  (* the attribute letters *)

    MARK_ON  = "*";
    MARK_OFF = " ";

    (* The commands the window's own buttons carry, and the two answers a
       nested prompt can have.  Both prompts use the same pair: which one is up
       is what `asking` says, so a number never has to mean two things at the
       same moment and the two are always read together. *)
    CMD_UP     = 1;
    CMD_MKDIR  = 2;
    CMD_OK     = 3;
    CMD_CANCEL = 4;
    ANS_YES    = 11;                    (* the first button: OK, and Yes *)
    ANS_NO     = 12;                    (* the second: Cancel, and No *)

    (* Which of our own prompts holds the desk's slot. *)
    ASK_NONE   = 0;
    ASK_FOLDER = 1;
    ASK_OVER   = 2;

    (* The eight stops of the window's ring, in the order the window is given
       them: the order an event is offered in and the order Tab walks.  They are
       only names for "which widget" here - the walk itself is the window's, and
       nothing in this module counts round a ring any more.  The arrows belong
       to the two lists and are never a ring key. *)
    R_DRIVES = 0;  R_FILES = 1;  R_NAME = 2;  R_TYPE = 3;
    R_UP     = 4;  R_MKDIR = 5;  R_OK   = 6;  R_CANCEL = 7;

    (* The same ring with the two fields taken out: the two panes keep the
       numbers they have above - the drives first and the listing second,
       because the two fields are what stands between the listing and the four
       buttons and they are the two things this ring does not have - so "the
       ring is on the listing" stays one comparison in both modes, and only the
       buttons are given a second set of names. *)
    R_D_UP = 2;  R_D_MKDIR = 3;  R_D_OK = 4;  R_D_CANCEL = 5;

    (* How much a message may say.  Tui's status line takes 96 bytes and cuts
       what does not fit, so this is room to spare rather than a second limit. *)
    MSGLEN = 160;


TYPE

    (* What the caller says and what it is told.  The answer is the option
       record itself, because the directory the box ended in is one of the
       things the caller wants to know: Start copies the record in, the box
       works on its own copy, and Answer copies it out.

       The caller's own record is therefore written in exactly one place, which
       is what keeps a refused accept - or a mask typed into the box and never
       accepted - from leaking into it.  A cancel does not undo what the box did
       to its copy: the path line may have moved and the mask may have been
       re-read, and Answer reports both.  `accepted` is what says whether any of
       it means anything, and it is FALSE on a cancel, so the rest is a record
       of where the box was when it was let go rather than an answer. *)
    Opt* = RECORD
        title*:     ARRAY TitleMax OF CHAR;     (* in *)
        dir*:       ARRAY PathMax OF CHAR;      (* in: where to start; out: where it ended *)
        name*:      ARRAY NameMax OF CHAR;      (* in: a suggestion; out: names[0] *)
        names*:     ARRAY MaxSel, NameMax OF CHAR;   (* out *)
        nsel*:      INTEGER;                    (* out: how many names, 0 on a cancel *)
        masks*:     ARRAY MaskMax OF CHAR;      (* in, and out: what was in force *)
        mustExist*: BOOLEAN;                    (* in: TRUE is Open, FALSE is Save *)
        multi*:     BOOLEAN;                    (* in: may more than one be taken *)
        dirs*:      BOOLEAN;                    (* in: the answer is the directory, not a file *)
        accepted*:  BOOLEAN                     (* out: FALSE means it was cancelled *)
    END;

    (* The whole state of one dialog.  No part of it is a module variable: two
       of these can exist and neither knows about the other, which is the rule
       the demo's own state follows. *)
    FD* = RECORD
        win*:     TuiWin.Window;
        files*:   TuiList.ListBox;
        drives*:  TuiList.ListBox;
        nameF*:   TuiFld.Field;
        maskF*:   TuiFld.Field;
        upb*, mkdir*, okb*, cancel*: TuiBtns.Button;
        ents:     ARRAY MaxEnt OF Dirs.Entry;   (* gathered, sorted, then fed *)
        idx:      ARRAY MaxEnt OF INTEGER;      (* the sorted order of ents *)
        marks:    ARRAY MaxEnt + 1 OF BOOLEAN;  (* by list row; row 0 is ".." *)
        nent, dirs, first, nmarks: INTEGER;
        trunc:    BOOLEAN;                      (* more entries than MaxEnt *)
        o*:       Opt;                          (* and the answer, once there is one *)
        done*:    BOOLEAN;
        asking:   INTEGER;                      (* which prompt, if either *)
        overN:    INTEGER;                      (* names the question is about *)
        prompt*:  TuiDlg.Dialog;               (* ours; freed with the rest *)
        dlg*:     TuiDlg.Dialog;
        busy:     BOOLEAN                       (* up, and taking every event *)
    END;


(* A string onto the end of another.  Strings.Append does this and answers
   whether it all fitted, which cannot be called as a statement - so the answer
   is dropped here, which is the same thing a caller that ignored it would do. *)
PROCEDURE Add (s: ARRAY OF CHAR; VAR d: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
    n := Strings.Length(d);
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) & (n < LEN(d) - 1) DO
        d[n] := s[i];
        INC(n); INC(i)
    END;
    IF LEN(d) > 0 THEN d[n] := 0X END
END Add;


(* A row buffer filled with spaces.  A list row must fill every cell it shows,
   or what was drawn in the row before shows through where the new text is
   shorter. *)
PROCEDURE Blank (VAR text: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
    i := 0;
    WHILE i < LEN(text) - 1 DO
        text[i] := " ";
        INC(i)
    END;
    IF LEN(text) > 0 THEN text[LEN(text) - 1] := 0X END
END Blank;


(* The first n characters of s at pos, and everything of s at pos. *)
PROCEDURE PutN (s: ARRAY OF CHAR; pos, n: INTEGER; VAR d: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (i < n) & (s[i] # 0X) & (pos + i < LEN(d) - 1) DO
        IF pos + i >= 0 THEN d[pos + i] := s[i] END;
        INC(i)
    END
END PutN;


PROCEDURE Put (s: ARRAY OF CHAR; pos: INTEGER; VAR d: ARRAY OF CHAR);
BEGIN
    PutN(s, pos, LEN(s), d)
END Put;


(* The same, ending at pos + w - 1: what a column of numbers is made of.  A
   number wider than its column keeps its left end, which is the end that says
   how big it is. *)
PROCEDURE PutRight (s: ARRAY OF CHAR; pos, w: INTEGER; VAR d: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
    n := Strings.Length(s);
    IF n > w THEN
        PutN(s, pos, w, d)
    ELSE
        Put(s, pos + w - n, d)
    END
END PutRight;


(* Cut a byte string back to the last whole character.

   Only the text page can say where a character ends, and on the one-byte pages
   there is nothing to cut: every string this box shows is then one byte a
   character and a cut is already a character boundary.  On a multi-byte page a
   buffer one byte too small leaves half a sequence behind, and half a sequence
   is not a shorter string - it is a broken one, drawn as one replacement
   glyph.  A path cut at the frame is exactly where that happens. *)
PROCEDURE CutChar (VAR s: ARRAY OF CHAR);
VAR i, n, cp, len: INTEGER; done: BOOLEAN;
BEGIN
    IF TuiPage.Text() = Charset.PageUtf8 THEN
        n := Strings.Length(s);
        i := 0; done := FALSE;
        WHILE (i < n) & ~done DO
            Charset.Decode(s, i, Charset.PageUtf8, cp, len);
            IF i + len > n THEN
                s[i] := 0X;              (* the last character is cut: drop it *)
                done := TRUE
            ELSE
                INC(i, len)
            END
        END
    END
END CutChar;


(* The name, into a column n bytes wide, and never cut inside a character.

   THE COLUMNS AFTER THE NAME MOVE LEFT ON A MULTI-BYTE PAGE, and that is a
   limitation of this row rather than of the drawing.  A row is a byte buffer of
   ROWLEN and the width of a column in it is a number of bytes; a canvas cell is
   a code point, and on a page where a character is two bytes the two counts are
   not the same number.  The size, the stamp and the letters are written at
   their own byte positions, as they always were, so they land that many cells
   further left than the header above them - which is what a file manager with a
   proportional font looks like, and is a great deal better than the alternative,
   which is a name drawn as somebody else's letters.

   Putting them back where the header says would need the row to hold n cells of
   name in up to four times n bytes, and the row has not got them (TuiList gives
   a row ITEMLEN bytes and this box fills ROWLEN of them).  A cell column cannot
   be pinned in a byte buffer wider than it is, so the honest answer is to move
   the columns and to say so here. *)
PROCEDURE PutName (s: ARRAY OF CHAR; pos, n: INTEGER; VAR d: ARRAY OF CHAR);
VAR i, j, cp, len, full: INTEGER;
BEGIN
    i := 0; full := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) & (full = 0) DO
        len := 1;
        IF TuiPage.Text() = Charset.PageUtf8 THEN
            Charset.Decode(s, i, Charset.PageUtf8, cp, len)
        END;
        IF (i + len > n) OR (pos + i + len > LEN(d) - 1) THEN
            full := 1                   (* the whole of it does not fit *)
        ELSE
            FOR j := 0 TO len - 1 DO d[pos + i + j] := s[i + j] END;
            INC(i, len)
        END
    END
END PutName;


(* Two digits of v at pos.  v is taken modulo 100 by the caller. *)
PROCEDURE Two (v, pos: INTEGER; VAR s: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
    n := v MOD 100;
    IF n < 0 THEN n := 0 END;
    IF (pos >= 0) & (pos + 1 < LEN(s)) THEN
        s[pos] := CHR(ORD("0") + n DIV 10);
        s[pos + 1] := CHR(ORD("0") + n MOD 10)
    END
END Two;


(* The packed DOS date and time Dirs and Files both speak, as DD-MM-YY HH:MM.
   The packing is ArchFile's: five bits of day, four of month, seven of year
   from 1980, five of hour, six of minute, five of second halved. *)
PROCEDURE DateText (t: INTEGER; VAR s: ARRAY OF CHAR);
VAR y, m, d, h, mi: INTEGER;
BEGIN
    y := t DIV 2000000H + 1980;
    m := t DIV 200000H MOD 10H;
    d := t DIV 10000H MOD 20H;
    h := t DIV 800H MOD 20H;
    mi := t DIV 20H MOD 40H;
    Two(y, 0, s);
    s[2] := "-";
    Two(m, 3, s);
    s[5] := "-";
    Two(d, 6, s);
    s[8] := " ";
    Two(h, 9, s);
    s[11] := ":";
    Two(mi, 12, s);
    s[14] := 0X
END DateText;


(* The attribute byte as the letters the header names.  A directory answers D
   and nothing else on DOS and Windows, which round 10 measured; the other
   letters are there because Unix synthesises its byte from what it has and a
   browser should show what it is given rather than a subset of it. *)
PROCEDURE AttrText (attr: INTEGER; VAR s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
    i := 0;
    IF Dirs.AttrReadOnly IN BITS(attr) THEN s[i] := "R"; INC(i) END;
    IF Dirs.AttrHidden IN BITS(attr) THEN s[i] := "H"; INC(i) END;
    IF Dirs.AttrSystem IN BITS(attr) THEN s[i] := "S"; INC(i) END;
    IF Dirs.AttrVolume IN BITS(attr) THEN s[i] := "V"; INC(i) END;
    IF Dirs.AttrDir IN BITS(attr) THEN s[i] := "D"; INC(i) END;
    IF Dirs.AttrArchive IN BITS(attr) THEN s[i] := "A"; INC(i) END;
    s[i] := 0X
END AttrText;


(* Names compared the way a user reads them: without case.  The walk's own
   order is the operating system's, and on DOS it is the 8.3 order of the
   directory - neither is a thing to show somebody looking for a file. *)
PROCEDURE NameCompare (a, b: ARRAY OF CHAR): INTEGER;
VAR i, r: INTEGER; ca, cb: CHAR;
BEGIN
    i := 0; r := 0;
    WHILE (r = 0) & (i < LEN(a)) & (i < LEN(b)) & (a[i] # 0X) & (b[i] # 0X) DO
        ca := a[i]; cb := b[i];
        Strings.Cap(ca); Strings.Cap(cb);
        IF ca # cb THEN
            IF ca < cb THEN r := -1 ELSE r := 1 END
        END;
        INC(i)
    END;
    IF r = 0 THEN
        IF i >= LEN(a) THEN
            IF i < LEN(b) THEN r := -1 END
        ELSIF a[i] # 0X THEN
            r := 1
        ELSIF (i < LEN(b)) & (b[i] # 0X) THEN
            r := -1
        END
    END;
    RETURN r
END NameCompare;


(* The status line: what is in the directory, how much of it is marked, and the
   three keys that are not the arrows.  Every message the box puts up is
   replaced by this the moment the listing is read again. *)
PROCEDURE Report (VAR fd: FD);
VAR s, t: ARRAY MSGLEN OF CHAR;
BEGIN
    s[0] := 0X;
    Strings.FromInt(fd.dirs, t); Add(t, s);
    IF fd.dirs = 1 THEN Add(" folder, ", s) ELSE Add(" folders, ", s) END;
    Strings.FromInt(fd.nent - fd.dirs, t); Add(t, s);
    IF fd.nent - fd.dirs = 1 THEN Add(" file", s) ELSE Add(" files", s) END;
    IF fd.o.multi THEN
        Add("   ", s);
        Strings.FromInt(fd.nmarks, t); Add(t, s);
        Add(" marked", s)
    END;
    IF fd.trunc THEN
        Add("   (only the first 512 entries)", s)
    END;
    IF fd.o.dirs THEN
        Add("   Enter walks in, Choose answers, Esc cancels", s)
    ELSE
        Add("   Enter takes, Esc cancels", s)
    END;
    Tui.SetStatus(s)
END Report;


PROCEDURE Message (s: ARRAY OF CHAR);
BEGIN
    Tui.SetStatus(s)
END Message;


(* A message and the name it is about, which is what every refusal says. *)
PROCEDURE Say2 (a, b: ARRAY OF CHAR);
VAR s: ARRAY MSGLEN OF CHAR;
BEGIN
    s[0] := 0X;
    Add(a, s);
    Add(b, s);
    Tui.SetStatus(s)
END Say2;


PROCEDURE ClearMarks (VAR fd: FD);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO MaxEnt DO fd.marks[i] := FALSE END;
    fd.nmarks := 0
END ClearMarks;


(* The entry a list row shows, or -1 for the ".." row and for a row past the
   end.  Rows 0..first-1 are the one synthetic row, so the mapping is the same
   whether or not the directory has a parent. *)
PROCEDURE RowEntry (VAR fd: FD; row: INTEGER): INTEGER;
VAR r, k: INTEGER;
BEGIN
    r := -1;
    k := row - fd.first;
    IF (k >= 0) & (k < fd.nent) THEN r := fd.idx[k] END;
    RETURN r
END RowEntry;


PROCEDURE RowUp (VAR text: ARRAY OF CHAR);
BEGIN
    Blank(text);
    Put("..", NCOL, text)
END RowUp;


(* One entry as one row of the listing.

   A directory is given the word <DIR> where a file is given its size and
   nothing where a file is given its stamp.  The second of those is the first
   one carried a step further: a folder's own date cannot be pinned the way a
   file's can, because Files.SetFTime takes a file handle and no platform here
   will give one for a directory - and a dump of this box is compared byte for
   byte between two machines, so a column that answered "whenever this tree was
   made" would make every dump of the box worth nothing.  Nothing the box does
   reads a folder's stamp, so the column is the one place the omission shows. *)
PROCEDURE RowText (VAR e: Dirs.Entry; VAR text: ARRAY OF CHAR);
VAR s: ARRAY 32 OF CHAR;
BEGIN
    Blank(text);
    PutName(e.name, NCOL, NW, text);
    IF e.isDir THEN
        PutRight("<DIR>", SCOL, SW, text)
    ELSE
        Strings.FromInt(e.size, s);
        PutRight(s, SCOL, SW, text);
        DateText(e.time, s);
        Put(s, DCOL, text)
    END;
    AttrText(e.attr, s);
    Put(s, ACOL, text)
END RowText;


(* The words above the pane, in the same buffer a row is built in, so the
   columns of the two cannot come apart. *)
PROCEDURE Header (VAR text: ARRAY OF CHAR);
BEGIN
    Blank(text);
    Put("Name", NCOL, text);
    PutRight("Size", SCOL, SW, text);
    Put("Modified", DCOL, text);
    Put("Attr", ACOL, text)
END Header;


(* The drive pane.  Dirs.Drives answers the names separated by ";", which is the
   shape Dirs.MatchAny already takes its masks in, so splitting one is the same
   walk over a terminator and a separator.  A machine that names no drive at all
   gets the current directory as its one row rather than an empty box. *)
PROCEDURE Load (VAR fd: FD);
VAR s: ARRAY 128 OF CHAR; name: ARRAY 16 OF CHAR;
    cur, i, j, n: INTEGER;
BEGIN
    fd.drives.Clear(fd.drives);
    n := Dirs.Drives(s, cur);
    i := 0;
    WHILE s[i] # 0X DO
        j := 0;
        WHILE (s[i] # 0X) & (s[i] # ";") DO
            IF j < 15 THEN name[j] := s[i]; INC(j) END;
            INC(i)
        END;
        name[j] := 0X;
        fd.drives.Add(fd.drives, name);
        IF s[i] = ";" THEN INC(i) END
    END;
    IF n = 0 THEN fd.drives.Add(fd.drives, ".") END;
    IF cur >= 0 THEN fd.drives.Select(fd.drives, cur) END
END Load;


(* Whether a is to be shown above b: directories first, then by name.  It takes
   the two entries by index rather than by value, because a walk of five hundred
   entries would otherwise copy half a megabyte to sort itself. *)
PROCEDURE Before (VAR fd: FD; i, j: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    IF fd.ents[i].isDir # fd.ents[j].isDir THEN
        r := fd.ents[i].isDir
    ELSE
        r := NameCompare(fd.ents[i].name, fd.ents[j].name) < 0
    END;
    RETURN r
END Before;


(* An insertion sort over an index array.  The entries themselves are never
   moved: the listing and the marks are both indexed by row, and a row that
   changes what it holds when a file is added would be a mark on the wrong
   file. *)
PROCEDURE Sort (VAR fd: FD);
VAR i, j, k: INTEGER;
BEGIN
    FOR i := 0 TO fd.nent - 1 DO fd.idx[i] := i END;
    FOR i := 1 TO fd.nent - 1 DO
        k := fd.idx[i];
        j := i - 1;
        WHILE (j >= 0) & Before(fd, k, fd.idx[j]) DO
            fd.idx[j + 1] := fd.idx[j];
            DEC(j)
        END;
        fd.idx[j + 1] := k
    END
END Sort;


(* Whether the mask takes this file.  An empty mask takes everything, and every
   directory is kept whatever the mask says - which is what every file dialog
   does, and what the two panes exist for: a mask that hid the directories would
   leave no way into them.

   A box that is choosing a directory has no mask to apply and no field to type
   one into, so it takes every name there is: what the caller asked for is a
   folder, and a folder is not what a mask is about. *)
PROCEDURE MaskOk (VAR fd: FD; name: ARRAY OF CHAR): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := fd.o.dirs OR (fd.o.masks[0] = 0X) OR Dirs.MatchAny(name, fd.o.masks);
    RETURN r
END MaskOk;


(* One directory into fd.ents.

   The walk is Dirs.FindFirst, and which call of the platform stands behind it
   is Dirs's answer and not this box's: on Windows that walk is FindFirstFileW
   and the name arrives as the UTF-8 the canvas draws in, and on every other
   target it is the platform's own bytes, which are what that host's console
   draws.  There used to be two procedures here, a byte walk and a wide one
   with a UTF-16 to UTF-8 conversion between them, and a $IF to choose; the
   choice moved down into Dirs, where the rest of the platform split already
   lives, and this is one walk again.

   The three rules are this box's own and are why the gather exists at all: a
   directory is taken whatever the mask says, the count is capped, and the cap
   is reported rather than hidden. *)
PROCEDURE Gather (VAR fd: FD);
VAR
    f: Dirs.Finder;
    e: Dirs.Entry;
    more: BOOLEAN;
BEGIN
    more := Dirs.FindFirst(f, fd.o.dir, "*", e);
    WHILE more DO
        IF e.isDir OR MaskOk(fd, e.name) THEN
            IF fd.nent < MaxEnt THEN
                fd.ents[fd.nent] := e;
                IF e.isDir THEN INC(fd.dirs) END;
                INC(fd.nent)
            ELSE
                fd.trunc := TRUE
            END
        END;
        more := Dirs.FindNext(f, e)
    END;
    Dirs.FindClose(f)
END Gather;

(* Read the directory into the state and feed the listing.  Every re-read goes
   through here - a navigation, a mask change, a new folder - so the marks, the
   order and the status line are one thing rather than three. *)
PROCEDURE Read (VAR fd: FD);
VAR
    text: ARRAY ROWLEN OF CHAR;
    up: ARRAY PathMax OF CHAR;
    i: INTEGER;
BEGIN
    fd.nent := 0; fd.dirs := 0; fd.trunc := FALSE;
    ClearMarks(fd);

    Gather(fd);
    Sort(fd);

    (* ".." is a row the box makes up, and it is not offered at a root, where
       the parent is the directory itself. *)
    Dirs.Parent(fd.o.dir, up);
    IF Strings.Equal(up, fd.o.dir) THEN fd.first := 0 ELSE fd.first := 1 END;

    fd.files.Clear(fd.files);
    IF fd.first = 1 THEN
        RowUp(text);
        fd.files.Add(fd.files, text)
    END;
    FOR i := 0 TO fd.nent - 1 DO
        RowText(fd.ents[fd.idx[i]], text);
        fd.files.Add(fd.files, text)
    END;
    fd.files.Select(fd.files, fd.first);
    Report(fd)
END Read;


(* The mark column, painted over the rows the list has just drawn.

   TuiList grew marks of its own in the round after this dialog was written, so
   the reason this is here is no longer that a list cannot carry them.  It is
   that the marks this listing wants are not the marks any list would offer.  A
   row here is not just a row: the ".." at the top is a way out of the directory
   and not a name, a folder is a name that Accept would walk into rather than
   take, and at most MaxSel of the rest may be taken at once.  Those three rules
   belong to a file dialog and to nothing else, and they are answered where they
   are read (ToggleMark) rather than where they are drawn.

   So the column stays where it was.  The mark cell is the first cell of the
   row's own text, which RowText composes and ROWLEN and NCOL say the shape of,
   and painting it is one cell's write after the list has drawn - in the pair
   the list drew that row in, which is why the attribute is read back out of the
   cell rather than worked out again from the row and the selection.  A list
   that could mark rows would carry a second selection through every caller that
   never wanted one; what it would have to grow to take this over is a "may I
   mark this row?" hook, and with one this procedure would be SetMulti plus that
   hook, with the three rules above moved into it unchanged. *)
PROCEDURE PaintMarks (VAR fd: FD);
VAR i, k, a, row: INTEGER;
BEGIN
    IF fd.o.multi THEN
        FOR i := 0 TO fd.nent - 1 DO
            row := fd.first + i;
            k := row - fd.files.top;
            IF (k >= 0) & (k < fd.files.height) THEN
                a := fd.win.canvas.AttrAt(fd.win.canvas, fd.files.x + MCOL,
                                          fd.files.y + k);
                IF fd.marks[row] THEN
                    fd.win.canvas.Put(fd.win.canvas, fd.files.x + MCOL,
                                      fd.files.y + k, MARK_ON, a)
                ELSE
                    fd.win.canvas.Put(fd.win.canvas, fd.files.x + MCOL,
                                      fd.files.y + k, MARK_OFF, a)
                END
            END
        END
    END
END PaintMarks;


(* Everything the box is made of, into its own canvas.  The frame is Windows'
   and is redrawn every frame; this is the body, and it is redrawn whole every
   time because a shorter row would not cover a longer one. *)
PROCEDURE Paint (VAR fd: FD);
VAR
    c: TuiCanv.Canvas;
    fa, ta: INTEGER;
    text: ARRAY ROWLEN OF CHAR;
    path: ARRAY PATHW OF CHAR;
BEGIN
    c := fd.win.canvas;
    fd.win.Refresh(fd.win);             (* a clean body to draw the box on *)

    (* The panes are rules drawn on the body, not bands round it.  The pair is
       the window's own body pair - the one Refresh has just filled with - so
       the frame gives up the glyphs and no colour of its own, and what is left
       of it is a thin line.  A pair of its own, the way a dialog's frame has
       one, would make the two panes the loudest thing in the box rather than
       the quietest: the eye should land on the listing, not on the rule round
       it.  The label rides on that rule in the same pair, so it reads as a gap
       in the line rather than as a strip across it. *)
    fa := TuiTheme.Attr(TuiTheme.Frame);
    ta := TuiTheme.Attr(TuiTheme.DialogText);

    c.Frame(c, DRVBOX_X, BOX_TOP, DRVBOX_W, BOX_H, fa, FALSE);
    c.Frame(c, FILEBOX_X, BOX_TOP, FILEBOX_W, BOX_H, fa, FALSE);
    c.Print(c, DRVBOX_X + 2, BOX_TOP, "Drives", fa);

    Header(text);
    c.Print(c, FILE_X, ROW_HEAD, text, ta);

    Strings.Copy(fd.o.dir, path);       (* cut, so it stops at the frame *)
    CutChar(path);                      (* and cut again, at a character *)
    c.Print(c, LBL_X, ROW_PATH, path, ta);
    (* Two rows of the box are the two fields', and a mode that has neither
       leaves them empty: nothing is drawn there rather than something else,
       because the box this mode is a copy of is the box whose geometry the
       tabs of this sample are compared by. *)
    IF ~fd.o.dirs THEN
        c.Print(c, LBL_X, ROW_NAME, "File name:", ta);
        c.Print(c, LBL_X, ROW_TYPE, "Files of type:", ta)
    END;

    (* A bracket a side rather than a frame.  A frame is three rows and a field
       is one, so the two of them framed would take the rows the buttons sit on.
       The bracket is what makes an empty field visible at all: a field paints
       its own band and nothing more, so an empty one is a blank row, and without
       something around it the label reads as running into whatever is next.  It
       is drawn before the fields because their band is inside it - and because
       the band is the wider of the two, the pair can be drawn in either order
       and this one is the one that does not depend on that. *)
    IF ~fd.o.dirs THEN
        c.Put(c, FLDB_L, ROW_NAME, "[", ta);
        c.Put(c, FLDB_R, ROW_NAME, "]", ta);
        c.Put(c, FLDB_L, ROW_TYPE, "[", ta);
        c.Put(c, FLDB_R, ROW_TYPE, "]", ta)
    END;

    fd.drives.draw(fd.drives, c);
    fd.files.draw(fd.files, c);
    fd.nameF.draw(fd.nameF, c);
    fd.maskF.draw(fd.maskF, c);
    fd.upb.draw(fd.upb, c);
    fd.mkdir.draw(fd.mkdir, c);
    fd.okb.draw(fd.okb, c);
    fd.cancel.draw(fd.cancel, c);

    PaintMarks(fd)
END Paint;


(* Go to a directory and read it.  The name field is emptied, because a name
   typed for the directory that was on show is not a name for this one, and a
   field that kept it would answer with it the moment Enter was pressed. *)
PROCEDURE Into (VAR fd: FD; path: ARRAY OF CHAR);
BEGIN
    Strings.Copy(path, fd.o.dir);
    fd.nameF.SetText(fd.nameF, "");
    Read(fd)
END Into;


PROCEDURE Up (VAR fd: FD);
VAR up: ARRAY PathMax OF CHAR;
BEGIN
    Dirs.Parent(fd.o.dir, up);
    IF ~Strings.Equal(up, fd.o.dir) THEN Into(fd, up) END
END Up;


(* Switch to the drive a row of the pane names.  The name is the root of that
   drive: Join puts the separator after "C:" and leaves the one "/" already
   ends with alone, so both platforms come out of the same line. *)
PROCEDURE DriveTo (VAR fd: FD; i: INTEGER);
VAR name: ARRAY 16 OF CHAR; full: ARRAY PathMax OF CHAR;
BEGIN
    IF (i >= 0) & (i < fd.drives.count) THEN
        fd.drives.Get(fd.drives, i, name);
        Dirs.Join(name, "", full);
        Into(fd, full)
    END
END DriveTo;


(* Mark the row, or unmark it.  A row that is ".." is not markable, and neither
   is a directory: the answer is a set of files, and a marked directory would be
   a name that Accept then treats as a way into it rather than as a name - one
   Enter on a marked folder would walk into it.  Both are refused with a word
   rather than silently, so the key never looks dead. *)
PROCEDURE ToggleMark (VAR fd: FD; row: INTEGER);
VAR k: INTEGER;
BEGIN
    k := RowEntry(fd, row);
    IF k < 0 THEN
        IF row >= 0 THEN Message("The row above is not a file to take") END
    ELSIF fd.ents[k].isDir THEN
        Say2("A folder is not a file to take: ", fd.ents[k].name)
    ELSIF fd.marks[row] THEN
        fd.marks[row] := FALSE;
        DEC(fd.nmarks);
        Report(fd)
    ELSE
        fd.marks[row] := TRUE;
        INC(fd.nmarks);
        Report(fd)
    END
END ToggleMark;


(* Space and Ins mark the row the cursor is on.  They are offered to the
   listing only in multi mode, so a caller that asked for one name never sees a
   mark appear; and only while the ring is on the listing, so Space in a field
   is still a space. *)
PROCEDURE MarkKey (VAR fd: FD; VAR e: Events.Event): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := fd.o.multi & (TuiWin.Ring(fd.win) = R_FILES) &
         (Events.IsKey(e, Events.K_SPACE) OR Events.IsKey(e, Events.K_INS));
    IF r THEN
        ToggleMark(fd, fd.files.sel);
        e.kind := Events.NONE
    END;
    RETURN r
END MarkKey;


(* The two ways the box ends, and the only two places `accepted` is written.
   It is a field of the option record and not a field of the state, because it
   is part of the answer: a caller reads it out of what Answer copied back, and
   it is the one thing there that says whether the rest means anything.  It is
   FALSE on the way in - a caller has not accepted anything yet - so a cancel
   leaves what Start put there. *)
PROCEDURE Cancel (VAR fd: FD);
BEGIN
    fd.o.accepted := FALSE;
    fd.done := TRUE;
    Tui.Hide(fd.win)
END Cancel;


(* The box is answered with n names that are already in fd.o.names. *)
PROCEDURE Finish (VAR fd: FD; n: INTEGER);
BEGIN
    fd.o.nsel := n;
    Strings.Copy(fd.o.names[0], fd.o.name);
    fd.o.accepted := TRUE;
    fd.done := TRUE;
    Tui.Hide(fd.win)
END Finish;


(* The names the box means by "the answer", into fd.o.names, and how many there
   are.  In multi mode the marked rows are the whole of it; in single mode it is
   the name field, or the row the cursor is on when the field is empty - which
   is what makes Enter take what is on show without typing it first.

   Writing them straight into the caller's record is safe: they went into
   fd.o.names, and fd.o is copied back to the caller only by Answer, so an
   accept that is refused here leaves the caller's own record untouched. *)
PROCEDURE Collect (VAR fd: FD): INTEGER;
VAR n, k, row: INTEGER;
BEGIN
    n := 0;
    IF fd.o.multi & (fd.nmarks > 0) THEN
        FOR row := fd.first TO fd.first + fd.nent - 1 DO
            IF fd.marks[row] & (n < MaxSel) THEN
                k := RowEntry(fd, row);
                IF k >= 0 THEN
                    Strings.Copy(fd.ents[k].name, fd.o.names[n]);
                    INC(n)
                END
            END
        END
    ELSE
        fd.nameF.GetText(fd.nameF, fd.o.names[0]);
        Strings.Trim(fd.o.names[0]);
        IF fd.o.names[0][0] = 0X THEN
            k := RowEntry(fd, fd.files.sel);
            IF k >= 0 THEN
                Strings.Copy(fd.ents[k].name, fd.o.names[0])
            END
        END;
        IF fd.o.names[0][0] # 0X THEN n := 1 END
    END;
    RETURN n
END Collect;


(* The first of n names for which Files.FileExists answers `want`, or -1 when
   there is none.  One walk answers both questions the accept has to ask: what
   is missing, when the file must already be there, and what is there, when it
   must not. *)
PROCEDURE FirstOne (VAR fd: FD; n: INTEGER; want: BOOLEAN): INTEGER;
VAR i, found: INTEGER; full: ARRAY PathMax OF CHAR;
BEGIN
    found := -1; i := 0;
    WHILE (found < 0) & (i < n) DO
        Dirs.Join(fd.o.dir, fd.o.names[i], full);
        IF Files.FileExists(full) = want THEN found := i END;
        INC(i)
    END;
    RETURN found
END FirstOne;


(* Whether a name names a directory of the directory the box is in. *)
PROCEDURE DirName (VAR fd: FD; name: ARRAY OF CHAR): BOOLEAN;
VAR r: BOOLEAN; full: ARRAY PathMax OF CHAR;
BEGIN
    Dirs.Join(fd.o.dir, name, full);
    r := Files.ExistsDir(full);
    RETURN r
END DirName;


(* The overwrite question.  A name the caller may overwrite and that is there
   is the one thing a Save has to ask about, and it is asked once for the whole
   set rather than once per name: a question asked four times is a question
   nobody reads. *)
PROCEDURE AskOver (VAR fd: FD; i, n: INTEGER);
VAR s, t: ARRAY MSGLEN OF CHAR;
BEGIN
    fd.overN := n;
    s[0] := 0X;
    IF n = 1 THEN
        Add(fd.o.names[i], s)
    ELSE
        Strings.FromInt(n, t);
        Add(t, s);
        Add(" names, and one of them", s)
    END;
    Add(" is already there", s);
    fd.dlg.SetText(fd.dlg, s, "Overwrite?");
    Tui.SetDialog(fd.dlg);
    fd.asking := ASK_OVER
END AskOver;


(* What OK means, and the whole of the difference between Open and Save.
   A single name that is a directory is a way into it rather than an answer;
   with mustExist a name that is not there is refused and the box stays; without
   it a name that is there is asked about; and anything else is the answer. *)
PROCEDURE Accept (VAR fd: FD);
VAR n, i: INTEGER; full: ARRAY PathMax OF CHAR;
BEGIN
    IF fd.o.dirs THEN
        (* There is nothing to collect: the answer is the directory the box is
           in, and it goes out through the same two fields every other answer
           does - Finish is what sets nsel, name, accepted and done - so a
           caller reads it exactly as it reads a file name, and the rule that
           an accepted answer has one name holds here too. *)
        Strings.Copy(fd.o.dir, fd.o.names[0]);
        Finish(fd, 1)
    ELSE
        n := Collect(fd);
        IF fd.nmarks > MaxSel THEN
            Message("Too many rows are marked: at most 32 names can be taken")
        ELSIF n = 0 THEN
            Message("Type a name in the box, or choose one from the list")
        ELSIF (n = 1) & DirName(fd, fd.o.names[0]) THEN
            Dirs.Join(fd.o.dir, fd.o.names[0], full);
            Into(fd, full)
        ELSE
            i := FirstOne(fd, n, ~fd.o.mustExist);
            IF i < 0 THEN
                Finish(fd, n)
            ELSIF fd.o.mustExist THEN
                Say2("No such file: ", fd.o.names[i])
            ELSE
                AskOver(fd, i, n)
            END
        END
    END
END Accept;


PROCEDURE MakeFolder (VAR fd: FD);
BEGIN
    fd.prompt.SetFieldText(fd.prompt, "");
    Tui.SetDialog(fd.prompt);
    fd.asking := ASK_FOLDER
END MakeFolder;


(* What a button's command means.  A button carries an id and never fires
   anything itself, so this is the one place the four ids are read. *)
PROCEDURE Press (VAR fd: FD; cmd: INTEGER);
BEGIN
    IF cmd = CMD_UP THEN Up(fd)
    ELSIF cmd = CMD_MKDIR THEN MakeFolder(fd)
    ELSIF cmd = CMD_OK THEN Accept(fd)
    ELSIF cmd = CMD_CANCEL THEN Cancel(fd)
    END
END Press;


(* Enter, or a click in single mode, on the row the cursor is on. *)
PROCEDURE Take (VAR fd: FD; row: INTEGER);
VAR k: INTEGER; full: ARRAY PathMax OF CHAR;
BEGIN
    k := RowEntry(fd, row);
    IF k < 0 THEN
        IF fd.first = 1 THEN Up(fd) END
    ELSIF fd.ents[k].isDir THEN
        Dirs.Join(fd.o.dir, fd.ents[k].name, full);
        Into(fd, full)
    ELSIF fd.o.dirs THEN
        (* A file is not an answer to "which folder": the row is one to walk
           past, and the listing's own click has already moved the cursor onto
           it.  Nothing happens here on purpose - the box stays up. *)
    ELSE
        (* Enter takes the row in either mode.  In multi mode Collect reads the
           marks first and this name only when there are none, so one Enter on a
           file row with marks on is the whole answer, and one without them
           takes the row the cursor is on - which is what "Enter is what takes"
           has to mean if a click in that mode is only a cursor move. *)
        fd.nameF.SetText(fd.nameF, fd.ents[k].name);
        Accept(fd)
    END
END Take;


(* A click in multi mode: the cursor lands and the name is shown, and nothing
   is answered.  A box that closed on the first click would be a box nobody
   could mark a second file in. *)
PROCEDURE Cursor (VAR fd: FD; row: INTEGER);
VAR k: INTEGER;
BEGIN
    k := RowEntry(fd, row);
    IF k >= 0 THEN
        fd.nameF.SetText(fd.nameF, fd.ents[k].name)
    END
END Cursor;


(* Whether the press was in the listing's rows and not on its scrollbar.  TuiList
   draws the bar in the last column and only when the list is longer than it is
   tall, which is the same condition spelled out here.

   The event it is asked about is the one that arrived and not the one the list
   was offered: a widget that takes an event says so by clearing its kind - the
   framework's own rule - and Events.IsPress reads that kind, so the same record
   after the list has had it is no longer a press and this answers FALSE for
   every click.  Mouse keeps the event as it arrived for exactly this. *)
PROCEDURE RowClick (VAR fd: FD; VAR e: Events.Event): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := Events.IsPress(e) & TuiWidg.Inside(fd.files, e.x, e.y);
    IF r & (fd.files.count > fd.files.height) &
       (e.x = fd.files.x + fd.files.width - 1) THEN
        r := FALSE
    END;
    RETURN r
END RowClick;


(* The press, offered to the box's widgets by the window itself, in the ring's
   order - and the box reacts to the one that answered.  Which one that was is
   the widget the window hands back, compared against the box's own: no index is
   kept anywhere, and the order the widgets are offered in is not the box's to
   know any more.

   The widget that takes a press is the one the ring is on from then on, which
   the window does inside Send, so Tab carries on from where the pointer left
   the keyboard.

   What the pointer did is read off the event as it arrived, because the widget
   that takes it clears its kind on the way past - so a click on a row is a press
   in the copy and not in the record the list has finished with.  The
   coordinates are the same in both. *)
PROCEDURE Mouse (VAR fd: FD; VAR e: Events.Event): BOOLEAN;
VAR handled: BOOLEAN; who: TuiWidg.Widget; was: Events.Event;
BEGIN
    handled := FALSE;
    was := e;
    handled := fd.win.Send(fd.win, e, who);
    IF handled & (who # NIL) THEN
        IF who = fd.files THEN
            IF RowClick(fd, was) THEN
                IF fd.o.multi THEN
                    IF e.ctrl THEN
                        ToggleMark(fd, fd.files.sel)
                    ELSE
                        ClearMarks(fd);
                        Cursor(fd, fd.files.sel);
                        Report(fd)
                    END
                ELSE
                    Take(fd, fd.files.sel)
                END
            END
        ELSIF who = fd.drives THEN
            DriveTo(fd, fd.drives.sel)
        ELSIF who = fd.upb THEN
            Press(fd, CMD_UP)
        ELSIF who = fd.mkdir THEN
            Press(fd, CMD_MKDIR)
        ELSIF who = fd.okb THEN
            Press(fd, CMD_OK)
        ELSIF who = fd.cancel THEN
            Press(fd, CMD_CANCEL)
        END
    END;
    RETURN handled
END Mouse;


(* The type field's Enter: take what is in it as the mask and read again. *)
PROCEDURE Reread (VAR fd: FD);
BEGIN
    fd.maskF.GetText(fd.maskF, fd.o.masks);
    Strings.Trim(fd.o.masks);
    Read(fd)
END Reread;


(* Enter, on every stop of the ring: what the widget the ring is on means by it.
   The four buttons act through the one Press the module has, the two lists take
   what they are pointing at, the type field reads the directory again and the
   name field is the answer.

   A button reached this way has already declined the key - a hot button takes
   Enter itself, which is why the four arms below are the ones the box gives
   when nobody else took it - and the arms are kept whole rather than left as an
   else, because a map with a hole in it would answer Accept for whatever fell
   through. *)
PROCEDURE OnEnter (VAR fd: FD);
VAR sel: INTEGER;
BEGIN
    sel := TuiWin.Ring(fd.win);
    IF sel = R_DRIVES THEN DriveTo(fd, fd.drives.sel)
    ELSIF sel = R_FILES THEN Take(fd, fd.files.sel)
    ELSIF fd.o.dirs THEN
        (* The ring without the fields, whose four buttons are two stops
           nearer the front - and there is no type field to re-read either. *)
        IF sel = R_D_UP THEN Press(fd, CMD_UP)
        ELSIF sel = R_D_MKDIR THEN Press(fd, CMD_MKDIR)
        ELSIF sel = R_D_OK THEN Press(fd, CMD_OK)
        ELSE Press(fd, CMD_CANCEL)
        END
    ELSE
        IF sel = R_UP THEN Press(fd, CMD_UP)
        ELSIF sel = R_MKDIR THEN Press(fd, CMD_MKDIR)
        ELSIF sel = R_OK THEN Press(fd, CMD_OK)
        ELSIF sel = R_CANCEL THEN Press(fd, CMD_CANCEL)
        ELSIF sel = R_TYPE THEN Reread(fd)
        ELSE Accept(fd)
        END
    END
END OnEnter;


(* Esc and Enter are the box's own two keys.  Everything else - a character
   typed into a field, a space, an arrow in a list, and Tab - goes to the window,
   which offers it to the widget the ring is on: the widget takes what is its
   own and declines the rest, and the window is what walks the ring on Tab.  The
   box no longer knows the order its widgets are offered in, and no longer keeps
   an index of its own to keep in step with the walk.

   The arrows are deliberately never the box's own: two lists are most of what
   this box is, and the widget the ring is on is the one offered them.

   Esc comes first, so a key that closes the box is never also a key a widget
   could want, and MarkKey next, because Space in the listing is a mark and
   Space in a field is a space - which is a choice about the ring that only the
   box can make. *)
PROCEDURE Key (VAR fd: FD; VAR e: Events.Event): BOOLEAN;
VAR handled: BOOLEAN; who: TuiWidg.Widget; d: INTEGER;
BEGIN
    handled := FALSE;
    IF Events.IsKey(e, Events.K_ESC) THEN
        Cancel(fd);
        handled := TRUE
    ELSIF MarkKey(fd, e) THEN
        handled := TRUE
    ELSIF Events.IsKey(e, Events.K_ENTER) THEN
        handled := fd.win.Send(fd.win, e, who);
        IF handled & (who # NIL) THEN
            IF who = fd.upb THEN Press(fd, CMD_UP)
            ELSIF who = fd.mkdir THEN Press(fd, CMD_MKDIR)
            ELSIF who = fd.okb THEN Press(fd, CMD_OK)
            ELSIF who = fd.cancel THEN Press(fd, CMD_CANCEL)
            END
        ELSE
            OnEnter(fd);
            handled := TRUE
        END
    ELSE
        d := fd.drives.sel;
        handled := fd.win.Send(fd.win, e, who);
        IF handled & (who # NIL) THEN
            IF who = fd.nameF THEN
                (* a name typed by hand is what the box is being asked for, so
                   the marks a moment ago are not *)
                ClearMarks(fd);
                Report(fd)
            ELSIF (who = fd.drives) & (fd.drives.sel # d) THEN
                DriveTo(fd, fd.drives.sel)
            END
        END
    END;
    RETURN handled
END Key;


(* A mouse event as the widgets must see it.  An event carries desktop cells; a
   widget lives in its window's own canvas, so the window's corner comes off
   first - and a cell outside the window is put off the top left corner, where
   no widget of any size can be, so that a drag which began inside and was let
   go outside still reaches the widget holding it. *)
PROCEDURE Local (VAR fd: FD; VAR e: Events.Event; VAR local: Events.Event);
BEGIN
    local := e;
    IF TuiWidg.Inside(fd.win, e.x, e.y) THEN
        local.x := e.x - fd.win.x;
        local.y := e.y - fd.win.y
    ELSE
        local.x := -1;
        local.y := -1
    END
END Local;


(* ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   The seven calls the application makes.
   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ *)


(* The stops the window is given, in the order it is given them: the order an
   event is offered in, the order Tab walks and the order a press is offered in
   - so a press that lands on a button is never offered to a list first, which
   is what the order is for.

   Two rings exist because two modes exist, and it is built at every Start
   rather than once in Init: which one is wanted is not known until the caller
   has said what it is asking for.  The window keeps its own ring, so this is
   the only place the order is written down. *)
PROCEDURE BuildRing (VAR fd: FD);
BEGIN
    TuiWin.ClearRing(fd.win);
    TuiWin.AddWidget(fd.win, fd.drives);
    TuiWin.AddWidget(fd.win, fd.files);
    IF ~fd.o.dirs THEN
        TuiWin.AddWidget(fd.win, fd.nameF);
        TuiWin.AddWidget(fd.win, fd.maskF)
    END;
    TuiWin.AddWidget(fd.win, fd.upb);
    TuiWin.AddWidget(fd.win, fd.mkdir);
    TuiWin.AddWidget(fd.win, fd.okb);
    TuiWin.AddWidget(fd.win, fd.cancel)
END BuildRing;


(* Build the window, its widgets, its ring and its two prompts.  The window is
   made and hidden at once - the rule the demo's own late windows follow - so no
   picture before Start can see it. *)
PROCEDURE Init* (VAR fd: FD);
VAR bt: INTEGER;
BEGIN
    fd.win := Tui.CreateWindow(WinX, WinY, WinW, WinH, "");
    Tui.Hide(fd.win);

    (* The eight widgets are given no host, and this is the one place in the
       sample where that is deliberate rather than a thing left undone.

       A host would give them two things: the window would paint them in the
       order they were made in, and it would free them when it goes.  Neither is
       what this box needs.  It paints them itself, in Paint, and the order is
       the whole of why: the two lists are drawn first and the marks the user
       put on them are read back off the canvas afterwards, cell by cell, by
       PaintMarks - so a walk that repainted a list after the marks would wipe
       them, and the box would lose its selection on every frame.  A walk gives
       one order and this module needs another, so the painting stays here.

       They are given back by this module's own Done for the same reason: a
       window frees what it owns, and a widget it does not own is a widget it
       must not free.  That is not a leak - it is the same rule the two dialogs
       follow, and it is the reason Done below still has eight lines in it while
       every other module's has none. *)
    fd.drives := TuiList.Create(DRV_X, LST_Y, DRV_W, LST_H, NIL);
    fd.files := TuiList.Create(FILE_X, LST_Y, FILE_W, LST_H, NIL);
    fd.nameF := TuiFld.Create(FLD_X, ROW_NAME, FLD_W, NIL);
    fd.maskF := TuiFld.Create(FLD_X, ROW_TYPE, FLD_W, NIL);

    fd.upb := TuiBtns.Create("Up", CMD_UP, FALSE, NIL);
    fd.upb.SetPos(fd.upb, UP_X, TOOL_Y);
    fd.mkdir := TuiBtns.Create("New folder", CMD_MKDIR, FALSE, NIL);
    fd.mkdir.SetPos(fd.mkdir, MKDIR_X, TOOL_Y);
    fd.okb := TuiBtns.Create("Open", CMD_OK, TRUE, NIL);
    fd.okb.SetPos(fd.okb, OK_X, BTN_Y);
    fd.cancel := TuiBtns.Create("Cancel", CMD_CANCEL, FALSE, NIL);
    fd.cancel.SetPos(fd.cancel, CANCEL_X, BTN_Y);

    (* The ring is the full one until a caller asks for another: see
       BuildRing, which is what Start calls again for every open. *)
    fd.o.dirs := FALSE;
    BuildRing(fd);

    fd.prompt := TuiDlg.Create("New folder");
    fd.prompt.AddField(fd.prompt);
    fd.prompt.SetText(fd.prompt, "The name of the folder to make, then",
                      "Enter: it is made in this directory.");
    bt := fd.prompt.AddButton(fd.prompt, "OK", ANS_YES, TRUE);
    bt := fd.prompt.AddButton(fd.prompt, "Cancel", ANS_NO, FALSE);

    (* The box's own title, and not the question: a dialog draws its title as a
       tab on the top frame and its two lines inside, so a title that repeated
       the second line would say the same three words twice in one picture. *)
    fd.dlg := TuiDlg.Create("Overwrite");
    fd.dlg.SetText(fd.dlg, "The file is already there", "Overwrite?");
    bt := fd.dlg.AddButton(fd.dlg, "Yes", ANS_YES, TRUE);
    bt := fd.dlg.AddButton(fd.dlg, "No", ANS_NO, FALSE);

    fd.nent := 0; fd.dirs := 0; fd.first := 0; fd.nmarks := 0;
    fd.trunc := FALSE; fd.overN := 0;
    fd.done := FALSE; fd.asking := ASK_NONE;
    fd.o.dir[0] := 0X; fd.o.name[0] := 0X; fd.o.masks[0] := 0X;
    fd.o.names[0][0] := 0X; fd.o.nsel := 0;
    fd.o.mustExist := TRUE; fd.o.multi := FALSE; fd.o.accepted := FALSE; fd.busy := FALSE
END Init;


(* Take the caller's options, read the directory, put the box up.  A directory
   the caller named that is not there is not an error to report: the box opens
   on the program's own directory instead, which is a place the user can get
   somewhere from, and the path line says where they are. *)
PROCEDURE Start* (VAR fd: FD; VAR o: Opt);
VAR nx, ny: INTEGER;
BEGIN
    fd.o := o;
    fd.done := FALSE;
    fd.o.accepted := FALSE;             (* nothing has been accepted yet *)
    (* A prompt of ours left in the desk's slot is put down before the box
       starts.  The box cannot be answered while one is up, so the demo never
       arrives here with one - but the two are one decision and a caller that
       left them disagreeing would be showing a question that no longer belongs
       to anything and swallowing every event meant for the box. *)
    IF fd.asking # ASK_NONE THEN Tui.SetDialog(NIL) END;
    fd.asking := ASK_NONE;
    fd.overN := 0;
    IF fd.o.dirs THEN
        fd.okb.SetLabel(fd.okb, "Choose");
        fd.cancel.SetPos(fd.cancel, CANCEL_DIR_X, BTN_Y)
    ELSIF fd.o.mustExist THEN
        fd.okb.SetLabel(fd.okb, "Open");
        fd.cancel.SetPos(fd.cancel, CANCEL_X, BTN_Y)
    ELSE
        fd.okb.SetLabel(fd.okb, "Save");
        fd.cancel.SetPos(fd.cancel, CANCEL_X, BTN_Y)
    END;
    (* The two fields are not in this mode's ring and are not drawn either: a
       widget paints itself only while it is visible, so this is what makes the
       two rows they stand on blank rather than what makes them wrong.  It is
       also what keeps a press in those rows from reaching a field. *)
    fd.nameF.visible := ~fd.o.dirs;
    fd.maskF.visible := ~fd.o.dirs;
    BuildRing(fd);
    fd.win.SetTitle(fd.win, fd.o.title);
    Load(fd);
    IF (fd.o.dir[0] = 0X) OR ~Files.ExistsDir(fd.o.dir) THEN
        Dirs.CurrentDir(fd.o.dir)
    END;
    IF fd.o.dir[0] = 0X THEN
        fd.o.dir[0] := "."; fd.o.dir[1] := 0X
    END;
    fd.maskF.SetText(fd.maskF, fd.o.masks);
    fd.nameF.SetText(fd.nameF, fd.o.name);
    Read(fd);

    (* Centred on the screen, by the arithmetic the desk's own dialogs place
       themselves with (TuiDlg.Place): half of what is left over, with the
       menu bar's row as the floor.  On an 80x25 screen that is exactly the
       corner the box has always opened in - 0 and 1 - so nothing moves there;
       on a larger one it lands in the middle rather than the top left, which is
       the whole point of asking for it.

       It is done here and not in Init, because the box can be dragged: opening
       twice should put it in the middle twice, not wherever it was left.  It is
       done before Show for the plain reason that a window moved while it is
       hidden has nothing to repaint. *)
    nx := (Tui.Cols() - fd.win.width) DIV 2;
    IF nx < 0 THEN nx := 0 END;
    ny := (Tui.Rows() - fd.win.height) DIV 2;
    IF ny < 1 THEN ny := 1 END;
    fd.win.Move(fd.win, nx, ny);

    Tui.Show(fd.win);
    (* The walk starts on the listing, and saying so is also what marks the
       widgets: the window hands the keyboard to the stop it is on and marks
       every other one off, which is what the box used to spell out for all
       eight of them.  It comes after Show because Show is what makes the window
       the desk's active one, and a window without the keyboard marks none of
       its widgets. *)
    TuiWin.SetRing(fd.win, R_FILES);
    Paint(fd)
END Start;


(* One event, while the box is up.  TRUE once it has been answered, which is
   when the caller reads Answer and hides nothing - the box has hidden itself.

   An event that arrives while one of our own prompts holds the desk is not
   ours: Tui is routing it to the prompt, and the answer comes back through
   Told. *)
PROCEDURE Handle* (VAR fd: FD; VAR e: Events.Event): BOOLEAN;
VAR handled: BOOLEAN; local: Events.Event;
BEGIN
    handled := FALSE;
    IF ~fd.done & (fd.asking = ASK_NONE) THEN
        IF e.kind = Events.KEYBOARD THEN
            handled := Key(fd, e)
        ELSIF e.kind = Events.MOUSE THEN
            Local(fd, e, local);
            handled := Mouse(fd, local)
        END;
        IF handled THEN e.kind := Events.NONE END;
        Paint(fd)
    END;
    RETURN fd.done
END Handle;


(* Whether one of our prompts is the desk's dialog at this moment.  The
   application asks this before it decides who gets the event, and it is the
   only thing that makes the desk's slot ours. *)
PROCEDURE Asks* (VAR fd: FD): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := fd.asking # ASK_NONE;
    RETURN r
END Asks;


(* Whether the desk cell (x, y) is the box's own title row - the one place it
   lets itself be taken hold of, and so the one press the application offers the
   desk while the box is up.

   The box is modal: every other event is handed to Handle and the desk never
   sees it, so the drag Windows would begin on a title row of its own accord is
   never begun here.  Rather than move the window by hand, the application asks
   this and passes that one press on to Tui.Dispatch - so the box is dragged by
   the same code that drags every other window, with the same clamping, and
   nothing about dragging is written twice.

   Only the title.  The bottom right corner is the desk's other grip and is
   deliberately not offered: the box's whole layout is fixed numbers measured
   from its frame, so a resize would not reflow anything - it would only slide
   every widget out of the box.

   The coordinates are the desk's, which is what a mouse event carries.  Zone
   tests the window's own rectangle first, so a cell outside the box is never a
   grip. *)
PROCEDURE Grabs* (VAR fd: FD; x, y: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := fd.win.Zone(fd.win, x, y) = TuiWin.ZONE_TITLE;
    RETURN r
END Grabs;


(* The command the desk's dialog answered with, which is one of our prompts
   answering; the answer is whether the box is answered now, which is what
   Handle answers too.  Which prompt it was is state here and nowhere else, so
   the numbers a prompt's buttons carry never have to be unique across the box.

   The answer is returned rather than left for the caller to find out, because
   the overwrite question's Yes is an accept and its No is not - and the caller
   that routed this event to the desk instead of to Handle would otherwise have
   to offer the same event a second time to learn which, and offering it twice
   is what would press the button under it twice.

   It is private: Ask below is the way in, and it is Ask that decides what a
   command means rather than what a key means. *)
PROCEDURE Told (VAR fd: FD; cmd: INTEGER): BOOLEAN;
VAR name: ARRAY 64 OF CHAR; full: ARRAY PathMax OF CHAR; was: INTEGER;
BEGIN
    was := fd.asking;
    fd.asking := ASK_NONE;
    IF was = ASK_FOLDER THEN
        IF cmd = ANS_YES THEN
            fd.prompt.GetFieldText(fd.prompt, name);
            Strings.Trim(name);
            IF name[0] = 0X THEN
                Message("No name was typed, so no folder was made")
            ELSE
                Dirs.Join(fd.o.dir, name, full);
                IF Files.CreateDir(full) THEN
                    Read(fd)                (* the new folder is in it now *)
                ELSE
                    Say2("Could not make the folder: ", name)
                END
            END
        ELSE
            Message("No folder was made")
        END
    ELSIF was = ASK_OVER THEN
        IF cmd = ANS_YES THEN
            Finish(fd, fd.overN)
        ELSE
            Message("Nothing was overwritten")
        END
    END;
    Paint(fd);
    RETURN fd.done
END Told;


(* The desk's slot while one of our prompts is in it: the event is offered to
   Tui, which is what draws and feeds the box, and the command it answers with
   comes straight back here.  The application calls this instead of
   Tui.Dispatch, and it is the one place the two halves of the routing meet.

   Esc is the reason it exists rather than the application calling Dispatch
   itself.  TuiDlg answers Esc by closing with no command at all, which is what
   a box with one button wants and is exactly wrong for a prompt whose two
   answers are both commands: the dialog would go and this module would go on
   believing a question was up, so Asks would keep answering TRUE and every
   event would be handed to a desk whose slot is empty - the box would be deaf
   for good.  So the key is taken before the dialog is offered it, and turned
   into the answer the prompt's own Cancel button carries: a question closed by
   the keyboard is cancelled, and the two ways out of one question are one
   answer. *)
PROCEDURE Ask* (VAR fd: FD; VAR e: Events.Event): BOOLEAN;
VAR cmd: INTEGER; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF Events.IsKey(e, Events.K_ESC) THEN
        Tui.SetDialog(NIL);
        e.kind := Events.NONE;
        r := Told(fd, ANS_NO)
    ELSE
        cmd := Tui.Dispatch(e);
        IF cmd # 0 THEN r := Told(fd, cmd) END
    END;
    RETURN r
END Ask;


PROCEDURE Answer* (VAR fd: FD; VAR o: Opt);
BEGIN
    o := fd.o
END Answer;


(* Put the file dialog up over the desk.

   Every way in - the four menu entries and the four keys - comes through here,
   so the options are written in one place and a caller says no more than which
   of the boxes it wants: Open asks for a file that is there and Save for a name
   that need not be, which is the whole of the difference between them;
   everything else about the box is the same box.

   multi is the other half of "which box": it is the caller's flag for whether
   more than one name may be taken, and the box shows the mark column and reads
   the marks only when it is set.  The sample opens one file at a time from the
   plain entries and asks for a set from the third, so both of the box's two
   ways of answering - the name field and the marks - are reachable by hand and
   neither has to be taken on trust.

   dir and masks are the caller's because where the box opens and what it
   filters are the application's choices and not this module's.  They arrive as
   parameters rather than being imported, because DemCtx holds a TuiFile.FD
   and so this module must not import DemCtx. *)
PROCEDURE Open* (VAR fd: FD; VAR o: Opt; dir, masks: ARRAY OF CHAR;
                 save, multi, dirs: BOOLEAN);
BEGIN
    IF dirs THEN
        Strings.Copy("Choose a folder", o.title);
        (* No mask at all, which is the other half of what this mode is for: the
           box shows every name the directory holds.  The box does not apply a
           mask in this mode whatever is here, so this is said for the record
           rather than for the reading of it. *)
        o.masks[0] := 0X
    ELSIF save THEN
        Strings.Copy("Save as", o.title)
    ELSIF multi THEN
        Strings.Copy("Open some files", o.title)
    ELSE
        Strings.Copy("Open a file", o.title)
    END;
    Strings.Copy(dir, o.dir);
    o.name[0] := 0X;
    IF ~dirs THEN Strings.Copy(masks, o.masks) END;
    o.mustExist := ~save;
    o.multi := multi;
    o.dirs := dirs;
    o.nsel := 0;
    o.accepted := FALSE;
    Start(fd, o);
    fd.busy := TRUE
END Open;


(* Whether the box is up.  The application asks this before it decides who gets
   an event, and it is the only thing that makes the desk's events ours. *)
PROCEDURE Busy* (VAR fd: FD): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := fd.busy;
    RETURN r
END Busy;


(* The box has been answered: read the result out, put the window away, and say
   in the status line what came of it.

   The window is hidden and not given back.  The desktop owns every window and
   Tui.Done gives them all back, so a module that disposed of one would be
   handing back what it did not make - and the same rule is what makes opening
   the box a second time cost nothing but the reading of a directory.

   The five messages are this module's: the box is what knows its own four modes
   and which of them answers with a folder. *)
PROCEDURE Close (VAR fd: FD; VAR o: Opt);
VAR s: ARRAY 256 OF CHAR; t: ARRAY 16 OF CHAR; more: BOOLEAN;
BEGIN
    Answer(fd, o);
    Tui.Hide(fd.win);
    fd.busy := FALSE;
    IF ~o.accepted THEN
        IF o.dirs THEN
            Strings.Copy("No folder was chosen", s)
        ELSE
            Strings.Copy("The file dialog was cancelled", s)
        END
    ELSIF o.nsel > 1 THEN
        Strings.Copy("Chosen: ", s);
        Strings.FromInt(o.nsel, t);
        more := Strings.Append(t, s);
        more := Strings.Append(" files", s)
    ELSIF o.dirs THEN
        (* The answer is the folder the box was in, and it arrives in `name`
           like any other answer - the box makes sure of that - so this is the
           word in front of it and nothing else. *)
        Strings.Copy("Folder: ", s);
        more := Strings.Append(o.name, s)
    ELSE
        Strings.Copy("Chosen: ", s);
        more := Strings.Append(o.name, s)
    END;
    Tui.SetStatus(s)
END Close;


(* One turn of the box, while it is up: the event is offered exactly once,
   either to a prompt of ours or to the box itself.

   The file dialog is modal, and its modality is here rather than in the
   framework, which is the framework's own rule: Tui deliberately does not know
   what a window holds, and "while this one is up nothing else may be touched"
   is a statement about what a window holds.  So while the box is up the desk
   is not asked anything at all - no menu opens, no window switch happens, no
   second box is raised, Esc does not quit and F6 does not move the focus -
   because every one of those lives in Dispatch and in Handle, and neither is
   called.

   The one exception is a prompt of the box's own.  That prompt is a real
   dialog in the desk's slot, and Tui is what draws that slot and routes events
   to it, so Dispatch IS called while one is up - and what it answers is handed
   straight to the box, which is the only thing that knows which of its two
   questions was answered.  The event is offered exactly once either way, which
   is what keeps Yes from being pressed a second time on the way past.

   Repaint and Tui.Draw still run on every turn, box or no box.  Nothing of it
   can be seen through the box, which covers the desk, but the alternative is a
   frame path with a hole in it - and the box's own canvas is drawn into by the
   box itself, so the picture is still one Draw of one desk. *)
PROCEDURE Step* (VAR fd: FD; VAR o: Opt; VAR e: Events.Event);
VAR p: INTEGER;
BEGIN
    IF Asks(fd) THEN
        IF Ask(fd, e) THEN Close(fd, o) END
    ELSE
            (* The pointer cell is the desk's and stays the desk's while the box
               is up.  It is drawn last of all, over the box like everything
               else, and the cell it is drawn in is one only Tui.Dispatch
               records - so a movement is offered to the desk and its answer
               dropped, which costs nothing: a movement is not a press, so it
               raises no window and opens no menu.

               A press is offered only where the box says it may be taken hold
               of - TuiFile.Grabs, which answers for the box's own title row
               and nothing else.  That one press the desk spends on dragging the
               box, by the same code that drags every other window; every other
               press is withheld, because the box is modal and a press it did not
               want - one on the menu bar, or on any of the rows the box does not
               cover - would go on to the desk and be taken by whatever is behind
               the box, which is the one thing modality is for.

               A release is offered too, and must be: it is the event that ends
               the drag the press began, and a desk left in drag mode would go on
               moving the box under the pointer.  It cannot do anything else - a
               menu opens on a press and never on a release, and a release raises
               no window - so offering it costs the modality nothing. *)
        IF (e.kind = Events.MOUSE) &
           (Grabs(fd, e.x, e.y) OR ~Events.IsPress(e)) THEN
            p := Tui.Dispatch(e)
        END;
        IF Handle(fd, e) THEN Close(fd, o) END
    END
END Step;


(* Free what this module made.  The window is not among it: the desktop owns
   every window and Tui.Done gives them all back, so a module that disposed of
   one would be giving back what it did not make. *)
PROCEDURE Done* (VAR fd: FD);
BEGIN
    IF fd.drives # NIL THEN fd.drives.Done(fd.drives); fd.drives := NIL END;
    IF fd.files # NIL THEN fd.files.Done(fd.files); fd.files := NIL END;
    IF fd.nameF # NIL THEN fd.nameF.Done(fd.nameF); fd.nameF := NIL END;
    IF fd.maskF # NIL THEN fd.maskF.Done(fd.maskF); fd.maskF := NIL END;
    IF fd.upb # NIL THEN Oberon.Done(fd.upb); fd.upb := NIL END;
    IF fd.mkdir # NIL THEN Oberon.Done(fd.mkdir); fd.mkdir := NIL END;
    IF fd.okb # NIL THEN Oberon.Done(fd.okb); fd.okb := NIL END;
    IF fd.cancel # NIL THEN Oberon.Done(fd.cancel); fd.cancel := NIL END;
    IF fd.prompt # NIL THEN fd.prompt.Done(fd.prompt); fd.prompt := NIL END;
    IF fd.dlg # NIL THEN fd.dlg.Done(fd.dlg); fd.dlg := NIL END;
    fd.busy := FALSE;
    fd.win := NIL
END Done;

END TuiFile.






