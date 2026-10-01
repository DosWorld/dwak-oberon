MODULE Events;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   What the input layer reports and what a consumer acts on.

   This is the one vocabulary of input in the tree.  It is filled by the layer
   behind it - lib/<arch>/ArchInput.mod through the portable lib/common/Input.mod
   - and read by whoever wants the keyboard and the mouse: the text-mode
   interface in samples/tui, and any other interface that agrees to speak this
   record.  Nothing here knows what a device is.

   One record covers every producer: kind says which one spoke, and the fields
   that producer does not fill stay zero.  There are six kinds of event:

     MOUSE     the pointer, with the button state now and as the event before it
               left it; wheel is 0
     KEYBOARD  a key went down
     KEYUP     a key came back up
     TEXT      the user typed a character, in ch; a window reports this as a
               message of its own, a console puts the character on the KEYBOARD
               event and never sends this one
     WHEEL     the wheel turned, by whole notches in wheel, positive away from
               the user
     RESIZE    the screen says it changed size, in cols and rows

   Not every producer sends every kind, and the two that read a keyboard do not
   agree about the last two.  A console reports a keystroke once, when the key
   goes down, and knows the character at that moment - so it never sends a KEYUP
   and never sends a TEXT.  A window reports the key and the character as two
   messages of their own, and reports the key coming back up as a third, because
   a key held down is a fact a caller has to be able to stop believing; so there
   the character is on the TEXT event and the KEYBOARD one carries none.  A
   caller that reads characters reads TEXT where there is one and the KEYBOARD
   event where there is not, and a caller that reads keys reads KEYBOARD and
   ignores TEXT entirely.

   x and y are the pointer's position in the unit its own producer works in,
   which is the one thing that differs between them: a text console reports a
   character cell, a graphical window reports a pixel.  A consumer that draws
   knows which of the two it asked for.

   A RESIZE is a notification to look and not an answer: it carries the size the
   console reported, and what a console reports is often its screen *buffer*
   rather than its window, so a consumer that wants to know how big the screen is
   asks the screen.  TuiScr.Resize is the one that does, and it takes no size
   from here.

   An event is also how a consumer says it took the event: a widget that acts on
   one sets kind to NONE, and whatever sees NONE does nothing with it.  That is
   what keeps a keystroke that moved the menu from also moving a list behind it.

   A mouse event carries the buttons as they are now and as the event before it
   left them, and that is what tells a press from a movement.  A producer may
   report the pointer only when something about it changed - the console body
   does, so that a still pointer costs no frames - and then a drag arrives as a
   run of identical "the button is down" reports; a widget that acted on every
   one of them would act again at every step of a drag - a menu opening because
   the pointer crossed the bar on its way somewhere else, a button firing because
   the pointer was dragged over it.  Only the event knows what the one before it
   left, so this is where the comparison belongs: SetMouse fills prev in, and
   every consumer asks IsPress or IsRelease instead of keeping a copy of the
   previous state of its own. *)

CONST

    (* The kinds of event. *)
    NONE*     = 0;
    MOUSE*    = 1;
    KEYBOARD* = 2;
    RESIZE*   = 3;
    TEXT*     = 4;
    WHEEL*    = 5;
    KEYUP*    = 6;

    (* The scancodes the framework itself uses, as int 16h AH=00h returns them
       in the high half of AX, and as the console reports them in a key record.
       An arrow key has no ASCII code at all, so the scancode is the only name it
       has - and it is the same number on both targets, which is what lets one
       set of names serve every producer. *)
    K_ESC*   = 001H;
    K_BACK*  = 00EH;
    K_TAB*   = 00FH;
    K_ENTER* = 01CH;
    K_SPACE* = 039H;
    K_LEFT*  = 04BH;
    K_RIGHT* = 04DH;
    K_UP*    = 048H;
    K_DOWN*  = 050H;
    K_HOME*  = 047H;
    K_END*   = 04FH;
    K_PGUP*  = 049H;
    K_PGDN*  = 051H;
    K_F1*    = 03BH;
    K_F2*    = 03CH;
    K_F3*    = 03DH;
    K_F4*    = 03EH;
    K_F5*    = 03FH;
    K_F6*    = 040H;
    K_F7*    = 041H;
    K_F8*    = 042H;
    K_F9*    = 043H;
    K_F10*   = 044H;
    (* F11 and F12 are here because the first ten are all spoken for and the
       sample had two commands left to bind: the ten above are the menu bar's,
       the file dialog's and the windows', and no combination of them was left
       that a reader could be expected to guess.  A console and a BIOS both
       report these two the same way they report F1 to F10. *)
    K_F11*   = 057H;
    K_F12*   = 058H;
    (* Ins has no ASCII code, so - like an arrow - the scancode is the only name
       it has.  It is here because it and Space are the two keys a list of rows
       is marked with, and the file dialog offers both to its listing. *)
    K_INS*   = 052H;
    K_DEL*   = 053H;
    (* X is not a key the framework uses: it is here because Alt+X is the
       one the demo hangs its exit on, and the exit is matched on the key
       rather than on the character, which is 0 on a console and depends on
       the layout under BIOS.  See IsAltScan. *)
    K_X*     = 02DH;

    (* The modifiers, and the letters a consumer matches with Ctrl.  They are
       here for the same reason X is: Ctrl+S has to be named by the key and not
       by the character, because the character a Ctrl+letter makes is the
       letter's own control code - so a test on the character alone cannot tell
       Ctrl+H from Backspace or Ctrl+I from Tab, while 01FH is the S key under
       every layout there is.

       Both shifts are named and a consumer with one bit for them takes either;
       which of the two it was is a distinction nothing here has ever needed.
       Alt is reported by a window as the menu key and by a console as the
       eighth bit of the shift state, so both reach a caller as this one code. *)
    K_SHIFT*   = 02AH;
    K_SHIFT_R* = 036H;
    K_CTRL*    = 01DH;
    K_ALT*     = 038H;
    K_A*       = 01EH;
    K_C*       = 02EH;
    K_E*       = 012H;
    K_N*       = 031H;
    K_O*       = 018H;
    K_S*       = 01FH;
    K_V*       = 02FH;
    K_Y*       = 015H;
    K_Z*       = 02CH;

    (* The control codes a Ctrl+letter leaves in the ASCII half of the key.  The
       scancode is still the letter's own, so Ctrl+C arrives as the scancode of C
       with 03H where the letter's own code would be - which is why the test for
       one of these pairs the code with the ctrl flag and not the code alone. *)
    CTRL_A* = 001H;
    CTRL_C* = 003H;
    CTRL_F* = 006H;
    CTRL_V* = 016H;
    CTRL_X* = 018H;
    CTRL_Y* = 019H;
    CTRL_Z* = 01AH;

    (* The mouse buttons, as int 33h AX=0003h reports them in BX.  The left and
       the right are the same two numbers a window's mouse message uses - its
       MK_LBUTTON is 1 and its MK_RBUTTON is 2 - but the middle is not: that
       message says 10H where this says 4, and it has the shift and control keys
       in the same set besides.  So a window body picks the three out of wParam
       one at a time rather than passing it through. *)
    MB_LEFT*   = 1;
    MB_RIGHT*  = 2;
    MB_MIDDLE* = 4;

TYPE

    Event* = RECORD
        kind*    : INTEGER;             (* NONE, MOUSE, KEYBOARD, RESIZE, TEXT
                                           or WHEEL *)
        x*, y*   : INTEGER;             (* the pointer, in the producer's unit *)
        buttons* : INTEGER;             (* the button state: a set of MB_* *)
        prev*    : INTEGER;             (* what the event before this one left *)
        wheel*   : INTEGER;             (* a WHEEL: whole notches, away is + *)
        key*     : INTEGER;             (* the ASCII code, 0 for a pure scancode key *)
        scan*    : INTEGER;             (* the scancode *)
        ch*      : INTEGER;             (* a TEXT, or the character a KEYBOARD
                                           made: 0 when the event is neither,
                                           and 0 on every KEYBOARD a window
                                           sends, which reports the character
                                           as a TEXT event of its own.  Like x
                                           and y it is in the producer's unit -
                                           a window reports a Unicode code
                                           point, a console the byte its code
                                           page gives - but only the window
                                           ever sends a TEXT, and that is the
                                           one a consumer that reads characters
                                           reads.  See the TEXT event below *)
        cols*, rows*: INTEGER;          (* a resize: what the console said *)
        ctrl*, alt*, shift*: BOOLEAN
    END;

VAR
    lastButtons: INTEGER;               (* what the last mouse event left down *)


PROCEDURE Clear* (VAR e: Event);
BEGIN
    e.kind := NONE;
    e.x := 0;
    e.y := 0;
    e.buttons := 0;
    e.prev := 0;
    e.wheel := 0;
    e.key := 0;
    e.scan := 0;
    e.ch := 0;
    e.cols := 0;
    e.rows := 0;
    e.ctrl := FALSE;
    e.alt := FALSE;
    e.shift := FALSE
END Clear;


(* One key event.  shiftState is the BIOS shift state as int 16h AH=02h returns
   it in AL, which the caller has already read: bit 0 is the right shift, bit 1
   the left one, bit 2 control and bit 3 alt.  The Windows console body builds
   the same four bits out of dwControlKeyState before it calls this.

   The character the key makes is not a parameter: a producer that has a wide one
   - a Windows console reports a WCHAR - writes it into the event's own ch field
   after this returns, and the one field is 0 for a key that makes no character
   at all.  key stays what it always was, the low byte of the same character, so
   every comparison written against it still means what it meant. *)
PROCEDURE SetKey* (VAR e: Event; scan, key, shiftState: INTEGER);
BEGIN
    Clear(e);
    e.kind := KEYBOARD;
    e.scan := scan;
    e.key := key;
    e.ch := key;
    e.shift := ODD(shiftState) OR ODD(shiftState DIV 2);
    e.ctrl := ODD(shiftState DIV 4);
    e.alt := ODD(shiftState DIV 8)
END SetKey;


(* The same key, coming back up.  It is its own kind and not a flag on the
   KEYBOARD event, because the two are not the same news to a consumer: a widget
   that acts on a keystroke must act once, when the key went down, and an event
   that carried "this key is still down" would have it act again at the moment
   the key was let go.  A kind a consumer does not switch on is inert, and every
   consumer written before this one existed switches on KEYBOARD.

   A producer that never learns of a key coming up - a console does not, and a
   DOS machine does not - never sends this, and a consumer that tracks what is
   held has to do without it there.  What the field is for is a window, where a
   key that is held is a fact the caller would otherwise have no way to stop
   believing. *)
PROCEDURE SetKeyUp* (VAR e: Event; scan, key, shiftState: INTEGER);
BEGIN
    Clear(e);
    e.kind := KEYUP;
    e.scan := scan;
    e.key := key;
    e.ch := key;
    e.shift := ODD(shiftState) OR ODD(shiftState DIV 2);
    e.ctrl := ODD(shiftState DIV 4);
    e.alt := ODD(shiftState DIV 8)
END SetKeyUp;


(* One mouse event.  This is where the previous button state is recorded, which
   is what makes a press tellable from a movement; the caller does not have to
   track it, and two callers cannot disagree about it. *)
PROCEDURE SetMouse* (VAR e: Event; x, y, buttons: INTEGER);
BEGIN
    Clear(e);
    e.kind := MOUSE;
    e.x := x;
    e.y := y;
    e.buttons := buttons;
    e.prev := lastButtons;
    lastButtons := buttons
END SetMouse;


(* The wheel turned, by whole notches and away from the user.  There is no
   pointer position in it: a window reports the wheel at the *screen* position of
   the pointer while every other mouse message carries the client one, and a
   record that mixed the two would move the pointer every time the wheel turned.
   So a consumer of this event reads wheel and nothing else. *)
PROCEDURE SetWheel* (VAR e: Event; notches: INTEGER);
BEGIN
    Clear(e);
    e.kind := WHEEL;
    e.wheel := notches
END SetWheel;


(* The user typed a character, which is not the same thing as pressing a key: a
   key that makes none - an arrow, a function key - sends no character at all,
   and one keystroke may make several.

   ch is a Unicode code point.  That is what a window has and what a window
   sends; a producer holding only a byte of a code page would have to say so,
   and none does, because the one event this is has no consumer on a target
   that could not produce a code point.

   This is the message a text field wants and a widget that answers to named keys
   ignores; the console body never sends it, because a console reports the
   character inside the key record and there is nothing to send twice. *)
PROCEDURE SetText* (VAR e: Event; ch: INTEGER);
BEGIN
    Clear(e);
    e.kind := TEXT;
    e.ch := ch
END SetText;


(* One screen resize, as the console reported it.

   cols and rows are what the console said, and they are the size of its screen
   *buffer* - a console with a scrollback keeps a buffer taller than the window
   it shows, and a buffer that has been grown keeps its lines when the window
   shrinks.  Measured on a console whose buffer was 36 rows over a 27-row window:
   the report said 36.  So this is a notification that the screen changed and not
   an answer about how big it is, and a consumer asks the screen for that.
   TuiScr.Resize is the one that does, and it takes no size from here. *)
PROCEDURE SetSize* (VAR e: Event; cols, rows: INTEGER);
BEGIN
    Clear(e);
    e.kind := RESIZE;
    e.cols := cols;
    e.rows := rows
END SetSize;


(* Whether e is this keystroke - the test every widget's onEvent starts with. *)
PROCEDURE IsKey* (VAR e: Event; scan: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (e.kind = KEYBOARD) & (e.scan = scan);
    RETURN r
END IsKey;


(* Whether e is one of the Ctrl+letter keys above.  The ASCII code alone would
   be enough on a keyboard that sends nothing else for those keys, but the flag
   is what the caller actually means, and it is the flag that tells Ctrl+H from
   Backspace and Ctrl+I from Tab. *)
PROCEDURE IsCtrl* (VAR e: Event; code: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (e.kind = KEYBOARD) & e.ctrl & (e.key = code);
    RETURN r
END IsCtrl;


(* Whether e is one of the keys that has no character of its own - an arrow, a
   function key - held with Ctrl down.

   This is a second predicate and not a second use of IsCtrl because the two
   kinds of key report themselves differently and only one of them has a code to
   be named by.  A Ctrl+letter arrives with the letter's own control code where
   the character would be, so IsCtrl has something to compare; a Ctrl+arrow
   arrives with a character of zero, exactly as a plain arrow does, and there is
   nothing in the key field to tell the two apart.  The scan code is what is left
   - and on both targets it is the arrow's own scan code, because a console and
   int 16h alike report the extended key by the code the key makes rather than by
   the number the keyboard sends ahead of it.

   So a caller that wants Ctrl+Left writes this, and a caller that wants a plain
   Left writes IsKey - which matches the Ctrl one as well, since the scan code is
   the same, so the Ctrl arm has to stand first in the chain. *)
PROCEDURE IsCtrlScan* (VAR e: Event; scan: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (e.kind = KEYBOARD) & e.ctrl & (e.scan = scan);
    RETURN r
END IsCtrlScan;


(* The character a keystroke made, or 0 when it made none.

   There is one place in this record a character lives, and two halves of it are
   written by every producer: ch is the character itself and key is its LOW BYTE,
   which is what every comparison against a key has always been and what a scan
   code is not.  For an ASCII letter the two are the same number, so a gate
   written on key reads as a gate on the character for as long as the keyboard
   only makes ASCII - and stops reading as one the moment it does not.  П is
   U+041F and its low byte is 1FH, so a test of `key >= 20H` refuses the letter
   outright; я is U+044F, whose low byte 4FH is the letter O, so the same test
   lets a different character through.  Measured 2026-10-01 with
   _probe/FldWide.mod: of А U+0410 to я U+044F, the sixteen letters А..П were
   refused by a text field and the sixteen Р..Я went in.

   So the question is asked HERE and not at each call site, and the answer is a
   code point - the character itself, on both pages.  ch answers whenever it
   holds a character; when it holds none, key answers if it is one, which is the
   producer that reports a byte and leaves ch at zero, and 0 answers otherwise,
   which is a key with no character of its own - an arrow, a function key, and
   Enter - and every control code.

   Zero is "no character", and a caller does not have to know which of the three
   happened: an arm that types what this answers types only when there is
   something to type.  Nothing here is about Ctrl or Alt; a caller that wants a
   plain key still says so, because AltGr on several layouts makes a character
   of its own and a Ctrl+letter carries the letter's control code. *)
PROCEDURE Char* (VAR e: Event): INTEGER;
VAR cp: INTEGER;
BEGIN
    cp := e.ch;
    IF cp < 20H THEN
        cp := 0;
        IF (e.ch = 0) & (e.key >= 20H) & (e.key <= 0FFH) THEN
            cp := e.key
        END
    END;
    RETURN cp
END Char;


(* Whether an event is the key scan with Alt and without Ctrl.

   Alt and Ctrl are tested separately because AltGr sets **both** of the shift
   bits - BIOS shift state bits 2 and 3, and the console's RIGHT_ALT and
   LEFT_CTRL together - and on several layouts AltGr with a letter produces a
   character of its own.  So a caller that means Alt and not Ctrl has to say so,
   or the AltGr combinations would be taken for it.

   The match is on the scan code and not on the character: the character for
   Alt+X is 0 on a console and is the layout's own letter under BIOS, while
   02DH is the X key under every layout. *)
PROCEDURE IsAltScan* (VAR e: Event; scan: INTEGER): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (e.kind = KEYBOARD) & e.alt & ~e.ctrl & (e.scan = scan);
    RETURN r
END IsAltScan;


(* Whether a button is down in this event, whether it just went down or was
   already down.  This is the test for "keep following the pointer", not for
   "the user clicked me". *)
PROCEDURE IsClick* (VAR e: Event): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (e.kind = MOUSE) & ODD(e.buttons);
    RETURN r
END IsClick;


(* Whether this event is the moment a button went down: nothing was down before
   it and something is now.  This is the test for "the user clicked me" - what a
   button, a menu entry and a dialog answer to, and what the desktop uses to
   begin a drag.  A movement that carries a button already down is not one, so a
   drag that starts somewhere else and passes over a widget does not operate
   it. *)
PROCEDURE IsPress* (VAR e: Event): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (e.kind = MOUSE) & ODD(e.buttons) & ~ODD(e.prev);
    RETURN r
END IsPress;


(* Whether this event is the moment the last button came up - the end of a drag
   or a click that held nothing.  An event with a button still down is not one,
   so a drag cannot end halfway through itself. *)
PROCEDURE IsRelease* (VAR e: Event): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (e.kind = MOUSE) & ~ODD(e.buttons) & ODD(e.prev);
    RETURN r
END IsRelease;

END Events.
