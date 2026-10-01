MODULE TuiTree;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A tree view: a hierarchy flattened into the rows of a list box, one of them
   chosen, with the nodes that are open drawn above the nodes they hold.

   The widget holds no hierarchy of its own.  It asks the owner for one, through
   two callbacks and an id: Count answers how many children a node has, and Child
   answers the i-th of them - its name, its own id, and whether it has children
   of its own.  The id of the root is always ROOT, which is -1, and every other
   id is the owner's to invent: this module hands back whatever Child gave it and
   never looks inside one.  That is the whole of the contract, and it is what
   lets the same widget serve a directory tree, an outline or anything else a
   program keeps a parent-and-children record of.

   The root's own name is the one thing those two callbacks cannot supply - both
   of them name a child - so the owner writes it with SetRoot, once, beside the
   caption of the window the tree stands in.

   The rows are the tree flattened in pre-order, and that one fact is what the
   whole module rests on.  A node's children are the rows immediately below it,
   so whether a node is open is not a flag anybody keeps: the row below an open
   node is deeper than it is and names it as its parent, and the row below a shut
   one is not.  IsOpen asks exactly that, and opening and closing are an insert
   and a delete of a run of rows.  A flag per node would be a second copy of a
   fact the rows already carry, and the two could disagree - which is the shape
   of bug a widget like this is most likely to have.

   The parent of a row is kept as the parent's id and not as its row: an insert
   moves every row below it, so a row index would have to be rewritten all the
   way down the array on every expand.  An id survives the move, and the row it
   stands on is asked for when it is needed, which is once per gesture.

   What is loaded is only what is open, so a tree of a hundred thousand nodes
   costs the rows of the part being looked at.  Count and Child are asked once
   per node, when it is first opened, and never again - which is why a tree that
   has been walked draws at the speed of a list box, and why an owner that
   changes its data has to say so: NodeChanged for one node, Reset for all of
   them.

   One node is chosen and no more than one.  There are no marks here and no
   Shift range, and that is a decision and not an omission: a tree's selection is
   a place in a hierarchy rather than a set of rows, and the gestures that would
   grow one - Shift with an arrow, a Ctrl click - mean something else in a widget
   whose rows move when they are expanded.  The chosen row is drawn in TreeSel,
   or in TreeSelIdle when the window it is in is not the one the keyboard is on,
   exactly as a list's and a table's are.

   The tree has a palette of its own in the themes - Tree for its surface,
   TreeLine for the rules that show the levels, TreeBar for its scrollbar - and
   the slots were appended to the theme rather than borrowed from the table's, so
   a theme may paint a tree one way while the table beside it stays another.

   The levels are drawn the way a file manager of the DOS years drew them - the
   connectors of Norton Commander and Volkov Commander - and how is worth saying
   because the cheap way to do it is wrong.  A row at depth d stands at column
   2d, its own branch in the two columns to the left of it, and its name two
   columns further on, so one level is two columns wide and the name of a node
   at depth d begins at column 2d + 2 whatever its parent is.  The branch is a
   tee when something follows the row at its own level and an elbow when nothing
   does, and the column the branch stands in is the column the parent's own
   marker stands in, so the elbows and tees of one level line up under the
   marker of the level above and the picture reads as a tree and not as an
   indent.  A column to the left of those carries a vertical rule for every
   ancestor whose own subtree is not finished yet.  Those flags are worked out
   by Compute once per change of shape and read here unchanged; the alternative,
   walking up the ancestors of every row on every frame, is O(rows x depth x
   depth), and this layer draws on every frame.

   The root is the one row with no branch: nothing leads into the first row of a
   tree, so its marker stands in the leftmost column of the widget.

   What says whether a node is open is the marker at the node's own column: a
   plus for a node that is shut and that the owner reported as having children, a
   minus for one that is open, and a blank for a node with no children at all -
   the same two characters DOS TREE used.  The branch columns are the one thing
   on a row whose colour is not the row's own: they are drawn in TreeLine while
   the row they cross is an ordinary one, and in the row's pair when the row is
   the chosen one, because a chosen row is one surface and a line across it in a
   second colour reads as a crack.  The marker is drawn in the row's own pair
   either way: it is what the row says, not the line it hangs from.

   A click anywhere on a row chooses it, and on a node the owner reported as
   having children it opens or shuts it as well.  The whole row is the target and
   not the marker's own cell: the marker is one character wide, and a reader who
   aims at a name and is given a cursor move has been made to aim twice for one
   idea.  There is nothing else a click on a row could mean - this widget's
   selection follows the cursor, so a press on a row is the choice of it either
   way - and a node with no children has nothing to open, so a click on one is
   the choice alone, exactly as it always was.

   A name longer than the room left for it is cut at the widget's own right edge
   and not at the canvas's: the canvas would let it run on over the scrollbar,
   which is a cell of this widget that the text must not have.

   Mutation is the owner's, and there are two calls for it.  NodeChanged says one
   node's name or its has-children flag has changed, and it is re-read - from the
   node's parent, because the two callbacks name a child and there is no third
   one that names a node.  Reset says the whole tree is a different tree: the
   rows go, the root is asked for again, and the cursor is back at the top.  What
   NodeChanged deliberately does not do is re-read the children of a node that is
   already open: an owner that has added or removed a child of an open node
   should Close it and Open it again, which is one gesture and says what
   happened.

   A node the owner reports as having children and then answers zero of them for
   is a node with no children, and it is drawn as one from that moment: the owner
   is asked once, and its answer is what the tree believes.

   The geometry is in cells of whatever canvas the tree draws into, and draw
   takes that canvas as a parameter - a tree inside a window draws into the
   window's own canvas, not into the desktop.  Nothing here is a fixed size: the
   widget reads its own rectangle when it draws, so an owner that resizes it -
   which in this sample is a panel told to stretch - has done the whole of what
   there is to do.
*)

IMPORT TuiCanv, Events, Strings, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST

    ROOT* = -1;                     (* the id of the root, whatever it is *)
    MAXNODES* = 512;                (* rows the flattened tree may hold *)
    NAMELEN = 49;                   (* bytes a node's name takes, its 0X too *)
    INDENT = 2;                     (* columns one level of the indent takes *)
    BARCOLS = 1;                    (* columns the scrollbar takes when it is
                                       shown *)
    MAXLEVEL = 32;                  (* levels the indent drawing has room for *)

TYPE

    Tree* = POINTER TO TreeDesc;

    (* How many children a node has.  Asked once, when the node is first opened,
       and never while it is shut: a tree that asked on every frame would be a
       tree that walks the whole of what it is showing sixty times a second. *)
    CountProc* = PROCEDURE (self: Tree; id: INTEGER): INTEGER;

    (* The i-th child of a node.  cid is the id the widget will hand back when it
       opens that child in its turn, name is what the row is drawn with, and kids
       says whether the child has children of its own - which is what the row's
       marker is and what decides whether Right does anything on it.

       The widget asks for i from 0 upwards, in one run, for one id at a time:
       Count first and then Child for each.  An owner that walks a directory or
       a table may rely on that and keep its walk open across the calls; an owner
       that cannot is free to answer each one from scratch. *)
    ChildProc* = PROCEDURE (self: Tree; id, i: INTEGER;
                            VAR cid: INTEGER; VAR name: ARRAY OF CHAR;
                            VAR kids: BOOLEAN);

    TreeDesc* = RECORD (TuiWidg.WidgetDesc)

        (* The flattened tree, one array per fact rather than one array of
           records.  Six parallel arrays read a little longer than a record would
           and they cost nothing at all: a record here would be an exported
           record's field of an unexported type, and the dialect does not thank a
           module for that. *)

        nid:   ARRAY MAXNODES OF INTEGER;   (* the id the owner gave the node *)
        npar:  ARRAY MAXNODES OF INTEGER;   (* the id of its parent *)
        ndep:  ARRAY MAXNODES OF INTEGER;   (* how deep it stands; the root 0 *)
        nhas:  ARRAY MAXNODES OF BOOLEAN;   (* the owner says it has children *)
        nname: ARRAY MAXNODES OF ARRAY NAMELEN OF CHAR;

        (* For every row, whether the row that follows its whole subtree stands
           at the same depth - which is what a vertical rule in the indent is
           drawn from.  It is derived from the three arrays above and is only
           ever a cache of them: stale is what says it has to be worked out
           again, and Compute is the only thing that clears it. *)
        nsib:  ARRAY MAXNODES OF BOOLEAN;
        stale: BOOLEAN;

        n*: INTEGER;                (* rows on show, the root's own among them *)
        sel*, top*: INTEGER;

        (* The two questions the owner answers, and the record the owner keeps
           its own state in - which is what env is for, and NIL for a module
           whose data is a module variable.  An owner that ignores them is an
           owner whose tree is one row deep. *)
        Count*: CountProc;
        Child*: ChildProc;
        env*: TuiWidg.Widget;

        (* The id fired when the cursor moves, a node opens or closes, or the
           tree is reset.  Nothing else here is an event: an owner that wants to
           know where the cursor is reads SelId and Level when its own command
           runs, or on every frame. *)
        cmd*: INTEGER;

        host: TuiWin.Window;

        (* The scrollbar: whether its thumb is being held, and how far down the
           thumb the pointer took hold.  Whether a mouse event is a press is not
           kept here - the event carries it. *)
        grabbing: BOOLEAN;
        grabDY: INTEGER;

        draw*:   PROCEDURE (self: Tree; target: TuiCanv.Canvas);
        onEvent*: PROCEDURE (self: Tree; VAR e: Events.Event): BOOLEAN;
        SetRoot*: PROCEDURE (self: Tree; name: ARRAY OF CHAR);
        Reset*:  PROCEDURE (self: Tree);
        Open*:   PROCEDURE (self: Tree; id: INTEGER);
        Close*:  PROCEDURE (self: Tree; id: INTEGER);
        Toggle*: PROCEDURE (self: Tree; id: INTEGER);
        Select*: PROCEDURE (self: Tree; id: INTEGER);
        SelId*:  PROCEDURE (self: Tree): INTEGER;
        Level*:  PROCEDURE (self: Tree): INTEGER;
        NodeChanged*: PROCEDURE (self: Tree; id: INTEGER)
    END;


PROCEDURE Rows (self: Tree): INTEGER;
VAR r: INTEGER;
BEGIN
    r := self.height;
    IF r < 1 THEN r := 1 END;
    RETURN r
END Rows;


(* Whether the tree is longer than it is tall, and so needs a scrollbar. *)
PROCEDURE Scrolled (self: Tree): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := self.n > Rows(self);
    RETURN r
END Scrolled;


(* The thumb: how many rows of the track it takes, and which row it starts on.
   Drawing it and hit testing it have to agree on both, so they are worked out
   here and nowhere else - the arithmetic a list box already keeps, over n rows
   where a list has count. *)
PROCEDURE Thumb (self: Tree; VAR size, offset: INTEGER);
VAR rows: INTEGER;
BEGIN
    rows := Rows(self);
    IF self.n <= rows THEN
        size := rows;
        offset := 0
    ELSE
        size := rows * rows DIV self.n;
        IF size < 1 THEN size := 1 END;
        offset := self.top * (rows - size) DIV (self.n - rows);
        IF offset > rows - size THEN offset := rows - size END;
        IF offset < 0 THEN offset := 0 END
    END
END Thumb;


(* Put the thumb's top at row thumbTop of the track, and the tree's top where
   that comes to.  This is the exact inverse of what Thumb does with top, which
   is what a drag of the thumb needs on every step.

   The selection is deliberately left alone, for the reason a list's is: a
   scrollbar scrolls, it does not choose. *)
PROCEDURE ScrollTo (self: Tree; thumbTop: INTEGER);
VAR rows, size, off, t: INTEGER;
BEGIN
    rows := Rows(self);
    Thumb(self, size, off);
    IF thumbTop < 0 THEN thumbTop := 0 END;
    IF thumbTop > rows - size THEN thumbTop := rows - size END;
    IF thumbTop < 0 THEN thumbTop := 0 END;
    IF rows - size > 0 THEN
        t := thumbTop * (self.n - rows) DIV (rows - size)
    ELSE
        t := 0                            (* nothing is scrolled: there is no track *)
    END;
    IF t > self.n - rows THEN t := self.n - rows END;
    IF t < 0 THEN t := 0 END;
    self.top := t
END ScrollTo;


(* Move top so that sel is one of the rows on show. *)
PROCEDURE EnsureTop (self: Tree);
VAR rows: INTEGER;
BEGIN
    rows := Rows(self);
    IF self.sel < self.top THEN
        self.top := self.sel
    END;
    IF self.sel >= self.top + rows THEN
        self.top := self.sel - rows + 1
    END;
    IF self.top > self.n - rows THEN
        self.top := self.n - rows
    END;
    IF self.top < 0 THEN
        self.top := 0
    END
END EnsureTop;


(* The row an id stands on, or -1 when the node is not loaded - which is every
   node that has never been opened, and every node of a tree that has just been
   reset.  It is a walk of the rows and not a table: the rows are at most
   MAXNODES long and this is asked once per gesture, never once per frame. *)
PROCEDURE RowOf (self: Tree; id: INTEGER): INTEGER;
VAR r, i: INTEGER;
BEGIN
    r := -1;
    i := 0;
    WHILE (i < self.n) & (r < 0) DO
        IF self.nid[i] = id THEN r := i END;
        INC(i)
    END;
    RETURN r
END RowOf;


(* Whether the node on this row has its children on show.  The rows say so by
   themselves, and that is the whole of the test: the row below an open node is
   one level deeper and names it as its parent, and the row below a shut one is
   neither.  There is no flag anywhere in this module that says a node is open,
   and so there is no flag that can disagree with the rows. *)
PROCEDURE IsOpen (self: Tree; row: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (row >= 0) & (row < self.n) & self.nhas[row] & (row + 1 < self.n) &
         (self.ndep[row + 1] > self.ndep[row]) &
         (self.npar[row + 1] = self.nid[row]);
    RETURN r
END IsOpen;


(* One row's five facts, moved from one place in the arrays to another.  It is a
   procedure and not a record assignment because there is no record: the arrays
   are parallel and this is what keeps the five of them in step. *)
PROCEDURE MoveNode (self: Tree; dst, src: INTEGER);
BEGIN
    self.nid[dst] := self.nid[src];
    self.npar[dst] := self.npar[src];
    self.ndep[dst] := self.ndep[src];
    self.nhas[dst] := self.nhas[src];
    Strings.Copy(self.nname[src], self.nname[dst])
END MoveNode;


(* Work out, for every row, whether the row that follows its subtree is a
   sibling of it.

   It is one walk from the last row to the first, with an array that remembers
   the nearest row seen so far at each depth.  For the row being looked at, the
   nearest row below it whose depth is no greater than its own is the first row
   of whatever comes next; when that row's depth is the same as its own, the two
   are siblings and a rule is drawn beside everything in between.

   The cost is rows x depth and it is paid once per change of shape - an open, a
   close, a reset - and never on a frame that only draws. *)
PROCEDURE Compute (self: Tree);
VAR
    r, L, j, d: INTEGER;
    after: ARRAY MAXLEVEL OF INTEGER;
BEGIN
    FOR L := 0 TO MAXLEVEL - 1 DO after[L] := self.n END;
    r := self.n - 1;
    WHILE r >= 0 DO
        d := self.ndep[r];
        IF d > MAXLEVEL - 1 THEN d := MAXLEVEL - 1 END;
        j := self.n;
        FOR L := 0 TO d DO
            IF after[L] < j THEN j := after[L] END
        END;
        self.nsib[r] := (j < self.n) & (self.ndep[j] = self.ndep[r]);
        IF self.ndep[r] < MAXLEVEL THEN after[self.ndep[r]] := r END;
        DEC(r)
    END;
    self.stale := FALSE
END Compute;


(* Open the node on this row: ask the owner how many children it has and put
   them in, as a run of rows immediately below it.

   The tail of the array is moved down by as many rows as are coming in, and the
   move is made from the end backwards so that nothing is overwritten before it
   has been read.  The move comes first and the filling second, and that order is
   the whole of the reason the parent is stored as an id: a child's own row is
   inserted among rows that have already moved, and a row index kept in a child
   would be wrong by the time the child is written.

   A node the owner says has children and then answers none for is a node with no
   children, and it stops being drawn with a marker.  The owner is asked once:
   its answer is what the tree believes from then on. *)
PROCEDURE OpenRow (self: Tree; row: INTEGER);
VAR
    k, i, m, base, d, id, cid: INTEGER;
    kids: BOOLEAN;
BEGIN
    IF (row >= 0) & (row < self.n) & self.nhas[row] & ~IsOpen(self, row) THEN
        id := self.nid[row];
        d := self.ndep[row];
        k := self.Count(self, id);
        IF k < 0 THEN k := 0 END;
        IF k = 0 THEN
            self.nhas[row] := FALSE
        ELSE
            IF k > MAXNODES - self.n THEN k := MAXNODES - self.n END;
            IF k > 0 THEN
                m := self.n - (row + 1);
                base := row + 1;
                i := m - 1;
                WHILE i >= 0 DO
                    MoveNode(self, base + k + i, base + i);
                    DEC(i)
                END;
                FOR i := 0 TO k - 1 DO
                    cid := 0;
                    kids := FALSE;
                    self.nname[base + i][0] := 0X;
                    self.Child(self, id, i, cid, self.nname[base + i], kids);
                    self.nid[base + i] := cid;
                    self.npar[base + i] := id;
                    self.ndep[base + i] := d + 1;
                    self.nhas[base + i] := kids
                END;
                INC(self.n, k);
                self.stale := TRUE
            END
        END
    END
END OpenRow;


(* Shut the node on this row: take away every row below it that is deeper than it
   is, which is its whole subtree however far it was opened, and close the gap.

   The subtree is counted first and the move is one run, so a node opened six
   levels deep costs one pass of the array and not six. *)
PROCEDURE CloseRow (self: Tree; row: INTEGER);
VAR d, k, i: INTEGER;
BEGIN
    IF IsOpen(self, row) THEN
        d := self.ndep[row];
        k := 0;
        i := row + 1;
        WHILE (i < self.n) & (self.ndep[i] > d) DO
            INC(i);
            INC(k)
        END;
        i := row + 1;
        WHILE i + k < self.n DO
            MoveNode(self, i, i + k);
            INC(i)
        END;
        DEC(self.n, k);
        (* The cursor may have been inside what went away.  It is put back on the
           last row rather than left pointing past the end, and the node that was
           closed is above it either way. *)
        IF self.sel > self.n - 1 THEN self.sel := self.n - 1 END;
        IF self.sel < 0 THEN self.sel := 0 END;
        self.stale := TRUE;
        EnsureTop(self)
    END
END CloseRow;


(* Put the cursor on a row and keep it on show. *)
PROCEDURE SetSel (self: Tree; i: INTEGER);
VAR r: INTEGER;
BEGIN
    r := i;
    IF r < 0 THEN r := 0 END;
    IF r > self.n - 1 THEN r := self.n - 1 END;
    IF r < 0 THEN r := 0 END;
    self.sel := r;
    EnsureTop(self)
END SetSel;


PROCEDURE SetRoot* (self: Tree; name: ARRAY OF CHAR);
BEGIN
    Strings.Copy(name, self.nname[0])
END SetRoot;


(* Read the whole tree again, from the root down.

   The rows are thrown away and the root is asked for again - one row, shut, with
   the cursor at the top of the tree.  The root's own name is not touched, because
   it is the owner's and nothing the owner is asked can supply it.

   This is what an owner calls when its data is a different tree than it was, and
   it is the counterpart of a table's RowsChanged: the widget cannot work it out
   for itself, because everything it knows came from the owner in the first
   place. *)
PROCEDURE Reset* (self: Tree);
VAR k: INTEGER;
BEGIN
    self.n := 0;
    self.sel := 0;
    self.top := 0;
    self.grabbing := FALSE;
    self.stale := TRUE;
    IF self.Count # NIL THEN
        k := self.Count(self, ROOT);
        self.nid[0] := ROOT;
        self.npar[0] := ROOT;
        self.ndep[0] := 0;
        self.nhas[0] := k > 0;
        self.n := 1
    END
END Reset;


PROCEDURE Open* (self: Tree; id: INTEGER);
VAR row: INTEGER;
BEGIN
    row := RowOf(self, id);
    IF row >= 0 THEN OpenRow(self, row) END
END Open;


PROCEDURE Close* (self: Tree; id: INTEGER);
VAR row: INTEGER;
BEGIN
    row := RowOf(self, id);
    IF row >= 0 THEN CloseRow(self, row) END
END Close;


(* What a click on a row, the Right key and the Left key all come to: shut a
   node that is open and open one that is shut. *)
PROCEDURE Toggle* (self: Tree; id: INTEGER);
VAR row: INTEGER;
BEGIN
    row := RowOf(self, id);
    IF row >= 0 THEN
        IF IsOpen(self, row) THEN
            CloseRow(self, row)
        ELSE
            OpenRow(self, row)
        END
    END
END Toggle;


PROCEDURE Select* (self: Tree; id: INTEGER);
VAR row: INTEGER;
BEGIN
    row := RowOf(self, id);
    IF row >= 0 THEN SetSel(self, row) END
END Select;


PROCEDURE SelId* (self: Tree): INTEGER;
VAR id: INTEGER;
BEGIN
    id := ROOT;
    IF (self.sel >= 0) & (self.sel < self.n) THEN id := self.nid[self.sel] END;
    RETURN id
END SelId;


PROCEDURE Level* (self: Tree): INTEGER;
VAR d: INTEGER;
BEGIN
    d := 0;
    IF (self.sel >= 0) & (self.sel < self.n) THEN d := self.ndep[self.sel] END;
    RETURN d
END Level;


(* One node's name, or its has-children flag, is not what it was.

   It is re-read from the node's parent, and it has to be: the two callbacks an
   owner gives this module name a child, and there is no third one that names a
   node.  So the parent's children are walked until the id comes round again,
   which is the same walk OpenRow makes and costs the same.

   What this does not do is re-read the children of a node that is open.  An
   owner that has added or removed a child of one should Close it and Open it
   again - one gesture, and one that says what happened. *)
PROCEDURE NodeChanged* (self: Tree; id: INTEGER);
VAR
    row, prow, k, i, cid: INTEGER;
    kids: BOOLEAN;
    nm: ARRAY NAMELEN OF CHAR;
BEGIN
    row := RowOf(self, id);
    IF row >= 0 THEN
        IF row = 0 THEN
            (* the root has no parent to be named by: its own caption is the
               owner's and its children are a count and nothing else *)
            IF self.Count # NIL THEN self.nhas[0] := self.Count(self, ROOT) > 0 END
        ELSE
            prow := RowOf(self, self.npar[row]);
            IF prow >= 0 THEN
                k := self.Count(self, self.npar[row]);
                i := 0;
                WHILE i < k DO
                    cid := 0;
                    kids := FALSE;
                    nm[0] := 0X;
                    self.Child(self, self.npar[row], i, cid, nm, kids);
                    IF cid = id THEN
                        Strings.Copy(nm, self.nname[row]);
                        self.nhas[row] := kids
                    END;
                    INC(i)
                END
            END
        END
    END
END NodeChanged;


PROCEDURE draw (self: Tree; target: TuiCanv.Canvas);
VAR
    i, L, rows, r, y, d, ind, tx, x0, x1, w, ra, ta, ca, ba, size, off: INTEGER;
    bar: BOOLEAN;
    ch: TuiCanv.Char;
    line: ARRAY MAXLEVEL OF BOOLEAN;
    buf: ARRAY NAMELEN OF CHAR;
BEGIN
    IF self.stale THEN Compute(self) END;

    (* The three pairs, read once per frame.  The chosen row is drawn in the pair
       the tree's focus deserves, and it is one row and not a range: what is
       chosen is where the cursor is, and this is the whole of what says so. *)
    ta := TuiTheme.Attr(TuiTheme.Tree);
    ca := TuiTheme.Attr(TuiTheme.TreeLine);
    ba := TuiTheme.Attr(TuiTheme.TreeBar);

    rows := Rows(self);
    w := self.width;
    x0 := self.x;
    bar := Scrolled(self);
    IF bar THEN
        x1 := x0 + w - BARCOLS - 1
    ELSE
        x1 := x0 + w - 1
    END;
    IF x1 < x0 THEN x1 := x0 END;

    IF self.top > self.n - 1 THEN self.top := self.n - 1 END;
    IF self.top < 0 THEN self.top := 0 END;

    (* Which levels carry a rule on the first row being drawn.  The ancestors of
       the top row are rows above the viewport, so their nsib flags are read
       rather than computed - the walk goes up the array once and not once per
       row, which is the whole reason the flags are kept at all. *)
    FOR L := 0 TO MAXLEVEL - 1 DO line[L] := FALSE END;
    IF self.top > 0 THEN
        L := self.ndep[self.top] - 1;
        IF L > MAXLEVEL - 1 THEN L := MAXLEVEL - 1 END;
        r := self.top - 1;
        WHILE L >= 0 DO
            WHILE (r >= 0) & (self.ndep[r] # L) DO DEC(r) END;
            IF r >= 0 THEN line[L] := self.nsib[r] END;
            DEC(L)
        END
    END;

    FOR i := 0 TO rows - 1 DO
        y := self.y + i;
        IF self.top + i < self.n THEN
            r := self.top + i;
            IF r = self.sel THEN
                IF self.focused THEN
                    ra := TuiTheme.Attr(TuiTheme.TreeSel)
                ELSE
                    ra := TuiTheme.Attr(TuiTheme.TreeSelIdle)
                END
            ELSE
                ra := ta
            END;
            target.Fill(target, x0, y, w, 1, " ", ra);

            d := self.ndep[r];
            IF d > MAXLEVEL - 1 THEN d := MAXLEVEL - 1 END;

            (* The rules of the levels this row hangs inside: every ancestor whose
               own subtree is not finished draws one down the column its marker
               stands in.  The row's own level is not among them - its column is
               the branch drawn below, and it is a tee or an elbow and never a
               plain rule. *)
            FOR L := 0 TO d - 2 DO
                IF line[L] THEN
                    target.Put(target, x0 + L * INDENT, y, TuiCanv.SL_V, ca)
                END
            END;

            ind := d * INDENT;
            tx := ind + 2;
            IF (ind < w) & (tx < w) THEN
                (* The row's own branch, in the two columns to the left of its
                   marker.  The root has none: nothing leads into the first row of
                   a tree, so its marker is in the leftmost column of the widget. *)
                IF d > 0 THEN
                    IF self.nsib[r] THEN
                        ch := TuiCanv.SL_VR
                    ELSE
                        ch := TuiCanv.SL_BL
                    END;
                    target.Put(target, x0 + ind - INDENT, y, ch, ca);
                    target.Put(target, x0 + ind - INDENT + 1, y, TuiCanv.SL_H, ca)
                END;
                IF self.nhas[r] THEN
                    IF IsOpen(self, r) THEN
                        ch := "-"
                    ELSE
                        ch := "+"
                    END;
                    target.Put(target, x0 + ind, y, ch, ra)
                END;
                Strings.Copy(self.nname[r], buf);
                IF Strings.Length(buf) > w - tx THEN buf[w - tx] := 0X END;
                target.Print(target, x0 + tx, y, buf, ra)
            END;

            line[d] := self.nsib[r]
        ELSE
            target.Fill(target, x0, y, w, 1, " ", ta)
        END
    END;

    IF bar THEN
        (* the track is a light shade and the thumb a solid block; where each of
           them goes is Thumb's business, so that a press on the bar lands on
           what the drawing put there *)
        Thumb(self, size, off);
        FOR i := 0 TO rows - 1 DO
            IF (i >= off) & (i < off + size) THEN
                target.Put(target, x0 + w - 1, self.y + i, TuiCanv.BLOCK, ba)
            ELSE
                target.Put(target, x0 + w - 1, self.y + i, TuiCanv.SHADE_LIGHT,
                           ba)
            END
        END
    END
END draw;


PROCEDURE onEvent (self: Tree; VAR e: Events.Event): BOOLEAN;
VAR
    handled: BOOLEAN;
    rows, size, off, row, d, was, wasn: INTEGER;
BEGIN
    handled := FALSE;
    was := self.sel;
    wasn := self.n;

    (* The keys are the window's to hand out, and it hands them to the widget the
       keyboard is on.  A tree that took them regardless would answer for every
       window whose ring it stands in and take the arrows away from the widget
       the walk is on.  The kind is tested beside the focus, as a table tests it.
       A press is not gated either way: the pointer is what says which widget a
       press means. *)
    IF self.focused & (e.kind = Events.KEYBOARD) THEN
        IF Events.IsKey(e, Events.K_UP) THEN
            SetSel(self, self.sel - 1);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_DOWN) THEN
            SetSel(self, self.sel + 1);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_HOME) THEN
            SetSel(self, 0);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_END) THEN
            SetSel(self, self.n - 1);
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_PGUP) THEN
            SetSel(self, self.sel - Rows(self));
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_PGDN) THEN
            SetSel(self, self.sel + Rows(self));
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_RIGHT) THEN
            (* Right opens a shut node that has children, and on anything else it
               steps into the subtree - onto the first child, which is the row
               below.  On a node that is open already it is that step and not a
               second open, which is what makes Right twice on the same node land
               on the first of its children rather than do nothing. *)
            IF (self.sel >= 0) & (self.sel < self.n) & self.nhas[self.sel] &
               ~IsOpen(self, self.sel) THEN
                OpenRow(self, self.sel)
            ELSE
                SetSel(self, self.sel + 1)
            END;
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_LEFT) THEN
            (* Left shuts an open node, and on a node that is already shut it goes
               to the parent - which is the nearest row above at one level less,
               and is found by the same walk up the array the rules are seeded
               from. *)
            IF IsOpen(self, self.sel) THEN
                CloseRow(self, self.sel)
            ELSE
                d := self.sel;
                row := -1;
                IF (self.sel >= 0) & (self.sel < self.n) THEN
                    WHILE (d > 0) & (row < 0) DO
                        DEC(d);
                        IF self.ndep[d] < self.ndep[self.sel] THEN row := d END
                    END
                END;
                IF row >= 0 THEN SetSel(self, row) END
            END;
            handled := TRUE
        END
    END;

    IF ~handled & (e.kind = Events.MOUSE) THEN
        rows := Rows(self);
        IF self.grabbing THEN
            (* The bar has the pointer until the button comes up and follows it
               anywhere, on or off the track - where ScrollTo's clamp pins the
               thumb at the end and holds it there. *)
            IF Events.IsClick(e) THEN
                ScrollTo(self, e.y - self.y - self.grabDY)
            ELSE
                self.grabbing := FALSE
            END;
            handled := TRUE
        ELSIF Events.IsPress(e) & Scrolled(self) &
              (e.x = self.x + self.width - 1) &
              (e.y >= self.y) & (e.y < self.y + rows) THEN
            (* A press on the bar.  On the thumb it takes hold of it; on the
               track either side of it, it moves a page.  It is tested before the
               rows are, because the bar column is inside the tree and a press on
               it must not also choose whichever row it happens to be level
               with. *)
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
            (* A click on the rows, anywhere on a row.  It chooses the row, and
               on a node that has children it opens or shuts it as well.  The
               whole row is the target rather than the marker's own column,
               because the marker is one character wide and a click that aims at
               a name should not have to be aimed twice; the row has no other job
               a press could mean, this widget's selection following its cursor.
               A node with no children has nothing in that column and nothing to
               open, so a click on one chooses it and stops there. *)
            row := self.top + e.y - self.y;
            IF row < self.n THEN
                SetSel(self, row);
                IF self.nhas[row] THEN
                    IF IsOpen(self, row) THEN
                        CloseRow(self, row)
                    ELSE
                        OpenRow(self, row)
                    END
                END
            END;
            handled := TRUE
        END
    END;

    (* One id, fired once, and only when the picture it describes has moved: a
       press that chose the row the cursor was on already is not news, and an
       owner redrawing a status line on every such press would be redrawing it
       for nothing.  Opening and closing count as movement as much as the cursor
       does - the row count is what says so. *)
    IF handled & ((self.sel # was) OR (self.n # wasn)) THEN
        IF self.cmd # 0 THEN
            TuiWin.Notify(self.host, self, self.cmd)
        END
    END;
    IF handled THEN
        e.kind := Events.NONE            (* taken: nobody further down sees it *)
    END;
    RETURN handled
END onEvent;


(* The two ways in for a router that does not know what kind of widget this is:
   take an event, and take the keyboard on or off.  Both are declared for
   TuiWidg.Widget, which is what a window's ring holds, and both narrow back to a
   tree before doing anything - the guard on the type, the cast for the fields. *)
PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR t: Tree; h: BOOLEAN;
BEGIN
    h := FALSE;
    IF w IS Tree THEN
        t := w(Tree);
        h := t.onEvent(t, e)
    END;
    RETURN h
END Handle;


PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR t: Tree;
BEGIN
    IF w IS Tree THEN
        t := w(Tree);
        t.focused := on
    END
END Take;


PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR t: Tree;
BEGIN
    IF w IS Tree THEN
        t := w(Tree);
        t.draw(t, target)
    END
END Paint;


PROCEDURE DoneTree (self: Oberon.Object);
VAR t: Tree;
BEGIN
    t := self(Tree);
    DISPOSE(t)
END DoneTree;


(* A tree of the window host, which takes it from here.  The two questions are
   handed over after the widget exists and not as arguments to Create, which is
   what makes "read it again" one act with one name: SetRoot and Reset are the
   calls, and the widget is hollow until Reset has been made.

   Nothing is asked of the owner here, so a tree that is made and never reset is
   a widget of no rows - which draws as the empty surface it is. *)
PROCEDURE Create* (x, y, w, h: INTEGER; cmd: INTEGER;
                   env: TuiWidg.Widget; host: TuiWin.Window): Tree;
VAR t: Tree;
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
    t.lastCmd := 0;
    t.n := 0;
    t.sel := 0;
    t.top := 0;
    t.Count := NIL;
    t.Child := NIL;
    t.env := env;
    t.cmd := cmd;
    t.host := host;
    t.grabbing := FALSE;
    t.grabDY := 0;
    t.stale := TRUE;
    t.nname[0][0] := 0X;
    t.draw := draw;
    t.onEvent := onEvent;
    t.handler := Handle;
    t.taker := Take;
    t.painter := Paint;
    t.onCommand := NIL;                  (* a tree fires ids, it takes none *)
    t.SetRoot := SetRoot;
    t.Reset := Reset;
    t.Open := Open;
    t.Close := Close;
    t.Toggle := Toggle;
    t.Select := Select;
    t.SelId := SelId;
    t.Level := Level;
    t.NodeChanged := NodeChanged;
    t.Done := DoneTree;
    TuiWin.Own(host, t);
    RETURN t
END Create;

END TuiTree.
