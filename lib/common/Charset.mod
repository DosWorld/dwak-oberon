MODULE Charset;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A code page: which page a name means, what a byte of one draws, and which
   byte draws a code point.

   This module holds no setting and knows no screen.  Which page anything uses
   is the caller's business, and the callers do not agree on how many there
   are: the framework keeps TWO - the page its host draws in and the page its
   own text bytes mean - and a QuickHelp reader keeps one, named on a command
   line, with no screen anywhere near it.  Both import this, and neither has to
   know about the other.

   THE SPLIT, AND WHY IT IS ONE.

   The tables were never the framework's.  Cp437 and Cp866 are in lib/common
   beside this file, and this is the dispatcher over them and nothing more.
   It used to live inside TuiPage, which is the framework's two settings - so a
   .hlp converter that wanted a byte table had to import a screen framework to
   get one, the whole of tui through a single constant.  That dependency
   pointed the wrong way.  It points this way now: TuiPage imports Charset,
   and Charset imports nothing but the two tables and Strings.

   ASCII NEEDS NO PAGE.  20H through 7EH draw themselves on every page there
   is; only 01H to 1FH and 7FH differ, because those are the glyphs the VGA
   font puts at them and every OEM page was built on that font.  So a byte in
   that range needs no table to be read and a code point in it needs none to be
   written, which is both the common case by far and the fast one.

   A PAGE THIS BUILD HAS NOT GOT IS NOT AN ERROR HERE.  PointOf answers the
   byte itself and ByteOn answers -1, which a caller writes as the '?' it has
   always written.  A page name is a setting, and a setting can come off a
   command line; a program handed one it does not know should draw something
   and say so rather than refuse to start.  A converter is the one caller that
   must refuse instead - a database read in the wrong page is not a failure, it
   is a file of wrong characters - and it gets that by asking ByName and
   checking the answer itself, which is what HlpPage.FromArgs does.
*)

IMPORT Strings, Cp437, Cp866;

CONST
    (* The pages a screen can be set to.  Named Page* and not Cp*, because Cp437
       and Cp866 are the modules that carry them and a constant of that name
       here would stand in front of the module at every use. *)
    Page437* = 0;
    Page866* = 1;
    PageUnicode* = 2;                   (* the host draws code points itself *)
    PageUtf8* = 3;                      (* text, not a screen: 1 to 4 bytes
                                           to the character *)

    (* PageUnicode IS NOT UTF-8, and the difference is the whole of why
       PageUtf8 exists.

       As a SCREEN page Unicode says "the host draws code points itself" - a
       Windows console, which wants a WCHAR and not a byte.  As a TEXT page it
       is the reading in which one byte is one code point, which is Latin-1:
       PointOf answers the byte unchanged for 0..0FFH and the page can hold
       nothing above it.

       UTF-8 has neither property.  One character is one to four bytes, so a
       byte of it is not a character and PointOf cannot be asked about one at
       all - which is what Decode below is for.  A file in UTF-8 read as
       PageUnicode is therefore not slightly wrong: every byte above 7FH
       becomes a Latin-1 letter that the file never meant, so a Chinese
       article reads as runs of accented vowels and a Russian one as a wall of
       them.  ByName used to answer PageUnicode for the name "utf8" - see
       there. *)

    (* What every page there is draws as the ASCII it is.  Only 01H to 1FH and
       7FH differ between OEM pages, because those are the VGA font's own
       glyphs; 20H through 7EH are the same character everywhere.  So a byte
       here needs no page to be read and a code point here needs no page to be
       written, which is both the common case by far and the fast one. *)
    ASCII_LO* = 20H;
    ASCII_HI* = 7EH;

VAR
    (* THE REVERSE TABLE, and it is here and not in Cp437 or Cp866 because it
       is a *speed* decision and those two are correct without it.

       Cp437.ByteOf and Cp866.ByteOf search their page a byte at a time.  That
       is right for what they were written for - a paste, a copy, a few hundred
       characters once - and it is far too slow here: the screen converts one
       cell at a time on a host that is not wide, two thousand cells a frame,
       and a search of two hundred and fifty-six entries each is half a million
       calls a frame.

       So the page in use is turned round once, into a sorted list of the two
       hundred and fifty-six code points it draws and the byte of each, and a
       lookup is a binary search of eight steps.  It cannot come to disagree
       with PointOf, because it is built FROM PointOf - the same property the
       searched form has, arrived at the other way.

       Built when the page asked for is not the page it holds.  A program
       converts with one page at a time - the screen with the screen's, a dump
       with the dump's - so that is one build per page per run and not one per
       cell.  A caller that alternated pages cell by cell would rebuild it cell
       by cell, which is the one way to make this slower than the search it
       replaced; nothing does and nothing should. *)
    revPage: INTEGER;                   (* which page the table holds, -1 none *)
    revKeys: ARRAY 100H OF INTEGER;     (* its code points, ascending *)
    revVal: ARRAY 100H OF BYTE;         (* and the byte that draws each *)


(* The code point of one byte of `page`, which is what turns a byte into
   something a canvas or a Markdown file can hold.  A byte of a page this build
   has not got is itself, so a program that never sets a page draws its own
   ASCII correctly whatever happens. *)
PROCEDURE PointOf* (b, page: INTEGER): INTEGER;
VAR cp: INTEGER;
BEGIN
    IF page = Page437 THEN
        cp := Cp437.Point(b)
    ELSIF page = Page866 THEN
        cp := Cp866.Point(b)
    ELSIF (b >= 0) & (b <= 0FFH) THEN
        cp := b                        (* Unicode, or a page nobody carries *)
    ELSE
        cp := 0
    END;

    RETURN cp
END PointOf;


(* Turn `page` round into revKeys and revVal, which is what the reverse table
   is for and why it is here rather than in Cp437 or Cp866.

   Those two search their page a byte at a time.  That is right for what they
   were written for - a paste, a copy, a few hundred characters once - and it
   is far too slow for this: the screen converts one cell at a time on a host
   that is not wide, two thousand cells a frame, and a search of two hundred and
   fifty-six entries each is half a million calls a frame.  So the page in
   use is turned round once, into a sorted list of the two hundred and fifty-six
   code points it draws and the byte of each, and a lookup is a binary search of
   eight steps.  It cannot come to disagree with PointOf, because it is built FROM
   PointOf - the same property the searched form has, arrived at the other way.

   An insertion sort, and it is the right one here: two hundred and fifty-six
   entries, done once per page per run, on a list that is already nearly in
   order for most of a code page's low half.  A better sort would be a longer
   thing to read for a cost nobody measures. *)
PROCEDURE BuildRev (page: INTEGER);
VAR b, i, j, k, v: INTEGER;
BEGIN
    FOR b := 0 TO 0FFH DO
        revKeys[b] := PointOf(b, page);
        revVal[b] := b
    END;
    FOR i := 1 TO 0FFH DO
        k := revKeys[i];
        v := revVal[i];
        j := i - 1;
        WHILE (j >= 0) & (revKeys[j] > k) DO
            revKeys[j + 1] := revKeys[j];
            revVal[j + 1] := revVal[j];
            DEC(j)
        END;
        revKeys[j + 1] := k;
        revVal[j + 1] := v
    END;
    revPage := page
END BuildRev;


(* The byte drawing cp in the table the caller has already made current, or -1.
   Eight steps and no call, which is what makes a frame affordable. *)
PROCEDURE Seek (cp: INTEGER): INTEGER;
VAR lo, hi, mid, r: INTEGER;
BEGIN
    r := -1;
    lo := 0;
    hi := 0FFH;
    WHILE lo <= hi DO
        mid := (lo + hi) DIV 2;
        IF revKeys[mid] = cp THEN
            r := revVal[mid];
            lo := hi + 1                (* found: leave the loop at its top *)
        ELSIF revKeys[mid] < cp THEN
            lo := mid + 1
        ELSE
            hi := mid - 1
        END
    END;

    RETURN r
END Seek;


(* The byte of `page` that draws this code point, or -1 when the page has not
   got it.  The caller writes the '?' it has always written.

   The page asked for is not always the screen's - a dump is 866 whatever the
   host is - so the table is rebuilt whenever the request changes page.  A
   program converts with one page at a time, screen with screen and dump with
   dump, so that is one rebuild per page per run and never one per cell.  A
   caller that alternated pages cell by cell would rebuild it cell by cell,
   which is the one way to make this slower than the search it replaced;
   nothing does and nothing should. *)
PROCEDURE ByteOn* (cp, page: INTEGER): INTEGER;
VAR b: INTEGER;
BEGIN
    IF (cp >= ASCII_LO) & (cp <= ASCII_HI) THEN
        b := cp                         (* every page draws these as themselves *)
    ELSE
        IF revPage # page THEN BuildRev(page) END;
        b := Seek(cp)
    END;

    RETURN b
END ByteOn;


(* Two strings equal, terminators and all.  A nested procedure cannot see the
   parameters of the one around it in this language, so this is at module level
   and takes both of them. *)
PROCEDURE Same (a, b: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER; r: BOOLEAN;
BEGIN
    i := 0;
    WHILE (i < LEN(a)) & (i < LEN(b)) & (a[i] # 0X) & (a[i] = b[i]) DO
        INC(i)
    END;
    r := (i < LEN(a)) & (i < LEN(b)) & (a[i] = 0X) & (b[i] = 0X);
    RETURN r
END Same;


(* A page name off a command line.  Answers -1 for a name this build does not
   know, and the name is matched exactly and in lower case - a setting is
   written once and a case-insensitive match would only make it harder to say
   which spellings work. *)
PROCEDURE ByName* (name: ARRAY OF CHAR): INTEGER;
VAR page: INTEGER;
BEGIN
    page := -1;
    IF Same(name, "437") OR Same(name, "cp437") OR Same(name, "oem437") THEN
        page := Page437
    ELSIF Same(name, "866") OR Same(name, "cp866") OR Same(name, "oem866") THEN
        page := Page866
    ELSIF Same(name, "unicode") OR Same(name, "wide") THEN
        page := PageUnicode
    ELSIF Same(name, "utf8") OR Same(name, "utf-8") THEN
        (* These two used to answer PageUnicode, and that was a lie with a
           symptom: a .hlp read as "utf8" came out in Latin-1, every byte above
           7FH a different letter, and nothing said so.  A database read in
           the wrong page is not a failure - it is a file of wrong characters,
           which is exactly the shape of error that never gets reported.  The
           name is the reader's to give and it means what it says now. *)
        page := PageUtf8
    END;

    RETURN page
END ByName;


(* How a page is spelled back to a user.  Copied field by field and not
   assigned: a string literal does not assign to an open array parameter in
   this language, which is a rule about the parameter and not about the text. *)
PROCEDURE Name* (page: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
    IF page = Page437 THEN
        Strings.Copy("437", s)
    ELSIF page = Page866 THEN
        Strings.Copy("866", s)
    ELSIF page = PageUnicode THEN
        Strings.Copy("unicode", s)
    ELSIF page = PageUtf8 THEN
        Strings.Copy("utf8", s)
    ELSE
        Strings.Copy("?", s)
    END
END Name;


(* One character of a byte string, and how many bytes it took.

   This is the reading a page of variable width needs, and it is why PointOf
   cannot serve.  PointOf answers about ONE byte, and a page it can do that for
   is one where a byte is a character - 437, 866, and Unicode-as-Latin-1.  UTF-8
   is not such a page: a character is one to four bytes and no single byte of it
   means anything, so a reader has to be told the code point AND where the next
   one begins.  Both come out of here, and a caller walking a string advances i
   by len and never by one.

   Every other page answers len = 1 and the code point PointOf gives, so a
   walker written against this call reads 437 and 866 and Latin-1 exactly as it
   did before - which is what keeps the single-width readers honest and is the
   property the whole change rests on.

   A sequence that is not UTF-8 - a continuation byte where a lead belongs, one
   truncated at the end of the buffer, an overlong form, a surrogate - is one
   U+FFFD and len = 1.  len = 1 is deliberate: zero would stop a walker dead,
   and a length that swallowed the following bytes would hide a real character
   behind a broken one.  The character after a bad byte is still read. *)
PROCEDURE Decode* (b: ARRAY OF CHAR; i, page: INTEGER; VAR cp, len: INTEGER);
VAR b0, u, n, k: INTEGER;
    ok: BOOLEAN;
BEGIN
    cp := 0FFFDH;
    len := 1;
    IF (i < 0) OR (i >= LEN(b)) THEN
        ok := FALSE                    (* past the caller's buffer: nothing *)
    ELSIF page # PageUtf8 THEN
        cp := PointOf(ORD(b[i]), page);
        ok := TRUE
    ELSE
        ok := TRUE;
        b0 := ORD(b[i]);
        IF b0 < 80H THEN
            cp := b0                   (* the one length every page agrees on *)
        ELSE
            IF (b0 >= 0C0H) & (b0 < 0E0H) THEN
                n := 2; u := b0 MOD 20H
            ELSIF (b0 >= 0E0H) & (b0 < 0F0H) THEN
                n := 3; u := b0 MOD 10H
            ELSIF (b0 >= 0F0H) & (b0 < 0F8H) THEN
                n := 4; u := b0 MOD 8H
            ELSE
                n := 0                 (* a continuation byte, or 0FEH/0FFH *)
            END;
            IF n = 0 THEN
                ok := FALSE
            ELSIF i + n > LEN(b) THEN
                ok := FALSE            (* truncated at the end of the buffer *)
            ELSE
                k := 1;
                WHILE ok & (k < n) DO
                    (* A NUL is not a continuation byte, so a line that ends
                       inside a sequence fails here and not at the caller. *)
                    IF (ORD(b[i + k]) >= 80H) & (ORD(b[i + k]) < 0C0H) THEN
                        u := u * 40H + (ORD(b[i + k]) MOD 40H)
                    ELSE
                        ok := FALSE
                    END;
                    INC(k)
                END;
                IF ok THEN
                    cp := u;
                    len := n
                END
            END
        END
    END;
    IF ok & (page = PageUtf8) THEN
        (* The forms UTF-8 forbids.  A surrogate is refused because a canvas
           cell is a WCHAR and a surrogate is half of one, and an overlong form
           because two encodings of one character is how a filter is walked
           past.  Both are answered as a broken byte is. *)
        IF (cp > 10FFFFH) OR ((cp >= 0D800H) & (cp <= 0DFFFH)) THEN
            cp := 0FFFDH; len := 1
        ELSIF ((len = 2) & (cp < 80H)) OR ((len = 3) & (cp < 800H))
            OR ((len = 4) & (cp < 10000H)) THEN
            cp := 0FFFDH; len := 1
        END
    END
END Decode;


(* How many bytes the UTF-8 encoding of a code point takes, and 0 for a value
   that is not one.

   The same question Encode answers, asked without a buffer, and it is the same
   table and not a second guess at it - Encode is written in terms of this, so
   a caller that measures with Width and writes with Encode gets exactly the
   count it measured.  That is what a caller appending into a buffer it must
   not overrun needs: it can decide whether the whole of something fits BEFORE
   writing the first byte of it, which is the only way to keep a partly written
   string out of the buffer.

   The refusals are Encode's refusals and are named there. *)
PROCEDURE Width* (cp: INTEGER): INTEGER;
VAR n: INTEGER;
BEGIN
    IF cp < 0 THEN
        n := 0                          (* not a code point at all *)
    ELSIF cp < 80H THEN
        n := 1
    ELSIF cp < 800H THEN
        n := 2
    ELSIF (cp >= 0D800H) & (cp <= 0DFFFH) THEN
        n := 0                          (* half of a pair, so not a character *)
    ELSIF cp < 10000H THEN
        n := 3
    ELSIF cp < 110000H THEN
        n := 4
    ELSE
        n := 0                          (* past the last plane *)
    END;

    RETURN n
END Width;


(* The UTF-8 encoding of one code point, written into dst at i, and how many
   bytes it took.  i is advanced, so a caller building a string in a loop calls
   this once per character and watches only the buffer's end.

   THE ONE ENCODER.  There were three of these: Cp437.Emit and Files.EmitUtf8,
   both private and each doing this same arithmetic for its own caller, and
   MuInput.Utf8, which is public and the only complete one - it is what a
   microui text box types through.  The arithmetic is about the encoding and not
   about any page, so it belongs to the module the pages live in, and a fourth
   copy is what the next page would have become.  MuInput.Utf8 calls this now.

   Answers 0 and writes nothing for something that is not a code point -
   negative, a surrogate, or past the last plane.  i does not move, which is how
   the caller knows nothing was written.

   The four cases are Width's four answers, and the branches below are keyed on
   them rather than on the ranges again, so the table of ranges is written once
   in this module and the two cannot come to disagree. *)
PROCEDURE Encode* (cp: INTEGER; VAR dst: ARRAY OF CHAR; VAR i: INTEGER): INTEGER;
VAR n: INTEGER;
BEGIN
    n := Width(cp);
    IF n = 1 THEN
        dst[i] := CHR(cp)
    ELSIF n = 2 THEN
        dst[i] := CHR(0C0H + cp DIV 40H);
        dst[i + 1] := CHR(80H + cp MOD 40H)
    ELSIF n = 3 THEN
        dst[i] := CHR(0E0H + cp DIV 1000H);
        dst[i + 1] := CHR(80H + cp DIV 40H MOD 40H);
        dst[i + 2] := CHR(80H + cp MOD 40H)
    ELSIF n = 4 THEN
        dst[i] := CHR(0F0H + cp DIV 40000H);
        dst[i + 1] := CHR(80H + cp DIV 1000H MOD 40H);
        dst[i + 2] := CHR(80H + cp DIV 40H MOD 40H);
        dst[i + 3] := CHR(80H + cp MOD 40H)
    END;
    i := i + n;
    RETURN n
END Encode;


BEGIN
    (* The reverse table holds nothing yet, and that has to be said out loud.
       A module variable of an ordinal type is zero and Page437 IS zero, so
       leaving this alone makes the first request for 437 compare equal to the
       page the table is supposed to hold, skip the build, and search a table
       of two hundred and fifty-six zeros - for the whole run, since the build
       that would have set revPage is the one that was skipped.  The symptom is
       a page that converts correctly for ASCII, which needs no table at all,
       and answers -1 for every byte above it: measured, one hundred and sixty
       of the two hundred and fifty-six bytes of 437 wrong, which is exactly
       the count below 20H.  -1 is a page number no page has. *)
    revPage := -1
END Charset.
