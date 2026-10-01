(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A reader of an MS-DOS QuickHelp `.hlp` database, in object-oriented style
   and shared by every target.  It opens a file, answers how many topics the
   file holds, names them, hands out their text, and finds a topic by name.

   The style is ByteArr's: the record carries a pointer to every method beside
   the data, Create binds them, and a caller writes

       r := QHReader.Create();
       IF r.Open(r, "qbasic.hlp") THEN
           n := r.Topics(r);
           IF r.Name(r, 0, title) THEN ... END;
           len := r.Text(r, 0, text);
           t := r.Find(r, "Syntax", QHReader.AllWords);
           r.Close(r)
       ELSE
           r.Msg(r, why)
       END;
       r.Done(r)

   and never names the module again except for the two mode constants of Find.
   The receiver is handed over by hand, because this dialect has no implicit
   self, so a call is r.Topics(r) and r.Topics() is a parameter error.  What
   the record holds besides the methods is private: the image of the file and
   the decompressor can only be reached through the methods.

   The compression is not repeated here.  A `.hlp` topic is a WORD of declared
   length and then a Huffman, dictionary and run-length stream, and that stream
   is the whole business of HuffDec, which this module drives; what is added
   here is the file around it - the header, the topic index, the two sections
   the codec is loaded from, and the line records a topic decodes to.  Nothing
   in this module is about a particular caller: it opens a path, and the bytes
   it hands out are the bytes of the file, in the code page the file was
   written in, with no mapping to Unicode and no formatting of any kind.

   A name is the text of the topic's own `:n` command, which is where a
   QuickHelp topic carries its title.  It is worth knowing what that costs: a
   name lives in the compressed text and nowhere else in the file, so naming a
   topic decodes it, and Find - which compares names - decodes every topic of
   the database once per search.  There is no index of names to be had, because
   the format has none.

   The file is held whole in one heap block, so a database larger than
   Heap.MaxPayload cannot be opened - 16 MB on a 32-bit or 64-bit target, and
   4 KB on a 16-bit one.  That is the same bound the rest of the toolkit has.
*)
MODULE QHReader;

IMPORT SYSTEM, Files, Heap, ByteArr, HuffDec;


CONST
    (* The header of the format, which is 70 bytes: the six section offsets
       are DWORDs from 22H, and the counts are WORDs before them. *)
    H_SIGNATURE  = 0;                   (* the bytes 4C 4E, in that order *)
    H_WINHELP    = 35F3FH;              (* the DWORD a WinHelp 3 database
                                           begins with: the same extension
                                           and a format that is not this one *)
    H_VERSION    = 2;
    H_ATTRIBUTES = 4;                   (* bit 0: the contexts are case
                                           sensitive; bit 1: the file is
                                           locked and cannot be decompressed *)
    H_CONTROL    = 6;                   (* what opens a command line, `:` *)
    H_TOPICS     = 8;
    H_CONTEXTS   = 0AH;
    H_WIDTH      = 0CH;                 (* the width HELPMAKE was given with
                                           /W, or 0 when it was given none *)
    H_PREDEFINED = 0EH;
    H_NAME       = 10H;                 (* the file's own name, not the title *)
    H_NAME_LEN   = 14;                  (* 0EH bytes, NUL padded *)
    H_RESERVED1  = 1EH;                 (* junk in some files, never checked *)
    H_TOPICINDEX = 22H;
    H_CTXSTR     = 26H;
    H_CTXMAP     = 2AH;
    H_KEYWORDS   = 2EH;                 (* 0 when the file has no dictionary *)
    H_HUFFMAN    = 32H;
    H_TOPICTEXT  = 36H;
    H_TITLE      = 3AH;                 (* where the /N title is, or 0 *)
    H_RESERVED3  = 3EH;
    H_SIZE       = 42H;
    H_LEN        = 46H;

    (* The two ways Find reads its argument.  In both of them only the name of
       a topic is searched: never its text and never a context name. *)
    Exact*    = 0;                      (* the whole argument is one name *)
    AllWords* = 1;                      (* every word occurs in the name *)

    CHUNK     = 4096;                   (* the file is read through this *)
    MAX_TITLE = 256;                    (* the longest name Find compares *)
    MAX_MSG   = 160;                    (* the longest message Msg hands out *)

    (* The bounds the line records and the context section are read with.
       MAX_LINE is the ceiling a style run is written into; it is not a limit
       of the format, which counts a line's text in a BYTE and so allows 254
       bytes at the very most.  ARROW is the CP437 arrow QuickHelp frames a
       link with, which is drawn but is not part of the link. *)
    MAX_CTX    = 4096;                  (* names kept, of a WORD-wide count *)
    MAX_LINE   = 256;
    MAX_LINKS  = 32;
    MAX_TARGET = 64;                    (* the longest target seen in a real
                                           database is 32 - a cross-file jump
                                           of QB45QCK.HLP - and the block that
                                           holds it is a BYTE, so nothing can
                                           come near this *)
    MAX_NAME   = 32;                    (* the database name is 14 bytes *)
    ARROW      = 10H;

    (* A line record is measured in these, and a topic's text is handed out
       with them between the lines. *)
    CR    = 0DH;
    LF    = 0AH;
    SPACE = " ";


TYPE
    ByteArray* = ByteArr.ByteArray;

    (* One link of one line.  `first` and `last` are 1-based and inclusive over
       the characters of that line, already shortened past a trailing arrow
       unless KeepArrow said not to; `target` is the target as the file spells
       it - a context name, or `@L` and four hex digits for a topic number held
       in two bytes - and `topic` is what it resolved to: a topic number, or -1
       for the history command and for a name that answers to nothing.

       `byNumber` says which of the format's two spellings of a target the file
       used: TRUE when it is the empty target and the number in two bytes, FALSE
       when it is text.  Both are read into one `target` here and both resolve
       to one `topic`, so this is the only thing that tells them apart - and a
       converter that writes the database back is the caller that needs to, or
       a context name comes back as a number and the two files differ. *)
    Link* = RECORD
        first*, last*: INTEGER;
        target*: ARRAY MAX_TARGET OF CHAR;
        topic*: INTEGER;
        byNumber*: BOOLEAN
    END;

    (* The two arrays a caller hands in when it reads a line's attributes.
       They are named types and not open ones because LENGTH of this compiler
       is the length of a string and is refused for anything but a CHAR array,
       so an open array of INTEGER or of records could not be measured. *)
    Styles* = ARRAY MAX_LINE OF INTEGER;
    Links*  = ARRAY MAX_LINKS OF Link;

    Reader* = POINTER TO ReaderDesc;
    ReaderDesc* = RECORD
        (* The file, whole, in one heap block.  A database is addressed
           linearly and its parts must end up in one run, which is why it is
           read in through a stack buffer and moved into place.  The section
           addresses are absolute and already carry the base; `keywords` is 0
           when the file has no dictionary, and the zero is kept rather than
           turned into an address, because it is the flag. *)
        base:       INTEGER;
        size:       INTEGER;
        topicIndex: INTEGER;
        keywords:   INTEGER;
        huffman:    INTEGER;
        topicText:  INTEGER;
        ctxStrings: INTEGER;            (* where the context names live *)
        ctxMap:     INTEGER;            (* and where their topics are listed *)
        topics:     INTEGER;
        contexts:   INTEGER;            (* the count the header states *)
        names:      INTEGER;            (* the names that count is answered by *)
        yielded:    INTEGER;            (* ... and the empty one past them *)
        width:      INTEGER;
        attributes: INTEGER;
        sensitive:  BOOLEAN;            (* bit 0 of the attributes *)
        locked:     BOOLEAN;            (* bit 1: the text is not compressed *)
        ctrl:       CHAR;               (* the header's command character *)
        dbName:     ARRAY MAX_NAME OF CHAR;

        (* The header's first and third junk DWORDs, kept because a caller
           that copies a database back has to put them where they were:
           `COBOL.HLP` carries the bytes `JCK` and a CR at the first of them,
           and no reader may test either. *)
        reserved1:  INTEGER;
        reserved3:  INTEGER;

        (* The title the database was made with, HELPMAKE's /N, which is a
           section of its own after the topic text.  Zero is the header's way
           of saying the file has none, and is the usual answer: not one of
           the five databases measured here carries a title. *)
        title:      INTEGER;

        (* The context section, read once when the file is opened: where each
           name is, and the topic the map gives it.  Only the names the header
           counts are kept.  The section yields one more than that - its own
           trailing NUL is the end of a last, empty name - and that one belongs
           to no topic, so nothing is searched through it. *)
        ctxName:    ARRAY MAX_CTX OF INTEGER;
        ctxTopic:   ARRAY MAX_CTX OF INTEGER;

        (* One decompressor for the whole file: the tree and the dictionary
           belong to the database and not to a topic, so they are loaded once
           and every topic is decoded through them.  `sect` carries a section to
           the codec, which reads ByteArrays and not addresses; `buf` holds a
           topic that is being decoded for its name. *)
        huff:       HuffDec.Decompressor;
        sect:       ByteArray;
        buf:        ByteArray;

        (* What the last Decode read out of the file: how many bytes of the
           topic's blob the bits came from, and how many the blob held.  The
           two are equal for every topic of a sound database, which is what
           makes the pair worth asking for.  A topic that cannot be read leaves
           them set, so a damaged one is reported with the same two numbers a
           sound one is. *)
        lastUsed:   INTEGER;
        lastBlob:   INTEGER;

        (* The style bytes of every block read since the file was opened, by
           value, and how many there were.  This is a diagnostic and nothing
           more: the styles a caller wants are the per-character ones Attrs
           hands back.  It lives here rather than in a parameter because a
           report is the only caller that wants it, and the alternative is the
           same run walk written a second time. *)
        styleBytes: ARRAY 256 OF INTEGER;
        styleTotal: INTEGER;

        (* Whether a link's range keeps the arrow that closes it.  FALSE is
           what a program that draws a link wants, and the default, so every
           caller that says nothing is unaffected. *)
        keepArrow:  BOOLEAN;

        msg:        ARRAY MAX_MSG OF CHAR;

        (* One pointer per method, bound by Create. *)
        Open*:         PROCEDURE (self: Reader; path: ARRAY OF CHAR): BOOLEAN;
        Close*:        PROCEDURE (self: Reader);
        Topics*:       PROCEDURE (self: Reader): INTEGER;
        Name*:         PROCEDURE (self: Reader; topic: INTEGER; VAR name: ARRAY OF CHAR): BOOLEAN;
        Text*:         PROCEDURE (self: Reader; topic: INTEGER; dst: ByteArray): INTEGER;
        Raw*:          PROCEDURE (self: Reader; topic: INTEGER; dst: ByteArray): INTEGER;
        Find*:         PROCEDURE (self: Reader; keywords: ARRAY OF CHAR; mode: INTEGER): INTEGER;
        Hidden*:       PROCEDURE (self: Reader; topic: INTEGER): BOOLEAN;
        Contexts*:     PROCEDURE (self: Reader): INTEGER;
        Names*:        PROCEDURE (self: Reader): INTEGER;
        ContextTopic*: PROCEDURE (self: Reader; i: INTEGER): INTEGER;
        ContextName*:  PROCEDURE (self: Reader; i: INTEGER; VAR s: ARRAY OF CHAR);
        DbName*:       PROCEDURE (self: Reader; VAR s: ARRAY OF CHAR);
        Width*:        PROCEDURE (self: Reader): INTEGER;
        Ctrl*:         PROCEDURE (self: Reader): CHAR;
        Sensitive*:    PROCEDURE (self: Reader): BOOLEAN;
        Locked*:       PROCEDURE (self: Reader): BOOLEAN;
        FileTitle*:    PROCEDURE (self: Reader; VAR s: ARRAY OF CHAR);
        FileSize*:     PROCEDURE (self: Reader): INTEGER;
        Header*:       PROCEDURE (self: Reader; VAR version, attributes, predefined,
                                      reserved1, titleOff, reserved3, sizeField,
                                      ctrlByte: INTEGER);
        Offsets*:      PROCEDURE (self: Reader; VAR ti, cs, cm, kw, ht, tt: INTEGER);
        BlobUsed*:     PROCEDURE (self: Reader): INTEGER;
        BlobSize*:     PROCEDURE (self: Reader): INTEGER;
        TreeNodes*:    PROCEDURE (self: Reader): INTEGER;
        DictEntries*:  PROCEDURE (self: Reader): INTEGER;
        DictWord*:     PROCEDURE (self: Reader; i: INTEGER;
                                  dst: ByteArray): INTEGER;
        StyleByte*:    PROCEDURE (self: Reader; i: INTEGER): INTEGER;
        StyleTotal*:   PROCEDURE (self: Reader): INTEGER;
        Line*:         PROCEDURE (self: Reader; a: ByteArray; len: INTEGER; VAR pos: INTEGER;
                                  VAR textPos, textLen, attrPos, attrLen: INTEGER): BOOLEAN;
        IsCommand*:    PROCEDURE (self: Reader; a: ByteArray; textPos, textLen: INTEGER): BOOLEAN;
        Command*:      PROCEDURE (self: Reader; a: ByteArray; textPos, textLen: INTEGER): CHAR;
        Attrs*:        PROCEDURE (self: Reader; a: ByteArray;
                                  textPos, textLen, attrPos, attrLen: INTEGER;
                                  VAR styles: Styles; VAR links: Links): INTEGER;
        KeepArrow*:    PROCEDURE (self: Reader; on: BOOLEAN);
        Msg*:          PROCEDURE (self: Reader; VAR s: ARRAY OF CHAR);
        Done*:         PROCEDURE (self: Reader)
    END;


PROCEDURE Byte (adr: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    SYSTEM.GET8(adr, v);

    RETURN v
END Byte;


PROCEDURE Word (adr: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    SYSTEM.GET16(adr, v);

    RETURN v
END Word;


(* A DWORD of this format is a file offset and never a negative number, so the
   zero extension GET32 gives is the reading wanted and no sign is put back. *)
PROCEDURE DWord (adr: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    SYSTEM.GET32(adr, v);

    RETURN v
END DWord;


(* The lower case of one ASCII byte and of nothing else: a title is ASCII, and
   a byte above 7FH is a character of the text and not a letter. *)
PROCEDURE Lower (b: INTEGER): INTEGER;
BEGIN
    IF (b >= 41H) & (b <= 5AH) THEN
        b := b + 20H
    END;

    RETURN b
END Lower;


PROCEDURE StrLen (s: ARRAY OF CHAR): INTEGER;
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < LENGTH(s)) & (s[i] # 0X) DO
        INC(i)
    END;

    RETURN i
END StrLen;


PROCEDURE StrCopy (VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
VAR
    i, n: INTEGER;

BEGIN
    n := LEN(dst) - 1;
    i := 0;
    WHILE (i < n) & (i < LENGTH(src)) & (src[i] # 0X) DO
        dst[i] := src[i];
        INC(i)
    END;
    dst[i] := 0X
END StrCopy;


PROCEDURE Clear (VAR s: ARRAY OF CHAR);
BEGIN
    s[0] := 0X
END Clear;


(* One byte of an array as an INTEGER, which is how the records of a topic are
   walked.  The bytes are read through the method and not by address, because a
   ByteArray is a directory of blocks and the bytes past the end of the block
   an index falls in are not next to it. *)
PROCEDURE At (a: ByteArray; idx: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    v := a.Get8(a, idx);

    RETURN v
END At;


(* The len bytes of the array that begin at idx, as a string.  They are not NUL
   terminated - a line record is ended by its length and by nothing else - so
   the caller says how many there are. *)
PROCEDURE ArrToStrN (a: ByteArray; idx, len: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    i, n: INTEGER;

BEGIN
    n := LEN(s) - 1;
    i := 0;
    WHILE (i < n) & (i < len) DO
        s[i] := CHR(At(a, idx + i));
        INC(i)
    END;
    s[i] := 0X
END ArrToStrN;


(* Two bytes of an array as an INTEGER, little endian, as Word is for the file
   image: an empty link target carries the topic it names this way, rather than
   in a string. *)
PROCEDURE At16 (a: ByteArray; idx: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    v := a.Get16(a, idx);

    RETURN v
END At16;


PROCEDURE Pow (b, e: INTEGER): INTEGER;
VAR
    i, v: INTEGER;

BEGIN
    v := 1;
    FOR i := 1 TO e DO
        v := v * b
    END;

    RETURN v
END Pow;


(* Four hex digits of v at dst, upper case, which is how a reader spells a
   topic number the file stores as two bytes. *)
PROCEDURE HexOut (v, dst: INTEGER);
VAR
    i, d: INTEGER;

BEGIN
    i := 0;
    WHILE i < 4 DO
        d := (v DIV Pow(16, 3 - i)) MOD 16;
        IF d < 10 THEN
            SYSTEM.PUT8(dst + i, d + 30H)
        ELSE
            SYSTEM.PUT8(dst + i, d + 37H)
        END;
        INC(i)
    END
END HexOut;


(* The value of the four hex digits at adr, or -1 when one of the four is not
   a digit.  A target that only looks like a topic number must not resolve. *)
PROCEDURE Hex4 (adr: INTEGER): INTEGER;
VAR
    i, v, d: INTEGER;
    ok: BOOLEAN;

BEGIN
    v := 0;
    ok := TRUE;
    i := 0;
    WHILE ok & (i < 4) DO
        d := Byte(adr + i);
        IF (d >= 30H) & (d <= 39H) THEN
            d := d - 30H
        ELSIF (d >= 41H) & (d <= 46H) THEN
            d := d - 37H
        ELSIF (d >= 61H) & (d <= 66H) THEN
            d := d - 57H
        ELSE
            ok := FALSE
        END;
        IF ok THEN
            v := v * 16 + d;
            INC(i)
        END
    END;
    IF ~ok THEN
        v := -1
    END;

    RETURN v
END Hex4;


(* The NUL terminated string at adr, and never more than max bytes of it: a
   name lives in a section whose end is known, and one that is not terminated
   must not walk out of the file. *)
PROCEDURE MemToStr (adr, max: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    i, n: INTEGER;

BEGIN
    n := LEN(s) - 1;
    i := 0;
    WHILE (i < n) & (i < max) & (Byte(adr + i) # 0) DO
        s[i] := CHR(Byte(adr + i));
        INC(i)
    END;
    s[i] := 0X
END MemToStr;


(* Does the string at adr, which ends within max bytes, read the same as s?
   With fold set, upper and lower case count as the same letter, which is what
   a database that does not declare its contexts case sensitive wants. *)
PROCEDURE MemEqStr (adr, max: INTEGER; s: ARRAY OF CHAR; fold: BOOLEAN): BOOLEAN;
VAR
    i, a, b: INTEGER;
    same, done: BOOLEAN;

BEGIN
    same := TRUE;
    done := FALSE;
    i := 0;
    WHILE ~done & (i <= max) DO
        a := Byte(adr + i);
        IF i < LENGTH(s) THEN
            b := ORD(s[i])
        ELSE
            b := 0
        END;
        IF fold THEN
            a := Lower(a);
            b := Lower(b)
        END;
        IF a # b THEN
            same := FALSE;
            done := TRUE
        ELSIF a = 0 THEN
            done := TRUE
        ELSE
            INC(i)
        END
    END;

    RETURN same
END MemEqStr;


PROCEDURE Fail (self: Reader; why: ARRAY OF CHAR);
BEGIN
    StrCopy(self.msg, why)
END Fail;


(* One section of the image as an array, for the decompressor, which reads
   ByteArrays and not addresses.  It is a copy, and `sect` is only ever handed
   over and then dropped: the codec keeps what it needs of what it is given -
   the dictionary is copied into itself and a topic's blob is appended to the
   stream being read - so the one array serves every section and every topic. *)
PROCEDURE Section (self: Reader; from, limit: INTEGER): ByteArray;
BEGIN
    self.sect.SetLength(self.sect, 0);
    self.sect.AppendMem(self.sect, from, limit - from);

    RETURN self.sect
END Section;


(* One topic decoded, its line records appended to dst: the answer is how many
   bytes that was, 0 for a topic that holds nothing, and -1 for one that cannot
   be read.  dst is emptied first, so the answer is the topic itself and not
   the topic behind whatever the caller had there.

   OUTLEN is the topic's first WORD and the rest of it is the compressed blob.
   A topic that decodes to fewer bytes than it declared, or that reads past the
   end of its own blob, is refused rather than handed over half.

   BlobUsed and BlobSize describe what this call read, and they describe it for
   a topic that was refused as well. *)
PROCEDURE Decode (self: Reader; topic: INTEGER; dst: ByteArray): INTEGER;
VAR
    lo, hi, outLen, moved, result: INTEGER;

BEGIN
    self.lastUsed := 0;
    self.lastBlob := 0;
    dst.SetLength(dst, 0);
    result := -1;
    IF self.locked THEN
        (* Bit 1 of the attributes says the topics were never compressed, and
           what stands where their bits should be is not known here.  The
           header is still readable, which is what a report of such a file is
           for. *)
        Fail(self, "the file is locked: its topics are not compressed")
    ELSIF (topic >= 0) & (topic < self.topics) THEN
        lo := DWord(self.topicIndex + 4 * topic);
        hi := DWord(self.topicIndex + 4 * (topic + 1));
        IF (hi < lo + 2) OR (hi > self.size) THEN
            result := 0                   (* a topic with no data behind it *)
        ELSE
            self.lastBlob := hi - lo - 2;
            outLen := Word(self.base + lo);
            IF outLen = 0 THEN
                result := 0
            ELSE
                self.huff.Start(self.huff, outLen);
                self.huff.Feed(self.huff, Section(self, self.base + lo + 2, self.base + hi));
                moved := self.huff.Take(self.huff, dst);
                self.huff.Finish(self.huff);
                self.lastUsed := self.huff.Used(self.huff);
                IF self.huff.Ok(self.huff) & (moved = outLen) THEN
                    result := outLen
                ELSE
                    dst.SetLength(dst, 0)
                END
            END
        END
    END;

    RETURN result
END Decode;


(* One line record of a decoded topic.  Both lengths count themselves, so
   neither can be zero and the text of a line is at most 254 bytes.  `pos` is
   carried by the caller from one call to the next and left where the following
   line begins; the four other variables describe the record just read.  The
   answer is FALSE at the end of the topic and at a record that runs past it. *)
PROCEDURE Line (self: Reader; a: ByteArray; len: INTEGER; VAR pos: INTEGER;
                VAR textPos, textLen, attrPos, attrLen: INTEGER): BOOLEAN;
VAR
    p, m: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    p := pos;
    IF p < len THEN
        m := At(a, p) - 1;              (* the length byte counts itself *)
        INC(p);
        IF (m >= 0) & (p + m <= len) THEN
            textPos := p;
            textLen := m;
            INC(p, m);
            IF p < len THEN
                m := At(a, p) - 1;
                INC(p);
                IF m < 0 THEN
                    m := 0
                END;
                IF p + m <= len THEN
                    attrPos := p;
                    attrLen := m;
                    INC(p, m);
                    pos := p;
                    ok := TRUE
                END
            END
        END
    END;

    RETURN ok
END Line;


(* Whether a line is a command: a line whose first text byte is the header's
   control character.  Such a line is part of the topic and of its byte count
   like any other, and it is not drawn. *)
PROCEDURE IsCommand (self: Reader; a: ByteArray; textPos, textLen: INTEGER): BOOLEAN;
BEGIN
    RETURN (textLen > 0) & (At(a, textPos) = ORD(self.ctrl))
END IsCommand;


(* The command character of a line - "n" for a title, "x" for a topic the
   contents list hides - and 0X when the line does not carry one.  A command
   of no letter is still a command; it is only that nothing can be said about
   which one it is. *)
PROCEDURE Command (self: Reader; a: ByteArray; textPos, textLen: INTEGER): CHAR;
VAR
    c: CHAR;

BEGIN
    c := 0X;
    IF IsCommand(self, a, textPos, textLen) & (textLen >= 2) THEN
        c := CHR(At(a, textPos + 1))
    END;

    RETURN c
END Command;


(* The topic a context name belongs to, or -1.  The comparison folds case
   unless the header declares the contexts case sensitive, and it runs over the
   names the file really holds rather than over the count the header states,
   which is what the reference reader does as well. *)
PROCEDURE FindContext (self: Reader; name: ARRAY OF CHAR): INTEGER;
VAR
    i, t, max: INTEGER;
    hit: BOOLEAN;

BEGIN
    t := -1;
    i := 0;
    WHILE (t < 0) & (i < self.names) DO
        max := self.ctxMap - self.ctxName[i];
        IF self.sensitive THEN
            hit := MemEqStr(self.ctxName[i], max, name, FALSE)
        ELSE
            hit := MemEqStr(self.ctxName[i], max, name, TRUE)
        END;
        IF hit THEN
            t := self.ctxTopic[i]
        END;
        INC(i)
    END;

    RETURN t
END FindContext;


(* A link target as a topic number, the format's section 3.7.  `@L` and four
   hex digits whose top bit is set names a topic outright; a target with a `!`
   in it is the history command or a command for another database, neither of
   which is a topic here; anything else is a context name. *)
PROCEDURE Resolve (self: Reader; target: ARRAY OF CHAR): INTEGER;
VAR
    t, v, i, len: INTEGER;
    cmd: BOOLEAN;

BEGIN
    t := -1;
    len := StrLen(target);
    IF (len = 6) & (target[0] = "@") & (target[1] = "L") THEN
        v := Hex4(SYSTEM.ADR(target[2]));
        IF (v >= 0) & (v >= 8000H) THEN
            t := v - 8000H
        END
    ELSE
        cmd := FALSE;
        i := 0;
        WHILE i < len DO
            IF target[i] = "!" THEN
                cmd := TRUE
            END;
            INC(i)
        END;
        IF ~cmd & (len > 0) THEN
            t := FindContext(self, target)
        END
    END;

    RETURN t
END Resolve;


(* The styles and the links of one line, read from its attribute block.
   `styles` gets one entry per character of the text and `links` the line's
   links in the order the block lists them; the answer is how many were
   stored.

   The block is a default run whose length is the first byte, then a style byte
   and a length for each further run, then 0FFH and the link list.  The run
   walk keeps going after the text is covered, because where the link list
   begins is exactly what it is looking for.

   A block belongs to one line and the styles go with it, so this is a call per
   line and not per topic.  The style bytes are counted into the record as they
   go by, which is what a report of a database reads. *)
PROCEDURE Attrs (self: Reader; a: ByteArray;
                 textPos, textLen, attrPos, attrLen: INTEGER;
                 VAR styles: Styles; VAR links: Links): INTEGER;
VAR
    i, n, charIndex, chunk, s, count, j, x, y: INTEGER;
    first, last, k, tlen, nlinks: INTEGER;
    hit, done: BOOLEAN;
    shrink: ARRAY MAX_LINKS OF BOOLEAN;

BEGIN
    n := textLen;
    IF n > MAX_LINE THEN
        n := MAX_LINE
    END;
    FOR j := 0 TO n - 1 DO
        styles[j] := 0
    END;

    i := 0;
    charIndex := 0;
    chunk := 0;
    done := FALSE;
    WHILE ~done & (i < attrLen) DO
        s := 0;
        IF chunk > 0 THEN
            s := At(a, attrPos + i);
            INC(i);
            IF s = 0FFH THEN
                done := TRUE
            ELSE
                self.styleBytes[s] := self.styleBytes[s] + 1;
                INC(self.styleTotal);
                s := s MOD 8
            END
        END;
        IF ~done THEN
            IF i >= attrLen THEN
                done := TRUE
            ELSE
                count := At(a, attrPos + i);
                INC(i);
                IF count > n - charIndex THEN
                    count := n - charIndex
                END;
                j := 0;
                WHILE j < count DO
                    styles[charIndex + j] := s;
                    INC(j)
                END;
                INC(charIndex, count);
                INC(chunk)
            END
        END
    END;

    nlinks := 0;
    WHILE (i < attrLen) & (nlinks < MAX_LINKS) DO
        first := At(a, attrPos + i);
        last := first;
        IF i + 1 < attrLen THEN
            last := At(a, attrPos + i + 1)
        END;
        INC(i, 2);
        k := i;
        WHILE (k < attrLen) & (At(a, attrPos + k) # 0) DO
            INC(k)
        END;
        IF k >= attrLen THEN
            i := attrLen                 (* no terminator: the block is damaged *)
        ELSE
            tlen := k - i;
            IF tlen > MAX_TARGET - 1 THEN
                tlen := MAX_TARGET - 1
            END;
            ArrToStrN(a, attrPos + i, tlen, links[nlinks].target);
            i := k + 1;
            links[nlinks].byNumber := FALSE;
            IF (tlen = 0) & (i + 1 < attrLen) THEN
                (* An empty target is a topic number held in two bytes; the
                   reader spells it out the way the file would have. *)
                links[nlinks].target[0] := "@";
                links[nlinks].target[1] := "L";
                HexOut(At16(a, attrPos + i), SYSTEM.ADR(links[nlinks].target[2]));
                links[nlinks].target[6] := 0X;
                links[nlinks].byNumber := TRUE;
                INC(i, 2)
            END;
            IF first >= 1 THEN
                IF last > n THEN
                    last := n
                END;
                IF first <= last THEN
                    links[nlinks].first := first;
                    links[nlinks].last := last;
                    links[nlinks].topic := Resolve(self, links[nlinks].target);
                    INC(nlinks)
                END
            END
        END
    END;

    (* The format's section 3.8: a trailing arrow is drawn but is not part of
       the link.  The test asks whether the column after the arrow is already
       in another link, and it asks it of the links as they were read, so the
       decision is taken for every link before any of them is shortened.  A
       caller that keeps the arrow wants none of this and gets the range the
       file holds. *)
    IF self.keepArrow THEN
        FOR x := 0 TO nlinks - 1 DO
            shrink[x] := FALSE
        END
    ELSE
        FOR x := 0 TO nlinks - 1 DO
            shrink[x] := FALSE;
            last := links[x].last;
            IF (last >= 1) & (last <= n) & (At(a, textPos + last - 1) = ARROW) THEN
                hit := FALSE;
                IF last < n THEN
                    FOR y := 0 TO nlinks - 1 DO
                        IF (links[y].first <= last + 1) & (last + 1 <= links[y].last) THEN
                            hit := TRUE
                        END
                    END
                END;
                IF (last = n) OR ~hit THEN
                    shrink[x] := TRUE
                END
            END
        END
    END;
    j := 0;
    FOR x := 0 TO nlinks - 1 DO
        IF shrink[x] THEN
            DEC(links[x].last)
        END;
        IF links[x].first <= links[x].last THEN
            links[j] := links[x];
            INC(j)
        END
    END;

    RETURN j
END Attrs;


(* Whether the range of a link keeps the arrow that closes it.

   Section 3.8: the ► a database frames a link with is drawn but is not part of
   the link, so a program that draws one wants a range that ends before it, and
   that is the default - HelpWin and the reports here are unaffected by this.
   A converter that writes the database back wants the range the file holds,
   arrow and all, or the byte it writes is one short: 2237 of the 2349 links of
   QB45ADVR.HLP and 1163 of the 1433 of QB45QCK.HLP end inside the range in a
   trailing arrow, and a shorter range is a different line record.  Nothing but
   the shortening is turned off; every other rule of Attrs stands.

   The setting is the reader's and not the file's, so closing the database does
   not undo it: a caller that opens file after file says this once. *)
PROCEDURE KeepArrow* (self: Reader; on: BOOLEAN);
BEGIN
    self.keepArrow := on
END KeepArrow;


(* The bounds of s without its leading and trailing spaces: the text is
   s[lo .. hi). *)
PROCEDURE Trim (s: ARRAY OF CHAR; VAR lo, hi: INTEGER);
VAR
    n: INTEGER;

BEGIN
    n := StrLen(s);
    lo := 0;
    WHILE (lo < n) & (s[lo] = SPACE) DO
        INC(lo)
    END;
    hi := n;
    WHILE (hi > lo) & (s[hi - 1] = SPACE) DO
        DEC(hi)
    END
END Trim;


(* Whether the wlen characters of q that begin at `from` are the whole of s,
   which is slen characters long.  Case is not significant. *)
PROCEDURE SpanEq (s: ARRAY OF CHAR; slen: INTEGER; q: ARRAY OF CHAR; from, wlen: INTEGER): BOOLEAN;
VAR
    i, a, b: INTEGER;
    same: BOOLEAN;

BEGIN
    same := slen = wlen;
    i := 0;
    WHILE same & (i < wlen) DO
        a := Lower(ORD(s[i]));
        b := Lower(ORD(q[from + i]));
        IF a # b THEN
            same := FALSE
        ELSE
            INC(i)
        END
    END;

    RETURN same
END SpanEq;


(* Whether the wlen characters of q that begin at `from` occur anywhere in s,
   which is slen characters long.  Case is not significant.  A word of no
   characters does not occur, which is what a caller that has already dropped
   the spaces between words never asks. *)
PROCEDURE SpanIn (s: ARRAY OF CHAR; slen: INTEGER; q: ARRAY OF CHAR; from, wlen: INTEGER): BOOLEAN;
VAR
    i, j, a, b: INTEGER;
    hit, ok: BOOLEAN;

BEGIN
    hit := FALSE;
    IF wlen > 0 THEN
        i := 0;
        WHILE ~hit & (i + wlen <= slen) DO
            ok := TRUE;
            j := 0;
            WHILE ok & (j < wlen) DO
                a := Lower(ORD(s[i + j]));
                b := Lower(ORD(q[from + j]));
                IF a # b THEN
                    ok := FALSE
                ELSE
                    INC(j)
                END
            END;
            IF ok THEN
                hit := TRUE
            ELSE
                INC(i)
            END
        END
    END;

    RETURN hit
END SpanIn;


(* The text a reader draws of a topic: the characters of every line, each line
   ended with CR LF, and a command line left out, because a command is part of
   the topic but is not drawn.  The last line is ended too, so the result is a
   text block and not a paragraph.  The answer is how many bytes were
   appended. *)
PROCEDURE Flatten (self: Reader; a: ByteArray; len: INTEGER; dst: ByteArray): INTEGER;
VAR
    pos, tp, tl, ap, al, n: INTEGER;

BEGIN
    n := 0;
    pos := 0;
    WHILE Line(self, a, len, pos, tp, tl, ap, al) DO
        IF ~IsCommand(self, a, tp, tl) THEN
            dst.Append(dst, a, tp, tl);
            dst.Append8(dst, CR);
            dst.Append8(dst, LF);
            n := n + tl + 2
        END
    END;

    RETURN n
END Flatten;


(* The whole file into one heap block.  It is read through a stack buffer and
   moved into place, because a database is addressed linearly and its parts
   must end up in one run. *)
PROCEDURE Load (self: Reader; path: ARRAY OF CHAR): BOOLEAN;
VAR
    f: Files.File;
    buf: ARRAY CHUNK OF BYTE;
    total, got, k: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    IF Files.Reset(f, path) THEN
        total := Files.Size(f);
        IF total < H_LEN THEN
            Fail(self, "the file is shorter than a database header")
        ELSIF total > Heap.MaxPayload THEN
            Fail(self, "the file is larger than one heap block")
        ELSE
            self.base := Heap.Alloc(total);
            got := 0;
            ok := TRUE;
            WHILE ok & (got < total) DO
                k := Files.BlockRead(f, buf, MIN(CHUNK, total - got));
                IF k <= 0 THEN
                    ok := FALSE
                ELSE
                    SYSTEM.MOVE(SYSTEM.ADR(buf[0]), self.base + got, k);
                    INC(got, k)
                END
            END;
            IF ok THEN
                self.size := total
            ELSE
                Fail(self, "the file ended before the size it reported");
                Heap.Free(self.base);
                self.base := 0
            END
        END;
        Files.Close(f)
    ELSE
        Fail(self, "cannot open the file")
    END;

    RETURN ok
END Load;


(* The header into the record, the context section read out of the image, and
   the two sections the codec is loaded from.  Every check here is one the
   reader would otherwise fail on later and less clearly. *)
PROCEDURE Parse (self: Reader): BOOLEAN;
VAR
    kw, p, i, n: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := (Byte(self.base + H_SIGNATURE) = 4CH) & (Byte(self.base + H_SIGNATURE + 1) = 4EH);
    IF ~ok THEN
        (* A WinHelp 3 database shares the extension and nothing else: it is a
           different format with a different header, and it is the file a
           caller is most likely to hand over by mistake.  Read as this
           format it would report a section outside the file rather than what
           the file is. *)
        IF DWord(self.base + H_SIGNATURE) = H_WINHELP THEN
            Fail(self, "a WinHelp 3 database, not a QuickHelp one")
        ELSE
            Fail(self, "not a QuickHelp database")
        END
    END;

    FOR i := 0 TO 255 DO
        self.styleBytes[i] := 0
    END;
    self.styleTotal := 0;

    IF ok THEN
        self.topics := Word(self.base + H_TOPICS);
        self.contexts := Word(self.base + H_CONTEXTS);
        self.width := Word(self.base + H_WIDTH);
        self.attributes := Word(self.base + H_ATTRIBUTES);
        self.sensitive := self.attributes MOD 2 = 1;
        self.locked := (self.attributes DIV 2) MOD 2 = 1;
        self.reserved1 := DWord(self.base + H_RESERVED1);
        self.reserved3 := DWord(self.base + H_RESERVED3);
        self.ctrl := CHR(Byte(self.base + H_CONTROL));
        self.topicIndex := self.base + DWord(self.base + H_TOPICINDEX);
        self.ctxStrings := self.base + DWord(self.base + H_CTXSTR);
        self.ctxMap := self.base + DWord(self.base + H_CTXMAP);
        self.huffman := self.base + DWord(self.base + H_HUFFMAN);
        self.topicText := self.base + DWord(self.base + H_TOPICTEXT);
        MemToStr(self.base + H_NAME, H_NAME_LEN, self.dbName);

        (* The title, which the header points at with the same zero that says
           the file has none: an offset of zero is the header itself, so no
           file can have one there. *)
        kw := DWord(self.base + H_TITLE);
        self.title := 0;
        IF kw # 0 THEN
            self.title := self.base + kw
        END;

        (* An offset of zero says the file has no dictionary, and is kept as a
           zero here rather than turned into an address: the flag and the
           address would otherwise be the same number. *)
        kw := DWord(self.base + H_KEYWORDS);
        self.keywords := 0;
        IF kw # 0 THEN
            self.keywords := self.base + kw
        END;

        ok := self.contexts <= MAX_CTX;
        IF ~ok THEN
            Fail(self, "more context names than this reader holds")
        END
    END;

    IF ok THEN
        ok := (self.topicIndex + 4 * (self.topics + 1) <= self.base + self.size) &
              (self.ctxStrings <= self.ctxMap) &
              (self.ctxMap + 2 * self.contexts <= self.base + self.size) &
              (self.base + kw <= self.base + self.size) &
              (self.huffman <= self.topicText) &
              (self.topicText <= self.base + self.size) &
              (self.title <= self.base + self.size);
        IF ~ok THEN
            Fail(self, "a section of the file lies outside it")
        END
    END;

    IF ok THEN
        (* The context strings run up to the context map, and the map gives the
           topic of each.  Only the names the header counts are kept, which is
           what the map is indexed by. *)
        p := self.ctxStrings;
        i := 0;
        WHILE (p < self.ctxMap) & (i < self.contexts) DO
            self.ctxName[i] := p;
            self.ctxTopic[i] := Word(self.ctxMap + 2 * i);
            WHILE (p < self.ctxMap) & (Byte(p) # 0) DO
                INC(p)
            END;
            INC(p);
            INC(i)
        END;
        self.names := i;
        IF self.names < self.contexts THEN
            ok := FALSE;
            Fail(self, "the context strings ended before the map did")
        END;

        (* Every name in the region is NUL terminated and the region itself
           ends where the map begins, so reading it to its end yields one name
           per NUL and one more past the last of them - the trailing empty
           string the reference reader sees. *)
        p := self.ctxStrings;
        self.yielded := 0;
        WHILE p < self.ctxMap DO
            IF Byte(p) = 0 THEN
                INC(self.yielded)
            END;
            INC(p)
        END;
        INC(self.yielded)
    END;

    IF ok THEN
        IF self.keywords # 0 THEN
            n := self.huff.Dict(self.huff, Section(self, self.keywords, self.huffman))
        END;
        IF self.huff.Load(self.huff, Section(self, self.huffman, self.topicText)) = 0 THEN
            ok := FALSE;
            Fail(self, "the file has no Huffman tree")
        END
    END;

    RETURN ok
END Parse;


(* Close the file and forget it.  The decompressor and the two working arrays
   stay, so the same reader can be opened again; Done is what gives them back.
   Closing a reader that is already closed is not an error. *)
PROCEDURE Close* (self: Reader);
BEGIN
    IF self.base # 0 THEN
        Heap.Free(self.base)
    END;
    self.base := 0;
    self.size := 0;
    self.topics := 0;
    self.contexts := 0;
    self.names := 0;
    self.yielded := 0;
    self.width := 0;
    self.attributes := 0;
    self.sensitive := FALSE;
    self.locked := FALSE;
    self.ctrl := 0X;
    self.topicIndex := 0;
    self.keywords := 0;
    self.huffman := 0;
    self.topicText := 0;
    self.ctxStrings := 0;
    self.ctxMap := 0;
    self.lastUsed := 0;
    self.lastBlob := 0;
    self.reserved1 := 0;
    self.reserved3 := 0;
    self.title := 0;
    Clear(self.dbName)
END Close;


(* Open a database, replacing whatever the reader held.  The answer is FALSE
   and Msg says why when the file cannot be opened, is not a QuickHelp
   database, or is damaged; a reader that failed to open holds nothing. *)
PROCEDURE Open* (self: Reader; path: ARRAY OF CHAR): BOOLEAN;
VAR
    ok: BOOLEAN;

BEGIN
    Close(self);
    Clear(self.msg);
    ok := Load(self, path);
    IF ok THEN
        ok := Parse(self)
    END;
    IF ~ok THEN
        Close(self)
    END;

    RETURN ok
END Open;


(* How many topics the database holds, and 0 when it is closed. *)
PROCEDURE Topics* (self: Reader): INTEGER;
BEGIN
    RETURN self.topics
END Topics;


(* How many context names the header counts, and how many the section really
   yields - one more, because its trailing NUL ends a last, empty name.  Only
   the counted ones belong to a topic, and only those ContextName and
   ContextTopic answer for. *)
PROCEDURE Contexts* (self: Reader): INTEGER;
BEGIN
    RETURN self.contexts
END Contexts;


PROCEDURE Names* (self: Reader): INTEGER;
BEGIN
    RETURN self.yielded
END Names;


(* The topic the i-th context name belongs to, or -1. *)
PROCEDURE ContextTopic* (self: Reader; i: INTEGER): INTEGER;
VAR
    t: INTEGER;

BEGIN
    t := -1;
    IF (i >= 0) & (i < self.contexts) THEN
        t := self.ctxTopic[i]
    END;

    RETURN t
END ContextTopic;


(* The i-th context name, as the bytes the file holds.  A name is NUL
   terminated and the next one follows it, so the map is the bound.  The caller
   is handed the bytes and not characters: a name is written in the code page
   of the machine that made the database, and what a byte means is the
   caller's business. *)
PROCEDURE ContextName* (self: Reader; i: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
    Clear(s);
    IF (i >= 0) & (i < self.contexts) THEN
        MemToStr(self.ctxName[i], self.ctxMap - self.ctxName[i], s)
    END
END ContextName;


(* The name of the database, which the header carries in fourteen bytes. *)
PROCEDURE DbName* (self: Reader; VAR s: ARRAY OF CHAR);
BEGIN
    StrCopy(s, self.dbName)
END DbName;


PROCEDURE Width* (self: Reader): INTEGER;
BEGIN
    RETURN self.width
END Width;


PROCEDURE Ctrl* (self: Reader): CHAR;
BEGIN
    RETURN self.ctrl
END Ctrl;


PROCEDURE Sensitive* (self: Reader): BOOLEAN;
BEGIN
    RETURN self.sensitive
END Sensitive;


(* Whether the header says the file is locked, which is bit 1 of the
   attributes and means the topics were never compressed.  The header, the
   index and the context names are all readable, so a report of such a file
   says everything but its text; Text, Raw, Find and Name answer nothing. *)
PROCEDURE Locked* (self: Reader): BOOLEAN;
BEGIN
    RETURN self.locked
END Locked;


(* The title the database was made with, HELPMAKE's /N: a NUL-terminated
   string in a section of its own, which the header points at.  An empty
   answer is what a file without one gives, and is the usual one - the four
   QuickBASIC databases and the qbasic.hlp beside this module all carry the
   offset zero that says so. *)
PROCEDURE FileTitle* (self: Reader; VAR s: ARRAY OF CHAR);
VAR
    p, i, limit: INTEGER;

BEGIN
    Clear(s);
    limit := self.base + self.size;
    p := self.title;
    i := 0;
    WHILE (i < LEN(s) - 1) & (p # 0) & (p < limit) & (Byte(p) # 0) DO
        s[i] := CHR(Byte(p));
        INC(i);
        INC(p)
    END;
    s[i] := 0X
END FileTitle;


(* How long the file is, and 0 when the reader holds none. *)
PROCEDURE FileSize* (self: Reader): INTEGER;
BEGIN
    RETURN self.size
END FileSize;


(* The header fields that have no accessor of their own: everything a report of
   a database prints about it. *)
PROCEDURE Header* (self: Reader; VAR version, attributes, predefined,
                       reserved1, titleOff, reserved3, sizeField, ctrlByte: INTEGER);
BEGIN
    version := Word(self.base + H_VERSION);
    attributes := self.attributes;
    predefined := Word(self.base + H_PREDEFINED);
    reserved1 := DWord(self.base + H_RESERVED1);
    titleOff := DWord(self.base + H_TITLE);
    reserved3 := DWord(self.base + H_RESERVED3);
    sizeField := DWord(self.base + H_SIZE);
    ctrlByte := ORD(self.ctrl)
END Header;


(* The six section offsets as the header stores them: from the start of the
   file, and not as the addresses the record works in. *)
PROCEDURE Offsets* (self: Reader; VAR ti, cs, cm, kw, ht, tt: INTEGER);
BEGIN
    ti := DWord(self.base + H_TOPICINDEX);
    cs := DWord(self.base + H_CTXSTR);
    cm := DWord(self.base + H_CTXMAP);
    kw := DWord(self.base + H_KEYWORDS);
    ht := DWord(self.base + H_HUFFMAN);
    tt := DWord(self.base + H_TOPICTEXT)
END Offsets;


(* The blob the last Decode read: how many bytes the bits came from, and how
   many there were.  The two are equal for every topic of a sound database. *)
PROCEDURE BlobUsed* (self: Reader): INTEGER;
BEGIN
    RETURN self.lastUsed
END BlobUsed;


PROCEDURE BlobSize* (self: Reader): INTEGER;
BEGIN
    RETURN self.lastBlob
END BlobSize;


(* How many nodes the file's Huffman tree holds, and how many entries its
   dictionary has.  Both are read out of the decompressor, which is where the
   two sections went when the file was opened. *)
PROCEDURE TreeNodes* (self: Reader): INTEGER;
VAR
    n: INTEGER;

BEGIN
    n := 0;
    IF self.huff # NIL THEN
        n := self.huff.Nodes(self.huff)
    END;

    RETURN n
END TreeNodes;


PROCEDURE DictEntries* (self: Reader): INTEGER;
VAR
    n: INTEGER;

BEGIN
    n := 0;
    IF self.huff # NIL THEN
        n := self.huff.Entries(self.huff)
    END;

    RETURN n
END DictEntries;


(* One entry of the dictionary, appended to dst as the bytes the file holds,
   and how many they were; -1 when the file has no such entry, which is also
   what a file with no dictionary answers for every index.

   The entries of a dictionary are not NUL terminated and may hold any byte at
   all, which is why the answer is a count and not a string: a caller that
   wants to read one back has to be told where it ends. *)
PROCEDURE DictWord* (self: Reader; i: INTEGER; dst: ByteArray): INTEGER;
VAR
    n: INTEGER;

BEGIN
    n := -1;
    IF self.huff # NIL THEN
        n := self.huff.Word(self.huff, i, dst)
    END;

    RETURN n
END DictWord;


(* How often one style byte was seen in the attribute blocks read since the
   file was opened, and how many style bytes there were in all.  A diagnostic,
   and what a report of a database reads. *)
PROCEDURE StyleByte* (self: Reader; i: INTEGER): INTEGER;
VAR
    n: INTEGER;

BEGIN
    n := 0;
    IF (i >= 0) & (i < 256) THEN
        n := self.styleBytes[i]
    END;

    RETURN n
END StyleByte;


PROCEDURE StyleTotal* (self: Reader): INTEGER;
BEGIN
    RETURN self.styleTotal
END StyleTotal;


(* The name of a topic: the text of its `:n` command, without the command
   itself, truncated to the caller's array.  The answer is FALSE, and the name
   empty, when the topic carries no such command or cannot be read at all - and
   a topic without a name is one Find can never return.

   The topic is decoded whole to read it, because its name is in the compressed
   text and nowhere else in the file; `buf` is clobbered. *)
PROCEDURE Name* (self: Reader; topic: INTEGER; VAR name: ARRAY OF CHAR): BOOLEAN;
VAR
    len, pos, tp, tl, ap, al: INTEGER;
    found: BOOLEAN;

BEGIN
    Clear(name);
    len := Decode(self, topic, self.buf);
    pos := 0;
    found := FALSE;
    WHILE ~found & (len > 0) & Line(self, self.buf, len, pos, tp, tl, ap, al) DO
        IF Command(self, self.buf, tp, tl) = "n" THEN
            ArrToStrN(self.buf, tp + 2, tl - 2, name);
            found := TRUE
        END
    END;

    RETURN found
END Name;


(* The text of a topic, replacing whatever dst held: the characters of its
   lines, each ended with CR LF, and its command lines left out.  The answer is
   the length, or -1 for a topic that cannot be read, and 0 for one that holds
   nothing and for one that holds nothing but commands.

   What comes out is bytes of the file's own code page - CP437 in practice -
   with no mapping to any other: the caller decides what a byte means.  Styles,
   links and the line structure itself are not here; Raw is what keeps them. *)
PROCEDURE Text* (self: Reader; topic: INTEGER; dst: ByteArray): INTEGER;
VAR
    len: INTEGER;

BEGIN
    len := Decode(self, topic, self.buf);
    dst.SetLength(dst, 0);
    IF len > 0 THEN
        len := Flatten(self, self.buf, len, dst)
    ELSIF len < 0 THEN
        len := -1
    END;

    RETURN len
END Text;


(* Whether the topic carries an `:x` command, which is how a database marks a
   topic that a contents list leaves out.  `buf` is clobbered. *)
PROCEDURE Hidden* (self: Reader; topic: INTEGER): BOOLEAN;
VAR
    len, pos, tp, tl, ap, al: INTEGER;
    found: BOOLEAN;

BEGIN
    len := Decode(self, topic, self.buf);
    found := FALSE;
    pos := 0;
    WHILE ~found & (len > 0) & Line(self, self.buf, len, pos, tp, tl, ap, al) DO
        IF Command(self, self.buf, tp, tl) = "x" THEN
            found := TRUE
        END
    END;

    RETURN found
END Hidden;


(* The topic as the file carries it, decoded and nothing else: the line records
   with their length bytes, their attribute blocks, their styles and their
   links, and their commands where the commands are.  The answer is the length,
   or -1 for a topic that cannot be read.  A caller that wants the drawn text
   wants Text; this is for one that walks the records itself. *)
PROCEDURE Raw* (self: Reader; topic: INTEGER; dst: ByteArray): INTEGER;
BEGIN
    RETURN Decode(self, topic, dst)
END Raw;


(* The number of the first topic whose name matches, or -1.  Only the name is
   looked at in either mode: not the text of a topic and not a context name,
   and a topic that carries no `:n` cannot match at all.

   Exact reads the whole argument as one name; AllWords splits it on spaces and
   asks that every word occur in the name.  Case is not significant in either
   mode, leading and trailing spaces are ignored, and a run of spaces between
   two words is one separator.

   The search decodes every topic of the database, because a name lives in the
   compressed text and nowhere else in the file.  That is the price of the
   format; there is no index of names to be had, since the format has none. *)
PROCEDURE Find* (self: Reader; keywords: ARRAY OF CHAR; mode: INTEGER): INTEGER;
VAR
    t, i, j, lo, hi, slen, result: INTEGER;
    name: ARRAY MAX_TITLE OF CHAR;
    hit: BOOLEAN;

BEGIN
    result := -1;
    Trim(keywords, lo, hi);
    IF hi > lo THEN
        t := 0;
        WHILE (result < 0) & (t < self.topics) DO
            IF Name(self, t, name) THEN
                slen := StrLen(name);
                IF mode = Exact THEN
                    hit := SpanEq(name, slen, keywords, lo, hi - lo)
                ELSE
                    hit := TRUE;
                    i := lo;
                    WHILE hit & (i < hi) DO
                        j := i;
                        WHILE (j < hi) & (keywords[j] # SPACE) DO
                            INC(j)
                        END;
                        IF j > i THEN
                            hit := SpanIn(name, slen, keywords, i, j - i)
                        END;
                        i := j;
                        WHILE (i < hi) & (keywords[i] = SPACE) DO
                            INC(i)
                        END
                    END
                END;
                IF hit THEN
                    result := t
                END
            END;
            INC(t)
        END
    END;

    RETURN result
END Find;


PROCEDURE Msg* (self: Reader; VAR s: ARRAY OF CHAR);
BEGIN
    StrCopy(s, self.msg)
END Msg;


(* Give the decompressor, the two working arrays and the record back to the
   allocator.  The caller's variable is dangling afterwards and the methods
   must not be called again. *)
PROCEDURE Done* (self: Reader);
BEGIN
    Close(self);
    self.buf.Done(self.buf);
    self.sect.Done(self.sect);
    self.huff.Done(self.huff);
    DISPOSE(self)
END Done;


(* A reader with no file open.  This is where the methods are bound to the
   record: after it returns, r.Open is Open and so on, and the caller needs
   nothing but the value it was handed. *)
PROCEDURE Create* (): Reader;
VAR
    self: Reader;
    i: INTEGER;

BEGIN
    NEW(self);
    self.base := 0;
    self.size := 0;
    self.topics := 0;
    self.contexts := 0;
    self.names := 0;
    self.yielded := 0;
    self.width := 0;
    self.attributes := 0;
    self.sensitive := FALSE;
    self.locked := FALSE;
    self.ctrl := 0X;
    self.reserved1 := 0;
    self.reserved3 := 0;
    self.title := 0;
    self.topicIndex := 0;
    self.keywords := 0;
    self.huffman := 0;
    self.topicText := 0;
    self.ctxStrings := 0;
    self.ctxMap := 0;
    self.lastUsed := 0;
    self.lastBlob := 0;
    self.styleTotal := 0;
    self.keepArrow := FALSE;
    FOR i := 0 TO 255 DO
        self.styleBytes[i] := 0
    END;
    Clear(self.dbName);
    Clear(self.msg);
    self.huff := HuffDec.Create();
    self.sect := ByteArr.Create(0);
    self.buf := ByteArr.Create(0);
    self.Open := Open;
    self.Close := Close;
    self.Topics := Topics;
    self.Name := Name;
    self.Text := Text;
    self.Raw := Raw;
    self.Find := Find;
    self.Hidden := Hidden;
    self.Contexts := Contexts;
    self.Names := Names;
    self.ContextTopic := ContextTopic;
    self.ContextName := ContextName;
    self.DbName := DbName;
    self.Width := Width;
    self.Ctrl := Ctrl;
    self.Sensitive := Sensitive;
    self.Locked := Locked;
    self.FileTitle := FileTitle;
    self.FileSize := FileSize;
    self.Header := Header;
    self.Offsets := Offsets;
    self.BlobUsed := BlobUsed;
    self.BlobSize := BlobSize;
    self.TreeNodes := TreeNodes;
    self.DictEntries := DictEntries;
    self.DictWord := DictWord;
    self.StyleByte := StyleByte;
    self.StyleTotal := StyleTotal;
    self.Line := Line;
    self.IsCommand := IsCommand;
    self.Command := Command;
    self.Attrs := Attrs;
    self.KeepArrow := KeepArrow;
    self.Msg := Msg;
    self.Done := Done;

    RETURN self
END Create;


END QHReader.
