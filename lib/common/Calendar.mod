(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.
*)
MODULE Calendar;

TYPE

Date* = RECORD
     day*, month*, year* : INTEGER
END;

Time* = RECORD
     hours*, minutes*, seconds* : INTEGER
END;

DateTime* = RECORD
    time* : Time;
    date* : Date
END;


(* Whether year is a leap year: every fourth, but not every hundredth, unless
   it is also every four hundredth.  Year 0 is a leap year, as the rule says. *)
PROCEDURE Leap*(year : INTEGER):BOOLEAN;
VAR r: BOOLEAN;
BEGIN
    r := (year MOD 4 = 0) & (year MOD 100 # 0) OR (year MOD 400 = 0);
    RETURN r
END Leap;


(* The days of a month of a year.  February is the only one a year changes, so
   it is the only one that has to be asked about; the month is assumed to be
   1..12. *)
PROCEDURE DaysIn*(year, month : INTEGER):INTEGER;
VAR n: INTEGER;
BEGIN
    IF month = 2 THEN
        IF Leap(year) THEN n := 29 ELSE n := 28 END
    ELSIF (month = 4) OR (month = 6) OR (month = 9) OR (month = 11) THEN
        n := 30
    ELSE
        n := 31
    END;
    RETURN n
END DaysIn;


(* The day of the week of a date: 0 is Monday and 6 is Sunday, which is the
   numbering a week of seven names is read in and the one a locale's own table
   is kept in.  Which day a week starts on is not a calendar's business - it is
   the locale's - so this answers the weekday and nothing else.

   Sakamoto's rule: shift the year back for January and February - the two
   months that end a year, so that the leap day falls at the end of the shifted
   one - add a month offset from the table below, and take the total modulo
   seven.  That counts from Sunday, so the last line turns it round to count
   from Monday.  The table is a chain of tests rather than an array because a
   module-level array can only be filled by assignment, and four lines that
   never run are cheaper than a variable this module does not otherwise need.

   Gregorian, and the year is assumed to be 1..9999 - below that a division
   rounds the wrong way and the answer is off. *)
PROCEDURE DayOfWeek*(year, month, day : INTEGER):INTEGER;
VAR y, t, n: INTEGER;
BEGIN
    y := year;
    IF month < 3 THEN DEC(y) END;
    IF month = 1 THEN t := 0
    ELSIF month = 2 THEN t := 3
    ELSIF month = 3 THEN t := 2
    ELSIF month = 4 THEN t := 5
    ELSIF month = 5 THEN t := 0
    ELSIF month = 6 THEN t := 3
    ELSIF month = 7 THEN t := 5
    ELSIF month = 8 THEN t := 1
    ELSIF month = 9 THEN t := 4
    ELSIF month = 10 THEN t := 6
    ELSIF month = 11 THEN t := 2
    ELSE t := 4
    END;
    n := (y + y DIV 4 - y DIV 100 + y DIV 400 + t + day) MOD 7;    (* 0 = Sunday *)
    n := (n + 6) MOD 7;                                            (* 0 = Monday *)
    RETURN n
END DayOfWeek;

END Calendar.