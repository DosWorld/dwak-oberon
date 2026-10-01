(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    A small reader for the .ini files this tree's programs take their
    settings from: `[section]` headings, `key = value` pairs, and `;` or `#`
    at the start of a line for a comment.  Portable - it reads through Files
    and names no platform at all - so a program that uses it uses it the same
    way on every target.

    The file is read ONCE, into one buffer, and every question is answered by
    walking that buffer.  The two other shapes are worse.  A handle-based
    reader would have to re-open or seek for each lookup.  An array of parsed
    entries would be a second copy of what the buffer already holds, with a
    fixed ceiling on the number of keys besides - and the buffer is the
    cheaper of the two at run time even though the entry array would be the
    smaller of the two to write.

    There are two buffers, sized differently, and a file that does not fit in
    them is refused rather than cut.  The part that was dropped would be
    whichever sections came last - for a theme file, whole themes - and a
    program that quietly ran on the defaults while the settings it was given
    said otherwise is worse than one that says the file was too long.  Two and
    not one because the file is decoded into the second: a UTF-16 file is
    converted to UTF-8 as it is read, and the conversion grows a character to
    three bytes where the source had two, so it cannot be done in place.  And
    because it grows, the second buffer is the larger of the two - see the
    constants for the arithmetic.

    SIZE IS NOT THE COMPILER'S BUSINESS HERE, and the measurement is worth
    writing down exactly, because it is true of the file and not of the image.
    A zero-filled module array is uninitialised data: the image records how
    much of it there is and does not write it out, so the file does not grow
    by the size of these buffers.  Measured at MaxBytes 1024, at 131072 and at
    262144, on _probe/IniTest: the image is 34816 bytes for win64con and 36864
    for dpmi32pe at all three, to the byte.  What does change is the header -
    SizeOfImage, 516096 to 843776 on win64con and 454656 to 782336 on dpmi32pe
    between the last two sizes - and every relocation that addresses a buffer,
    so the images at two sizes are the same length and are not the same bytes.
    What the buffers cost is run-time memory, which is why they are sized for
    the files this tree actually reads rather than made generous.

    THE FILE MAY BE UNICODE.  A settings file is edited by hand in whatever
    editor the machine has, and Notepad's "Unicode" is UTF-16 with a byte
    order mark, so the reader knows three encodings rather than one: plain
    bytes (ASCII, and UTF-8, which is bytes), UTF-16 little-endian and UTF-16
    big-endian.  The two UTF-16 forms are recognised by the mark they open
    with - FFH FEH and FEH FFH - and a UTF-8 file by its own mark, EFH BBH
    BFH, which is skipped.  UTF-16 is converted to UTF-8 as it is read, so the
    rest of this module never learns which of the three it was handed.

    Nothing else is done about encodings, and one thing is done on purpose: a
    NUL is dropped wherever it appears.  That is what reads a UTF-16 file
    whose mark was stripped - the tail of every other byte of an ASCII file
    is a NUL, and dropping those leaves exactly the text - and it is also what
    keeps a stray NUL in an eight-bit file out of the line it sits on.

    Lines are terminated by CR, LF or CRLF - all three, because all three
    arrive - and held with a 0DX after each, which is the one character a text
    file cannot contain, and a line is copied out into the caller's variable
    rather than pointed at.  Section and key names are compared without
    regard to case, which is the convention for the format and the reason
    `[Common]` and `gui.Theme` are the same question as `[common]` and
    `gui.theme`.  Values are not case-folded: a value is whatever was
    written.

    Comments are whole lines.  A `;` or `#` in the middle of a value is part
    of the value, so a colour is written `#RRGGBB` and not quoted to keep the
    `#` - the `#` only opens a comment at the start of a line, after leading
    spaces.
*)

MODULE IniReader;

IMPORT Files, Strings;


CONST

    (* The file, and the text decoded from it.  Two sizes, because the
       encodings disagree at both ends.

       The form designer's theme file is the large file this tree reads, and
       by a long way: eight themes naming every colour and every nuance of
       every one of them is 67060 bytes with its comments, which is the
       measurement MaxBytes was sized from rather than a guess.  A settings
       file is edited by hand, though, and an editor that saves "Unicode"
       saves UTF-16 - two bytes for every character - so the same file comes
       back at 134122 bytes.  That is the number that matters and the number
       that has already bitten: at 128 KB the file itself was read and its
       UTF-16 form was refused with `is too long`, which is the one encoding
       the seventh theme had left room for.

       MaxBytes is a round 256 KB.  Measured: a theme of this size costs
       about 14000 bytes of UTF-16 - the nine sections of the file run from
       5814 to 9677 bytes in UTF-8, and the header is 7471 - so the file could
       grow to nine more themes of this size before the number is in question
       again.  The point of writing the arithmetic down is that the next
       person to add a theme measures instead of assuming; the point of the
       number being twice what it was is that a check which fails on a user's
       own saved file is worse than a buffer nobody fills.

       MaxText is the bound the conversion itself imposes, not a round number.
       One UTF-16 code unit is two bytes and becomes at most three bytes of
       UTF-8 - that is the wide characters, 0800H and above - so the text is
       at most one and a half times the bytes it came from, and two more bytes
       are the terminator the last line may need.  That is what covers any
       file that fits in MaxBytes.  PutByte refuses rather than overruns if
       the arithmetic is ever wrong, so this is a space decision and never a
       safety one.

       See the header: the size of these arrays is not the size of any image. *)
    MaxBytes = 262144;
    MaxText  = MaxBytes * 3 DIV 2 + 2;

    (* Which encoding the file was written in.  Recognised from the byte
       order mark and from nothing else; see the header. *)
    Enc8    = 0;
    Enc16LE = 1;
    Enc16BE = 2;

    (* section names, keys and values, each in one. *)
    MaxName = 64;
    MaxValue = 256;

    (* The most lines the index can hold.  A line is at least two characters
       in buf - one of them and its 0DX - so the whole of MaxText could hold
       more lines than this, and unlike the buffers this one is a policy and
       not a bound.  A theme file of 256 KB has some eight thousand lines; this
       is twice that.  Past it the file is refused and not read on: a
       line with no index entry is a line whose text is the previous line's,
       and answering a lookup with the wrong text is the one failure worth
       more than the file. *)
    MaxLines = 16384;


VAR

    raw:    ARRAY MaxBytes OF CHAR;     (* the file exactly as it lies *)
    buf:    ARRAY MaxText OF CHAR;      (* the same text, 0DX after every line *)
    len:    INTEGER;                    (* characters used in buf *)
    lines:  INTEGER;                    (* the 0DX count, which is the line count *)
    start:  INTEGER;                    (* where the line being read begins *)
    over:   BOOLEAN;                    (* the file did not fit *)
    starts: ARRAY MaxLines OF INTEGER;  (* where each line begins in buf *)
    err:    ARRAY 40 OF CHAR;
    ready:   BOOLEAN;


(* ---------------------------------------------------------------------------
   reading the file
*)

(* PutByte - one byte of the decoded text.  Past the end of the buffer the
   rest of the file is dropped and the whole of it is refused; see the
   header for why refusing beats cutting. *)
PROCEDURE PutByte (b: INTEGER);
BEGIN
    IF len >= MaxText - 1 THEN
        over := TRUE
    ELSE
        buf[len] := CHR(b);
        INC(len)
    END
END PutByte;


(* PutChar - one character of the decoded text, as UTF-8.

   Three bytes at most, because a code unit of UTF-16 is at most three bytes
   of UTF-8, and the two forms of a surrogate pair are written as the two
   three-byte sequences they are.  A surrogate pair is therefore not a single
   character here - it reaches a caller as two sequences, which is what a
   reader that compares keys never looks at. *)
PROCEDURE PutChar (u: INTEGER);
BEGIN
    IF u = 0 THEN
        (* a NUL is not text; see the header *)
    ELSIF u < 80H THEN
        PutByte(u)
    ELSIF u < 800H THEN
        PutByte(0C0H + u DIV 40H);
        PutByte(80H + u MOD 40H)
    ELSE
        PutByte(0E0H + u DIV 1000H);
        PutByte(80H + (u DIV 40H) MOD 40H);
        PutByte(80H + u MOD 40H)
    END
END PutChar;


(* EndLine - close the line being read: record where it began, terminate it
   and start the next one. *)
PROCEDURE EndLine;
BEGIN
    IF lines < MaxLines THEN
        starts[lines] := start
    ELSE
        over := TRUE
    END;
    PutByte(ORD(0DX));
    INC(lines);
    start := len
END EndLine;


(* Decode - the file in `raw`, `n` characters of it, into `buf` as lines.

   The order of the two tests in the loop is the whole of the line handling:
   CR ends a line and remembers that it did, LF ends one only when the CR
   before it was not already a line ending of its own, and anything else
   clears the memory.  So CR, LF and CRLF are each one line ending, which is
   what a file written on any of the three systems has. *)
PROCEDURE Decode (n: INTEGER);
VAR
    i, enc, u, b0, b1: INTEGER;
    sawCR: BOOLEAN;

BEGIN
    len := 0; lines := 0; start := 0; over := FALSE;
    sawCR := FALSE;
    enc := Enc8;
    i := 0;

    IF (n >= 3) & (ORD(raw[0]) = 0EFH) & (ORD(raw[1]) = 0BBH) &
       (ORD(raw[2]) = 0BFH) THEN
        i := 3                                  (* UTF-8 with a mark *)
    ELSIF (n >= 2) & (ORD(raw[0]) = 0FFH) & (ORD(raw[1]) = 0FEH) THEN
        enc := Enc16LE; i := 2
    ELSIF (n >= 2) & (ORD(raw[0]) = 0FEH) & (ORD(raw[1]) = 0FFH) THEN
        enc := Enc16BE; i := 2
    END;

    WHILE ~over & (i < n) DO
        IF enc = Enc8 THEN
            u := ORD(raw[i]);
            INC(i)
        ELSE
            b0 := ORD(raw[i]);
            IF i + 1 < n THEN b1 := ORD(raw[i + 1]) ELSE b1 := 0 END;
            INC(i, 2);
            IF enc = Enc16LE THEN u := b0 + b1 * 256 ELSE u := b0 * 256 + b1 END
        END;

        IF u = 0DH THEN
            EndLine; sawCR := TRUE
        ELSIF u = 0AH THEN
            IF ~sawCR THEN EndLine END;
            sawCR := FALSE
        ELSE
            sawCR := FALSE;
            PutChar(u)
        END
    END;
    (* a last line with no terminator of its own is still a line *)
    IF (~over) & (len > start) THEN EndLine END
END Decode;


(* Open - read the whole file into the buffers, indexing where each line
   begins as it goes.
   Parameters: name - the path.
   Result: TRUE when it was read and it fitted.  FALSE leaves every lookup
   answering "not there" and Error saying which of the two it was.

   The index is what makes a lookup cheap.  Without it LineText has to walk
   the buffer from the start to find line n, so one lookup costs the whole
   file and a caller asking a hundred questions - which a theme reader does,
   once per colour and once more per nuance of it - pays for the file a
   hundred times.  With it a lookup costs the lines it reads. *)
PROCEDURE Open* (name: ARRAY OF CHAR): BOOLEAN;
VAR
    f: Files.File;
    n: INTEGER;
    ok: BOOLEAN;

BEGIN
    ready := FALSE;
    lines := 0;
    len := 0;
    start := 0;
    over := FALSE;
    COPY("cannot be read", err);

    ok := Files.Reset(f, name);
    IF ok THEN
        COPY("", err);
        IF Files.Size(f) > MaxBytes THEN
            over := TRUE
        ELSE
            n := Files.BlockReadText(f, raw, MaxBytes);
            Decode(n)
        END;
        Files.Close(f);
        IF over THEN COPY("is too long", err) END;
        ready := ~over
    END;

    RETURN ready
END Open;


(* Error - why Open refused, or the empty string when it did not. *)
PROCEDURE Error* (VAR s: ARRAY OF CHAR);
BEGIN
    Strings.Copy(err, s)
END Error;


(* Lines - how many lines the file held.  For a diagnostic, not for reading:
   the line a value came from is not tracked. *)
PROCEDURE Lines* (): INTEGER;
BEGIN
    RETURN lines
END Lines;


(* ---------------------------------------------------------------------------
   lines
*)

(* LineText - copy line n out.  Lines are numbered from 0, in the order the
   file held them, blank lines included.  A line past the end reads as empty
   rather than as the last one, so a caller that overruns its loop gets
   nothing instead of a line it has already had. *)
PROCEDURE LineText (n: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    i, k, cap: INTEGER;

BEGIN
    IF n < lines THEN i := starts[n] ELSE i := len END;
    cap := LEN(s) - 1;
    k := 0;
    WHILE (i < len) & (buf[i] # 0DX) & (k < cap) DO
        s[k] := buf[i];
        INC(k); INC(i)
    END;
    s[k] := 0X
END LineText;


PROCEDURE Cap (c: CHAR): CHAR;
VAR
    r: CHAR;

BEGIN
    r := c;
    IF (c >= "a") & (c <= "z") THEN r := CHR(ORD(c) - 32) END;
    RETURN r
END Cap;


(* Same - equality without regard to case, which is how the format is read.
   Neither argument is modified, so a query may name a constant. *)
PROCEDURE Same (a, b: ARRAY OF CHAR): BOOLEAN;
VAR
    i: INTEGER;
    r: BOOLEAN;

BEGIN
    i := 0;
    WHILE (a[i] # 0X) & (b[i] # 0X) & (Cap(a[i]) = Cap(b[i])) DO INC(i) END;
    r := (a[i] = 0X) & (b[i] = 0X);
    RETURN r
END Same;


(* Unquote - take off one layer of matching double quotes, which is what a
   value that holds leading or trailing spaces is written with. *)
PROCEDURE Unquote (VAR s: ARRAY OF CHAR);
VAR
    n: INTEGER;
    t: ARRAY MaxValue OF CHAR;

BEGIN
    n := Strings.Length(s);
    IF (n >= 2) & (s[0] = '"') & (s[n - 1] = '"') THEN
        Strings.Extract(s, 1, n - 2, t);
        Strings.Copy(t, s)
    END
END Unquote;


(* Split - one line into its parts.
   `isSection` is set when the line was `[name]` and key holds the name;
   otherwise key holds a `key = value` pair's key and val its value.
   A blank line and a comment leave key empty.  A line with a key and no `=`
   leaves key empty too: it is not a setting, and answering with an empty
   value for it would hide the mistake. *)
PROCEDURE Split (s: ARRAY OF CHAR; VAR key, val: ARRAY OF CHAR;
                 VAR isSection: BOOLEAN);
VAR
    i, n: INTEGER;
    c: CHAR;

BEGIN
    key[0] := 0X;
    val[0] := 0X;
    isSection := FALSE;

    i := 0;
    WHILE (s[i] # 0X) & Strings.Space(s[i]) DO INC(i) END;
    c := s[i];

    IF (c = 0X) OR (c = ";") OR (c = "#") THEN
        (* a blank line or a comment: nothing to take *)
    ELSIF c = "[" THEN
        INC(i);
        n := 0;
        WHILE (s[i] # 0X) & (s[i] # "]") & (n < LEN(key) - 1) DO
            key[n] := s[i];
            INC(n); INC(i)
        END;
        key[n] := 0X;
        Strings.Trim(key);
        isSection := (s[i] = "]") & (key[0] # 0X)
    ELSE
        n := 0;
        WHILE (s[i] # 0X) & (s[i] # "=") & (n < LEN(key) - 1) DO
            key[n] := s[i];
            INC(n); INC(i)
        END;
        key[n] := 0X;
        IF s[i] = "=" THEN
            Strings.Trim(key);
            INC(i);
            n := 0;
            WHILE (s[i] # 0X) & (n < LEN(val) - 1) DO
                val[n] := s[i];
                INC(n); INC(i)
            END;
            val[n] := 0X;
            Strings.Trim(val);
            Unquote(val)
        ELSE
            key[0] := 0X
        END
    END
END Split;


(* ---------------------------------------------------------------------------
   looking things up
*)

(* Get - the value of `key` in `section`.
   Result: TRUE when the pair was there.  A key that is absent, a section
   that is absent and a value that is empty all answer FALSE: an .ini file
   has no way to say "absent" and "empty" differently, and a setting this
   reader is asked for always has a value that means something. *)
PROCEDURE Get* (section, key: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN;
VAR
    i: INTEGER;
    s, k, v, cur: ARRAY MaxValue OF CHAR;
    isSect, found: BOOLEAN;

BEGIN
    value[0] := 0X;
    cur[0] := 0X;
    found := FALSE;
    i := 0;
    WHILE (i < lines) & ~found DO
        LineText(i, s);
        Split(s, k, v, isSect);
        IF isSect THEN
            Strings.Copy(k, cur)
        ELSIF (k[0] # 0X) & (v[0] # 0X) & Same(cur, section) & Same(k, key) THEN
            Strings.Copy(v, value);
            found := TRUE
        END;
        INC(i)
    END;

    RETURN found
END Get;


(* GetInt - the same, read as a decimal integer. *)
PROCEDURE GetInt* (section, key: ARRAY OF CHAR; VAR v: INTEGER): BOOLEAN;
VAR
    s: ARRAY MaxValue OF CHAR;
    ok: BOOLEAN;

BEGIN
    ok := Get(section, key, s);
    IF ok THEN ok := Strings.ToInt(s, v) END;
    RETURN ok
END GetInt;


PROCEDURE Nibble (c: CHAR; VAR v: INTEGER): BOOLEAN;
VAR
    ok: BOOLEAN;

BEGIN
    ok := TRUE;
    IF (c >= "0") & (c <= "9") THEN
        v := ORD(c) - ORD("0")
    ELSIF (c >= "A") & (c <= "F") THEN
        v := ORD(c) - ORD("A") + 10
    ELSIF (c >= "a") & (c <= "f") THEN
        v := ORD(c) - ORD("a") + 10
    ELSE
        v := 0;
        ok := FALSE
    END;
    RETURN ok
END Nibble;


(* GetColor - a colour written `#RGB`, `#RRGGBB` or `#RRGGBBAA`, with or
   without the `#`.  The three-digit form is the same colour with every
   nibble doubled, which is what makes a theme readable: `#08F` and `#0088FF`
   are one value.

   `n` comes back as 3 or 4 and c holds r, g, b and, for the four-component
   form, a.  A caller that wants alpha to keep its own default looks at `n`
   rather than at a sentinel in c, because every byte value is a colour
   somebody could mean. *)
PROCEDURE GetColor* (section, key: ARRAY OF CHAR; VAR n: INTEGER;
                     VAR c: ARRAY OF INTEGER): BOOLEAN;
VAR
    s: ARRAY MaxValue OF CHAR;
    i, k, digits, v: INTEGER;
    d: ARRAY 8 OF INTEGER;
    ok, good: BOOLEAN;

BEGIN
    n := 0;
    ok := Get(section, key, s);
    IF ok THEN
        i := 0;
        IF (s[i] = "#") OR ((s[i] = "0") & ((s[i + 1] = "x") OR (s[i + 1] = "X"))) THEN
            IF s[i] = "#" THEN INC(i) ELSE INC(i, 2) END
        END;
        digits := 0;
        good := TRUE;
        WHILE (s[i] # 0X) & good DO
            IF (digits < 8) & Nibble(s[i], v) THEN
                d[digits] := v;
                INC(digits)
            ELSE
                good := FALSE
            END;
            INC(i)
        END;
        IF good & (digits = 3) THEN
            (* #RGB: a nibble doubled is the same as the byte times 17 *)
            k := 0;
            WHILE k < 3 DO
                c[k] := d[k] * 17;
                INC(k)
            END;
            n := 3
        ELSIF good & ((digits = 6) OR (digits = 8)) THEN
            k := 0;
            WHILE k < digits DIV 2 DO
                c[k] := d[k * 2] * 16 + d[k * 2 + 1];
                INC(k)
            END;
            n := digits DIV 2
        ELSE
            ok := FALSE
        END
    END;

    RETURN ok
END GetColor;


BEGIN
    len := 0;
    lines := 0;
    start := 0;
    over := FALSE;
    ready := FALSE;
    COPY("not opened", err)
END IniReader.
