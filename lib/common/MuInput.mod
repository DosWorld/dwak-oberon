MODULE MuInput;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   What an event means to microui.

   lib/common/Events.mod is the one vocabulary of input in this tree and
   lib/common/Input.mod is the one way in - the keyboard, the mouse and the
   clipboard, read once, for every interface that agrees to speak the record.
   This is the other end of it: the same vocabulary read by the library on the
   far side, so that a host whose loop feeds microui has one call in its input
   path and no translation of its own.

   The host keeps everything it had.  Its message loop, its window procedure,
   the moment it peeks and the moment it waits, and which messages it handles
   itself are all its own; what moves out is the *meaning* of a message, which
   is the part two hosts would otherwise write twice and then disagree about -
   which scancode is which key, what a button message is saying, how many bytes
   a typed character occupies.

   Three of the four kinds of event are a translation and the fourth is not.
   A WHEEL and a TEXT already say what they mean and need only to be put into
   the library's units.  A MOUSE does not: a window reports the button state as
   it *is*, and microui wants the moment it *changed*, so the two sets are
   compared and the difference is what is sent - a bit that is down now and was
   not is a press, one that was down and is not is a release, and a report that
   changed nothing is a move.  That comparison needs the button state of the
   event before this one, which is what Events.SetMouse records and what a host
   translating a message on its own has no way to know.

   A KEYBOARD that names no key microui knows - F2, F3, Escape, Tab, Space and
   the rest - is *not* taken: Route answers FALSE for it, and the host is free
   to act on it.  That is deliberate and it is the one place the host's own
   keys stay its own; a host that swallowed every key here could not bind a
   function key at all, because microui would only ever see an unknown key
   pressed.

   Text is UTF-8, because that is what microui's buffers and this library's
   renderer are.  An event carries a code point - that is what a window
   produces, and a window is the only producer that sends a TEXT - so the
   encoding from a code point to UTF-8 is here, once, for every host.

   Nothing here is a pump and nothing here touches a loop.  Route is called
   from inside a window procedure, with an event already in hand, and returns
   before anything else happens. *)

IMPORT Events, MuBase, Microui, Charset;

CONST

    (* One notch of a wheel, in the units microui's scroll takes.

       A notch is what a wheel reports and a scroll step is what the library
       works in, and they are not the same number: one notch is three steps,
       and away from the user is negative because the library's y grows
       downwards.  Events.wheel is already in whole notches - the body that
       reads a wheel message divides by the 120 a notch is - so this is the
       only conversion left to make. *)
    WheelAway = -30;

    (* The widest a character can be: four bytes of UTF-8 and the terminator
       nothing in this library is handed without. *)
    TextMax = 5;


(* The microui key bit a scancode stands for, or 0 for a key microui has no
   name for.

   The match is on the scancode and not on the character, for the reason the
   K_* constants give: a Ctrl+letter arrives with the letter's own control code
   where the character would be, so Ctrl+S and Ctrl+Shift+S and the two layouts
   that put S in two places all have to be told apart by the key and not by
   what it typed.

   Shift, control and alt are reported as themselves, exactly as the
   framework's own hosts report them, so a consumer watching for a control
   letter tests for the letter's bit and the control bit together.  The two
   shifts share the one bit microui has for them.

   What is not here is as deliberate as what is: no function key, no Escape,
   no Tab and no Space has a microui name, so nothing is invented for them and
   the host that wants one binds it itself. *)
PROCEDURE KeyBit (scan: INTEGER): INTEGER;
VAR res: INTEGER;
BEGIN
    IF scan = Events.K_BACK THEN
        res := MuBase.KeyBackspace
    ELSIF scan = Events.K_ENTER THEN
        res := MuBase.KeyReturn
    ELSIF (scan = Events.K_SHIFT) OR (scan = Events.K_SHIFT_R) THEN
        res := MuBase.KeyShift
    ELSIF scan = Events.K_CTRL THEN
        res := MuBase.KeyCtrl
    ELSIF scan = Events.K_ALT THEN
        res := MuBase.KeyAlt
    ELSIF scan = Events.K_LEFT THEN
        res := MuBase.KeyLeft
    ELSIF scan = Events.K_RIGHT THEN
        res := MuBase.KeyRight
    ELSIF scan = Events.K_UP THEN
        res := MuBase.KeyUp
    ELSIF scan = Events.K_DOWN THEN
        res := MuBase.KeyDown
    ELSIF scan = Events.K_DEL THEN
        res := MuBase.KeyDelete
    ELSIF scan = Events.K_HOME THEN
        res := MuBase.KeyHome
    ELSIF scan = Events.K_END THEN
        res := MuBase.KeyEnd
    ELSIF scan = Events.K_A THEN
        res := MuBase.KeyA
    ELSIF scan = Events.K_C THEN
        res := MuBase.KeyC
    ELSIF scan = Events.K_E THEN
        res := MuBase.KeyE
    ELSIF scan = Events.K_N THEN
        res := MuBase.KeyN
    ELSIF scan = Events.K_O THEN
        res := MuBase.KeyO
    ELSIF scan = Events.K_S THEN
        res := MuBase.KeyS
    ELSIF scan = Events.K_V THEN
        res := MuBase.KeyV
    ELSIF scan = Events.K_X THEN
        res := MuBase.KeyX
    ELSIF scan = Events.K_Y THEN
        res := MuBase.KeyY
    ELSIF scan = Events.K_Z THEN
        res := MuBase.KeyZ
    ELSE
        res := 0
    END;

    RETURN res
END KeyBit;


(* One code point as UTF-8, and how many bytes it took.

   The caller terminates the string; this writes at most four bytes and never
   touches s beyond them.  A value that is not a character is written as
   nothing at all and answers zero, which is what a caller tests: there is no
   encoding for it and a replacement character would be a character the user
   did not type.  Two kinds of value are not characters, and both are refused
   here rather than written - a surrogate half, which is one end of a pair and
   not a character on its own, and anything above U+10FFFF, which is past the
   end of Unicode however well the arithmetic happens to work out.  The
   encoding's own four ranges cover 21 bits and Unicode uses 21 bits' worth
   minus that last plane and a half, so the last range is closed at the
   standard's end and not at the arithmetic's.

   The four ranges are the encoding's own, and the arithmetic is what makes
   UTF-8 self-synchronising - a lead byte says how many followed it, which is
   why a renderer can walk a string it was handed in the middle and a textbox
   can step back over a continuation byte it did not write.

   It is exported because it is the half of Route that has nothing to do with
   microui: a host with a code point in hand and a UTF-8 buffer to fill - a
   window title, a file name in a dialog - needs exactly this and nothing
   else.

   THE ARITHMETIC MOVED 2026-10-01, and this is now a wrapper.  The four ranges
   above used to be written out here, and the same four were written out twice
   more elsewhere in the tree - Cp437.Emit and Files.EmitUtf8, both private, and
   this one public.  None of the three was about its own caller: encoding a code
   point is a fact about UTF-8, so it went to the module that owns the code
   pages, as Charset.Encode(cp, dst, i) - the same four ranges, with the index a
   variable instead of a constant zero.  This procedure is that call with the
   index fixed at nought, and it keeps its name and its signature because it is
   what a host calls and because the ranges are worth stating where a reader of
   microui will meet them.

   Nothing about its behaviour changed, and that is checkable rather than
   asserted: the two branch lists are the same branch list, in the same order,
   so the byte counts and the refusals agree on every input.  A caller that
   wants to append - several characters into one buffer - should call
   Charset.Encode directly and keep the index itself; this one always writes at
   s[0] and is for the one-character-at-a-time caller it was written for. *)
PROCEDURE Utf8* (cp: INTEGER; VAR s: ARRAY OF CHAR): INTEGER;
VAR i, n: INTEGER;
BEGIN
    i := 0;
    n := Charset.Encode(cp, s, i);

    RETURN n
END Utf8;


(* One mouse event into the context.

   The two sets are compared and only the difference is sent.  A button that
   went down and a button that came up are separate calls in microui, and the
   releases are made before the presses: an event that changed two bits at once
   is a chord, and a context told about the press first would hold both buttons
   for the length of one call.

   A report that changed nothing is a move, and it is sent every time - microui
   re-reads the pointer each frame and a host that skipped the still reports
   would leave a click that never moved the mouse with no position at all.  The
   console body is the one that drops unchanged reports, before they become
   events, so nothing here has to know which host it is under.

   The pointer is in the producer's unit, which is a pixel for every host that
   has a microui window; the library is told the number it was given. *)
PROCEDURE Mouse (ctx: Microui.Context; VAR e: Events.Event);
VAR up, down: INTEGER;
BEGIN
    up := ORD(BITS(e.prev) - BITS(e.buttons));
    down := ORD(BITS(e.buttons) - BITS(e.prev));
    IF (up = 0) & (down = 0) THEN
        Microui.InputMouseMove(ctx, e.x, e.y)
    ELSE
        IF ODD(up DIV MuBase.MouseLeft) THEN
            Microui.InputMouseUp(ctx, e.x, e.y, MuBase.MouseLeft)
        END;
        IF ODD(up DIV MuBase.MouseRight) THEN
            Microui.InputMouseUp(ctx, e.x, e.y, MuBase.MouseRight)
        END;
        IF ODD(up DIV MuBase.MouseMiddle) THEN
            Microui.InputMouseUp(ctx, e.x, e.y, MuBase.MouseMiddle)
        END;
        IF ODD(down DIV MuBase.MouseLeft) THEN
            Microui.InputMouseDown(ctx, e.x, e.y, MuBase.MouseLeft)
        END;
        IF ODD(down DIV MuBase.MouseRight) THEN
            Microui.InputMouseDown(ctx, e.x, e.y, MuBase.MouseRight)
        END;
        IF ODD(down DIV MuBase.MouseMiddle) THEN
            Microui.InputMouseDown(ctx, e.x, e.y, MuBase.MouseMiddle)
        END
    END
END Mouse;


(* One event into the context.  TRUE when microui was told about it.

   FALSE is not a failure: it means the event was not the library's, and there
   are three ways that happens.  A kind it has no input for - RESIZE, which is
   the host's own business, and NONE, which is what a widget leaves behind when
   it takes an event.  A key with no microui name, which the host is then free
   to bind.  And a character that did not arrive whole - a lone surrogate half,
   or one no encoding exists for - which is dropped rather than guessed at.

   An event this takes is the caller's no longer, and a host that follows the
   framework's convention for that will clear it; the library has no way to say
   so itself, so a caller that wants the event consumed does it as it does for
   every other consumer of the record. *)
PROCEDURE Route* (ctx: Microui.Context; VAR e: Events.Event): BOOLEAN;
VAR
    k, n: INTEGER;
    s: ARRAY TextMax OF CHAR;
    hit: BOOLEAN;
BEGIN
    hit := TRUE;
    IF e.kind = Events.MOUSE THEN
        Mouse(ctx, e)
    ELSIF e.kind = Events.WHEEL THEN
        hit := e.wheel # 0;
        IF hit THEN
            Microui.InputScroll(ctx, 0, e.wheel * WheelAway)
        END
    ELSIF (e.kind = Events.KEYBOARD) OR (e.kind = Events.KEYUP) THEN
        k := KeyBit(e.scan);
        hit := k # 0;
        IF hit THEN
            IF e.kind = Events.KEYBOARD THEN
                Microui.InputKeyDown(ctx, k)
            ELSE
                Microui.InputKeyUp(ctx, k)
            END
        END
    ELSIF e.kind = Events.TEXT THEN
        n := Utf8(e.ch, s);
        hit := n # 0;
        IF hit THEN
            s[n] := 0X;
            Microui.InputText(ctx, s)
        END
    ELSE
        hit := FALSE
    END;

    RETURN hit
END Route;

END MuInput.
