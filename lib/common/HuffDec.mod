(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The Huffman decompressor of the QuickHelp `.hlp` format, in object-oriented
   style and shared by every target.  The format compresses a topic with three
   passes and this module is all three: a tree written as a run of WORDs, a
   stream of bits read from the most significant bit of a byte down, and the
   pass that turns a symbol back into bytes - a dictionary reference, two
   run-length forms and an escape.  There is no end-of-stream symbol: the
   caller says how many bytes the stream holds and the decoder stops there,
   which is how a topic of a `.hlp` file is decoded.

   The style is ByteArr's: the record carries a pointer to every method beside
   the data, Create binds them, and a caller writes

       d := HuffDec.Create();
       n := d.Load(d, tree);
       n := d.Dict(d, dictionary);
       d.Start(d, outLen);
       d.Feed(d, blob);
       n := d.Take(d, text);
       d.Finish(d);
       ok := d.Ok(d);
       d.Done(d)

   and never names the module again.  The receiver is handed over by hand,
   because this dialect has no implicit self, so a call is d.Take(d, text) and
   d.Take(text) is a parameter error.  What the record holds besides the
   methods is private: the tree, the dictionary and the bit cursor can only be
   reached through the methods.

   Both ends of the stream are ByteArray, and nothing here opens a file or
   knows what a database is.  Fed bytes are kept and read in place rather than
   copied out, so a caller may hand over a chunk at a time - Take answers with
   whatever the bytes fed so far can produce - and the same object decodes one
   topic after another, with the tree and the dictionary loaded once, because
   Start resets the stream and nothing else.

   Two properties are worth stating, since they are what the callers here rely
   on.  The stream is read lazily: a byte of the blob is fetched by the bit
   that needs it and no byte is fetched by a bit that does not, so Used is
   exactly the blob a topic spent and a decoder that read one bit too many
   would be visible in it.  And an instruction is decoded as a whole: when the
   bytes fed so far run out in the middle of one - which in a stream is not a
   fault but only the caller being early - the instruction's bits are given
   back and Take answers with what came before it, so the next Feed continues
   where the last one stopped rather than in the middle of a symbol.

   The dictionary is a section of length-prefixed entries and no entry is NUL
   terminated: its length byte is the only thing that ends one, and reading an
   entry as a string would run two of them together and desynchronise the very
   next symbol.  The entries are copied in here, so the caller may free the
   section it passed as soon as Dict returns.
*)
MODULE HuffDec;

IMPORT ByteArr;


CONST
    (* A tree over 256 leaves cannot exceed 511 nodes, and the run ends with
       one zero WORD more. *)
    MAXNODES* = 512;

    (* The ten-bit index of a dictionary entry, which is all a reference in
       the stream can name. *)
    MAXDICT* = 1024;

    (* What the third pass reads as an instruction rather than as a byte.
       10H..17H name a dictionary entry, 18H and 19H are the two run-length
       forms, and 1AH escapes the byte after it.  The names carry BYTE or CNT
       where the plain word is a keyword of the language. *)
    DICT_LOW    = 10H;
    SPACE_BYTE  = 20H;                  (* the space a run of spaces is made of *)
    SPACE_CNT   = 18H;
    REPEAT_BYTE = 19H;
    ESCAPE_BYTE = 1AH;

    (* A node value with this bit set is a leaf and its symbol is the low
       byte. *)
    LEAF = 8000H;


TYPE
    ByteArray* = ByteArr.ByteArray;

    Decompressor* = POINTER TO DecompressorDesc;
    DecompressorDesc* = RECORD
        (* The blob, kept as it was fed, and the cursor into it.  `cur` holds
           the byte being drained and `left` the bits of it not yet handed
           out, so nothing is fetched before it is wanted. *)
        src:     ByteArray;
        pos:     INTEGER;               (* the next byte of src to fetch *)
        cur:     INTEGER;
        left:    INTEGER;
        bits:    INTEGER;               (* bits handed out, the measure of Used *)
        starved: BOOLEAN;               (* a bit was wanted past the bytes fed *)

        (* The tree, as the file writes it, and the dictionary, as the file
           holds it.  Both survive Start, so one object reads many topics. *)
        nodes:   ARRAY MAXNODES OF INTEGER;
        nnodes:  INTEGER;
        dict:    ByteArray;             (* the entries, one after another *)
        dictAdr: ARRAY MAXDICT OF INTEGER;
        dictLen: ARRAY MAXDICT OF INTEGER;
        ndict:   INTEGER;

        (* The stream.  `want` is the length the caller declared and `got`
           what has been produced of it. *)
        want:    INTEGER;
        got:     INTEGER;
        bad:     BOOLEAN;               (* the stream is damaged, not merely short *)

        (* One pointer per method, bound by Create. *)
        Load*:    PROCEDURE (self: Decompressor; tree: ByteArray): INTEGER;
        Dict*:    PROCEDURE (self: Decompressor; section: ByteArray): INTEGER;
        Start*:   PROCEDURE (self: Decompressor; outLen: INTEGER);
        Feed*:    PROCEDURE (self: Decompressor; src: ByteArray);
        Take*:    PROCEDURE (self: Decompressor; dst: ByteArray): INTEGER;
        Finish*:  PROCEDURE (self: Decompressor);
        Used*:    PROCEDURE (self: Decompressor): INTEGER;
        Got*:     PROCEDURE (self: Decompressor): INTEGER;
        Want*:    PROCEDURE (self: Decompressor): INTEGER;
        Nodes*:   PROCEDURE (self: Decompressor): INTEGER;
        Entries*: PROCEDURE (self: Decompressor): INTEGER;
        Word*:    PROCEDURE (self: Decompressor; i: INTEGER;
                             dst: ByteArray): INTEGER;
        Ok*:      PROCEDURE (self: Decompressor): BOOLEAN;
        Done*:    PROCEDURE (self: Decompressor)
    END;

    (* Where the bit stream stood when an instruction began.  It is saved
       before the instruction and put back when the input runs out inside it,
       which is what makes a chunk boundary invisible: every field the bits
       move is here, and the answer is one assignment. *)
    Mark = RECORD
        pos, cur, left, bits: INTEGER;
        starved: BOOLEAN
    END;


PROCEDURE Save (self: Decompressor; VAR m: Mark);
BEGIN
    m.pos := self.pos;
    m.cur := self.cur;
    m.left := self.left;
    m.bits := self.bits;
    m.starved := self.starved
END Save;


PROCEDURE Restore (self: Decompressor; m: Mark);
BEGIN
    self.pos := m.pos;
    self.cur := m.cur;
    self.left := m.left;
    self.bits := m.bits;
    self.starved := m.starved
END Restore;


(* The tree is a run of WORDs ended by a zero WORD; a node with its high bit
   set is a leaf and its symbol is the low byte, and otherwise bit 0 of a code
   goes to node value DIV 2 and bit 1 to the node after this one.  The count
   returned is of nodes stored, without the terminator, so that the caller can
   tell a tree that ended where it should from one that ran into the section
   after it.

   The terminator is the whole WORD and not its low byte: a node may well be
   0XX00H, and a test of the low byte alone would end the tree there. *)
PROCEDURE Load* (self: Decompressor; tree: ByteArray): INTEGER;
VAR
    p, v, lim: INTEGER;

BEGIN
    self.nnodes := 0;
    lim := tree.Length(tree);
    p := 0;
    v := 1;
    WHILE (p + 2 <= lim) & (self.nnodes < MAXNODES) & (v # 0) DO
        v := tree.Get16(tree, p);
        IF v # 0 THEN
            self.nodes[self.nnodes] := v;
            INC(self.nnodes)
        END;
        p := p + 2
    END;

    RETURN self.nnodes
END Load;


(* The dictionary section: a run of entries, each a length byte and then that
   many bytes, with no terminator of any kind.  The count returned is of
   entries stored, which the caller compares against the section size - an
   entry that ran past the end would leave the last record short.  An offset
   of zero in the header means the file has no dictionary at all, and a file
   without one has no valid entry for the stream to name. *)
PROCEDURE Dict* (self: Decompressor; section: ByteArray): INTEGER;
VAR
    p, n, lim: INTEGER;

BEGIN
    self.dict.SetLength(self.dict, 0);
    self.dict.AppendFull(self.dict, section);
    lim := self.dict.Length(self.dict);
    self.ndict := 0;
    p := 0;
    WHILE (p < lim) & (self.ndict < MAXDICT) DO
        n := self.dict.Get8(self.dict, p);
        INC(p);
        self.dictAdr[self.ndict] := p;
        self.dictLen[self.ndict] := n;
        INC(self.ndict);
        p := p + n
    END;

    RETURN self.ndict
END Dict;


(* Begin a stream of outLen bytes.  The tree and the dictionary stay where they
   are - they belong to the database and not to the topic - while everything
   the bits move is reset, and the bytes fed for the previous stream are
   dropped rather than kept: a caller that decodes one topic after another
   would otherwise hold the whole file twice. *)
PROCEDURE Start* (self: Decompressor; outLen: INTEGER);
BEGIN
    self.src.SetLength(self.src, 0);
    self.pos := 0;
    self.cur := 0;
    self.left := 0;
    self.bits := 0;
    self.starved := FALSE;
    self.want := outLen;
    self.got := 0;
    self.bad := FALSE
END Start;


PROCEDURE Feed* (self: Decompressor; src: ByteArray);
BEGIN
    self.src.AppendFull(self.src, src)
END Feed;


(* One bit of the stream, the most significant of the byte first, which is the
   order the tree was written to be walked in.

   A bit wanted past the bytes fed so far is not a fault - the caller may have
   more to hand over - so it raises `starved` and answers zero, and the zero is
   only there so that the walk can stop.  A bit that was not really handed out
   is not counted, which keeps the bit count a measure of the blob and not of
   how much the caller happened to feed. *)
PROCEDURE Bit (self: Decompressor): INTEGER;
VAR
    k: INTEGER;

BEGIN
    k := 0;
    IF self.left = 0 THEN
        IF self.pos < self.src.Length(self.src) THEN
            self.cur := self.src.Get8(self.src, self.pos);
            INC(self.pos);
            self.left := 8
        ELSE
            self.starved := TRUE
        END
    END;
    IF ~self.starved THEN
        DEC(self.left);
        k := self.cur DIV 80H;
        self.cur := (self.cur MOD 80H) * 2;
        INC(self.bits)
    END;

    RETURN k
END Bit;


(* One symbol: the tree walked from its root, one bit per step, until a leaf is
   reached.  A code that leaves the node table answers -1, and one that walked
   in a circle still consumes a bit per step and so reaches the end of the
   bytes fed and stops. *)
PROCEDURE Symbol (self: Decompressor): INTEGER;
VAR
    i, v, sym: INTEGER;

BEGIN
    i := 0;
    sym := -1;
    WHILE (sym < 0) & (i < self.nnodes) & ~self.starved DO
        v := self.nodes[i];
        IF v >= LEAF THEN
            sym := v MOD 100H
        ELSIF Bit(self) = 0 THEN
            i := v DIV 2
        ELSE
            INC(i)
        END
    END;

    RETURN sym
END Symbol;


(* n bytes of one value appended to dst.  The declared length ends the stream,
   so a run that would pass it is cut there and the bits it cost are spent all
   the same - the decoder has read the count before it can know. *)
PROCEDURE PutRun (self: Decompressor; dst: ByteArray; v, n: INTEGER);
VAR
    room: INTEGER;

BEGIN
    room := self.want - self.got;
    IF n > room THEN
        n := room
    END;
    WHILE n > 0 DO
        dst.Append8(dst, v);
        INC(self.got);
        DEC(n)
    END
END PutRun;


(* The bytes of one dictionary entry, and then the space that bit 2 of the
   referring symbol asks for - after the entry and not before it. *)
PROCEDURE PutDict (self: Decompressor; dst: ByteArray; idx: INTEGER);
VAR
    i, n, adr, room: INTEGER;

BEGIN
    IF (idx >= 0) & (idx < self.ndict) THEN
        adr := self.dictAdr[idx];
        n := self.dictLen[idx];
        room := self.want - self.got;
        IF n > room THEN
            n := room
        END;
        i := 0;
        WHILE i < n DO
            dst.Append8(dst, self.dict.Get8(self.dict, adr + i));
            INC(self.got);
            INC(i)
        END
    END
END PutDict;


(* One instruction of the third pass, its bytes appended to dst: the byte
   itself, or an escape, a dictionary entry, a count of spaces or a repeated
   byte.  A symbol that is none of the control bytes stands for itself.

   The answer is FALSE when the instruction is not there in full - either the
   bytes fed ran out inside it, which puts the bits it had used back and is no
   fault at all, or the stream is damaged, which is remembered.  Nothing is
   appended until the whole instruction has been read, so a caller that feeds
   a stream in pieces never sees half of one. *)
PROCEDURE Step (self: Decompressor; dst: ByteArray): BOOLEAN;
VAR
    m: Mark;
    c, k, n, idx: INTEGER;
    ok: BOOLEAN;

BEGIN
    Save(self, m);
    c := Symbol(self);
    ok := ~self.starved;
    IF ok THEN
        IF c < 0 THEN
            self.bad := TRUE; ok := FALSE
        ELSIF (c < DICT_LOW) OR (c > ESCAPE_BYTE) THEN
            PutRun(self, dst, c, 1)
        ELSIF c = ESCAPE_BYTE THEN
            k := Symbol(self);
            IF self.starved THEN
                ok := FALSE
            ELSIF k < 0 THEN
                self.bad := TRUE; ok := FALSE
            ELSE
                PutRun(self, dst, k, 1)
            END
        ELSIF c = SPACE_CNT THEN
            n := Symbol(self);
            IF self.starved THEN
                ok := FALSE
            ELSIF n < 0 THEN
                self.bad := TRUE; ok := FALSE
            ELSE
                PutRun(self, dst, SPACE_BYTE, n)
            END
        ELSIF c = REPEAT_BYTE THEN
            k := Symbol(self);
            n := Symbol(self);
            IF self.starved THEN
                ok := FALSE
            ELSIF (k < 0) OR (n < 0) THEN
                self.bad := TRUE; ok := FALSE
            ELSE
                PutRun(self, dst, k, n)
            END
        ELSE                            (* 10H..17H: a dictionary entry *)
            k := Symbol(self);
            IF self.starved THEN
                ok := FALSE
            ELSIF k < 0 THEN
                self.bad := TRUE; ok := FALSE
            ELSE
                idx := ((c MOD 4) * 100H) + k;
                PutDict(self, dst, idx);
                IF c MOD 8 >= 4 THEN
                    PutRun(self, dst, SPACE_BYTE, 1)
                END
            END
        END
    END;
    IF ~ok & ~self.bad THEN
        Restore(self, m)                (* the input is early, not the stream bad *)
    END;

    RETURN ok
END Step;


(* Decode as much as the bytes fed so far can produce, appending it to dst, and
   answer how many bytes that was.  It stops at the declared length, at a
   damaged stream, and at an instruction whose bytes have not arrived, so a
   caller may Take after every Feed or only once at the end.

   An instruction may produce no byte at all - a dictionary entry of length
   zero, a run of none - and the walk then continues on the bits alone until
   the declared length is reached or the bytes run out, which is what the
   decoder of a `.hlp` topic does with the same stream. *)
PROCEDURE Take* (self: Decompressor; dst: ByteArray): INTEGER;
VAR
    before, moved: INTEGER;
    done: BOOLEAN;

BEGIN
    before := dst.Length(dst);
    done := FALSE;
    WHILE ~done & ~self.bad & (self.got < self.want) DO
        IF ~Step(self, dst) THEN
            done := TRUE
        END
    END;
    moved := dst.Length(dst) - before;

    RETURN moved
END Take;


(* No more bytes will be fed.  A stream that has not produced everything it
   declared is damaged after all - which is the one thing that cannot be told
   from a caller that is merely early until the caller says it is done. *)
PROCEDURE Finish* (self: Decompressor);
BEGIN
    IF self.starved OR (self.got < self.want) THEN
        self.bad := TRUE
    END
END Finish;


(* How much of the blob the bits came from, in bytes: the bits handed out
   rounded up, since the last byte of a stream may carry unused low bits.  It
   is what says whether a topic consumed exactly its own blob. *)
PROCEDURE Used* (self: Decompressor): INTEGER;
BEGIN
    RETURN (self.bits + 7) DIV 8
END Used;


PROCEDURE Got* (self: Decompressor): INTEGER;
BEGIN
    RETURN self.got
END Got;


PROCEDURE Want* (self: Decompressor): INTEGER;
BEGIN
    RETURN self.want
END Want;


PROCEDURE Nodes* (self: Decompressor): INTEGER;
BEGIN
    RETURN self.nnodes
END Nodes;


PROCEDURE Entries* (self: Decompressor): INTEGER;
BEGIN
    RETURN self.ndict
END Entries;


(* One entry of the dictionary, appended to dst.  The answer is how many bytes
   it was, or -1 when the database has no such entry.

   An entry is a length and that many bytes with no terminator of any kind, so
   this hands back a count rather than a string: the entry may hold a NUL, and
   the only thing that ends it is the length the section gave it. *)
PROCEDURE Word* (self: Decompressor; i: INTEGER; dst: ByteArray): INTEGER;
VAR
    adr, n, k: INTEGER;

BEGIN
    n := -1;
    IF (i >= 0) & (i < self.ndict) & (self.dict # NIL) THEN
        adr := self.dictAdr[i];
        n := self.dictLen[i];
        k := 0;
        WHILE k < n DO
            dst.Append8(dst, self.dict.Get8(self.dict, adr + k));
            INC(k)
        END
    END;

    RETURN n
END Word;


(* Whether the stream is sound: everything it declared has been produced and
   nothing was read that was not there.  It is read after Finish, since before
   it a short answer only means the bytes are still coming. *)
PROCEDURE Ok* (self: Decompressor): BOOLEAN;
BEGIN
    RETURN ~self.bad & (self.got = self.want)
END Ok;


(* Give the two working arrays and the record back to the allocator.  The
   caller's variable is dangling afterwards and the methods must not be called
   again. *)
PROCEDURE Done* (self: Decompressor);
BEGIN
    self.src.Done(self.src);
    self.dict.Done(self.dict);
    DISPOSE(self)
END Done;


(* A decompressor with no tree, no dictionary and no stream.  This is where the
   methods are bound to the record: after it returns, d.Load is Load and so on,
   and the caller needs nothing but the value it was handed. *)
PROCEDURE Create* (): Decompressor;
VAR
    self: Decompressor;

BEGIN
    NEW(self);
    self.src := ByteArr.Create(0);
    self.dict := ByteArr.Create(0);
    self.pos := 0;
    self.cur := 0;
    self.left := 0;
    self.bits := 0;
    self.starved := FALSE;
    self.nnodes := 0;
    self.ndict := 0;
    self.want := 0;
    self.got := 0;
    self.bad := FALSE;
    self.Load := Load;
    self.Dict := Dict;
    self.Start := Start;
    self.Feed := Feed;
    self.Take := Take;
    self.Finish := Finish;
    self.Used := Used;
    self.Got := Got;
    self.Want := Want;
    self.Nodes := Nodes;
    self.Entries := Entries;
    self.Word := Word;
    self.Ok := Ok;
    self.Done := Done;

    RETURN self
END Create;


END HuffDec.
