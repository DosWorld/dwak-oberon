(* Public domain. Copyright (c) 2026, DosWorld.

   A growable sequence of fixed-size elements, shared by every target.

   The elements are bytes: the storage is a ByteArr, and every block, every
   byte address and every move at the byte level belongs to it (see
   ByteArr).  What is here is the geometry on top of it - which byte an
   element starts at - and the operations a sequence of elements needs.

   Element i of block c starts at byte ChunkBytes*(2^c - 1) + (i - per*(2^c -
   1))*stride, where stride is the element size rounded up to a word and per is
   the number of strides one block holds, ChunkBytes DIV stride.  The elements
   of a block lie one stride apart inside it and none of them straddles the
   boundary: block c holds per*2^c of them, so a list of b blocks holds
   per*(2^b - 1) - the byte array's capacity divided by the stride.  Because a
   stride is a whole number of words and a block begins on a word, a stored
   element is aligned for any type, and because the block under it is never
   moved, an element's address stays valid for as long as the element is in the
   list.  What a block cannot hold is left unused: six-byte elements take a
   stride of eight, so 511 of them fill a block on a 64-bit target and four
   bytes of it are never touched.

   The element size is fixed at CreateList and may not exceed ChunkBytes, one
   block's worth of bytes, since an element has to lie inside one block.
   Elements are copied in and out by address: Add copies from an address the
   caller supplies, Get answers with the address of the stored element, and the
   caller converts between the two with SYSTEM.ADR and SYSTEM.VAL.

   CreateList makes the list and Done unmakes it: Done gives every block back
   to Heap through the byte array and disposes the list record itself, so the
   caller's variable is left dangling and must not be used again.  Both List
   and Map are `Oberon.Object`s - their records extend ObjectDesc and inherit
   the `Done` field from it; see Oberon.mod for the root type and for why the
   destructor is not optional.  Clear
   empties the list but keeps its blocks - that, and not Done, is how a list is
   refilled.  Pack gives back the blocks past the end of the elements in use.
   Every procedure but CreateList and CreateListCapacity needs a list that has
   been created, and every procedure but Done leaves one that can still be
   used.

   Map, beside it, is a table of string keys to fixed-size values, written the
   same way and built on the same list: a key is stored zero-padded to keySize
   and a value is an element of a list, so both keep a stable, aligned address.
   Lookup is open addressing over a table of slots, a removed entry is reused
   rather than shifted, and there is no way to walk a map - it is asked about a
   key.  CreateMap and CreateMapCapacity make one, Done unmakes it, and Clear
   and Pack answer for a map as they do for a list.

   Requires ByteArr, and through it Heap, Files, SYSTEM and DISPOSE (see
   ByteArr), and Oberon, whose Object is the base of both of the types here.
   Not thread safe.
*)
MODULE Arrays;

IMPORT ByteArr, Oberon, SYSTEM;

CONST
    (* A block of the list is a block of the byte array, which is one chunk of
       Heap, so the element geometry is the byte geometry counted in strides. *)
    ChunkBytes = ByteArr.ChunkBytes;
    (* The slot table of a map.  Its size is a power of two, it never holds
       more entries than half as many slots as it has, and it starts at eight
       slots, so a probe always meets an empty one and the arithmetic stays a
       single MOD. *)
    MinSlots = 8;
    (* The modulus of the hash: a prime below 2^23, so that multiplying it by
       31 and adding a byte cannot overflow a 32-bit INTEGER, and the hash is
       never negative whatever the word size. *)
    $IF (BITS_16)
        HashMod = 997;
    $ELSE
        HashMod = 6700417;
    $END

TYPE
    List* = POINTER TO ListDesc;
    (* List and Map are `Oberon.Object`s: both records extend ObjectDesc, so
       both inherit the `Done` field and neither declares one of its own.
       What each supplies is a procedure taking `Oberon.Object`, bound into
       that field by CreateList and CreateMap - see Oberon.mod for what the
       root is for and why a destructor is not optional. *)
    ListDesc* = RECORD (Oberon.ObjectDesc)
        (* The elements, as bytes, in the blocks of the byte array. *)
        bytes:  ByteArr.ByteArray;
        size:   INTEGER;    (* bytes of an element, as the caller sees it *)
        stride: INTEGER;    (* bytes between stored elements *)
        per:    INTEGER;    (* elements in block zero *)
        count:  INTEGER;    (* elements in use *)

        (* One pointer per method, bound by Create. *)
        Capacity*:  PROCEDURE (self: List): INTEGER;
        Reserve*:   PROCEDURE (self: List; minCap: INTEGER);
        Add*:       PROCEDURE (self: List; elem: INTEGER);
        Insert*:    PROCEDURE (self: List; i: INTEGER; elem: INTEGER);
        Remove*:    PROCEDURE (self: List; i: INTEGER);
        Put*:       PROCEDURE (self: List; i: INTEGER; elem: INTEGER);
        Get*:       PROCEDURE (self: List; i: INTEGER): INTEGER;
        GetCopy*:   PROCEDURE (self: List; i: INTEGER; dst: INTEGER);
        Count*:     PROCEDURE (self: List): INTEGER;
        ElemSize*:  PROCEDURE (self: List): INTEGER;
        Clear*:     PROCEDURE (self: List);
        Pack*:      PROCEDURE (self: List)
    END;

    Map* = POINTER TO MapDesc;
    MapDesc* = RECORD (Oberon.ObjectDesc)
        (* Entry e of the map is keys[e] with vals[e].  Slot s of the table
           holds e + 1, or zero for a slot no key claims.  free is the stack of
           entry indices no key uses; a freed entry keeps its place in keys and
           vals and is reused by the next Put, so an entry index never changes
           for as long as the map lives. *)
        index:  List;       (* slots words: the table *)
        keys:   List;       (* keySize bytes each, zero-padded *)
        vals:   List;       (* valueSize bytes each *)
        free:   List;       (* free entry indices *)
        keybuf: ByteArr.ByteArray;    (* keySize zero bytes: the key buffer *)
        keySize, valSize, slots, count: INTEGER;

        (* One pointer per method, bound by CreateMap. *)
        Put*:       PROCEDURE (self: Map; key: ARRAY OF CHAR; valAdr: INTEGER);
        Get*:       PROCEDURE (self: Map; key: ARRAY OF CHAR; dstAdr: INTEGER): BOOLEAN;
        Contains*:  PROCEDURE (self: Map; key: ARRAY OF CHAR): BOOLEAN;
        ValueAdr*:  PROCEDURE (self: Map; key: ARRAY OF CHAR): INTEGER;
        Remove*:    PROCEDURE (self: Map; key: ARRAY OF CHAR): BOOLEAN;
        Clear*:     PROCEDURE (self: Map);
        Pack*:      PROCEDURE (self: Map);
        Count*:     PROCEDURE (self: Map): INTEGER;
        Capacity*:  PROCEDURE (self: Map): INTEGER;
        KeySize*:   PROCEDURE (self: Map): INTEGER;
        ValueSize*: PROCEDURE (self: Map): INTEGER
    END;

PROCEDURE AlignUp (n, a: INTEGER): INTEGER;
BEGIN
    RETURN (n + a - 1) DIV a * a
END AlignUp;

(* Block c holds per*2^c elements and so begins at element per*(2^c - 1).
   Both are cheap enough to recompute rather than store. *)
PROCEDURE Full (l: List; c: INTEGER): INTEGER;
BEGIN
    RETURN l.per * LSL(1, c)
END Full;

PROCEDURE Base (l: List; c: INTEGER): INTEGER;
BEGIN
    RETURN l.per * (LSL(1, c) - 1)
END Base;

(* Elements stored in block c.  Only the last block in use can be short. *)
PROCEDURE Used (l: List; c: INTEGER): INTEGER;
VAR
    n: INTEGER;

BEGIN
    n := Full(l, c);
    IF Base(l, c) + n > l.count THEN
        n := l.count - Base(l, c)
    END

    RETURN n
END Used;

(* The block holding element i.  Block c begins at element per*(2^c - 1), so
   i DIV per + 1 lies in [2^c, 2^(c+1)), and the largest power of two not
   above it is the block number. *)
PROCEDURE Locate (l: List; i: INTEGER): INTEGER;
VAR
    span, c: INTEGER;

BEGIN
    span := 1; c := 0;
    WHILE span * 2 <= i DIV l.per + 1 DO
        span := span * 2;
        INC(c)
    END;

    RETURN c
END Locate;

(* The first byte of block c: the blocks before it hold ChunkBytes*(2^c - 1)
   bytes between them. *)
PROCEDURE ByteBase (c: INTEGER): INTEGER;
BEGIN
    RETURN ChunkBytes * (LSL(1, c) - 1)
END ByteBase;

(* The byte element i starts at.  It lies inside one block, because per is a
   whole number of strides, so this is the address of the whole element. *)
PROCEDURE ByteOf (l: List; i: INTEGER): INTEGER;
VAR
    c: INTEGER;

BEGIN
    c := Locate(l, i);

    RETURN ByteBase(c) + (i - Base(l, c)) * l.stride
END ByteOf;

(* The bytes the array must hold for n elements: the last of them and no more.
   No elements need no bytes. *)
PROCEDURE BytesFor (l: List; n: INTEGER): INTEGER;
VAR
    bytes: INTEGER;

BEGIN
    bytes := 0;
    IF n > 0 THEN
        bytes := ByteOf(l, n - 1) + l.stride
    END;

    RETURN bytes
END BytesFor;

PROCEDURE Capacity (l: List): INTEGER;
BEGIN
    RETURN l.per * (l.bytes.Capacity(l.bytes) DIV ChunkBytes)
END Capacity;

(* Room for minCap elements.  Never shrinks: a list that has held many elements
   keeps its blocks until Pack or Done gives them back.  Growing the list grows
   the byte array, which zeroes the bytes it opens. *)
PROCEDURE Reserve (l: List; minCap: INTEGER);
VAR
    want: INTEGER;

BEGIN
    ASSERT(minCap >= 0);
    want := BytesFor(l, minCap);
    IF want > l.bytes.Length(l.bytes) THEN
        l.bytes.SetLength(l.bytes, want)
    END
END Reserve;

(* Append an element, copied from the address elem.  The address must lie
   outside the list. *)
PROCEDURE Add (l: List; elem: INTEGER);
BEGIN
    ASSERT(elem # 0);
    l.bytes.SetLength(l.bytes, BytesFor(l, l.count + 1));
    l.bytes.CopyMem(l.bytes, ByteOf(l, l.count), elem, l.size);
    INC(l.count)
END Add;

(* Open a place at index i and put a copy of the element at elem in it.

   The elements from i on move up one, one block at a time from the top down.
   A block above the one being shifted has already been shifted, so a full
   block simply hands its last element to the base of the block above - which
   the pass has already emptied.  Inside a block the elements go in one move
   instead of one move each: ByteArr.Move carries a run towards the higher
   address safely, and every destination byte lies one stride above its source
   and inside this block. *)
PROCEDURE Insert (l: List; i: INTEGER; elem: INTEGER);
VAR
    c, b, lo, hi: INTEGER;

BEGIN
    ASSERT((i >= 0) & (i <= l.count));
    ASSERT(elem # 0);
    l.bytes.SetLength(l.bytes, BytesFor(l, l.count + 1));   (* the top slot *)

    IF i < l.count THEN
        c := Locate(l, l.count - 1);        (* the block of the last element *)
        b := Base(l, c);
        hi := Used(l, c);

        WHILE (c >= 0) & (b + hi > i) DO
            lo := i - b;
            IF lo < 0 THEN lo := 0 END;

            IF hi = Full(l, c) THEN
                (* a full block hands its last element to the base of the block
                   above, a slot the pass has already emptied *)
                l.bytes.Move(l.bytes, ByteOf(l, b + hi), ByteOf(l, b + hi - 1), l.size);
                DEC(hi)
            END;
            IF hi > lo THEN
                (* the rest of the block up one slot *)
                l.bytes.Move(l.bytes, ByteOf(l, b + lo + 1), ByteOf(l, b + lo),
                             (hi - lo) * l.stride)
            END;

            DEC(c);
            IF c >= 0 THEN
                b := Base(l, c);
                hi := Used(l, c)
            END
        END
    END;

    l.bytes.CopyMem(l.bytes, ByteOf(l, i), elem, l.size);
    INC(l.count)
END Insert;

(* Drop element i, closing the gap.  The body is the shift of Insert again,
   downwards, where a run of elements goes in one move.

   The length of that move is the run's span, (n - 1)*stride + size, and not
   n*size: consecutive elements are a stride apart while only size bytes of
   each are data, so n*size stops short of the last element of the run and
   leaves it where it was.

   The count is decremented only at the end, so Used answers with the block as
   it still is: the element being dropped has not left it yet, and the top
   block ends one element further than the shortened list will.  That last
   element is one the shift has to carry down like any other - leave it out
   and the gap stays open at the end of the list. *)
PROCEDURE Remove (l: List; i: INTEGER);
VAR
    c, b, lo, hi, n: INTEGER;

BEGIN
    ASSERT((i >= 0) & (i < l.count));

    c := Locate(l, i);                  (* the block holding the element dropped *)
    WHILE Base(l, c) < l.count DO       (* the block still holds elements *)
        b := Base(l, c);
        lo := i - b;
        IF lo < 0 THEN lo := 0 END;

        hi := b + Used(l, c) - 1;       (* the last element stored in the block *)
        n := hi - b - lo;               (* the elements that follow the gap *)

        IF n > 0 THEN
            l.bytes.Move(l.bytes, ByteOf(l, b + lo), ByteOf(l, b + lo + 1),
                         (n - 1) * l.stride + l.size)
        END;
        IF l.count > b + Full(l, c) THEN
            (* the block above hands its first element down *)
            l.bytes.Move(l.bytes, ByteOf(l, hi), ByteOf(l, hi + 1), l.size)
        END;

        INC(c)
    END;
    DEC(l.count);
    l.bytes.SetLength(l.bytes, BytesFor(l, l.count))
END Remove;

(* Replace element i, copying from the address elem. *)
PROCEDURE Put (l: List; i: INTEGER; elem: INTEGER);
BEGIN
    ASSERT((i >= 0) & (i < l.count));
    ASSERT(elem # 0);
    l.bytes.CopyMem(l.bytes, ByteOf(l, i), elem, l.size)
END Put;

(* The address of element i, for reading or for writing in place. *)
PROCEDURE Get (l: List; i: INTEGER): INTEGER;
BEGIN
    ASSERT((i >= 0) & (i < l.count));

    RETURN l.bytes.Adr(l.bytes, ByteOf(l, i))
END Get;

(* Copy element i to the address dst. *)
PROCEDURE GetCopy (l: List; i: INTEGER; dst: INTEGER);
BEGIN
    ASSERT((i >= 0) & (i < l.count));
    ASSERT(dst # 0);
    l.bytes.CopyTo(l.bytes, ByteOf(l, i), l.size, dst)
END GetCopy;

PROCEDURE Count (l: List): INTEGER;
BEGIN
    RETURN l.count
END Count;

PROCEDURE ElemSize (l: List): INTEGER;
BEGIN
    RETURN l.size
END ElemSize;

(* Empty the list, keeping its blocks, so that refilling it allocates nothing
   until it grows past the capacity it had. *)
PROCEDURE Clear (l: List);
BEGIN
    l.count := 0;
    l.bytes.SetLength(l.bytes, 0)
END Clear;

(* Give back the blocks past the end of the elements in use.  The elements
   themselves keep their addresses: Pack never moves one. *)
PROCEDURE Pack (l: List);
BEGIN
    l.bytes.SetLength(l.bytes, BytesFor(l, l.count));
    l.bytes.Pack(l.bytes)
END Pack;

(* Give the list up: every block goes back to Heap through the byte array and
   the record itself goes back to the allocator, which is the DISPOSE that
   answers the NEW of Create.  The caller's variable is dangling afterwards.

   The parameter is `Oberon.Object` and the guard below is why: this is what
   goes into the inherited `Done` field, whose declared type is `PROCEDURE
   (self: Object)`, and a procedure variable has to match its field's type
   exactly.  Oberon.mod has the rule; _probe/ObjInh.mod measures it. *)
PROCEDURE Done (self: Oberon.Object);
VAR l: List;
BEGIN
    l := self(List);
    l.bytes.Done(l.bytes);
    l.count := 0;
    l.bytes := NIL;
    DISPOSE(l)
END Done;

(* An empty list of elements elemSize bytes each.  Nothing is allocated for the
   elements until one is added.  This is where the methods are bound to the
   record: after it returns, l.Add is Add and so on, and the caller needs
   nothing but the value it was handed. *)
PROCEDURE CreateList* (elemSize: INTEGER): List;
VAR
    l: List;

BEGIN
    ASSERT(elemSize > 0);
    NEW(l);
    l.size := elemSize;
    l.stride := AlignUp(elemSize, SYSTEM.SIZE(INTEGER));
    ASSERT(l.stride <= ChunkBytes);     (* an element has to lie inside one block *)
    l.per := ChunkBytes DIV l.stride;
    l.count := 0;
    l.bytes := ByteArr.Create(0);
    l.Capacity := Capacity;
    l.Reserve := Reserve;
    l.Add := Add;
    l.Insert := Insert;
    l.Remove := Remove;
    l.Put := Put;
    l.Get := Get;
    l.GetCopy := GetCopy;
    l.Count := Count;
    l.ElemSize := ElemSize;
    l.Clear := Clear;
    l.Pack := Pack;
    l.Done := Done;

    RETURN l
END CreateList;

PROCEDURE CreateListCapacity* (elemSize, cap: INTEGER): List;
VAR
    l: List;

BEGIN
    l := CreateList(elemSize);
    IF cap > 0 THEN
        l.Reserve(l, cap)
    END;

    RETURN l
END CreateListCapacity;

(* ---------------------------------------------------------------------------
   Map: keys to values.

   A key is a string - the characters up to its first zero byte, or up to the
   end of the array it is passed in - and it is stored zero-padded to keySize
   and compared as a whole.  The padding is what makes the comparison cheap:
   two keys of the same string are the same keySize bytes wherever they came
   from, so no comparison and no hash has to look for a terminator.  A key
   longer than keySize is a broken contract and not silently truncated.

   A value is valueSize bytes, copied in and out by address, exactly an element
   of a list, so a value in place keeps its address and ValueAdr can hand it
   out.

   The table is open addressing with linear probing over a list of slots: slot
   s holds the index of an entry plus one, or zero for a slot no key claims,
   and entry e is keys[e] with vals[e].  A key that is not in the map is
   answered for without any chain to walk, and the table never holds more
   entries than half its slots, so a probe always ends at an empty slot.  It
   doubles when that limit is reached and Pack rebuilds it at the size the
   entries in use need.

   Remove does not shift an entry out of keys or vals: it puts the entry on a
   free stack for the next Put to reuse, so entry indices never change, and it
   closes the hole in the slot table itself instead - the entries that follow
   move back one slot each, as long as moving one does not carry it out of its
   own probe sequence.  A lookup then never has to step over a removed entry,
   and no slot is ever a tombstone.

   There is no way to walk a map: it is asked about a key.  Contains answers
   whether the key is there, Get copies the value out, ValueAdr answers with
   the address of the stored value, and Put adds or replaces.
   --------------------------------------------------------------------------- *)

(* The smallest power of two whose half holds n entries: the table a map of n
   entries needs, and the one CreateMapCapacity starts from. *)
PROCEDURE MapTightSlots (n: INTEGER): INTEGER;
VAR
    slots: INTEGER;

BEGIN
    slots := MinSlots;
    WHILE slots DIV 2 < n DO
        slots := slots * 2
    END;

    RETURN slots
END MapTightSlots;

(* A table of n empty slots.  Reserve opens the bytes - zeroed, as every byte
   the byte array opens is - and the count is set to the whole table at once,
   which is cheaper than adding n zero words one at a time. *)
PROCEDURE MapNewIndex (n: INTEGER): List;
VAR
    idx: List;

BEGIN
    idx := CreateList(SYSTEM.SIZE(INTEGER));
    idx.Reserve(idx, n);
    idx.count := n;

    RETURN idx
END MapNewIndex;

(* The caller's key as the map keeps it: its characters and then zeros to
   keySize, in the map's own key buffer.  The list a key is stored in can only
   be written whole, from an address outside it, so this buffer is where the
   padding comes from; it is also what MapHash and MapSameKey read the searched
   key from.  A key with no zero byte among its first keySize bytes is longer
   than the map takes and traps here. *)
PROCEDURE MapPrepare (m: Map; key: ARRAY OF CHAR);
VAR
    i, n: INTEGER;

BEGIN
    n := 0;
    WHILE (n < LEN(key)) & (key[n] # 0X) DO INC(n) END;
    ASSERT(n <= m.keySize);
    m.keybuf.Fill(m.keybuf, 0, m.keySize, 0);
    i := 0;
    WHILE i < n DO
        m.keybuf.Put8(m.keybuf, i, ORD(key[i]));
        INC(i)
    END
END MapPrepare;

(* The hash of n bytes at adr, per the modulus of the constant section, so that
   it never goes negative on any word size.  Both a stored key and the searched
   one are zero-padded to keySize, so the same string always hashes alike and
   no terminator has to be found. *)
PROCEDURE MapHash (adr, n: INTEGER): INTEGER;
VAR
    h, i: INTEGER;
    b: BYTE;

BEGIN
    h := 0;
    i := 0;
    WHILE i < n DO
        SYSTEM.GET8(adr + i, b);
        h := (h MOD HashMod) * 31 + b;
        INC(i)
    END;

    RETURN h
END MapHash;

(* Whether entry e holds the key in keybuf.  Both are keySize bytes, the stored
   one and the searched one, so this is a plain byte comparison. *)
PROCEDURE MapSameKey (m: Map; e, kb: INTEGER): BOOLEAN;
VAR
    i: INTEGER;
    adr: INTEGER;
    a, b: BYTE;
    same: BOOLEAN;

BEGIN
    adr := m.keys.Get(m.keys, e);
    same := TRUE;
    i := 0;
    WHILE same & (i < m.keySize) DO
        SYSTEM.GET8(adr + i, a);
        SYSTEM.GET8(kb + i, b);
        same := a = b;
        INC(i)
    END;

    RETURN same
END MapSameKey;

(* The entry holding the key in keybuf, or -1 when the map does not hold it.
   slot is where the probe stopped: the slot holding that entry, or the empty
   slot a Put of the key would take. *)
PROCEDURE MapProbe (m: Map; kb: INTEGER; VAR slot: INTEGER): INTEGER;
VAR
    h, i, v, e: INTEGER;
    adr: INTEGER;
    done: BOOLEAN;

BEGIN
    h := MapHash(kb, m.keySize) MOD m.slots;
    slot := h;
    e := -1;
    done := FALSE;
    i := 0;
    WHILE ~done & (i < m.slots) DO
        adr := m.index.Get(m.index, h);
        SYSTEM.GET(adr, v);
        IF v = 0 THEN
            slot := h;
            done := TRUE
        ELSIF MapSameKey(m, v - 1, kb) THEN
            slot := h;
            e := v - 1;
            done := TRUE
        ELSE
            h := (h + 1) MOD m.slots;
            INC(i)
        END
    END;

    RETURN e
END MapProbe;

(* Whether k lies in the circular interval (i, j].  An entry whose probe
   sequence runs from k to j has to pass i on the way, so it may not take a
   hole left at i; one whose interval does not cover i may. *)
PROCEDURE MapInRange (i, j, k: INTEGER): BOOLEAN;
VAR
    r: BOOLEAN;

BEGIN
    IF i < j THEN
        r := (k > i) & (k <= j)
    ELSE
        r := (k > i) OR (k <= j)
    END;

    RETURN r
END MapInRange;

(* Close the hole at slot i, so that no lookup ever has to step over a removed
   entry: the entries after it move back one slot each, and the hole moves on,
   until an empty slot ends it.  An entry that cannot move - its own probe
   sequence starts inside the interval the hole and it span - is left where it
   is and stepped over, so j walks the table on its own and only i follows it. *)
PROCEDURE MapBackshift (m: Map; hole: INTEGER);
VAR
    i, j, v, k: INTEGER;
    adr: INTEGER;
    done: BOOLEAN;

BEGIN
    i := hole;
    j := hole;
    done := FALSE;
    WHILE ~done DO
        j := (j + 1) MOD m.slots;
        adr := m.index.Get(m.index, j);
        SYSTEM.GET(adr, v);
        IF v = 0 THEN
            done := TRUE
        ELSE
            k := MapHash(m.keys.Get(m.keys, v - 1), m.keySize) MOD m.slots;
            IF ~MapInRange(i, j, k) THEN
                adr := m.index.Get(m.index, i);
                SYSTEM.PUT(adr, v);
                i := j
            END
        END
    END;
    adr := m.index.Get(m.index, i);
    SYSTEM.PUT(adr, 0)
END MapBackshift;

(* A table of newSlots slots holding the entries the old one holds.  The old
   table is the map's list of entries - a removed entry left it at once, and
   the entry it named is on the free stack - so walking it is walking the map,
   and the new table is built before the old one is given up. *)
PROCEDURE MapReindex (m: Map; newSlots: INTEGER);
VAR
    idx: List;
    s, v, h, w: INTEGER;
    adr: INTEGER;
    done: BOOLEAN;

BEGIN
    idx := MapNewIndex(newSlots);
    s := 0;
    WHILE s < m.slots DO
        adr := m.index.Get(m.index, s);
        SYSTEM.GET(adr, v);
        IF v # 0 THEN
            h := MapHash(m.keys.Get(m.keys, v - 1), m.keySize) MOD newSlots;
            done := FALSE;
            WHILE ~done DO
                adr := idx.Get(idx, h);
                SYSTEM.GET(adr, w);
                IF w = 0 THEN
                    done := TRUE
                ELSE
                    h := (h + 1) MOD newSlots
                END
            END;
            adr := idx.Get(idx, h);
            SYSTEM.PUT(adr, v)
        END;
        INC(s)
    END;
    m.index.Done(m.index);
    m.index := idx;
    m.slots := newSlots
END MapReindex;

(* The free stack: the entries a Remove has freed, waiting for the next Put.
   Both ends of it are its last element, which is the one List.Remove moves no
   bytes for. *)
PROCEDURE MapPushFree (m: Map; e: INTEGER);
BEGIN
    m.free.Add(m.free, SYSTEM.ADR(e))
END MapPushFree;

PROCEDURE MapPopFree (m: Map; VAR e: INTEGER): BOOLEAN;
VAR
    n: INTEGER;
    ok: BOOLEAN;

BEGIN
    n := m.free.Count(m.free);
    ok := n > 0;
    IF ok THEN
        m.free.GetCopy(m.free, n - 1, SYSTEM.ADR(e));
        m.free.Remove(m.free, n - 1)
    END;

    RETURN ok
END MapPopFree;

(* Add the key with a copy of the value at valAdr, or replace the value of the
   key that is already there. *)
PROCEDURE MapPut (m: Map; key: ARRAY OF CHAR; valAdr: INTEGER);
VAR
    slot, e, kb: INTEGER;
    adr: INTEGER;

BEGIN
    ASSERT(valAdr # 0);
    MapPrepare(m, key);
    IF m.count + 1 > m.slots DIV 2 THEN      (* room for one more entry *)
        MapReindex(m, m.slots * 2)
    END;
    kb := m.keybuf.Adr(m.keybuf, 0);
    e := MapProbe(m, kb, slot);
    IF e >= 0 THEN
        m.vals.Put(m.vals, e, valAdr)        (* the key is there: its value *)
    ELSE
        IF MapPopFree(m, e) THEN             (* or a freed entry, reused *)
            m.keys.Put(m.keys, e, kb);
            m.vals.Put(m.vals, e, valAdr)
        ELSE                                 (* or a new one, appended *)
            e := m.keys.Count(m.keys);
            m.keys.Add(m.keys, kb);
            m.vals.Add(m.vals, valAdr)
        END;
        adr := m.index.Get(m.index, slot);
        SYSTEM.PUT(adr, e + 1);
        INC(m.count)
    END
END MapPut;

(* Copy the value of the key to dstAdr, answering whether the map holds the
   key.  A key that is not there leaves dstAdr alone. *)
PROCEDURE MapGet (m: Map; key: ARRAY OF CHAR; dstAdr: INTEGER): BOOLEAN;
VAR
    slot, e, kb: INTEGER;
    found: BOOLEAN;

BEGIN
    MapPrepare(m, key);
    kb := m.keybuf.Adr(m.keybuf, 0);
    e := MapProbe(m, kb, slot);
    found := e >= 0;
    IF found THEN
        m.vals.GetCopy(m.vals, e, dstAdr)
    END;

    RETURN found
END MapGet;

PROCEDURE MapContains (m: Map; key: ARRAY OF CHAR): BOOLEAN;
VAR
    slot, kb: INTEGER;

BEGIN
    MapPrepare(m, key);
    kb := m.keybuf.Adr(m.keybuf, 0);

    RETURN MapProbe(m, kb, slot) >= 0
END MapContains;

(* The address of the stored value, for reading or for writing in place, or 0
   when the map does not hold the key.  A value is an element of a list, so it
   never straddles a block and the address is the value. *)
PROCEDURE MapValueAdr (m: Map; key: ARRAY OF CHAR): INTEGER;
VAR
    slot, e, kb: INTEGER;
    adr: INTEGER;

BEGIN
    MapPrepare(m, key);
    kb := m.keybuf.Adr(m.keybuf, 0);
    e := MapProbe(m, kb, slot);
    adr := 0;
    IF e >= 0 THEN
        adr := m.vals.Get(m.vals, e)
    END;

    RETURN adr
END MapValueAdr;

(* Drop the key and its value, answering whether the map held it.  The entry
   goes on the free stack for the next Put to fill; the hole it leaves in the
   table is closed by MapBackshift. *)
PROCEDURE MapRemove (m: Map; key: ARRAY OF CHAR): BOOLEAN;
VAR
    slot, e, kb: INTEGER;
    ok: BOOLEAN;

BEGIN
    MapPrepare(m, key);
    kb := m.keybuf.Adr(m.keybuf, 0);
    e := MapProbe(m, kb, slot);
    ok := e >= 0;
    IF ok THEN
        MapPushFree(m, e);
        DEC(m.count);
        MapBackshift(m, slot)
    END;

    RETURN ok
END MapRemove;

(* Empty the map, keeping every block: refilling it allocates nothing until it
   grows past the table it had.  The table itself is zeroed in one fill of the
   bytes the slots live in - every slot is its element's first word. *)
PROCEDURE MapClear (m: Map);
VAR
    b: ByteArr.ByteArray;

BEGIN
    m.keys.Clear(m.keys);
    m.vals.Clear(m.vals);
    m.free.Clear(m.free);
    m.count := 0;
    b := m.index.bytes;
    b.Fill(b, 0, b.Length(b), 0)
END MapClear;

(* Give back the blocks past the entries in use and rebuild the table at the
   smallest size that holds them.  Entries a Remove freed keep their place in
   the key and value lists until Clear, so a map that has held many keys holds
   that storage until then: Clear followed by Pack is what gives it back. *)
PROCEDURE MapPack (m: Map);
BEGIN
    m.keys.Pack(m.keys);
    m.vals.Pack(m.vals);
    m.free.Pack(m.free);
    MapReindex(m, MapTightSlots(m.count))
END MapPack;

PROCEDURE MapCount (m: Map): INTEGER;
BEGIN
    RETURN m.count
END MapCount;

PROCEDURE MapCapacity (m: Map): INTEGER;
BEGIN
    RETURN m.slots DIV 2
END MapCapacity;

PROCEDURE MapKeySize (m: Map): INTEGER;
BEGIN
    RETURN m.keySize
END MapKeySize;

PROCEDURE MapValueSize (m: Map): INTEGER;
BEGIN
    RETURN m.valSize
END MapValueSize;

(* Give the map up: every block of every one of its lists and of the key buffer
   goes back to Heap, and the record itself goes back to the allocator, which
   is the DISPOSE that answers the NEW of CreateMap.
   The parameter is `Oberon.Object` for the reason Done gives. *)
PROCEDURE MapDone (self: Oberon.Object);
VAR m: Map;
BEGIN
    m := self(Map);
    m.keys.Done(m.keys);
    m.vals.Done(m.vals);
    m.free.Done(m.free);
    m.index.Done(m.index);
    m.keybuf.Done(m.keybuf);
    m.keySize := 0;
    m.valSize := 0;
    m.slots := 0;
    m.count := 0;
    m.keys := NIL;
    m.vals := NIL;
    m.free := NIL;
    m.index := NIL;
    m.keybuf := NIL;
    DISPOSE(m)
END MapDone;

(* An empty map of keys of at most keySize bytes and values of valueSize bytes
   each.  The key buffer is keySize zero bytes, one block of Heap that every
   key the map is asked about is prepared in; the table starts at MinSlots
   slots, and nothing is allocated for the entries until one is put.  This is
   where the methods are bound to the record. *)
PROCEDURE CreateMap* (keySize, valueSize: INTEGER): Map;
VAR
    m: Map;

BEGIN
    ASSERT(keySize > 0);
    ASSERT(valueSize > 0);          (* a list refuses a zero element size *)
    ASSERT(keySize <= ChunkBytes);
    ASSERT(valueSize <= ChunkBytes);
    NEW(m);
    m.keySize := keySize;
    m.valSize := valueSize;
    m.count := 0;
    m.slots := MinSlots;
    m.index := MapNewIndex(MinSlots);
    m.keys := CreateList(keySize);
    m.vals := CreateList(valueSize);
    m.free := CreateList(SYSTEM.SIZE(INTEGER));
    m.keybuf := ByteArr.Create(keySize);
    m.Put := MapPut;
    m.Get := MapGet;
    m.Contains := MapContains;
    m.ValueAdr := MapValueAdr;
    m.Remove := MapRemove;
    m.Clear := MapClear;
    m.Pack := MapPack;
    m.Count := MapCount;
    m.Capacity := MapCapacity;
    m.KeySize := MapKeySize;
    m.ValueSize := MapValueSize;
    m.Done := MapDone;

    RETURN m
END CreateMap;

PROCEDURE CreateMapCapacity* (keySize, valueSize, cap: INTEGER): Map;
VAR
    m: Map;

BEGIN
    ASSERT(cap >= 0);
    m := CreateMap(keySize, valueSize);
    IF cap > 0 THEN
        MapReindex(m, MapTightSlots(cap))
    END;

    RETURN m
END CreateMapCapacity;

END Arrays.
