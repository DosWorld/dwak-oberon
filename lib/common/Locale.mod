(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The names a date is written with, and which day a week starts on.

   A calendar is arithmetic and a locale is a decision, so the two are separate
   modules: Calendar answers how many days a month has and what weekday a date
   falls on, and this answers what those things are called and where a week
   begins.  Neither knows about the other.

   There is one set of names for the whole program.  That is the decision the
   module is built on: a widget that draws a month name asks here, at the
   moment it draws, so a program that changes its locale is showing the new
   names on the next frame - nothing is copied into a widget, and there is no
   second place a name could be stale.  TuiTheme is the same shape for the same
   reason.

   The names are held in a record rather than in module variables because a
   program may want more than one set at a time - the sample keeps two and
   swaps between them - and Set and Get are how a whole set is installed or
   taken.  The accessors are what a widget uses; Set and Get are for a caller
   that keeps a set of its own.

   The weekday table counts from Monday, 0..6, which is Calendar.DayOfWeek's
   own numbering.  Which end of it a week is *drawn* from is mondayFirst: a
   calendar whose first column is Monday starts at 0 and one whose first column
   is Sunday starts at 6, so the flag turns the table and nothing else.

   The tables are filled by assignment - the dialect has no array initialiser -
   so Default is a list of assignments and the module body calls it.  A name
   longer than its slot is cut by Strings.Copy, which stops at the room it has
   and terminates; the slots are wide enough for a full English name and a
   console cell is one byte, so an accented name in a DOS code page fits too.
*)

MODULE Locale;

IMPORT Strings;

CONST
    MONLEN* = 16;                   (* bytes a month name takes, its 0X included *)
    DAYLEN* = 16;                   (* the same for a weekday name *)
    MONTHS* = 12;
    DAYS* = 7;

TYPE

    (* A whole set of names and the week's first day.  A record and not a set
       of module variables because a caller may keep more than one: Get takes
       the set in force, the caller changes what it likes, and Set installs it. *)
    Names* = RECORD
        month*: ARRAY MONTHS OF ARRAY MONLEN OF CHAR;    (* 1 is January *)
        day*:   ARRAY DAYS OF ARRAY DAYLEN OF CHAR;      (* 0 is Monday *)
        mondayFirst*: BOOLEAN                            (* the week starts on Monday *)
    END;

VAR
    cur: Names;                     (* the set in force, and the only one *)


(* The name of a month, 1..12.  A month outside that range - which a caller
   computing one itself can produce - answers an empty string rather than a
   name off the end of the table. *)
PROCEDURE Month* (m: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
    IF (m >= 1) & (m <= MONTHS) THEN
        Strings.Copy(cur.month[m - 1], s)
    ELSIF LEN(s) > 0 THEN
        s[0] := 0X
    END
END Month;


(* The name of a weekday, 0..6, Monday first. *)
PROCEDURE Day* (d: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
    IF (d >= 0) & (d < DAYS) THEN
        Strings.Copy(cur.day[d], s)
    ELSIF LEN(s) > 0 THEN
        s[0] := 0X
    END
END Day;


PROCEDURE MondayFirst* (): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := cur.mondayFirst;
    RETURN r
END MondayFirst;


PROCEDURE SetMonth* (m: INTEGER; name: ARRAY OF CHAR);
BEGIN
    IF (m >= 1) & (m <= MONTHS) THEN
        Strings.Copy(name, cur.month[m - 1])
    END
END SetMonth;


PROCEDURE SetDay* (d: INTEGER; name: ARRAY OF CHAR);
BEGIN
    IF (d >= 0) & (d < DAYS) THEN
        Strings.Copy(name, cur.day[d])
    END
END SetDay;


PROCEDURE SetMondayFirst* (on: BOOLEAN);
BEGIN
    cur.mondayFirst := on
END SetMondayFirst;


(* Install a whole set at once, and take the one that stands. *)
PROCEDURE Set* (VAR n: Names);
BEGIN
    cur := n
END Set;


PROCEDURE Get* (VAR n: Names);
BEGIN
    n := cur
END Get;


(* The names this module starts with: the English ones, and a week that begins
   on Monday.  Another language is SetMonth and SetDay, or a whole Names filled
   in by the caller and handed to Set - nothing here has to know about it. *)
PROCEDURE Default*;
BEGIN
    SetMonth(1, "January");
    SetMonth(2, "February");
    SetMonth(3, "March");
    SetMonth(4, "April");
    SetMonth(5, "May");
    SetMonth(6, "June");
    SetMonth(7, "July");
    SetMonth(8, "August");
    SetMonth(9, "September");
    SetMonth(10, "October");
    SetMonth(11, "November");
    SetMonth(12, "December");
    SetDay(0, "Monday");
    SetDay(1, "Tuesday");
    SetDay(2, "Wednesday");
    SetDay(3, "Thursday");
    SetDay(4, "Friday");
    SetDay(5, "Saturday");
    SetDay(6, "Sunday");
    SetMondayFirst(TRUE)
END Default;

BEGIN
    Default
END Locale.
