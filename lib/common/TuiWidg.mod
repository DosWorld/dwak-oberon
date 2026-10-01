MODULE TuiWidg;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The part of a widget the framework itself needs: where it is, whether it is
   visible and focused, the canvas it draws into, and the two ways in - an
   event, and the keyboard on or off.

   Everything else is data only, and the reason is the dialect: a method field
   has to name a receiver type, and a procedure declared for one widget type
   cannot be stored in a field declared for another.  So each widget declares
   its own draw and onEvent, binds them in its own Create and is called with an
   explicit self, as ByteArr does it.

   The procedures here are the whole of what the layer above a widget may ask of
   it, and they are declared for the base type for that one reason: it takes an
   event (handler) and the keyboard (taker), it draws itself when it is told
   where (painter), it is told when the room it has changed (resizer), and it
   answers an id it fired (onCommand).  Each widget binds its own to them and
   narrows back to itself with a type guard, so a window paints and routes what
   it owns without ever naming a widget type - which is what an application had
   to write itself before, once per widget, in a second place that had to be
   kept in step with the first.

   A widget with nothing to offer leaves the field NIL, and the framework skips
   it: a progress bar has no id to answer with and never enters a keyboard ring.
   What is left here is what every widget has in common, which is what lets
   Inside and WindowAt be written once.

   GIVING BACK WHAT IT TOOK IS NOT ONE OF THOSE FIELDS, AND USED TO BE.  This
   record carried a `disposer` of its own beside the destructor every widget
   already had, and the two were the same act written twice - the same body, two
   names, and a reader left to work out which one a window actually called.  The
   base record now extends `Oberon.ObjectDesc`, so a widget is an object like
   every other one in this library: it inherits the one `Done` field, its
   constructor binds `x.Done := DoneSomething`, and a window gives back what it
   owns with `Oberon.Done`.  `lib/common/Oberon.mod` is the manual and says why
   there is exactly one destructor and never a second one under another name.

   A widget's x and y live in the coordinate system of whatever canvas it draws
   into: a list inside a window uses the window's own canvas, a window uses the
   desktop.  Only the desktop's coordinates are screen cells, and that is what
   an event carries. *)

IMPORT TuiCanv, Events, Oberon;

TYPE

    Widget* = POINTER TO WidgetDesc;

    (* The five an owner calls a widget through, and the reason the base carries
       any methods at all.

       A method field has to name a receiver type, and a procedure declared for
       one widget type cannot be stored in a field declared for another - so a
       window could not call "whatever this widget's onEvent is" by name, and a
       widget could not hand one up.  These are declared for the base type
       instead, with the receiver written as an ordinary first parameter, the way
       TuiCmb declares the two its owner supplies; each widget binds its own
       to them in its own Create and narrows back to itself with a type guard.

       That is what lets a window - and Tui above it - pass an event to a widget
       without knowing what kind of widget it is, paint it, hand it a command id
       and give it back.  A widget with nothing to offer leaves the field NIL. *)
    Handler* = PROCEDURE (w: Widget; VAR e: Events.Event): BOOLEAN;
    Taker*   = PROCEDURE (w: Widget; on: BOOLEAN);

    (* Where it draws itself.  The target is the canvas of whatever owns it - a
       window's own canvas for a widget of that window - and the widget's x and y
       are read in that canvas, so one signature serves every kind. *)
    Painter* = PROCEDURE (w: Widget; target: TuiCanv.Canvas);

    (* What it does when the room it has changed.  The window calls it, for every
       widget it owns that binds one, after a resize - its own, from the corner
       being dragged or from the desk being resized - and that is the whole of
       what tells a widget its rectangle is not what it was.  cw and ch are the
       canvas it draws into as it is now, which is the room the widget has to
       work with, and is not the widget's own width and height: a panel that
       fills its window sets its own from these, and one that keeps a corner
       leaves them alone.

       Only the widgets that hold parts of their own bind it.  A list, a table, a
       text area read their geometry from x, y, width and height every time they
       draw, so a widget that was resized is drawn to its new size on the next
       frame with nothing called at all.  What needs the call is a widget whose
       parts are widgets - a panel, which has to put them where they belong - and
       that is why this is a method and not a convention: the window cannot know
       which of the two a widget is. *)
    Resizer* = PROCEDURE (w: Widget; cw, ch: INTEGER);

    (* What it does with an id.  TRUE means it acted on it, which stops the
       search; a widget that carries no ids but is still a command's target - a
       window - is the other user of this field. *)
    OnCommand* = PROCEDURE (w: Widget; cmd: INTEGER): BOOLEAN;

    (* Giving back what it took is the inherited `Done`, and it is not declared
       here.  A widget's destructor is `PROCEDURE DoneSomething (self:
       Oberon.Object)`, it guards down to itself, and the constructor binds it -
       see the note at the head of this module and `Oberon.mod` for the rule. *)
    WidgetDesc* = RECORD (Oberon.ObjectDesc)
        x*, y*, width*, height*: INTEGER;
        visible*, focused*: BOOLEAN;
        canvas*: TuiCanv.Canvas;           (* a canvas of its own, or NIL *)
        handler*: Handler;                  (* what takes an event, or NIL *)
        taker*:   Taker;                    (* the keyboard on and off, or NIL *)
        (* The id it fired, 0 for none.  A widget with a window hands the id to
           that window and leaves this alone; the field is what a widget without
           one writes instead, and what a window writes when an id is its own
           last word on the event.  Either way the desk reads it here. *)
        lastCmd*: INTEGER;
        painter*:   Painter;                (* how it draws itself, or NIL *)
        resizer*:   Resizer;                (* what it does when resized, or NIL *)
        onCommand*: OnCommand;              (* what it does with an id, or NIL *)

        (* The two places an application hangs what it knows on the thing
           itself, and the reason they are on every widget rather than on a
           window: ten windows of one kind are ten separate pieces of work, and
           what tells them apart has to travel with the window.  A callback is
           handed the widget and nothing else - a widget's handler gets the
           widget, a window's own onCommand gets the window - so "which one is
           this" has to be a question the thing itself can answer. *)

        (* The application's own number for it: which window this is, which
           control fired.  0 means unnamed, which is what a widget nobody has
           numbered reports. *)
        id*:        INTEGER;

        (* An address the application keeps beside it - the record of its own
           that belongs to this window, its file, its buffer.  An INTEGER and
           not a pointer, because this dialect has no untyped pointer: a pointer
           goes in with SYSTEM.VAL(INTEGER, p), or SYSTEM.ADR(p^) when p is the
           only designator there is, and comes back out with
           SYSTEM.VAL(PMyRec, w.data) - the two spellings give the same number
           (measured), and NIL is 0.  What is stored is the address alone: the
           type comes back from the reader, so writer and reader are one
           agreement the compiler cannot check for them. *)
        data*:      INTEGER
    END;


(* Whether the point is in the widget's rectangle. *)
PROCEDURE Inside* (w: Widget; x, y: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := w.visible & (x >= w.x) & (y >= w.y) &
         (x < w.x + w.width) & (y < w.y + w.height);
    RETURN r
END Inside;


PROCEDURE SetRect* (w: Widget; x, y, width, height: INTEGER);
BEGIN
    w.x := x;
    w.y := y;
    w.width := width;
    w.height := height
END SetRect;

END TuiWidg.
