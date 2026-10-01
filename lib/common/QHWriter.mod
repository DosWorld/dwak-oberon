(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A writer of an MS-DOS QuickHelp `.hlp` database, in object-oriented style
   and shared by every target.  It is the other half of QHReader: it is told
   where a topic begins, what its title is and what each of its lines holds,
   and it writes the file.  Nothing here is about Markdown or about any other
   notation - the caller reads its own source and hands over the characters.

   The style is ByteArr's: the record carries a pointer to every method beside
   the data, Create binds them, and a caller writes

       w := QHWriter.Create();
       w.Pass(w, QHWriter.Count);
       ... one walk over the source: w.Topic(w, n), w.Title(w, ..),
           w.Line(w, ..), and w.EndTopic(w) at the end of every topic ...
       flat := w.Tree(w, flat);
       w.Pass(w, QHWriter.Measure);
       ... the same walk again ...
       IF w.Save(w, "out.hlp") THEN
           w.Pass(w, QHWriter.Write);
           ... the same walk a third time ...
           ok := w.Finish(w)
       END;
       w.Done(w)

   and never names the module again except for those constants.  The receiver
   is handed over by hand, because this dialect has no implicit self, so a call
   is w.Topic(w, 0) and w.Topic(0) is a parameter error.

   Three passes are needed because two of the file's sections cannot be written
   before the whole of the source has been seen.  The header names the section
   offsets and the topic index holds the size of every topic, and the size of a
   topic depends on the tree, which is built from the frequencies of all of
   them.  So Count walks the source counting the topics and the symbols,
   Measure asks the encoder how long each topic will be now that the tree is
   known, and Write produces the file.  A pass keeps nothing but its own
   numbers: the source is read again rather than a topic held in memory, and
   the bytes of a topic are built up in one growable array that is emptied at
   the start of the next one.

   The compression is not repeated here.  A topic is a WORD of declared length
   and then a Huffman, dictionary and run-length stream, and that stream is the
   whole business of HuffEnc, which this module drives; what is added here is
   the file around it - the header, the topic index, the line records a topic
   is built from, and the two sections the codec is loaded from.

   Two sections beside the topics are the caller's to fill and are written
   empty when it does not.  A context is the name a reader searches for, and it
   is given one at a time with Context.  A dictionary is a compression tool,
   and it is given whole with Dictionary - whole because it is a section of the
   file and not a list the writer assembles, and because the encoder indexes it
   once rather than reading it per topic.  Both empty forms are legal: a reader
   opens a database with no contexts, and reads a dictionary section of no
   entries.  Neither touches the topic text or the topic index.

   A link's target is either a topic number or a string.  A topic number is
   written in the form every reader here resolves - `@L` and four hex digits -
   and any other target is written as the caller spelled it, because a target
   this writer cannot resolve is exactly the one a caller has to carry
   verbatim: a context name, `!B`, or the `FILE.HLP!context` of a jump into
   another database.
*)
MODULE QHWriter;

IMPORT Files, ByteArr, HuffEnc;


CONST
    (* The header, PLAN.MD section 3.1, 70 bytes: the two signature bytes are
       the bytes 4C 4EH in that order, so the word that writes them little
       endian is 4E4CH and not 4C4EH. *)
    H_SIGNATURE  =  0;
    H_VERSION    =  2;
    H_ATTRIBUTES =  4;                  (* bit 0: contexts are case sensitive *)
    H_CONTROL    =  6;                  (* what opens a command line, `:` *)
    H_TOPICS     =  8;
    H_CONTEXTS   = 0AH;
    H_WIDTH      = 0CH;                 (* the database's own display width *)
    H_PREDEFINED = 0EH;
    H_NAME       = 10H;
    H_RESERVED1  = 1EH;
    H_TOPICINDEX = 22H;
    H_CTXSTR     = 26H;
    H_CTXMAP     = 2AH;
    H_KEYWORDS   = 2EH;
    H_HUFFMAN    = 32H;
    H_TOPICTEXT  = 36H;
    H_TITLE      = 3AH;                 (* where the /N title is, or 0 *)
    H_RESERVED3  = 3EH;
    H_SIZE       = 42H;
    H_LEN        = 46H;

    (* What a pass over the source is for. *)
    Count*   = 0;                       (* the frequencies of the whole file *)
    Measure* = 1;                       (* how long each topic will be *)
    Write*   = 2;                       (* the file itself *)

    (* What a finished topic was missing, one bit each.  None of them changes
       the bytes written: every one is a complaint about the source, and the
       caller is the one that has a line number to report it with. *)
    NoTitle*     = 1;                   (* a topic with no heading *)
    TooLong*     = 2;                   (* a topic longer than a WORD counts *)
    SizeChanged* = 4;                   (* a topic that is not the size it
                                           measured *)

    MAX_TEXT   = 254;                   (* the format's own bound on a line,
                                           in characters and in style runs *)
    MAX_LINKS  = 32;                    (* at most this many on one line *)
    MAX_TOPICS = 4096;                  (* the most this writer can hold the
                                           sizes of, which is what the index
                                           is written from *)
    MAX_NAME   = 14;                    (* the header's own name field *)
    MAX_TITLE  = 256;                   (* the file's title, HELPMAKE's /N:
                                           a string with no bound of the
                                           format's own *)
    MAX_BLOB   = 65536;                 (* OUTLEN is a WORD *)
    MAX_TARGET = 64;                    (* a link target as written, NUL and
                                           all; the reader's bound is the
                                           same one *)
    MAX_CTX    = 4096;                  (* contexts, of a WORD-wide count *)
    DB_WIDTH   = 78;                    (* what a reference database says *)
    DB_VERSION = 2;                     (* what every file seen says *)
    DB_CTRL    = 3AH;                   (* `:`, what opens a command line *)


TYPE
    ByteArray* = ByteArr.ByteArray;

    (* A link as the file records it: the first and the last column it covers,
       1-based, and where it leads.  A target is a topic number or a string and
       which of the two it is, is `topic`: a number 0 or more is written as the
       empty target the format spells a cross-reference with and the number in
       two bytes after it, and `target` is then not looked at, while -1 means
       the link leads somewhere this file cannot name and `target` is written
       as it stands. *)
    Link* = RECORD
        first*, last*, topic*: INTEGER;
        target*: ARRAY MAX_TARGET OF CHAR
    END;
    Links* = ARRAY MAX_LINKS OF Link;

    (* One style byte per character of a line.  Bold is 1, italic 2, underline
       4, and the writer only copies them: which combination means what is the
       caller's business and the reader's. *)
    Styles* = ARRAY MAX_TEXT OF INTEGER;

    Writer* = POINTER TO WriterDesc;
    WriterDesc* = RECORD
        (* The pass being made, and what it has found so far.  The topic under
           construction is built into blob, and its length is kept beside it
           because the array cannot say how much of it is this topic's. *)
        mode:    INTEGER;
        topics:  INTEGER;
        done:    INTEGER;
        topic:   INTEGER;               (* -1 before the first of a pass *)
        blobLen: INTEGER;
        full:    BOOLEAN;               (* the topic ran past MAX_BLOB *)
        titled:  BOOLEAN;               (* a heading has been seen for it *)
        sizes:   ARRAY MAX_TOPICS OF INTEGER;   (* one per topic, in the
                                                   order they were written *)

        (* The compressor and the three arrays it works through: the topic as
           a decoder must produce it, the compressed form of it, and the tree
           section on its way out. *)
        enc:     HuffEnc.Compressor;
        blob:    ByteArr.ByteArray;
        outBuf:  ByteArr.ByteArray;
        treeBuf: ByteArr.ByteArray;

        name:    ARRAY MAX_NAME OF CHAR;
        hdr:     ARRAY H_LEN OF CHAR;

        (* The file's title - HELPMAKE's /N, one string for the whole
           database - and the number of bytes of the section that carries it,
           which is its length with the NUL on the end.  Zero says the file
           has no title and no section. *)
        title:    ARRAY MAX_TITLE OF CHAR;
        titleLen: INTEGER;
        dst:     Files.File;
        opened:  BOOLEAN;               (* dst holds an open file *)
        ok:      BOOLEAN;               (* nothing has failed yet *)
        total:   INTEGER;               (* the size of the file, after Save *)
        dataOff: INTEGER;               (* where the topic text begins *)
        flat:    BOOLEAN;               (* the tree compresses nothing *)

        (* The two sections that stand between the topic index and the topic
           text.  Both are held in the form the file wants them, so writing
           them is a copy: `dictBlob` is the run of length-prefixed entries of
           section 2, and `ctxBlob` is the NUL-terminated names.  Their lengths
           are kept beside them because a ByteArray cannot say how much of
           itself a section is. *)
        dictBlob: ByteArr.ByteArray;
        dictLen:  INTEGER;
        ctxBlob:  ByteArr.ByteArray;
        ctxLen:   INTEGER;
        ctxmap:   ARRAY MAX_CTX OF INTEGER;
        nctx:     INTEGER;

        (* The header fields that are the source's and not the writer's.
           None of them changes the bytes of a topic; they are here because a
           database carries the display width it was made for and the control
           character its command lines use, and a caller that decoded one may
           hand both back. *)
        version:    INTEGER;
        attributes: INTEGER;
        predefined: INTEGER;
        width:      INTEGER;
        control:    INTEGER;

        (* The header's two junk DWORDs, which a caller that decoded a
           database may hand back: neither is checked and neither means
           anything, but zeroing them would not be copying the file. *)
        reserved1:  INTEGER;
        reserved3:  INTEGER;

        (* One pointer per method, bound by Create. *)
        Pass*:     PROCEDURE (self: Writer; mode: INTEGER);
        Topic*:    PROCEDURE (self: Writer; n: INTEGER): BOOLEAN;
        Title*:    PROCEDURE (self: Writer; text: ARRAY OF CHAR; len: INTEGER;
                                  VAR styles: Styles): BOOLEAN;
        Line*:     PROCEDURE (self: Writer; text: ARRAY OF CHAR; len: INTEGER;
                              VAR styles: Styles; VAR links: Links;
                              nlinks: INTEGER): BOOLEAN;
        Command*:  PROCEDURE (self: Writer; text: ARRAY OF CHAR;
                              len: INTEGER): BOOLEAN;
        EndTopic*: PROCEDURE (self: Writer): INTEGER;
        Tree*:     PROCEDURE (self: Writer; flat: BOOLEAN): BOOLEAN;
        Name*:     PROCEDURE (self: Writer; name: ARRAY OF CHAR);
        FileTitle*: PROCEDURE (self: Writer; title: ARRAY OF CHAR);
        Reserved*: PROCEDURE (self: Writer; reserved1, reserved3: INTEGER);
        Header*:   PROCEDURE (self: Writer; version, attributes, predefined,
                                  width, control: INTEGER);
        Dictionary*: PROCEDURE (self: Writer; blob: ByteArray): INTEGER;
        Context*:  PROCEDURE (self: Writer; name: ARRAY OF CHAR;
                              topic: INTEGER): BOOLEAN;
        Save*:     PROCEDURE (self: Writer; path: ARRAY OF CHAR): BOOLEAN;
        Finish*:   PROCEDURE (self: Writer): BOOLEAN;
        Topics*:   PROCEDURE (self: Writer): INTEGER;
        Total*:    PROCEDURE (self: Writer): INTEGER;
        Flat*:     PROCEDURE (self: Writer): BOOLEAN;
        Done*:     PROCEDURE (self: Writer)
    END;


PROCEDURE Clear (VAR s: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE i < LEN(s) DO
        s[i] := 0X;
        INC(i)
    END
END Clear;


(* One byte of the topic under construction.

   The low byte is what goes out, and the mask says so rather than leaving it
   to the assignment: an attribute block can be longer than a byte counts when
   a line carries many style runs or many links, and the field it is written
   into is a BYTE.  A topic whose bytes no longer fit a WORD is not a topic the
   format has, so the run stops at the bound and the caller is told at the end
   of the topic. *)
PROCEDURE PutBlob (self: Writer; b: INTEGER);
BEGIN
    IF self.blobLen < MAX_BLOB THEN
        self.blob.Append8(self.blob, b MOD 256);
        INC(self.blobLen)
    ELSE
        self.full := TRUE
    END
END PutBlob;


(* How many bytes a link's target takes, its own NUL terminator included.  The
   length of the whole attribute block is written before the block is, so this
   is asked of every link before any of them is written.

   A topic number is three bytes - the empty target, which is a NUL, and the
   number's two - and a string target is its own characters and a NUL, which is
   why this is measured here and not written as a constant. *)
PROCEDURE TargetLen (VAR lk: Link): INTEGER;
VAR
    i: INTEGER;

BEGIN
    IF lk.topic >= 0 THEN
        i := 3                          (* the empty target and the number *)
    ELSE
        i := 1;                         (* the NUL alone *)
        WHILE (i < MAX_TARGET) & (lk.target[i - 1] # 0X) DO
            INC(i)
        END
    END;

    RETURN i
END TargetLen;


(* The target of a link as the file spells it.

   A topic number is written the way a QuickHelp database writes its own
   cross-references and the way every reader here resolves them: an empty
   target - the NUL this procedure ends with - followed by the number in two
   bytes with the 8000H that says it is a topic.  That is three bytes where the
   `@L` and four hex digits of section 6 are seven, and it is what makes the
   qbasic.hlp of this repository read back byte for byte: that file holds 1055
   links of this form and not one target spelled out as `@L` text, and the
   reader takes either.

   Any other target is written as the caller spelled it - a context name, `!B`,
   the `FILE.HLP!context` of a jump into another database - because a target
   this writer cannot resolve is exactly the one that has to survive verbatim.
   The list of links is a run of NUL terminated targets, and this writes the
   terminator: without it a reader walks off the end of the block and drops
   every link of the line. *)
PROCEDURE PutTarget (self: Writer; VAR lk: Link);
VAR
    v, i: INTEGER;

BEGIN
    IF lk.topic >= 0 THEN
        v := lk.topic + 8000H;
        PutBlob(self, 0);               (* the empty target ... *)
        PutBlob(self, v MOD 256);       (* ... and the number, low byte first *)
        PutBlob(self, v DIV 256)
    ELSE
        i := 0;
        WHILE (i < MAX_TARGET - 1) & (lk.target[i] # 0X) DO
            PutBlob(self, ORD(lk.target[i]));
            INC(i)
        END;
        PutBlob(self, 0)
    END
END PutTarget;


(* The line record: its length, its text, the length of its attributes and the
   attributes.  The attribute block is a run of characters whose style is the
   default one, then a style byte and a length for every run that differs, and
   then, when there are links, an 0FFH and the links.  A link is its first and
   last column and a target, and a column is a byte.

   The length of the text counts itself, so the caller's len is at most
   MAX_TEXT and the byte written is one more than the characters.  The same
   bound is the caller's because the characters are the caller's: nothing here
   can drop one. *)
PROCEDURE EmitLine (self: Writer; text: ARRAY OF CHAR; len: INTEGER;
                    VAR styles: Styles; VAR links: Links; nlinks: INTEGER);
VAR
    i, st, run, alen: INTEGER;

BEGIN
    PutBlob(self, len + 1);
    i := 0;
    WHILE i < len DO
        PutBlob(self, ORD(text[i]));
        INC(i)
    END;

    (* The length of the attribute block counts itself, so it is one more than
       the bytes that follow: the run of unstyled characters that opens the
       block, two bytes for every style run after it, and 0FFH and, per link,
       the first column, the last and the target with its terminator. *)
    alen := 2;
    i := 0;
    WHILE (i < len) & (styles[i] = 0) DO
        INC(i)
    END;
    WHILE i < len DO
        st := styles[i];
        WHILE (i < len) & (styles[i] = st) DO
            INC(i)
        END;
        INC(alen, 2)
    END;
    IF nlinks > 0 THEN
        INC(alen, 1);
        i := 0;
        WHILE i < nlinks DO
            INC(alen, 2 + TargetLen(links[i]));
            INC(i)
        END
    END;

    PutBlob(self, alen);
    i := 0;
    WHILE (i < len) & (styles[i] = 0) DO
        INC(i)
    END;
    PutBlob(self, i);
    WHILE i < len DO
        st := styles[i];
        run := i;
        WHILE (i < len) & (styles[i] = st) DO
            INC(i)
        END;
        PutBlob(self, st);
        PutBlob(self, i - run)
    END;

    IF nlinks > 0 THEN
        PutBlob(self, 0FFH);
        i := 0;
        WHILE i < nlinks DO
            PutBlob(self, links[i].first);
            PutBlob(self, links[i].last);
            PutTarget(self, links[i]);
            INC(i)
        END
    END
END EmitLine;


(* A line record for a title: the command character, the letter, and then the
   text, with the styles the caller gives but never a link.  The command is
   part of the line, so it is counted by the line's own length byte - two bytes
   written beside the text rather than before the byte - and it is unstyled,
   which is why the run of unstyled characters the block opens with starts two
   characters further along than the caller's own styles do.

   That a title has no links is the one place this module knowingly parts with
   the writer it was taken from.  There a title went through the same routine a
   line of the body does, and that routine takes the link list from beside the
   line rather than in it: the caller fills it, and a title filled nothing, so
   every title went out carrying a copy of the links of the last body line
   before it, with first and last columns belonging to a longer line.  135 of
   the 366 titles of qbasic.md caught one that way, and qbasic.hlp itself - the
   1996 file this family of programs is checked against - has not one title
   that carries a link.

   The answer is FALSE when the title does not fit a line record, and the
   record written is then the MAX_TEXT characters that do, which is what a
   caller that builds its line character by character ends up with. *)
PROCEDURE Title* (self: Writer; text: ARRAY OF CHAR; len: INTEGER;
                   VAR styles: Styles): BOOLEAN;
VAR
    i, st, run, alen, n: INTEGER;

BEGIN
    n := len + 2;
    IF n > MAX_TEXT THEN
        n := MAX_TEXT
    END;
    PutBlob(self, n + 1);
    PutBlob(self, ORD(":"));
    PutBlob(self, ORD("n"));
    i := 0;
    WHILE i < n - 2 DO
        PutBlob(self, ORD(text[i]));
        INC(i)
    END;

    (* The attribute block, built the way EmitLine builds one but with no links
       to follow it.  The run of characters whose style is the default one
       opens the block, and the `:n` are two of them, so the count written is
       the caller's own unstyled head plus those two. *)
    alen := 2;
    i := 0;
    WHILE (i < len) & (styles[i] = 0) DO
        INC(i)
    END;
    WHILE i < len DO
        st := styles[i];
        WHILE (i < len) & (styles[i] = st) DO
            INC(i)
        END;
        INC(alen, 2)
    END;
    PutBlob(self, alen);
    i := 0;
    WHILE (i < len) & (styles[i] = 0) DO
        INC(i)
    END;
    PutBlob(self, i + 2);
    WHILE i < len DO
        st := styles[i];
        run := i;
        WHILE (i < len) & (styles[i] = st) DO
            INC(i)
        END;
        PutBlob(self, st);
        PutBlob(self, i - run)
    END;
    self.titled := TRUE;

    RETURN n = len + 2
END Title;


(* A command line that is not a title: `:l` and the number of a parent topic,
   `:x` for a hidden one, or the `: ` that opens a line of no text at all.

   The whole line is the command, so there is nothing here of what Title has -
   no text beside the two command bytes, no style and no link - and the record
   is the characters the caller gives and one run of unstyled characters over
   all of them.  A command is written where it stands among the lines of its
   topic and not at either end of them: the format has one command per line
   record, and a caller that decoded a database put each of them back where it
   found it.

   The answer is FALSE when the line does not fit a line record, in which case
   nothing is written.  A command of no characters is refused: the control
   character is what makes the line a command at all. *)
PROCEDURE Command* (self: Writer; text: ARRAY OF CHAR; len: INTEGER): BOOLEAN;
VAR
    i, n: INTEGER;
    fits: BOOLEAN;

BEGIN
    fits := (len >= 1) & (len <= MAX_TEXT);
    IF fits THEN
        n := len;
        PutBlob(self, n + 1);
        i := 0;
        WHILE i < n DO
            PutBlob(self, ORD(text[i]));
            INC(i)
        END;
        PutBlob(self, 2);               (* the block, and the one run in it *)
        PutBlob(self, n)                (* every character of it is unstyled *)
    END;

    RETURN fits
END Command;


(* One line of the body.  The characters are the caller's, already turned into
   the bytes of the code page; the styles and the links are its too, and a link
   column is 1-based and counts characters of the line and not bytes of the
   file.

   The answer is FALSE when the line does not fit a record, in which case
   nothing was written: a caller that builds its characters one at a time has
   already stopped at MAX_TEXT of them, so the refusal is a guard on the bound
   and not a way of trimming a line. *)
PROCEDURE Line* (self: Writer; text: ARRAY OF CHAR; len: INTEGER;
                 VAR styles: Styles; VAR links: Links;
                 nlinks: INTEGER): BOOLEAN;
VAR
    fits: BOOLEAN;

BEGIN
    fits := (len <= MAX_TEXT) & (nlinks >= 0) & (nlinks <= MAX_LINKS);
    IF fits THEN
        EmitLine(self, text, len, styles, links, nlinks)
    END;

    RETURN fits
END Line;


(* Begin a topic that the source says is number n.  The answer is whether it is
   the next one: a topic index is what the file is written from, so a source
   that names them out of order, or skips one, is a source this writer cannot
   place, and the caller says so rather than being stopped. *)
PROCEDURE Topic* (self: Writer; n: INTEGER): BOOLEAN;
BEGIN
    self.topic := n;
    self.blobLen := 0;
    self.full := FALSE;
    self.titled := FALSE;
    self.blob.SetLength(self.blob, 0);

    RETURN n = self.done
END Topic;


(* End the topic under construction, and answer what was wrong with it as a set
   of bits.  What a pass does with it is the whole difference between the three
   of them: Count adds its characters to the frequencies of the file, Measure
   asks the encoder how long it will be, and Write produces it and compares the
   length with the one Measure gave.

   The encoder reads a ByteArray and the topic is already one, so there is no
   copy here: what is encoded is exactly what PutBlob built. *)
PROCEDURE EndTopic* (self: Writer): INTEGER;
VAR
    problems, n: INTEGER;

BEGIN
    problems := 0;
    IF self.topic >= 0 THEN
        IF ~self.titled THEN
            problems := problems + NoTitle
        END;
        IF self.full THEN
            problems := problems + TooLong
        END;
        INC(self.done);
        IF self.mode = Count THEN
            self.enc.Count(self.enc, self.blob);
            INC(self.topics)
        ELSIF self.mode = Measure THEN
            (* OUTLEN and then the bits, rounded up to whole bytes: the size
               of the topic in the file, which the index holds. *)
            self.sizes[self.topic] := 2 + (self.enc.Bits(self.enc, self.blob) + 7) DIV 8
        ELSE
            self.outBuf.SetLength(self.outBuf, 0);
            self.enc.Encode(self.enc, self.blob, self.outBuf);
            self.enc.Finish(self.enc, self.outBuf);
            n := 2 + self.outBuf.Length(self.outBuf);
            IF Files.WriteWord(self.dst, self.blobLen) # 2 THEN
                n := -1                     (* the file refused the OUTLEN word *)
            ELSIF ~self.outBuf.Write(self.outBuf, self.dst) THEN
                n := -1                     (* or the blob that follows it *)
            END;
            IF n # self.sizes[self.topic] THEN
                problems := problems + SizeChanged
            END
        END
    END;
    self.topic := -1;

    RETURN problems
END EndTopic;


(* Build the tree the topics are compressed with, which can only be done once
   the whole file has been counted.  The answer is the tree this writer now
   has: the flat one when the caller asked for it, and the flat one as well
   when there is nothing to compress with, which is what a source of one
   repeated character amounts to. *)
PROCEDURE Tree* (self: Writer; flat: BOOLEAN): BOOLEAN;
VAR
    isFlat: BOOLEAN;

BEGIN
    isFlat := flat;
    IF ~isFlat THEN
        isFlat := ~self.enc.Huffman(self.enc)
    END;
    IF isFlat THEN
        self.enc.Flat(self.enc)
    END;
    self.flat := isFlat;

    RETURN isFlat
END Tree;


(* The name the header carries: fourteen bytes holding the name the database
   was compressed from, such as `qb45advr.hlp`, which is how a reader tells
   one file of a concatenated bunch from another.  It is not the name of the
   file on disk and it is not the title: the title is FileTitle, and it is a
   section of its own.  A shorter name is padded with NULs; a name of exactly
   fourteen is written whole and is not terminated, which is what the field's
   own width says. *)
PROCEDURE Name* (self: Writer; name: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < MAX_NAME) & (i < LEN(name)) & (name[i] # 0X) DO
        self.name[i] := name[i];
        INC(i)
    END;
    WHILE i < MAX_NAME DO
        self.name[i] := 0X;
        INC(i)
    END
END Name;


(* The title of the whole database, HELPMAKE's /N.  It is not the name of the
   file and it is not the name of any topic: the file carries it once, in a
   section of its own that stands after the last topic, and the header points
   at it.  A writer that is never told one writes no such section, which is
   what all five databases measured here do.

   The section holds the string and the NUL that ends it, and the header's own
   field is the offset of the first byte: an empty title is written as the
   offset zero, which is the header itself and is the only spelling the format
   has for "this file has no title". *)
PROCEDURE FileTitle* (self: Writer; title: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < MAX_TITLE - 1) & (i < LEN(title)) & (title[i] # 0X) DO
        self.title[i] := title[i];
        INC(i)
    END;
    self.title[i] := 0X;
    IF i = 0 THEN
        self.titleLen := 0               (* an empty title is no title: the
                                            header's only way to say a file
                                            has none is the offset zero *)
    ELSE
        self.titleLen := i + 1           (* the section holds the NUL too *)
    END
END FileTitle;


(* The header's first and third junk DWORDs, put back where they were read.
   Neither is meaningful to any reader and neither is ever tested, but a
   database that comes back with them zeroed is not the database that went in:
   COBOL.HLP carries the bytes `JCK` and a CR at the first of them, and the
   reference for the format says outright that a reader may not test it. *)
PROCEDURE Reserved* (self: Writer; reserved1, reserved3: INTEGER);
BEGIN
    self.reserved1 := reserved1;
    self.reserved3 := reserved3
END Reserved;


(* A pass over the source begins here.  What it clears is what the walk
   accumulates: which topic is being built, how many this pass has finished,
   and - on the counting pass, which is the only one that sets it - how many
   the file has. *)
PROCEDURE Pass* (self: Writer; mode: INTEGER);
BEGIN
    self.mode := mode;
    self.topic := -1;
    self.done := 0;
    IF mode = Count THEN
        self.topics := 0
    END
END Pass;


PROCEDURE Put16 (VAR h: ARRAY OF CHAR; ofs, v: INTEGER);
BEGIN
    h[ofs] := CHR(v MOD 100H);
    h[ofs + 1] := CHR((v DIV 100H) MOD 100H)
END Put16;


PROCEDURE Put32 (VAR h: ARRAY OF CHAR; ofs, v: INTEGER);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE i < 4 DO
        h[ofs + i] := CHR(v MOD 100H);
        v := v DIV 100H;
        INC(i)
    END
END Put32;


(* The header, written before anything else in the file because it is what says
   where everything else is.

   The five sections between the index and the topic text are placed by running
   one cursor over them in the order they are written, so a section that is
   empty costs its own offset and nothing else.  An empty one makes two fields
   equal, which is exactly what an offset of the same value in two consecutive
   fields says - except for the dictionary, whose offset is 0 and not the next
   section's when it has no entries: the format spells "no dictionary" that way
   and every reader here tests the field for it.  The title is the same: 0 is
   the spelling for "none", and the caller has already worked its offset out
   because it is the one section that stands past the last topic. *)
PROCEDURE MakeHeader (self: Writer; total, dataOff, titleOff: INTEGER);
VAR
    i, off: INTEGER;

BEGIN
    i := 0;
    WHILE i < H_LEN DO
        self.hdr[i] := 0X;
        INC(i)
    END;
    Put16(self.hdr, H_SIGNATURE, 4E4CH);
    Put16(self.hdr, H_VERSION, self.version);
    Put16(self.hdr, H_ATTRIBUTES, self.attributes);
    Put16(self.hdr, H_CONTROL, self.control);
    Put16(self.hdr, H_TOPICS, self.topics);
    Put16(self.hdr, H_CONTEXTS, self.nctx);
    Put16(self.hdr, H_WIDTH, self.width);
    Put16(self.hdr, H_PREDEFINED, self.predefined);
    i := 0;
    WHILE i < MAX_NAME DO
        self.hdr[H_NAME + i] := self.name[i];
        INC(i)
    END;
    Put32(self.hdr, H_RESERVED1, self.reserved1);
    off := H_LEN + 4 * (self.topics + 1);
    Put32(self.hdr, H_TOPICINDEX, H_LEN);
    Put32(self.hdr, H_CTXSTR, off);
    INC(off, self.ctxLen);
    Put32(self.hdr, H_CTXMAP, off);
    INC(off, 2 * self.nctx);
    IF self.dictLen > 0 THEN
        Put32(self.hdr, H_KEYWORDS, off)
    ELSE
        Put32(self.hdr, H_KEYWORDS, 0)
    END;
    INC(off, self.dictLen);
    Put32(self.hdr, H_HUFFMAN, off);
    Put32(self.hdr, H_TOPICTEXT, dataOff);
    Put32(self.hdr, H_TITLE, titleOff);
    Put32(self.hdr, H_RESERVED3, self.reserved3);
    Put32(self.hdr, H_SIZE, total)
END MakeHeader;


(* Create the file and write everything that stands before the topic text: the
   header, the index - one offset per topic and one past the last - the context
   strings and their map, the dictionary and the tree.  The file is left open
   and the topics are written into it by the writing pass, which is what the
   indices just written are waiting for.

   The two numbers the header needs are computed here because both depend on
   all three passes: the size of a topic comes from Measure, the size of the
   tree from the counting, and the two together - with the two sections the
   caller filled, whose sizes are known before any pass - are the size of the
   file, which is the last field of the header. *)
PROCEDURE Save* (self: Writer; path: ARRAY OF CHAR): BOOLEAN;
VAR
    i, off, titleOff: INTEGER;
    ok: BOOLEAN;

BEGIN
    self.total := 0;
    i := 0;
    WHILE i < self.topics DO
        INC(self.total, self.sizes[i]);
        INC(i)
    END;
    self.dataOff := H_LEN + 4 * (self.topics + 1) + self.ctxLen +
                    2 * self.nctx + self.dictLen + self.enc.TreeSize(self.enc);
    INC(self.total, self.dataOff);

    (* The title is the one section of the format that stands after the topic
       text rather than among the five before it, so its offset is where the
       last topic ends - the number the index's own last DWORD carries, which
       is `total` as it stands here - and the file is that much longer than
       its index says.  A file with no title writes the offset zero, which is
       the header itself and is how the format says there is none.

       Only the offset is worked out here.  The bytes themselves are written
       by Finish, because the topic text has not been written yet at this
       point and the title stands behind all of it. *)
    titleOff := 0;
    IF self.titleLen > 0 THEN
        titleOff := self.total;
        INC(self.total, self.titleLen)
    END;

    ok := Files.ReWrite(self.dst, path);
    IF ok THEN
        self.opened := TRUE;
        MakeHeader(self, self.total, self.dataOff, titleOff);
        ok := Files.BlockWriteText(self.dst, self.hdr, H_LEN) = H_LEN;

        off := self.dataOff;
        i := 0;
        WHILE i < self.topics DO
            IF Files.WriteDWord(self.dst, off) # 4 THEN
                ok := FALSE
            END;
            INC(off, self.sizes[i]);
            INC(i)
        END;
        IF Files.WriteDWord(self.dst, off) # 4 THEN
            ok := FALSE
        END;

        IF ~self.ctxBlob.Write(self.ctxBlob, self.dst) THEN
            ok := FALSE
        END;
        i := 0;
        WHILE i < self.nctx DO
            IF Files.WriteWord(self.dst, self.ctxmap[i]) # 2 THEN
                ok := FALSE
            END;
            INC(i)
        END;
        IF ~self.dictBlob.Write(self.dictBlob, self.dst) THEN
            ok := FALSE
        END;

        self.treeBuf.SetLength(self.treeBuf, 0);
        self.enc.Tree(self.enc, self.treeBuf);
        IF ~self.treeBuf.Write(self.treeBuf, self.dst) THEN
            ok := FALSE
        END
    END;
    self.ok := ok;

    RETURN ok
END Save;


(* Close the file, and the answer is whether every buffered write reached it.
   A database that was refused for want of space looks exactly like one that
   was written, so this answer is the only way to tell. *)
PROCEDURE Finish* (self: Writer): BOOLEAN;
VAR
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    IF self.opened THEN
        (* The title is the one section of the format that stands after the
           topic text, so it cannot be written where Save writes the others:
           Save runs before the writing pass, and the topics are appended to
           the file after it.  Here the file is standing at the end of the
           last topic, which is exactly the offset the header was given. *)
        IF (self.titleLen > 0) &
           (Files.BlockWriteText(self.dst, self.title, self.titleLen) # self.titleLen) THEN
            self.ok := FALSE
        END;
        ok := Files.Ok(self.dst) & self.ok;
        Files.Close(self.dst);
        self.opened := FALSE
    END;

    RETURN ok
END Finish;


(* The header fields a source can know and the writer cannot.  Every one of
   them is written into the header of the file and none of them reaches a
   topic: the display width and the control character describe how a reader
   should draw what is there. *)
PROCEDURE Header* (self: Writer; version, attributes, predefined,
                   width, control: INTEGER);
BEGIN
    self.version := version;
    self.attributes := attributes;
    self.predefined := predefined;
    self.width := width;
    self.control := control
END Header;


(* The dictionary, whole and in the form the file wants it: a run of entries,
   each a BYTE length and that many bytes.  It is handed over rather than
   assembled here because it is a section of the file and because the encoder
   indexes it once - a dictionary given after the counting pass has begun would
   describe a stream that was counted without it, so this is called before
   Pass.

   The answer is how many entries it holds, which is what the encoder will
   index; more than 1024 is a dictionary a reference in the stream could not
   name, since an index is ten bits. *)
PROCEDURE Dictionary* (self: Writer; blob: ByteArray): INTEGER;
VAR
    p, n, len, q, count: INTEGER;

BEGIN
    self.dictBlob.SetLength(self.dictBlob, 0);
    n := blob.Length(blob);
    p := 0;
    count := 0;
    WHILE (p < n) & (count < 1024) DO
        len := blob.Get8(blob, p);
        IF p + 1 + len > n THEN
            p := n                          (* a truncated entry ends it *)
        ELSE
            self.dictBlob.Append8(self.dictBlob, len);
            q := 0;
            WHILE q < len DO
                self.dictBlob.Append8(self.dictBlob, blob.Get8(blob, p + 1 + q));
                INC(q)
            END;
            INC(p, 1 + len);
            INC(count)
        END
    END;
    self.dictLen := self.dictBlob.Length(self.dictBlob);
    self.enc.SetDictionary(self.enc, self.dictBlob);

    RETURN count
END Dictionary;


(* One context: the name a reader can search for, and the topic it belongs to.
   The names are written into the file in the order they are given and the map
   is parallel to them, so the order is the caller's and a reader that walks
   the two together sees them the way the file holds them.

   The answer is FALSE when the table is full or the name is empty, and nothing
   is written then: a context name is what a reader looks a topic up by, and an
   empty one is a name nothing can match. *)
PROCEDURE Context* (self: Writer; name: ARRAY OF CHAR;
                    topic: INTEGER): BOOLEAN;
VAR
    i, len: INTEGER;
    fits: BOOLEAN;

BEGIN
    len := 0;
    WHILE (len < LEN(name)) & (name[len] # 0X) DO
        INC(len)
    END;
    fits := (self.nctx < MAX_CTX) & (len > 0) & (topic >= 0);
    IF fits THEN
        i := 0;
        WHILE i < len DO
            self.ctxBlob.Append8(self.ctxBlob, ORD(name[i]));
            INC(i)
        END;
        self.ctxBlob.Append8(self.ctxBlob, 0);
        self.ctxmap[self.nctx] := topic;
        INC(self.nctx);
        self.ctxLen := self.ctxBlob.Length(self.ctxBlob)
    END;

    RETURN fits
END Context;


PROCEDURE Topics* (self: Writer): INTEGER;
BEGIN
    RETURN self.topics
END Topics;


PROCEDURE Total* (self: Writer): INTEGER;
BEGIN
    RETURN self.total
END Total;


PROCEDURE Flat* (self: Writer): BOOLEAN;
BEGIN
    RETURN self.flat
END Flat;


(* Give the compressor and the three arrays back to the allocator.  The file is
   closed first, so a writer that is dropped without Finish leaves nothing
   open.  The caller's variable is dangling afterwards and the methods must not
   be called again. *)
PROCEDURE Done* (self: Writer);
BEGIN
    IF self.opened THEN
        Files.Close(self.dst);
        self.opened := FALSE
    END;
    self.blob.Done(self.blob);
    self.outBuf.Done(self.outBuf);
    self.treeBuf.Done(self.treeBuf);
    self.dictBlob.Done(self.dictBlob);
    self.ctxBlob.Done(self.ctxBlob);
    self.enc.Done(self.enc);
    DISPOSE(self)
END Done;


(* A writer with no file open and nothing counted.  This is where the methods
   are bound to the record: after it returns, w.Topic is Topic and so on, and
   the caller needs nothing but the value it was handed. *)
PROCEDURE Create* (): Writer;
VAR
    self: Writer;
    i: INTEGER;

BEGIN
    NEW(self);
    self.mode := Count;
    self.topics := 0;
    self.done := 0;
    self.topic := -1;
    self.blobLen := 0;
    self.full := FALSE;
    self.titled := FALSE;
    self.opened := FALSE;
    self.ok := FALSE;
    self.total := 0;
    self.dataOff := 0;
    self.flat := FALSE;
    i := 0;
    WHILE i < MAX_TOPICS DO
        self.sizes[i] := 0;
        INC(i)
    END;
    self.version := DB_VERSION;
    self.attributes := 0;               (* the contexts are not case sensitive *)
    self.predefined := 0;
    self.width := DB_WIDTH;
    self.control := DB_CTRL;
    self.nctx := 0;
    self.ctxLen := 0;
    self.dictLen := 0;
    self.reserved1 := 0;
    self.reserved3 := 0;
    self.titleLen := 0;
    Clear(self.name);
    Clear(self.title);
    Clear(self.hdr);
    self.enc := HuffEnc.Create();
    self.blob := ByteArr.Create(0);
    self.outBuf := ByteArr.Create(0);
    self.treeBuf := ByteArr.Create(0);
    self.dictBlob := ByteArr.Create(0);
    self.ctxBlob := ByteArr.Create(0);
    self.Pass := Pass;
    self.Topic := Topic;
    self.Title := Title;
    self.Line := Line;
    self.Command := Command;
    self.EndTopic := EndTopic;
    self.Tree := Tree;
    self.Name := Name;
    self.FileTitle := FileTitle;
    self.Reserved := Reserved;
    self.Header := Header;
    self.Dictionary := Dictionary;
    self.Context := Context;
    self.Save := Save;
    self.Finish := Finish;
    self.Topics := Topics;
    self.Total := Total;
    self.Flat := Flat;
    self.Done := Done;

    RETURN self
END Create;


END QHWriter.
