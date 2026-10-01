(*
    Public domain (The Unlicense)

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The font a program has when it has no font of its own.

    Exactly one of the generated font modules is compiled in - the one this
    file imports - and which one is decided here, by $IF, and nowhere else.
    That is the whole reason this module exists: the font modules are big
    (FontI8x16.mod is 25 KB of source for 749 glyphs) and carrying three of
    them would be carrying three fonts to use one.

    The default is 8x16 on every target.  The exception is a DPMI32 target,
    where it is 8x8: a DOS screen is 640x480 in the graphics mode the host puts
    up, and 8x8 gives 80x60 characters there against 80x30 - twice the window
    in the same pixels, which is what a program whose whole interface is text
    wants.  It is also the one size where the glyphs were drawn for that
    screen in the first place.

    Any of them can be forced from the command line, on any target:

        Compiler prog.mod win64gui    -def MU_FONT_8X8
        Compiler prog.mod dpmi32le    -def MU_FONT_8X14
        Compiler prog.mod win64gui    -def MU_FONT_8X16

    and a target that is happy with 8x16 needs no option at all.

    ORDER IS THE WHOLE MECHANISM, and the three `-def` names come first.
    Written the other way round - `$IF (MU_FONT_8X8 | DPMI32)` at the head,
    which is how this file was written first - a `-def` is dead on all three
    dpmi32 targets, because DPMI32 is true there whatever else is defined and
    the first arm that matches wins: measured, `dpmi32le -def MU_FONT_8X14`
    compiled in FontI8x8 and said nothing about it.  So the DPMI32 default
    is the arm AFTER the three explicit ones and not a condition on them, and
    the chain below is in the order the options are meant to be tried in.

    The same chain is written twice, once for the IMPORT and once for the two
    procedures - one chain cannot name the module for the other - so the two
    must be kept in step.  A branch added to one and not the other does not
    fail to compile: it imports one face and paints another.

    What it offers is deliberately a store and not a PaintFn: building the
    store is where the tables are read, it can only fail once, and the caller
    that gets one has a font it can measure, list and paint with the same
    calls it uses for a file.  lib/Windows/MuHost.mod asks for `font.pcf` in
    the program's own directory first and comes here only when there is none.
*)

MODULE FontBuiltin;

$IF (MU_FONT_8X8)
IMPORT FontFile, FontI8x8;
$ELSIF (MU_FONT_8X14)
IMPORT FontFile, FontI8x14;
$ELSIF (MU_FONT_8X16)
IMPORT FontFile, FontI8x16;
$ELSIF (DPMI32)
IMPORT FontFile, FontI8x8;
$ELSE
IMPORT FontFile, FontI8x16;
$END


(* Copy - a name into the caller's buffer, terminated, and never past its end.

   Written out rather than assigned because the two sides are different
   lengths: the generated module's Name is 32 characters of room and the
   caller's may be longer or shorter, and an assignment between open arrays of
   different lengths is not something this dialect has. *)
PROCEDURE Copy (src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR
    i, cap: INTEGER;

BEGIN
    cap := LEN(dst) - 1;
    IF cap > LEN(src) - 1 THEN cap := LEN(src) - 1 END;
    i := 0;
    WHILE (i < cap) & (src[i] # 0X) DO
        dst[i] := src[i];
        INC(i)
    END;
    dst[i] := 0X
END Copy;


(* Load - the built-in font, as the same store a file is read into.

   The chain below is the one above, in the same order, and the two are one
   mechanism: an arm here that names a different face from its twin in the
   IMPORT is a module that imports one font and paints another. *)

$IF (MU_FONT_8X8)

PROCEDURE Load* (VAR st: FontFile.Store): BOOLEAN;
BEGIN
    RETURN FontFile.FromTable(FontI8x8.Codes, FontI8x8.Box,
                                FontI8x8.Bits, FontI8x8.CellW,
                                FontI8x8.CellH, FontI8x8.Ascent, st)
END Load;


PROCEDURE Name* (VAR s: ARRAY OF CHAR);
BEGIN
    Copy(FontI8x8.Name, s)
END Name;

$ELSIF (MU_FONT_8X14)

PROCEDURE Load* (VAR st: FontFile.Store): BOOLEAN;
BEGIN
    RETURN FontFile.FromTable(FontI8x14.Codes, FontI8x14.Box,
                                FontI8x14.Bits, FontI8x14.CellW,
                                FontI8x14.CellH, FontI8x14.Ascent, st)
END Load;


PROCEDURE Name* (VAR s: ARRAY OF CHAR);
BEGIN
    Copy(FontI8x14.Name, s)
END Name;

$ELSIF (MU_FONT_8X16)

PROCEDURE Load* (VAR st: FontFile.Store): BOOLEAN;
BEGIN
    RETURN FontFile.FromTable(FontI8x16.Codes, FontI8x16.Box,
                                FontI8x16.Bits, FontI8x16.CellW,
                                FontI8x16.CellH, FontI8x16.Ascent, st)
END Load;


PROCEDURE Name* (VAR s: ARRAY OF CHAR);
BEGIN
    Copy(FontI8x16.Name, s)
END Name;

$ELSIF (DPMI32)

PROCEDURE Load* (VAR st: FontFile.Store): BOOLEAN;
BEGIN
    RETURN FontFile.FromTable(FontI8x8.Codes, FontI8x8.Box,
                                FontI8x8.Bits, FontI8x8.CellW,
                                FontI8x8.CellH, FontI8x8.Ascent, st)
END Load;


PROCEDURE Name* (VAR s: ARRAY OF CHAR);
BEGIN
    Copy(FontI8x8.Name, s)
END Name;

$ELSE

PROCEDURE Load* (VAR st: FontFile.Store): BOOLEAN;
BEGIN
    RETURN FontFile.FromTable(FontI8x16.Codes, FontI8x16.Box,
                                FontI8x16.Bits, FontI8x16.CellW,
                                FontI8x16.CellH, FontI8x16.Ascent, st)
END Load;


PROCEDURE Name* (VAR s: ARRAY OF CHAR);
BEGIN
    Copy(FontI8x16.Name, s)
END Name;

$END


END FontBuiltin.
