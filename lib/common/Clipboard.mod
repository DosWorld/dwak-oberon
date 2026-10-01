MODULE Clipboard;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The clipboard the four keys use: one mechanism for the life of the program,
   never both - and the second of the two only where it can be needed.

   There are two places text can be.  One is the clipboard of the machine, which
   every program on it shares; the other is a buffer of this module's own, which
   reaches no further than this process.  Only one target has the buffer, and
   what decides that is the target and not a preference.

   DPMI32.  A DOS program has no clipboard call of its own, and whether the host
   offers the services that stand in for one cannot be known before the program
   runs.  So here, and only here, the choice is made at run time: ArchClip is
   asked once, the answer is remembered, and the buffer is what answers when the
   answer is no.  A host without the calls and a host with them are both ordinary
   cases, and neither is an error.

   Every other target.  The platform is asked and its answer is the answer -
   TRUE where it has a clipboard, FALSE where it has not - and there is no
   buffer, because a buffer here would be inventing a clipboard out of a module
   variable and calling it the machine's.  A target whose ArchClip reports no
   clipboard therefore has no clipboard: the four keys do nothing there, which
   is exactly what that platform is saying, and it stays true until somebody
   writes the ArchClip that host deserves.  Windows, whose ArchClip answers TRUE,
   is what this module is for; a host with no clipboard of its own is not
   pretended otherwise.

   So the rule the arrangement keeps on every target is the same - one mechanism
   per program, and never both - and on every target but one it is a fact of the
   source rather than of the run.

   Two other arrangements were tried and neither was right, which is recorded
   here so that neither is reached for again.

   The first read the buffer and only then the system clipboard.  That makes text
   copied in another program unreachable for the rest of the session: the buffer
   is never empty again once the program has copied anything, so the system
   clipboard is never consulted, and the one thing the buffer cannot do -
   receive what somebody copied elsewhere - is the whole reason to have a system
   clipboard at all.

   The second read the system clipboard and fell back to the buffer when it held
   nothing.  On a platform that has a clipboard that is a shadow copy nothing
   ever reads: every paste is answered by the system, and the buffer is written
   by every copy and read by none.  It also gives a paste two meanings decided by
   which of the two happens to be empty, so an empty clipboard pastes the last
   thing this program copied - and an empty clipboard does not mean that on any
   machine.

   So a platform with a clipboard uses it and nothing else, exactly as every
   other program on that machine does, and a copy followed by a paste gives back
   what was copied because a copy writes the system clipboard and a paste reads
   it.  A paste that finds no text there pastes nothing, which is what an empty
   clipboard means everywhere else.  The one platform that may have no clipboard
   at all gets the buffer, which is all it can have.  Nothing is mixed and
   nothing falls back, and the buffer is not named on the path a platform with a
   clipboard takes.

   MAXCLIP is the buffer's size and stays the ceiling for the widgets built on
   this module: a single line field holds 255 characters, and a text area's
   paste is cut to the same number.  That is a ceiling and not a rule - a longer
   block from outside is cut rather than refused.  Nothing here is allocated:
   the buffer is module storage, which is what keeps the invariant that no frame
   allocates.

   The text this module carries is UTF-8, on every target, and that is a
   contract and not a coincidence.  A clipboard is Unicode - on Windows it is
   UTF-16 behind this very edge, which is what ArchClip hands it to and takes it
   back from - and the one encoding every platform layer here can meet is that
   one.  So a caller holding Unicode, which on this machine means a microui
   textbox, calls Put and Get and nothing else, and a caller whose text is the
   screen's own code page calls PutScreen and GetScreen, which are the same two
   calls with the conversion made on the way in and on the way out.  See Cp437.

   What that replaced: Put and Get once carried bytes with no encoding at all
   and the layers below read them as they pleased, so the Tui's code page 437
   met a Windows edge that decoded UTF-8 and a 0FEH - which is not a byte of
   any UTF-8 sequence - arrived at the machine as U+00FE.  An encoding
   has to be named somewhere; naming it here is what lets the two callers above
   differ without either of them knowing what the platform under it is. *)

$IF (DPMI32)
IMPORT ArchClip, Cp437, Strings;
$ELSE
IMPORT ArchClip, Cp437;
$END

CONST
    MAXCLIP* = 256;                 (* bytes the framework's copy takes, its 0X
                                       included; the ceiling the widgets above
                                       read, on every target, whether or not
                                       there is a buffer here to hold it *)

    (* The room a copy of the screen's own text takes once it is UTF-8.  The
       worst case is three bytes a character: everything in code page 437 that
       is drawn rather than typed - the box-drawing set, the blocks, the filled-square bullet
       QuickBasic writes its articles with - is a three-byte one, and only the
       accented Latin and the Greek are two.  MAXCLIP is the ceiling on the
       characters, so the room is that three times over plus the terminator.
       One buffer serves both directions: a copy and a paste are never in
       flight together and nothing here is reentrant. *)
    SCRLEN = 3 * MAXCLIP + 1;

$IF (DPMI32)
VAR
    scr: ARRAY SCRLEN OF CHAR;      (* what the screen's text becomes, and what
                                       the clipboard becomes on the way back -
                                       the one buffer PutScreen and GetScreen
                                       need between them *)
    buf: ARRAY MAXCLIP OF CHAR;     (* written and read only where the host has
                                       no clipboard calls to give *)
    known, system: BOOLEAN;         (* the platform was asked, and what it said *)
    ok: BOOLEAN;                    (* what the platform answered the last call;
                                       nothing above this module asks, and the
                                       name is here because a function cannot be
                                       called as a statement *)
$ELSE
VAR
    scr: ARRAY SCRLEN OF CHAR;      (* the same buffer, and the only storage
                                       this half has besides it *)
    ok: BOOLEAN;                    (* the same, and the only state there is:
                                       there is nothing else here to remember *)
$END


(* Whether this process has the clipboard of the machine.

   A program may ask this to say which it got, and that is worth saying: text
   copied where there is a system clipboard can be pasted into any other program,
   and text copied into the buffer can be pasted back here and nowhere else.
   Nothing in this tree asks today.

   The system clipboard is the wider of the two and not an unlimited one.  What
   a platform's layer can carry is that platform's to say, and one of them says
   little: lib/dpmi32/ArchClip.mod records the measurement, and outside ASCII a
   dpmi32 program copies and pastes nothing that survives.  That is a limit of
   the host under the DOS target and not of this arrangement - the arrangement
   is what makes the text reach the host at all. *)
PROCEDURE System* (): BOOLEAN;
BEGIN
$IF (DPMI32)
    (* Asked of the platform the first time anything here needs to know and not
       before, because on this target the answer costs an interrupt and a program
       that never copies anything should never pay for one.  The answer cannot
       change while the program runs. *)
    IF ~known THEN
        known := TRUE;
        system := ArchClip.Available()
    END;

    RETURN system
$ELSE
    (* The platform's answer is the answer, and it is the same one every time:
       Windows always has a clipboard, and a host that has not been given one
       yet always has not. *)
    RETURN ArchClip.Available()
$END
END System;


(* s into the clipboard - the machine's where there is one, this module's buffer
   where the host under the DOS target has no calls to give.

   Where the text went decides what happens when it does not fit: the buffer is
   MAXCLIP bytes and a longer copy is cut to it, while the machine's clipboard is
   asked for what the platform layer can carry and answers for itself. *)
PROCEDURE Put* (s: ARRAY OF CHAR);
BEGIN
$IF (DPMI32)
    IF System() THEN
        ok := ArchClip.Put(s)
    ELSE
        Strings.Copy(s, buf)
    END
$ELSE
    ok := ArchClip.Put(s)
$END
END Put;


(* A paste into s, from the same place the copy went.

   A system implementation clears s before it fills it, so a paste that finds
   nothing on that clipboard leaves an empty string rather than the last one -
   which is the answer an empty clipboard has to give, and it is given on the
   system path alone: where the host has no calls, the buffer answers instead,
   and it always holds the last thing this program copied. *)
PROCEDURE Get* (VAR s: ARRAY OF CHAR);
BEGIN
$IF (DPMI32)
    IF System() THEN
        ok := ArchClip.Get(s)
    ELSE
        Strings.Copy(buf, s)
    END
$ELSE
    ok := ArchClip.Get(s)
$END
END Get;


(* A copy from a widget whose text is the screen's own bytes.

   Put above takes UTF-8 and a canvas holds code page 437, so a Tui widget is
   not a caller of Put and this is what it calls instead.  The conversion is the
   whole difference between the two, and it is made here and only here: the
   platform layers below never see one, because they are handed UTF-8 either
   way, and a widget that holds Unicode does not pay for a conversion it does
   not need.

   The copy is cut at what scr holds, which is three times MAXCLIP characters'
   worth of bytes - so everything a widget built on this module can hold goes,
   and a caller with a longer buffer of its own loses the tail.  That is the
   same ceiling Put already documents for the buffer it keeps on the DOS target,
   and it is a cut and not a refusal. *)
PROCEDURE PutScreen* (s: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
    n := Cp437.ToUtf8(s, scr);
    IF n > 0 THEN
        Put(scr)
    END
END PutScreen;


(* A paste into a widget that draws the screen's code page.

   The character count survives and not the characters: a code point the code
   page has not got becomes one '?', in its place, so everything after it lands
   where the machine's clipboard had it.  A caller that pasted a web page into a
   console widget shows a row of question marks, which is what the console has
   always shown for what it cannot draw. *)
PROCEDURE GetScreen* (VAR s: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
    Get(scr);
    (* The count is the answer to a question nothing here asks - how much text
       came across - and it is read into a name only because a function cannot
       be called as a statement. *)
    n := Cp437.FromUtf8(scr, s)
END GetScreen;

END Clipboard.
