MODULE TuiWin;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A window: a rectangle with a frame, a title against the left end of its top
   line, and a canvas of its own.

   The canvas is the point.  Everything a window shows - the lists in it, and
   the frame itself - is drawn into that canvas in the window's own
   coordinates, and the window reaches the screen with one Blit onto the
   desktop.  So moving a window is an assignment, redrawing it costs a blit of
   its own size rather than a repaint of the screen, and a window that is partly
   off the desktop is clipped by Blit instead of by every widget in it.

   The same canvas is what makes overlapping windows work without anything
   behind them being saved: the desktop is cleared and rebuilt from these
   canvases on every frame, so a window that moves away simply stops painting
   over its neighbour, and the neighbour is whole again because its own canvas
   was never touched.  There is no hidden surface to restore - the canvas is
   where the pixels live.

   The focused window gets a double line frame and the Title pair; the others a
   single line and TitleIdle.

   A window is also where an event stops being the desk's and becomes a widget's.
   What it holds is a ring - the widgets the owner added, in the order it added
   them - and an event handed to the window is offered to them in that order
   until one answers.  The application above it does not have to know which
   widget is which: it says which window an event is for, and the window says
   which widget took it.

   The order of the ring is the order of the offering, and the two are not
   decoration.  A pull-down that is down is drawn outside its own rectangle and
   takes a press anywhere, so it has to be offered the event before the widget
   the press landed in - which is exactly what being earlier in the ring says.
   The order of the walk is the same order, so Tab from a window's last widget
   comes back to its first.

   What a window owns is a second list, and it is not the ring.  The ring is what
   an event is offered to and what Tab walks; a widget may be in a window -
   painted by it every frame, freed by it - without ever being in the ring.  A
   progress bar is that case: it is drawn and has nothing to answer with, so it
   is owned and never offered anything.  Ownership is what lets a window be given
   back in one call, and what lets the application stop keeping a second list of
   its own: Done gives back what the window owns, then the canvas, then the
   window.

   A window also carries the command ids its own widgets fire.  A widget that
   fires one hands it to Notify, and the window that offered it the event acts on
   it - through the ring and then its own onCommand, which is where the ids that
   act on a window belong, beside the widgets that fire them.  Only an id nobody
   takes goes up to the desk, and from there to the application.

   A widget hands the id over rather than leaving it in a field of its own
   because one event can carry more than one.  A field holds the id written last
   and the one before it is gone; a queue holds them all, in the order they were
   fired, which is the order they are acted on in.  A widget that has no window
   to hand to - one built into a dialog that is nobody's window - leaves the id
   in lastCmd, and Send reads it there as it always did.  The two paths are both
   here, and a widget takes exactly one of them.

   A window is taken hold of in two places - its title row, which moves it, and
   the cell at its bottom right corner, which sizes it - and Zone is what says
   which of them a desktop cell is.  The desktop does the dragging: it has the
   mouse and the work area, and the window only has to obey Move and SetSize.
   SetSize is the one operation here that frees and allocates, because the canvas
   is the window's pixels and a new size needs a new one.

   Colours come from TuiTheme, read at the moment of drawing, so a theme switch
   shows itself on the next frame.  The exception is the canvas itself, which is
   filled when the window is made - Refresh refills it, and Tui.SetTheme calls
   that for every window.  A window that wants colours of its own copies the
   theme into pairs and sets ownPairs; from then on it is its own, and a theme
   switch leaves it alone. *)

IMPORT TuiCanv, Events, Strings, TuiTheme, TuiWidg, Oberon;

CONST
    MAXTITLE = 40;                  (* bytes the title takes, its 0X included *)

    (* TuiWidg one window may hold and hand an event to.  A window with fewer is
       the usual case; the ring is a fixed array because the dialect has no
       growable one, and twelve is more than any window in this sample carries. *)
    MAXRING* = 12;

    (* TuiWidg one window may own, which is a larger number than the one above
       and a different question.  A window owns every widget that named it -
       what it paints and what it frees - and a panel it lays itself out with is
       one of those, so the tree of a window built out of panels is owned beside
       its controls.  What that costs is a list of pointers in the record and
       nothing while the window is small. *)
    OWN = 24;
    MINW* = 8;                      (* the smallest a window may be resized to:
                                       a frame, a title and something inside *)
    MINH* = 4;

    (* Ids one event may carry up from the widgets it was offered to.  One is
       the usual case; two is a widget that acts on a press in two ways at once.
       A widget that fires into a full queue is refused, the way a widget added
       to a full ring is, because the alternative is writing past the end. *)
    MAXPEND = 4;

    (* The column a title starts at, counting the frame's own corner as column
       0.  It is a fixed column and not one worked out from the window's width,
       so the titles of two windows of different widths line up with each other
       on the desk, which is what a row of stacked windows is read as. *)
    TITLE_X = 3;

    (* What part of a window a desktop cell falls on.  The title row and the one
       cell at the bottom right corner are the two places a window lets itself
       be taken hold of, so this is the whole of the hit testing one does. *)
    ZONE_NONE* = 0;
    ZONE_TITLE* = 1;
    ZONE_CORNER* = 2;
    ZONE_CLOSE* = 3;

TYPE

    Window* = POINTER TO WindowDesc;

    (* The moments a window is told about, and the reason they are declared
       for a window rather than for a widget.

       Whether a window is on show is the desk's fact and not the window's: Show,
       Hide and Close are the desk's calls, and the desk is the only thing that
       knows the whole answer - which window had the keyboard, where the focus
       goes, whether this one was modal and has to come off that stack.  A window
       that wants to know has to be told, and without these three it is the
       application that tells it, at every one of those call sites.  That is what
       this sample did: the module that hid its own window printed the status line
       itself, beside the call, because the window could not be asked to.

       So the split between these and the hooks on WidgetDesc is by who acts.  A
       widget's painter and onCommand are the window's business - the window
       paints it and hands it an id.  A window's onShow and onHide are the desk's.
       Nothing else in the sample shows or hides a widget: a panel of a tab strip
       is shown by its window's own state, and a widget of a hidden window is
       never drawn and never offered anything, which is why there is no pair of
       hooks one level down.

       NIL is the usual case for all of them and means the window has nothing to
       say at that moment. *)
    OnShow*  = PROCEDURE (w: Window);
    OnHide*  = PROCEDURE (w: Window);

    (* Asked before the window goes: TRUE is "yes, take me off", FALSE is a
       refusal and nothing happens at all.  It is what an application uses for
       the question a real window asks - there is unsaved work, a choice is half
       made, the point of the window is not over - and it is the one place a
       window has the last word about itself. *)
    OnClose* = PROCEDURE (w: Window): BOOLEAN;

    (* Told afterwards, and only when the ask above said yes: the window is off
       the desk, and this is the moment the application gives back what that
       window was holding - the record of its own, the file it had open, the
       buffer it allocated for it.

       It is deliberately not onHide, which is the near miss: a window hides when
       it is put away and can come back, so a hide is a pause.  This is the end of
       that window, and it is fired once, when the desk closes it.  Nothing is
       freed here by the framework - the window record itself belongs to the desk
       and is given back at Done - so an application that has nothing per window
       leaves this NIL and loses nothing. *)
    OnClosed* = PROCEDURE (w: Window);

    WindowDesc* = RECORD (TuiWidg.WidgetDesc)
        title: ARRAY MAXTITLE OF CHAR;

        (* Whether the window shows the box that closes it, in the last three
           cells of its title row before the corner.  It is opt in and off by
           default, and the reason is what a window is here: a plain window of
           this desk is a thing that can be hidden and shown again, and a box
           drawn on all of them would offer a way out of the ones whose owner
           never meant to give one.  A form that is a form - a dialog, a document
           window, anything that stands for work of its own - sets it, and the
           application hears about the press through onClosed. *)
        closeBox*: BOOLEAN;

        active*: BOOLEAN;
        ownPairs*: BOOLEAN;                 (* use pairs rather than the theme *)
        pairs*: ARRAY TuiTheme.NPAIR OF INTEGER;

        (* Whether this window has been closed since it was last on show.  It is
           what makes the telling happen once: a close hides the window and hides
           it again the second time it is asked, so without this a window closed
           twice would be told twice, and an application that frees its record in
           that telling would free it twice.  Show clears it, because a window
           that is on show again is a window whose work has begun again - and it
           is the desk that reads and writes it, which is why it is not private.
           A closed window answers FALSE to Close: there is nothing left to
           tell. *)
        closed*: BOOLEAN;

        (* What is in the window, in the order the owner put it there.  The order
           is the order an event is offered in - which is what makes an open
           pull-down swallow a press that landed in the widget behind it, since
           the box is offered the event first - and it is the order Tab walks.
           rsel is the widget the keyboard is on, and the only one whose own
           focused flag is set while the window has the keyboard. *)
        ring: ARRAY MAXRING OF TuiWidg.Widget;
        nring: INTEGER;
        rsel: INTEGER;

        (* What the window is responsible for: every widget that named it, in
           the order they were made, which is also the order they are painted in.
           A widget is owned from the moment its Create runs - it is handed the
           window it belongs to, and the window takes it - and it stays owned
           while it is out of the ring, which is what makes a bar painted and not
           walkable.  RemoveWidget takes it out of both lists.

           The two lists are the same size no longer, and the reason is what a
           panel is: a panel is owned like any widget, so a window that lays
           itself out with panels owns its whole tree - its pages, the bands its
           parts sit in - beside its controls.  A window built that way holds a
           dozen widgets before a single page is filled, and the ring it walks is
           still three or four stops.  OWN is the room for the first and MAXRING
           the room for the second, and neither number is what the other one is
           about. *)
        owned: ARRAY OWN OF TuiWidg.Widget;
        nowned: INTEGER;

        (* The ids the widgets fired while this window was offering them the
           event, in the order they fired them.  Send acts on them after the
           walk, so a widget hands one over from its handler and never from
           outside an event: a window that is not in the middle of Send has
           nothing to drain, and an id left here would wait for the next one. *)
        pending: ARRAY MAXPEND OF INTEGER;
        npend: INTEGER;

        (* The two ids the window answers for itself when every widget it holds
           has declined the key: Enter fires the first and Esc the second, and 0
           means the window has no such answer.  They are ids and not widgets
           because an id is what a window acts on and what its own Command is
           given - and a widget could not be named here in any case: WidgetDesc
           carries no command of its own, so there would be nothing to read one
           out of.

           These are what make Enter and Esc a window's keys rather than a
           dialog's.  They are tried *last* - after the whole ring has declined -
           which is the rule a Delphi form follows when its memo has the focus
           and its default button does not fire.  A window with a text area in it
           therefore loses nothing by naming a default: the area takes Enter for
           its newline, and the default answers only the Enter the area did not
           want. *)
        dflt*, cancel*: INTEGER;

        (* Told when it comes on show, when it goes off, asked before it goes and
           told after it has gone.  The application sets these on the window it
           built - they are its policy and not the window's - and the desk fires
           them.

           onClose is asked before Hide touches anything, so a window that says
           no is a window nothing happened to: it is still on show, it still has
           the keyboard, and it is still on the modal stack if it was.  A window
           that has set none is a window that always goes, which is what Hide did
           before there was an ask - so an application that never fills these in
           loses nothing it had.  onClosed is fired after the window is off, and
           only when onClose allowed it: the ask is a question and this is the
           answer being acted on. *)
        onShow*: OnShow;
        onHide*: OnHide;
        onClose*: OnClose;
        onClosed*: OnClosed;

        Draw*:     PROCEDURE (self: Window; target: TuiCanv.Canvas);
        Focus*:    PROCEDURE (self: Window; on: BOOLEAN);
        Command*:  PROCEDURE (self: Window; cmd: INTEGER): BOOLEAN;
        Send*:     PROCEDURE (self: Window; VAR e: Events.Event;
                              VAR who: TuiWidg.Widget): BOOLEAN;
        SetTitle*: PROCEDURE (self: Window; title: ARRAY OF CHAR);
        Move*:     PROCEDURE (self: Window; x, y: INTEGER);
        Zone*:     PROCEDURE (self: Window; x, y: INTEGER): INTEGER;
        SetSize*:  PROCEDURE (self: Window; w, h: INTEGER);
        Refresh*:  PROCEDURE (self: Window)
    END;


(* The pair to draw a slot with: the window's own when it has any, the theme's
   otherwise.  Every colour this module uses goes through here.

   It is exported because a widget that paints a surface of its own has to paint
   it in the colour the window it is in paints its body: a panel that cleared its
   cells with the theme's own pair would leave a rectangle of the wrong colour in
   a window that keeps a table of its own, and the Items window does. *)
PROCEDURE Attr* (self: Window; slot: INTEGER): INTEGER;
VAR a: INTEGER;
BEGIN
    IF self.ownPairs THEN
        a := self.pairs[slot]
    ELSE
        a := TuiTheme.Attr(slot)
    END;
    RETURN a
END Attr;


(* Paint what the window holds, then the frame and the title, into the window's
   own canvas, and put that canvas on the target.  The title goes over the top
   line of the frame, so a long one is cut to what fits between the corners.

   The contents are the window's own painter, if it has one, and then every
   widget it owns that is visible, in the order it took them.  A window's own
   painter is for what is not a widget - a strip of text, a line of labels - and
   it runs first, under everything.

   It is drawn from TITLE_X and is not centred: the column is a constant, so
   two windows of different widths show their titles in the same place, and a
   window that is resized does not slide its own title along the top line while
   it is being dragged.

   The frame gives up the corner's own column and, from TITLE_X - 1, the blank
   column the title's own strip is filled over - that pair is what keeps the
   words off the corner, and the blank one is what the fill below covers.  The
   column between them, column 1, is left as the frame drew it, so the strip
   starts one cell in rather than hard against the corner.

   The room a title has is the top line less the two corners and a pad column
   either side of the words, so the fill of n + 2 columns starting at TITLE_X - 1
   ends on the column before the right corner whatever n is.  That is what the
   limit below measures: TITLE_X + n must not reach width - 1.  A window that
   asked for the close box is measured the same way with the box's own three
   columns taken off the end, so the words stop before the box and the box sits
   in the room they gave up. *)
PROCEDURE Draw (self: Window; target: TuiCanv.Canvas);
VAR a, n, i, lim: INTEGER; buf: ARRAY MAXTITLE OF CHAR;
BEGIN
    IF self.visible THEN
        (* What is in the window is drawn before the frame is, so a widget that
           reached the frame's own cells is painted over by it - which is the
           order this was written in when the application did the painting.  A
           widget that is not visible is skipped: the tab window keeps every
           panel of its strip in one window and says which one is up with these
           flags, so the flag is the whole of what decides what is painted. *)
        IF self.painter # NIL THEN
            self.painter(self, self.canvas)
        END;
        FOR i := 0 TO self.nowned - 1 DO
            IF self.owned[i].visible & (self.owned[i].painter # NIL) THEN
                self.owned[i].painter(self.owned[i], self.canvas)
            END
        END;
        IF self.active THEN
            a := Attr(self, TuiTheme.FrameActive)
        ELSE
            a := Attr(self, TuiTheme.Frame)
        END;
        self.canvas.Frame(self.canvas, 0, 0, self.width, self.height, a,
                          self.active);
        IF self.active THEN
            a := Attr(self, TuiTheme.Title)
        ELSE
            a := Attr(self, TuiTheme.TitleIdle)
        END;
        Strings.Copy(self.title, buf);
        n := Strings.Length(buf);
        IF self.closeBox THEN
            lim := self.width - 8
        ELSE
            lim := self.width - 5
        END;
        IF n > lim THEN
            n := lim;
            IF n < 0 THEN n := 0 END;
            buf[n] := 0X
        END;
        IF n > 0 THEN
            self.canvas.Fill(self.canvas, TITLE_X - 1, 0, n + 2, 1, " ", a);
            self.canvas.Print(self.canvas, TITLE_X, 0, buf, a)
        END;
        (* The box is drawn last, over the title's own strip, and in the title's
           own attribute: it is part of the bar and not a widget, so there is
           nothing to hover, nothing to focus and nothing to take an event - the
           desk reads the three cells as a zone and the window hears about the
           press from the desk.  A window narrower than the box needs prints
           nothing at all, which is what the test below is: the three cells have
           to be inside the frame, and MINW is 8. *)
        IF self.closeBox & (self.width >= 6) THEN
            self.canvas.Print(self.canvas, self.width - 4, 0, "[X]", a)
        END;
        target.Blit(target, self.x, self.y, self.canvas)
    END
END Draw;


(* Say to the widgets which one the keyboard is on.  Exactly one comes out
   focused - the chosen stop - and a window without the keyboard marks none of
   them, so a widget gated on its own flag is deaf exactly when its window is.

   This is the only writer of that flag pair, which is what the application used
   to spell out for every widget of every window on every frame.  It is Mark and
   not the walk that does it, so a ring that was emptied and filled again - the
   tab window's, when the strip switches the panel under it - is back in step
   with one call.

   A widget that is not visible is never focused, whatever the walk stands on.
   A hidden widget takes no event and is not a stop, so the flag would be a
   keyboard state nothing can reach - and the one place it would be read is the
   widget's own draw, which does not run either.  The two flags are set from the
   same three facts: the window has the keyboard, the walk is on this index, and
   the widget is on show. *)
PROCEDURE Mark (self: Window);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO self.nring - 1 DO
        IF self.ring[i].taker # NIL THEN
            self.ring[i].taker(self.ring[i],
                self.focused & (i = self.rsel) & self.ring[i].visible)
        END
    END
END Mark;


PROCEDURE Focus (self: Window; on: BOOLEAN);
BEGIN
    self.active := on;
    self.focused := on;
    Mark(self)
END Focus;


(* Put the keyboard on a widget of the ring other than the first.  A window whose
   widgets are not added in the order they are meant to be walked - the text
   window, whose boxes must be offered a press before the area the press landed
   in - says where the walk starts with this.  An index outside the ring is
   ignored, because there is no widget it could mean. *)
PROCEDURE SetRing* (self: Window; i: INTEGER);
BEGIN
    IF (i >= 0) & (i < self.nring) THEN
        self.rsel := i;
        Mark(self)
    END
END SetRing;


(* Where the walk stands.  An owner whose reaction depends on which widget took
   an event - the file dialog's Enter means one thing on a list and another on a
   field - asks this rather than keeping an index of its own: two copies of one
   number are two numbers that drift. *)
PROCEDURE Ring* (self: Window): INTEGER;
VAR i: INTEGER;
BEGIN
    i := self.rsel;
    RETURN i
END Ring;


(* The id Enter fires when the window's own widgets have all declined it,
   and the id Esc fires the same way.  See the two fields for why they are ids.

   Nothing is re-marked and nothing is repainted: what changes is what the
   window does with a key it was already being offered. *)
PROCEDURE SetDefault* (self: Window; cmd: INTEGER);
BEGIN
    self.dflt := cmd
END SetDefault;


PROCEDURE SetCancel* (self: Window; cmd: INTEGER);
BEGIN
    self.cancel := cmd
END SetCancel;


(* Add a widget to the end of the ring, in the order the owner adds them.  A
   window that is full refuses the rest, and so does one handed nothing: the ring
   is what an event is offered to, and a widget that is not in it is a widget
   nothing arrives at.

   The flags are not touched here.  What a widget's focused says is decided by
   the walk - rsel and the window's own focus - so a ring that is rebuilt while
   the keyboard stays where it was leaves the flags alone, and Mark puts them
   right again when the window is told who has the keyboard. *)
PROCEDURE AddWidget* (self: Window; w: TuiWidg.Widget);
BEGIN
    IF (w # NIL) & (self.nring < MAXRING) THEN
        self.ring[self.nring] := w;
        INC(self.nring)
    END
END AddWidget;


(* Take a widget into the window without putting it in the ring: it is painted
   and given back with the rest, and no event is ever offered to it.

   This is what a widget's own Create calls, so a widget knows the window it
   belongs to from the moment it exists and the application never keeps the list
   a second time.  Being owned and being in the ring are separate on purpose: a
   bar is drawn in a window and has no id and no keyboard, and a widget that
   entered the ring to be painted would also enter the Tab walk. *)
PROCEDURE Own* (self: Window; w: TuiWidg.Widget);
BEGIN
    IF (self # NIL) & (w # NIL) & (self.nowned < OWN) THEN
        self.owned[self.nowned] := w;
        INC(self.nowned)
    END
END Own;


(* Hand this window an id a widget fired, to be acted on when the event being
   offered is over.  This is what a widget's own fire calls, in place of writing
   its own lastCmd, and it is the counterpart of Own: a widget that knows the
   window it belongs to says so, and one that has no window says nothing and
   leaves the id where Send has always looked for it.

   w is the widget that fired, and it is named for the one case where there is no
   window to hand to: the id goes into w's own lastCmd and the walk over the ring
   finds it.  A widget that fires into a full queue is refused and loses the id -
   the caller is a widget in an event handler and has nowhere to report it, and
   four ids in one event is already more than the sample has. *)
PROCEDURE Notify* (self: Window; w: TuiWidg.Widget; id: INTEGER);
BEGIN
    IF self # NIL THEN
        IF self.npend < MAXPEND THEN
            self.pending[self.npend] := id;
            INC(self.npend)
        END
    ELSIF w # NIL THEN
        w.lastCmd := id
    END
END Notify;


(* Empty the ring, keeping where the walk stands.  The owner of a window whose
   contents change - the tab window, whose panels come and go under the strip -
   empties it and adds what is on show, and the walk is not moved by that: a
   panel switched under the ring leaves the ring where it was, on the widget the
   same stop names in the panel that is now up.

   The widgets that are leaving are told so.  A widget not in a ring is a widget
   nothing arrives at, so it is already inert - but the flag it was left wearing
   is state nothing can reach to clear: the panel it belongs to is not drawn and
   not offered anything, and when it comes back Mark sets the flag it should have
   anyway.  Clearing here is what keeps a widget out of a ring and a widget
   without the keyboard the same thing. *)
PROCEDURE ClearRing* (self: Window);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO self.nring - 1 DO
        IF self.ring[i].taker # NIL THEN
            self.ring[i].taker(self.ring[i], FALSE)
        END
    END;
    self.nring := 0
END ClearRing;


(* Give a widget up: out of the ring and out of what the window owns, so the
   window will not paint it, offer it anything or free it again.  The order of
   what stays is the order it was in - a removal is not a reason for two widgets
   to swap places in the Tab walk.

   A widget that is leaving the ring is told the keyboard is off it first, for
   the same reason ClearRing does it: the flag is state nothing could reach once
   the widget is out of the ring, and a widget that comes back is marked by the
   walk anyway.

   The owner calls this when it is about to give a widget back itself - the tab
   window, whose panels come and go - and a widget's own Done calls it for the
   widget it is freeing, because the window it was owned by outlives it. *)
PROCEDURE RemoveWidget* (self: Window; w: TuiWidg.Widget);
VAR i, n: INTEGER; was: BOOLEAN;
BEGIN
    was := FALSE;
    n := 0;
    FOR i := 0 TO self.nring - 1 DO
        IF self.ring[i] = w THEN
            was := TRUE
        ELSE
            self.ring[n] := self.ring[i];
            INC(n)
        END
    END;
    self.nring := n;
    IF was & (w # NIL) & (w.taker # NIL) THEN
        w.taker(w, FALSE)
    END;
    n := 0;
    FOR i := 0 TO self.nowned - 1 DO
        IF self.owned[i] # w THEN
            self.owned[n] := self.owned[i];
            INC(n)
        END
    END;
    self.nowned := n;
    IF (self.nring > 0) & (self.rsel > self.nring - 1) THEN
        self.rsel := self.nring - 1
    END;
    Mark(self)
END RemoveWidget;


(* Hand a command id to what the window holds: the ring first, in the order an
   event is offered in, and then the window's own onCommand.  TRUE means somebody
   acted on it.

   This is what a widget's fired id meets.  A widget hands the id to Notify and
   the window that offered it the event calls this - so the arm that acts on an
   id stands in the window that owns it, next to the widgets that fire it, and
   the application no longer keeps a chain of every id in the sample. *)
PROCEDURE Command* (self: Window; cmd: INTEGER): BOOLEAN;
VAR i: INTEGER; taken: BOOLEAN;
BEGIN
    taken := FALSE;
    i := 0;
    WHILE ~taken & (i < self.nring) DO
        IF self.ring[i].visible & (self.ring[i].onCommand # NIL) THEN
            taken := self.ring[i].onCommand(self.ring[i], cmd)
        END;
        INC(i)
    END;
    IF ~taken & (self.onCommand # NIL) THEN
        taken := self.onCommand(self, cmd)
    END;
    RETURN taken
END Command;


(* The next stop of the Tab walk, in the direction given, or -1 when there is
   none.  The walk steps over two kinds of ring entry and stops on neither: a
   widget that is not visible - it takes no event, so landing there would leave
   the window with nobody focused - and a widget with no keyboard to take, which
   is a widget in the ring for the mouse alone.  A panel is the second kind: a
   split line is dragged with the mouse and never with the keyboard.

   Nothing is skipped in a ring where every entry is visible and takes the
   keyboard, so the walk is the same one-step walk it has always been: the index
   after this one, wrapped.  A ring of one is not walked at all, which is the
   caller's own test and the reason this answers -1 rather than the index it
   started on. *)
PROCEDURE Next (self: Window; back: BOOLEAN): INTEGER;
VAR k, i, r: INTEGER;
BEGIN
    r := -1;
    IF self.nring > 1 THEN
        i := self.rsel;
        FOR k := 1 TO self.nring - 1 DO
            IF back THEN
                i := (i - 1 + self.nring) MOD self.nring
            ELSE
                i := (i + 1) MOD self.nring
            END;
            IF (r < 0) & self.ring[i].visible & (self.ring[i].taker # NIL) THEN
                r := i
            END
        END
    END;
    RETURN r
END Next;


(* The window's half of the event loop, and the whole of what it knows about what
   it holds: an event is offered to the widgets of the ring, in the order they
   were added, and the first one that answers has it.

   Both kinds of event are offered the same way, and that is deliberate.  What a
   widget does with an event that was not meant for it is decline, and declining
   is free: a key is gated by the widget's own focused flag, a press by the cell
   the event carries.  Offering everything to everyone is what makes an open
   pull-down swallow a press that landed behind it - it is offered first and
   takes it - and it is what the application used to write out once per window.

   A press that is taken is also the widget that has the keyboard from then on,
   which is the rule the desk keeps for windows one level up.  If nothing took a
   Tab and there is more than one widget to walk to, Tab walks the ring; a window
   with one widget is not walked at all, because there is nowhere to walk to.

   who is the widget that answered, or NIL.

   The ids the widgets fired are acted on here, after the walk and before this
   answers.  A widget that handed its id to Notify has it in the queue and the
   queue is drained in the order the ids were fired; a widget that had no window
   to hand to left it in lastCmd and the walk over the ring reads it, first one
   only, as it always did.  Both go to Command, which is the ring and then the
   window's own onCommand; an id nobody takes is left in the window's lastCmd for
   the desk.

   Every lastCmd is cleared whether or not its id is the one that is acted on, so
   nothing stale survives into the next event.  The queue is drained by index
   rather than emptied first, so an id fired by a handler while the queue is
   being drained is acted on too; it cannot run away, because the queue is full
   at four and Notify refuses what will not fit. *)
PROCEDURE Send* (self: Window; VAR e: Events.Event; VAR who: TuiWidg.Widget): BOOLEAN;
VAR i, cmd: INTEGER; handled: BOOLEAN;
BEGIN
    handled := FALSE;
    who := NIL;
    IF (e.kind = Events.KEYBOARD) OR (e.kind = Events.MOUSE) THEN
        i := 0;
        WHILE ~handled & (i < self.nring) DO
            IF self.ring[i].visible & (self.ring[i].handler # NIL) THEN
                handled := self.ring[i].handler(self.ring[i], e)
            END;
            IF handled THEN
                who := self.ring[i];
                (* The walk's position is the keyboard's, and a widget that
                   cannot hold the keyboard cannot be where the keyboard is.  A
                   panel is the one widget of that kind that handles anything at
                   all - it takes the mouse for a split line - and without this
                   the press that took hold of a line would move the keyboard off
                   the list beside it and onto a widget with none. *)
                IF self.ring[i].taker # NIL THEN self.rsel := i END
            END;
            INC(i)
        END
    END;
    (* Enter and Esc, once the whole ring has declined them: the window's own
       two ids, fired the way a widget fires one - into the queue the walk below
       drains, so the window's own Command is asked first and the desk only if
       it declines.  The event is taken here rather than left to the desk, and
       that is the point of the pair: an application that gives a window a
       default action should not also have to remember not to quit on the Esc
       that window wanted. *)
    IF ~handled & (e.kind = Events.KEYBOARD) THEN
        IF Events.IsKey(e, Events.K_ENTER) & (self.dflt # 0) THEN
            Notify(self, NIL, self.dflt);
            e.kind := Events.NONE;
            handled := TRUE
        ELSIF Events.IsKey(e, Events.K_ESC) & (self.cancel # 0) THEN
            Notify(self, NIL, self.cancel);
            e.kind := Events.NONE;
            handled := TRUE
        END
    END;
    IF ~handled & (e.kind = Events.KEYBOARD) & Events.IsKey(e, Events.K_TAB) THEN
        i := Next(self, e.shift);
        IF i >= 0 THEN
            self.rsel := i;
            e.kind := Events.NONE;
            handled := TRUE
        END
    END;
    Mark(self);
    cmd := 0;
    FOR i := 0 TO self.nring - 1 DO
        IF self.ring[i].lastCmd # 0 THEN
            IF cmd = 0 THEN
                cmd := self.ring[i].lastCmd
            END;
            self.ring[i].lastCmd := 0
        END
    END;
    IF cmd # 0 THEN
        IF Command(self, cmd) THEN
            handled := TRUE
        ELSE
            self.lastCmd := cmd         (* nobody here: the desk is asked *)
        END
    END;
    i := 0;
    WHILE i < self.npend DO
        cmd := self.pending[i];
        IF Command(self, cmd) THEN
            handled := TRUE
        ELSE
            self.lastCmd := cmd
        END;
        INC(i)
    END;
    self.npend := 0;
    RETURN handled
END Send;


PROCEDURE SetTitle (self: Window; title: ARRAY OF CHAR);
BEGIN
    Strings.Copy(title, self.title)
END SetTitle;


PROCEDURE Move (self: Window; x, y: INTEGER);
BEGIN
    self.x := x;
    self.y := y
END Move;


(* What the cell (x, y) of the desktop is on this window: its close box, its
   title row, the corner cell a resize is taken hold of by, or neither.

   The title row is the whole top line rather than just the words in it, because
   that is the line the user sees as the handle; the corner is one cell, which
   is a small target but the only one that means "both axes at once".  The
   window's own rectangle is tested first, so a point outside it is never a
   grip.

   The box comes before the title and is the three cells of the top line the
   drawing put it in, and only in a window that asked for one - a window that
   shows no box has no zone there, and a press on those cells takes hold of the
   title as it did before there was a box.  It is the same three cells Draw
   writes, worked out the same way, which is the one thing the two have to agree
   about.

   Coordinates are the desktop's, not the canvas's - a drag arrives from the
   mouse and the mouse works in screen cells. *)
PROCEDURE Zone* (self: Window; x, y: INTEGER): INTEGER;
VAR z: INTEGER;
BEGIN
    z := ZONE_NONE;
    IF (x >= self.x) & (x < self.x + self.width) &
       (y >= self.y) & (y < self.y + self.height) THEN
        IF (y = self.y) & self.closeBox & (self.width >= 6) &
           (x >= self.x + self.width - 4) & (x < self.x + self.width - 1) THEN
            z := ZONE_CLOSE
        ELSIF y = self.y THEN
            z := ZONE_TITLE
        ELSIF (x = self.x + self.width - 1) & (y = self.y + self.height - 1) THEN
            z := ZONE_CORNER
        END
    END;
    RETURN z
END Zone;


(* A new size: the canvas is made first and the old one freed after it, so a
   window is never left with none.  The rectangle follows the canvas. *)
PROCEDURE SetSize (self: Window; w, h: INTEGER);
VAR c: TuiCanv.Canvas; i: INTEGER;
BEGIN
    IF w < MINW THEN w := MINW END;
    IF h < MINH THEN h := MINH END;
    IF (w # self.width) OR (h # self.height) THEN
        c := TuiCanv.Create(w, h);
        c.Clear(c, Attr(self, TuiTheme.Frame));
        self.canvas.Done(self.canvas);
        self.canvas := c;
        self.width := w;
        self.height := h;
        (* Every widget that holds parts of its own is told the room it has now,
           in the order it was taken.  A widget that reads its geometry as it
           draws binds no resizer and is not called: the new size is what it
           draws to on the next frame whether anybody tells it or not.  See
           TuiWidg.Resizer for why this is a method and not a convention. *)
        FOR i := 0 TO self.nowned - 1 DO
            IF self.owned[i].resizer # NIL THEN
                self.owned[i].resizer(self.owned[i], w, h)
            END
        END
    END
END SetSize;


(* Repaint the window's background, which is the one colour that is not read at
   draw time.  The contents - a list, say - are the application's to redraw. *)
PROCEDURE Refresh (self: Window);
BEGIN
    self.canvas.Clear(self.canvas, Attr(self, TuiTheme.Frame))
END Refresh;


(* Give the window back: what it owns first, then its canvas, then the record
   itself.  The desktop calls this for every window it holds when it is done with
   them - as `Oberon.Done(w)`, through the inherited field - so an application
   gives its windows back and nothing else.

   It takes `Oberon.Object` and guards down because it is what goes into that
   field, whose declared type is `PROCEDURE (self: Object)`.

   Both lists are emptied before any widget is freed.  A widget that is freed by
   hand - the tab window's panels - takes itself out of the window it was in, and
   a list being walked while it is being shortened would step over an entry or
   read past the end.  An emptied list makes that call a no-op instead.

   onClosed is deliberately not fired here.  This is the end of the program and
   not the end of the window: it runs for every window the desk still holds,
   most of which were never closed, and it runs for a window that was closed too
   - so firing there would tell an application twice about the same window and
   free its record twice.  What an application wants given back at exit it gives
   back in its own last statement, one call per window it still has open. *)
PROCEDURE DoneWindow (self: Oberon.Object);
VAR w: Window; i, n: INTEGER;
BEGIN
    w := self(Window);
    n := w.nowned;
    w.nowned := 0;
    w.nring := 0;
    FOR i := 0 TO n - 1 DO
        Oberon.Done(w.owned[i])
    END;
    Oberon.Done(w.canvas);
    DISPOSE(w)
END DoneWindow;


PROCEDURE Create* (x, y, w, h: INTEGER; title: ARRAY OF CHAR): Window;
VAR win: Window;
BEGIN
    ASSERT((w >= MINW) & (h >= MINH));      (* a frame, and a title between it *)
    NEW(win);
    win.x := x;
    win.y := y;
    win.width := w;
    win.height := h;
    win.visible := TRUE;
    win.focused := FALSE;
    win.active := FALSE;
    win.ownPairs := FALSE;
    win.closeBox := FALSE;              (* a box is asked for, never assumed *)
    win.closed := FALSE;
    win.id := 0;                        (* and so is a name *)
    win.data := 0;
    win.nring := 0;
    win.rsel := 0;
    win.nowned := 0;
    win.npend := 0;
    win.dflt := 0;
    win.cancel := 0;
    win.handler := NIL;                 (* a window is not a widget of a window *)
    win.taker := NIL;
    win.lastCmd := 0;

    (* The two a window uses as its own: what it paints itself and what it does
       with the ids its widgets fire.  An application sets them on the window it
       built; a window with neither is the usual case.

       Giving the window back is not one of them - it is the inherited `Done`,
       bound below, and `Oberon.Done(w)` is how the desk reaches it.  This used
       to be a `disposer` of the window's own, left NIL here, which is what a
       field that is a second name for the destructor buys a reader: nothing. *)
    win.painter := NIL;
    win.onCommand := NIL;
    win.Done := DoneWindow;

    (* And the four the desk fires, which are nobody's until an application
       sets them: a window with no lifecycle of its own is the rule and not the
       exception.  See the four fields. *)
    win.onShow := NIL;
    win.onHide := NIL;
    win.onClose := NIL;
    win.onClosed := NIL;
    win.canvas := TuiCanv.Create(w, h);
    win.Draw := Draw;
    win.Focus := Focus;
    win.Command := Command;
    win.Send := Send;
    win.SetTitle := SetTitle;
    win.Move := Move;
    win.Zone := Zone;
    win.SetSize := SetSize;
    win.Refresh := Refresh;
    win.canvas.Clear(win.canvas, Attr(win, TuiTheme.Frame));
    SetTitle(win, title);
    RETURN win
END Create;


END TuiWin.
