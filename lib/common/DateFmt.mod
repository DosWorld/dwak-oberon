(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   One date as text: YYYY-MM-DD, ten characters and nothing else.  Four digits
   of the year, a hyphen, two of the month, a hyphen, two of the day - no
   leading or trailing blank, no shortened field, no other separator.  A string
   that is not of that shape is not a date here, however close it looks.

   Parse answers whether a string is such a date and, when it is, hands the
   three numbers back in a Calendar.Date.  It is a strict reading of the text
   and of the calendar both: a string of another length, a separator somewhere
   else, a character that is not a digit, and a date the calendar does not have
   - month 13, day 0, 31 April, 29 February in a year that is not a leap one -
   all answer FALSE.  Whether a string is a date is not a question about its
   ten characters alone.  The date is written only when TRUE is answered, so a
   caller that lets the answer go keeps the date it had.

   Format is the other direction, and it checks rather than corrects: a date
   the calendar does not have, and a year outside 0000..9999, trip an ASSERT.
   Its result is always ten characters with the zeros written out, which is
   what makes the two agree - Parse(Format(d)) gives back the same day, month
   and year for every date Format accepts.

   The text is also the sort order, which is why the year leads: these ten
   bytes compare as plain bytes in the order the dates are in.

   Two things about this dialect shape the code.  The length of the text is
   measured the way Strings.Length measures it, because LEN of an open array is
   the room the caller has and not the length of what is in it - and the ten
   characters are read only once the length has answered ten.  And RETURN ends
   a function body and nothing else, so every helper here computes into a
   variable and falls through to one trailing RETURN.
*)

MODULE DateFmt;

IMPORT Calendar;

CONST
    DATELEN = 10;                   (* bytes a date takes, YYYY-MM-DD included *)


(* A decimal digit as a number, or -1 when the character is not one.  The
   answer is negative rather than a flag so that a caller can carry it in its
   accumulator and test it once, at the end. *)
PROCEDURE Digit(ch : CHAR):INTEGER;
VAR n: INTEGER;
BEGIN
    n := -1;
    IF (ch >= "0") & (ch <= "9") THEN
        n := ORD(ch) - ORD("0")
    END;
    RETURN n
END Digit;


(* The n digits at s[at ..] as a number, or -1 when any of them is not a
   digit.  The sign is the accumulator: a bad digit makes the whole answer -1
   and a later good one cannot revive it. *)
PROCEDURE Num(s : ARRAY OF CHAR; at, n : INTEGER):INTEGER;
VAR i, v, d: INTEGER;
BEGIN
    v := 0;
    FOR i := 0 TO n - 1 DO
        d := Digit(s[at + i]);
        IF d < 0 THEN
            v := -1
        ELSIF v >= 0 THEN
            v := v * 10 + d
        END
    END;
    RETURN v
END Num;


(* n as exactly two digits at s[at] and s[at + 1], 0..99 assumed. *)
PROCEDURE Put2(VAR s : ARRAY OF CHAR; at, n : INTEGER);
BEGIN
    s[at] := CHR(ORD("0") + n DIV 10 MOD 10);
    s[at + 1] := CHR(ORD("0") + n MOD 10)
END Put2;


(* y as exactly four digits at s[at] and the three cells after it, 0..9999
   assumed.  The year is written out digit by digit rather than as a number,
   because a leading zero is part of the text and not padding. *)
PROCEDURE Put4(VAR s : ARRAY OF CHAR; at, y : INTEGER);
BEGIN
    s[at] := CHR(ORD("0") + y DIV 1000 MOD 10);
    s[at + 1] := CHR(ORD("0") + y DIV 100 MOD 10);
    s[at + 2] := CHR(ORD("0") + y DIV 10 MOD 10);
    s[at + 3] := CHR(ORD("0") + y MOD 10)
END Put4;

PROCEDURE Parse*(str : ARRAY OF CHAR; VAR date : Calendar.Date):BOOLEAN;
VAR n, y, m, d: INTEGER; ok: BOOLEAN;
BEGIN
    n := 0;
    WHILE (n < LEN(str)) & (str[n] # 0X) DO INC(n) END;

    (* The shape is tested before the characters are read, so that the six
       digits below are always read from a string that has them: str[7] of a
       five character string is past its end. *)
    ok := n = DATELEN;
    IF ok THEN
        IF (str[4] = "-") & (str[7] = "-") THEN
            y := Num(str, 0, 4);
            m := Num(str, 5, 2);
            d := Num(str, 8, 2);

            (* Three tests and not one: the month has to be known good before
               DaysIn is asked what it holds, or February of month 13 would be
               answered for.

               The year starts at 1 and not at 0, and that is a range the string
               cannot state: four digits can spell 0000, and the Gregorian rule
               this calendar uses makes year 0 a leap year, so 0000-02-29 passed
               every test here and reached a widget whose own range - see
               TuiDate.ClampDate - begins at 1.  A date this module accepts has
               to be one the calendar it feeds will agree with. *)
            ok := (y >= 1) & (m >= 1) & (m <= 12) & (d >= 1);
            IF ok THEN
                ok := d <= Calendar.DaysIn(y, m)
            END
        ELSE
            ok := FALSE
        END
    END;

    IF ok THEN
        date.day := d;
        date.month := m;
        date.year := y
    END;
    RETURN ok
END Parse;


PROCEDURE Format*(date : Calendar.Date; VAR str : ARRAY OF CHAR);
VAR y: INTEGER;
BEGIN
    ASSERT(LEN(str) > DATELEN);         (* ten characters and a 0X *)
    y := date.year;
    ASSERT((y >= 0) & (y <= 9999));
    ASSERT((date.month >= 1) & (date.month <= 12));
    ASSERT((date.day >= 1) & (date.day <= Calendar.DaysIn(y, date.month)));

    Put4(str, 0, y);
    str[4] := "-";
    Put2(str, 5, date.month);
    str[7] := "-";
    Put2(str, 8, date.day);
    str[DATELEN] := 0X
END Format;

END DateFmt.
