MODULE TuiTab;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A row of tabs, one of them chosen: the header of a set of panels of which one
   is on show.  A click on a title chooses it, and so do the arrow keys while
   the strip has the keyboard.

   It is a switcher and nothing else.  The panels are the owner's - drawn by the
   owner's own widgets, into the owner's own window - and all this widget does
   when the choice changes is fire the command id it was given.  A tab control
   that drew its panels would have to know what a widget is, and no widget here
   knows that of another: they are handed to each other only as opaque data, and
   this one would be the first exception.

   Its titles are its own, as a menu bar's are: fixed text the owner writes once,
   so AddTab stores a copy and there is nothing to read back through a callback.
   A combo box is the other way round for the other reason - its items are a list
   the owner may change under it, so they are read afresh at every use.  Both are
   the same rule: what a widget does not own it has to ask for, and what it owns
   it may keep.

   The chosen tab is drawn in the pair a selection is drawn in - the focused one
   while the strip has the keyboard and the idle one while it does not - which is
   the rule a list follows, and the reason the strip needs no theme slot of its
   own.  The rest are simply the frame's pair, which is the colour of the body
   the strip covers.

   Those are the list's two slots and not the title bar's, and the difference is
   measurable rather than a matter of taste: a title bar's idle pair is the
   frame's own in the mono theme, so a strip in a window that does not have the
   keyboard would draw its chosen tab in the colour of the tabs either side of it
   and nothing on the screen would say which panel is on show.  The list's two
   differ from the frame in both themes.

   Two titles are separated by a bar, drawn in the body's pair rather than in
   either tab's, so the strip reads as the row of names it is: the bar belongs to
   neither of the two names it stands between, which is why a tab's own fill
   stops short of it and only the last tab has none after it.  The bar is inside
   the tab's rectangle all the same, so a press on it answers with the tab it
   divides the row after - the same rule the pad columns keep, and the reason no
   column of the strip is dead.

   A tab wider than what is left of the strip is cut by the canvas, like every
   other cell a widget writes past its own rectangle; one that would start past
   the strip's right edge is not drawn at all and not hit, so a strip with more
   titles than room never answers a click on a tab that is not on the screen. *)

IMPORT TuiCanv, Events, Strings, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST
    MAXTAB = 8;                     (* titles the strip holds *)
    TEXTLEN = 24;                   (* bytes one takes, its 0X included *)
    PADL = 1;                       (* blank columns left of a title *)
    PADR = 1;                       (* and right of it *)
    SEP = 1;                        (* and the bar between two of them *)

TYPE

    Tabs* = POINTER TO TabsDesc;

    TabsDesc* = RECORD (TuiWidg.WidgetDesc)
        ntab: INTEGER;              (* how many titles it holds *)
        titles: ARRAY MAXTAB OF ARRAY TEXTLEN OF CHAR;
        sel*: INTEGER;              (* the chosen tab *)
        cmd*: INTEGER;              (* the id the owner is told when it changes,
                                       handed to the window that owns it *)
        (* The window that owns it.  A host of NIL is a strip nobody owns but
           its maker, and it is then up to that maker to place it, paint it and
           free it. *)
        host: TuiWin.Window;

        draw*:    PROCEDURE (self: Tabs; target: TuiCanv.Canvas);
        onEvent*: PROCEDURE (self: Tabs; VAR e: Events.Event): BOOLEAN;
        AddTab*:  PROCEDURE (self: Tabs; title: ARRAY OF CHAR): INTEGER;
        Select*:  PROCEDURE (self: Tabs; i: INTEGER);
        Name*:    PROCEDURE (self: Tabs; i: INTEGER; VAR dst: ARRAY OF CHAR);
        SetPos*:  PROCEDURE (self: Tabs; x, y: INTEGER)
    END;


(* The column the title of tab i starts at: one pad column in from the strip's
   left edge, and each one after it at PADL + its title + PADR + SEP.

   TuiMenu.TopX is this same line, and the pad column is part of the tab rather
   than white space outside it for the same reason it is part of a menu title:
   TabAt subtracts the same PADL, so a tab's hit region reaches the strip's own
   left edge and no column of the row is dead.  The bar between two titles is
   inside that region for the same reason. *)
PROCEDURE TabX (self: Tabs; i: INTEGER): INTEGER;
VAR k, x: INTEGER;
BEGIN
    x := self.x + PADL;
    k := 0;
    WHILE k < i DO
        x := x + Strings.Length(self.titles[k]) + PADL + PADR + SEP;
        INC(k)
    END;
    RETURN x
END TabX;


(* How many columns a title with its two pad columns takes, which is what the
   tab draws in its own pair.  The bar after it is not part of this - it is
   drawn in the body's pair and its width is SEP - but it is part of the tab's
   rectangle below, which is what TabAt measures. *)
PROCEDURE TextW (self: Tabs; i: INTEGER): INTEGER;
VAR w: INTEGER;
BEGIN
    w := Strings.Length(self.titles[i]) + PADL + PADR;
    RETURN w
END TextW;


(* And the whole rectangle a tab occupies, the bar after it included.  The last
   tab's rectangle runs one column past anything it draws, which costs nothing
   and is what keeps the row free of dead columns at that end too. *)
PROCEDURE TabW (self: Tabs; i: INTEGER): INTEGER;
VAR w: INTEGER;
BEGIN
    w := TextW(self, i) + SEP;
    RETURN w
END TabW;


(* Which tab covers column x, -1 for none.  A tab that starts past the strip's
   right edge is not there to be hit, whatever the arithmetic of the columns
   before it says. *)
PROCEDURE TabAt (self: Tabs; x: INTEGER): INTEGER;
VAR i, k, found: INTEGER;
BEGIN
    found := -1;
    FOR i := 0 TO self.ntab - 1 DO
        k := TabX(self, i) - PADL;
        IF (TabX(self, i) < self.x + self.width) &
           (x >= k) & (x < k + TabW(self, i)) THEN
            found := i
        END
    END;
    RETURN found
END TabAt;


(* The pair a tab is drawn in.  The chosen one wears the selection pair - the
   focused one while the strip has the keyboard and the idle one while it does
   not, which is the whole difference between a window that is being worked in
   and one that is not - and every other tab wears the frame's, which is the pair
   of the body the strip sits on. *)
PROCEDURE Attr (self: Tabs; i: INTEGER): INTEGER;
VAR a: INTEGER;
BEGIN
    IF i = self.sel THEN
        IF self.focused THEN
            a := TuiTheme.Attr(TuiTheme.ListSel)
        ELSE
            a := TuiTheme.Attr(TuiTheme.ListSelIdle)
        END
    ELSE
        a := TuiTheme.Attr(TuiTheme.Frame)
    END;
    RETURN a
END Attr;


PROCEDURE draw (self: Tabs; target: TuiCanv.Canvas);
VAR i, x, w, a: INTEGER;
BEGIN
    FOR i := 0 TO self.ntab - 1 DO
        x := TabX(self, i);
        IF x < self.x + self.width THEN
            w := TextW(self, i);
            a := Attr(self, i);
            (* the fill starts at the tab's left pad column, so the tab's whole
               region is its own and the boundary between two of them is where
               their pairs meet *)
            target.Fill(target, x - PADL, self.y, w, 1, " ", a);
            target.Print(target, x, self.y, self.titles[i], a);
            (* and the bar that separates it from the tab after it, in the
               body's pair: it belongs to neither of the two names it stands
               between, which is why the fill above stops short of it.  The last
               tab has nothing after it and so draws none. *)
            IF i < self.ntab - 1 THEN
                target.Print(target, x - PADL + w, self.y, "|",
                             TuiTheme.Attr(TuiTheme.Frame))
            END
        END
    END
END draw;


PROCEDURE ClampSel (self: Tabs);
BEGIN
    IF self.sel > self.ntab - 1 THEN self.sel := self.ntab - 1 END;
    IF self.sel < 0 THEN self.sel := 0 END
END ClampSel;


(* Choose tab i and tell the owner, if i is one of the tabs and is not the one
   already chosen.

   A press on the tab that is already chosen is still the strip's - the click
   was answered, it just had nothing to do - which is the distinction TuiRadio
   makes for a click on the row that is already chosen, and it is what keeps a
   press on the strip from falling through to whatever is behind it.  A click
   on no tab at all is declined, and does fall through. *)
PROCEDURE Pick (self: Tabs; i: INTEGER): BOOLEAN;
VAR hit: BOOLEAN;
BEGIN
    hit := (i >= 0) & (i < self.ntab);
    IF hit & (i # self.sel) THEN
        self.sel := i;
        TuiWin.Notify(self.host, self, self.cmd)
    END;
    RETURN hit
END Pick;


(* The arrows walk the tabs and switch as they go, which is what the keys of a
   tab control do and the reason there is nothing to press afterwards: the panel
   appears under the strip while the arrow is still being held down.

   The walk is a ring, so neither end of the strip is a dead one.  Ctrl+arrow is
   deliberately left alone: the scan code is the plain arrow's and no code of its
   own, so a field in the panel on show would lose its word walk to the strip
   standing over it - the same guard the application's own rings keep.

   Nothing else is taken.  Tab in particular is not: it is how the application
   walks the widgets of the panel, and a strip that ate it would strand them. *)
PROCEDURE onEvent (self: Tabs; VAR e: Events.Event): BOOLEAN;
VAR hit: BOOLEAN; i: INTEGER;
BEGIN
    hit := FALSE;
    IF Events.IsPress(e) & TuiWidg.Inside(self, e.x, e.y) THEN
        hit := Pick(self, TabAt(self, e.x))
    ELSIF self.focused THEN
        IF Events.IsKey(e, Events.K_LEFT) & ~e.ctrl THEN
            i := self.sel - 1;
            IF i < 0 THEN i := self.ntab - 1 END;
            hit := Pick(self, i)
        ELSIF Events.IsKey(e, Events.K_RIGHT) & ~e.ctrl THEN
            i := self.sel + 1;
            IF i > self.ntab - 1 THEN i := 0 END;
            hit := Pick(self, i)
        ELSIF Events.IsKey(e, Events.K_HOME) THEN
            hit := Pick(self, 0)
        ELSIF Events.IsKey(e, Events.K_END) THEN
            hit := Pick(self, self.ntab - 1)
        END
    END;
    IF hit THEN
        e.kind := Events.NONE
    END;
    RETURN hit
END onEvent;


(* The two ways in for a router that does not know what kind of widget this is:
   take an event, and take the keyboard on or off.  Both are declared for
   TuiWidg.Widget, which is what a window's ring holds, and both narrow back to
   a strip before doing anything - the guard on the type, the cast for the
   fields.

   A strip is the one widget here whose own keys are the arrows: the walk offers
   it the event first, so Left and Right reach it while it has the keyboard and
   reach the ring only from a widget that declines them - which is to say, never,
   because the ring moves on Tab. *)
PROCEDURE Take (w: TuiWidg.Widget; on: BOOLEAN);
VAR t: Tabs;
BEGIN
    IF w IS Tabs THEN
        t := w(Tabs);
        t.focused := on
    END
END Take;


PROCEDURE Handle (w: TuiWidg.Widget; VAR e: Events.Event): BOOLEAN;
VAR t: Tabs; r: BOOLEAN;
BEGIN
    r := FALSE;
    IF w IS Tabs THEN
        t := w(Tabs);
        r := t.onEvent(t, e)
    END;
    RETURN r
END Handle;


(* One title, and the index it went to - or -1 when the strip is full, which is
   the one answer a caller can do nothing about.  TuiRadio.AddItem answers the
   same way. *)
PROCEDURE AddTab (self: Tabs; title: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
    i := -1;
    IF self.ntab < MAXTAB THEN
        i := self.ntab;
        Strings.Copy(title, self.titles[i]);
        INC(self.ntab)
    END;
    RETURN i
END AddTab;


(* Choose without firing anything, which is how an owner puts the strip in step
   with a choice something else made - a menu entry, or a key of its own.  It is
   not the user choosing and must not come back as a command. *)
PROCEDURE Select (self: Tabs; i: INTEGER);
BEGIN
    self.sel := i;
    ClampSel(self)
END Select;


(* The title of tab i, or an empty string for an index the strip does not have.
   The owner wrote the titles, so it does not learn them here; this is for what
   a program says about a choice it did not make itself, which is a status line.
   TuiCmb.ItemText is the same idea with the owner's data behind it. *)
PROCEDURE Name (self: Tabs; i: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN
    dst[0] := 0X;
    IF (i >= 0) & (i < self.ntab) THEN
        Strings.Copy(self.titles[i], dst)
    END
END Name;


PROCEDURE SetPos (self: Tabs; x, y: INTEGER);
BEGIN
    self.x := x;
    self.y := y
END SetPos;


(* Give the strip back.  Its titles are its own and go with it, so this is one
   line - and it stands before the adapters and Create for the reason Create is
   not last here: Create binds this into the inherited Done field, and a
   procedure has to be declared before it is used. *)
PROCEDURE DoneTabs (self: Oberon.Object);
VAR t: Tabs;
BEGIN
    t := self(Tabs);
    DISPOSE(t)
END DoneTabs;


(* Where it draws itself, for a window that paints what it owns. *)
PROCEDURE Paint (w: TuiWidg.Widget; target: TuiCanv.Canvas);
VAR t: Tabs;
BEGIN
    IF w IS Tabs THEN
        t := w(Tabs);
        t.draw(t, target)
    END
END Paint;


(* A strip of the window host, which takes it from here: it is painted with
   everything else that window owns and given back when the window is.  A host of
   NIL is a strip nobody owns but its maker, and it is then up to that maker to
   place it, paint it and free it, as before. *)
PROCEDURE Create* (x, y, w: INTEGER; cmd: INTEGER;
                   host: TuiWin.Window): Tabs;
VAR t: Tabs;
BEGIN
    ASSERT(w >= 4);
    NEW(t);
    t.x := x;
    t.y := y;
    t.width := w;
    t.height := 1;
    t.visible := TRUE;
    t.focused := FALSE;
    t.canvas := NIL;
    t.ntab := 0;
    t.sel := 0;
    t.cmd := cmd;
    t.lastCmd := 0;
    t.host := host;
    t.draw := draw;
    t.onEvent := onEvent;
    t.handler := Handle;
    t.taker := Take;
    t.painter := Paint;
    t.onCommand := NIL;                 (* a strip fires ids, it does not take them *)
    t.AddTab := AddTab;
    t.Select := Select;
    t.Name := Name;
    t.SetPos := SetPos;
    t.Done := DoneTabs;
    TuiWin.Own(host, t);
    RETURN t
END Create;

END TuiTab.
