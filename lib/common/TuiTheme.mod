MODULE TuiTheme;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The colour pairs the whole interface is drawn with, in one place.

   Every widget used to keep its own colour fields - a window had three, a menu
   four, a list three - and every one of them was set once in its Create and
   never looked at again.  That works, and it is why a colour scheme could not
   be changed: the values were copied into the widgets at the moment they were
   built.  Here they are a table instead, and a widget asks for the pair it is
   about to draw with at the moment it draws.  A theme switch is then a single
   assignment and the next Draw, with nothing to re-apply and nothing to miss.

   A pair is a VGA attribute byte, the same thing TuiCanv.Attr builds from a
   foreground and a background.  The slots are named after what they colour, not
   after the colours they hold, so a theme is a list of decisions rather than a
   list of numbers, and a widget names one slot instead of a colour.

   The two themes are built by the module body, because the dialect has no array
   initialiser: a pair can only be assigned, not declared.  Theme 0 is the
   interface as it looked before there was a theme at all - the blue field, the
   grey windows and the black on cyan selections of the DOS shells this one is
   written in the manner of - and it is the one in force until somebody asks for
   the other.

   Theme 1 has no colour in it at all, and one of its slots wants a background
   the attribute byte has no room for: three bits are the background's and the
   fourth is one the adapter reads as blink.  That fourth bit is what makes a
   light background possible and what makes it flicker, and the theme uses it -
   a white strip is how a black and white interface says "this one" - so it is
   also a theme that needs the blink bit turned into an intensity bit before it
   is drawn.  ArchTuiScr does that at the moment it takes the screen; see its
   comment for what happens without it.

   A window may keep its own table (see Windows): it copies this one with Fill
   and overrides what it likes, and is then its own theme whatever happens
   afterwards. *)

IMPORT TuiCanv, Strings;

CONST

    NPAIR* = 53;                    (* slots in a theme *)

    (* What each slot colours.  A widget names the slot, never a colour. *)
    Desk* = 0;                      (* the desktop behind the windows *)
    Frame* = 1;                     (* a window's frame, and its body *)
    FrameActive* = 2;               (* the same for the focused window *)
    Title* = 3;                     (* the title bar of the focused window *)
    TitleIdle* = 4;                 (* and of the others *)
    List* = 5;                      (* a list's rows *)
    ListSel* = 6;                   (* the selected row of a focused list *)
    ListSelIdle* = 7;               (* and of a list whose window is not the
                                       focused one.  The selection is still
                                       drawn - which row it is is worth knowing
                                       in either window - but in a pair that is
                                       quieter than the keyboard's, so which
                                       list the arrows will move is visible in
                                       the list itself and not only in the
                                       frame around it. *)
    ListBar* = 8;                   (* its scrollbar *)
    Menu* = 9;                      (* the menu bar and a drop-down *)
    MenuHot* = 10;                  (* the title whose drop-down is open *)
    MenuFrame* = 11;                (* the drop-down's box *)
    MenuSel* = 12;                  (* the highlighted entry in it *)
    Dialog* = 13;                   (* a dialog's body *)
    DialogFrame* = 14;              (* its frame *)
    DialogText* = 15;               (* the strip its title sits on, where the
                                       frame's pair is what the box is drawn
                                       with - so the title reads as a tab.  A
                                       dialog's message is drawn on its body,
                                       in the Dialog pair. *)
    Button* = 16;                   (* a button *)
    ButtonDefault* = 17;            (* the one Enter takes without being asked *)
    ButtonHot* = 18;                (* the one the keyboard is on *)
    Status* = 19;                   (* the status line, the last row *)
    Field* = 20;                    (* a one-line input field, and the text in
                                       it.  It is deliberately the one slot whose
                                       background is not the surface behind it:
                                       an input field that is the same colour as
                                       the box it sits in does not read as
                                       something that can be typed into. *)
    FieldSel* = 21;                 (* the selected run of a field that has the
                                       keyboard, and the caret when nothing is
                                       selected - the caret being a selection of
                                       one cell is what makes one slot do for
                                       both *)
    FieldSelIdle* = 22;             (* the same in a field that does not have it,
                                       which is quieter for the reason
                                       ListSelIdle is *)
    Check* = 23;                    (* a checkbox without the keyboard *)
    CheckHot* = 24;                 (* the one the keyboard is on.  A checkbox
                                       has no "default" state the way a button
                                       has, so two slots do for it where a
                                       button needs three: what the pair says is
                                       which widget a Space would reach, and
                                       whether the box is set is the mark. *)
    Radio* = 25;                    (* a radio group without the keyboard *)
    RadioHot* = 26;                 (* the group the keyboard is on *)
    Progress* = 27;                 (* the filled part of a progress bar *)
    ProgressEmpty* = 28;            (* the part of it not yet reached, drawn as
                                       a shade - the one pair in a theme whose
                                       glyph as well as its colour says which
                                       half of the widget it is *)
    TableHead* = 29;                (* a table's header row, the frozen strip
                                       its column titles sit on *)
    TableHeadSel* = 30;             (* the header cell of the column a click on
                                       the header chose.  A pair of its own and
                                       not the selected row's: the two are a
                                       strip and a bar, and a pair that reads as
                                       a chosen row reads as a mistake across a
                                       title *)
    TableBody* = 31;                (* a table's data rows, and the surface it
                                       leaves under them when the data runs out
                                       before the widget does *)
    TableRowSel* = 32;              (* the row a table's cursor is on *)
    TableRowSelIdle* = 33;          (* and that row in a table whose window is
                                       not the focused one, for the reason
                                       ListSelIdle gives *)
    TableBar* = 34;                 (* a table's scrollbars.  One slot and not
                                       the list's, because a table has two of
                                       them and they are drawn across the field
                                       rather than beside it *)
    Rule* = 35;                     (* a line drawn between two parts of a
                                       widget - a panel's split line, which is
                                       the one of them the mouse may take hold
                                       of.  It is quieter than the surface it
                                       crosses in both themes and it is a line
                                       in both: a pair that differed from the
                                       body by colour alone would say the cell
                                       is a cell of the body *)
    TableEdit* = 36;                (* the cell a table is being written into.
                                       Its own slot and neither the body's nor
                                       the chosen row's: the row underneath is
                                       one of those two and the whole point of
                                       the pair is that it says which one cell
                                       of it the keyboard is in.  The caret
                                       inside the cell needs no slot of its own
                                       - it is this pair with its two colours
                                       swapped, the inversion the mouse pointer
                                       is drawn with *)
    TextArea* = 37;                 (* a text area's body and the text in it -
                                       what Field is for a one-line field, and
                                       the pair the find line is drawn in as
                                       well *)
    TextAreaSel* = 38;              (* the selected run of a text area that has
                                       the keyboard, and the caret, which is a
                                       selection of one cell - the same two jobs
                                       FieldSel does, and the find line's cursor
                                       block wears it too *)
    TextAreaSelIdle* = 39;          (* the same in an area that does not have
                                       the keyboard, quieter for the reason
                                       FieldSelIdle is *)
    TextAreaBar* = 40;              (* an area's two scrollbars, whose corner
                                       cell is the horizontal one's last *)
    Combo* = 41;                    (* a combo box's face - the one-line strip
                                       that shows the item chosen - closed and
                                       without the keyboard *)
    ComboSel* = 42;                 (* the face while the drop-down is open.
                                       Open is a selection in progress and not a
                                       focus, which is why it is not
                                       ComboSelIdle *)
    ComboSelIdle* = 43;             (* the face, closed, of the box the keyboard
                                       is on.  A face has no third state: what
                                       the arrows reach has to be visible on the
                                       strip whether the box is open or shut, and
                                       the open face says the same thing more
                                       loudly rather than something else *)
    ComboFrame* = 44;               (* the drop-down's box, the frame the rows
                                       are laid in *)
    ComboList* = 45;                (* the rows of the drop-down *)
    ComboListSel* = 46;             (* the row of it the box has chosen.  The
                                       drop-down does not scroll a highlight
                                       around: the face shows one item and the
                                       list marks that one, so the mark follows
                                       the choice and not the pointer *)
    ComboBar* = 47;                 (* its scrollbar, drawn only when there are
                                       more items than rows to show *)
    Tree* = 48;                     (* a tree's rows *)
    TreeSel* = 49;                  (* the node the cursor is on, in a tree whose
                                       window has the keyboard *)
    TreeSelIdle* = 50;              (* and in one that has not, quieter for the
                                       reason ListSelIdle is quieter *)
    TreeBar* = 51;                  (* its scrollbar *)
    TreeLine* = 52;                 (* the rules that show the levels.  A tree is
                                       the one widget here whose drawing is not
                                       all rows and text: the indent carries a
                                       vertical rule for every level that still
                                       has a sibling below the row being drawn,
                                       and those are what this pair is for.  The
                                       rules belong to the widget rather than to
                                       the row, so on an ordinary row they take
                                       this pair and the row keeps its own - but
                                       on the chosen row they take the chosen
                                       row's pair instead, because a rule in a
                                       second colour across a bar reads as a
                                       crack in it rather than as a line drawn
                                       over it *)

    NTHEME = 2;                     (* themes below *)

TYPE

    (* One theme: a pair per slot.  The type is private - a window holds an
       ARRAY NPAIR OF INTEGER, which is what Fill fills and what Attr reads. *)
    Theme = RECORD
        pairs: ARRAY NPAIR OF INTEGER
    END;

VAR
    themes: ARRAY NTHEME OF Theme;
    cur: INTEGER;                   (* the theme in force *)


(* One pair of a theme. *)
PROCEDURE P (t, slot, fg, bg: INTEGER);
BEGIN
    themes[t].pairs[slot] := TuiCanv.Attr(fg, bg)
END P;


(* Theme 0 is the interface as it looked before themes existed: light grey on
   blue, black on light grey windows, a white on blue title bar for the window
   that has the focus.  The slots that were added with the dialogs and the
   buttons are chosen to match it.

   Theme 1 has no colour at all.  Everything is white on black, a surface that
   has to be read - the strip of a field, the row a list is on, the entry a
   menu has reached, the title strip of a dialog - is that pair turned over, and
   the two things that carry an accent are the widget the keyboard is on and the
   window it is in: yellow, which is what a colourless theme has instead of the
   highlight a coloured one gets for free, and, for a button, green, because a
   button is the one thing on a screen whose whole purpose is to be pressed.

   The idle selection is a pair of its own in both themes rather than the
   focused one dimmed by arithmetic - there is no operation here that darkens a
   colour, so a slot is a decision like any other.  In the classic theme it is a
   dark strip and in Mono a grey one; in both it reads as a selection and is
   plainly not the green, the cyan or the white that the list with the keyboard
   draws.

   The field's pairs follow the same rule and one more: a field is drawn in a
   pair that is not the surface it sits on, because the only thing that says a
   strip of a dialog can be typed into is that it does not look like the rest of
   it.  In Classic that strip is white on blue, which is what every program of
   this kind has ever asked for a name in, and the text window's body is drawn
   in the same pair - an editor and a one-line field are the same thing with
   different numbers of lines, and drawing them in two colours would be claiming
   otherwise.  Mono has no blue to put behind it and keeps the pair it had,
   black on white, which is also the lightest thing that theme owns.

   The selected run inside a field is that pair turned over, and the caret is
   the same thing one cell wide - so in Classic the field is white on blue and
   the selection in it is black on white, the inversion every editor of this
   kind marks a selection with.  A field that does not have the keyboard draws
   its selection as a grey block instead: the ordinary convention for a
   selection in a widget that is not the one being typed into, and what keeps
   the caret visible when the keyboard has moved on to the buttons.

   A table's rows were drawn in the list's four pairs and not in pairs of their
   own, on the argument that a chosen row is a chosen row and that a table whose
   bar of selection was a third colour would only be saying which widget drew
   it.  The coloured theme's table has since been given its own four, for the
   reason the header's two were needed: a slot shared with every list in the
   interface cannot be changed for one widget without changing it for all of
   them, and repainting the table through the list's pairs repaints the file
   box's three lists with it.  What a table has
   that a list has not is a header, and those two slots are the header's: the
   strip itself, and the one cell of it that is the column a click chose.  The
   strip is drawn in the body's pair and not in one of its own, because the
   titles are data too - the same rows as the rest, only frozen - and a strip in
   a colour of its own reads as a widget laid on top of the table rather than as
   its first row.  The chosen cell keeps a pair of its own, which is how a click
   on a title is visible at all: it is that theme's own way of saying "this
   one", and the one place in a table where a colour means something the data
   does not say.

   The list's four have since been given the table's values, so the two are one
   look written twice: a row is a row, and a file box whose three lists were
   drawn in a pair of their own beside a grid drawn in another is a file box
   that looks like a different program.  They stay two sets of slots because a
   list is not a table and the day somebody wants them to differ again is a day
   that needs no new slot.

   The text area and the combo box have been given slots of their own on that
   same argument, and they are the last two widgets that were still wearing
   somebody else's: an area was drawn in the field's four and a combo box in the
   field's three plus the menu frame's and the list's four.  A field is a strip
   one line tall and an area is a window full of lines, but a program of this
   kind draws them the same and the classic theme keeps them the same, so the
   change moved no cell.  What it buys is the one thing a shared slot cannot:
   the day somebody wants the editor green and the name boxes blue, it is a line
   in Build and not a new slot.

   A combo box takes seven and not the four a list has, because it is two
   widgets stacked: a face, drawn whether or not the box is open, and a
   drop-down, drawn only while it is.  They are separate sets on purpose - the
   face is the closed widget's whole appearance and has to be legible against
   the dialog behind it, which the drop-down's rows, laid inside a frame of
   their own, do not.  Its face has three states where a list's rows have two,
   because a face carries the focus as well as the choice: closed and idle,
   closed and holding the keyboard, and open.  The open one is the loudest of
   the three in both themes, since a drop-down that is up has taken the keyboard
   and the pointer both.

   Classic's table has four slots of its own besides the header's two, and
   Mono's four hold what Mono's list holds, so the monochrome table is the table
   it was.  The coloured one is not: a table is the one widget here that is a
   picture of something the owner of this interface used every day, which is
   FoxPro for MS-DOS's Browse window, and the grid it was first drawn as - black
   on light grey, which were the list's colours then - was not that picture.  So
   the body, the row the cursor is on and the two bars take the colours that
   window had, and the list, having been given them since, is the same picture
   with fewer columns.

   They are the Browse scheme of that product's shipped DEFAULT colour set -
   scheme 10 of the twelve, whose ten pairs are documented: W+/BG for its
   standard display, which is the field; GR+/B for its enhanced one, which is
   the record the cursor is on; W+/B for its status line; GR+/GR for a chosen
   item, which here is the header cell a click chose; N+/W for a message, which
   is a row in a window that does not have the keyboard - a light bar, quieter
   than the blue one and still a bar.  Two of the five are worn in the role they
   were chosen for - the field's pair, which is the body and the frozen strip
   above it, and the chosen item's, which is the header cell a click chose - and
   two are borrowed, the scheme having no pair called a bar or an idle row: the
   status line's pair went to the cursor row and to the two bars, because a bar
   is chrome here and not data, and the message pair went to the idle row.  The
   fifth, GR+/B, is the pair the scheme keeps for the record the cursor is on,
   and it is not worn at all: the header strip was drawn in it until the header
   was given the body's pair, and the cursor row has been drawn in the status
   line's pair since these six slots were made.

   The one pair the scheme reserves for a title, GR+/W, is left alone - a title
   it draws in yellow on white is a title nobody reads. *)
PROCEDURE Build;
BEGIN
    P(0, Desk, TuiCanv.LightGray, TuiCanv.Blue);
    P(0, Frame, TuiCanv.Black, TuiCanv.LightGray);
    P(0, FrameActive, TuiCanv.Black, TuiCanv.LightGray);
    P(0, Title, TuiCanv.White, TuiCanv.Blue);
    P(0, TitleIdle, TuiCanv.Black, TuiCanv.LightGray);
    P(0, List, TuiCanv.White, TuiCanv.Cyan);
    P(0, ListSel, TuiCanv.White, TuiCanv.Blue);
    P(0, ListSelIdle, TuiCanv.DarkGray, TuiCanv.White);
    P(0, ListBar, TuiCanv.White, TuiCanv.Blue);
    P(0, Menu, TuiCanv.Black, TuiCanv.LightGray);
    P(0, MenuHot, TuiCanv.White, TuiCanv.Blue);
    P(0, MenuFrame, TuiCanv.Black, TuiCanv.LightGray);
    P(0, MenuSel, TuiCanv.White, TuiCanv.Blue);
    P(0, Dialog, TuiCanv.Black, TuiCanv.LightGray);
    P(0, DialogFrame, TuiCanv.White, TuiCanv.Blue);
    P(0, DialogText, TuiCanv.Black, TuiCanv.LightGray);
    P(0, Button, TuiCanv.Black, TuiCanv.Cyan);
    P(0, ButtonDefault, TuiCanv.Black, TuiCanv.Green);
    P(0, ButtonHot, TuiCanv.White, TuiCanv.Blue);
    P(0, Field, TuiCanv.White, TuiCanv.Blue);
    P(0, FieldSel, TuiCanv.Black, TuiCanv.White);
    P(0, FieldSelIdle, TuiCanv.Black, TuiCanv.LightGray);
    P(0, Check, TuiCanv.Black, TuiCanv.LightGray);
    P(0, CheckHot, TuiCanv.White, TuiCanv.Blue);
    P(0, Radio, TuiCanv.Black, TuiCanv.LightGray);
    P(0, RadioHot, TuiCanv.White, TuiCanv.Blue);
    P(0, Progress, TuiCanv.Black, TuiCanv.Green);
    P(0, ProgressEmpty, TuiCanv.Black, TuiCanv.LightGray);
    P(0, Status, TuiCanv.Black, TuiCanv.Cyan);
    P(0, TableHead, TuiCanv.White, TuiCanv.Cyan);
    P(0, TableHeadSel, TuiCanv.Yellow, TuiCanv.Brown);
    P(0, TableBody, TuiCanv.White, TuiCanv.Cyan);
    P(0, TableRowSel, TuiCanv.White, TuiCanv.Blue);
    P(0, TableRowSelIdle, TuiCanv.DarkGray, TuiCanv.White);
    P(0, TableBar, TuiCanv.White, TuiCanv.Blue);
    P(0, TableEdit, TuiCanv.Black, TuiCanv.White);
    P(0, Rule, TuiCanv.DarkGray, TuiCanv.LightGray);
    P(0, TextArea, TuiCanv.White, TuiCanv.Blue);
    P(0, TextAreaSel, TuiCanv.Black, TuiCanv.White);
    P(0, TextAreaSelIdle, TuiCanv.Black, TuiCanv.LightGray);
    P(0, TextAreaBar, TuiCanv.White, TuiCanv.Blue);
    P(0, Combo, TuiCanv.White, TuiCanv.Blue);
    P(0, ComboSel, TuiCanv.Black, TuiCanv.White);
    P(0, ComboSelIdle, TuiCanv.Black, TuiCanv.LightGray);
    P(0, ComboFrame, TuiCanv.Black, TuiCanv.LightGray);
    P(0, ComboList, TuiCanv.White, TuiCanv.Cyan);
    P(0, ComboListSel, TuiCanv.White, TuiCanv.Blue);
    P(0, ComboBar, TuiCanv.White, TuiCanv.Blue);
    (* The tree is the one pane in this theme that is dark where the box around
       it is light: the rows are grey on black, so a tree dropped into a window
       reads as something let into it rather than as another list.  The cursor
       row is then a light bar on that dark pane, and the idle one the same bar
       with its text dimmed - the pair is visible either way, and which tree the
       arrows will move is visible in the tree and not only in its frame. *)
    P(0, Tree, TuiCanv.LightGray, TuiCanv.Black);
    P(0, TreeSel, TuiCanv.Black, TuiCanv.LightGray);
    P(0, TreeSelIdle, TuiCanv.DarkGray, TuiCanv.LightGray);
    P(0, TreeBar, TuiCanv.White, TuiCanv.Black);
    P(0, TreeLine, TuiCanv.DarkGray, TuiCanv.Black);

    P(1, Desk, TuiCanv.LightGray, TuiCanv.Black);
    P(1, Frame, TuiCanv.LightGray, TuiCanv.Black);
    P(1, FrameActive, TuiCanv.Yellow, TuiCanv.Black);
    P(1, Title, TuiCanv.Black, TuiCanv.Yellow);
    P(1, TitleIdle, TuiCanv.LightGray, TuiCanv.Black);
    P(1, List, TuiCanv.White, TuiCanv.Black);
    P(1, ListSel, TuiCanv.Black, TuiCanv.White);
    P(1, ListSelIdle, TuiCanv.Black, TuiCanv.LightGray);
    P(1, ListBar, TuiCanv.LightGray, TuiCanv.Black);
    P(1, Menu, TuiCanv.LightGray, TuiCanv.Black);
    P(1, MenuHot, TuiCanv.Black, TuiCanv.White);
    P(1, MenuFrame, TuiCanv.LightGray, TuiCanv.Black);
    P(1, MenuSel, TuiCanv.Black, TuiCanv.White);
    P(1, Dialog, TuiCanv.LightGray, TuiCanv.Black);
    P(1, DialogFrame, TuiCanv.White, TuiCanv.Black);
    P(1, DialogText, TuiCanv.Black, TuiCanv.White);
    P(1, Button, TuiCanv.Green, TuiCanv.Black);
    P(1, ButtonDefault, TuiCanv.Black, TuiCanv.Green);
    P(1, ButtonHot, TuiCanv.Black, TuiCanv.Yellow);
    P(1, Field, TuiCanv.Black, TuiCanv.White);
    P(1, FieldSel, TuiCanv.White, TuiCanv.Black);
    P(1, FieldSelIdle, TuiCanv.Black, TuiCanv.LightGray);
    P(1, Check, TuiCanv.LightGray, TuiCanv.Black);
    P(1, CheckHot, TuiCanv.Black, TuiCanv.LightGray);
    P(1, Radio, TuiCanv.LightGray, TuiCanv.Black);
    P(1, RadioHot, TuiCanv.Black, TuiCanv.LightGray);
    P(1, Progress, TuiCanv.Black, TuiCanv.White);
    P(1, ProgressEmpty, TuiCanv.Black, TuiCanv.LightGray);
    P(1, Status, TuiCanv.Black, TuiCanv.LightGray);
    P(1, TableHead, TuiCanv.Yellow, TuiCanv.Black);
    P(1, TableHeadSel, TuiCanv.Black, TuiCanv.White);
    P(1, TableBody, TuiCanv.White, TuiCanv.Black);
    P(1, TableRowSel, TuiCanv.Black, TuiCanv.LightGray);
    P(1, TableRowSelIdle, TuiCanv.Black, TuiCanv.LightGray);
    P(1, TableBar, TuiCanv.LightGray, TuiCanv.Black);
    P(1, TableEdit, TuiCanv.White, TuiCanv.Black);
    P(1, Rule, TuiCanv.DarkGray, TuiCanv.Black);
    P(1, TextArea, TuiCanv.Black, TuiCanv.White);
    P(1, TextAreaSel, TuiCanv.White, TuiCanv.Black);
    P(1, TextAreaSelIdle, TuiCanv.Black, TuiCanv.LightGray);
    P(1, TextAreaBar, TuiCanv.LightGray, TuiCanv.Black);
    P(1, Combo, TuiCanv.Black, TuiCanv.White);
    P(1, ComboSel, TuiCanv.White, TuiCanv.Black);
    P(1, ComboSelIdle, TuiCanv.Black, TuiCanv.LightGray);
    P(1, ComboFrame, TuiCanv.LightGray, TuiCanv.Black);
    P(1, ComboList, TuiCanv.White, TuiCanv.Black);
    P(1, ComboListSel, TuiCanv.Black, TuiCanv.White);
    P(1, ComboBar, TuiCanv.LightGray, TuiCanv.Black);
    (* The mono theme is dark already, so the tree keeps the list's surface and
       says where it differs with its rules - which is the one thing a tree has
       that a list does not, and here it is drawn in the only dim colour the
       sixteen leave. *)
    P(1, Tree, TuiCanv.White, TuiCanv.Black);
    P(1, TreeSel, TuiCanv.Black, TuiCanv.White);
    P(1, TreeSelIdle, TuiCanv.Black, TuiCanv.LightGray);
    P(1, TreeBar, TuiCanv.LightGray, TuiCanv.Black);
    P(1, TreeLine, TuiCanv.DarkGray, TuiCanv.Black)
END Build;


(* The pair the current theme gives a slot.  Every drawing method calls this, so
   a theme switch shows itself on the next frame without anything being told. *)
PROCEDURE Attr* (slot: INTEGER): INTEGER;
VAR a: INTEGER;
BEGIN
    IF (slot >= 0) & (slot < NPAIR) THEN
        a := themes[cur].pairs[slot]
    ELSE
        a := TuiCanv.DEF_ATTR
    END;
    RETURN a
END Attr;


PROCEDURE Cur* (): INTEGER;
VAR i: INTEGER;
BEGIN
    i := cur;
    RETURN i
END Cur;


PROCEDURE Set* (i: INTEGER);
BEGIN
    IF (i >= 0) & (i < NTHEME) THEN
        cur := i
    END
END Set;


PROCEDURE Count* (): INTEGER;
VAR n: INTEGER;
BEGIN
    n := NTHEME;
    RETURN n
END Count;


PROCEDURE Name* (i: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
    IF i = 0 THEN
        Strings.Copy("Classic", s)
    ELSIF i = 1 THEN
        Strings.Copy("Mono", s)
    ELSE
        s[0] := 0X
    END
END Name;


(* Copy the theme in force into a caller's own table - how a window starts a
   private colour scheme.  From then on it is that window's, and a theme switch
   leaves it alone.

   The parameter is an open array because the dialect allows nothing else in a
   formal parameter position; what is copied is the shorter of the two, so a
   caller's table may be any size and is never overrun. *)
PROCEDURE Fill* (VAR pairs: ARRAY OF INTEGER);
VAR s, n: INTEGER;
BEGIN
    n := LEN(pairs);
    IF n > NPAIR THEN n := NPAIR END;
    FOR s := 0 TO n - 1 DO
        pairs[s] := themes[cur].pairs[s]
    END
END Fill;


BEGIN
    cur := 0;
    Build
END TuiTheme.
