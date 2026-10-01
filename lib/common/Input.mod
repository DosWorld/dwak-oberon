MODULE Input;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The one module a program reads its keyboard and its mouse from.

   Nothing here knows what a device is.  The reading belongs to the host and
   lives in lib/<arch>/ArchInput.mod - one body for a DOS machine, two for
   Windows, an empty one where there is no keyboard to read - and this module is
   the name in front of it, so that a program says `IMPORT Input` and is written
   once for every host.  That is the arrangement Files and ArchFile keep, and
   the reason is the same: a program that named the host's module directly would
   have to be edited, and edited differently, for every host there is.

   The event is Events', and it is the same record whichever body filled it.
   What a program has to know about its host is therefore in Events and not
   here: a console is polled and a window is pushed to, so Poll answers FALSE on
   a window and FromMessage answers FALSE on a console, and a program that draws
   text calls one of them and a program that draws a window calls the other.

   Idle is the loop's, and it is what makes a program that is waiting cost
   nothing: it waits for the host to have something to read and returns when it
   has, or when waiting any longer would be wrong.  A caller that has work to do
   anyway - a clock, an animation - simply does not call it.

   Open and Close are the book-ends and not a reading: Open takes the host's
   devices and Close gives them back.  On most hosts there is nothing to take -
   a window under a real window manager has its keyboard and its mouse already,
   and an empty pair is the honest body there - but the pair is where a host
   whose devices arrive only when they are asked for asks, and it is not
   decoration.  Under HX-DOS, for one, a windowed program has no mouse at all
   until its input layer asks the console for one, because HX builds a window's
   mouse messages out of console records that only exist once a console mode
   bit has been set; the console body has always set it, which is why the
   console host's mouse works there and the windowed one's did not.  So a body
   that leaves this pair empty has said something about its host, and a host
   that has to be asked belongs in them.  A caller calls both exactly once,
   around everything else it does.

   There is one thing this module deliberately does not do, and it is worth
   saying because it reads as an omission.  Whether a mouse event is worth
   reporting is decided in the body and not here: a console's queue is polled,
   and a pointer that has not moved would be reported again at every poll - a
   frame redrawn for nothing - while a window's messages are pushed and every
   one of them is a real event that must not be dropped.  So the comparison
   against the last position lives with the transport that needs it, and not in
   the layer both transports share. *)

IMPORT ArchInput, Events;


PROCEDURE Open*;
BEGIN
    ArchInput.Open
END Open;


PROCEDURE Close*;
BEGIN
    ArchInput.Close
END Close;


PROCEDURE Poll* (VAR e: Events.Event): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := ArchInput.Poll(e);
    RETURN r
END Poll;


(* A message the host's window procedure received, if this host has one.

   The entry is here on every host and not only on the one that has a message
   loop, because a caller is written once: a console answers FALSE to every
   message and is never given one, and a window answers FALSE to every message
   that is not the input layer's and hands those back to its own window
   procedure.  A caller therefore asks the same question on both and acts on the
   answer in the same way.

   The three parameters are the message and its two words as the window
   procedure received them - msg, wParam and lParam - and nothing here reads
   them: what they mean is the host's business, and this is the one entry whose
   parameters a portable caller cannot have an opinion about. *)
PROCEDURE FromMessage* (msg, wParam, lParam: INTEGER; VAR e: Events.Event): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := ArchInput.FromMessage(msg, wParam, lParam, e);
    RETURN r
END FromMessage;


(* Which kind of window the caller made, said once - the W calls or the A ones.

   This is the one fact about a message that cannot be read out of the message,
   and the only reason the layer has to be told anything about the window it is
   reading.  A window registered with the W calls is handed the code point the
   keyboard produced; one registered with the A calls is handed a byte of the
   system code page, and a byte is not a character - so a caller says which it
   is where it registered the class, and every character after that is read the
   right way.

   It is here on every host for the reason FromMessage is: a caller is written
   once.  A console has no window and no two ways of reading a character, and
   its body does nothing with this.

   A caller that never calls it gets the ANSI reading, which is what a window
   that could not register the wide class has anyway. *)
PROCEDURE WideChars* (on: BOOLEAN);
BEGIN
    ArchInput.WideChars(on)
END WideChars;


PROCEDURE Idle*;
BEGIN
    ArchInput.Idle
END Idle;

END Input.
