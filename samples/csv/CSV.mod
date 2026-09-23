(*
    Public domain

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    CSV - character separated values, shared by every target.

    Text is UTF-8, and the byte path treats it as bytes.  That is correct
    rather than a shortcut: every delimiter this module looks for -- the
    separator, the quote, CR and LF -- is below 80X, and a UTF-8
    continuation byte is never below 80X, so a multi-byte character cannot
    be mistaken for one of them and no decoding is needed to find the field
    boundaries.  A file written by another program in any language reads
    back byte for byte.

    The W entry points are for callers that want the fields as UTF-16.
    They decode with Strings.Utf8To16 on the way in and encode with a
    private Utf16To8 on the way out, both covering the basic multilingual
    plane.  WCHAR does not exist on a 16-bit target, so those procedures
    are compiled only when the target is 32 bits or more.

    A row is parsed in place into the handle's line buffer and the fields
    are handed out one at a time by Field, so nothing is sized by the
    caller and no row storage is allocated.

    A row is written out ending in CRLF, which is what RFC 4180 asks for and
    what other programs expect to find.  Reading is more forgiving than
    writing: a row may end in CRLF, in a lone CR, or in a lone LF, so a file
    from a system that ends its lines some other way still reads.

    The bytes come and go through Files, the portable file module every
    target has, so a CSV file is opened, read and closed like any other
    file and this module never reaches past Files to a platform one.  A
    byte is read at a time, which costs nothing extra: Files keeps a page
    of the file in memory, and the per-character call is answered from
    there.
*)

MODULE CSV;

IMPORT Files, Strings;


CONST

    MAX_LINE*   = 4096;
    MAX_FIELDS* = 256;
    MAX_FIELD*  = 256;
    MAX_FILES*  = 32;

    Read* = 0;
    Write* = 1;

    (* ReadRow answers this when the input is exhausted.  No field count
       can be negative, so one value serves for both. *)
    Eof* = -1;


TYPE

    Handle* = INTEGER;


VAR

    handles: ARRAY MAX_FILES OF RECORD

        used:  BOOLEAN;
        mode:  INTEGER;
        sep:   CHAR;
        f:     Files.File;                (* the byte stream, through Files *)

        buf:   ARRAY MAX_LINE OF CHAR;    (* the current line, unescaped *)
        len:   INTEGER;                   (* how many bytes of it are used *)
        from:  ARRAY MAX_FIELDS OF INTEGER;   (* field i starts at buf[from[i]] *)
        size:  ARRAY MAX_FIELDS OF INTEGER;   (* and runs for size[i] bytes *)
        count: INTEGER;                   (* fields in buf *)

        eof:   BOOLEAN;
        line:  INTEGER;
        pendingLF: BOOLEAN

    END;

    initialized: BOOLEAN;


PROCEDURE Init;
VAR
    i: INTEGER;

BEGIN
    IF ~initialized THEN
        i := 0;
        WHILE i < MAX_FILES DO
            handles[i].used := FALSE;
            INC(i)
        END;
        initialized := TRUE
    END
END Init;


PROCEDURE AllocSlot (): INTEGER;
VAR
    i, res: INTEGER;

BEGIN
    Init;
    i := 0;
    WHILE (i < MAX_FILES) & handles[i].used DO
        INC(i)
    END;
    IF i < MAX_FILES THEN
        res := i
    ELSE
        res := -1
    END

    RETURN res
END AllocSlot;


PROCEDURE ValidHandle (h: Handle): BOOLEAN;
BEGIN
    Init;
    RETURN (h >= 0) & (h < MAX_FILES) & handles[h].used
END ValidHandle;


PROCEDURE ReadChar (h: Handle; VAR ch: CHAR): BOOLEAN;
VAR
    b: BYTE;
    ok: BOOLEAN;

BEGIN
    ok := Files.ReadByte(handles[h].f, b);
    IF ok THEN
        ch := CHR(b)
    ELSE
        ch := 0X
    END;

    RETURN ok
END ReadChar;


(* ReadRawLine - read one line into the handle's buffer.
   A line ends at a LF, at a CR, or at end of file; a CR is remembered so
   that the LF of a CRLF pair is swallowed at the start of the next call
   rather than showing up as an empty line.
   Parameters: h - the handle.
   Result: TRUE when a line was produced, which may be empty. *)
PROCEDURE ReadRawLine (h: Handle): BOOLEAN;
VAR
    ch: CHAR;
    ok, done: BOOLEAN;

BEGIN
    ok := FALSE;
    done := FALSE;
    handles[h].len := 0;

    WHILE ~done & ~handles[h].eof DO
        IF handles[h].pendingLF THEN
            handles[h].pendingLF := FALSE;
            IF ReadChar(h, ch) THEN
                IF ch = 0AX THEN
                    (* the LF half of a CRLF pair: nothing more to do, and
                       the loop goes on to read the next line *)
                ELSIF ch = 0DX THEN
                    handles[h].pendingLF := TRUE;
                    ok := TRUE;
                    done := TRUE
                ELSE
                    handles[h].buf[0] := ch;
                    handles[h].len := 1
                END
            ELSE
                handles[h].eof := TRUE
            END
        ELSIF ReadChar(h, ch) THEN
            ok := TRUE;
            IF ch = 0DX THEN
                handles[h].pendingLF := TRUE;
                done := TRUE
            ELSIF ch = 0AX THEN
                done := TRUE
            ELSIF handles[h].len < MAX_LINE - 1 THEN
                handles[h].buf[handles[h].len] := ch;
                INC(handles[h].len)
            END
        ELSE
            handles[h].eof := TRUE
        END
    END;

    handles[h].buf[handles[h].len] := 0X;
    IF ok THEN
        INC(handles[h].line)
    END;

    RETURN ok
END ReadRawLine;


(* SplitLine - cut the buffered line into fields.
   The fields are unescaped back into the same buffer: a write cursor trails
   the read cursor, so the text is compacted in place and a quoted field that
   shrinks can never overwrite what has not been read yet.  The start and
   length of each field are recorded, which is what Field hands out. *)
PROCEDURE SplitLine (h: Handle);
VAR
    i, w, n, start: INTEGER;
    c: CHAR;
    done: BOOLEAN;

BEGIN
    i := 0;
    w := 0;
    n := 0;

    WHILE (i < handles[h].len) & (n < MAX_FIELDS) DO
        start := w;

        IF handles[h].buf[i] = '"' THEN
            INC(i);
            done := FALSE;
            WHILE ~done & (i < handles[h].len) DO
                c := handles[h].buf[i];
                IF c = '"' THEN
                    IF (i + 1 < handles[h].len) & (handles[h].buf[i + 1] = '"') THEN
                        handles[h].buf[w] := '"';
                        INC(w);
                        INC(i, 2)
                    ELSE
                        INC(i);
                        done := TRUE
                    END
                ELSE
                    handles[h].buf[w] := c;
                    INC(w);
                    INC(i)
                END
            END;
            (* anything between the closing quote and the separator is not
               part of the field *)
            WHILE (i < handles[h].len) & (handles[h].buf[i] # handles[h].sep) DO
                INC(i)
            END
        ELSE
            WHILE (i < handles[h].len) & (handles[h].buf[i] # handles[h].sep) DO
                handles[h].buf[w] := handles[h].buf[i];
                INC(w);
                INC(i)
            END
        END;

        handles[h].from[n] := start;
        handles[h].size[n] := w - start;
        INC(n);

        IF i < handles[h].len THEN
            INC(i)
        END
    END;

    handles[h].count := n
END SplitLine;


PROCEDURE WriteChar (h: Handle; ch: CHAR): BOOLEAN;
BEGIN
    RETURN Files.WriteByte(handles[h].f, ORD(ch)) = 1
END WriteChar;


PROCEDURE WriteField (h: Handle; s: ARRAY OF CHAR): BOOLEAN;
VAR
    i, len: INTEGER;
    c: CHAR;
    needQuote, ok: BOOLEAN;

BEGIN
    len := Strings.Length(s);

    needQuote := FALSE;
    i := 0;
    WHILE i < len DO
        c := s[i];
        IF (c = handles[h].sep) OR (c = '"') OR (c = 0DX) OR (c = 0AX) THEN
            needQuote := TRUE
        END;
        INC(i)
    END;

    ok := TRUE;
    IF needQuote THEN
        ok := WriteChar(h, '"');
        i := 0;
        WHILE ok & (i < len) DO
            IF s[i] = '"' THEN
                ok := WriteChar(h, '"')
            END;
            IF ok THEN
                ok := WriteChar(h, s[i])
            END;
            INC(i)
        END;
        IF ok THEN
            ok := WriteChar(h, '"')
        END
    ELSE
        i := 0;
        WHILE ok & (i < len) DO
            ok := WriteChar(h, s[i]);
            INC(i)
        END
    END;

    RETURN ok
END WriteField;


PROCEDURE Open* (name: ARRAY OF CHAR; mode: INTEGER; sep: CHAR): Handle;
VAR
    slot, res: INTEGER;
    ok: BOOLEAN;

BEGIN
    Init;
    res := -1;

    IF (mode = Read) OR (mode = Write) THEN
        slot := AllocSlot();
        IF slot >= 0 THEN
            IF mode = Read THEN
                ok := Files.Reset(handles[slot].f, name)
            ELSE
                ok := Files.ReWrite(handles[slot].f, name)
            END;

            IF ok THEN
                handles[slot].used  := TRUE;
                handles[slot].mode  := mode;
                handles[slot].sep   := sep;
                handles[slot].len   := 0;
                handles[slot].count := 0;
                handles[slot].eof   := FALSE;
                handles[slot].line  := 0;
                handles[slot].pendingLF := FALSE;
                res := slot
            END
        END
    END;

    RETURN res
END Open;


PROCEDURE Close* (h: Handle);
BEGIN
    IF ValidHandle(h) THEN
        Files.Close(handles[h].f);
        handles[h].used := FALSE
    END
END Close;


(* ReadRow - read the next row and cut it into fields.
   The fields stay in the handle and are fetched with Field or FieldW, so
   they remain valid until the next ReadRow on the same handle.
   Parameters: h - the handle.
   Result: the number of fields, or Eof. *)
PROCEDURE ReadRow* (h: Handle): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := Eof;

    IF ValidHandle(h) & (handles[h].mode = Read) THEN
        IF ReadRawLine(h) THEN
            SplitLine(h);
            res := handles[h].count
        END
    END;

    RETURN res
END ReadRow;


(* Field - fetch one field of the row last read.
   Parameters: h - the handle; i - which field, from 0; s - receives it,
   truncated to fit and always terminated.
   Result: TRUE when there was such a field; s is empty when there was
   not. *)
PROCEDURE Field* (h: Handle; i: INTEGER; VAR s: ARRAY OF CHAR): BOOLEAN;
VAR
    len: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := ValidHandle(h) & (0 <= i) & (i < handles[h].count);

    IF ok THEN
        len := handles[h].size[i];
        Strings.CopyRange(handles[h].buf, s, handles[h].from[i], 0, len);
        IF len >= LEN(s) THEN
            len := LEN(s) - 1
        END;
        s[len] := 0X
    ELSIF LEN(s) > 0 THEN
        s[0] := 0X
    END;

    RETURN ok
END Field;


PROCEDURE FieldCount* (h: Handle): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF ValidHandle(h) THEN
        res := handles[h].count
    ELSE
        res := 0
    END;

    RETURN res
END FieldCount;


(* WriteRow - write one row, each field quoted only when it has to be, and
   the row itself ending in CRLF.
   Parameters: h - the handle; fields - the row; n - how many fields.
   Result: TRUE when the whole row was written. *)
PROCEDURE WriteRow* (h: Handle; VAR fields: ARRAY OF ARRAY OF CHAR; n: INTEGER): BOOLEAN;
VAR
    i: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := ValidHandle(h) & (handles[h].mode = Write) & (n >= 0);

    i := 0;
    WHILE ok & (i < n) DO
        IF i > 0 THEN
            ok := WriteChar(h, handles[h].sep)
        END;
        IF ok THEN
            ok := WriteField(h, fields[i])
        END;
        INC(i)
    END;

    IF ok THEN
        ok := WriteChar(h, 0DX)
    END;
    IF ok THEN
        ok := WriteChar(h, 0AX)
    END;

    RETURN ok
END WriteRow;


PROCEDURE Sep* (h: Handle): CHAR;
VAR
    res: CHAR;

BEGIN
    res := 0X;
    IF ValidHandle(h) THEN
        res := handles[h].sep
    END;

    RETURN res
END Sep;


PROCEDURE Mode* (h: Handle): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := -1;
    IF ValidHandle(h) THEN
        res := handles[h].mode
    END;

    RETURN res
END Mode;


PROCEDURE LineNo* (h: Handle): INTEGER;
VAR
    res: INTEGER;

BEGIN
    res := -1;
    IF ValidHandle(h) THEN
        res := handles[h].line
    END;

    RETURN res
END LineNo;


$IF (BITS_32 | BITS_64)

(* Utf16To8 - encode UTF-16 code units as UTF-8.
   This is the mirror of Strings.Utf8To16 and like it covers the basic
   multilingual plane.  A lone surrogate or a code point above FFFFH is
   written as the replacement character, because this module has no
   surrogate pairs to pair it with.  Encoding stops at the end of dst.
   Parameters: src - the code units, up to the first WCHR(0); dst -
   receives the bytes, always terminated. *)
PROCEDURE Utf16To8 (src: ARRAY OF WCHAR; VAR dst: ARRAY OF CHAR);
VAR
    i, j, u: INTEGER;
    room: BOOLEAN;

BEGIN
    i := 0;
    j := 0;
    WHILE (i < LEN(src)) & (src[i] # WCHR(0)) DO
        u := ORD(src[i]);
        room := j < LEN(dst) - 1;

        IF u < 80H THEN
            IF room THEN
                dst[j] := CHR(u);
                INC(j)
            END
        ELSIF u < 800H THEN
            IF j < LEN(dst) - 2 THEN
                dst[j] := CHR(0C0H + u DIV 64);
                dst[j + 1] := CHR(80H + u MOD 64);
                INC(j, 2)
            ELSE
                j := LEN(dst) - 1
            END
        ELSIF (u < 10000H) & ((u < 0D800H) OR (0DFFFH < u)) THEN
            IF j < LEN(dst) - 3 THEN
                dst[j] := CHR(0E0H + u DIV 4096);
                dst[j + 1] := CHR(80H + (u DIV 64) MOD 64);
                dst[j + 2] := CHR(80H + u MOD 64);
                INC(j, 3)
            ELSE
                j := LEN(dst) - 1
            END
        ELSE
            IF j < LEN(dst) - 3 THEN
                dst[j] := 0EFX; dst[j + 1] := 0BFX; dst[j + 2] := 0BDX;
                INC(j, 3)
            ELSE
                j := LEN(dst) - 1
            END
        END;

        INC(i)
    END;

    IF j < LEN(dst) THEN
        dst[j] := 0X
    END
END Utf16To8;


(* FieldW - fetch one field of the row last read, as UTF-16.
   Parameters: h - the handle; i - which field, from 0; s - receives it,
   terminated with WCHR(0).
   Result: TRUE when there was such a field. *)
PROCEDURE FieldW* (h: Handle; i: INTEGER; VAR s: ARRAY OF WCHAR): BOOLEAN;
VAR
    buf: ARRAY MAX_FIELD OF CHAR;
    n: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := Field(h, i, buf);

    IF ok THEN
        n := Strings.Utf8To16(buf, s);
        ok := n >= 0
    ELSIF LEN(s) > 0 THEN
        s[0] := WCHR(0)
    END;

    RETURN ok
END FieldW;


(* WriteRowW - write one row whose fields are UTF-16, encoding them as
   UTF-8 on the way out, and ending the row in CRLF.
   Parameters: h - the handle; fields - the row; n - how many fields.
   Result: TRUE when the whole row was written. *)
PROCEDURE WriteRowW* (h: Handle; VAR fields: ARRAY OF ARRAY OF WCHAR; n: INTEGER): BOOLEAN;
VAR
    i: INTEGER;
    buf: ARRAY MAX_FIELD * 3 + 1 OF CHAR;
    ok: BOOLEAN;

BEGIN
    ok := ValidHandle(h) & (handles[h].mode = Write) & (n >= 0);

    i := 0;
    WHILE ok & (i < n) DO
        IF i > 0 THEN
            ok := WriteChar(h, handles[h].sep)
        END;
        IF ok THEN
            Utf16To8(fields[i], buf);
            ok := WriteField(h, buf)
        END;
        INC(i)
    END;

    IF ok THEN
        ok := WriteChar(h, 0DX)
    END;
    IF ok THEN
        ok := WriteChar(h, 0AX)
    END;

    RETURN ok
END WriteRowW;

$END


END CSV.
