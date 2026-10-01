MODULE TuiPage;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   Which code page the screen is drawn in, and which one the program's own text
   bytes mean by.

   The framework draws on a canvas of *code points* now, and a host draws bytes
   or wide characters.  So there is a conversion at the host's edge, and it has
   to know what the host is: a Russian DOS box with 866 loaded, a DOSBox left at
   its own default of 437, a Windows console that takes Unicode and needs no
   conversion at all.  That question has exactly one answer per program and it
   lives here, in one variable, so that nothing else in the framework has to
   know the answer or ask it twice.

   TWO SETTINGS, AND WHY THEY ARE TWO.

   Screen is the page the host DRAWS IN - what a code point becomes on its way
   out.  Text is the page the program's own byte strings MEAN - what a byte
   becomes on its way in.  On a DOS box the two are almost always the same
   thing, because the bytes a program is handed (from its keyboard, from a
   file, from its own literals) are the bytes its screen is set to.  They come
   apart in three places and each one is real:

     - a Windows console, whose screen is Unicode and whose bytes are still the
       OEM page it was set to.  Screen = Unicode, Text = 866 there.
     - an article read out of a QuickHelp file, which is 437 whatever the host
       is, so the reader names 437 and not the setting.
     - a screen set to one page while the text came from the other - the whole
       reason the setting exists.

   SCREEN = Unicode means the host takes code points and nothing is converted.
   That is the best case and it is what Windows uses; a byte host set to it
   draws '?' above ASCII, which is honest and is what a console with the wrong
   font shows anyway.

   A page this build does not carry is a legal setting and answers '?' for
   every character.  That is deliberate: the setting can come off a command
   line, and a program that was handed a page name it does not know should draw
   something and say so, not refuse to start.

   THIS MODULE IS THE TWO SETTINGS, AND NOT THE PAGES.

   What a byte of a page is, which byte draws a code point, and how a page is
   named, are Charset's.  That is a table lookup with no screen behind it, and
   a .hlp converter wants it without wanting any of this - so Charset is the
   base and this is built on it.  OfText and ToScreen below are nothing more
   than the two settings applied to Charset's two directions; everything else
   here is which page is in use, and who is allowed to say so.
*)

IMPORT Charset;

VAR
    screen, text: INTEGER;

    (* Whether the program has chosen a page itself, one flag for each setting.
       The host's default is what applies when nothing was asked for - see
       DefaultScreen - so a program that sets a page before it opens the screen
       keeps it. *)
    choseScreen, choseText: BOOLEAN;


(* The page the host draws in. *)
PROCEDURE Screen* (): INTEGER;
VAR p: INTEGER;
BEGIN
    p := screen;
    RETURN p
END Screen;


(* The page the program's text bytes mean by. *)
PROCEDURE Text* (): INTEGER;
VAR p: INTEGER;
BEGIN
    p := text;
    RETURN p
END Text;


PROCEDURE SetScreen* (page: INTEGER);
BEGIN
    screen := page;
    choseScreen := TRUE
END SetScreen;


PROCEDURE SetText* (page: INTEGER);
BEGIN
    text := page;
    choseText := TRUE
END SetText;


(* What a host says its screen is, which is the host's to say: it is the one
   that knows which font is loaded.  A page the program has already chosen
   survives.

   That is what makes a page off a command line possible at all.  The host's
   answer arrives late - in Setup, which runs inside TuiScr.Open - and a
   program that wants another page has nowhere to put its choice before then
   except here, ahead of the open.  So the two are ordered by who spoke first
   and not by who spoke last, and a program that names no page gets the host's,
   which is the right answer when nobody has asked.

   A host that cannot be argued with does not call this at all - it calls
   SetScreen, because a fact about the hardware is not a default.  No host here
   is that: the two that speak are a DOS box, whose font is a setting somebody
   made, and a Windows console, whose screen page is inert - the two procedures
   that carry cells there hand a code point over as it stands and ask no page.
   So both propose, and a program's own answer stands on both. *)
PROCEDURE DefaultScreen* (page: INTEGER);
BEGIN
    IF ~choseScreen THEN screen := page END
END DefaultScreen;


(* The same, for what the program's own byte strings mean.  A host has an
   opinion here too - the bytes a DOS box hands a program are the page its
   keyboard and its files are in - and the program's choice still wins. *)
PROCEDURE DefaultText* (page: INTEGER);
BEGIN
    IF ~choseText THEN text := page END
END DefaultText;


(* The code point of one byte of the program's own text.  Shorthand for the
   call every reader of a byte string makes; the page is the setting above and
   the conversion is Charset's. *)
PROCEDURE OfText* (b: INTEGER): INTEGER;
VAR cp: INTEGER;
BEGIN
    cp := Charset.PointOf(b, text);
    RETURN cp
END OfText;


(* OfText read the other way: the bytes the program's own text uses for one
   character, written into dst at i, with i advanced and the count answered.
   This is what a widget writes when a character arrives from the keyboard and
   has to go into a buffer the page's other readers will read.

   IT IS NOT Charset.Encode, and the difference is the page.  On the UTF-8 page
   the character IS a code point and Encode is the whole of the answer - one, two
   or three bytes.  On a byte page the character is one byte of that page, which
   is what a search buffer has to hold if it is to match the text it is a prefix
   of: Encode would write the UTF-8 of the code point and a 866 buffer holding
   8F for П would never match the two bytes C2 8F.

   WHICH OF THE TWO A CALLER'S INTEGER IS depends on the producer, and the page
   is what says which.  A host with a wide keyboard - a Windows console - reports
   a code point, and every host with one runs on the UTF-8 page: ArchTuiScr
   proposes PageUtf8 there and Page866 on DOS, where the keyboard answers in the
   code page the screen is drawn in and the value is that page's own byte.

   SO THE TEST IS THE VALUE'S SIZE, NOT A LOOKUP.  On a byte page a value that
   fits in a byte IS the byte, and asking the table about it is wrong.  Measured
   2026-10-01: Page866's own table carries code points inside 80H..0BFH - byte
   FFH is the no-break space and byte FDH is the currency sign - so
   ByteOn(0A0H, Page866) answers FFH and ByteOn(0A4H, Page866) answers FDH.  A
   DOS box reports the byte A0H for the letter 'a' and A4H for 'd', so a round
   trip through ByteOn turned a search for either letter into a search for a
   character no keyboard makes, and the search silently found nothing.  Only two
   letters were reachable this way, which is exactly why the first probe missed
   it: the bytes it happened to use, 8EH and 8FH, have no code point in the table
   and fell through to the right answer by accident.

   Above 0FFH the value cannot be a byte of any page, so it is a code point and
   the table is the only thing that can place it.  That is the host which broke
   the pairing - a wide producer on a byte page - and a letter the page does not
   carry is then refused rather than written as something else.

   Answers 0 and writes nothing for a character that is not one, which is what
   an event with no character in it carries.  dst must have room for four bytes
   past i; the caller writes its own terminator. *)
PROCEDURE BytesOf* (cp: INTEGER; VAR dst: ARRAY OF CHAR; VAR i: INTEGER): INTEGER;
VAR p, b, n: INTEGER;
BEGIN
    n := 0;
    IF cp > 0 THEN
        p := text;
        IF p = Charset.PageUtf8 THEN
            n := Charset.Encode(cp, dst, i)
        ELSIF cp <= 0FFH THEN
            (* the byte page's own byte - see the note above on why the table
               must not be asked about it *)
            dst[i] := CHR(cp);
            INC(i);
            n := 1
        ELSE
            b := Charset.ByteOn(cp, p);
            IF b > 0 THEN
                dst[i] := CHR(b);
                INC(i);
                n := 1
            END
        END
    END;
    RETURN n
END BytesOf;


(* The byte the host draws this code point as, which is the whole of the way
   out for a host that is not wide. *)
PROCEDURE ToScreen* (cp: INTEGER): INTEGER;
VAR b: INTEGER;
BEGIN
    b := Charset.ByteOn(cp, screen);
    RETURN b
END ToScreen;


BEGIN
    (* The framework's own page: 866 is what a Russian DOS box is set to and
       what the Windows console is put into, and it is also the page the dump
       format is written in.  A host that is something else says so in
       TuiScr.Open, which is the only place that knows what the host is. *)
    screen := Charset.Page866;
    text := Charset.Page866
END TuiPage.
