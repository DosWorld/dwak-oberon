MODULE TuiMenu;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A menu bar with drop-downs.

   The bar is one row of top level titles; each of them owns a short list of
   entries, and every entry carries an INTEGER command id that the application
   defined.  The bar never acts on a command itself: Enter stores the id in
   lastCmd and closes the menu, and whoever asked for the event reads lastCmd -
   which keeps the framework ignorant of what the commands mean.

   Geometry: a top item takes PADL + the width of its title + PADR columns and
   they follow one another from one pad column in from the left edge of the bar,
   so the position of an item is computed from the widths of the ones before it
   rather than stored.  The leading pad column belongs to the first item, which
   is why the first title is indented and its hit region is not.
   TopX answers where an item starts and TopAt answers which item covers a
   column, which is all the hit testing a bar needs.

   The entries are the one part of this record that is not fixed: a bar may hold
   eight tops and twelve entries under each, but a menu of three items must not
   pay for the ninety-six it might have had.  So the entry text lives in a
   ByteArr, a slot per entry, exactly as a list keeps its items, and the array
   is grown no further than the highest slot in use - a bar whose tops are
   filled in order spends about what its entries need, and one that puts
   entries under a late top and none under an early one spends the gap as
   well, which is the price of an index that is arithmetic rather than state.
   The command ids stay in the record: they are four bytes each and indexing
   them is the same arithmetic, so there is nothing to gain by moving them.

   An entry whose text is one minus and nothing else is a separator.  The box
   draws a line across the row it sits in instead of a title, the mark steps
   over it in both directions, and a click on it chooses nothing.  The text is
   the whole of what makes it one, so an ordinary menu is a menu with no
   separators in it and there is no flag to keep in step with the row.

   An open menu takes every key and every click: nothing behind it may see the
   event that dismissed it.

   A bar also carries shortcuts, which is the other half of what an entry is: a
   key that fires a command without the bar being open.  A shortcut is held by
   the command and not by the entry, and the two are joined by the id - an
   entry whose command has one is drawn with it at the right end of its row,
   and a key whose command has an entry fires what that entry would have fired.
   So a command may have a shortcut and no entry at all, which is what a
   setting no menu carries looks like, and the key and the entry cannot disagree
   about what they mean: there is one record of it and the entry is found by the
   id it already carries.

   That is the whole of what an application has to do about its keys.  It
   declares them once, beside the ids it declares them for, and the bar answers
   them before any widget is offered the event - so there is no chain of
   function keys in the application's own handler, and no rule for it to keep
   about asking for a key before the routing or a widget will eat it.

   F10 is the bar's own and is not available as a shortcut.  A key that opens
   the menu is the one key a shortcut table must not be able to take away.

   The text a shortcut is drawn as is worked out from the key, and not written
   beside it: a name stored on its own is a second thing to keep in step with
   the key it names, and the mismatch it drifts into is invisible - the entry
   would say one key and the bar would answer another. *)

IMPORT ByteArr, TuiCanv, Events, Strings, TuiTheme, TuiWidg, Oberon;

CONST

    MAXTOP* = 8;                    (* top level titles.  Both ceilings are
                                       exported for the same reason: AddTop and
                                       AddItem drop what does not fit and answer
                                       nothing, so the only way an application
                                       can tell is to test against these. *)
    MAXITEM* = 12;                  (* entries under each of them *)
    MAXACCEL* = 24;                 (* keys a bar answers while it is closed.
                                       Exported for the same reason the two
                                       above are: SetShortcut drops the ones
                                       that do not fit and answers nothing. *)
    TEXTLEN = 24;                   (* bytes a title or an entry takes, its 0X
                                       included *)
    PADL = 1;                       (* blank columns left of a title *)
    PADR = 1;                       (* and right of it *)
    SHORTPAD = 2;                   (* blank columns between an entry and the
                                       shortcut drawn at the other end of its
                                       row.  Without it the two would be one
                                       word: nothing else separates them, since
                                       the entry is left justified and the
                                       shortcut right justified on one line. *)

    (* The modifiers of a shortcut, ORed together.  They are bits of one number
       because that is what they are matched as: a keystroke is turned into the
       same number - see Mods - and a key is then one integer and matching it is
       one comparison, where three flags would be three comparisons to keep in
       step with each other. *)
    M_SHIFT* = 1;
    M_CTRL*  = 2;
    M_ALT*   = 4;

    (* Where they sit in that integer, above the scancode.  A scancode is a byte
       - the highest this framework names is 58H - so the byte above it is free
       and the two can never run into each other. *)
    MBASE = 100H;

TYPE

    MenuBar* = POINTER TO MenuBarDesc;

    MenuBarDesc* = RECORD (TuiWidg.WidgetDesc)
        titles: ARRAY MAXTOP OF ARRAY TEXTLEN OF CHAR;
        items: ByteArr.ByteArray;             (* one TEXTLEN slot per entry *)
        cmds: ARRAY MAXTOP * MAXITEM OF INTEGER;
        nitem: ARRAY MAXTOP OF INTEGER;
        (* The keys that fire a command while the bar is closed: the command,
           and the key as the scancode and its modifiers packed into one number
           - see MBASE.  Two arrays and not one because the pair is what a
           shortcut is; a shortcut is looked up by its command when the
           drop-down is drawn and by its key when a keystroke arrives, so both
           halves have to be there and neither is derivable from the other. *)
        acmd: ARRAY MAXACCEL OF INTEGER;
        akey: ARRAY MAXACCEL OF INTEGER;
        naccel: INTEGER;
        total: INTEGER;                         (* slots the array has been grown to *)
        ntop: INTEGER;
        cur*, item*: INTEGER;       (* the highlighted title, and the entry under it *)
        open*: BOOLEAN;             (* the id Enter fired is the base's own
                                       lastCmd; 0 is "none" *)

        draw*:    PROCEDURE (self: MenuBar; target: TuiCanv.Canvas);
        onEvent*: PROCEDURE (self: MenuBar; VAR e: Events.Event): BOOLEAN;
        AddTop*:  PROCEDURE (self: MenuBar; title: ARRAY OF CHAR): INTEGER;
        AddItem*: PROCEDURE (self: MenuBar; top: INTEGER; title: ARRAY OF CHAR;
                             cmd: INTEGER);
        SetShortcut*: PROCEDURE (self: MenuBar; cmd, scan, mods: INTEGER);
        Close*:   PROCEDURE (self: MenuBar)
    END;


(* The slot entry item of top sits in.  It is arithmetic rather than a stored
   base, so entries may be added to the tops in any order; total is how far the
   array has been grown, which is also the highest slot that holds anything. *)
PROCEDURE Slot (self: MenuBar; top, item: INTEGER): INTEGER;
VAR k: INTEGER;
BEGIN
    k := top * MAXITEM + item;
    IF k > self.total - 1 THEN k := self.total - 1 END;
    IF k < 0 THEN k := 0 END;
    RETURN k
END Slot;


(* The text of slot k, which is what every reader of an entry wants. *)
PROCEDURE Entry (self: MenuBar; k: INTEGER; VAR text: ARRAY OF CHAR);
BEGIN
    IF (k >= 0) & (k < self.total) THEN
        self.items.GetStr(self.items, k * TEXTLEN, text)
    ELSE
        text[0] := 0X
    END
END Entry;


(* The modifiers of a keystroke as the number SetShortcut was given, so that a
   key is one integer on both sides of the comparison.

   Shift, Ctrl and Alt are read one at a time and added, rather than written as
   a sum of the three flags.  Alt and Ctrl are separate bits on purpose: AltGr
   sets **both** of the shift bits - see Events.IsAltScan - so a combination
   typed with AltGr is its own key here and does not match a plain Alt one. *)
PROCEDURE Mods (VAR e: Events.Event): INTEGER;
VAR m: INTEGER;
BEGIN
    m := 0;
    IF e.shift THEN m := m + M_SHIFT END;
    IF e.ctrl THEN m := m + M_CTRL END;
    IF e.alt THEN m := m + M_ALT END;
    RETURN m
END Mods;


(* Declare a key that fires a command while the bar is closed.

   There is no entry in this call, and that is the design rather than a gap: a
   shortcut belongs to the command, so this may be called before the entry that
   carries the id or after it, and a command with no entry at all is as valid as
   one with - what such a command loses is the reminder beside a row and not the
   key.

   A key is refused when it is not a key (a scancode of zero), when the command
   is not a command (an id of zero, which is what "nothing fired" is), and when
   the table is full.  A key registered twice keeps the command it was given
   first: the search stops at the first match, so a second registration is inert
   rather than a second answer. *)
PROCEDURE SetShortcut (self: MenuBar; cmd, scan, mods: INTEGER);
BEGIN
    IF (cmd # 0) & (scan # 0) & (self.naccel < MAXACCEL) THEN
        self.acmd[self.naccel] := cmd;
        self.akey[self.naccel] := scan + mods * MBASE;
        INC(self.naccel)
    END
END SetShortcut;


(* Whether entry i of the current top is a separator.  One minus and a
   terminator is the whole of what says so, which is what keeps the entry text
   the only thing a caller has to write: there is no flag beside it to fall out
   of step, and "-x" or "--" is an ordinary entry like any other. *)
PROCEDURE IsSep (self: MenuBar; i: INTEGER): BOOLEAN;
VAR line: ARRAY TEXTLEN OF CHAR; sep: BOOLEAN;
BEGIN
    Entry(self, Slot(self, self.cur, i), line);
    sep := (line[0] = "-") & (line[1] = 0X);
    RETURN sep
END IsSep;


(* The entry a step of dir from entry i lands on: the first one in that
   direction that can be chosen, wrapping at both ends.  A box holding nothing
   but separators has no such entry and answers i, and so does an empty box, so
   no caller has to ask first whether there is anything to step onto.

   This is the whole of "a separator never takes the mark": nothing else moves
   self.item, and both of the keys that do go through here. *)
PROCEDURE Step (self: MenuBar; i, dir: INTEGER): INTEGER;
VAR k, n, r: INTEGER; found: BOOLEAN;
BEGIN
    n := self.nitem[self.cur];
    r := i;
    found := FALSE;
    k := 0;
    WHILE (k < n) & ~found DO
        INC(k);
        r := r + dir;
        IF r > n - 1 THEN
            r := 0
        ELSIF r < 0 THEN
            r := n - 1
        END;
        IF ~IsSep(self, r) THEN
            found := TRUE
        END
    END;
    RETURN r
END Step;


(* The column the title of top item i starts at: one pad column in from the left
   edge of the bar, so the first title is not flush against it, and the ones
   after it follow at PADL + the title + PADR.

   The pad column is part of the item rather than white space outside it, which
   is what keeps everything else in step with this one line: TopAt subtracts the
   same PADL to find the item's hit region (so the region starts at the bar's
   own left edge and no column of the row is dead), the hot title is filled from
   the same place, and DropX - which is TopX of the current item less PADL - puts
   the first drop-down flush with the left edge and every other one under its own
   title. *)
PROCEDURE TopX (self: MenuBar; i: INTEGER): INTEGER;
VAR k, x: INTEGER;
BEGIN
    x := self.x + PADL;
    k := 0;
    WHILE k < i DO
        x := x + Strings.Length(self.titles[k]) + PADL + PADR;
        INC(k)
    END;
    RETURN x
END TopX;


(* Which top item covers column x of the bar, -1 for none. *)
PROCEDURE TopAt (self: MenuBar; x: INTEGER): INTEGER;
VAR i, k, w, found: INTEGER;
BEGIN
    found := -1;
    FOR i := 0 TO self.ntop - 1 DO
        k := TopX(self, i) - PADL;
        w := Strings.Length(self.titles[i]) + PADL + PADR;
        IF (x >= k) & (x < k + w) THEN
            found := i
        END
    END;
    RETURN found
END TopAt;


(* The column the drop-down of the current title starts at: under the title,
   over the title's own pad column, and never off the left edge - the first
   title is one pad column in from it, so its box is flush with the left edge
   and a box with its frame outside the canvas would lose that frame. *)
PROCEDURE DropX (self: MenuBar): INTEGER;
VAR x: INTEGER;
BEGIN
    x := TopX(self, self.cur) - PADL;
    IF x < 0 THEN
        x := 0
    END;
    RETURN x
END DropX;


(* The name of a key, as it is written on the keycap.

   A key this framework has no name for answers with an empty string, and a
   shortcut whose key has no name is drawn as nothing.  That is not a silent
   failure: what a keystroke is matched by is its scancode, so such a key works,
   and what is missing is the reminder beside the row - which is the honest
   thing to draw, since the alternative is a name that is not the key's.

   The letters are the key *positions* the scancodes number and not any one
   layout's alphabet: 2DH is the X key wherever X is on the board, which is why
   the sample's Alt+X is matched on the scan code and not on the character.
   The three rows below are the QWERTY positions those codes are numbered by,
   and a name for a key whose position carries another letter on another layout
   would be a claim this module cannot make. *)
PROCEDURE KeyName (scan: INTEGER; VAR s: ARRAY OF CHAR);
VAR row: ARRAY 12 OF CHAR; i: INTEGER; t: ARRAY 4 OF CHAR; more: BOOLEAN;
BEGIN
    s[0] := 0X;
    row[0] := 0X;
    i := -1;
    IF (scan >= 03BH) & (scan <= 044H) THEN            (* F1 .. F10 *)
        Strings.Copy("F", s);
        Strings.FromInt(scan - 03BH + 1, t);
        more := Strings.Append(t, s)
    ELSIF (scan >= 002H) & (scan <= 00BH) THEN         (* 1 .. 0 *)
        Strings.Copy("1234567890", row);
        i := scan - 002H
    ELSIF (scan >= 010H) & (scan <= 019H) THEN         (* Q .. P *)
        Strings.Copy("QWERTYUIOP", row);
        i := scan - 010H
    ELSIF (scan >= 01EH) & (scan <= 026H) THEN         (* A .. L *)
        Strings.Copy("ASDFGHJKL", row);
        i := scan - 01EH
    ELSIF (scan >= 02CH) & (scan <= 032H) THEN         (* Z .. M *)
        Strings.Copy("ZXCVBNM", row);
        i := scan - 02CH
    END;
    IF i >= 0 THEN
        s[0] := row[i];
        s[1] := 0X
    END
END KeyName;


(* The text a shortcut is shown as: its modifiers, the name of its key, and
   nothing at all when the command has no shortcut or its key has no name.

   The order the modifiers are written in is the one every interface of this
   kind writes them in, and not the order of the M_* bits, which is how they are
   stored and not how they are spelled. *)
PROCEDURE ShortcutText (self: MenuBar; cmd: INTEGER; VAR s: ARRAY OF CHAR);
VAR i, k: INTEGER; key: ARRAY TEXTLEN OF CHAR; more: BOOLEAN;
BEGIN
    s[0] := 0X;
    i := 0;
    WHILE (i < self.naccel) & (self.acmd[i] # cmd) DO
        INC(i)
    END;
    IF i < self.naccel THEN
        k := self.akey[i];
        KeyName(k MOD MBASE, key);
        IF key[0] # 0X THEN
            IF ODD(k DIV (MBASE * M_CTRL)) THEN
                more := Strings.Append("Ctrl+", s)
            END;
            IF ODD(k DIV (MBASE * M_SHIFT)) THEN
                more := Strings.Append("Shift+", s)
            END;
            IF ODD(k DIV (MBASE * M_ALT)) THEN
                more := Strings.Append("Alt+", s)
            END;
            more := Strings.Append(key, s)
        END
    END
END ShortcutText;


(* The width the drop-down of the current title needs: every entry plus its two
   pads, the two frame columns, the same again as white space on the right, and
   the shortcut of the entry's command when it has one - a gap and then the
   shortcut, both of them inside the frame. *)
PROCEDURE DropW (self: MenuBar): INTEGER;
VAR i, w, tw: INTEGER; line, key: ARRAY TEXTLEN OF CHAR;
BEGIN
    w := 8;                                     (* an empty box still has a frame *)
    IF self.cur >= 0 THEN
        FOR i := 0 TO self.nitem[self.cur] - 1 DO
            Entry(self, Slot(self, self.cur, i), line);
            tw := Strings.Length(line) + 2 * PADL + 4;
            ShortcutText(self, self.cmds[Slot(self, self.cur, i)], key);
            IF Strings.Length(key) > 0 THEN
                tw := tw + SHORTPAD + Strings.Length(key)
            END;
            IF tw > w THEN
                w := tw
            END
        END
    END;
    RETURN w
END DropW;


PROCEDURE Close (self: MenuBar);
BEGIN
    self.open := FALSE
END Close;


(* Open the drop-down under the current title, on its first entry: the first
   one that can be chosen, so a box whose first row is a separator opens on the
   entry under it rather than with nothing marked. *)
PROCEDURE OpenBar (self: MenuBar);
BEGIN
    IF self.cur > self.ntop - 1 THEN
        self.cur := self.ntop - 1
    END;
    IF self.cur < 0 THEN
        self.cur := 0
    END;
    self.item := Step(self, -1, 1);
    self.open := self.ntop > 0
END OpenBar;


(* The drop-down box of the current title, over the bar.

   A separator is the one row that is drawn rather than written, and it is drawn
   edge to edge across the inner width - which is what makes it a line between
   the groups rather than an entry with a strange title.  The mark is never on
   such a row (Step moves self.item over them), and the line takes the menu's
   own pair, so the theme needs no slot of its own for it. *)
PROCEDURE DropDown (self: MenuBar; target: TuiCanv.Canvas);
VAR i, x, y, w, h, a, ma, sa, n: INTEGER;
    line, key: ARRAY TEXTLEN OF CHAR;
BEGIN
    x := DropX(self);
    y := self.y + 1;
    w := DropW(self);
    h := self.nitem[self.cur] + 2;
    ma := TuiTheme.Attr(TuiTheme.Menu);
    sa := TuiTheme.Attr(TuiTheme.MenuSel);
    target.Fill(target, x, y, w, h, " ", ma);
    FOR i := 0 TO self.nitem[self.cur] - 1 DO
        IF (i = self.item) & ~IsSep(self, i) THEN
            a := sa
        ELSE
            a := ma
        END;
        Entry(self, Slot(self, self.cur, i), line);
        target.Fill(target, x + 1, y + 1 + i, w - 2, 1, " ", a);
        IF IsSep(self, i) THEN
            target.HLine(target, x + 1, y + 1 + i, w - 2, TuiCanv.SL_H, a)
        ELSE
            target.Print(target, x + 1 + PADL, y + 1 + i, line, a);
            (* The shortcut, at the other end of the row and inside the frame
               by one pad, which is where every menu of this kind puts it: the
               eye finds the entry by its left edge and the key by its right,
               and neither moves when the other grows. *)
            ShortcutText(self, self.cmds[Slot(self, self.cur, i)], key);
            n := Strings.Length(key);
            IF n > 0 THEN
                target.Print(target, x + w - 1 - PADR - n, y + 1 + i, key, a)
            END
        END
    END;
    target.Frame(target, x, y, w, h, TuiTheme.Attr(TuiTheme.MenuFrame), FALSE)
END DropDown;


PROCEDURE draw (self: MenuBar; target: TuiCanv.Canvas);
VAR i, x, n, ma, ha: INTEGER;
BEGIN
    ma := TuiTheme.Attr(TuiTheme.Menu);
    ha := TuiTheme.Attr(TuiTheme.MenuHot);
    target.Fill(target, self.x, self.y, self.width, 1, " ", ma);
    FOR i := 0 TO self.ntop - 1 DO
        x := TopX(self, i);
        n := Strings.Length(self.titles[i]);
        IF self.open & (i = self.cur) THEN
            target.Fill(target, x - PADL, self.y, n + PADL + PADR, 1, " ", ha);
            target.Print(target, x, self.y, self.titles[i], ha)
        ELSE
            target.Print(target, x, self.y, self.titles[i], ma)
        END
    END;
    IF self.open THEN
        DropDown(self, target)
    END
END draw;


(* Whether this keystroke is one of the bar's shortcuts, and fire it if it is.

   Only ever asked while the bar is closed, which is what makes a shortcut a
   shortcut: while a drop-down is open the menu is being used with the keyboard
   and every key means what the open menu says it means, a shortcut included -
   F1 in an open menu is not "open the date window", it is the key the menu does
   not use.

   The comparison is one integer against one integer, because the key and the
   modifiers were packed into one number when the shortcut was declared.  What
   that buys is not speed but the absence of a rule: a table of keys and a table
   of modifier sets would have to be searched in step, and the two would be one
   mistake away from pairing a key with another shortcut's modifiers. *)
PROCEDURE Accelerator (self: MenuBar; VAR e: Events.Event): BOOLEAN;
VAR i, k: INTEGER; fired: BOOLEAN;
BEGIN
    fired := FALSE;
    k := e.scan + Mods(e) * MBASE;
    i := 0;
    WHILE (i < self.naccel) & ~fired DO
        IF self.akey[i] = k THEN
            self.lastCmd := self.acmd[i];   (* the desktop's Step reads this *)
            fired := TRUE
        ELSE
            INC(i)
        END
    END;
    RETURN fired
END Accelerator;


PROCEDURE onEvent (self: MenuBar; VAR e: Events.Event): BOOLEAN;
VAR handled, take: BOOLEAN; i, x, y, w, h: INTEGER;
BEGIN
    handled := FALSE;
    IF e.kind = Events.KEYBOARD THEN
        take := FALSE;
        IF Events.IsKey(e, Events.K_F10) THEN
            (* A bar with no titles has nothing to open, and F10 on one is not
               this widget's key: taking it left the application unable to ask
               for F10 at all, for a bar that was only waiting to be filled.  A
               bar an application has built is filled before it is handed over,
               so this is the empty bar and nothing else. *)
            IF self.ntop = 0 THEN
                take := FALSE
            ELSE
                IF self.open THEN
                    Close(self)
                ELSE
                    OpenBar(self)
                END;
                take := TRUE
            END
        ELSIF self.open THEN
            IF Events.IsKey(e, Events.K_LEFT) THEN
                DEC(self.cur);
                IF self.cur < 0 THEN self.cur := self.ntop - 1 END;
                IF self.cur < 0 THEN self.cur := 0 END;
                self.item := 0
            ELSIF Events.IsKey(e, Events.K_RIGHT) THEN
                INC(self.cur);
                IF self.cur > self.ntop - 1 THEN self.cur := 0 END;
                self.item := 0
            ELSIF Events.IsKey(e, Events.K_UP) THEN
                self.item := Step(self, self.item, -1)
            ELSIF Events.IsKey(e, Events.K_DOWN) THEN
                self.item := Step(self, self.item, 1)
            ELSIF Events.IsKey(e, Events.K_ENTER) THEN
                IF (self.item >= 0) & (self.item < self.nitem[self.cur]) &
                   ~IsSep(self, self.item) THEN
                    self.lastCmd := self.cmds[Slot(self, self.cur, self.item)]
                END;
                Close(self)
            ELSIF Events.IsKey(e, Events.K_ESC) THEN
                Close(self)
            END;
            take := TRUE                    (* an open menu swallows every key *)
        ELSE
            (* The bar is closed and the key is not F10: the last thing it can
               be before the widget with the keyboard sees it is one of the
               shortcuts this application declared. *)
            take := Accelerator(self, e)
        END;
        handled := take
    ELSIF e.kind = Events.MOUSE THEN
        (* A press, not the movement that follows it.  Otherwise a drag that
           began somewhere else would open the bar as it crossed it, or fire the
           entry it happened to pass over. *)
        IF Events.IsPress(e) THEN
            i := -1;
            IF (e.y = self.y) & (e.x >= self.x) & (e.x < self.x + self.width) THEN
                i := TopAt(self, e.x)
            END;
            IF i >= 0 THEN
                IF self.open & (i = self.cur) THEN
                    Close(self)             (* a second click on the hot title *)
                ELSE
                    self.cur := i;
                    OpenBar(self)
                END;
                handled := TRUE
            ELSIF self.open THEN
                (* a click on the box picks the entry under it; a click anywhere
                   else just dismisses the menu *)
                x := DropX(self);
                y := self.y + 1;
                w := DropW(self);
                h := self.nitem[self.cur] + 2;
                IF (e.x > x) & (e.x < x + w - 1) & (e.y > y) &
                   (e.y < y + h - 1) THEN
                    i := e.y - y - 1;
                    (* A press on a separator is a press on the box: it closes
                       the menu and fires nothing, and the mark stays where it
                       was rather than standing on a row that may not carry it. *)
                    IF (i >= 0) & (i < self.nitem[self.cur]) & ~IsSep(self, i) THEN
                        self.item := i;
                        self.lastCmd := self.cmds[Slot(self, self.cur, i)]
                    END
                END;
                Close(self);
                handled := TRUE
            END
        END
    END;
    IF handled THEN
        e.kind := Events.NONE
    END;
    RETURN handled
END onEvent;


(* A new top level title; answers its index, or -1 when the bar is full. *)
PROCEDURE AddTop (self: MenuBar; title: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
    i := -1;
    IF self.ntop < MAXTOP THEN
        i := self.ntop;
        Strings.Copy(title, self.titles[i]);
        self.nitem[i] := 0;
        INC(self.ntop)
    END;
    RETURN i
END AddTop;


(* An entry under a top.  The array grows to hold the entry's slot and no
   further, so a bar of three entries spends three slots and a bar of ninety-six
   spells out the whole table - the record holds only the pointers either way. *)
PROCEDURE AddItem (self: MenuBar; top: INTEGER; title: ARRAY OF CHAR; cmd: INTEGER);
VAR k: INTEGER;
BEGIN
    IF (top >= 0) & (top < self.ntop) & (self.nitem[top] < MAXITEM) THEN
        k := top * MAXITEM + self.nitem[top];
        IF k + 1 > self.total THEN
            self.items.SetLength(self.items, (k + 1) * TEXTLEN);
            self.total := k + 1
        END;
        self.items.PutStr(self.items, k * TEXTLEN, title);
        self.cmds[k] := cmd;
        INC(self.nitem[top])
    END
END AddItem;


(* Give the bar back: the entry storage first, then the record itself.  The
   desktop calls this for the menu it holds when it is done with it - by the
   inherited field now, `Oberon.Done(m)`, and not by a procedure of this
   module: a class has one destructor and Oberon.mod says why.

   It takes `Oberon.Object` and guards down because it is what goes into that
   field, whose declared type is `PROCEDURE (self: Object)`. *)
PROCEDURE DoneMenuBar (self: Oberon.Object);
VAR m: MenuBar;
BEGIN
    m := self(MenuBar);
    m.items.Done(m.items);
    DISPOSE(m)
END DoneMenuBar;


PROCEDURE Create* (): MenuBar;
VAR m: MenuBar; i: INTEGER;
BEGIN
    NEW(m);
    m.x := 0;
    m.y := 0;
    m.width := 0;
    m.height := 1;
    m.visible := TRUE;
    m.focused := FALSE;
    m.canvas := NIL;
    m.items := ByteArr.Create(0);
    m.total := 0;
    m.ntop := 0;
    m.cur := 0;
    m.item := 0;
    m.open := FALSE;
    m.lastCmd := 0;
    m.naccel := 0;
    FOR i := 0 TO MAXTOP - 1 DO
        m.nitem[i] := 0
    END;
    m.draw := draw;
    m.onEvent := onEvent;
    m.AddTop := AddTop;
    m.AddItem := AddItem;
    m.SetShortcut := SetShortcut;
    m.Close := Close;
    m.Done := DoneMenuBar;
    RETURN m
END Create;

END TuiMenu.
