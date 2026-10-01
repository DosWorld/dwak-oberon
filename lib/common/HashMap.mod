(* Public domain. Copyright (c) 2026, DosWorld.

   Owning, unordered string -> INTEGER map. Call Init before first use;
   never copy an initialized HashMap by assignment. All fields are private.
   Keys are copied, end at the first zero byte (or LEN), and compare by bytes.
   Values may be arbitrary INTEGERs, including zero and negative numbers.
   Get leaves its output unchanged on failure. RemoveValue removes ALL matches.
   Clear/Destroy release storage; the empty map can immediately be reused.
   Reserve reserves buckets, not entry/key storage. Pack compacts both arenas
   and shrinks buckets. No pointers into the map are exported.

   Entries: 64 per allocation. Strings: separate 4096-byte pages, slots with
   16/64/256/1024 payload bytes. Long keys use multiple slots. Removed slots
   are reused immediately. Empty pages are returned to the heap by Pack.
   Buckets: radix-32 directory of 128-bucket pages; lookup never walks a
   linked list of pages. Growth doubles bucket count at load factor 3/4.
   Cached positive hashes avoid dependence on signed overflow/word size.
   Pack works in place except for the replacement bucket directory.

   Requires SYSTEM and a target providing DISPOSE (the desktop/DOS targets).
   Freed pages return to the target heap; macOS uses libSystem malloc/free.
   Allocation failure follows the runtime's NEW policy. Not thread safe.
*)
MODULE HashMap;

IMPORT SYSTEM;

CONST
    Entries = 1024; PageBytes = 4096; BucketCount = 128; Fanout = 32;
    Classes = 4;
    $IF (BITS_16)
        MaxBuckets = 16384;
    $ELSE
        MaxBuckets = 1073741824;
    $END

TYPE
    Entry = POINTER TO EntryBody;
    Slot = POINTER TO SlotBody;
    EntryBody = RECORD
        next: Entry;
        key: Slot;
        hash, length, value: INTEGER (* length = -1 means free *)
    END;
    SlotBody = RECORD
        next, prev: Slot; (* key chain, or free chain when owner = NIL *)
        owner: Entry;
        size: INTEGER   (* actual payload bytes used *)
    END;
    EntryPage = POINTER TO RECORD
        next, prev: EntryPage;
        data: ARRAY Entries OF EntryBody
    END;
    StringPage = POINTER TO RECORD
        next, prev: StringPage;
        data: ARRAY PageBytes OF BYTE
    END;
    Buckets = POINTER TO RECORD
        data: ARRAY BucketCount OF Entry
    END;
    Directory = POINTER TO RECORD
        child: ARRAY Fanout OF Directory;
        page: Buckets
    END;
    HashMap* = RECORD
        root: Directory;
        bucketSize, span, count: INTEGER;
        first, last: EntryPage;
        free: Entry;
        strings, tails: ARRAY Classes OF StringPage;
        spare: ARRAY Classes OF Slot
    END;

(* Only for fresh/uninitialized records; use Clear to reset a live map. *)
PROCEDURE Init*(VAR map: HashMap);
VAR i: INTEGER;
BEGIN
    map.root := NIL; map.bucketSize := 0; map.span := 0; map.count := 0;
    map.first := NIL; map.last := NIL; map.free := NIL;
    FOR i := 0 TO Classes - 1 DO
        map.strings[i] := NIL; map.tails[i] := NIL; map.spare[i] := NIL
    END
END Init;

PROCEDURE Capacity(c: INTEGER): INTEGER;
VAR n: INTEGER;
BEGIN
    n := 16;
    WHILE c > 0 DO n := n * 4; DEC(c) END
    RETURN n
END Capacity;

PROCEDURE EntryAt(p: EntryPage; i: INTEGER): Entry;
VAR address: INTEGER;
BEGIN
    address := SYSTEM.ADR(p.data[i])
    RETURN SYSTEM.VAL(Entry, address)
END EntryAt;

PROCEDURE SlotAt(p: StringPage; i, c: INTEGER): Slot;
VAR address: INTEGER;
BEGIN
    address := SYSTEM.ADR(p.data) + i * (SYSTEM.SIZE(SlotBody) + Capacity(c))
    RETURN SYSTEM.VAL(Slot, address)
END SlotAt;

PROCEDURE Slots(c: INTEGER): INTEGER;
BEGIN
    RETURN PageBytes DIV (SYSTEM.SIZE(SlotBody) + Capacity(c))
END Slots;

PROCEDURE Bytes(s: Slot): INTEGER;
BEGIN
    RETURN SYSTEM.VAL(INTEGER, s) + SYSTEM.SIZE(SlotBody)
END Bytes;

PROCEDURE NewDirectory(): Directory;
VAR d: Directory; i: INTEGER;
BEGIN
    NEW(d); d.page := NIL;
    FOR i := 0 TO Fanout - 1 DO d.child[i] := NIL END
    RETURN d
END NewDirectory;

(* span is the number of buckets covered by one root child, zero for leaf. *)
PROCEDURE Page(root: Directory; span, index: INTEGER): Buckets;
VAR d: Directory; i: INTEGER;
BEGIN
    d := root;
    WHILE span > 0 DO
        i := index DIV span; index := index MOD span;
        IF d.child[i] = NIL THEN d.child[i] := NewDirectory() END;
        d := d.child[i];
        IF span = BucketCount THEN span := 0 ELSE span := span DIV Fanout END
    END;
    IF d.page = NIL THEN
        NEW(d.page);
        FOR i := 0 TO BucketCount - 1 DO d.page.data[i] := NIL END
    END
    RETURN d.page
END Page;

PROCEDURE FreeDirectory(d: Directory);
VAR i: INTEGER;
BEGIN
    IF d # NIL THEN
        FOR i := 0 TO Fanout - 1 DO FreeDirectory(d.child[i]) END;
        IF d.page # NIL THEN DISPOSE(d.page) END;
        DISPOSE(d)
    END
END FreeDirectory;

PROCEDURE Rehash(VAR map: HashMap; size: INTEGER);
VAR root: Directory; span, covered, i, b: INTEGER;
    p: EntryPage; e: Entry; page: Buckets;
BEGIN
    root := NewDirectory(); span := 0; covered := BucketCount;
    WHILE covered < size DO
        span := covered;
        (* The root can cover more than MaxBuckets without multiplying it. *)
        IF covered > MaxBuckets DIV Fanout THEN covered := MaxBuckets
        ELSE covered := covered * Fanout END
    END;
    i := 0;
    WHILE i < size DO page := Page(root, span, i); INC(i, BucketCount) END;
    p := map.first;
    WHILE p # NIL DO
        FOR i := 0 TO Entries - 1 DO
            e := EntryAt(p, i);
            IF e.length >= 0 THEN
                b := e.hash MOD size; page := Page(root, span, b);
                e.next := page.data[b MOD BucketCount]; page.data[b MOD BucketCount] := e
            END
        END;
        p := p.next
    END;
    FreeDirectory(map.root);
    map.root := root; map.span := span; map.bucketSize := size
END Rehash;

PROCEDURE Reserve*(VAR map: HashMap; capacity: INTEGER);
VAR size: INTEGER;
BEGIN
    ASSERT((capacity >= 0) & (capacity <= MaxBuckets DIV 4 * 3));
    IF capacity > 0 THEN
        size := BucketCount;
        WHILE capacity > size DIV 4 * 3 DO size := size * 2 END;
        IF size > map.bucketSize THEN Rehash(map, size) END
    END
END Reserve;

PROCEDURE Hash(key: ARRAY OF CHAR; VAR length: INTEGER): INTEGER;
VAR h: INTEGER;
BEGIN
    h := 0; length := 0;
    WHILE (length < LEN(key)) & (key[length] # 0X) DO
        (* Bounded arithmetic, including on 16-bit hosts. *)
        $IF (BITS_16)
            h := (h MOD 997) * 31 + ORD(key[length]);
        $ELSE
            h := (h MOD 6700417) * 31 + ORD(key[length]);
        $END;
        INC(length)
    END
    RETURN h
END Hash;

PROCEDURE Equal(e: Entry; key: ARRAY OF CHAR; length: INTEGER): BOOLEAN;
VAR s: Slot; i, pos: INTEGER; ch: CHAR; same: BOOLEAN;
BEGIN
    same := e.length = length; s := e.key; pos := 0;
    WHILE same & (s # NIL) DO
        i := 0;
        WHILE same & (i < s.size) DO
            SYSTEM.GET(Bytes(s) + i, ch); same := ch = key[pos];
            INC(i); INC(pos)
        END;
        s := s.next
    END
    RETURN same
END Equal;

PROCEDURE Find(VAR map: HashMap; key: ARRAY OF CHAR; hash, length: INTEGER): Entry;
VAR e: Entry; p: Buckets; found: BOOLEAN; b: INTEGER;
BEGIN
    e := NIL; found := FALSE;
    IF map.bucketSize > 0 THEN
        b := hash MOD map.bucketSize; p := Page(map.root, map.span, b);
        e := p.data[b MOD BucketCount];
        WHILE (e # NIL) & ~found DO
            IF e.hash = hash THEN found := Equal(e, key, length) END;
            IF ~found THEN e := e.next END
        END
    END
    RETURN e
END Find;

PROCEDURE NewEntry(VAR map: HashMap): Entry;
VAR p: EntryPage; e: Entry; i: INTEGER;
BEGIN
    IF map.free = NIL THEN
        NEW(p); p.next := NIL; p.prev := map.last;
        IF map.last = NIL THEN map.first := p ELSE map.last.next := p END;
        map.last := p;
        FOR i := Entries - 1 TO 0 BY -1 DO
            e := EntryAt(p, i); e.length := -1; e.key := NIL;
            e.next := map.free; map.free := e
        END
    END;
    e := map.free; map.free := e.next
    RETURN e
END NewEntry;

PROCEDURE NewSlot(VAR map: HashMap; c: INTEGER): Slot;
VAR p: StringPage; s: Slot; i: INTEGER;
BEGIN
    IF map.spare[c] = NIL THEN
        NEW(p); p.next := NIL; p.prev := map.tails[c];
        IF map.tails[c] = NIL THEN map.strings[c] := p ELSE map.tails[c].next := p END;
        map.tails[c] := p;
        FOR i := Slots(c) - 1 TO 0 BY -1 DO
            s := SlotAt(p, i, c); s.owner := NIL; s.prev := NIL; s.size := 0;
            s.next := map.spare[c]; map.spare[c] := s
        END
    END;
    s := map.spare[c]; map.spare[c] := s.next;
    s.next := NIL; s.prev := NIL
    RETURN s
END NewSlot;

PROCEDURE SaveKey(VAR map: HashMap; e: Entry; key: ARRAY OF CHAR; length: INTEGER);
VAR pos, n, c, i: INTEGER; s, prev: Slot;
BEGIN
    pos := 0; prev := NIL; e.key := NIL;
    WHILE pos < length DO
        n := MIN(length - pos, Capacity(Classes - 1)); c := 0;
        WHILE Capacity(c) < n DO INC(c) END;
        s := NewSlot(map, c); s.owner := e; s.size := n; s.prev := prev;
        IF prev = NIL THEN e.key := s ELSE prev.next := s END;
        FOR i := 0 TO n - 1 DO SYSTEM.PUT(Bytes(s) + i, key[pos + i]) END;
        INC(pos, n); prev := s
    END
END SaveKey;

PROCEDURE Put*(VAR map: HashMap; key: ARRAY OF CHAR; value: INTEGER);
VAR h, length, b: INTEGER; e: Entry; p: Buckets;
BEGIN
    h := Hash(key, length); e := Find(map, key, h, length);
    IF e = NIL THEN
        Reserve(map, map.count + 1); e := NewEntry(map);
        e.hash := h; e.length := length; SaveKey(map, e, key, length);
        b := h MOD map.bucketSize; p := Page(map.root, map.span, b);
        e.next := p.data[b MOD BucketCount]; p.data[b MOD BucketCount] := e;
        INC(map.count)
    END;
    e.value := value
END Put;

PROCEDURE Get*(VAR map: HashMap; key: ARRAY OF CHAR; VAR value: INTEGER): BOOLEAN;
VAR h, length: INTEGER; e: Entry;
BEGIN
    h := Hash(key, length); e := Find(map, key, h, length);
    IF e # NIL THEN value := e.value END
    RETURN e # NIL
END Get;

PROCEDURE Contains*(VAR map: HashMap; key: ARRAY OF CHAR): BOOLEAN;
VAR h, length: INTEGER;
BEGIN
    h := Hash(key, length)
    RETURN Find(map, key, h, length) # NIL
END Contains;

PROCEDURE Release(VAR map: HashMap; e: Entry);
VAR s, next: Slot; c: INTEGER;
BEGIN
    s := e.key;
    WHILE s # NIL DO
        next := s.next; c := 0;
        WHILE Capacity(c) < s.size DO INC(c) END;
        s.owner := NIL; s.prev := NIL; s.next := map.spare[c]; map.spare[c] := s;
        s := next
    END;
    e.key := NIL; e.length := -1; e.next := map.free; map.free := e;
    DEC(map.count)
END Release;

PROCEDURE Remove*(VAR map: HashMap; key: ARRAY OF CHAR): BOOLEAN;
VAR h, length, b: INTEGER; e, prev: Entry; p: Buckets; found: BOOLEAN;
BEGIN
    h := Hash(key, length); found := FALSE;
    IF map.bucketSize > 0 THEN
        b := h MOD map.bucketSize; p := Page(map.root, map.span, b);
        b := b MOD BucketCount; e := p.data[b]; prev := NIL;
        WHILE (e # NIL) & ~found DO
            IF e.hash = h THEN found := Equal(e, key, length) END;
            IF ~found THEN prev := e; e := e.next END
        END;
        IF found THEN
            IF prev = NIL THEN p.data[b] := e.next ELSE prev.next := e.next END;
            Release(map, e)
        END
    END
    RETURN found
END Remove;

(* No reverse index: O(bucket capacity + entries + removed key bytes). *)
PROCEDURE RemoveValue*(VAR map: HashMap; value: INTEGER): INTEGER;
VAR b, removed: INTEGER; p: Buckets; e, prev, next: Entry;
BEGIN
    removed := 0; b := 0;
    WHILE b < map.bucketSize DO
        p := Page(map.root, map.span, b); e := p.data[b MOD BucketCount]; prev := NIL;
        WHILE e # NIL DO
            next := e.next;
            IF e.value = value THEN
                IF prev = NIL THEN p.data[b MOD BucketCount] := next ELSE prev.next := next END;
                Release(map, e); INC(removed)
            ELSE prev := e END;
            e := next
        END;
        INC(b)
    END
    RETURN removed
END RemoveValue;

PROCEDURE Count*(VAR map: HashMap): INTEGER;
BEGIN RETURN map.count END Count;

PROCEDURE Clear*(VAR map: HashMap);
VAR p, pn: EntryPage; s, sn: StringPage; c: INTEGER;
BEGIN
    FreeDirectory(map.root); p := map.first;
    WHILE p # NIL DO pn := p.next; DISPOSE(p); p := pn END;
    FOR c := 0 TO Classes - 1 DO
        s := map.strings[c];
        WHILE s # NIL DO sn := s.next; DISPOSE(s); s := sn END
    END;
    Init(map)
END Clear;

PROCEDURE Destroy*(VAR map: HashMap);
BEGIN Clear(map) END Destroy;

(* Compact entries by filling holes with tail entries. Bucket links are
   deliberately rebuilt later; key-slot owner links are repaired immediately. *)
PROCEDURE PackEntries(VAR map: HashMap);
VAR p, tail, next: EntryPage; i, j, left: INTEGER; dst, src: Entry; s: Slot;
BEGIN
    tail := map.last; j := Entries - 1; p := map.first; left := map.count;
    WHILE left > 0 DO
        i := 0;
        WHILE (i < Entries) & (left > 0) DO
            dst := EntryAt(p, i);
            IF dst.length < 0 THEN
                src := EntryAt(tail, j);
                WHILE src.length < 0 DO
                    DEC(j);
                    IF j < 0 THEN tail := tail.prev; j := Entries - 1 END;
                    src := EntryAt(tail, j)
                END;
                dst^ := src^; src.length := -1; src.key := NIL;
                s := dst.key;
                WHILE s # NIL DO s.owner := dst; s := s.next END
            END;
            INC(i); DEC(left)
        END;
        IF left > 0 THEN p := p.next END
    END;
    (* count > 0: p is now the last retained page. *)
    tail := p.next; p.next := NIL; map.last := p;
    WHILE tail # NIL DO next := tail.next; DISPOSE(tail); tail := next END;
    map.free := NIL;
    FOR j := Entries - 1 TO i BY -1 DO
        dst := EntryAt(p, j); dst.length := -1; dst.key := NIL;
        dst.next := map.free; map.free := dst
    END
END PackEntries;

PROCEDURE PackStrings(VAR map: HashMap; c: INTEGER);
VAR p, tail, next, keep: StringPage; i, j, live, left, used: INTEGER;
    s, dst: Slot;
BEGIN
    live := 0; p := map.strings[c];
    WHILE p # NIL DO
        FOR i := 0 TO Slots(c) - 1 DO
            s := SlotAt(p, i, c); IF s.owner # NIL THEN INC(live) END
        END;
        p := p.next
    END;
    left := live; p := map.strings[c]; tail := map.tails[c]; j := Slots(c) - 1;
    keep := NIL; used := 0;
    WHILE left > 0 DO
        i := 0;
        WHILE (i < Slots(c)) & (left > 0) DO
            dst := SlotAt(p, i, c);
            IF dst.owner = NIL THEN
                s := SlotAt(tail, j, c);
                WHILE s.owner = NIL DO
                    DEC(j);
                    IF j < 0 THEN tail := tail.prev; j := Slots(c) - 1 END;
                    s := SlotAt(tail, j, c)
                END;
                dst^ := s^; SYSTEM.MOVE(Bytes(s), Bytes(dst), s.size);
                IF dst.prev = NIL THEN dst.owner.key := dst ELSE dst.prev.next := dst END;
                IF dst.next # NIL THEN dst.next.prev := dst END;
                s.owner := NIL
            END;
            INC(i); DEC(left)
        END;
        keep := p; used := i; p := p.next
    END;
    WHILE p # NIL DO next := p.next; DISPOSE(p); p := next END;
    map.tails[c] := keep; map.spare[c] := NIL;
    IF keep = NIL THEN map.strings[c] := NIL
    ELSE
        keep.next := NIL;
        FOR i := Slots(c) - 1 TO used BY -1 DO
            s := SlotAt(keep, i, c); s.owner := NIL; s.prev := NIL;
            s.next := map.spare[c]; map.spare[c] := s
        END
    END
END PackStrings;

(* Explicit compaction; values and application-owned records are untouched. *)
PROCEDURE Pack*(VAR map: HashMap);
VAR c, size: INTEGER;
BEGIN
    IF map.count = 0 THEN Clear(map)
    ELSE
        PackEntries(map);
        FOR c := 0 TO Classes - 1 DO PackStrings(map, c) END;
        size := BucketCount;
        WHILE map.count > size DIV 4 * 3 DO size := size * 2 END;
        Rehash(map, size)
    END
END Pack;

END HashMap.
