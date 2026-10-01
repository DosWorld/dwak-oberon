MODULE Tui;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The desktop: the canvas the whole interface is composed on, the windows on
   it, the menu bar, the status line and the mouse cursor.

   Draw is a frame, and it is complete: the background is cleared, every window
   paints itself, then the menu, then the status line and at the very end the
   cell the mouse is on.  Nothing draws outside it, so the screen never has to
   be told what changed - the whole frame goes out at once.

   The desktop owns the focus and hands it out: a click gives it to the window
   under the pointer, F6 cycles it, and Shift+F6 cycles it the other way.  A
   window can also be taken off the desk
   and put back - Hide and Show - and a hidden one is invisible to every part of
   the desktop: TuiWin.Draw leaves it out of the frame, TuiWidg.Inside refuses
   it so no click can reach it and WindowAt cannot answer it, and F6 walks past
   it.  The focus is the desktop's to give, so it is also the desktop's to take
   away: hiding the window that has it gives it to the topmost window still on
   show, and a desk with every window hidden has no focus at all rather than a
   keyboard that types into a window nobody can see.

   Tab is not the desktop's either, but it is now a window's: a window holds its
   widgets in a ring and walks it, so the desktop does not have to know what a
   widget is to see one take a key.  What it does know is which window should
   have the event, and that is the whole of Send - the second half of the event
   loop, after Dispatch has done the desk's own half.

   So the route is: the desk first (the menu, a dialog, a drag, the window a
   click chose), the application next (its own keys, F2 and F3 and Alt+X), and
   then Send - which hands the event to the window, and the window hands it to
   its widgets.  The order matters and is the application's to keep: a key the
   application claims never reaches a widget, and everything it does not is a
   widget's business.

   The one thing the desktop does take away is the event the menu consumed: a
   widget that acted on an event sets its kind to NONE, and everything after it
   in the chain sees NONE and leaves that event alone.

   A pop-up stands in front of all of that.  It is a window the desk holds
   outside its z-order, paints after everything else and offers every event to
   before anything else - so a calendar raised by a widget floats over the desk
   beside that widget, over whatever it covers, and while it is up nothing
   else in the program acts.  See SetPopup for what that buys and what it
   costs, and Project for the one piece of arithmetic it and Send share. *)

IMPORT TuiCanv, TuiDlg, Events, TuiMenu, Strings, TuiTheme, TuiWidg, TuiWin, Oberon;

CONST
    MAXWIN* = 32;                    (* windows on the desktop.  Exported so an
                                       application can test before it asks:
                                       CreateWindow answers NIL once the desk is
                                       full, and NIL is a thing to check for
                                       rather than to discover afterwards. *)
    STATLEN = 96;                   (* bytes the status line takes, its 0X included *)

    (* What a dialog that was closed without being answered reports as its
       command.  TuiDlg answers 0 for that - Esc and a dialog with no buttons
       both leave by Fire(self, -1) - and 0 is also what Dispatch reports for an
       event that fired nothing at all, so an application could not tell a
       cancelled dialog from a quiet keystroke.  TuiDlg' own header says the
       application can tell by the id alone; this is the id that makes that
       true.  It is negative because every command an application invents is a
       positive one, so no id it has can collide with it. *)
    CANCELLED* = -1;

    (* What a drag in progress is doing.  NONE also means "no drag", so the
       state is one integer rather than a flag beside a mode. *)
    DRAG_NONE = 0;
    DRAG_MOVE = 1;
    DRAG_SIZE = 2;

    (* The first row a window may occupy.  Row 0 is the menu bar, and a window
       dragged under it would have its title painted over by the bar - and a
       window whose title cannot be seen cannot be taken hold of again.  The
       other end is the status line, which owns the last row. *)
    TOPROW = 1;

    (* The smallest desk this desktop will work on: one window, the row above it
       and the status line below it.  A console window can be dragged to almost
       nothing, and it is dragged by the user rather than asked for - so the size
       arrives from outside the program and cannot be assumed to be sensible.
       Below this, a window's frame and its status line would be the whole desk
       and the arithmetic that places them would ask for a rectangle with no rows
       in it.  The desk is held at this size and the screen simply shows the part
       of it that fits. *)
    MINCOLS = TuiWin.MINW;
    MINROWS = TuiWin.MINH + 2;

    (* The character the desk is filled with before a window is drawn on it.

       A space by default, because the desk is the surface the windows sit on and
       a pattern under them competes with what is drawn over it.  It stands here,
       in the module that owns the desk, because it is one character for the whole
       of it: the pair it is drawn in belongs to the theme (TuiTheme.Desk) and a
       character is not a pair, so no theme slot could hold one.  Set it to a
       shade (TuiCanv.SHADE_LIGHT) for a textured desktop, or to any other single
       character.  A module that wants to clear a rectangle of the desk to the
       same character reads it from here rather than writing a space.

       It is a code point and not a byte now, which is why it is spelled WCHR(20H)
       and not 20X: an application may set it to a character no single-byte page
       has - a shade, an arrow, a box corner - and what the host does with one it
       cannot draw is the host's business, decided at the screen.  The shades are
       the case that matters: SHADE_LIGHT is 2591H, which no OEM page carries, so
       a textured desk is now something a DOS box can be asked for at all. *)
    DeskChar* = WCHR(20H);

    (* How deep the modal stack may go.  A modal window may raise a dialog, and
       a dialog a pop-up: what is under the top is frozen rather than gone, and
       comes back when the top is taken down.  A fifth modal replaces the fourth
       rather than being refused, which is the shape the two single slots had
       before there was a stack at all. *)
    MAXMODAL* = 4;

    (* What an entry of the stack holds.  A dialog is not a window - TuiDlg'
       Dialog is six rows of message and buttons and not a window of the desk -
       so an entry says which of the two it is.  NONE is no entry at all, which
       is what a slot is left as when it is taken off the stack. *)
    MODAL_NONE = 0;
    MODAL_WINDOW = 1;
    MODAL_DIALOG = 2;

TYPE

    (* The character an interface draws with.

       It is the canvas's own character type and not a second one, and the alias
       is the whole point: a program that draws through Windows or TuiCanv, or
       that reads a character back out of one, is working in this type already,
       and a type declared here with a life of its own would not assign to a
       canvas.  It is exported because an application writing a widget needs a
       name for it - every character an application wants (the frame pieces, the
       arrows, the shades) is a constant of TuiCanv, and this is the type of a
       variable that holds one.

       An application never needs it to hold text.  A string literal assigns to
       a canvas, to an ARRAY OF this type and to a parameter of one, so a caption
       is still written "Open" and not as a list of characters; this type is for
       the one character that is a *picture* - a frame piece, a tick, a shade. *)
    TuiChar* = TuiCanv.Char;

    (* One thing the desk offers every event to and nothing else, and what it
       is.  See SetDialog, SetPopup and ShowModal for the three ways one gets
       onto the stack. *)
    Modal = RECORD
        kind: INTEGER;
        win: TuiWin.Window;
        dlg: TuiDlg.Dialog
    END;

    (* What an application registers for the commands its windows did not take.
       A type of its own because a formal procedure parameter has to name one -
       the dialect has no anonymous procedure type in a parameter list. *)
    CmdProc* = PROCEDURE (cmd: INTEGER): BOOLEAN;

VAR
    desk: TuiCanv.Canvas;
    wins: ARRAY MAXWIN OF TuiWin.Window;
    (* The z-order, back to front: order[k] is the index in wins of the k-th
       window from the bottom.  wins itself is never reordered - a window keeps
       the index it was created under, which is what the application's own
       references to it mean - so this is a permutation of 0..nwin-1 and the
       only thing a raise changes. *)
    order: ARRAY MAXWIN OF INTEGER;
    nwin, active, cols, rows: INTEGER;
    menu: TuiMenu.MenuBar;
    (* The modal stack: what the desk offers every event to, top last, and -
       while it holds anything - the only thing it offers them to.  Nothing here
       is in wins unless it was made there: a pop-up is a window of a widget's
       own and a modal window is one the application showed modally, and neither
       is part of the z-order or walked by F6 while it is on the stack.  The
       desk holds both and owns neither: whichever made them frees them. *)
    modal: ARRAY MAXMODAL OF Modal;
    nmodal: INTEGER;
    (* Who answers a command that no window took.  The desk asks the windows in
       the order they were created and then this, and it is NIL until an
       application registers one - a desk whose windows answer every id they fire
       needs no handler here at all.  It is the application's own ids that end up
       here: Quit, About, and the ones that act on whichever window has the
       focus, which is a fact no single window knows. *)
    onCmd: CmdProc;
    status: ARRAY STATLEN OF CHAR;
    mouseOn: BOOLEAN;
    mouseX, mouseY, mouseButtons: INTEGER;
    (* The drag in progress, if any: which window, what it is doing, and how far
       the pointer was from the window's corner when it began - so the window
       does not jump under the pointer on the first move.  Whether an event is a
       press is not kept here: the event carries what the one before it left. *)
    dragMode, dragWin, dragDX, dragDY: INTEGER;


(* Bring window i to the top of the z-order: find where it sits and slide the
   windows that were above it down one place.  Nothing else about the window
   changes - the pixels it was covering are repainted from the window below it
   on the next frame, because every window draws from its own canvas and the
   desktop is rebuilt from scratch. *)
PROCEDURE Raise (i: INTEGER);
VAR k, at: INTEGER;
BEGIN
    IF (i >= 0) & (i < nwin) THEN
        at := 0;
        FOR k := 0 TO nwin - 1 DO
            IF order[k] = i THEN at := k END
        END;
        FOR k := at TO nwin - 2 DO
            order[k] := order[k + 1]
        END;
        order[nwin - 1] := i
    END
END Raise;


(* Make window i the focused one, and only it.  Focus is what raises: there is
   no separate "bring to front" gesture, so a click and an F6 both show the
   window they picked on top of the others.

   A window is told through its own Focus and not by writing the two flags here,
   and that is the whole of the routine's job: TuiWin.Focus is what marks the
   window's ring, so a window told this way has its widgets in step with it the
   moment the focus moves.  Writing the pair by hand left every widget's own
   focused flag where it was until something else happened to re-mark the ring -
   and the six per-frame Focus calls the sample used to make in its window units
   existed only to cover that gap.  This routine is the only writer of the pair,
   which is what Windows.Mark says of itself and what makes the two of them one
   mechanism rather than two. *)
PROCEDURE SetActive (i: INTEGER);
VAR k: INTEGER;
BEGIN
    active := i;
    IF i >= 0 THEN
        Raise(i)
    END;
    FOR k := 0 TO nwin - 1 DO
        wins[k].Focus(wins[k], k = i)
    END
END SetActive;


PROCEDURE Init* (c, r: INTEGER);
VAR i: INTEGER;
BEGIN
    (* The size comes from the screen, so every size is possible and none of
       them is a programming error: a console can be dragged down to two rows
       and left there before the program is ever started.  There was an assert
       here refusing anything under three; it was measured firing on a four by
       two console, which is a trap where the honest answer is a desk held at
       the size it needs and a screen showing what it can.  See MINCOLS. *)
    IF c < MINCOLS THEN c := MINCOLS END;
    IF r < MINROWS THEN r := MINROWS END;
    cols := c;
    rows := r;
    desk := TuiCanv.Create(c, r);
    menu := NIL;
    nmodal := 0;
    FOR i := 0 TO MAXWIN - 1 DO
        wins[i] := NIL;
        order[i] := i
    END;
    nwin := 0;
    active := -1;
    mouseOn := FALSE;
    mouseX := 0;
    mouseY := 0;
    mouseButtons := 0;
    dragMode := DRAG_NONE;
    dragWin := -1;
    dragDX := 0;
    dragDY := 0;
    onCmd := NIL;
    status[0] := 0X
END Init;


(* Switch the colour scheme.

   Almost nothing has to be done for it: every widget reads the pair it draws
   with at the moment it draws, so the next frame is in the new theme with
   nothing told and nothing re-applied.  The exception is a window's canvas,
   which was filled when the window was made and is not touched by drawing -
   it is refilled here.  What is *inside* a window is the application's, and it
   paints it again on its next frame; a window with colour pairs of its own
   keeps them, because Refresh reads the same Attr every other draw does. *)
PROCEDURE SetTheme* (i: INTEGER);
VAR k: INTEGER;
BEGIN
    TuiTheme.Set(i);
    FOR k := 0 TO nwin - 1 DO
        IF wins[k] # NIL THEN
            wins[k].Refresh(wins[k])
        END
    END
END SetTheme;


PROCEDURE Desk* (): TuiCanv.Canvas;
VAR c: TuiCanv.Canvas;
BEGIN
    c := desk;
    RETURN c
END Desk;


(* The menu bar, which is drawn on the top row of the desktop.

   A bar that was already here is given back.  This used to overwrite the
   pointer and leave the old bar to nobody: the leak was silent, because the
   pointer was the only way to reach it, and TuiMenu.Done is what frees the array
   the bar grew for its entries.  A bar handed in twice is left alone - it is
   the one that is already here, and freeing it would take away what the caller
   has just asked for. *)
PROCEDURE SetMenu* (m: TuiMenu.MenuBar);
BEGIN
    IF (menu # NIL) & (menu # m) THEN
        Oberon.Done(menu)
    END;
    menu := m;
    IF m # NIL THEN
        m.x := 0;
        m.y := 0;
        m.width := cols
    END
END SetMenu;


(* Put one thing on the modal stack: the top of it, which is the only entry
   the desk will offer an event to.  A full stack takes the place of the entry
   that was on top, which is what keeps a fourth modal from being a modal that
   silently never came up. *)
PROCEDURE PushW (w: TuiWin.Window);
BEGIN
    IF nmodal = MAXMODAL THEN DEC(nmodal) END;
    modal[nmodal].kind := MODAL_WINDOW;
    modal[nmodal].win := w;
    modal[nmodal].dlg := NIL;
    INC(nmodal)
END PushW;


PROCEDURE PushD (d: TuiDlg.Dialog);
BEGIN
    IF nmodal = MAXMODAL THEN DEC(nmodal) END;
    modal[nmodal].kind := MODAL_DIALOG;
    modal[nmodal].win := NIL;
    modal[nmodal].dlg := d;
    INC(nmodal)
END PushD;


(* Take the top entry off and answer it, so that CloseModal can hide a window
   without asking the stack for it twice.  An empty stack answers an empty entry
   rather than trapping: taking a modal down that is not up is a call with
   nothing to do, not a mistake. *)
PROCEDURE PopTop (VAR m: Modal);
BEGIN
    m.kind := MODAL_NONE;
    m.win := NIL;
    m.dlg := NIL;
    IF nmodal > 0 THEN
        m := modal[nmodal - 1];
        DEC(nmodal);
        modal[nmodal].kind := MODAL_NONE;
        modal[nmodal].win := NIL;
        modal[nmodal].dlg := NIL
    END
END PopTop;


(* Take the topmost entry of one kind off the stack, leaving the rest where they
   are.  A kind that is not on the stack is nothing to do, and that is the case
   worth having: taking a pop-up down that is not up is what a widget does on
   its way out, and it must not disturb the dialog that is. *)
PROCEDURE PopKind (kind: INTEGER);
VAR i, at: INTEGER;
BEGIN
    at := -1;
    FOR i := 0 TO nmodal - 1 DO
        IF modal[i].kind = kind THEN at := i END
    END;
    IF at >= 0 THEN
        FOR i := at TO nmodal - 2 DO
            modal[i] := modal[i + 1]
        END;
        DEC(nmodal);
        modal[nmodal].kind := MODAL_NONE;
        modal[nmodal].win := NIL;
        modal[nmodal].dlg := NIL
    END
END PopKind;


(* Take one window off the stack wherever it is on it, and every mention of it:
   showing a window modally twice must not leave it on the stack twice, or the
   second copy would still be offered events after the window had gone. *)
PROCEDURE PopWindow (w: TuiWin.Window);
VAR i, k: INTEGER;
BEGIN
    k := 0;
    FOR i := 0 TO nmodal - 1 DO
        IF modal[i].win # w THEN
            modal[k] := modal[i];
            INC(k)
        END
    END;
    FOR i := k TO nmodal - 1 DO
        modal[i].kind := MODAL_NONE;
        modal[i].win := NIL;
        modal[i].dlg := NIL
    END;
    nmodal := k
END PopWindow;


(* What is on top of the modal stack: the window, NIL when the top is a dialog
   or when there is no top.  An application asks this to know whether its own
   modal window is still up - the desk takes one down by itself as soon as it is
   no longer on show. *)
PROCEDURE ModalTop* (): TuiWin.Window;
VAR w: TuiWin.Window;
BEGIN
    w := NIL;
    IF (nmodal > 0) & (modal[nmodal - 1].win # NIL) THEN
        w := modal[nmodal - 1].win
    END;
    RETURN w
END ModalTop;


(* How many things are modal: 0 for a desk the application can be typed into. *)
PROCEDURE ModalDepth* (): INTEGER;
VAR n: INTEGER;
BEGIN
    n := nmodal;
    RETURN n
END ModalDepth;


(* Put a dialog up.  It is centred and opened here rather than by the caller,
   because the desktop is what knows how big the desktop is and a dialog that
   had to be opened as well as set would be one call too many to forget.

   From this moment the dialog sees every event until it closes, when Dispatch
   takes it back down and answers the command it fired.  There is one entry of
   this kind on the stack, so a second dialog replaces the first and leaves a
   pop-up it was raised from where it is - and the first dialog is still the
   caller's to free. *)
PROCEDURE SetDialog* (d: TuiDlg.Dialog);
BEGIN
    IF d = NIL THEN
        PopKind(MODAL_DIALOG)
    ELSE
        d.Place(d, cols, rows);
        d.Open(d);
        (* One entry of this kind, so a second dialog replaces the first - and
           the first is still the caller's to free.  It goes off the stack
           rather than under the new one: two dialogs up at once is not what
           replacing means. *)
        PopKind(MODAL_DIALOG);
        PushD(d)
    END
END SetDialog;


(* Put a pop-up window over everything, or take down the one that is up.

   A pop-up like this is not a dialog and cannot be one: TuiDlg.Dialog is a
   fixed six rows of message and buttons, and a widget's own panel - a
   calendar, a colour picker - is neither.  So the desktop holds a plain window
   instead, and the three things it does with it are the whole of what a pop-up
   is here:

     - it paints it after every window and after the dialog, so a pop-up is
       never clipped by the window that raised it and may stand outside it;
     - it offers it every event before the drag, before the dialog, before the
       menu and before any window, and then takes the event away from all of
       them by setting its kind to NONE.  That is the modality, and it costs
       one assignment: the application's own keys read the kind, so F2, F3, F1
       and Alt+X do nothing at all while a pop-up is up, and Send routes
       nothing;
     - it brings it back inside the desk when the desk changes size, as a
       dialog is placed.

   The window is deliberately not in wins.  A pop-up is not a window of the
   desk: it does not join the z-order, it does not become the active window, F6
   walks past it and a click cannot choose it.  It floats over the desk the way
   a menu's drop-down floats over the bar, and for the same reason - it belongs
   to the widget that raised it and to nothing else.  The desk does not own it
   either: the caller made the window, fills it and frees it.

   There is one entry of this kind, so a second pop-up replaces the first
   rather than standing on it - which is what a second press on the button that
   raised it means. *)
PROCEDURE SetPopup* (w: TuiWin.Window);
BEGIN
    IF w = NIL THEN
        PopKind(MODAL_WINDOW)
    ELSE
        PopKind(MODAL_WINDOW);          (* a second pop-up replaces the first *)
        PushW(w)
    END
END SetPopup;


PROCEDURE SetStatus* (s: ARRAY OF CHAR);
BEGIN
    Strings.Copy(s, status)
END SetStatus;


PROCEDURE Window* (i: INTEGER): TuiWin.Window;
VAR w: TuiWin.Window;
BEGIN
    w := NIL;
    IF (i >= 0) & (i < nwin) THEN
        w := wins[i]
    END;
    RETURN w
END Window;


PROCEDURE Active* (): INTEGER;
VAR i: INTEGER;
BEGIN
    i := active;
    RETURN i
END Active;


(* The size of the desktop.  The application needs it to place what it owns: a
   dialog centres itself on these, and a window is clamped by them. *)
PROCEDURE Cols* (): INTEGER;
VAR c: INTEGER;
BEGIN
    c := cols;
    RETURN c
END Cols;


PROCEDURE Rows* (): INTEGER;
VAR r: INTEGER;
BEGIN
    r := rows;
    RETURN r
END Rows;


(* The topmost window the point is in, -1 for none.  The walk is up the
   z-order, so the last window that covers the point is the one on top - which
   is the one the user can see and therefore the one being pointed at. *)
PROCEDURE WindowAt* (x, y: INTEGER): INTEGER;
VAR k, found: INTEGER;
BEGIN
    found := -1;
    FOR k := 0 TO nwin - 1 DO
        IF TuiWidg.Inside(wins[order[k]], x, y) THEN
            found := order[k]
        END
    END;
    RETURN found
END WindowAt;


(* The desktop cell an event carries turned into a window's own coordinates, or
   (-1, -1) when the point is not in the window.

   A widget's rectangle is in its window's canvas and an event's cell is the
   desk's, so this is where the two meet.  A point outside the window becomes
   (-1, -1) rather than a coordinate that happens to look like a cell inside it,
   which is what lets a widget that took the mouse when the button went down
   follow the button up wherever the pointer has got to without ever acting on
   a cell it does not own.

   A key is projected too, and always to (-1, -1): it carries no cell at all -
   its x and y are zero - and a widget that reads them for a key would be
   reading the corner of its own canvas.  The original event is untouched; the
   copy is what the window is given. *)
PROCEDURE Project (w: TuiWin.Window; VAR e: Events.Event; inside: BOOLEAN;
                   VAR local: Events.Event);
BEGIN
    local := e;
    IF inside THEN
        local.x := e.x - w.x;
        local.y := e.y - w.y
    ELSE
        local.x := -1;
        local.y := -1
    END
END Project;


(* Register what answers the commands no window took.  An application calls this
   once, after its windows are built, with the procedure that holds its own ids;
   the desk calls it last, so a window's answer always comes first. *)
PROCEDURE SetOnCommand* (p: CmdProc);
BEGIN
    onCmd := p
END SetOnCommand;


(* Act on a command id: the windows in the order they were created, and then the
   application's own handler.  TRUE means somebody acted on it.

   The order is creation order and not z-order, for the same reason F6 walks the
   windows that way: raising a window must not change what an id means.  The
   order does not decide between two windows in this sample - every id has one
   owner - it only decides who is asked and declines first.

   An id that arrives here came from the menu, from a dialog, or from a widget
   whose own window declined it.  Ids a widget fires are acted on inside that
   widget's window before this is reached; what is left is what the desk or the
   application owns. *)
PROCEDURE Command* (cmd: INTEGER): BOOLEAN;
VAR i: INTEGER; taken: BOOLEAN;
BEGIN
    taken := FALSE;
    i := 0;
    WHILE ~taken & (i < nwin) DO
        IF wins[i] # NIL THEN
            taken := wins[i].Command(wins[i], cmd)
        END;
        INC(i)
    END;
    IF ~taken & (onCmd # NIL) THEN
        taken := onCmd(cmd)
    END;
    RETURN taken
END Command;


(* Hand an event to the window that should have it, and let the window hand it to
   its own widgets.  This is the second half of the event loop - Dispatch is the
   desk's half, and this is the half that reaches what is inside a window.

   Which window: the one the keyboard is on for a key, and the one under the
   pointer for the mouse - which is not necessarily the same window, since a
   click is what chooses, one step earlier, in Dispatch.

   A mouse event over no window at all still goes to the window that has the
   keyboard, with a cell off the top left corner where no widget can be.  That is
   for the widget that took the mouse when the button went down: it has to see
   the button come up wherever the pointer is by then, or a scrollbar dragged out
   of its window would go on following the pointer for the rest of the run.

   The event the window is given is the desktop cell turned into the window's own
   coordinates, because a widget's rectangle is in its window's canvas - and the
   one the caller gets back still carries the desk's.  who is the widget that
   answered, or NIL.

   A command the window could not place is offered to the desk before this
   answers: the window leaves it in its own lastCmd when neither its ring nor its
   own onCommand took it, and that is the only way an id fired deep inside a
   widget reaches an application that owns it. *)
PROCEDURE Send* (VAR e: Events.Event; VAR who: TuiWidg.Widget): BOOLEAN;
VAR i, cmd: INTEGER; local: Events.Event;
    w: TuiWin.Window; handled: BOOLEAN;
BEGIN
    handled := FALSE;
    who := NIL;
    w := NIL;
    i := -1;
    IF e.kind = Events.MOUSE THEN
        i := WindowAt(e.x, e.y)
    END;
    IF e.kind = Events.KEYBOARD THEN
        IF active >= 0 THEN w := wins[active] END
    ELSIF e.kind = Events.MOUSE THEN
        IF i >= 0 THEN
            w := wins[i]
        ELSIF active >= 0 THEN
            w := wins[active]
        END
    END;
    IF w # NIL THEN
        Project(w, e, i >= 0, local);
        handled := w.Send(w, local, who);
        IF local.kind = Events.NONE THEN
            e.kind := Events.NONE
        END;
        IF w.lastCmd # 0 THEN
            cmd := w.lastCmd;
            w.lastCmd := 0;
            IF Command(cmd) THEN
                handled := TRUE
            END
        END
    END;
    RETURN handled
END Send;


(* F6 walks the windows in the order they were created, not in z-order.
   Cycling the z-order instead would be wrong as soon as focus raises: the
   window just raised is the last in the order, so the next rank would be the
   one it displaced, and F6 would alternate between two windows forever.

   A window that is not on show is skipped.  The walk is over the windows that
   are on the desk, not over the records in wins: giving the keyboard to a
   hidden window would move a selection nobody can see while the window that is
   on show drew its own as idle - so an F6 with one window visible leaves the
   focus where it is, which is the honest answer to "the next one you can see".

   dir is +1 for the next window and -1 for the one before it, which is the
   whole of what Shift costs the walk.  The desk does not know what a widget is:
   what is inside a window is the application's, and a plain Tab is left to the
   window's own ring - see Send. *)
PROCEDURE FocusStep (dir: INTEGER);
VAR i, k, n, found: INTEGER;
BEGIN
    found := -1;
    n := nwin;
    i := active;
    IF i < 0 THEN i := 0 END;
    FOR k := 0 TO n - 1 DO
        i := i + dir;
        IF i >= n THEN i := 0 END;
        IF i < 0 THEN i := n - 1 END;
        IF (found < 0) & (wins[i] # NIL) & wins[i].visible THEN
            found := i
        END
    END;
    IF found >= 0 THEN
        SetActive(found)
    END
END FocusStep;


(* The next window on the desk.  The application asks for this by name - the
   menu entry does - and the key that does the same thing is F6. *)
PROCEDURE FocusNext*;
BEGIN
    FocusStep(1)
END FocusNext;


(* The index of a window the desktop holds, -1 for one it does not.  Hide is
   given the record the application keeps, because that is what an application
   has; the desktop itself works in indices, and this is the one place the two
   are translated. *)
PROCEDURE IndexOf (w: TuiWin.Window): INTEGER;
VAR i, found: INTEGER;
BEGIN
    found := -1;
    IF w # NIL THEN
        FOR i := 0 TO nwin - 1 DO
            IF wins[i] = w THEN found := i END
        END
    END;
    RETURN found
END IndexOf;


(* Give the focus to the topmost window that is on show, or to none at all when
   every window is hidden.  This is where the focus goes when the window holding
   it disappears: to the one the user is looking at, which is the top of the
   z-order rather than the next one in creation order. *)
PROCEDURE FocusTop;
VAR k, j, found: INTEGER;
BEGIN
    found := -1;
    FOR k := 0 TO nwin - 1 DO
        j := order[nwin - 1 - k];               (* the top of the order first *)
        IF (found < 0) & (wins[j] # NIL) & wins[j].visible THEN
            found := j
        END
    END;
    SetActive(found)
END FocusTop;


(* Take a window off the desk, and put it back.

   Both are the desktop's rather than the window's, and the reason is the focus:
   a window knows nothing about what else is on the desk, so it cannot know where
   the focus should go when the one that had it disappears.  Hide hands it to the
   topmost window still on show, and a desk with every window hidden ends up with
   no focus - which is the honest state, since Active then answers -1, F6 has
   nowhere to go, and the application's own routing has nothing to route to.

   Show is the other half of the same rule, and it gives back both of the things
   Hide took away: the window is visible, it is on top, **and it has the
   keyboard**.  `CreateWindow` leaves a window in exactly that state, and a window
   that has come back is in the state a new one is in: it is the window the user
   asked for, and the key that asks for it is meant to leave them able to work in
   it at once.  A window that came back on top and un-chosen was a picture of a
   window rather than a window - there to be pointed at and not to be typed into,
   and the click that was then needed to use it is the click the key should have
   saved.  This sample reported that twice: first as a window coming back behind
   the one that covered it, then as a window with no keyboard, and the two are one
   sentence - what comes back comes back as the window it was.

   A window that was raised while this one was away is behind it from now on: what
   is asked for is the window, and where it was left in the z-order is not. *)
PROCEDURE Hide* (w: TuiWin.Window);
VAR i: INTEGER; was: BOOLEAN;
BEGIN
    i := IndexOf(w);
    IF i >= 0 THEN
        was := w.visible;
        w.visible := FALSE;
        (* A window that was modal is not modal any more.  Hiding it is the
           whole of how a modal window closes: the desk offers every event to
           what is on the modal stack, and a window left on that stack with
           nothing on the desk would be offered the whole run and could answer
           none of it - the user's presses would land on a window that is not
           there.  The stack holds only what is on show, and this is what keeps
           that true.  See ShowModal, which is the other end of it.

           A window that was never modal is not on the stack, and PopWindow
           finds nothing to take off - so this costs an application that never
           shows anything modally one walk over an empty stack. *)
        PopWindow(w);
        IF i = active THEN
            FocusTop
        END;
        (* Told last, so that what the callback finds is the state the user is
           left in: the window is off the desk, it is off the modal stack if it
           was on it, and the keyboard has already gone to whatever is still on
           show - a callback can ask Tui.Active and get the answer that stands.

           Only a window that was on show is told.  A hide that changes nothing
           is not a moment: several windows of this sample are built and hidden
           in the same breath, and a window that was made and taken away again
           before anyone looked at it was never shown to be hidden from. *)
        IF was & (w.onHide # NIL) THEN
            w.onHide(w)
        END
    END
END Hide;


PROCEDURE Show* (w: TuiWin.Window);
VAR i: INTEGER; was: BOOLEAN;
BEGIN
    IF w # NIL THEN
        i := IndexOf(w);
        IF i >= 0 THEN
            was := w.visible;
            w.visible := TRUE;
            SetActive(i);
            (* Told after the focus, so that a callback which lays itself out
               does it in the window the user is about to type in, and not in
               one that is still waiting for the keyboard.  The frame itself is
               drawn from this state later in the same turn, so anything the
               callback changes is in the picture the user's next key is read
               from.

               Only a window that was off show is told: showing one that is
               already up - what brings a covered window to the top - is not a
               moment, and a window that comes back is told again. *)
            IF ~was & (w.onShow # NIL) THEN
                w.onShow(w)
            END;
            (* A window on show is a window whose work has begun: whatever it was
               told when it was last closed no longer stands, and the next close
               will tell it again.  It is set here and not on the notice above,
               because it belongs to the state and not to the callback - a window
               with no onShow is armed just the same. *)
            w.closed := FALSE
        END
    END
END Show;


(* Ask the window whether it may go, and take it off the desk if it says yes.

   This is the one call the desk makes that a window can refuse, and the reason
   the question is a call of its own rather than a test an application writes:
   it belongs to the window.  An application that tests at the call site tests
   at every call site - the key, the menu entry, the button - and the window's
   own policy ends up written out as many times as there are ways to close it,
   and out of step as soon as one of them is forgotten.  Asked here, the policy
   is written once, and whatever got there first asks it.

   The window is asked before anything is touched, so a refusal is a call that
   did nothing at all: Hide is not reached and the answer is the whole of the
   effect.  TRUE means the desk did take it off - which is also the answer for a
   window with no onClose, since such a window is one that always goes, and that
   is what Hide alone used to do.

   A window that is not on the desk cannot be closed and answers FALSE: there is
   nothing to ask and nothing to take away.  Neither can one that has been closed
   already, and that is the answer that keeps the telling below from happening
   twice: the window is still on the desk after a close - off show is not gone -
   and a second close of it must not tell an application to give back a record it
   has already given back.  Show arms it again.

   Once it has gone the window is told, through onClosed, and that is the whole
   of the difference between a close and a hide: the ask decides whether it goes,
   the telling is the window's own work being over - its file, its record, its
   buffer given back.  A window told this is a window whose work is finished; if
   it is to be used again it is built again, which is why nothing here shows it
   again afterwards and why the hook is named for the close and not for the
   hide. *)
PROCEDURE Close* (w: TuiWin.Window): BOOLEAN;
VAR ok: BOOLEAN;
BEGIN
    ok := FALSE;
    IF (w # NIL) & (IndexOf(w) >= 0) & ~w.closed THEN
        ok := TRUE;
        IF w.onClose # NIL THEN
            ok := w.onClose(w)
        END;
        IF ok THEN
            (* Marked before anything is called, so that a handler which closes
               this same window again - from onHide, or from onClosed itself -
               finds it already closed instead of starting a second telling. *)
            w.closed := TRUE;
            Hide(w);
            IF w.onClosed # NIL THEN
                w.onClosed(w)
            END
        END
    END;
    RETURN ok
END Close;


(* Put a window on the desk as a modal one: it is shown, it takes the keyboard,
   and from then until it is no longer on show the desk offers every event to it
   and to nothing else.

   This is what a window cannot do for itself and what a dialog is not.  TuiDlg'
   Dialog is six rows of message and buttons that the desk knows how to open; a
   modal window is any window at all, with whatever the application put in it,
   and the desk needs to know nothing about its contents to freeze the desk for
   it.

   There is nothing to call to close one.  The rule is the window's own
   visibility - a modal window hides itself, through its buttons or through the
   cancel id it was given, and Hide takes it off the stack as well as off the
   desk.  One act, in one place, is what closes a modal window and gives the
   desk back: a window that had to be told twice, by hiding and then by being
   taken off the stack, could be left up by an application that forgot the
   second.

   A window already on the stack is moved to the top rather than put on it
   twice. *)
PROCEDURE ShowModal* (w: TuiWin.Window);
BEGIN
    IF (w # NIL) & (IndexOf(w) >= 0) THEN
        PopWindow(w);
        PushW(w);
        Show(w)
    END
END ShowModal;


(* Take the top of the modal stack down, whatever it is.  A window is hidden by
   it as well: the stack is what the desk offers events to, and a window left on
   show with nothing offered to it would be a window that cannot be used.  A
   dialog is only dropped - it is the application's, and the application gives it
   back. *)
PROCEDURE CloseModal*;
VAR m: Modal;
BEGIN
    PopTop(m);
    IF m.win # NIL THEN
        Hide(m.win)
    END
END CloseModal;


(* v brought into lo..hi.  A window larger than the work area leaves the range
   empty; the low end wins, so what stays on the screen is the window's top left
   - its title, which is the grip - rather than its bottom right, which would
   put the title off the top and the window out of reach. *)
PROCEDURE Clamp (v, lo, hi: INTEGER): INTEGER;
VAR r: INTEGER;
BEGIN
    r := v;
    IF r < lo THEN r := lo END;
    IF r > hi THEN r := hi END;
    IF r < lo THEN r := lo END;
    RETURN r
END Clamp;


(* The rectangle a window of this shape may have on a desk of this size.

   The size is decided before the position, and that order is the point: a
   window that is too big has to be made smaller first, so that the position it
   is then given is one its own frame agrees about.  Taking the position first
   and shrinking afterwards would leave a window whose title - the grip the user
   takes hold of - had been pushed off the desk by its own bottom right corner.

   A window larger than the desk keeps its size down to the desk and lands at the
   top left; a desk smaller than a window's own minimum gives a range with no
   cells in it, and Clamp answers the low end, so what survives is the window's
   top left: its title, which is what can be taken hold of.  Nothing here makes a
   window bigger, so a desk that grew leaves every window where it was. *)
PROCEDURE DeskRect (x, y, w, h, c, r: INTEGER; VAR nx, ny, nw, nh: INTEGER);
BEGIN
    nw := w;
    IF nw > c THEN nw := c END;
    IF nw < TuiWin.MINW THEN nw := TuiWin.MINW END;
    nh := h;
    IF nh > r - 1 - TOPROW THEN nh := r - 1 - TOPROW END;
    IF nh < TuiWin.MINH THEN nh := TuiWin.MINH END;
    nx := Clamp(x, 0, c - nw);
    ny := Clamp(y, TOPROW, r - 1 - nh)
END DeskRect;


(* Put a window back inside a desk of this size: first its size, then its
   position, and only what actually changed is set.  TuiWin.SetSize makes the
   window's canvas again, so calling it with the size the window already has
   would throw away a canvas and everything in it for nothing - and the
   application's own drawing with it. *)
PROCEDURE ClampWindow (w: TuiWin.Window; c, r: INTEGER);
VAR nx, ny, nw, nh: INTEGER;
BEGIN
    DeskRect(w.x, w.y, w.width, w.height, c, r, nx, ny, nw, nh);
    IF (nw # w.width) OR (nh # w.height) THEN
        w.SetSize(w, nw, nh)
    END;
    w.Move(w, nx, ny)
END ClampWindow;


(* Take hold of window i: remember which one and what the drag will do, and
   where the pointer was relative to the window's corner. *)
PROCEDURE BeginDrag (i, mode, x, y: INTEGER);
BEGIN
    dragWin := i;
    dragMode := mode;
    dragDX := x - wins[i].x;
    dragDY := y - wins[i].y
END BeginDrag;


(* The pointer, with the window in hand.  A move keeps the grab offset, so the
   window travels with the pointer and lands where the pointer put it; a resize
   takes the corner to the pointer, so the window's width is the distance from
   its left edge to the pointer - one more than the difference, because the
   pointer is on a cell and the window includes it.

   Both are clamped to the work area, which is what keeps a window on the
   desktop whatever the pointer does.  A resize makes a new canvas and does not
   lay out what is inside the window: that is the application's, and it sees the
   new size on the next frame it paints. *)
PROCEDURE Follow (x, y: INTEGER);
VAR w: TuiWin.Window;
BEGIN
    IF (dragWin >= 0) & (dragWin < nwin) THEN
        w := wins[dragWin];
        IF w # NIL THEN
            IF dragMode = DRAG_MOVE THEN
                w.Move(w, Clamp(x - dragDX, 0, cols - w.width),
                          Clamp(y - dragDY, TOPROW, rows - 1 - w.height))
            ELSIF dragMode = DRAG_SIZE THEN
                w.SetSize(w, Clamp(x - w.x + 1, TuiWin.MINW, cols - w.x),
                             Clamp(y - w.y + 1, TuiWin.MINH, rows - 1 - w.y))
            END
        END
    END
END Follow;


PROCEDURE CreateWindow* (x, y, w, h: INTEGER; title: ARRAY OF CHAR): TuiWin.Window;
VAR win: TuiWin.Window; nx, ny, nw, nh: INTEGER;
BEGIN
    win := NIL;
    IF nwin < MAXWIN THEN
        (* The request is brought inside the desk before the window is made, and
           not after: TuiWin.Create asserts that what it is given is at least
           MINW by MINH, so a window that has to be smaller than it asked for has
           to be subtracted from before it exists.  An application that asks for
           more than the desk can hold gets a window on the desk rather than a
           trap - which is what makes an application written for one screen size
           work on another. *)
        DeskRect(x, y, w, h, cols, rows, nx, ny, nw, nh);
        win := TuiWin.Create(nx, ny, nw, nh, title);
        wins[nwin] := win;
        order[nwin] := nwin;
        INC(nwin);
        SetActive(nwin - 1)
    END;
    RETURN win
END CreateWindow;


(* Follow the desk to the size the screen is showing now.

   The windows are not laid out again: the application asked for them at a
   particular place and size, and there is no formula that would put them back
   the way it meant if the desk changed - so they keep the cells they were given
   and are only brought inside the desk, which for a larger screen is nothing at
   all.  A window that had to be made smaller stays smaller when the screen grows
   again; the honest statement is that a resize can take a window's size away and
   cannot give it back.

   The desk canvas is made before the old one is given back - TuiWin.SetSize's
   rule, for the same reason: a program that cannot get the memory for the new
   desk still has the old one to draw on.

   A drag in progress is dropped rather than clamped.  It was measured from a
   corner of a window and against a desk that may not exist any more, so the next
   pointer movement would move a window by a distance the user never asked for.
   The button is still down and the event that ends the drag still arrives; the
   window is simply left where the resize put it. *)
PROCEDURE Resize* (c, r: INTEGER);
VAR i: INTEGER; newDesk: TuiCanv.Canvas;
BEGIN
    IF c < MINCOLS THEN c := MINCOLS END;
    IF r < MINROWS THEN r := MINROWS END;
    IF (c # cols) OR (r # rows) THEN
        newDesk := TuiCanv.Create(c, r);
        desk.Done(desk);
        desk := newDesk;
        cols := c;
        rows := r;
        IF menu # NIL THEN
            menu.width := cols
        END;
        FOR i := 0 TO nwin - 1 DO
            IF wins[i] # NIL THEN
                ClampWindow(wins[i], cols, rows)
            END
        END;
        (* Everything on the modal stack follows the desk as well, and each
           entry the way its own kind has to: a dialog is placed, because
           TuiDlg works out its own rectangle from the size it is given, and a
           window is clamped, because it is a window of the desk and has a
           frame that must stay on it. *)
        FOR i := 0 TO nmodal - 1 DO
            IF modal[i].dlg # NIL THEN
                modal[i].dlg.Place(modal[i].dlg, cols, rows)
            ELSIF modal[i].win # NIL THEN
                ClampWindow(modal[i].win, cols, rows)
            END
        END;
        dragMode := DRAG_NONE;
        dragWin := -1
    END
END Resize;


PROCEDURE Draw*;
VAR i, k, a, sa: INTEGER;
BEGIN
    desk.Fill(desk, 0, 0, desk.w, desk.h, DeskChar, TuiTheme.Attr(TuiTheme.Desk));
    FOR k := 0 TO nwin - 1 DO
        i := order[k];
        wins[i].Draw(wins[i], desk)
    END;
    IF menu # NIL THEN
        menu.draw(menu, desk)
    END;
    (* The modal stack goes over everything the desktop holds and under the
       status line and the cursor, which are the desktop's own and never
       covered.  The order is the order the entries were pushed, which is the
       order they were raised in: a dialog raised from a modal window is painted
       over it, and a pop-up raised from the dialog over both.  Nothing else can
       be on top of them, because while the stack holds anything nothing else is
       being offered events. *)
    FOR k := 0 TO nmodal - 1 DO
        IF modal[k].dlg # NIL THEN
            modal[k].dlg.draw(modal[k].dlg, desk)
        ELSIF modal[k].win # NIL THEN
            modal[k].win.Draw(modal[k].win, desk)
        END
    END;
    sa := TuiTheme.Attr(TuiTheme.Status);
    desk.Fill(desk, 0, rows - 1, cols, 1, " ", sa);
    desk.Print(desk, 1, rows - 1, status, sa);
    (* the mouse cursor is the cell under it with its two colours the other way
       round: no character is drawn, so the cell keeps what it was showing *)
    IF mouseOn & (mouseX >= 0) & (mouseY >= 0) & (mouseX < cols) & (mouseY < rows)
    THEN
        a := desk.AttrAt(desk, mouseX, mouseY);
        desk.SetAttr(desk, mouseX, mouseY, a MOD 16 * 16 + a DIV 16)
    END
END Draw;


(* Offer an event to the desktop.  Answers the command id a menu entry fired,
   or 0.  The event comes back with its kind set to NONE when the desktop - or
   the menu - has taken it.

   Two things happen to a pointer event before anything else sees it.  A drag in
   progress takes it: the desktop captured the mouse when the window was taken
   hold of and keeps every event until the button comes back up, so the widget
   under the pointer does not act on the movement as well - which matters,
   because a movement with the button down has Events.IsClick true of it and a
   list would otherwise re-select a row at every step of the drag.

   And a press is only a press when the event before it left the button up.  The
   input layer reports the mouse only when something about it changed, so the
   events that make up a drag arrive as a run of identical-looking "the button is
   down" reports; without that comparison a window would be raised and grabbed
   again by every step of its own drag.  The comparison is the event's own -
   Events.IsPress reads what the event before it left - so the desktop keeps no
   copy of the previous button state to get out of step with. *)
PROCEDURE Dispatch* (VAR e: Events.Event): INTEGER;
VAR cmd, i, z: INTEGER; pressed, released, taken, closed: BOOLEAN;
    local: Events.Event; who: TuiWidg.Widget;
    w: TuiWin.Window; d: TuiDlg.Dialog;
BEGIN
    cmd := 0;
    pressed := Events.IsPress(e);
    released := Events.IsRelease(e);
    IF e.kind = Events.MOUSE THEN
        mouseX := e.x;
        mouseY := e.y;
        mouseButtons := e.buttons;
        mouseOn := TRUE
    END;

    (* The modal stack, and this block is the whole of it: the top entry is
       offered the event and nothing else on the desk is.  The kind is set to
       NONE on the way out, and that one assignment is the whole of the freeze -
       every block below reads the kind, so the drag, the menu, F6, the window
       the press landed in and the application's own keys all do nothing while
       anything is modal.  It stands before the drag because a drag is the
       desk's own grab and a modal raised from inside a window must not be
       fighting one.

       What is under the top is frozen rather than gone.  A dialog raised from a
       modal window, and a pop-up raised from that dialog, each leave what they
       were raised from on the stack and behind them on the screen, and taking
       the top down gives the desk back to the one below. *)
    IF nmodal > 0 THEN
        IF modal[nmodal - 1].dlg # NIL THEN
            d := modal[nmodal - 1].dlg;
            IF d.onEvent(d, e) THEN
                IF d.closed THEN
                    cmd := d.lastCmd;
                    IF cmd = 0 THEN cmd := CANCELLED END;
                    PopKind(MODAL_DIALOG)
                END
            END
        ELSIF modal[nmodal - 1].win # NIL THEN
            w := modal[nmodal - 1].win;
            Project(w, e,
                    (e.kind = Events.MOUSE) & TuiWidg.Inside(w, e.x, e.y),
                    local);
            (* Send answers whether a widget of the ring took it.  The answer is
               deliberately not asked for: a modal window is modal whether or not
               one of its widgets wanted the event, so the kind goes to NONE
               either way.  What the window did want is noticed below it. *)
            taken := w.Send(w, local, who);
            (* An id that no widget of the window took is left in the window's
               own lastCmd - by the window's two keys as much as by one of its
               widgets - and it leaves here as the answer of this event, which
               is the road a menu entry's id already takes.  Step acts on it
               once the desk is done with the event, so a modal window's id is
               answered by the application exactly as a window's id is when the
               window is not modal. *)
            IF w.lastCmd # 0 THEN
                cmd := w.lastCmd;
                w.lastCmd := 0
            END;
            IF ~w.visible THEN
                PopWindow(w)            (* it hid itself: off the stack *)
            END
        ELSE
            CloseModal                  (* an entry with neither: drop it *)
        END;
        e.kind := Events.NONE
    END;

    IF (dragMode # DRAG_NONE) & (e.kind = Events.MOUSE) THEN
        IF released THEN
            dragMode := DRAG_NONE
        ELSE
            Follow(e.x, e.y)
        END;
        e.kind := Events.NONE
    END;

    IF menu # NIL THEN
        IF menu.onEvent(menu, e) THEN
            IF menu.lastCmd # 0 THEN
                cmd := menu.lastCmd;
                menu.lastCmd := 0
            END
        END
    END;

    IF e.kind = Events.KEYBOARD THEN
        (* F6 hands the keyboard to the next window on the desk, Shift+F6 to the
           one before it.

           Alt+F4 closes the window that has the keyboard, and it is the desk
           that does it because the desk is what holds the window: Close asks the
           window first and tells it afterwards, so the keystroke is worth
           exactly what the box on the title row is worth and no more.  A window
           that refuses keeps the keyboard and the key is still taken - the user
           asked that window, and the window answered.  With no window to ask,
           the key is left alone and belongs to the application.

           A plain Tab is deliberately not the desk's either, and is left alone
           here with its kind intact - the same way F2 and F3 reach the
           application.  The desk still does not know what a widget is; what it
           knows now is which window has the keyboard, and Send hands the event
           to that window, which walks its own ring with it.  So Tab is decided
           after the application has had its say, not before. *)
        IF (e.scan = Events.K_F4) & e.alt THEN
            i := Active();
            IF i >= 0 THEN
                closed := Close(wins[i]);
                e.kind := Events.NONE
            END
        ELSIF e.scan = Events.K_F6 THEN
            IF e.shift THEN
                FocusStep(-1)
            ELSE
                FocusStep(1)
            END;
            e.kind := Events.NONE
        END
    ELSIF e.kind = Events.MOUSE THEN
        IF pressed THEN
            i := WindowAt(e.x, e.y);
            IF i >= 0 THEN
                SetActive(i);                   (* which also raises it *)
                z := wins[i].Zone(wins[i], e.x, e.y);
                IF z = TuiWin.ZONE_CLOSE THEN
                    closed := Close(wins[i]);
                    e.kind := Events.NONE
                ELSIF z = TuiWin.ZONE_TITLE THEN
                    BeginDrag(i, DRAG_MOVE, e.x, e.y);
                    e.kind := Events.NONE
                ELSIF z = TuiWin.ZONE_CORNER THEN
                    BeginDrag(i, DRAG_SIZE, e.x, e.y);
                    e.kind := Events.NONE
                END
            END
        END
    END;
    RETURN cmd
END Dispatch;


(* Give back everything the desktop owns: each window (its canvas and then the
   record - TuiWin.Done does both, where this used to free the canvas and drop
   the record on the floor), the menu with its entry storage, and the desk. *)
PROCEDURE Done*;
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO nwin - 1 DO
        IF wins[i] # NIL THEN
            Oberon.Done(wins[i])
        END;
        wins[i] := NIL;
        order[i] := i
    END;
    nwin := 0;
    active := -1;
    dragMode := DRAG_NONE;
    dragWin := -1;
    nmodal := 0;                        (* the entries are ours, what they
                                           hold is the caller's to free *)
    IF menu # NIL THEN
        Oberon.Done(menu);
        menu := NIL
    END;
    IF desk # NIL THEN
        desk.Done(desk);
        desk := NIL
    END
END Done;

END Tui.
