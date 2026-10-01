MODULE TuiApp;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The interactive session: the screen, the keyboard, and the loop that joins
   them to a desktop.

   Tui knows neither a screen nor an input.  It is handed events and it draws
   into a canvas, and that is exactly what keeps it testable - a program can
   drive the same desktop with no screen at all and dump the canvas it drew,
   which is what the tui sample's `canvas` argument does.  What is left over is
   the pump, and the pump has to live somewhere that may name both a screen and
   an input, so it lives here and nowhere else.

   An application that uses this module names neither TuiScr nor Input:

       TuiApp.Open(0, 0);
       MyForm.Build(TuiApp.Cols(), TuiApp.Rows());
       TuiApp.Present;
       TuiApp.Run(MyForm.Step);
       TuiApp.Close

   Run takes a procedure and not an object because the language has no
   closures.  The step is a module-level procedure of the application - it is
   the application that keeps the state the turn is about - and it answers
   whether the application has finished.  Everything the pump does around that
   turn is the same for every application, so it is written once, here.

   Nothing in this file draws, decides or knows what an application is.  It is
   the smallest module that can hold the four things the two entries used to
   spell out twice: the size the screen answered with, the frame after every
   turn, the resize before the turn that would be drawn at the wrong size
   without it, and the idle that keeps the loop from spinning.

   The one thing here that is not a pump is the code page the screen is drawn
   in, and it is here for the same reason: a program has to be able to say which
   font its host has loaded, and this is the only place that opens a screen.
   It comes off the command line - `-cp 866` - and Page says how.
*)


IMPORT Args, Charset, TuiPage, Events, Input, TuiScr, Strings, Tui;

(* What one turn of an application is.

   The answer is what ends the session - TRUE when the application is done - so
   an application does not have to publish a flag of its own for the loop to
   read.  The frame is presented whichever way the answer goes: the last turn of
   a session draws like every other, and the screen on the way out is the screen
   the last event made. *)
TYPE StepProc* = PROCEDURE (VAR e: Events.Event): BOOLEAN;

(* Where the code page the screen is drawn in comes from.

   This is the framework's one piece of configuration, and it is read here
   because this is the one procedure that opens a screen: a program that uses
   TuiApp is told which page to draw in without ever hearing that a page layer
   exists, and one that uses TuiScr directly sets the page itself.

   The setting is a command-line option - `-cp` and then a page name - and it
   may stand anywhere on the line, so that it does not have to be counted past
   whatever arguments the application has of its own:

       Demo selftest -cp 866

   The names are Charset.ByName's: 437, 866 and unicode, each with the few
   spellings that procedure knows.  An option this does not recognise, and no
   option at all, leaves the host's own answer standing - which is the right
   answer when nobody has asked, and is supplied by ArchTuiScr.Setup inside
   TuiScr.Open, one call further down.

   That is why the page is set *before* the screen is opened rather than after.
   Both orders would work for a host that reads the setting once, and only one
   works for a host that reads it at the open, which is what every host here
   does.  TuiPage.DefaultScreen and TuiPage.DefaultText are the other half of
   the arrangement: the host's answer fills in only what the program has not
   already chosen, so a page set here survives the open and a page not named
   here is not overridden by anything.

   ONE NAME SETS BOTH SETTINGS, and that is why the option names a page rather
   than a screen.  TuiPage keeps the screen's page and the text's page apart
   because a Windows console really is two - it draws code points and reads
   bytes - but that is a fact about a console and not about the machine a user
   is describing when they type `-cp 866`.  What they are saying is "this box is
   a Russian DOS box": its font is 866 and so are the bytes its keyboard and its
   files hand the program.  So both are set, and the two come apart exactly
   where the host says they do and not where the option does. *)
PROCEDURE Page (): INTEGER;
VAR i, p: INTEGER; a: ARRAY 32 OF CHAR;
BEGIN
    p := -1;
    i := 1;
    WHILE (i < Args.argc) & (p < 0) DO
        Args.GetArg(i, a);
        IF Strings.Equal(a, "-cp") & (i + 1 < Args.argc) THEN
            Args.GetArg(i + 1, a);
            p := Charset.ByName(a)
        END;
        INC(i)
    END;

    RETURN p
END Page;


(* Ask the screen for a size and open the keyboard.

   A size of 0, 0 asks for none at all, which is how a screen is told "what you
   have is what you get": under DOS that is the video mode, and on a console it
   is the window the program was started in.  Asking for a size would move a
   window the user had put where they wanted it - so an interactive run passes
   zeros, and a self-test passes the size its dumps were taken at, which is what
   makes every run of it the same shape and its dumps comparable. *)
PROCEDURE Open* (cols, rows: INTEGER);
VAR p: INTEGER;
BEGIN
    p := Page();
    IF p >= 0 THEN
        TuiPage.SetScreen(p);
        TuiPage.SetText(p)
    END;
    TuiScr.Open(cols, rows);
    Input.Open
END Open;

(* The size the screen answered with, which is what an application builds to.

   It is the screen's answer and not the request, and the difference is real: a
   console buffer cannot be smaller than the window and a window that refuses to
   grow keeps its size, so a program that built to what it asked for would build
   past the edge of what it got. *)
PROCEDURE Cols* (): INTEGER;
BEGIN
    RETURN TuiScr.Cols()
END Cols;


PROCEDURE Rows* (): INTEGER;
BEGIN
    RETURN TuiScr.Rows()
END Rows;

(* Put the desktop on the screen.

   The pump calls it after every turn; an application calls it once itself, to
   get the interface up before the first event - otherwise the session would
   open on a blank screen and the first key would be typed at nothing. *)
PROCEDURE Present*;
BEGIN
    TuiScr.Present(Tui.Desk())
END Present;

(* The screen as it stands, written to a file.

   Reading the screen back is the only way to prove what reached it: the canvas
   says what was drawn and not what was shown, and the two are the same only if
   the blit, the attributes and the code page all agreed.  It is the screen
   layer that can be asked, so an application that wants the proof asks here. *)
PROCEDURE Dump* (name: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN TuiScr.Dump(name)
END Dump;

(* The loop.

   Poll, and on an event: the resize first, because the frame this event makes
   is composed at the new size and a resize applied after the turn would be
   drawn at the old one; then the turn; then the frame.  The order is the whole
   of the routine and it is the order both entries had written out by hand.

   With no event the loop idles rather than spins, which is what the input layer
   is for: a console waits there, and under DOS it is where the machine is given
   back to the system between keys.  An idle that did nothing would be a busy
   loop and this one is not. *)
PROCEDURE Run* (step: StepProc);
VAR e: Events.Event; quit: BOOLEAN;
BEGIN
    quit := FALSE;
    WHILE ~quit DO
        IF Input.Poll(e) THEN
            IF e.kind = Events.RESIZE THEN
                TuiScr.Resize;
                Tui.Resize(TuiScr.Cols(), TuiScr.Rows())
            END;
            quit := step(e);
            TuiScr.Present(Tui.Desk())
        ELSE
            Input.Idle
        END
    END
END Run;

(* Give the keyboard and the screen back, in the order they were taken. *)
PROCEDURE Close*;
BEGIN
    Input.Close;
    TuiScr.Close
END Close;

END TuiApp.
