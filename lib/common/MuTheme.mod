(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The colours a program is drawn in, read from an .ini file beside its own
    image.

    The rule is one line long: an image called `C:\dir\prog.exe` takes its
    colours from `C:\dir\prog.ini`, and an image started from a directory
    that holds no such file runs on microui's own defaults and says nothing
    about it.  The name is built from Program's answer and Dirs.Separator,
    so it is the same rule on every target rather than a Windows path written
    into portable code.

    The file is an ordinary .ini, read by IniReader:

        [common]
        gui.theme = win95          ; which section holds the colours

        [win95]
        button       = #C0C0C0     ; what a control is filled with
        button.light = #FFFFFF     ; the top and left of its bevel
        button.dark  = #808080     ; the bottom and right of it
        button.border= #000000     ; the frame outside that
        ...

    THE TWO HALVES OF A KEY.  A fill is named by the colour's own name and a
    nuance of that fill by the colour's name and the field, joined by a dot:

        <colour>              the fill
        <colour>.<field>      one nuance of it

    Twenty-two colours and six fields, so a theme has a hundred and thirty-two
    nuances to name and never has to name one it does not care about.  The
    colours are microui's own fourteen and eight this tree added - a close
    box, a resize grip, a selected run of text, a scrollbar thumb's two live
    states and a popup's body - and the fields are the six of MuBase.Part:

        text border window title titletext panel
        button buttonhover buttonfocus
        base basehover basefocus
        scroll scrollthumb
        titlebtn titlebtnhover titlebtnfocus
        grip select scrollthumbhover scrollthumbfocus popup

        border  the frame around the fill;        a = 0 draws none
        light   the top and left of a 3D bevel;   a = 0 draws none
        dark    its bottom and right;             a = 0 draws none
        text    the ink drawn on the fill;        a = 0 keeps the program's
        shadow  a one-pixel drop shadow;          a = 0 draws none
        caret   a text field's insertion bar;     a = 0 keeps the text colour

    The colours are FILLS and the fills are what a control's state picks
    between: `button` at rest, `buttonhover` under the pointer, `buttonfocus`
    while it is held.  Every one of the three has its own six fields, so a
    theme that wants a pressed button's bevel inverted can say so and one
    that does not says nothing.

    A SHORT THEME IS STILL A THEME.  Naming a fill alone is enough: whatever
    the file sets is laid over the defaults and every nuance the file did not
    name goes back to being derived from the fills, exactly as microui derives
    them - every control framed in `border`, every caption in `text`, no bevel
    and no shadow anywhere.  So `border = #808080` frames the whole program in
    grey and `border = #808080` plus `button.border = #000000` frames all of
    it in grey but the buttons in black.  Nothing has to be said twice.

    Nothing else is read.  The style's seven measurements - padding, spacing,
    indent, the title height and so on - are deliberately NOT here.  A theme
    that moved them would move the layout with them, and every claim this tree
    makes about where a control lands is a claim about the layout as it is.
    A colour is a thing a theme may change and a padding is not.

    A colour written with three components keeps the alpha its slot already
    had, which is opaque everywhere except `panel` - microui draws no
    background behind a panel, and a theme that gives one an opaque colour
    will find out why that default is what it is.  A theme that wants a
    transparent fill where the default is opaque, or the reverse, writes the
    fourth component.

    Reading a file is not enough on its own: something has to ask.  Apply is
    that, and it overlays the theme on a style after Microui.Init has built
    the defaults - which is the only order that works, because a theme is a
    difference from the defaults and not a replacement for them.
*)

MODULE MuTheme;

IMPORT Strings, Files, Dirs, Program, IniReader, MuBase, Microui;


CONST

    (* A name array has to hold the name AND its terminator, which is one
       more than the longest name looks like it needs: `scrollthumbhover` and
       `scrollthumbfocus` are sixteen characters, so a KeyMax of 16 stores
       them with no room for the 0X and the string then runs into whatever
       follows it in the array.  That is not a reading error - it reaches
       IniReader's comparison as an unterminated string and traps there.  The
       limit is the longest name plus room to spare, not the longest name. *)
    KeyMax  = 24;                       (* the longest colour name is 16 *)
    FieldMax = 16;                      (* the longest field name is 6 *)
    (* a colour name, a dot, a field name and a terminator *)
    DottedMax = KeyMax + 1 + FieldMax;
    NameMax = 64;
    PathMax = 1024;
    WordMax = 256;
    NoteMax = 96;


VAR

    (* one table, both directions: the keys are written once here and both
       the reader that fills the theme and the caller that prints one back
       out walk it, so a key cannot come to mean one slot on the way in and
       another on the way out. *)
    keys:   ARRAY MuBase.ColorMax OF ARRAY KeyMax OF CHAR;
    fields: ARRAY MuBase.PartFields OF ARRAY FieldMax OF CHAR;

    thm:  ARRAY MuBase.ColorMax OF MuBase.Color;    (* the theme's own fills *)
    set:  ARRAY MuBase.ColorMax OF BOOLEAN;         (* which of them it named *)
    (* and the same for the nuances of each of them *)
    athm: ARRAY MuBase.ColorMax OF ARRAY MuBase.PartFields OF MuBase.Color;
    aset: ARRAY MuBase.ColorMax OF ARRAY MuBase.PartFields OF BOOLEAN;

    nick: ARRAY NameMax OF CHAR;                   (* the theme's name *)
    path: ARRAY PathMax OF CHAR;                   (* the file it was looked for in *)
    err:  ARRAY NoteMax OF CHAR;
    got:  BOOLEAN;                                 (* the file was there *)
    nset: INTEGER;                                 (* how many slots it set *)

    (* The desktop, under the key `desktop`.

       It is the one colour here that is NOT a slot of Microui.Style, and it
       is read the same way and kept separately for that reason: a theme is
       given to a style, and the desktop is not in the style.  It is the
       window's own background, which is the host's - MuHost.Run takes it as
       an argument - so the reader keeps it and the host asks for it.  A
       theme that names none leaves deskSet FALSE and the host's own
       background stands. *)
    desk:    MuBase.Color;
    deskSet: BOOLEAN;

    (* module level because a module body has no locals of its own *)
    dir, base, leaf: ARRAY PathMax OF CHAR;
    i, f: INTEGER;
    ok: BOOLEAN;   (* Append answers one, and a function call is not a statement *)


PROCEDURE InitKeys;
BEGIN
    COPY("text",        keys[MuBase.ColorText]);
    COPY("border",      keys[MuBase.ColorBorder]);
    COPY("window",      keys[MuBase.ColorWindowBG]);
    COPY("title",       keys[MuBase.ColorTitleBG]);
    COPY("titletext",   keys[MuBase.ColorTitleText]);
    COPY("panel",       keys[MuBase.ColorPanelBG]);
    COPY("button",      keys[MuBase.ColorButton]);
    COPY("buttonhover", keys[MuBase.ColorButtonHover]);
    COPY("buttonfocus", keys[MuBase.ColorButtonFocus]);
    COPY("base",        keys[MuBase.ColorBase]);
    COPY("basehover",   keys[MuBase.ColorBaseHover]);
    COPY("basefocus",   keys[MuBase.ColorBaseFocus]);
    COPY("scroll",      keys[MuBase.ColorScrollBase]);
    COPY("scrollthumb", keys[MuBase.ColorScrollThumb]);

    COPY("titlebtn",         keys[MuBase.ColorTitleBtn]);
    COPY("titlebtnhover",    keys[MuBase.ColorTitleBtnHover]);
    COPY("titlebtnfocus",    keys[MuBase.ColorTitleBtnFocus]);
    COPY("grip",             keys[MuBase.ColorGrip]);
    COPY("select",           keys[MuBase.ColorSelect]);
    COPY("scrollthumbhover", keys[MuBase.ColorScrollThumbHover]);
    COPY("scrollthumbfocus", keys[MuBase.ColorScrollThumbFocus]);
    COPY("popup",            keys[MuBase.ColorPopupBG]);

    COPY("border", fields[MuBase.PartBorder]);
    COPY("light",  fields[MuBase.PartLight]);
    COPY("dark",   fields[MuBase.PartDark]);
    COPY("text",   fields[MuBase.PartText]);
    COPY("shadow", fields[MuBase.PartShadow]);
    COPY("caret",  fields[MuBase.PartCaret])
END InitKeys;


(* The alpha a slot keeps when the file names three components and not four.
   Everything is opaque except a panel, which microui draws no background
   behind - `panel bg` is transparent in the default style and is meant to
   be.  A theme that wants one of the eight slots this tree added, all of
   which start transparent, writes three components and gets an opaque
   colour: naming a slot is how a theme says it wants it seen. *)
PROCEDURE DefaultAlpha (slot: INTEGER): INTEGER;
VAR
    a: INTEGER;

BEGIN
    a := 255;
    IF slot = MuBase.ColorPanelBG THEN a := 0 END;
    RETURN a
END DefaultAlpha;


(* Dotted - the key that names one field of one fill: `button.border`.  The
   one place the two halves are joined, so the reader and the writer of the
   name cannot spell it differently. *)
PROCEDURE Dotted (slot, f: INTEGER; VAR key: ARRAY OF CHAR);
VAR
    ok: BOOLEAN;

BEGIN
    Strings.Copy(keys[slot], key);
    ok := Strings.Append(".", key);
    ok := Strings.Append(fields[f], key)
END Dotted;


(* A colour, or a word in Error when the key is there and is not one.  The
   two answers are separate because the caller wants to count what it set and
   still complain about what it could not read. *)
PROCEDURE Colour (theme: ARRAY OF CHAR; key: ARRAY OF CHAR; alpha: INTEGER;
                  VAR c: MuBase.Color; VAR there, bad: BOOLEAN);
VAR
    n: INTEGER;
    v: ARRAY 8 OF INTEGER;
    raw: ARRAY WordMax OF CHAR;
    a: INTEGER;

BEGIN
    there := FALSE;
    IF IniReader.GetColor(theme, key, n, v) THEN
        IF n = 4 THEN a := v[3] ELSE a := alpha END;
        MuBase.MakeColor(c, v[0], v[1], v[2], a);
        there := TRUE
    ELSIF IniReader.Get(theme, key, raw) THEN
        (* the key is there and what it holds is not a colour *)
        bad := TRUE
    END
END Colour;


(* Read - take every colour of section `theme`, and every nuance of one, that
   this module knows.

   A key the file does not hold is not an error, and neither is a theme that
   names only some of them.  A key that is there and is not a colour is
   passed over with a word in Error, because a theme with one bad line in it
   is more use running on the rest than on none at all. *)
PROCEDURE Read (theme: ARRAY OF CHAR);
VAR
    k, f: INTEGER;
    key: ARRAY DottedMax OF CHAR;
    bad: BOOLEAN;

BEGIN
    nset := 0;
    bad := FALSE;
    deskSet := FALSE;
    FOR k := 0 TO MuBase.ColorMax - 1 DO
        Colour(theme, keys[k], DefaultAlpha(k), thm[k], set[k], bad);
        IF set[k] THEN INC(nset) END;
        FOR f := 0 TO MuBase.PartFields - 1 DO
            Dotted(k, f, key);
            (* a nuance of an invisible fill keeps the fill's own alpha rule:
               `grip` is transparent until a theme names it, and so is the
               frame around it *)
            Colour(theme, key, DefaultAlpha(k), athm[k][f], aset[k][f], bad);
            IF aset[k][f] THEN INC(nset) END
        END
    END;
    (* `desktop` is read after the two loops and is counted in nset like any
       other key, so a file that names only a desktop is a theme that set
       something and reports as one.  It is not in the loop above because it
       is not a slot: there is no key in `keys` for it and no field of it,
       and it reaches no part of the style. *)
    Colour(theme, "desktop", 255, desk, deskSet, bad);
    IF deskSet THEN INC(nset) END;
    IF bad & (nset > 0) THEN
        COPY("a colour in the theme is not one", err)
    END
END Read;


(* KeyOf - the key a colour slot is written under, or the empty string for an
   index that is not a slot.  For a caller that wants to print a theme back
   out; MuTheme itself only reads. *)
PROCEDURE KeyOf* (slot: INTEGER; VAR key: ARRAY OF CHAR);
BEGIN
    key[0] := 0X;
    IF (slot >= 0) & (slot < MuBase.ColorMax) THEN
        Strings.Copy(keys[slot], key)
    END
END KeyOf;


(* FieldOf - the same for one of the six fields of a Part, and DottedKeyOf
   for the pair of them spelled the way the file spells it.  Both are for a
   caller that prints; they name nothing the reader does not already use. *)
PROCEDURE FieldOf* (f: INTEGER; VAR name: ARRAY OF CHAR);
BEGIN
    name[0] := 0X;
    IF (f >= 0) & (f < MuBase.PartFields) THEN
        Strings.Copy(fields[f], name)
    END
END FieldOf;


PROCEDURE DottedKeyOf* (slot, f: INTEGER; VAR key: ARRAY OF CHAR);
BEGIN
    key[0] := 0X;
    IF (slot >= 0) & (slot < MuBase.ColorMax) &
       (f >= 0) & (f < MuBase.PartFields) THEN
        Dotted(slot, f, key)
    END
END DottedKeyOf;


(* Apply - put the theme into a style.

   Result: TRUE when something was set.  Three steps, and the order is the
   whole of the design:

       1. the fills the file named are laid over the style's own
       2. SeedParts derives every nuance from the fills - microui's rule,
          unchanged
       3. the nuances the file named are laid over that

   So a theme that names nothing but fills gets exactly what microui would
   have derived from them, and a theme that names a nuance gets it.  A style
   the file did not mention at all is left exactly as Microui.Init built
   it. *)
PROCEDURE Apply* (VAR s: Microui.Style): BOOLEAN;
VAR
    k, f, n: INTEGER;

BEGIN
    n := 0;
    FOR k := 0 TO MuBase.ColorMax - 1 DO
        IF set[k] & (k < LEN(s.colors)) THEN
            s.colors[k] := thm[k];
            INC(n)
        END
    END;
    IF n > 0 THEN
        Microui.SeedParts(s)
    END;
    FOR k := 0 TO MuBase.ColorMax - 1 DO
        IF k < LEN(s.parts) THEN
            FOR f := 0 TO MuBase.PartFields - 1 DO
                IF aset[k][f] THEN
                    MuBase.PartSet(s.parts[k], f, athm[k][f]);
                    INC(n)
                END
            END
        END
    END;

    RETURN n > 0
END Apply;


(* Name - the theme's name out of `gui.theme`, or the empty string when none
   was read. *)
PROCEDURE Name* (VAR s: ARRAY OF CHAR);
BEGIN
    Strings.Copy(nick, s)
END Name;


(* FilePath - the .ini that was looked for, whether or not it was there, so a
   program can say which file it read.  The empty string means the target
   could not say where the image is (`Program.Base` was empty) and no file
   could be named at all. *)
PROCEDURE FilePath* (VAR s: ARRAY OF CHAR);
BEGIN
    Strings.Copy(path, s)
END FilePath;


(* Found - the file was there.  A program that wants to report "no theme
   file" tells that from "a theme file I could not use" by this and by
   Error. *)
PROCEDURE Found* (): BOOLEAN;
BEGIN
    RETURN got
END Found;


(* Slots - how many slots the theme set, a fill and a nuance counting alike.
   The desktop is one of them when the theme named one. *)
PROCEDURE Slots* (): INTEGER;
BEGIN
    RETURN nset
END Slots;


(* Desktop - the theme's own window background, under the key `desktop`, and
   whether it named one.

   This is the only colour in the file that is not a slot of Microui.Style,
   and a caller has to ask for it separately for that reason: Apply puts a
   theme into a style, and a style has no background - the window's is the
   host's.  A theme that names none answers FALSE and the caller's own
   background stands, which is the same rule as every other key here: a
   colour the file does not name changes nothing. *)
PROCEDURE Desktop* (VAR c: MuBase.Color): BOOLEAN;
BEGIN
    c := desk;
    RETURN deskSet
END Desktop;


(* Error - what went wrong with a file that was there, or the empty string.
   A missing file is not an error: it is the ordinary case, and a program
   with no .ini beside it is meant to run on the defaults. *)
PROCEDURE Error* (VAR s: ARRAY OF CHAR);
BEGIN
    Strings.Copy(err, s)
END Error;


BEGIN
    nick[0] := 0X;
    path[0] := 0X;
    err[0] := 0X;
    got := FALSE;
    nset := 0;
    deskSet := FALSE;
    InitKeys;
    FOR i := 0 TO MuBase.ColorMax - 1 DO
        set[i] := FALSE;
        FOR f := 0 TO MuBase.PartFields - 1 DO aset[i][f] := FALSE END
    END;

    (* The file is the program's own name with the extension changed, in the
       program's own directory.  Base and not Name: the extension is the one
       part of the name this does not want, and a target that cannot say
       where the image is answers an empty Base, which leaves nothing to
       look for and is not a failure - it is a target with no file to read. *)
    Program.Dir(dir);
    Program.Base(base);
    IF base[0] # 0X THEN
        COPY(base, leaf);
        ok := Strings.Append(".ini", leaf);
        Dirs.Join(dir, leaf, path);
        IF Files.FileExists(path) THEN
            got := TRUE;
            IF ~IniReader.Open(path) THEN
                IniReader.Error(err)
            ELSIF ~IniReader.Get("common", "gui.theme", nick) THEN
                COPY("no [common] gui.theme names a theme", err);
                nick[0] := 0X
            ELSE
                Read(nick);
                IF nset = 0 THEN
                    COPY("the theme names no colour this knows", err)
                END
            END
        END
    END
END MuTheme.
