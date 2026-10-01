MODULE TuiScr;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The screen the interface is put on.

   Two things are portable about it and both are here.  The first is the blit:
   a canvas goes out row by row, and a canvas cell is a code point and then its
   attribute, four bytes, so a row of cells is a run of bytes and nothing has to
   be told the colour of every cell separately.

   The second is that a frame is a bulk copy a row, and how much more than that
   it is depends on the host.  A row of the canvas is copied out into a row
   buffer and handed to the target as an address.  Four bytes a cell is exactly
   what a Windows console cell is - CHAR_INFO is a 16-bit character and a 16-bit
   attribute, in that order - so there the row goes where it belongs in one
   WriteConsoleOutputW and costs nothing but the copy.  A DOS text screen holds
   two bytes a cell and holds a *byte* for the character, so a row has to be
   converted on its way out, a cell at a time, into the code page the screen is
   set to; that is the DOS body's business, it is what ArchTuiScr exists for,
   and TuiPage says what a code point becomes there.  Either way the framework
   above this module costs one row copy a row and never looks at a cell.

   Writing only the cells that differ from what is already on the screen was
   tried, measured and removed, and it is worth saying why, because the idea is
   the obvious one.  A difference has to be found by reading both copies a cell
   at a time, and a cell read that way - two loads and a comparison, in the
   cheapest form the dialect allows, with the rows in single-block buffers so
   that a cell is one instruction - costs about twenty-five emulated cycles.
   The write it saves costs nothing to save: under DOSBox-X, putting all four
   thousand cells of an eighty by twenty-five screen on the screen takes no
   measurable time at all (0.00 s over two hundred frames), because the
   emulated adapter's memory is ordinary RAM.  Two hundred frames of a canvas
   with one cell changing cost 6.05 s with the difference and 4.03 s without
   it, and the difference costs the same whether one cell changed or forty: it
   is the comparison, and the comparison is proportional to the screen, not to
   what changed.  So a difference pays only where the sink is slow enough for
   the writing to be worth avoiding - a serial terminal, a remote display - and
   neither target of this framework is one.  A frame writes the whole screen.
   README.md, "Drawing, and what a frame costs", has the numbers and the probes
   that produced them, both of which are kept outside the repository.

   Dump reads the screen back and lets TuiCanv write it out, so what the demo
   compares after a run is the screen and not the canvas it meant to put there.
   The dump is not a difference and never was: that is what keeps the two
   comparable. *)

IMPORT ArchTuiScr, ByteArr, TuiCanv;

CONST
    (* The widest screen this module will take, and it is the application's
       request that is cut down rather than the screen: a row of the canvas is
       copied into a row buffer and read there as a plain run of bytes at a
       fixed offset from the buffer's address, so a row has to fit the first
       block of a byte array.  That block is at least four kilobytes on either
       target that has a screen, and a row of 512 cells is two kilobytes - a
       cell is four bytes now, a code point and an attribute - so this is the
       cap with room to spare.  A console wider than this is asked for this
       width and the answer is what the interface gets, the same way a DOS
       screen is the video mode's size and not the application's. *)
    MAXCOLS = 512;

VAR
    row: ByteArr.ByteArray;       (* one row of the canvas, on its way out *)
    cols, rows, rowBytes: INTEGER;
    opened: BOOLEAN;


PROCEDURE Cols* (): INTEGER;
VAR n: INTEGER;
BEGIN
    n := cols;
    RETURN n
END Cols;


PROCEDURE Rows* (): INTEGER;
VAR n: INTEGER;
BEGIN
    n := rows;
    RETURN n
END Rows;


(* Take the screen, asking for the size the application would like.  What it
   gets is what ArchTuiScr answers, which under DOS is the video mode and
   cannot be anything else.

   Setup comes first and it comes before anything is drawn, because it is what
   tells TuiPage which host it is on - and only this call site knows.  It is
   the one place in the framework where a target says what its screen and its
   text are, and it is asked before Open so that a screen that fails to open
   still leaves the page layer describing the host it is really on. *)
PROCEDURE Open* (wantCols, wantRows: INTEGER);
VAR c, r: INTEGER;
BEGIN
    IF ~opened THEN
        ArchTuiScr.Setup;
        c := wantCols;
        r := wantRows;
        IF c > MAXCOLS THEN c := MAXCOLS END;
        ArchTuiScr.Open(c, r);
        IF (c > 0) & (r > 0) THEN
            cols := c;
            rows := r;
            rowBytes := cols * TuiCanv.CELL;
            row := ByteArr.Create(rowBytes);
            opened := TRUE
        END
    END
END Open;


(* Follow the screen to the size it is showing now.

   Nothing is asked for: this runs because the screen said it changed, and the
   size it changed to is read from the screen.  A console reports its buffer and
   the buffer is often the taller of the two, so the size is queried rather than
   taken from the record that brought us here.

   The row buffer is the only thing here sized from the screen, so it is the only
   thing made again - and the new one is made before the old one is given back,
   which is the rule TuiWin.SetSize keeps for a canvas: a size the allocator
   cannot meet must leave the screen working rather than half changed.

   A size the screen already has is not a resize.  A console reports its size
   when it likes - one report arrives the moment window input is turned on, and
   it says what the size already was - so comparing first is what keeps an idle
   report from costing a kilobyte of heap and a lost screen. *)
PROCEDURE Resize*;
VAR c, r: INTEGER; buf: ByteArr.ByteArray;
BEGIN
    IF opened THEN
        ArchTuiScr.Size(c, r);
        IF c > MAXCOLS THEN c := MAXCOLS END;
        IF (c > 0) & (r > 0) & ((c # cols) OR (r # rows)) THEN
            buf := ByteArr.Create(c * TuiCanv.CELL);
            row.Done(row);
            row := buf;
            cols := c;
            rows := r;
            rowBytes := c * TuiCanv.CELL
        END
    END
END Resize;


PROCEDURE Close*;
BEGIN
    IF opened THEN
        ArchTuiScr.Close;
        row.Done(row);
        opened := FALSE
    END
END Close;


(* The canvas on the screen: every row of it, a row at a time, from the top.
   A row that the canvas does not have - the canvas may be shorter than the
   screen, or the application may have asked for fewer columns - is left as it
   is, which is what lets a smaller canvas sit on a larger screen. *)
PROCEDURE Present* (c: TuiCanv.Canvas);
VAR y, w: INTEGER;
BEGIN
    IF opened & (c # NIL) THEN
        w := cols;
        IF w > c.w THEN w := c.w END;
        FOR y := 0 TO rows - 1 DO
            IF y < c.h THEN
                c.GetRow(c, y, w * TuiCanv.CELL, row);
                ArchTuiScr.Write(0, y, w, row.Adr(row, 0))
            END
        END
    END
END Present;


(* What is on the screen now, written to a file in the format TuiCanv.Dump
   documents.

   The screen is read a row at a time into the row buffer and reaches the
   canvas from there, because a canvas of any size is more than one block and
   TuiCanv.PutRow is the call that knows it. *)
PROCEDURE Dump* (name: ARRAY OF CHAR): BOOLEAN;
VAR c: TuiCanv.Canvas; ok: BOOLEAN; y: INTEGER;
BEGIN
    ok := FALSE;
    IF opened THEN
        c := TuiCanv.Create(cols, rows);
        FOR y := 0 TO rows - 1 DO
            ArchTuiScr.Read(0, y, cols, 1, row.Adr(row, 0));
            c.PutRow(c, y, rowBytes, row)
        END;
        ok := c.Dump(c, name);
        c.Done(c)
    END;
    RETURN ok
END Dump;

END TuiScr.
