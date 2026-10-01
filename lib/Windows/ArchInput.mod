MODULE ArchInput;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The two devices the interface listens to, as Windows has them: the keyboard
   and the mouse.  The event they produce is Events', and the module a program
   imports is lib/common/Input.mod, which forwards to this one - so nothing
   above either of them knows which host is underneath.

   This file carries two hosts and not one, and that is the whole reason it is
   split.  A Windows program is either a console program, which reads a queue it
   has to ask for, or a windowed one, which is told what happened in messages it
   may not ask for; the two share the record and nothing else, so the body is
   chosen by the target and not by a property of the running program - which of
   the two a build is, is known when it is built.

   Between them the two bodies answer the same five entries - Open, Close, Poll,
   Idle and FromMessage - so a caller is written once and compiled twice.  In
   each body one of the two ways in is a no-op: a console has no messages, a
   window has no queue to poll.

   The console body is the older one and the one that has been measured.  On
   Windows there is no interrupt to simulate: the console keeps a queue of input
   records and this module reads them, which is a better arrangement than the
   DOS one in every way but one - the queue has to be asked for records rather
   than for a key.  A record carries its own kind, so what the DOS body does
   with two interrupts (take the key, then ask for the shift state) is one
   record here, and the mouse's position arrives in cells rather than in pixels,
   so nothing is divided down.  The console body answers one thing the DOS one
   cannot: a console that has been resized reports it in the input queue, so
   there the screen's own change is an event like any other.

   The window body is the mirror of it - it is pushed to and never asks - and
   that is why its Poll answers nothing.  FromMessage below is where it lives. *)

$IF (win32con | win64con | win32dll | win64dll)

IMPORT SYSTEM, WINAPI, Events;

CONST
    KERNEL = "kernel32.dll";

    STD_INPUT_HANDLE = -10;

    GENERIC_READ_WRITE = 0C0000000H;
    SHARE_RW           = 3;
    OPEN_EXISTING      = 3;

    (* The console input mode that raw input means: mouse records in, window-size
       records in, extended flags on, and line input, echo, Ctrl+C-as-a-signal
       and quick edit off.  It is written as a value rather than masked into the
       old one - the dialect has no bit operators on integers at all, '&', 'OR'
       and '~' being for BOOLEAN - and SetConsoleMode takes a whole mode in any
       case.  Quick edit has to be turned off explicitly, and EXTENDED_FLAGS is
       what makes the console look at that bit: left on, the first click starts
       a text selection and the console sends nothing at all until it is
       cleared.  Line input and echo left on would be worse still - the console
       would hold every key until Enter and hand over a line of text instead of
       the keys that made it. *)
    MODE_RAW = 98H;                 (* MOUSE_INPUT + WINDOW_INPUT + EXTENDED_FLAGS *)

    (* dwControlKeyState, as far as the framework is concerned.  Each of these
       is a single bit, so a state is tested for one by dividing by it and
       asking whether the quotient is odd. *)
    RIGHT_ALT     = 1;
    LEFT_ALT      = 2;
    RIGHT_CTRL    = 4;
    LEFT_CTRL     = 8;
    SHIFT_PRESSED = 10H;

    (* INPUT_RECORD: a kind, two bytes that pad it out to four, and sixteen
       bytes of record.  The fields inside those sixteen are read at the offsets
       the Win32 headers put them at, and they are read as bytes and words
       rather than declared as a record with INTEGER fields: an INTEGER is eight
       bytes on a 64-bit target, so a record built out of them would have one
       layout on a 32-bit target and another on a 64-bit one, and neither would
       be Win32's.  A key record is a BOOL, three WORDs, a WCHAR and a DWORD -
       bKeyDown, wRepeatCount, wVirtualKeyCode, wVirtualScanCode, uChar and
       dwControlKeyState - and a mouse record is a COORD, three DWORDs: the
       position, the buttons, the control keys and the event flags. *)
    KEY_EVENT   = 1;
    MOUSE_EVENT = 2;
    (* The console saying its screen changed size.  Its payload is a bare COORD,
       so the two words are the columns and the rows it reports - which is the
       size of the screen *buffer* and not of the window, as the comment on
       Events.SetSize says.  It arrives because MODE_RAW turns ENABLE_WINDOW_INPUT
       on; with that bit clear the console reports nothing about the window at
       all. *)
    WINDOW_BUFFER_SIZE_EVENT = 4;

    (* The offsets below are counted from the start of the payload, which is
       where GetWord reads: the four bytes in front of it are the kind and the
       padding that gives the sixteen bytes their alignment.  They are the Win32
       headers' own offsets, so they are passed as they stand and there is
       nothing to add to them - adding the four would read each field four bytes
       past itself, and a scancode read that way comes out of the control key
       state, which is zero for every key that carries no modifier. *)
    K_DOWN  = 0;                    (* BOOL bKeyDown *)
    K_SCAN  = 8;                    (* WORD wVirtualScanCode *)
    K_CHAR  = 10;                   (* WCHAR uChar *)
    K_STATE = 12;                   (* DWORD dwControlKeyState *)
    M_X       = 0;                  (* COORD dwMousePosition *)
    M_Y       = 2;
    M_BUTTONS = 4;                  (* DWORD dwButtonState *)
    S_X       = 0;                  (* COORD dwSize, in a size record *)
    S_Y       = 2;

    (* Idle waits on the console's input handle, which is signalled when there
       is something in the queue.  A timeout bounds the wait, so a signal that
       never comes costs a frame every so often rather than the program. *)
    WAITMS = 50;

TYPE
    Rec = RECORD                    (* INPUT_RECORD, twenty bytes *)
        kind, pad: WCHAR;
        payload: ARRAY 16 OF BYTE
    END;

VAR
    hi: INTEGER;                    (* the console's input *)
    opened: BOOLEAN;
    saveMode: INTEGER;              (* the mode it had before we took it *)
    lastX, lastY, lastButtons: INTEGER;
    name: ARRAY 16 OF CHAR;


PROCEDURE [windows-, KERNEL, ""] GetConsoleMode* (h, m: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] SetConsoleMode* (h, m: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] GetNumberOfConsoleInputEvents* (h, n: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] ReadConsoleInputW* (h, buf, count, read: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] WaitForSingleObject* (h, ms: INTEGER): INTEGER;


(* A word at an offset in the record's sixteen bytes, and a double word as the
   two words of it. *)
PROCEDURE GetWord (VAR rec: Rec; off: INTEGER): INTEGER;
VAR w: WCHAR;
BEGIN
    SYSTEM.GET(SYSTEM.ADR(rec.payload[0]) + off, w);
    RETURN ORD(w)
END GetWord;


PROCEDURE GetDWord (VAR rec: Rec; off: INTEGER): INTEGER;
BEGIN
    RETURN GetWord(rec, off) + GetWord(rec, off + 2) * 65536
END GetDWord;


(* Take the console's input, in the mode raw input needs.

   The handle to start from is stdin, and it is the right one when the program
   was started from a console; when it was started with its input redirected,
   stdin belongs to no console and asking it for a console mode fails, so the
   fallback opens CONIN$, which is the console itself. *)
PROCEDURE Open*;
VAR ok: BOOLEAN; mode: INTEGER;
BEGIN
    lastX := -1;
    lastY := -1;
    lastButtons := -1;
    mode := 0;                      (* an out DWORD into an INTEGER: see Poll *)
    hi := WINAPI.GetStdHandle(STD_INPUT_HANDLE);
    ok := GetConsoleMode(hi, SYSTEM.ADR(mode)) # 0;
    IF ~ok THEN
        name := "CONIN$";
        hi := WINAPI.CreateFileA(SYSTEM.ADR(name), GENERIC_READ_WRITE, SHARE_RW,
                                 NIL, OPEN_EXISTING, 0, 0);
        ok := GetConsoleMode(hi, SYSTEM.ADR(mode)) # 0
    END;
    IF ok THEN
        saveMode := mode;
        ok := SetConsoleMode(hi, MODE_RAW) # 0
    END;
    opened := ok
END Open;


PROCEDURE Close*;
VAR res: INTEGER;
BEGIN
    IF opened THEN
        res := SetConsoleMode(hi, saveMode);
        opened := FALSE
    END
END Close;


(* One event, if the console's queue has one.

   The queue may hold several records at once and most of them are not events
   the framework wants: a key that came up, a mouse that moved within the cell
   it was already in.  So the queue is drained until an event is found, and what
   was drained is not wasted - a key-up is what tells the next Poll that the
   key is no longer down.

   The console reports a key by the code the key makes, not by the letter on it,
   and that code is the same scan code int 16h returns - which is what lets
   Events' K_* constants name it on both targets.  A key with no character of
   its own, an arrow or a function key, arrives with a character of zero, and
   the code is what is left.  That character is a wide one and the event carries
   it whole in ch; key keeps its low byte, which is what the DOS body reads out
   of AX and what every comparison against a key has always been.

   The shift state differs from the BIOS one in one place only: the console says
   a shift key is down without saying which, and the framework's state byte has
   a bit for each, so a shift is reported as the left one. *)
PROCEDURE Poll* (VAR e: Events.Event): BOOLEAN;
VAR
    got, ok: BOOLEAN;
    n, read, kind, scan, key, shift, x, y, b, st, w: INTEGER;
    rec: Rec;
BEGIN
    got := FALSE;
    Events.Clear(e);
    IF opened THEN
        (* n starts at zero because the count comes back as a Win32 DWORD and an
           INTEGER is eight bytes here: only the low four are written, and the
           other four would otherwise be whatever the stack last held - a count
           that is then read as a huge negative, and a keyboard that answers
           nothing. *)
        n := 0;
        ok := GetNumberOfConsoleInputEvents(hi, SYSTEM.ADR(n)) # 0;
        WHILE ok & (n > 0) & ~got DO
            (* THE WIDE CALL, and the record it fills is laid out the same as the
               narrow one's: uChar is at the same offset in both, so this is a
               name and not a layout.  What it changes is what a letter is.  The
               narrow call answers AsciiChar - one byte of the console's INPUT
               code page, which on a Russian machine is not the code page the
               interface draws in - so a Cyrillic key arrived as a byte that
               means a different letter, the same garbage the file dialog showed
               for a name.  UnicodeChar is the character itself. *)
            ok := ReadConsoleInputW(hi, SYSTEM.ADR(rec), 1, SYSTEM.ADR(read)) # 0;
            IF ok THEN
                n := n - 1;
                kind := ORD(rec.kind);
                IF kind = KEY_EVENT THEN
                    IF GetDWord(rec, K_DOWN) # 0 THEN
                        scan := GetWord(rec, K_SCAN);
                        w := GetWord(rec, K_CHAR);
                        key := w MOD 256;
                        st := GetDWord(rec, K_STATE);
                        shift := 0;
                        IF ODD(st DIV SHIFT_PRESSED) THEN
                            shift := shift + 2            (* the left shift *)
                        END;
                        IF ODD(st DIV RIGHT_CTRL) OR ODD(st DIV LEFT_CTRL) THEN
                            shift := shift + 4
                        END;
                        IF ODD(st DIV RIGHT_ALT) OR ODD(st DIV LEFT_ALT) THEN
                            shift := shift + 8
                        END;
                        Events.SetKey(e, scan, key, shift);
                        (* key stays the low byte, because every comparison ever
                           written against it is a byte comparison and an
                           accelerator is a letter of the Latin alphabet.  The
                           character itself goes in ch, which is where the event
                           record says a producer puts what the keyboard made -
                           a code point, and 0 for a key that makes none. *)
                        e.ch := w;
                        got := TRUE
                    END
                ELSIF kind = MOUSE_EVENT THEN
                    x := GetWord(rec, M_X);
                    y := GetWord(rec, M_Y);
                    b := GetDWord(rec, M_BUTTONS);
                    IF (b # lastButtons) OR (x # lastX) OR (y # lastY) THEN
                        lastButtons := b;
                        lastX := x;
                        lastY := y;
                        Events.SetMouse(e, x, y, b);
                        got := TRUE
                    END
                ELSIF kind = WINDOW_BUFFER_SIZE_EVENT THEN
                    (* Every one of these is reported, without asking whether it
                       says something new.  Comparing the payload against the
                       size the screen was last known to have would drop the
                       report that matters: a window made smaller over a buffer
                       that did not change sends a record saying the size the
                       buffer already had, and that is exactly the moment the
                       interface has to look again.  The cost of not comparing is
                       one query that finds nothing to do - TuiScr.Resize
                       compares the answer against what it has. *)
                    Events.SetSize(e, GetWord(rec, S_X), GetWord(rec, S_Y));
                    got := TRUE
                END
            END
        END
    END;
    RETURN got
END Poll;


(* Wait for the console to have something to read.  A console input handle is
   waitable, and it is signalled exactly when the queue is not empty, which is
   what the DOS body gets from the tick counter. *)
PROCEDURE Idle*;
VAR res: INTEGER;
BEGIN
    IF opened THEN
        res := WaitForSingleObject(hi, WAITMS)
    ELSE
        WINAPI.Sleep(WAITMS)
    END
END Idle;


(* A console has no message queue and no window procedure, so nothing calls
   this.  It is here because the module above this one offers one entry for
   every host - a caller names it whichever host it is compiled for - and this
   is the arm that has nothing to answer. *)
PROCEDURE FromMessage* (msg, wParam, lParam: INTEGER; VAR e: Events.Event): BOOLEAN;
BEGIN
    RETURN FALSE
END FromMessage;


(* A console reads its characters one way and has no second reading to choose
   between, so there is nothing here to set.

   The two-way case is a window's, and it is the A and W classes: what the
   console body reads is a character of the console's own, which arrives inside
   the key record as the byte a code page gives - it is written into the event's
   own ch field - and no TEXT event is ever sent from here.  So the flag is
   accepted and not kept, and a caller that sets it has said something true of a
   window and nothing at all of this. *)
PROCEDURE WideChars* (on: BOOLEAN);
BEGIN
END WideChars;

$ELSIF (win32gui | win64gui)

IMPORT SYSTEM, Events;

(*
   The windowed host: the input layer as a function of a window procedure.

   A windowed program is not allowed to ask for its input.  It is sent messages,
   by the loop it has of its own through PeekMessage and DispatchMessage, and
   the only place a message exists is the window procedure that receives it.  So
   the entry below is a push and not a poll: whoever owns that procedure hands
   each message here, gets an event back if the input layer had one to make of
   it, and handles the message itself if it did not.

   That is the whole of the contract and it is deliberately not a pump.  The
   window class, the message filter, the moment a frame is built and the wait
   between frames are the caller's; this module never calls PeekMessage, never
   dispatches and never waits.  It could not: it is called from inside a window
   procedure, and pumping messages from there re-enters the procedure.

   What it does own is the meaning of a message - whether WM_KEYDOWN is a key to
   report, what a scancode is, which bit of wParam is the middle button - so
   that two programs cannot disagree about it.

   The four entries the other body has are here too, because the module above
   this one offers them on every host.  Two of them do nothing: there is nothing
   to poll, the messages being pushed, and nothing to wait for, the wait
   belonging to the caller's loop - a caller that calls Poll here is told there
   is nothing, which is true.  Open and Close are not empty, and what they do is
   the one thing about a windowed host that is not a message: see the comment on
   Open below. *)

CONST
    (* The messages this layer owns.  Every one of them can be turned into an
       event out of the two parameters alone; everything else - a paint, a
       command, a timer, a close - is the caller's, and so is WM_SIZE, which a
       window has to answer by resizing the surface it draws on before anything
       can be drawn at all. *)
    WM_KEYDOWN     = 100H;
    WM_KEYUP       = 101H;
    WM_CHAR        = 102H;
    WM_SYSKEYDOWN  = 104H;
    WM_SYSKEYUP    = 105H;
    WM_MOUSEMOVE   = 200H;
    WM_LBUTTONDOWN = 201H;
    WM_LBUTTONUP   = 202H;
    WM_RBUTTONDOWN = 204H;
    WM_RBUTTONUP   = 205H;
    WM_MBUTTONDOWN = 207H;
    WM_MBUTTONUP   = 208H;
    WM_MOUSEWHEEL  = 20AH;
    WM_KILLFOCUS   = 2;

    (* One notch of the wheel.  A message reports a delta counted in these, and
       a driver that reports less than a whole notch per click is possible:
       Windows accumulates the remainder itself and sends a whole multiple once
       enough of them have arrived, so a delta below one notch is dropped here
       rather than carried.  What that loses is a wheel that never reaches a
       whole notch at all, which no driver seen does. *)
    WHEEL_DELTA = 120;

    (* The virtual keys this body has to name, and the list is three long
       because a scancode is not read from here.  Nothing below needs VK_A or
       VK_F2: a virtual key is the key's name on the current layout, a scancode
       is the key's place on the keyboard, and it is the scancode a message
       carries and the K_* constants name.  What is left is the three modifiers,
       whose state is not a key event of its own but a field on every event. *)
    VK_SHIFT   = 10H;
    VK_CONTROL = 11H;
    VK_MENU    = 12H;

    (* The console's input handle, by the kernel's own name for it, and the one
       bit of the console mode the mouse needs.  Both are declared in the console
       body above as well; they are repeated here rather than shared, because the
       two bodies are alternatives and only one of them is ever compiled, so
       there is no scope in which one could lend the other a constant. *)
    STD_INPUT_HANDLE   = -10;
    ENABLE_MOUSE_INPUT = 10H;

    (* The button bits of wParam, as Win32 names them.  MK_LBUTTON and
       MK_RBUTTON happen to be the numbers Events.MB_LEFT and MB_RIGHT are;
       MK_MBUTTON is not the number MB_MIDDLE is, and the same word carries
       MK_SHIFT and MK_CONTROL besides, so TuiBtns below picks the three out one
       at a time rather than passing wParam through. *)
    MK_LBUTTON = 1;
    MK_RBUTTON = 2;
    MK_MBUTTON = 10H;

    (* The halves of a UTF-16 surrogate pair, and the arithmetic that rejoins
       them: a code point above the BMP is 10000H + (high - D800H) * 400H +
       (low - DC00H), and neither half is a character on its own.  All six are
       the Win32 headers' own numbers. *)
    SurHigh     = 0D800H;
    SurHighLast = 0DBFFH;
    SurLow      = 0DC00H;
    SurLowLast  = 0DFFFH;
    SurBase     = 10000H;
    SurShift    = 400H;

    (* CP_ACP: the system ANSI code page.  A window registered with the A calls
       hands over a byte of it where a Unicode window hands over a code unit, so
       the byte has to be asked about rather than believed. *)
    CP_ACP = 0;

    (* The DLL the kernel calls live in - MultiByteToWideChar, which the A
       window's characters are read with, and the three the console mode needs -
       spelled the way the pragma wants it: a constant and not a keyword,
       uppercased by the compiler, which is the spelling ArchClip uses for its
       own. *)
    KERNEL = "kernel32.dll";

    (* And the DLL the cursor call lives in.  The spelling rule is KERNEL's. *)
    USER = "user32.dll";

VAR
    shiftState: INTEGER;            (* the modifiers, as Events.SetKey wants them *)
    pending: INTEGER;               (* a high surrogate waiting for its low half *)
    wideChars: BOOLEAN;             (* the window was registered with the W calls *)
    mouseOn: BOOLEAN;               (* Open asked the host for its mouse *)
    modeTaken: BOOLEAN;             (* ... and for a console mode bit besides *)
    saveMode: INTEGER;              (* the mode the console had before that *)


PROCEDURE [windows-, KERNEL, ""] MultiByteToWideChar (cp, flags, srcAdr, srcLen,
                                                      dstAdr, dstLen: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GetStdHandle (which: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] GetConsoleMode (h, m: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] SetConsoleMode (h, m: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] ShowCursor (show: INTEGER): INTEGER;


(* The mode with the mouse bit set, which is the one line of this that cannot be
   written the way it reads.  The dialect has no bit operators on integers -
   '&', 'OR' and '~' are for BOOLEAN - so a bit that is a power of two is added
   to a number that does not carry it and the number is left alone when it does;
   dividing by the bit and asking whether the quotient is odd is the test, and it
   is the same one the console body makes of a key's control state.  Adding the
   bit in this way is what HX's own EnableMouseInput does with it, and a whole
   mode is passed on because SetConsoleMode takes a whole mode in any case. *)
PROCEDURE WithMouse (mode: INTEGER): INTEGER;
VAR r: INTEGER;
BEGIN
    IF (mode DIV ENABLE_MOUSE_INPUT) MOD 2 = 0 THEN
        r := mode + ENABLE_MOUSE_INPUT
    ELSE
        r := mode
    END;
    RETURN r
END WithMouse;


(* Ask the console for a mouse and the host for a pointer to it, which together
   are the one thing about a windowed host that is not a message.

   On Windows neither call is needed and neither does harm: a window is sent
   WM_MOUSEMOVE by the system, and the display counter the two move starts at
   zero and is put back where it was, so the pair is inert there.

   Under HX-DOS it is not, and HX's own sources say exactly why.  There the mouse
   reaches a window along a chain that begins at the DOS driver: DUSER32.DLL
   builds WM_MOUSEMOVE and its brothers out of console MOUSE_EVENT records, those
   records come out of a sixty-four entry ring buffer inside DKRNL32, INT 33h
   fills that buffer through an event handler, and the handler is installed by
   DKRNL32's InitMouse.  InitMouse is called from one place, the tail of
   SetConsoleMode, where the test is on the mode that was handed in:

       .if (al & ENABLE_MOUSE_INPUT) invoke InitMouse
       .else invoke DeinitMouse .endif

   That test sits at a label both of SetConsoleMode's paths fall through to, so
   it depends on the argument alone and not at all on the handle being a real
   console.  Nothing in this tree had ever called SetConsoleMode on a window's
   behalf, so the handler was never installed, the buffer stayed empty, and a
   windowed program got no mouse at all.  What made that look like a broken
   pointer rather than a deaf program is that the same chain draws the pointer:
   with no record there is no WM_SETCURSOR either, so the cursor the class asked
   for is never shown.

   The obvious way to ask - DUSER32's ShowCursor, whose own InitMouse is what
   brings up the VESA pointer - is not enough on its own, and the reason for that
   is invisible from here.  That InitMouse calls a private EnableMouseInput, and
   EnableMouseInput guards its SetConsoleMode:

       .if (!(cl & ENABLE_MOUSE_INPUT))
           or cl, ENABLE_MOUSE_INPUT
           invoke SetConsoleMode, ebx, ecx
       .endif

   Read the console mode of a windowed HX process and the bit is already there,
   before the program has made a call of its own - measured, and not a default:
   DKRNL32 starts from ENABLE_PROCESSED_INPUT or ENABLE_LINE_INPUT or
   ENABLE_ECHO_INPUT and nothing else.  That number is kept for the machine and
   not for one process, so what set it was another HX program, and it says
   nothing whatever about whether this one has a handler.  A guard that reads the
   number cannot tell the two apart: it finds the bit set, skips the call, and
   the handler is never installed after all.  Hence the SetConsoleMode below,
   which cannot be skipped - it is handed a mode that carries the bit whenever
   this body asks, and the test is on the argument - and which reaches InitMouse,
   whose own flag is per-process, so what gets made is the handler this program
   was missing.

   So the two calls are wanted for different things.  SetConsoleMode installs the
   handler that fills the buffer; ShowCursor asks DUSER32 for the pointer that
   the buffer's records then move.  On Windows the argument to ShowCursor is a
   BOOL, which is 1 or 0 and not this language's BOOLEAN, and 1 is what shows a
   cursor.

   The console body replaces the console mode with one of its own, because it
   wants the queue read one way and no other.  This body wants a single bit and
   reads no queue at all, so the mode is read back first, one bit is added to it,
   and Close puts the number back as it was found.  The return values are not
   read - a function call is not a statement in this language, so they are taken
   and dropped - and there is nothing that could be done about either failing
   anyway: a host without a console has no mouse to be had, and one without a
   pointer has nothing to draw. *)
PROCEDURE Open*;
VAR n, h: INTEGER;
BEGIN
    h := GetStdHandle(STD_INPUT_HANDLE);
    modeTaken := GetConsoleMode(h, SYSTEM.ADR(saveMode)) # 0;
    IF modeTaken THEN
        n := SetConsoleMode(h, WithMouse(saveMode))
    ELSE
        n := SetConsoleMode(h, ENABLE_MOUSE_INPUT)
    END;
    n := ShowCursor(1);
    mouseOn := TRUE
END Open;


(* Give back what Open took, each only if it was taken, and in the reverse order:
   nothing is drawn from a buffer that is about to stop being filled.

   The console mode goes back as it was found, and the display counter Open moved
   comes back down.  On HX the mode that goes back already carries the mouse bit
   - that is the whole reason Open has to call SetConsoleMode at all - so this
   call reaches InitMouse again rather than DeinitMouse.  InitMouse keeps the
   flag it was guarded by and has nothing left to do the second time, and the
   handler it installed belongs to a process that is about to end; HX's own
   EnableMouseInput leaves the same work to an exit handler rather than to a
   matching call.  What this call does give back is the mode itself, which is
   what a caller that closes and then does something else is owed. *)
PROCEDURE Close*;
VAR n, h: INTEGER;
BEGIN
    IF mouseOn THEN
        n := ShowCursor(0);
        mouseOn := FALSE
    END;
    IF modeTaken THEN
        h := GetStdHandle(STD_INPUT_HANDLE);
        n := SetConsoleMode(h, saveMode);
        modeTaken := FALSE
    END
END Close;


PROCEDURE Poll* (VAR e: Events.Event): BOOLEAN;
BEGIN
    RETURN FALSE
END Poll;


PROCEDURE Idle*;
BEGIN
END Idle;


(* Which kind of window the caller made, said once.

   This is the one fact about a message that the module cannot read out of the
   message, and the only reason it is asked for.  A window registered with the W
   calls is handed the code point the keyboard produced; one registered with the
   A calls is handed a byte of the system code page, and a byte on its own is
   not a character - 0CFH names one in one code page and is undefined in
   another.  So the caller says which it is, once, where it registered the
   class, and every WM_CHAR after that is read the right way.

   A caller that never calls this gets the ANSI reading, which is what a window
   that could not register the wide class has anyway. *)
PROCEDURE WideChars* (on: BOOLEAN);
BEGIN
    wideChars := on;
    pending := 0
END WideChars;


(* Half of a message parameter, as the signed number Windows put there.

   A mouse message carries its x in the low half of lParam and its y in the high
   one, and the two are signed: a mouse captured so that the pointer leaves the
   client area reports a negative coordinate, which read as an unsigned half
   would be 65535 and would put the pointer past the right edge of the screen.
   Oberon's MOD is non-negative, so the halves come out of it as 0 to 65535, and
   anything from 32768 up is what wraps back below zero. *)
PROCEDURE Half (v: INTEGER): INTEGER;
VAR w: INTEGER;
BEGIN
    w := v MOD 65536;
    IF w >= 32768 THEN w := w - 65536 END;
    RETURN w
END Half;


(* The buttons wParam says are down, in the MB_* bits the record uses. *)
PROCEDURE TuiBtns (wParam: INTEGER): INTEGER;
VAR b: INTEGER;
BEGIN
    b := 0;
    IF ODD(wParam DIV MK_LBUTTON) THEN b := b + Events.MB_LEFT END;
    IF ODD(wParam DIV MK_RBUTTON) THEN b := b + Events.MB_RIGHT END;
    IF ODD(wParam DIV MK_MBUTTON) THEN b := b + Events.MB_MIDDLE END;
    RETURN b
END TuiBtns;


(* Set or clear one modifier of shiftState.  The bit is cleared and then set
   rather than added to when the key goes down, because a key held down repeats:
   the message that says it is still down arrives again and again, and a state
   that added to itself at every one of them would climb.  value is the bit's
   weight in the encoding Events.SetKey reads - 1 for shift, 4 for control, 8
   for alt. *)
PROCEDURE Modifier (value: INTEGER; down: BOOLEAN);
VAR was: INTEGER;
BEGIN
    was := shiftState DIV value MOD 2;          (* 0 or 1: was it already set *)
    IF was = 1 THEN shiftState := shiftState - value END;
    IF down THEN shiftState := shiftState + value END
END Modifier;


(* One WM_CHAR, as the event it makes, or FALSE when it makes none.

   This is where the two things that make a code *unit* differ from a code
   *point* are dealt with, and there are exactly two.  A window registered with
   the A calls hands over a byte of the system code page, which has to be asked
   about rather than believed.  A character above the BMP is two UTF-16 code
   units, a high half and a low half, and arrives as two messages: the high one
   is held here until the low one completes it, and a high half that is not
   followed by a low one is dropped, because on its own it is not a character.

   Control characters are dropped as well.  Return and Backspace are not lost by
   that - they arrive as key messages, which is where a consumer reads them, and
   a TEXT for either would be a second report of the same keypress.  A dropped
   character answers FALSE, so a caller has one test to make and not two. *)
PROCEDURE Char (code: INTEGER; VAR e: Events.Event): BOOLEAN;
VAR
    cp: INTEGER;
    b: CHAR;
    w: WCHAR;
    ok: BOOLEAN;
BEGIN
    cp := -1;
    IF ~wideChars THEN
        pending := 0;
        IF (code >= 20H) & (code < 7FH) THEN
            cp := code
        ELSIF (code > 7FH) & (code < 100H) THEN
            b := CHR(code);
            IF MultiByteToWideChar(CP_ACP, 0, SYSTEM.ADR(b), 1,
                                   SYSTEM.ADR(w), 1) = 1 THEN
                cp := ORD(w)
            END
        END
    ELSIF (code >= SurHigh) & (code <= SurHighLast) THEN
        pending := code
    ELSIF (code >= SurLow) & (code <= SurLowLast) THEN
        IF pending # 0 THEN
            cp := SurBase + (pending - SurHigh) * SurShift + (code - SurLow);
            pending := 0
        END
    ELSE
        pending := 0;
        IF (code >= 20H) & (code # 7FH) THEN cp := code END
    END;

    ok := cp >= 0;
    IF ok THEN
        Events.SetText(e, cp)
    END;
    RETURN ok
END Char;


(* One window message, turned into an event if the input layer has one to make
   of it.  TRUE means the message was the input layer's and e is what it said;
   FALSE means it is the caller's to handle.  A message that is the input
   layer's but says nothing worth an event - a wheel that did not reach a whole
   notch - answers FALSE as well, so a caller has one test and not two, and the
   price is that it may act on a message that was not really its own.  For a
   wheel whose delta rounded to zero that is nothing at all.

   The key is read out of lParam and not out of a table.  Bits 16 to 23 of a key
   message are the scan code the keyboard sent, and that code is the same one a
   console and int 16h report - it is the set Events' K_* constants are named in
   - so an arrow arrives as 48H and F2 as 3CH, and a caller that knows K_F2
   knows it here.  The virtual key code in wParam is the key's name on the
   current layout, which is a different thing and the wrong one for this: two
   layouts put two different keys in the same place only by accident, where the
   scancode is the same key on every layout there is.

   The character is not on the key event, because a window is not told it there.
   A key that makes a character makes two messages - the key, and the character
   TranslateMessage derived from it - so a letter arrives as a KEYBOARD event
   followed by a TEXT one, and a key that makes no character sends only the
   first.  A text field reads the TEXT and ignores the KEYBOARD; a widget that
   answers to named keys reads the KEYBOARD and ignores the TEXT.

   A modifier key is reported like any other, and the state it leaves behind
   goes into the event's own flags - so a caller watching the shift flag of each
   event sees it come up when the key goes down and go back down when the key
   comes up, which is the transition it has to act on.

   The event is cleared before the message is looked at, and that is the same
   thing Poll does at its own entry.  Without it a FALSE answer would hand back
   the event before this one - a record that is not empty and not this message,
   which is a trap for any caller that reads the fields before testing the
   answer, and a plain lie for one that logs every message.  FALSE has to mean
   "no event", and that is what it means here. *)
PROCEDURE FromMessage* (msg, wParam, lParam: INTEGER; VAR e: Events.Event): BOOLEAN;
VAR
    scan, x, y, d: INTEGER;
    down, owned: BOOLEAN;
BEGIN
    Events.Clear(e);
    owned := FALSE;

    (* A window that loses the focus loses the modifier state with it.  The
       key-up for a shift held while the user switches away goes to whoever has
       the focus by then and never arrives here, so the bit stays set for the
       rest of the run and every event after it claims a shift that is not down -
       a Ctrl+click that selects a range forever after one Alt+Tab.  The state is
       this module's and the message is not, so it is cleared here and the answer
       is FALSE, which leaves the message to the caller like any other it does
       not own - and a half of a surrogate pair waiting for the other half is
       dropped with it. *)
    IF msg = WM_KILLFOCUS THEN
        shiftState := 0;
        pending := 0
    END;

    IF msg = WM_CHAR THEN
        owned := Char(wParam, e)
    ELSIF msg = WM_MOUSEWHEEL THEN
        (* The delta is the high half of wParam.  The position in lParam is
           where the pointer is on the *screen*, which is not what any other
           mouse message reports, and it is dropped rather than reported as a
           client position that would be wrong by the window's own origin. *)
        d := (wParam DIV 65536) MOD 65536;
        IF d >= 32768 THEN d := d - 65536 END;
        (* The division has to round toward ZERO - what is below one notch is
           dropped - and DIV rounds DOWN, which is the same thing for a delta
           that is not negative and not for one that is: -40 DIV 120 is -1, so a
           driver reporting a fifth of a notch of scroll UP reported a whole
           notch up that nobody turned.  The negation is brought up first. *)
        IF d < 0 THEN
            d := 0 - ((0 - d) DIV WHEEL_DELTA)
        ELSE
            d := d DIV WHEEL_DELTA
        END;
        IF d # 0 THEN
            Events.SetWheel(e, d);
            owned := TRUE
        END
    ELSIF (msg = WM_MOUSEMOVE) OR (msg = WM_LBUTTONDOWN) OR
          (msg = WM_LBUTTONUP) OR (msg = WM_RBUTTONDOWN) OR
          (msg = WM_RBUTTONUP) OR (msg = WM_MBUTTONDOWN) OR
          (msg = WM_MBUTTONUP) THEN
        x := Half(lParam);
        y := Half(lParam DIV 65536);
        Events.SetMouse(e, x, y, TuiBtns(wParam));
        owned := TRUE
    ELSIF (msg = WM_KEYDOWN) OR (msg = WM_SYSKEYDOWN) OR
          (msg = WM_KEYUP) OR (msg = WM_SYSKEYUP) THEN
        down := (msg = WM_KEYDOWN) OR (msg = WM_SYSKEYDOWN);
        IF wParam = VK_SHIFT THEN
            Modifier(1, down)
        ELSIF wParam = VK_CONTROL THEN
            Modifier(4, down)
        ELSIF wParam = VK_MENU THEN
            Modifier(8, down)
        END;
        scan := (lParam DIV 65536) MOD 256;
        IF down THEN
            Events.SetKey(e, scan, 0, shiftState)
        ELSE
            Events.SetKeyUp(e, scan, 0, shiftState)
        END;
        owned := TRUE
    END;
    RETURN owned
END FromMessage;


$END

END ArchInput.
