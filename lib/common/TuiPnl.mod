MODULE TuiPnl;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A panel: a widget whose parts are widgets.

   The children of a panel are ordinary widgets of the window the panel is in -
   the window owns them and they stand in its ring, exactly as the buttons beside
   them do.  So a panel routes nothing.  An event is offered to its children by
   the window, in the order they were added, and each child decides for itself
   whether the event is for it, which is what a widget has always done.  What a
   panel adds is the three things a child cannot work out for itself: where it
   goes, what happens to it when the panel is hidden, and what it is told when
   the room the panel has changed.

   Two kinds of panel, and the difference is one decision.

   A PLAIN panel puts nothing anywhere.  Its children keep the rectangles the
   owner gave them, and what the panel does is carry them when it is moved and
   hide them when it is hidden.  It is a group, and the whole of its point is
   that an owner can hold one thing and say "all of these" to it.

   A BORDER panel lays its children out in five places: UP, DOWN, LEFT and RIGHT
   hold to their edge and keep the thickness they were added with, and CENTER is
   what is left - the one that grows and shrinks with the panel.  That is the
   whole of what "this widget stretches with its window" means here, and it is
   reached from above.  A window that is resized tells every widget it owns that
   has a resizer; a panel that has been told to stretch answers by taking the
   window's own interior as its rectangle; the sides keep their thickness and the
   centre child takes what they leave.  A list, a table, a text area read their
   geometry as they draw, so the centre child is drawn to its new size on the
   very next frame with nothing called on it at all - the panel is the only part
   that had to be told.

   The cells between a panel's edge and its children are its gap wide, which is
   GAP unless SetGap says otherwise, and a child is placed inside the panel,
   never on its frame.  The gap is the panel's own and not a constant because
   the two uses want different numbers: a panel that stands in a room beside
   other things needs a cell of air round it, and a panel that IS a window's
   whole interior does not - the window's frame is already the inset, and one
   more cell on each side is a cell of the picture given away.  A panel is drawn
   before its children - the window takes them in the order they were created -
   so a child must be created after the panel it belongs to, and a panel that
   paints a surface of its own (only a border panel does) paints it under them.

   A split line is a cell of a border panel's own: one cell between a side and
   what is next to it, drawn as a rule, and taken hold of with the mouse to move
   that border.  A side with a split set keeps the line and a side without one
   keeps nothing - two children that meet are adjacent, as they were before.  The
   line is one cell wide because the drag needs a cell of its own that is not
   also a cell of either child: a boundary with no cell between the two is a
   boundary a press cannot be aimed at, and it would have to be guessed at from
   which half of a child's own cell the pointer was in.

   Only a border panel is ever dragged, and only at a line it has; the panel is
   in the window's ring for that reason and for no other - it has no keyboard and
   takes no command, so the Tab walk steps over it, and every other event it is
   offered it declines.

   Hiding is recursive here and is a fact about the widget, not about the
   drawing.  A hidden widget is not painted, is not offered an event, is never
   focused and never answers an id - that is Windows' rule and it is what makes
   Show below the whole of hiding a subtree: the children of a hidden panel are
   hidden, a panel among them takes its own, and a hidden widget is inert rather
   than merely invisible.  Show takes any widget, so an owner says the same
   sentence about a list, a button and a panel - a panel's own SetVisible is the
   same call with the receiver in hand.

   A hidden child keeps its place.  Laying out around it would mean that showing
   a status line moved everything above it, and the panel's own rectangle is the
   surface that shows through where a hidden child was - which is what the same
   program does everywhere else, and is what makes a hidden part safe to bring
   back.

   There is no clipping anywhere in this framework, and a panel is where that
   shows: a child that is wider than the panel draws over what is beside it.
   Border layout never does that to a child of its own - every child is placed
   inside the panel - but an owner that places a plain panel's children itself, or
   a child that paints outside its rectangle, is the owner's business.
*)

IMPORT TuiCanv, Events, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST

    (* The two kinds. *)
    PLAIN* = 0;
    BORDER* = 1;

    (* The five places a child of a border panel goes.  A plain panel ignores
       the side it is handed. *)
    UP* = 0; DOWN* = 1; LEFT* = 2; RIGHT* = 3; CENTER* = 4;

    MAXCHILD* = 8;                  (* children one panel may hold *)

    (* The cells a child keeps from the panel's own edge, on every side: what a
       panel is made with, and what SetGap changes. *)
    GAP* = 1;

    (* What a drag may not go past.  A side is never squeezed below MINSIDE and
       the centre never gives up more than MINCENTER, so a line dragged to either
       end of its travel leaves two widgets rather than one and a sliver. *)
    MINSIDE = 2;
    MINCENTER = 3;

TYPE

    Panel* = POINTER TO PanelDesc;

    PanelDesc* = RECORD (TuiWidg.WidgetDesc)
        (* The window it is in.  A host of NIL is a panel nobody owns but its
           maker, and it is then up to that maker to place it, paint it and free
           it - the same rule a list has. *)
        host: TuiWin.Window;

        kids: ARRAY MAXCHILD OF TuiWidg.Widget;
        where: ARRAY MAXCHILD OF INTEGER;
        nkids: INTEGER;

        mode*: INTEGER;

        (* It follows the room its window has.  Off, the panel is where the
           owner put it and stays there however the window is resized. *)
        stretch*: BOOLEAN;

        (* The cells between the panel's edge and its children, on every side.
           GAP when the panel is made. *)
        gap*: INTEGER;

        (* Which sides have a split line. *)
        split: SET;

        (* What each side asks for, in cells: a height for UP and DOWN, a width
           for LEFT and RIGHT.  Read once, from the child, when the child is
           added, and changed from then on by a drag or by SetSide - the columns
           of a table are the same idea, and for the same reason: a size that is
           asked for on every frame is a size a drag cannot own. *)
        up, down, left, right: INTEGER;

        (* The line being dragged, or -1, and how far along it the pointer took
           hold.  Without the offset the line would jump under the pointer at the
           first movement, which is the bug a list's scrollbar keeps grabDY for. *)
        drag: INTEGER;
        grab: INTEGER;

        (* The id fired when a drag has moved a line.  A panel fires one thing
           and only this: the owner asked to be told when the layout moved, and
           nothing else about a panel is an event. *)
        cmd*: INTEGER;

        draw*:    PROCEDURE (self: Panel; target: TuiCanv.Canvas);
        onEvent*: PROCEDURE (self: Panel; VAR e: Events.Event): BOOLEAN;
        Add*:      PROCEDURE (self: Panel; kid: TuiWidg.Widget; side: INTEGER);
        SetRect*:  PROCEDURE (self: Panel; x, y, w, h: INTEGER);
        SetPos*:   PROCEDURE (self: Panel; x, y: INTEGER);
        SetVisible*: PROCEDURE (self: Panel; on: BOOLEAN);
        Stretch*:  PROCEDURE (self: Panel; on: BOOLEAN);
        SetGap*:   PROCEDURE (self: Panel; n: INTEGER);
        SetSplit*: PROCEDURE (self: Panel; side: INTEGER; on: BOOLEAN);
        SetSide*:  PROCEDURE (self: Panel; side, n: INTEGER);
        SideSize*: PROCEDURE (self: Panel; side: INTEGER): INTEGER;
        SetCmd*:   PROCEDURE (self: Panel; cmd: INTEGER);
        Layout*:   PROCEDURE (self: Panel)
    END;


(* Move everything a plain panel holds by the same amount.  A plain panel has no
   layout to work one out again from, so it is carried rather than placed - and a
   panel among what it holds is carried whole, which is why this goes all the way
   down instead of one level. *)
PROCEDURE Carry (p: Panel; dx, dy: INTEGER);
VAR i: INTEGER; kid: TuiWidg.Widget; q: Panel;
BEGIN
    FOR i := 0 TO p.nkids - 1 DO
        kid := p.kids[i];
        TuiWidg.SetRect(kid, kid.x + dx, kid.y + dy, kid.width, kid.height);
        IF kid IS Panel THEN
            q := kid(Panel);
            Carry(q, dx, dy)
        END
    END
END Carry;


(* Put a child where the layout says it goes.  A size below one cell is not a
   size, and a widget that is zero cells wide is a widget that divides by it, so
   the floor is applied here rather than in every caller.

   A child that is itself a panel is carried to its place and not simply moved:
   what a panel holds has to travel with it, and this is the one place in the
   layout that can move a panel - the pass at the end of Layout re-places what an
   inner panel holds when that panel lays out again, and says nothing to a plain
   one. *)
PROCEDURE Place (kid: TuiWidg.Widget; x, y, w, h: INTEGER);
VAR p: Panel; dx, dy: INTEGER;
BEGIN
    IF w < 1 THEN w := 1 END;
    IF h < 1 THEN h := 1 END;
    IF kid IS Panel THEN
        p := kid(Panel);
        dx := x - p.x;
        dy := y - p.y;
        IF (dx # 0) OR (dy # 0) THEN
            Carry(p, dx, dy)
        END
    END;
    TuiWidg.SetRect(kid, x, y, w, h)
END Place;


(* Put every child of a border panel where it belongs, and then let the panels
   among them do the same for theirs.

   The sides are placed in two passes, and not in the order the children were
   added, because a left child's height is what the up and the down children left
   it: a panel whose left child was added first would be laid out against a
   rectangle the up child has not taken its rows from yet.  The centre is a third
   pass for the same reason - it is the remainder of both axes at once.

   A plain panel lays out nothing: its children are where the owner put them. *)
PROCEDURE Layout* (self: Panel);
VAR i, ix, iy, iw, ih, top, bot, lf, rt: INTEGER; p: Panel;
BEGIN
    IF self.mode = BORDER THEN
        ix := self.x + self.gap;
        iy := self.y + self.gap;
        iw := self.width - 2 * self.gap;
        ih := self.height - 2 * self.gap;
        IF iw < 1 THEN iw := 1 END;
        IF ih < 1 THEN ih := 1 END;
        top := iy;
        bot := iy + ih;
        lf := ix;
        rt := ix + iw;
        FOR i := 0 TO self.nkids - 1 DO
            IF self.where[i] = UP THEN
                Place(self.kids[i], ix, top, iw, self.up);
                top := top + self.up;
                IF UP IN self.split THEN top := top + 1 END
            ELSIF self.where[i] = DOWN THEN
                bot := bot - self.down;
                Place(self.kids[i], ix, bot, iw, self.down);
                IF DOWN IN self.split THEN bot := bot - 1 END
            END
        END;
        FOR i := 0 TO self.nkids - 1 DO
            IF self.where[i] = LEFT THEN
                Place(self.kids[i], lf, top, self.left, bot - top);
                lf := lf + self.left;
                IF LEFT IN self.split THEN lf := lf + 1 END
            ELSIF self.where[i] = RIGHT THEN
                rt := rt - self.right;
                Place(self.kids[i], rt, top, self.right, bot - top);
                IF RIGHT IN self.split THEN rt := rt - 1 END
            END
        END;
        FOR i := 0 TO self.nkids - 1 DO
            IF self.where[i] = CENTER THEN
                Place(self.kids[i], lf, top, rt - lf, bot - top)
            END
        END;
        FOR i := 0 TO self.nkids - 1 DO
            IF self.kids[i] IS Panel THEN
                p := self.kids[i](Panel);
                Layout(p)
            END
        END
    END
END Layout;


(* The most a side may be asked for: the panel's own room on that axis, less
   what the side opposite it takes, less the centre's floor, less the line
   itself.  A panel too small to hold all three answers MINSIDE, which is the
   smallest answer that is still a widget. *)
PROCEDURE MaxSide (self: Panel; side: INTEGER): INTEGER;
VAR room, other: INTEGER;
BEGIN
    IF side = UP THEN
        room := self.height - 2 * self.gap;
        other := self.down;
        IF DOWN IN self.split THEN other := other + 1 END
    ELSIF side = DOWN THEN
        room := self.height - 2 * self.gap;
        other := self.up;
        IF UP IN self.split THEN other := other + 1 END
    ELSIF side = LEFT THEN
        room := self.width - 2 * self.gap;
        other := self.right;
        IF RIGHT IN self.split THEN other := other + 1 END
    ELSE
        room := self.width - 2 * self.gap;
        other := self.left;
        IF LEFT IN self.split THEN other := other + 1 END
    END;
    room := room - other - MINCENTER - 1;
    IF room < MINSIDE THEN room := MINSIDE END;
    RETURN room
END MaxSide;


(* Move one side's border.  What a drag calls at every step and what an owner
   calls to set a layout up, so both go through the same clamp and the same
   relayout. *)
PROCEDURE SetSide* (self: Panel; side, n: INTEGER);
VAR m: INTEGER;
BEGIN
    m := MaxSide(self, side);
    IF n < MINSIDE THEN n := MINSIDE END;
    IF n > m THEN n := m END;
    IF side = UP THEN
        self.up := n
    ELSIF side = DOWN THEN
        self.down := n
    ELSIF side = LEFT THEN
        self.left := n
    ELSE
        self.right := n
    END;
    Layout(self)
END SetSide;


(* What a side asks for now, which is what a drag has left it at. *)
PROCEDURE SideSize* (self: Panel; side: INTEGER): INTEGER;
VAR n: INTEGER;
BEGIN
    IF side = UP THEN
        n := self.up
    ELSIF side = DOWN THEN
        n := self.down
    ELSIF side = LEFT THEN
        n := self.left
    ELSE
        n := self.right
    END;
    RETURN n
END SideSize;


PROCEDURE SetCmd* (self: Panel; cmd: INTEGER);
BEGIN
    self.cmd := cmd
END SetCmd;


(* Which split line the cell is on, or -1.  The line is the cell the layout left
   between the side and what it borders, so the two agree by construction: the
   test is the same arithmetic the layout is, read backwards.

   The panel's own rectangle is tested first, so a cell outside it is never a
   line however the numbers work out. *)
PROCEDURE HitSplit (self: Panel; x, y: INTEGER): INTEGER;
VAR r, ix, iy, iw, ih: INTEGER;
BEGIN
    r := -1;
    IF TuiWidg.Inside(self, x, y) THEN
        ix := self.x + self.gap;
        iy := self.y + self.gap;
        iw := self.width - 2 * self.gap;
        ih := self.height - 2 * self.gap;
        IF (UP IN self.split) & (y = iy + self.up) &
           (x >= ix) & (x < ix + iw) THEN
            r := UP
        ELSIF (DOWN IN self.split) & (y = iy + ih - self.down - 1) &
              (x >= ix) & (x < ix + iw) THEN
            r := DOWN
        ELSIF (LEFT IN self.split) & (x = ix + self.left) &
              (y >= iy) & (y < iy + ih) THEN
            r := LEFT
        ELSIF (RIGHT IN self.split) & (x = ix + iw - self.right - 1) &
              (y >= iy) & (y < iy + ih) THEN
            r := RIGHT
        END
    END;
    RETURN r
END HitSplit;


(* The pointer, with a line in hand.  Each side's border is worked out from the
   cell the pointer is on and the offset the grab was taken with, so the line
   travels with the pointer rather than jumping to it; SetSide does the clamping,
   so a drag that runs off the panel ends with the two children at their smallest
   rather than in a panel with a negative child in it. *)
PROCEDURE Follow (self: Panel; x, y: INTEGER);
VAR n: INTEGER;
BEGIN
    IF self.drag = UP THEN
        n := y - self.grab - (self.y + self.gap)
    ELSIF self.drag = DOWN THEN
        n := (self.y + self.height - self.gap - 1) - (y - self.grab)
    ELSIF self.drag = LEFT THEN
        n := x - self.grab - (self.x + self.gap)
    ELSE
        n := (self.x + self.width - self.gap - 1) - (x - self.grab)
    END;
    SetSide(self, self.drag, n)
END Follow;


(* The panel's own event: a drag in progress follows the pointer, and a press on
   a split line begins one.  Everything else is declined, which is what leaves an
   event to the children behind it in the ring.

   A drag that has begun is followed wherever the pointer goes and whatever is
   under it, like a scrollbar's thumb, and it ends when the button comes up.  The
   id is fired at the end and not at every step: what an owner wants to know is
   where the layout came to rest.

   The hole a list's scrollbar has, a panel has too, and it is worth naming: a
   drag released over another window never reaches here - the desktop gives the
   mouse to the window under the pointer - so the panel keeps the line in hand
   until the next mouse event inside it ends the drag.  Nothing is wrong with the
   layout in the meantime, and the missed release fires no id. *)
PROCEDURE OnEvent (self: Panel; VAR e: Events.Event): BOOLEAN;
VAR s: INTEGER; handled: BOOLEAN;
BEGIN
    handled := FALSE;
    IF e.kind = Events.MOUSE THEN
        IF self.drag >= 0 THEN
            IF Events.IsClick(e) THEN
                Follow(self, e.x, e.y)
            ELSIF Events.IsRelease(e) THEN
                self.drag := -1;
                IF self.cmd # 0 THEN
                    TuiWin.Notify(self.host, self, self.cmd)
                END
            END;
            handled := TRUE
        ELSIF Events.IsPress(e) THEN
            s := HitSplit(self, e.x, e.y);
            IF s >= 0 THEN
                self.drag := s;
                IF s = UP THEN
                    self.grab := e.y - (self.y + self.gap + self.up)
                ELSIF s = DOWN THEN
                    self.grab := e.y - (self.y + self.height - self.gap - self.down - 1)
                ELSIF s = LEFT THEN
                    self.grab := e.x - (self.x + self.gap + self.left)
                ELSE
                    self.grab := e.x - (self.x + self.width - self.gap - self.right - 1)
                END;
                handled := TRUE
            END
        END
    END;
    RETURN handled
END OnEvent;


(* A border panel paints the surface its children sit on, and then the lines
   between them.  The surface is the window's own body pair, which is what keeps
   a panel in a window that keeps a theme of its own looking like the rest of it -
   and it is what a child that moved leaves behind, so it is painted every frame
   and not only when something changes.

   A plain panel paints nothing at all.  It is a group, and a group that painted
   would cover whatever the window's own painter had put there. *)
PROCEDURE Draw (self: Panel; target: TuiCanv.Canvas);
VAR a, ix, iy, iw, ih: INTEGER;
BEGIN
    IF self.visible & (self.mode = BORDER) & (self.width > 1) & (self.height > 1)
    THEN
        IF self.host # NIL THEN
            a := TuiWin.Attr(self.host, TuiTheme.Frame)
        ELSE
            a := TuiTheme.Attr(TuiTheme.Frame)
        END;
        target.Fill(target, self.x, self.y, self.width, self.height, " ", a);
        a := TuiTheme.Attr(TuiTheme.Rule);
        ix := self.x + self.gap;
        iy := self.y + self.gap;
        iw := self.width - 2 * self.gap;
        ih := self.height - 2 * self.gap;
        IF iw < 1 THEN iw := 1 END;
        IF ih < 1 THEN ih := 1 END;
        IF (UP IN self.split) & (self.up + 1 < ih) THEN
            target.HLine(target, ix, iy + self.up, iw, TuiCanv.SL_H, a)
        END;
        IF (DOWN IN self.split) & (self.down + 1 < ih) THEN
            target.HLine(target, ix, iy + ih - self.down - 1, iw,
                         TuiCanv.SL_H, a)
        END;
        IF (LEFT IN self.split) & (self.left + 1 < iw) THEN
            target.VLine(target, ix + self.left, iy, ih, TuiCanv.SL_V, a)
        END;
        IF (RIGHT IN self.split) & (self.right + 1 < iw) THEN
            target.VLine(target, ix + iw - self.right - 1, iy, ih,
                         TuiCanv.SL_V, a)
        END
    END
END Draw;


(* What the window calls when its own room changed.  A panel that stretches takes
   the window's interior - one cell in on each side, which is what the frame
   takes - and lays out again; a panel that does not is left where the owner put
   it.  A centre child of a stretched panel follows without being told, because a
   child's geometry is read when it draws. *)
PROCEDURE Resize (self: Panel; cw, ch: INTEGER);
BEGIN
    IF self.stretch THEN
        TuiWidg.SetRect(self, 1, 1, cw - 2, ch - 2);
        Layout(self)
    END
END Resize;


(* Tell the panel which of its children is one of its parts, and where that child
   goes.  The child is a widget of the window already - the window owns it and it
   stands in the window's ring - so this is about the layout and about nothing
   else, and a child added twice is a child the layout places twice.

   A side child's thickness is read from the child itself here and remembered:
   the owner sizes the widget it wants and says which edge it holds, and the size
   it gave is what the edge holds on to.  A centre child's size is not read - the
   centre is what the sides leave, and asking the widget for a number would be
   asking it the wrong question. *)
PROCEDURE Add* (self: Panel; kid: TuiWidg.Widget; side: INTEGER);
VAR n: INTEGER;
BEGIN
    IF (kid # NIL) & (self.nkids < MAXCHILD) THEN
        self.kids[self.nkids] := kid;
        self.where[self.nkids] := side;
        self.nkids := self.nkids + 1;
        IF (self.mode = BORDER) & (side # CENTER) THEN
            IF (side = UP) OR (side = DOWN) THEN
                n := kid.height
            ELSE
                n := kid.width
            END;
            (* A floor of one cell and not of MINSIDE, which is what a drag is
               held to.  A side that was added holding one row is a toolbar, and
               a toolbar is a thing an owner asks for; what MINSIDE protects is
               the other end of it, where a line dragged to the edge would leave
               a child with no room at all. *)
            IF n < 1 THEN n := 1 END;
            IF side = UP THEN
                self.up := n
            ELSIF side = DOWN THEN
                self.down := n
            ELSIF side = LEFT THEN
                self.left := n
            ELSE
                self.right := n
            END
        END;
        Layout(self)
    END
END Add;


(* Where the panel is, and how big.  A border panel lays out again - that is what
   a resize means to it - while a plain panel only carries its children along
   when it moves, because a plain panel has been told not to change their size.
   A plain panel moved by SetRect's width and height, then, is a panel whose
   children stay the size they were. *)
PROCEDURE SetRect* (self: Panel; x, y, w, h: INTEGER);
VAR dx, dy: INTEGER;
BEGIN
    dx := x - self.x;
    dy := y - self.y;
    TuiWidg.SetRect(self, x, y, w, h);
    IF self.mode = BORDER THEN
        Layout(self)
    ELSIF (dx # 0) OR (dy # 0) THEN
        Carry(self, dx, dy)
    END
END SetRect;


PROCEDURE SetPos* (self: Panel; x, y: INTEGER);
BEGIN
    SetRect(self, x, y, self.width, self.height)
END SetPos;


(* Show or hide a widget, and a panel takes everything it holds with it.

   Every widget has the flag - it is one field of the base record and the
   framework already tests it in the three places that matter, the paint, the
   walk and the command - so hiding one widget is a write.  What is here and not
   there is the recursion, and it is here because it is a panel that knows what
   it holds: hiding a panel means hiding its children, and a panel among them
   means its own, which is the whole of hiding a subtree.

   The flag and not the drawing is the whole of it.  A widget that is not painted
   but is still offered events is a widget that acts while it is not on the
   screen, and Windows tests `visible` before painting a widget, before offering
   it an event and before handing it an id, so setting the flag here is enough
   and the children need no rule of their own.

   This is the general form, and a panel's own SetVisible is the same call with
   the receiver already in hand: one word for a list, a button and a panel, which
   is what an owner that holds all three wants. *)
PROCEDURE Show* (w: TuiWidg.Widget; on: BOOLEAN);
VAR i: INTEGER; p: Panel;
BEGIN
    IF w # NIL THEN
        w.visible := on;
        IF w IS Panel THEN
            p := w(Panel);
            FOR i := 0 TO p.nkids - 1 DO
                Show(p.kids[i], on)
            END
        END
    END
END Show;


PROCEDURE SetVisible* (self: Panel; on: BOOLEAN);
BEGIN
    Show(self, on)
END SetVisible;


(* Follow the window's room from now on.  Turning it on takes the interior at
   once, so an owner that stretches a panel after building it sees the layout
   change on the frame it asked for and not on the next resize. *)
PROCEDURE Stretch* (self: Panel; on: BOOLEAN);
BEGIN
    self.stretch := on;
    IF on & (self.host # NIL) THEN
        SetRect(self, 1, 1, self.host.width - 2, self.host.height - 2)
    END
END Stretch;


(* How many cells a child keeps from the panel's edge.  It is part of the layout
   and not a look, so this lays out again.

   Two numbers are asked for in practice.  GAP, which is what a panel is made
   with and what a panel standing among others wants, and 0, which is what a
   panel that IS a window's interior wants: its children then reach the frame,
   which is where they were before there was a panel - the frame is the inset,
   and the room a stretched panel is given is exactly the room a window's own
   widgets used to be placed in, cell for cell. *)
PROCEDURE SetGap* (self: Panel; n: INTEGER);
BEGIN
    IF n < 0 THEN n := 0 END;
    self.gap := n;
    Layout(self)
END SetGap;


(* Give a side a split line, or take it away.  The line's cell is part of the
   layout, so this lays out again: turning one on makes the side's child keep its
   thickness and the cell the line lives in appear between it and its neighbour.
   The side's own size is not touched - a line is a cell the layout adds, not a
   cell the children give up. *)
PROCEDURE SetSplit* (self: Panel; side: INTEGER; on: BOOLEAN);
BEGIN
    IF on THEN
        INCL(self.split, side)
    ELSE
        EXCL(self.split, side);
        IF self.drag = side THEN self.drag := -1 END
    END;
    Layout(self)
END SetSplit;


PROCEDURE DonePanel (self: Oberon.Object);
VAR p: Panel;
BEGIN
    p := self(Panel);
    DISPOSE(p)
END DonePanel;


PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR p: Panel;
BEGIN
    IF w IS Panel THEN
        p := w(Panel);
        Draw(p, target)
    END
END Paint;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR p: Panel; h: BOOLEAN;
BEGIN
    h := FALSE;
    IF w IS Panel THEN
        p := w(Panel);
        h := OnEvent(p, e)
    END;
    RETURN h
END Handle;


PROCEDURE Resized (w: TuiWidg.Widget; cw, ch: INTEGER);
VAR p: Panel;
BEGIN
    IF w IS Panel THEN
        p := w(Panel);
        Resize(p, cw, ch)
    END
END Resized;


(* A panel of the window host, which takes it from here.  The children are the
   caller's: each is created with the same host, so the window owns it and paints
   it, and the caller adds it to the window's ring if it is to be offered events -
   which every child except a display-only one is.

   The panel itself enters the ring only if it is given a split line, because the
   ring is where an event is offered and a split is dragged.  It is not a Tab
   stop either way: it has no keyboard. *)
PROCEDURE Create* (x, y, w, h: INTEGER; mode: INTEGER;
                   host: TuiWin.Window): Panel;
VAR p: Panel;
BEGIN
    ASSERT((w > 0) & (h > 0));
    NEW(p);
    p.x := x;
    p.y := y;
    p.width := w;
    p.height := h;
    p.visible := TRUE;
    p.focused := FALSE;
    p.canvas := NIL;
    p.lastCmd := 0;
    p.host := host;
    p.nkids := 0;
    p.mode := mode;
    p.stretch := FALSE;
    p.gap := GAP;
    p.split := {};
    p.up := 0;
    p.down := 0;
    p.left := 0;
    p.right := 0;
    p.drag := -1;
    p.grab := 0;
    p.cmd := 0;
    p.draw := Draw;
    p.onEvent := OnEvent;
    p.handler := Handle;
    p.taker := NIL;
    p.painter := Paint;
    p.resizer := Resized;
    p.onCommand := NIL;
    p.Add := Add;
    p.SetRect := SetRect;
    p.SetPos := SetPos;
    p.SetVisible := SetVisible;
    p.Stretch := Stretch;
    p.SetGap := SetGap;
    p.SetSplit := SetSplit;
    p.SetSide := SetSide;
    p.SideSize := SideSize;
    p.SetCmd := SetCmd;
    p.Layout := Layout;
    p.Done := DonePanel;
    (* The window takes it from here, which is why a panel is created before the
       children it holds: what the window owns is painted in the order it was
       taken, and the surface a border panel paints has to be under them. *)
    TuiWin.Own(host, p);
    RETURN p
END Create;

END TuiPnl.
