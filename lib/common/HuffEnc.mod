(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The Huffman compressor of the QuickHelp `.hlp` format, in object-oriented
   style and shared by every target.  It is the inverse of HuffDec and writes
   the same three passes backwards: the tree of the file's own frequencies, the
   bits of a symbol, and the third pass that reads what those symbols mean - a
   dictionary entry, a run of spaces, a run of one byte, or a byte the escape
   keeps from being read as any of those.

   The style is ByteArr's: the record carries a pointer to every method beside
   the data, Create binds them, and a caller writes

       c := HuffEnc.Create();
       c.Count(c, text);            (* pass one: the frequencies *)
       built := c.Huffman(c);       (* or c.Flat(c) for the tree that compresses nothing *)
       size := c.TreeSize(c);
       c.Tree(c, treeBytes);
       c.Encode(c, text, blob);
       c.Finish(c, blob);
       c.Done(c)

   and never names the module again.  The receiver is handed over by hand,
   because this dialect has no implicit self, so a call is c.Encode(c, text,
   blob) and c.Encode(text, blob) is a parameter error.

   The tree is a run of WORDs in the file and a node is one of them.  A node
   with its high bit set is a leaf and its symbol is the low byte; otherwise
   bit 0 of a code goes to the node whose index is that value DIV 2 and bit 1
   to the node after this one.  Node numbers therefore run node, right subtree,
   left subtree - a left child's number is only known once the whole right
   subtree has been numbered - and Number below writes them in that order.

   Two trees can be built.  Flat is a perfect tree of depth 8 over the 256
   bytes, in which every symbol costs eight bits: the shape a decoder cannot
   get wrong, and so the one that tests the rest of the writer.  Huffman is the
   tree of the counted frequencies, and the one to use unless the caller asks
   for the flat one - or unless there is nothing to build with, fewer than two
   symbols having occurred, in which case Huffman refuses.

   The tree is written before the text and covers the whole of it, so it is
   built from the frequencies of the whole input and the caller must therefore
   count before it can encode anything: Count is the first pass, and the two
   entry points that follow it - Bits, which answers what a run of bytes will
   cost, and Encode, which spends it - are the second.  That is what lets a
   writer know the size of every part before it writes the index that holds the
   sizes.  Count may be called any number of times and accumulates, so a file
   that does not fit in memory is counted a chunk at a time; the bytes are
   handed to the two passes twice, which is the price of a tree that precedes
   its data.

   Both ends of the stream are ByteArray and nothing here opens a file: what
   Encode produces is appended to the array the caller passes, whole bytes
   only, with the half-written byte kept here until Finish pads it out.  A
   caller may therefore hand over the input a chunk at a time as well, and the
   output is the same whatever the chunks were.
*)
MODULE HuffEnc;

IMPORT ByteArr;


CONST
    NSYM*     = 256;                    (* the alphabet: one symbol per byte *)
    MAXNODES* = 512;                    (* a full tree over 256 leaves *)

    (* What the third pass reads as an instruction rather than as a byte.
       10H..17H name a dictionary entry, 18H and 19H are the two run-length
       forms, and 1AH escapes the byte after it.  The last of them is the only
       way to write any of the eleven, so it is the escape as well. *)
    ESC_LOW  = 10H;
    ESC_HIGH = 1AH;
    ESCAPE   = 1AH;

    (* The two run-length forms: 18H is a count of spaces and 19H a byte and a
       count of it, so the first costs two symbols and the second three, and a
       run is worth writing that way only when it covers more bytes than the
       instruction costs to spell - three spaces, four of any other byte.
       Measured on the four databases in samples/QHelp/samples: their 1355
       topics hold 4539 space runs and 411 repeated-byte runs (qbasic.hlp's own
       share, and the other three are the same shape), and the shortest run of
       either form that occurs is exactly the threshold below and not one byte
       longer.  So this is the rule the original encoder worked to, and writing
       it down here is copying it rather than approximating it.

       The count is a symbol like any other, so it is one byte wide: a longer
       run is cut at MAX_RUN here and continued by the instruction after it. *)
    SPACE_CNT  = 18H;
    REPEAT_CNT = 19H;
    MIN_SPACES = 3;
    MIN_REPEAT = 4;
    MAX_RUN    = 255;

    (* The dictionary: a ten-bit index, so at most 1024 entries, and a
       reference is two symbols - `10H` to `17H`, whose low two bits are the
       top of the index and whose bit 2 asks for a space to follow, and then
       the low eight bits of it.  Two symbols against the bytes they stand
       for, so an entry is worth referring to when it replaces three of them:
       MIN_MATCH is that length, and one shorter than it loses. *)
    MAXDICT   = 1024;
    MIN_MATCH = 3;
    DICT_LOW  = 10H;
    SPACE     = 20H;

    LEAF     = 8000H;                   (* the bit that says a node is one *)
    NFREE    = 2 * NSYM;                (* the tree under construction *)
    MAXDEPTH = 24;                      (* past this a code word would not fit *)


TYPE
    ByteArray* = ByteArr.ByteArray;

    Compressor* = POINTER TO CompressorDesc;
    CompressorDesc* = RECORD
        (* The first pass. *)
        freq:    ARRAY NSYM OF INTEGER; (* how often each byte occurs, escape included *)

        (* The dictionary, as the entries of the file section it came from:
           the blob itself is the caller's and is only read, `doff`/`dlen` are
           where each entry lies in it, and `order` is the entries sorted by
           their first byte so that a match at a position has only the entries
           that can begin there to try.  `start[b]` is where bucket b begins in
           `order` and `start[256]` is the end of the last one. *)
        dict:    ByteArray;
        doff:    ARRAY MAXDICT OF INTEGER;
        dlen:    ARRAY MAXDICT OF INTEGER;
        order:   ARRAY MAXDICT OF INTEGER;
        start:   ARRAY NSYM + 1 OF INTEGER;
        cursor:  ARRAY NSYM + 1 OF INTEGER;
        ndict:   INTEGER;

        (* The tree, as the file writes it, and one code per symbol: the bits
           in the low end of `cword` and how many of them there are. *)
        nodes:   ARRAY MAXNODES OF INTEGER;
        nnodes:  INTEGER;
        cword:   ARRAY NSYM OF INTEGER;
        cbits:   ARRAY NSYM OF INTEGER;
        built:   BOOLEAN;

        (* The tree under construction, before it is numbered into `nodes`. *)
        nf:      ARRAY NFREE OF INTEGER;
        nleft:   ARRAY NFREE OF INTEGER;
        nright:  ARRAY NFREE OF INTEGER;
        nsym:    ARRAY NFREE OF INTEGER;
        alive:   ARRAY NFREE OF BOOLEAN;
        root:    INTEGER;
        deep:    BOOLEAN;

        (* The bit stream's state: the bits of a byte not yet written. *)
        pending: INTEGER;
        npend:   INTEGER;

        (* One pointer per method, bound by Create. *)
        Reset*:    PROCEDURE (self: Compressor);
        SetDictionary*: PROCEDURE (self: Compressor; blob: ByteArray);
        Count*:    PROCEDURE (self: Compressor; src: ByteArray);
        Huffman*:  PROCEDURE (self: Compressor): BOOLEAN;
        Flat*:     PROCEDURE (self: Compressor);
        Ready*:    PROCEDURE (self: Compressor): BOOLEAN;
        TreeSize*: PROCEDURE (self: Compressor): INTEGER;
        Tree*:     PROCEDURE (self: Compressor; dst: ByteArray);
        Bits*:     PROCEDURE (self: Compressor; src: ByteArray): INTEGER;
        Encode*:   PROCEDURE (self: Compressor; src, dst: ByteArray);
        Finish*:   PROCEDURE (self: Compressor; dst: ByteArray);
        Done*:     PROCEDURE (self: Compressor)
    END;


PROCEDURE Pow2 (h: INTEGER): INTEGER;
VAR
    v, i: INTEGER;

BEGIN
    v := 1;
    FOR i := 1 TO h DO
        v := v * 2
    END;

    RETURN v
END Pow2;


(* Begin a database: every frequency back to zero and no tree built.  The
   counts of one database are not the counts of the next, and the arrays the
   tree is built in are left as they are, because nothing reads them until
   Huffman or Flat has filled them. *)
PROCEDURE Reset* (self: Compressor);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE i < NSYM DO
        self.freq[i] := 0;
        INC(i)
    END;
    self.built := FALSE;
    self.pending := 0;
    self.npend := 0
END Reset;


(* The dictionary of the database about to be compressed, in the form the file
   holds it: a run of entries, each a BYTE length and that many bytes.  The
   blob stays the caller's and is not copied - only the two tables that say
   where each entry is, which is all the matching needs.

   The entries are then sorted by their first byte, because that is what makes
   matching affordable: a position in the input can only begin one of the
   entries that starts with the byte standing there, and in a dictionary of a
   thousand words that is a handful.  The sort is a counting sort and it is not
   stable, which does not matter - two entries of the same length that both
   match are the same bytes. *)
PROCEDURE SetDictionary* (self: Compressor; blob: ByteArray);
VAR
    p, n, len, b, i: INTEGER;

BEGIN
    self.dict := blob;
    self.ndict := 0;
    n := blob.Length(blob);
    p := 0;
    WHILE (p < n) & (self.ndict < MAXDICT) DO
        len := blob.Get8(blob, p);
        IF p + 1 + len > n THEN
            p := n                          (* a truncated entry ends it *)
        ELSE
            self.doff[self.ndict] := p + 1;
            self.dlen[self.ndict] := len;
            INC(self.ndict);
            INC(p, 1 + len)
        END
    END;

    b := 0;
    WHILE b <= NSYM DO
        self.start[b] := 0;
        INC(b)
    END;
    i := 0;
    WHILE i < self.ndict DO
        IF self.dlen[i] > 0 THEN
            INC(self.start[blob.Get8(blob, self.doff[i]) + 1])
        END;
        INC(i)
    END;
    b := 0;
    WHILE b < NSYM DO
        INC(self.start[b + 1], self.start[b]);
        INC(b)
    END;
    b := 0;
    WHILE b <= NSYM DO
        self.cursor[b] := self.start[b];
        INC(b)
    END;
    i := 0;
    WHILE i < self.ndict DO
        IF self.dlen[i] > 0 THEN
            b := blob.Get8(blob, self.doff[i]);
            self.order[self.cursor[b]] := i;
            INC(self.cursor[b])
        END;
        INC(i)
    END
END SetDictionary;


(* The longest dictionary entry that stands at src[i], and how far past it the
   match reaches.  `adv` is the entry's length, or one more when a space
   follows it and the reference can absorb that too - which is what bit 2 of
   the first symbol is for, and it is why the answer is not simply the length.
   `idx` is -1 when no entry reaches MIN_MATCH.

   The scan takes the longest match and not the best one: an entry that is
   shorter than the longest that fits is never worth taking, because both cost
   the same two symbols and the longer one covers more. *)
PROCEDURE Match (self: Compressor; src: ByteArray; i, n: INTEGER;
                 VAR idx, adv: INTEGER);
VAR
    b, k, e, lim, q, p, best, bestIdx: INTEGER;
    space, ok: BOOLEAN;

BEGIN
    idx := -1;
    adv := 0;
    best := 0;
    bestIdx := -1;
    space := FALSE;
    b := src.Get8(src, i);
    k := self.start[b];
    WHILE k < self.start[b + 1] DO
        e := self.order[k];
        lim := self.dlen[e];
        IF (lim > best) & (i + lim <= n) THEN
            q := self.doff[e];
            p := 0;
            ok := TRUE;
            WHILE ok & (p < lim) DO
                IF src.Get8(src, i + p) # self.dict.Get8(self.dict, q + p) THEN
                    ok := FALSE
                END;
                INC(p)
            END;
            IF ok THEN
                best := lim;
                bestIdx := e;
                space := (i + lim < n) & (src.Get8(src, i + lim) = SPACE)
            END
        END;
        INC(k)
    END;
    IF bestIdx >= 0 THEN
        adv := best;
        IF space THEN
            INC(adv)
        END;
        IF adv >= MIN_MATCH THEN
            idx := bestIdx
        ELSE
            adv := 0
        END
    END
END Match;


(* The run of one byte standing at src[i], when it is long enough to be worth
   an instruction of its own: `adv` is how far it reaches, or zero when the
   bytes have to be written one symbol each, and `sym`, `cnt` and `k` are the
   instruction's symbols - the form, the count, and the byte a repeat repeats.
   `k` is not used by the space form, which is why it is set to zero there.

   A run of spaces is the commonest run there is and the cheapest to spell, so
   it has a form to itself; every other byte needs three symbols and so needs a
   longer run to pay for itself.  The count is cut at MAX_RUN.

   RunAt is asked BEFORE Match, and that order is the original encoder's and
   not a preference.  A dictionary entry that is itself a short run - the
   databases in samples/QHelp/samples hold `C4 C4 C4` and `B1 B1 B1` - covers
   three of the run's bytes for two symbols and leaves the rest of the run to
   be written after it, which for a run of forty is five symbols where the one
   instruction is three; measured on QB45ENER.HLP, taking the entry first finds
   3 repeated-byte runs where the file it came from holds 218, and costs 1647
   bytes.  A run that Match would have covered is a run all the same, and the
   longer it is the more the entry loses by.

   The byte a repeat repeats is written as a symbol and is not escaped, even
   when it is one of the eleven the third pass reads as an instruction: the
   decoder takes it as a value and never walks it, so inside `19H` a control
   byte costs the one symbol every other byte costs.  That is the only place in
   the stream where that is true, and it is why the count is not escaped
   either. *)
PROCEDURE RunAt (src: ByteArray; i, n: INTEGER; VAR sym, cnt, k, adv: INTEGER);
VAR
    b, j, r: INTEGER;

BEGIN
    sym := 0;
    cnt := 0;
    k := 0;
    adv := 0;
    b := src.Get8(src, i);
    j := i;
    WHILE (j < n) & (src.Get8(src, j) = b) DO
        INC(j)
    END;
    r := j - i;
    IF r > MAX_RUN THEN
        r := MAX_RUN
    END;
    IF b = SPACE THEN
        IF r >= MIN_SPACES THEN
            sym := SPACE_CNT;
            cnt := r;
            adv := r
        END
    ELSIF r >= MIN_REPEAT THEN
        sym := REPEAT_CNT;
        k := b;
        cnt := r;
        adv := r
    END
END RunAt;


(* The first pass: one run of the input counted.  The escape is counted as well
   as the byte it escapes, because both are written - a control byte costs the
   bits of two symbols and the tree has to know it.

   A run an entry of the dictionary covers is not counted byte by byte: it is
   written as a reference, so the two symbols of the reference are what the
   tree has to know about, and the bytes underneath it are not symbols of the
   stream at all.  Which run that is has to be decided here exactly as the
   writing pass will decide it, or the tree would be built for a stream that is
   not the one the file holds - both passes ask Match, and it answers from
   nothing but the input and the dictionary.  A run no entry covers is asked of
   RunAt in the same way, and for the same reason.

   A symbol written inside an instruction is counted as itself and not as an
   escaped byte, which is what the two run-length forms need: the count and the
   repeated byte are values the decoder reads, not instructions it walks. *)
PROCEDURE Count* (self: Compressor; src: ByteArray);
VAR
    i, n, b, idx, adv, s, sym, cnt, k: INTEGER;

BEGIN
    n := src.Length(src);
    i := 0;
    WHILE i < n DO
        adv := 0;
        RunAt(src, i, n, sym, cnt, k, adv);
        IF adv > 0 THEN
            INC(self.freq[sym]);
            IF sym = REPEAT_CNT THEN
                INC(self.freq[k])
            END;
            INC(self.freq[cnt]);
            INC(i, adv)
        ELSE
            idx := -1;
            IF self.ndict > 0 THEN
                Match(self, src, i, n, idx, adv)
            END;
            IF idx >= 0 THEN
                s := DICT_LOW + (idx DIV NSYM);
                IF adv > self.dlen[idx] THEN
                    INC(s, 4)               (* the space the reference appends *)
                END;
                INC(self.freq[s]);
                INC(self.freq[idx MOD NSYM]);
                INC(i, adv)
            ELSE
                b := src.Get8(src, i);
                IF (b >= ESC_LOW) & (b <= ESC_HIGH) THEN
                    INC(self.freq[ESCAPE])
                END;
                INC(self.freq[b]);
                INC(i)
            END
        END
    END
END Count;


(* The flat tree, written in the file's own order: a node is placed, then its
   right subtree, then its left one.  `path` is the code that reaches the node
   - a right step appends a 1 - and at a leaf it is the byte the leaf stands
   for, so a perfect tree of depth 8 over 256 bytes numbers every leaf by the
   code that reaches it. *)
PROCEDURE Place (self: Compressor; base, h, path: INTEGER);
VAR
    left: INTEGER;

BEGIN
    IF h = 0 THEN
        self.nodes[base] := LEAF + path
    ELSE
        (* The right subtree is itself perfect and has 2^h - 1 nodes, so the
           left child stands just past it. *)
        left := base + Pow2(h);
        self.nodes[base] := left * 2;
        Place(self, base + 1, h - 1, path * 2 + 1);
        Place(self, left, h - 1, path * 2)
    END
END Place;


(* The tree that compresses nothing: eight bits for every byte, and the code of
   a byte is the byte.  It is always valid, which is what makes it the shape to
   fall back on - a decoder cannot misread it, so it separates a fault in the
   tree from a fault in the rest of the writer. *)
PROCEDURE Flat* (self: Compressor);
VAR
    i: INTEGER;

BEGIN
    self.nnodes := Pow2(9) - 1;
    Place(self, 0, 8, 0);
    i := 0;
    WHILE i < NSYM DO
        self.cbits[i] := 8;
        self.cword[i] := i;
        INC(i)
    END;
    self.built := TRUE
END Flat;


(* How many nodes a subtree holds.  The numbering needs it: a node's left child
   stands past the whole of its right subtree. *)
PROCEDURE Subtree (self: Compressor; n: INTEGER): INTEGER;
VAR
    r: INTEGER;

BEGIN
    IF self.nleft[n] < 0 THEN
        r := 1
    ELSE
        r := 1 + Subtree(self, self.nleft[n]) + Subtree(self, self.nright[n])
    END;

    RETURN r
END Subtree;


(* Number a subtree into `nodes`, placing its root at k.  `acc` is the code that
   reaches the root: a right step appends a 1 to it, a left step a 0. *)
PROCEDURE Number (self: Compressor; n, k, acc, depth: INTEGER);
VAR
    rsz: INTEGER;

BEGIN
    IF depth > MAXDEPTH THEN
        self.deep := TRUE
    END;
    IF self.nleft[n] < 0 THEN
        self.cword[self.nsym[n]] := acc;
        self.cbits[self.nsym[n]] := depth;
        self.nodes[k] := LEAF + self.nsym[n]
    ELSE
        rsz := Subtree(self, self.nright[n]);
        self.nodes[k] := (k + 1 + rsz) * 2;
        Number(self, self.nright[n], k + 1, acc * 2 + 1, depth + 1);
        Number(self, self.nleft[n], k + 1 + rsz, acc * 2, depth + 1)
    END
END Number;


(* The tree of the counted frequencies.  The answer is FALSE when there is
   nothing to build - fewer than two symbols occur, so there is no tree at all
   - or when the tree that came out is one the file cannot hold: the caller
   then asks for the flat one, which is always valid. *)
PROCEDURE Huffman* (self: Compressor): BOOLEAN;
VAR
    i, n, live, a, b: INTEGER;
    ok: BOOLEAN;

BEGIN
    n := 0;
    i := 0;
    WHILE i < NSYM DO
        IF self.freq[i] > 0 THEN
            self.nf[n] := self.freq[i];
            self.nleft[n] := -1;
            self.nright[n] := -1;
            self.nsym[n] := i;
            self.alive[n] := TRUE;
            INC(n)
        END;
        INC(i)
    END;

    (* Every merge takes two roots and leaves one, so the number of roots is
       what says whether the tree is finished - not the number of nodes, which
       only grows. *)
    live := n;
    ok := n >= 2;
    WHILE ok & (live > 1) DO
        (* The two lightest roots: the whole of the tree building is this scan,
           repeated once per merge. *)
        a := -1;
        b := -1;
        i := 0;
        WHILE i < n DO
            IF self.alive[i] THEN
                IF (a < 0) OR (self.nf[i] < self.nf[a]) THEN
                    b := a;
                    a := i
                ELSIF (b < 0) OR (self.nf[i] < self.nf[b]) THEN
                    b := i
                END
            END;
            INC(i)
        END;
        IF (a < 0) OR (b < 0) THEN
            ok := FALSE                  (* two roots were not there to take *)
        ELSE
            self.nf[n] := self.nf[a] + self.nf[b];
            self.nleft[n] := a;
            self.nright[n] := b;
            self.nsym[n] := -1;
            self.alive[n] := TRUE;
            self.alive[a] := FALSE;
            self.alive[b] := FALSE;
            INC(n);
            DEC(live)
        END
    END;

    IF ok THEN
        self.root := n - 1;
        self.nnodes := Subtree(self, self.root);
        ok := self.nnodes <= MAXNODES;
        IF ok THEN
            self.deep := FALSE;
            Number(self, self.root, 0, 0, 0);
            ok := ~self.deep
        END
    END;
    self.built := ok;

    RETURN ok
END Huffman;


PROCEDURE Ready* (self: Compressor): BOOLEAN;
BEGIN
    RETURN self.built
END Ready;


(* How many bytes the tree section takes: one WORD per node and the zero WORD
   that ends it. *)
PROCEDURE TreeSize* (self: Compressor): INTEGER;
BEGIN
    RETURN 2 * (self.nnodes + 1)
END TreeSize;


(* The tree section, appended to dst.  The terminator is a whole zero WORD and
   not a zero low byte, which is why a node value may not be zero by accident:
   a value of 0XX00H would end the section early. *)
PROCEDURE Tree* (self: Compressor; dst: ByteArray);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE i < self.nnodes DO
        dst.Append16(dst, self.nodes[i]);
        INC(i)
    END;
    dst.Append16(dst, 0)
END Tree;


(* One bit, most significant first, which is the order the decoder reads and
   the order a code is written in.  A byte leaves only when eight bits have
   arrived, so nothing here can end in a half-written byte unless Finish pads
   it out. *)
PROCEDURE PutBit (self: Compressor; dst: ByteArray; b: INTEGER);
BEGIN
    self.pending := self.pending * 2 + b;
    INC(self.npend);
    IF self.npend = 8 THEN
        dst.Append8(dst, self.pending);
        self.pending := 0;
        self.npend := 0
    END
END PutBit;


(* One symbol.  Its code is held in the low end of a word, so the first bit out
   is the one under the highest set mask. *)
PROCEDURE PutSym (self: Compressor; dst: ByteArray; b: INTEGER);
VAR
    mask: INTEGER;

BEGIN
    mask := Pow2(self.cbits[b] - 1);
    WHILE mask > 0 DO
        PutBit(self, dst, (self.cword[b] DIV mask) MOD 2);
        mask := mask DIV 2
    END
END PutSym;


(* The second pass, measured: the bits a run of the input costs, escapes
   included.  The caller asks this before it writes anything, because the topic
   index holds the sizes and comes first in the file.

   The dictionary is asked in the same order and with the same answer as the
   counting pass and the writing one, so the three agree about which bytes of
   the input are symbols at all - and so is RunAt, whose answer is the same
   three symbols this pass has to add up and the writing pass will write.
   Nothing here passes its own tree back to RunAt: the rule is a threshold on
   the length of a run and does not look at a code word, so the tree the
   counting pass built and the tree this one measures with cannot make the two
   disagree about where a run begins. *)
PROCEDURE Bits* (self: Compressor; src: ByteArray): INTEGER;
VAR
    i, n, b, total, idx, adv, s, sym, cnt, k: INTEGER;

BEGIN
    total := 0;
    n := src.Length(src);
    i := 0;
    WHILE i < n DO
        adv := 0;
        RunAt(src, i, n, sym, cnt, k, adv);
        IF adv > 0 THEN
            INC(total, self.cbits[sym]);
            IF sym = REPEAT_CNT THEN
                INC(total, self.cbits[k])
            END;
            INC(total, self.cbits[cnt]);
            INC(i, adv)
        ELSE
            idx := -1;
            IF self.ndict > 0 THEN
                Match(self, src, i, n, idx, adv)
            END;
            IF idx >= 0 THEN
                s := DICT_LOW + (idx DIV NSYM);
                IF adv > self.dlen[idx] THEN
                    INC(s, 4)
                END;
                INC(total, self.cbits[s]);
                INC(total, self.cbits[idx MOD NSYM]);
                INC(i, adv)
            ELSE
                b := src.Get8(src, i);
                IF (b >= ESC_LOW) & (b <= ESC_HIGH) THEN
                    INC(total, self.cbits[ESCAPE])
                END;
                INC(total, self.cbits[b]);
                INC(i)
            END
        END
    END;

    RETURN total
END Bits;


(* The second pass, spent: one run of the input as symbols, its code bits
   appended to dst.  Every byte goes through the same stream - the text, the
   length prefixes and the attribute block of a topic alike - and a byte that
   the third pass would read as an instruction is escaped, which puts 1AH and
   the byte itself into the stream.  A chunk boundary is of no significance:
   the bits of a code may straddle the two calls and the byte they complete is
   appended by whichever call holds the last of them.

   A run is written the way Count counted it and Bits measured it, and neither
   of those two looks at a code word to decide, so the three are one decision
   written three times and not three decisions that have to be kept in step. *)
PROCEDURE Encode* (self: Compressor; src, dst: ByteArray);
VAR
    i, n, b, idx, adv, s, sym, cnt, k: INTEGER;

BEGIN
    n := src.Length(src);
    i := 0;
    WHILE i < n DO
        adv := 0;
        RunAt(src, i, n, sym, cnt, k, adv);
        IF adv > 0 THEN
            PutSym(self, dst, sym);
            IF sym = REPEAT_CNT THEN
                PutSym(self, dst, k)
            END;
            PutSym(self, dst, cnt);
            INC(i, adv)
        ELSE
            idx := -1;
            IF self.ndict > 0 THEN
                Match(self, src, i, n, idx, adv)
            END;
            IF idx >= 0 THEN
                (* Two symbols and no more: the ten-bit index is split across
                   them, and the space the entry is followed by travels in bit 2
                   of the first rather than as a symbol of its own. *)
                s := DICT_LOW + (idx DIV NSYM);
                IF adv > self.dlen[idx] THEN
                    INC(s, 4)
                END;
                PutSym(self, dst, s);
                PutSym(self, dst, idx MOD NSYM);
                INC(i, adv)
            ELSE
                b := src.Get8(src, i);
                IF (b >= ESC_LOW) & (b <= ESC_HIGH) THEN
                    PutSym(self, dst, ESCAPE)
                END;
                PutSym(self, dst, b);
                INC(i)
            END
        END
    END
END Encode;


(* The end of a stream: the bits that have not become a byte yet are padded out
   - with zeros, the low end of the byte - and appended.  The last byte of a
   stream may therefore carry bits no symbol asked for, which the decoder stops
   before reading because the length it was given ends first. *)
PROCEDURE Finish* (self: Compressor; dst: ByteArray);
BEGIN
    IF self.npend > 0 THEN
        WHILE self.npend < 8 DO
            self.pending := self.pending * 2;
            INC(self.npend)
        END;
        dst.Append8(dst, self.pending);
        self.pending := 0;
        self.npend := 0
    END
END Finish;


PROCEDURE Done* (self: Compressor);
BEGIN
    DISPOSE(self)
END Done;


(* A compressor with no counts and no tree.  This is where the methods are
   bound to the record: after it returns, c.Count is Count and so on, and the
   caller needs nothing but the value it was handed. *)
PROCEDURE Create* (): Compressor;
VAR
    self: Compressor;

BEGIN
    NEW(self);
    self.nnodes := 0;
    self.root := 0;
    self.deep := FALSE;
    self.ndict := 0;
    self.Reset := Reset;
    self.SetDictionary := SetDictionary;
    self.Count := Count;
    self.Huffman := Huffman;
    self.Flat := Flat;
    self.Ready := Ready;
    self.TreeSize := TreeSize;
    self.Tree := Tree;
    self.Bits := Bits;
    self.Encode := Encode;
    self.Finish := Finish;
    self.Done := Done;
    Reset(self);

    RETURN self
END Create;


END HuffEnc.
