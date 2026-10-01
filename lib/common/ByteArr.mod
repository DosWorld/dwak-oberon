(* Public domain. Copyright (c) 2026, DosWorld.

   A byte array of variable length, in object-oriented style, shared by every
   target.

   The style is the one lib/common/TuiCanv.mod uses: the record carries a
   pointer to every method beside the data, and Create binds them into the
   record it answers with.  A caller therefore writes

       b := ByteArr.Create(1000);
       b.Put8(b, 7, 65);
       b.Append8(b, 10);
       ok := b.Save(b, "out.bin");
       b.Done(b)

   and never names the module again - the method is reached through the
   record, one indirect call per operation.  A method is an ordinary
   procedure whose first parameter is the array, named self, and it is the
   record field that gets the * of an export while the procedure itself stays
   private to this module.  The receiver is handed over by hand: this dialect
   has no implicit self, so the call is b.Put8(b, 7, 65) and b.Put8(7, 65) is
   a parameter error.  What the record holds besides the methods is private
   too, so the methods are the only way in and the directory, the length and
   the block count cannot be corrupted from outside.  The price of the style
   is one pointer per method in every array, which is paid per array and not
   per byte.

   Arrays, in this same directory, is built on this module: a list of
   fixed-size elements holds one of these arrays and adds the element geometry
   on top of it - where element i begins, how many fit in a block - so the
   blocks, the directory that finds them and every byte-level move are written
   once, here, and the list never names Heap at all.

   The accessors are sized, and the number is the width in bits: Get8 and
   Put8 move one byte, Get16 and Put16 two, Get32 and Put32 four, and Get64,
   Put64 and their Append counterparts eight - the last of those only where
   INTEGER is 64 bits wide, since a wider value than that has nowhere to go.
   Append8 to Append64 append one value of that width, which is the way a
   single number is added to the array; Append, AppendFull and AppendMem add
   whole runs.  A sized value is written little-endian, the byte at the lower
   index least significant, and read back the same way, so PutN followed by
   GetN at the same index answers what was put.  It is assembled from the
   bytes one at a time and not by SYSTEM.GET16, because a value of two or
   more bytes may straddle two blocks and only its first byte is in the block
   that byte's address belongs to.  The value read is zero-extended, which is
   what SYSTEM.GET16 and SYSTEM.GET32 do on a 64-bit target; on a 32-bit one
   Get32 fills the whole of INTEGER, so a top bit set there reads as a
   negative number, as it does through SYSTEM.GET32.

   Two of the accessors are named for the width of what they fill rather than
   for a value they move: Fill8 sets a whole run of bytes to one byte, Fill16 a
   whole run of words to one word - the fill a screen asks for, since a cell is
   a character and its attribute and the two always move together.  Filling is
   the one operation a canvas performs in bulk, so on an x86 target both end in
   the CPU's own string store, rep stosb and rep stosw, one instruction to a
   block; every other target gets the doubling loop.  Fill is Fill8 under the
   name it had first.

   One operation is a search: FindByte answers the index of the first byte equal
   to b at or after from, or -1, and it is the array's other bulk operation on an
   x86 target, since it ends in repne scasb, one instruction a block.  Nothing is
   lost at a block boundary, because a byte has no tail.  It is what a text
   search is built on - look for the first character of what you are looking for
   and compare the rest yourself - and its companion RunLen answers how many
   bytes from an index lie in that index's own block, which is the stretch an
   address out of Adr is good for.  A reader that walks a run by address asks
   RunLen for the length rather than testing the block; only this module knows
   where the blocks end.

   A string goes in a character at a time through PutStr and AppendStr and
   comes back out through GetStr, one CHAR to one byte, stored asciiz: the
   characters and then the 0X that ends them, so n characters need n + 1 bytes
   and a string that does not fit into the destination is truncated at its
   terminator rather than overflowed.  Nothing is encoded on the way in - a
   source file is UTF-8 here, so the characters of a literal are already its
   UTF-8 bytes and copying them copies the encoding.
*)
MODULE ByteArr;

IMPORT Files, Heap, Oberon, Strings, SYSTEM;

CONST
    ChunkBytes* = Heap.MinPayload;  (* bytes in block zero, and the unit of growth *)
    MaxBlocks   = Heap.Classes;     (* blocks an array may use, and so its capacity *)
    $IF (BITS_16)
        MaxBytes* = 7874;           (* ChunkBytes * (2^MaxBlocks - 1) *)
    $ELSE
        MaxBytes* = ChunkBytes * 8191;  (* ChunkBytes * (2^13 - 1) *)
    $END
    BufSize = Files.BUFSIZE;        (* the buffer the file calls are staged through *)

TYPE
    ByteArray* = POINTER TO ByteArrayDesc;
    (* A ByteArray is an `Oberon.Object`: the record extends ObjectDesc and
       inherits the `Done` field from it rather than declaring one of its own.
       What is supplied here is `Done` below, a procedure taking
       `Oberon.Object`, bound into that inherited field by Create.  See
       Oberon.mod for what the root type is and why the destructor is the
       caller's obligation. *)
    ByteArrayDesc* = RECORD (Oberon.ObjectDesc)
        (* The data, private: only the methods below touch it. *)
        dir:    ARRAY MaxBlocks OF INTEGER;     (* block address; block c at dir[c] *)
        count:  INTEGER;                        (* bytes in use *)
        blocks: INTEGER;                        (* blocks allocated *)

        (* One pointer per method, bound by Create. *)
        Length*:      PROCEDURE (self: ByteArray): INTEGER;
        Capacity*:    PROCEDURE (self: ByteArray): INTEGER;
        Adr*:         PROCEDURE (self: ByteArray; idx: INTEGER): INTEGER;
        RunLen*:      PROCEDURE (self: ByteArray; idx: INTEGER): INTEGER;
        Get8*:        PROCEDURE (self: ByteArray; idx: INTEGER): BYTE;
        Get16*:       PROCEDURE (self: ByteArray; idx: INTEGER): INTEGER;
        GetStr*:      PROCEDURE (self: ByteArray; idx: INTEGER; VAR dst : ARRAY OF CHAR);
        FindByte*:    PROCEDURE (self: ByteArray; from: INTEGER; b: BYTE): INTEGER;
$IF (BITS_32 | BITS_64)
        Get32*:       PROCEDURE (self: ByteArray; idx: INTEGER): INTEGER;
$END
$IF (BITS_64)
        Get64*:       PROCEDURE (self: ByteArray; idx: INTEGER): INTEGER;
$END
        Put8*:        PROCEDURE (self: ByteArray; idx: INTEGER; b: BYTE);
        Put16*:       PROCEDURE (self: ByteArray; idx: INTEGER; v: INTEGER);
        PutStr*:      PROCEDURE (self: ByteArray; idx: INTEGER; dst : ARRAY OF CHAR);
$IF (BITS_32 | BITS_64)
        Put32*:       PROCEDURE (self: ByteArray; idx: INTEGER; v: INTEGER);
$END
$IF (BITS_64)
        Put64*:       PROCEDURE (self: ByteArray; idx: INTEGER; v: INTEGER);
$END
        Append8*:     PROCEDURE (self: ByteArray; b: BYTE);
        Append16*:    PROCEDURE (self: ByteArray; v: INTEGER);
        AppendStr*:   PROCEDURE (self: ByteArray; src: ARRAY OF CHAR);
$IF (BITS_32 | BITS_64)
        Append32*:    PROCEDURE (self: ByteArray; v: INTEGER);
$END
$IF (BITS_64)
        Append64*:    PROCEDURE (self: ByteArray; v: INTEGER);
$END
        Fill*:        PROCEDURE (self: ByteArray; idx, count: INTEGER; b: BYTE);
        Fill8*:       PROCEDURE (self: ByteArray; idx, count: INTEGER; b: BYTE);
        Fill16*:      PROCEDURE (self: ByteArray; idx, count: INTEGER; v: INTEGER);
$IF (BITS_32 | BITS_64)
        Fill32*:      PROCEDURE (self: ByteArray; idx, count: INTEGER; v: INTEGER);
$END
        SetLength*:   PROCEDURE (self: ByteArray; newLen: INTEGER);
        Pack*:        PROCEDURE (self: ByteArray);
        Append*:      PROCEDURE (self: ByteArray; src: ByteArray; idx, count: INTEGER);
        AppendFull*:  PROCEDURE (self: ByteArray; src: ByteArray);
        AppendMem*:   PROCEDURE (self: ByteArray; srcAdr, n: INTEGER);
        Copy*:        PROCEDURE (self: ByteArray; atIdx: INTEGER; src: ByteArray; idx, count: INTEGER);
        CopyMem*:     PROCEDURE (self: ByteArray; atIdx: INTEGER; srcAdr, n: INTEGER);
        CopyTo*:      PROCEDURE (self: ByteArray; srcIdx, count: INTEGER; dstAdr: INTEGER);
        Move*:        PROCEDURE (self: ByteArray; dstIdx, srcIdx, count: INTEGER);
        Remove*:      PROCEDURE (self: ByteArray; idx, count: INTEGER);
        Save*:        PROCEDURE (self: ByteArray; name: ARRAY OF CHAR): BOOLEAN;
        Write*:       PROCEDURE (self: ByteArray; VAR f : Files.File): BOOLEAN
    END;

(* Block c holds ChunkBytes*2^c bytes and begins at byte ChunkBytes*(2^c - 1).
   Both are cheap enough to recompute rather than store. *)
PROCEDURE Full (c: INTEGER): INTEGER;
BEGIN
    RETURN ChunkBytes * LSL(1, c)
END Full;

PROCEDURE Base (c: INTEGER): INTEGER;
BEGIN
    RETURN ChunkBytes * (LSL(1, c) - 1)
END Base;

(* The block holding byte i.  Block c begins at ChunkBytes*(2^c - 1), so
   i DIV ChunkBytes + 1 lies in [2^c, 2^(c+1)), and the largest power of two
   not above it is the block number. *)
PROCEDURE Locate (i: INTEGER): INTEGER;
VAR
    span, c: INTEGER;

BEGIN
    span := 1; c := 0;
    WHILE span * 2 <= i DIV ChunkBytes + 1 DO
        span := span * 2;
        INC(c)
    END

    RETURN c
END Locate;

PROCEDURE ElemAdr (self: ByteArray; i: INTEGER): INTEGER;
VAR
    c: INTEGER;

BEGIN
    c := Locate(i);

    RETURN self.dir[c] + i - Base(c)
END ElemAdr;

(* How many of the n bytes starting at i lie in i's own block: a run never
   crosses a block boundary, because the two blocks are not adjacent. *)
PROCEDURE Piece (i, n: INTEGER): INTEGER;
VAR
    c: INTEGER;

BEGIN
    c := Locate(i);

    RETURN MIN(n, Base(c) + Full(c) - i)
END Piece;

(* The same counted backwards from i inclusive, which is what a run that moves
   towards the higher address needs. *)
PROCEDURE PieceBack (i, n: INTEGER): INTEGER;
VAR
    c: INTEGER;

BEGIN
    c := Locate(i);

    RETURN MIN(n, i - Base(c) + 1)
END PieceBack;

PROCEDURE GetByte (adr: INTEGER): BYTE;
VAR
    v: BYTE;

BEGIN
    SYSTEM.GET(adr, v);

    RETURN v
END GetByte;

(* The value taken as an INTEGER so that a wide one can be handed over whole:
   PUT8 keeps the lowest byte of whatever it is given, which is the byte
   wanted.  It is not a BYTE parameter, because PutValue shifts a value down
   and the intermediate is an INTEGER. *)
PROCEDURE PutByte (adr: INTEGER; v: INTEGER);
BEGIN
    SYSTEM.PUT8(adr, v)
END PutByte;

(* n bytes at adr set to v.  The run is filled by doubling what is already
   there - one byte written, then two, then four - so any length costs
   O(log n) moves and no scratch buffer, and every move is inside one block
   because the caller keeps it there.  A length of zero writes nothing: the
   byte PUT8 would put down would be the first byte past the run. *)
PROCEDURE FillRange (adr, n: INTEGER; v: BYTE);
VAR
    k, m: INTEGER;

BEGIN
    IF n > 0 THEN
        PutByte(adr, v);
        k := 1;
        WHILE k < n DO
            m := MIN(k, n - k);
            SYSTEM.MOVE(adr, adr + k, m);
            INC(k, m)
        END
    END
END FillRange;

(* n bytes at adr set to v through the CPU's own string store: rep stosb on an
   x86 target, and the doubling loop of FillRange on any other.

   This is the one place a canvas fill can be fast rather than merely correct.
   Filling through Put8 costs a call and an address computation a byte, and
   under DOSBox-X twenty fills of an eighty by twenty-five canvas that way took
   5.07 s against a 3.04 s floor - a tenth of a second a screen - where the
   same twenty through this instruction measured 3.04 s, which is the floor
   itself.  A frame that cleared its canvas paid that tenth every time, and in
   a frame that did nothing else it was the largest single part of one.
   Measured again with the CPU pinned (DOSBox-X cycles = 5000, one session a
   run, the 3.0 s start-up subtracted), a clear of that canvas is 0.41 ms where
   presenting a whole frame of it is 5.1 ms: what a frame costs is the
   presenting, and the clearing is no longer visible in it.

   The caller keeps the run inside one block, so one instruction fills all of
   it and the block structure never enters into it.  AL is the byte stored and
   EDI the address, ECX the count.  EDI and the direction flag belong to the
   caller, hence the push and the CLD; the test comes first because a rep with
   ECX = 0 would still read EDI, and a zero-length fill is legal.  The body
   ends on its label and the compiler's own epilogue follows, which is how
   RTL's _move is written. *)
$IF (CPU_I386)

PROCEDURE [stdcall] FillBytes (adr, n, v: INTEGER);
BEGIN
    SYSTEM.CODE(
    08BH, 045H, 010H,    (*  mov eax, dword [ebp + 16]  v        *)
    08BH, 04DH, 00CH,    (*  mov ecx, dword [ebp + 12]  n        *)
    085H, 0C9H,          (*  test ecx, ecx                       *)
    07EH, 008H,          (*  jle L                               *)
    0FCH,                (*  cld                                 *)
    057H,                (*  push edi                            *)
    08BH, 07DH, 008H,    (*  mov edi, dword [ebp + 8]   adr      *)
    0F3H, 0AAH,          (*  rep stosb                           *)
    05FH                 (*  pop edi                             *)
                         (*  L:                                  *)
                )
END FillBytes;

(* n words at adr set to v.  This is the primitive the byte-sized fills are
   built on - a byte fill is a word fill of the same pattern doubled, which is
   what FillBytes above does - and it is stosw rather than stosd because the
   count is in words and any even run is exact.  FillDwords below is the wide
   one, and it is the one a screen asks for. *)
PROCEDURE [stdcall] FillWords (adr, n, v: INTEGER);
BEGIN
    SYSTEM.CODE(
    08BH, 045H, 010H,    (*  mov eax, dword [ebp + 16]  v        *)
    08BH, 04DH, 00CH,    (*  mov ecx, dword [ebp + 12]  n        *)
    085H, 0C9H,          (*  test ecx, ecx                       *)
    07EH, 009H,          (*  jle L                               *)
    0FCH,                (*  cld                                 *)
    057H,                (*  push edi                            *)
    08BH, 07DH, 008H,    (*  mov edi, dword [ebp + 8]   adr      *)
    066H, 0F3H, 0ABH,    (*  rep stosw                           *)
    05FH                 (*  pop edi                             *)
                         (*  L:                                  *)
                )
END FillWords;

(* n dwords at adr set to v, which is what a screen cell is now: a code point
   and its attribute, four bytes that always move together.  The count is in
   dwords, so a run of any whole number of cells is exact - which is what
   TuiCanv.Clear and TuiCanv.Fill hand over, and the reason this exists
   beside FillWords rather than instead of it. *)
PROCEDURE [stdcall] FillDwords (adr, n, v: INTEGER);
BEGIN
    SYSTEM.CODE(
    08BH, 045H, 010H,    (*  mov eax, dword [ebp + 16]  v        *)
    08BH, 04DH, 00CH,    (*  mov ecx, dword [ebp + 12]  n        *)
    085H, 0C9H,          (*  test ecx, ecx                       *)
    07EH, 008H,          (*  jle L                               *)
    0FCH,                (*  cld                                 *)
    057H,                (*  push edi                            *)
    08BH, 07DH, 008H,    (*  mov edi, dword [ebp + 8]   adr      *)
    0F3H, 0ABH,          (*  rep stosd                           *)
    05FH                 (*  pop edi                             *)
                         (*  L:                                  *)
                )
END FillDwords;

$ELSIF (CPU_AMD64)

PROCEDURE [oberon] FillBytes (adr, n, v: INTEGER);
BEGIN
    SYSTEM.CODE(
    048H, 08BH, 045H, 020H,  (*  mov rax, qword [rbp + 32]  v    *)
    048H, 08BH, 04DH, 018H,  (*  mov rcx, qword [rbp + 24]  n    *)
    048H, 085H, 0C9H,        (*  test rcx, rcx                   *)
    07EH, 009H,              (*  jle L                           *)
    0FCH,                    (*  cld                             *)
    057H,                    (*  push rdi                        *)
    048H, 08BH, 07DH, 010H,  (*  mov rdi, qword [rbp + 16]  adr  *)
    0F3H, 0AAH,              (*  rep stosb                       *)
    05FH                     (*  pop rdi                         *)
                             (*  L:                              *)
                )
END FillBytes;

PROCEDURE [oberon] FillWords (adr, n, v: INTEGER);
BEGIN
    SYSTEM.CODE(
    048H, 08BH, 045H, 020H,  (*  mov rax, qword [rbp + 32]  v    *)
    048H, 08BH, 04DH, 018H,  (*  mov rcx, qword [rbp + 24]  n    *)
    048H, 085H, 0C9H,        (*  test rcx, rcx                   *)
    07EH, 00AH,              (*  jle L                           *)
    0FCH,                    (*  cld                             *)
    057H,                    (*  push rdi                        *)
    048H, 08BH, 07DH, 010H,  (*  mov rdi, qword [rbp + 16]  adr  *)
    066H, 0F3H, 0ABH,        (*  rep stosw                       *)
    05FH                     (*  pop rdi                         *)
                             (*  L:                              *)
                )
END FillWords;

PROCEDURE [oberon] FillDwords (adr, n, v: INTEGER);
BEGIN
    SYSTEM.CODE(
    048H, 08BH, 045H, 020H,  (*  mov rax, qword [rbp + 32]  v    *)
    048H, 08BH, 04DH, 018H,  (*  mov rcx, qword [rbp + 24]  n    *)
    048H, 085H, 0C9H,        (*  test rcx, rcx                   *)
    07EH, 009H,              (*  jle L                           *)
    0FCH,                    (*  cld                             *)
    057H,                    (*  push rdi                        *)
    048H, 08BH, 07DH, 010H,  (*  mov rdi, qword [rbp + 16]  adr  *)
    0F3H, 0ABH,              (*  rep stosd                       *)
    05FH                     (*  pop rdi                         *)
                             (*  L:                              *)
                )
END FillDwords;

$ELSE

(* The same two operations with no string store to lean on, written as
   FillRange is: the pattern goes down once and the run doubles.  A 16-bit
   target has no wide loop and no rep, so this is also the branch the small
   targets take, and it is correct rather than quick - which is what they can
   afford, since neither has a screen of any size. *)
PROCEDURE FillBytes (adr, n, v: INTEGER);
BEGIN
    FillRange(adr, n, v)
END FillBytes;

PROCEDURE FillWords (adr, n, v: INTEGER);
VAR
    k, m: INTEGER;

BEGIN
    IF n > 0 THEN
        PutByte(adr, v);
        PutByte(adr + 1, v DIV 256);
        k := 1;
        WHILE k < n DO
            m := MIN(k, n - k);
            SYSTEM.MOVE(adr, adr + k * 2, m * 2);
            INC(k, m)
        END
    END
END FillWords;

PROCEDURE FillDwords (adr, n, v: INTEGER);
VAR
    k, m: INTEGER;

BEGIN
    IF n > 0 THEN
        PutByte(adr, v);
        PutByte(adr + 1, v DIV 100H);
        PutByte(adr + 2, v DIV 10000H);
        PutByte(adr + 3, v DIV 1000000H);
        k := 1;
        WHILE k < n DO
            m := MIN(k, n - k);
            SYSTEM.MOVE(adr, adr + k * 4, m * 4);
            INC(k, m)
        END
    END
END FillDwords;

$END

(* The first byte equal to v among the n at adr, its index written at the
   address dst - and nothing written at all when there is none, which is why
   the caller puts -1 there first.  Nothing comes back in a register: a
   function of this module is an Oberon function and its result is the
   compiler's business, while a procedure that ends on its label is the shape
   the compiler's own epilogue already knows how to follow.

   One instruction does the whole search.  repne scasb compares AL with the
   byte at EDI and repeats while they differ and ECX lasts, so the index comes
   out of where EDI stopped: one past the match when ZF says it matched, and
   wherever the count ran out when it does not - which is why the answer is
   only stored on the matched path.  The count is tested first because a rep
   with ECX = 0 would still read EDI, and a search of nothing is legal.

   This is only sound inside one piece.  It is a *byte* being looked for and a
   byte has no tail, so no match can straddle a piece boundary and the walk
   over the pieces loses nothing - which is what makes the primitive this
   cheap.  A substring could not be done this way, and a text search built on
   this therefore looks for its first byte here and compares the rest itself.

   EDI and the direction flag belong to the caller, hence the push and the
   CLD; EAX, ECX and EDX are the scratch of the sequence. *)
$IF (CPU_I386)

PROCEDURE [stdcall] ScanBytes (adr, n, v, dst: INTEGER);
BEGIN
    SYSTEM.CODE(
    057H,                (*  push edi                            *)
    08BH, 07DH, 008H,    (*  mov edi, dword [ebp + 8]   adr      *)
    08BH, 04DH, 00CH,    (*  mov ecx, dword [ebp + 12]  n        *)
    08BH, 045H, 010H,    (*  mov eax, dword [ebp + 16]  v        *)
    085H, 0C9H,          (*  test ecx, ecx                       *)
    07EH, 010H,          (*  jle L                               *)
    0FCH,                (*  cld                                 *)
    0F2H, 0AEH,          (*  repne scasb                         *)
    075H, 00BH,          (*  jne L                               *)
    08BH, 0D7H,          (*  mov edx, edi                        *)
    02BH, 055H, 008H,    (*  sub edx, dword [ebp + 8]   adr      *)
    04AH,                (*  dec edx                             *)
    08BH, 04DH, 014H,    (*  mov ecx, dword [ebp + 20]  dst      *)
    089H, 011H,          (*  mov [ecx], edx                      *)
    05FH                 (*  pop edi                             *)
                         (*  L:                                  *)
                )
END ScanBytes;

$ELSIF (CPU_AMD64)

PROCEDURE [oberon] ScanBytes (adr, n, v, dst: INTEGER);
BEGIN
    SYSTEM.CODE(
    057H,                    (*  push rdi                        *)
    048H, 08BH, 07DH, 010H,  (*  mov rdi, qword [rbp + 16]  adr  *)
    048H, 08BH, 04DH, 018H,  (*  mov rcx, qword [rbp + 24]  n    *)
    048H, 08BH, 045H, 020H,  (*  mov rax, qword [rbp + 32]  v    *)
    048H, 085H, 0C9H,        (*  test rcx, rcx                   *)
    07EH, 016H,              (*  jle L                           *)
    0FCH,                    (*  cld                             *)
    0F2H, 0AEH,              (*  repne scasb                     *)
    075H, 011H,              (*  jne L                           *)
    048H, 08BH, 0D7H,        (*  mov rdx, rdi                    *)
    048H, 02BH, 055H, 010H,  (*  sub rdx, qword [rbp + 16]  adr  *)
    048H, 0FFH, 0CAH,        (*  dec rdx                         *)
    048H, 08BH, 04DH, 028H,  (*  mov rcx, qword [rbp + 40]  dst  *)
    048H, 089H, 011H,        (*  mov [rcx], rdx                  *)
    05FH                     (*  pop rdi                         *)
                             (*  L:                              *)
                )
END ScanBytes;

$ELSE

(* The same walk with no string instruction to lean on: one byte at a time,
   which is what a target with no rep can afford and what the x86 pair is
   measured against.  A BYTE local and not an INTEGER, because a GET of a byte
   through the back end's four-byte read would take three bytes of the next
   value with it and the compare could then never be true - the one place in
   this file where the width of a SYSTEM.GET actually matters. *)
PROCEDURE ScanBytes (adr, n, v, dst: INTEGER);
VAR
    i: INTEGER;
    b: BYTE;
    found: BOOLEAN;

BEGIN
    i := 0;
    found := FALSE;
    WHILE (i < n) & ~found DO
        SYSTEM.GET(adr + i, b);
        found := b = v;
        IF ~found THEN INC(i) END
    END;
    IF found THEN PutByte(dst, i) END
END ScanBytes;

$END

(* The count bytes at idx as one little-endian value, byte idx the least
   significant one.  They are gathered one at a time and not with
   SYSTEM.GET16, because from the second byte on each may sit in a different
   block and only the first byte's address is known here.  The multiplication
   is what zero-extends: the value built never carries a sign of its own,
   and on a 64-bit target a Get32 is therefore never negative. *)
PROCEDURE GetValue (self: ByteArray; idx, count: INTEGER): INTEGER;
VAR
    v, i: INTEGER;

BEGIN
    ASSERT((idx >= 0) & (count > 0) & (idx + count <= self.count));
    v := 0;
    i := count;
    WHILE i > 0 DO
        DEC(i);
        v := v * 256 + GetByte(ElemAdr(self, idx + i))
    END;

    RETURN v
END GetValue;

(* The count low bytes of v written at idx, least significant first.  LSR
   shifts the pattern and not the sign, so a negative v gives the two's
   complement bytes it stands for; MOD would not do, being the remainder with
   the sign of the dividend and so negative for a negative v. *)
PROCEDURE PutValue (self: ByteArray; idx, count, v: INTEGER);
VAR
    i: INTEGER;

BEGIN
    ASSERT((idx >= 0) & (count > 0) & (idx + count <= self.count));
    i := 0;
    WHILE i < count DO
        PutByte(ElemAdr(self, idx + i), v);
        v := LSR(v, 8);
        INC(i)
    END
END PutValue;

PROCEDURE AddBlock (self: ByteArray);
BEGIN
    ASSERT(self.blocks < MaxBlocks);
    self.dir[self.blocks] := Heap.Alloc(Full(self.blocks));
    INC(self.blocks)
END AddBlock;

(* Room for n bytes, with the blocks the array does not have yet allocated and
   their contents left as the allocator left them.  The gap a growth opens is
   either zeroed by SetLength or written by Append, so nothing reads it
   undefined. *)
PROCEDURE Reserve (self: ByteArray; n: INTEGER);
BEGIN
    WHILE self.Capacity(self) < n DO
        AddBlock(self)
    END
END Reserve;

PROCEDURE Capacity (self: ByteArray): INTEGER;
BEGIN
    RETURN ChunkBytes * (LSL(1, self.blocks) - 1)
END Capacity;

(* Resize.  Growing allocates blocks and zeroes the bytes the array has not
   defined yet, so that a byte past the old end reads as zero rather than as
   what the allocator had there.  Shrinking keeps the blocks - capacity never
   falls, and the bytes that were there are still there if it grows again. *)
PROCEDURE SetLength (self: ByteArray; newLen: INTEGER);
VAR
    i, k: INTEGER;

BEGIN
    ASSERT((newLen >= 0) & (newLen <= MaxBytes));
    IF newLen > self.count THEN
        Reserve(self, newLen);
        i := self.count;
        WHILE i < newLen DO
            k := Piece(i, newLen - i);
            FillRange(ElemAdr(self, i), k, 0);
            INC(i, k)
        END
    END;
    self.count := newLen
END SetLength;

PROCEDURE Length (self: ByteArray): INTEGER;
BEGIN
    RETURN self.count
END Length;

(* The address of byte idx, for reading or writing in place.  It stays valid
   for as long as that byte is in the array: a block is never moved and never
   reallocated, and growing adds blocks rather than replacing one. *)
PROCEDURE Adr (self: ByteArray; idx: INTEGER): INTEGER;
BEGIN
    ASSERT((idx >= 0) & (idx < self.count));

    RETURN ElemAdr(self, idx)
END Adr;

(* How many bytes from idx onwards lie in idx's own block, which is what the
   address Adr answers with is good for: the bytes past that run are in another
   allocation and are not next to them.

   This is the companion Adr needs.  Reading a stretch of the array by address -
   a screen row out of a text store, say - costs one SYSTEM.GET a byte, and EDI
   that never has to be reloaded; without the run length every one of those
   reads would have to go through Get8's bounds test and its call, or the reader
   would have to copy the stretch out first.  Only this module knows where the
   blocks end, so it is the length that has to be asked for. *)
PROCEDURE RunLen (self: ByteArray; idx: INTEGER): INTEGER;
BEGIN
    ASSERT((idx >= 0) & (idx < self.count));

    RETURN Piece(idx, self.count - idx)
END RunLen;

PROCEDURE Get8 (self: ByteArray; idx: INTEGER): BYTE;
BEGIN
    ASSERT((idx >= 0) & (idx < self.count));

    RETURN GetByte(ElemAdr(self, idx))
END Get8;

PROCEDURE Put8 (self: ByteArray; idx: INTEGER; b: BYTE);
BEGIN
    ASSERT((idx >= 0) & (idx < self.count));
    PutByte(ElemAdr(self, idx), b)
END Put8;

PROCEDURE Get16 (self: ByteArray; idx: INTEGER): INTEGER;
BEGIN
    RETURN GetValue(self, idx, 2)
END Get16;

(* Append one value of the given width, growing the array to hold it. *)
PROCEDURE AppendValue (self: ByteArray; v, count: INTEGER);
VAR
    at: INTEGER;

BEGIN
    at := self.count;
    SetLength(self, at + count);
    PutValue(self, at, count, v)
END AppendValue;

PROCEDURE Append8 (self: ByteArray; b: BYTE);
BEGIN
    AppendValue(self, b, 1)
END Append8;

PROCEDURE Append16 (self: ByteArray; v: INTEGER);
BEGIN
    AppendValue(self, v, 2)
END Append16;

$IF (BITS_32 | BITS_64)
PROCEDURE Get32 (self: ByteArray; idx: INTEGER): INTEGER;
BEGIN
    RETURN GetValue(self, idx, 4)
END Get32;

PROCEDURE Put32 (self: ByteArray; idx: INTEGER; v: INTEGER);
BEGIN
    PutValue(self, idx, 4, v)
END Put32;

PROCEDURE Append32 (self: ByteArray; v: INTEGER);
BEGIN
    AppendValue(self, v, 4)
END Append32;
$END

$IF (BITS_64)
PROCEDURE Get64 (self: ByteArray; idx: INTEGER): INTEGER;
BEGIN
    RETURN GetValue(self, idx, 8)
END Get64;

PROCEDURE Put64 (self: ByteArray; idx: INTEGER; v: INTEGER);
BEGIN
    PutValue(self, idx, 8, v)
END Put64;

PROCEDURE Append64 (self: ByteArray; v: INTEGER);
BEGIN
    AppendValue(self, v, 8)
END Append64;
$END

PROCEDURE Put16 (self: ByteArray; idx: INTEGER; v: INTEGER);
BEGIN
    PutValue(self, idx, 2, v)
END Put16;

(* Every byte of idx..idx+count-1 set to b, one block at a time: the blocks of
   an array are not adjacent, so there is no run of the array that one
   instruction could fill across them.  Fill is this call under the name it was
   written with first. *)
PROCEDURE Fill8 (self: ByteArray; idx, count: INTEGER; b: BYTE);
VAR
    i, k, last: INTEGER;

BEGIN
    ASSERT((idx >= 0) & (count >= 0) & (idx + count <= self.count));
    last := idx + count;
    i := idx;
    WHILE i < last DO
        k := Piece(i, last - i);
        FillBytes(ElemAdr(self, i), k, b);
        INC(i, k)
    END
END Fill8;

(* Every cell of idx..idx+count-1 set to v, which is the fill a screen asks
   for: a cell is a character and its attribute, a word, and a canvas is a run
   of them.  The run is a whole number of cells beginning on a cell, which is
   what TuiCanv.Clear and TuiCanv.Fill hand over, and no cell of it is ever
   split across two blocks - a block is an even number of bytes beginning at an
   even offset, so a piece taken at a cell boundary holds whole cells.  Both
   are asserted, because a caller that broke either would get a shuffled screen
   rather than an error.  v is a cell as Put16 writes one: the low two bytes of
   the value it is given, so a wider value keeps its character and attribute
   and loses the rest. *)
PROCEDURE Fill16 (self: ByteArray; idx, count: INTEGER; v: INTEGER);
VAR
    i, k, last: INTEGER;

BEGIN
    ASSERT((idx >= 0) & (count >= 0) & (idx + count <= self.count));
    ASSERT((idx MOD 2 = 0) & (count MOD 2 = 0));
    last := idx + count;
    i := idx;
    WHILE i < last DO
        k := Piece(i, last - i);
        FillWords(ElemAdr(self, i), k DIV 2, v);
        INC(i, k)
    END
END Fill16;

$IF (BITS_32 | BITS_64)

(* Every dword of idx..idx+count-1 set to v.  Same contract as Fill16 one width
   up: the run is a whole number of four-byte units beginning on one, which is
   what TuiCanv.Clear and TuiCanv.Fill hand over - a screen cell is a code
   point and its attribute now, four bytes - and no unit of it is split across
   two blocks, because a block is a multiple of four bytes beginning at a
   multiple of four.  Both are asserted, because a caller that broke either
   would get a shuffled screen rather than an error.  v is a cell as Put32
   writes one: the low four bytes of the value it is given. *)
PROCEDURE Fill32 (self: ByteArray; idx, count: INTEGER; v: INTEGER);
VAR
    i, k, last: INTEGER;

BEGIN
    ASSERT((idx >= 0) & (count >= 0) & (idx + count <= self.count));
    ASSERT((idx MOD 4 = 0) & (count MOD 4 = 0));
    last := idx + count;
    i := idx;
    WHILE i < last DO
        k := Piece(i, last - i);
        FillDwords(ElemAdr(self, i), k DIV 4, v);
        INC(i, k)
    END
END Fill32;

$END

(* The byte fill under the name it had first, and now the same call and the
   same speed. *)
PROCEDURE Fill (self: ByteArray; idx, count: INTEGER; b: BYTE);
BEGIN
    Fill8(self, idx, count, b)
END Fill;

(* n bytes from memory at srcAdr written at index atIdx, which must already be
   inside the array: this writes, it does not grow.  The memory must lie
   outside the array - an address inside it would be overwritten as it was
   read, and Copy is the method for that case. *)
PROCEDURE CopyMem (self: ByteArray; atIdx: INTEGER; srcAdr, n: INTEGER);
VAR
    p, k: INTEGER;

BEGIN
    ASSERT((atIdx >= 0) & (n >= 0) & (atIdx + n <= self.count));
    p := 0;
    WHILE p < n DO
        k := Piece(atIdx + p, n - p);
        SYSTEM.MOVE(srcAdr + p, ElemAdr(self, atIdx + p), k);
        INC(p, k)
    END
END CopyMem;

(* n bytes of the array, from index srcIdx, written to memory at dstAdr. *)
PROCEDURE CopyTo (self: ByteArray; srcIdx, count: INTEGER; dstAdr: INTEGER);
VAR
    p, k: INTEGER;

BEGIN
    ASSERT((srcIdx >= 0) & (count >= 0) & (srcIdx + count <= self.count));
    p := 0;
    WHILE p < count DO
        k := Piece(srcIdx + p, count - p);
        SYSTEM.MOVE(ElemAdr(self, srcIdx + p), dstAdr + p, k);
        INC(p, k)
    END
END CopyTo;

(* Shift count bytes from srcIdx to dstIdx, both inside the array already.
   The ranges may overlap and either may be the higher one, so this is a
   memmove - except that SYSTEM.MOVE is not: it copies towards the higher
   address, so a run that goes downwards can be any length, the write
   trailing the read, while a run that goes upwards must stop short of the
   bytes it has yet to read and is capped at the distance between the two
   ranges.  Bounded that way, the destination of every run begins at or above
   the end of its source, and the copy towards the higher address reads each
   byte before it writes it. *)
PROCEDURE Move (self: ByteArray; dstIdx, srcIdx, count: INTEGER);
VAR
    d, p, k: INTEGER;

BEGIN
    ASSERT((count >= 0) & (dstIdx + count <= self.count) & (srcIdx + count <= self.count));
    IF (count > 0) & (dstIdx # srcIdx) THEN
        IF dstIdx < srcIdx THEN
            p := 0;
            WHILE p < count DO
                k := MIN(Piece(srcIdx + p, count - p), Piece(dstIdx + p, count - p));
                SYSTEM.MOVE(ElemAdr(self, srcIdx + p), ElemAdr(self, dstIdx + p), k);
                INC(p, k)
            END
        ELSE
            d := dstIdx - srcIdx;
            p := count;
            WHILE p > 0 DO
                k := MIN(MIN(PieceBack(srcIdx + p - 1, p), PieceBack(dstIdx + p - 1, p)), MIN(p, d));
                DEC(p, k);
                SYSTEM.MOVE(ElemAdr(self, srcIdx + p), ElemAdr(self, dstIdx + p), k)
            END
        END
    END
END Move;

(* count bytes of src, from index idx, written over self starting at atIdx,
   which must already have room for them.  src = self is legal: the ranges may
   overlap either way and Move is what handles that, so sliding a run of the
   array along itself is a Copy. *)
PROCEDURE Copy (self: ByteArray; atIdx: INTEGER; src: ByteArray; idx, count: INTEGER);
VAR
    p, k: INTEGER;

BEGIN
    ASSERT((idx >= 0) & (count >= 0) & (idx + count <= src.count));
    ASSERT((atIdx >= 0) & (atIdx + count <= self.count));
    IF src = self THEN
        Move(self, atIdx, idx, count)
    ELSE
        p := 0;
        WHILE p < count DO
            k := Piece(idx + p, count - p);     (* bounded by the source's block *)
            CopyMem(self, atIdx + p, ElemAdr(src, idx + p), k);
            INC(p, k)
        END
    END
END Copy;

(* count bytes of src, from index idx, appended to self, which grows to hold
   them.  src = self is legal and copies the array onto its own end: count and
   idx are the caller's, read before the growth, so growing a source that is
   the array itself cannot change what is being appended. *)
PROCEDURE Append (self: ByteArray; src: ByteArray; idx, count: INTEGER);
VAR
    at, p, k: INTEGER;

BEGIN
    ASSERT((idx >= 0) & (count >= 0) & (idx + count <= src.count));
    at := self.count;
    ASSERT(at + count <= MaxBytes);
    Reserve(self, at + count);      (* every byte opened is written below *)
    self.count := at + count;
    IF src = self THEN
        Move(self, at, idx, count)
    ELSE
        p := 0;
        WHILE p < count DO
            k := Piece(idx + p, count - p);     (* bounded by the source's block *)
            CopyMem(self, at + p, ElemAdr(src, idx + p), k);
            INC(p, k)
        END
    END
END Append;

(* The whole of src appended to self. *)
PROCEDURE AppendFull (self: ByteArray; src: ByteArray);
BEGIN
    Append(self, src, 0, src.count)
END AppendFull;

(* n bytes from memory at srcAdr appended to self, which grows to hold them.
   The memory must lie outside the array, as for CopyMem. *)
PROCEDURE AppendMem (self: ByteArray; srcAdr, n: INTEGER);
VAR
    at: INTEGER;

BEGIN
    at := self.count;
    ASSERT((n >= 0) & (at + n <= MaxBytes));
    Reserve(self, at + n);
    self.count := at + n;
    CopyMem(self, at, srcAdr, n)
END AppendMem;

(* A string is stored asciiz: the characters, one byte each, and then the 0X
   that ends them.  Nothing is encoded on the way in - a source file is UTF-8
   here, so the characters of a literal are already its UTF-8 bytes and copying
   them copies the encoding as it stands.

   GetStr copies the string at idx into dst, and stops at the first zero byte
   in the array, when dst has no room left for another character and the
   terminator (its length less one), or at the end of the array, whichever
   comes first.  dst is always terminated, so a string that does not fit is
   truncated rather than lost. *)
PROCEDURE GetStr (self: ByteArray; idx: INTEGER; VAR dst: ARRAY OF CHAR);
VAR
    i, n: INTEGER;
    ch: BYTE;

BEGIN
    ASSERT((idx >= 0) & (idx <= self.count));
    n := LEN(dst) - 1;                  (* the terminator needs one of them *)
    IF n > self.count - idx THEN
        n := self.count - idx
    END;
    i := 0; ch := 1;                    (* one, so that the loop reads a byte *)
    WHILE (i < n) & (ch # 0) DO
        ch := Get8(self, idx + i);
        IF ch # 0 THEN
            dst[i] := CHR(ch);
            INC(i)
        END
    END;
    dst[i] := 0X
END GetStr;

(* The index of the first byte equal to b at or after from, or -1 when there is
   no such byte in the array.  from past the end is an empty search and not an
   error, and a negative from is taken from the start, so a caller may pass a
   caret or an offset it has not bounded itself.

   The array is walked one piece at a time, because that is what the storage
   is: bytes that are contiguous within a piece and nowhere else.  Piece gives
   the length of the run from i, which is the whole of it except for the last
   piece of the array, so the walk asks for the smaller of that and what is
   left.  A byte that is not found advances i by the piece and the next scan
   begins at the first byte of the next block.

   The scan itself is ScanBytes, which is repne scasb where the target has one
   - one instruction a piece instead of one call and one address computation a
   byte, the difference between a search that is fast enough to run on every
   keystroke of an incremental find and one that is not.  Nothing is lost at a
   boundary: a byte has no tail.  This is the primitive a text search is built
   on, and a caller that wants a string looks for its first byte here and
   compares the rest itself - a query of one character, which is the common
   case, then costs exactly this. *)
PROCEDURE FindByte (self: ByteArray; from: INTEGER; b: BYTE): INTEGER;
VAR
    i, n, res: INTEGER;

BEGIN
    res := -1;
    i := from;
    IF i < 0 THEN i := 0 END;
    WHILE (i < self.count) & (res < 0) DO
        n := Piece(i, self.count - i);
        ScanBytes(ElemAdr(self, i), n, b, SYSTEM.ADR(res));
        IF res >= 0 THEN
            INC(res, i)
        ELSE
            INC(i, n)
        END
    END;

    RETURN res
END FindByte;

(* The string dst written over the array at idx, characters first and then the
   terminator, so n characters need n + 1 bytes. *)
PROCEDURE PutStr (self: ByteArray; idx: INTEGER; dst: ARRAY OF CHAR);
VAR
    i, n: INTEGER;

BEGIN
    n := Strings.Length(dst);
    ASSERT((idx >= 0) & (idx + n + 1 <= self.count));
    i := 0;
    WHILE i < n DO
        PutByte(ElemAdr(self, idx + i), ORD(dst[i]));
        INC(i)
    END;
    PutByte(ElemAdr(self, idx + n), 0)
END PutStr;

(* The string src appended to the array, which grows to hold it, terminator
   included.  An array of strings is built by appending one after another, and
   GetStr reads them back one after another. *)
PROCEDURE AppendStr (self: ByteArray; src: ARRAY OF CHAR);
VAR
    at: INTEGER;

BEGIN
    at := self.count;
    SetLength(self, at + Strings.Length(src) + 1);
    PutStr(self, at, src)
END AppendStr;

(* Delete count bytes at idx, closing the gap. *)
PROCEDURE Remove (self: ByteArray; idx, count: INTEGER);
BEGIN
    ASSERT((idx >= 0) & (count >= 0) & (idx + count <= self.count));
    Move(self, idx, idx + count, self.count - idx - count);
    SetLength(self, self.count - count)
END Remove;

(* Give every block back to Heap and the record to the allocator, which is the
   DISPOSE that answers the NEW of Create.  The caller's variable is dangling
   afterwards and the methods must not be called again.

   The parameter is `Oberon.Object`, not `ByteArray`, and the guard below is
   why: this is what goes into the inherited `Done` field, whose declared type
   is `PROCEDURE (self: Object)`, and a procedure variable has to match its
   field's type exactly.  It is the one piece of ceremony the root type costs
   a class, and Oberon.mod has the rule written out. *)
PROCEDURE Done (self: Oberon.Object);
VAR
    b: ByteArray;
    i: INTEGER;

BEGIN
    b := self(ByteArray);
    i := 0;
    WHILE i < b.blocks DO
        Heap.Free(b.dir[i]); b.dir[i] := 0; INC(i)
    END;
    b.count := 0;
    b.blocks := 0;
    DISPOSE(b)
END Done;

(* Give back the blocks past the end of the bytes in use, the ones a SetLength
   that grew and then shrank left behind.  The first block whose base is at or
   past the length is the first one nothing is stored in, and Base is monotone,
   so a scan finds it.  Unlike Done the array stays usable: what it holds is
   untouched and the blocks those bytes need are the ones it keeps. *)
PROCEDURE Pack (self: ByteArray);
VAR
    keep, i: INTEGER;

BEGIN
    keep := 0;
    WHILE (keep < self.blocks) & (Base(keep) < self.count) DO INC(keep) END;
    i := keep;
    WHILE i < self.blocks DO
        Heap.Free(self.dir[i]); self.dir[i] := 0; INC(i)
    END;
    self.blocks := keep
END Pack;

(* Every byte of the array written to the file, which must already be open for
   writing.  The file is the caller's: it is not opened, rewound or closed
   here, so several arrays go into one file one after another and the position
   after the last of them is where the next write would land.  It is a VAR
   parameter because Files.File is a record and every call in Files takes it by
   reference - a copy would be written through a file the caller never sees
   again.  FALSE when a write comes up short or Files has latched an error;
   a caller that closes the file itself reads Ok again after the close, which
   is where the last flush lands. *)
PROCEDURE Write (self: ByteArray; VAR f : Files.File): BOOLEAN;
VAR
    buf: ARRAY BufSize OF BYTE;
    i, m, k: INTEGER;
    ok: BOOLEAN;
BEGIN
    i := 0; ok := TRUE;
    WHILE ok & (i < self.count) DO
        m := MIN(BufSize, self.count - i);
        CopyTo(self, i, m, SYSTEM.ADR(buf));
        k := Files.BlockWrite(f, buf, m);
        IF k # m THEN
            ok := FALSE
        END;
        INC(i, m)
    END;

    RETURN ok & Files.Ok(f)
END Write;

(* Every byte of the array written to the file, which is created or truncated.
   FALSE when the file cannot be opened or a write falls short; the write
   error is latched by Files and survives Close, so it is read after the last
   flush rather than before it. *)
PROCEDURE Save (self: ByteArray; name: ARRAY OF CHAR): BOOLEAN;
VAR
    f: Files.File;
    ok: BOOLEAN;
BEGIN
    ok := Files.ReWrite(f, name);
    IF ok THEN
        ok := Write(self, f);
        Files.Close(f);
        ok := ok & Files.Ok(f)
    END;

    RETURN ok
END Save;

(* An array of size zero bytes.  The blocks are not allocated until a byte
   needs one, so Create(0) is the empty array to grow into.  This is where the
   methods are bound to the record: after it returns, self.Put8 is Put8 and so
   on, and the caller needs nothing but the value it was handed. *)
PROCEDURE Create* (size: INTEGER): ByteArray;
VAR
    self: ByteArray;

BEGIN
    ASSERT((size >= 0) & (size <= MaxBytes));
    NEW(self);
    self.count := 0;
    self.blocks := 0;
    self.Length := Length;
    self.Capacity := Capacity;
    self.Adr := Adr;
    self.RunLen := RunLen;
    self.Get8 := Get8;
    self.Get16 := Get16;
    self.GetStr := GetStr;
    self.FindByte := FindByte;
$IF (BITS_32 | BITS_64)
    self.Get32 := Get32;
$END
$IF (BITS_64)
    self.Get64 := Get64;
$END
    self.Put8 := Put8;
    self.Put16 := Put16;
    self.PutStr := PutStr;
$IF (BITS_32 | BITS_64)
    self.Put32 := Put32;
$END
$IF (BITS_64)
    self.Put64 := Put64;
$END
    self.Append8 := Append8;
    self.Append16 := Append16;
    self.AppendStr := AppendStr;
$IF (BITS_32 | BITS_64)
    self.Append32 := Append32;
$END
$IF (BITS_64)
    self.Append64 := Append64;
$END
    self.Fill := Fill;
    self.Fill8 := Fill8;
    self.Fill16 := Fill16;
$IF (BITS_32 | BITS_64)
    self.Fill32 := Fill32;
$END
    self.SetLength := SetLength;
    self.Pack := Pack;
    self.Append := Append;
    self.AppendFull := AppendFull;
    self.AppendMem := AppendMem;
    self.Copy := Copy;
    self.CopyMem := CopyMem;
    self.CopyTo := CopyTo;
    self.Move := Move;
    self.Remove := Remove;
    self.Save := Save;
    self.Write := Write;
    self.Done := Done;
    IF size > 0 THEN
        SetLength(self, size)
    END

    RETURN self
END Create;

(* The whole of a file as bytes.  NIL when the file cannot be opened, is
   larger than MaxBytes, or ends before the size it reported - an empty file
   gives an empty array and not NIL.  It sits below Create and AppendMem
   rather than beside CreateFromFile's cousins because a procedure has to be
   declared before it is used. *)
PROCEDURE CreateFromFile* (name: ARRAY OF CHAR): ByteArray;
VAR
    f: Files.File;
    self: ByteArray;
    buf: ARRAY BufSize OF BYTE;
    size, got, m, k: INTEGER;
    ok: BOOLEAN;

BEGIN
    self := NIL;
    IF Files.Reset(f, name) THEN
        size := Files.Size(f);
        IF (size >= 0) & (size <= MaxBytes) THEN
            self := Create(0);
            got := 0; ok := TRUE;
            WHILE ok & (got < size) DO
                m := MIN(BufSize, size - got);
                k := Files.BlockRead(f, buf, m);
                IF k <= 0 THEN
                    ok := FALSE            (* the file ended early *)
                ELSE
                    self.AppendMem(self, SYSTEM.ADR(buf), k);
                    INC(got, k)
                END
            END;
            IF ~ok THEN
                self.Done(self); self := NIL
            END
        END;
        Files.Close(f)
    END;

    RETURN self
END CreateFromFile;

END ByteArr.
