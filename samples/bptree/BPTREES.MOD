(*
   Public domain
   Copyright (c) 2026-, DosWorld

   Implementation B+ Trees for DWAK Oberon-07.
   Fixed pages, caller-ordered validated UTF-8 keys, native INTEGER values.
   Call Init before Create/Open. BpTree owns its storage: never copy it.
   One owner per file; no concurrent access, transactions or crash recovery. *)
MODULE BpTrees;

IMPORT F := Files, SYSTEM;

CONST
    MaxKey* = 240; PageSize* = 4096;
    OK* = 0; NotFound* = 1; BadKey* = 2; IOError* = 3;
    Corrupt* = 4; Closed* = 5; Exists* = 6; Limit* = 7;
    End* = 8; Stale* = 9; BufferSmall* = 10; Busy* = 11; BadPath* = 12;
    ConfigMismatch* = 13; BadOptions* = 14; Duplicate* = 15;
    MaxSerial = 2147483647;
    MaxKeys = 15; MinKeys = 7; Height = 32; CacheSize = 8;
    MaxPages = 524287; (* all byte offsets below signed 2 GiB *)
    Leaf = 1; Branch = 2; Free = 3; Magic = 31425044H;
TYPE
    CompareProc* = PROCEDURE (a, b: ARRAY OF CHAR): INTEGER;
    Key = ARRAY MaxKey + 1 OF CHAR;
    Node = POINTER TO RECORD
        kind, n, next: INTEGER;
        key: ARRAY MaxKeys + 1 OF Key;
        serial: ARRAY MaxKeys + 1 OF INTEGER;
        value: ARRAY MaxKeys + 1 OF INTEGER;
        child: ARRAY MaxKeys + 2 OF INTEGER
    END;
    Workspace = POINTER TO RECORD
        raw: ARRAY PageSize OF BYTE;
        path, slot: ARRAY Height OF INTEGER;
        a, b, parent: Node;
        cached: ARRAY CacheSize OF Node;
        cacheID: ARRAY CacheSize OF INTEGER;
        hand: INTEGER
    END;
    BpTree* = RECORD
        file: F.File;
        root, pages, free, count, error, generation: INTEGER;
        opened, failed, unique: BOOLEAN;
        compare: CompareProc;
        orderID, nextSerial: INTEGER;
        w: Workspace
    END;
    Cursor* = RECORD
        owner: Workspace;
        generation, page, index, visited: INTEGER
    END;

PROCEDURE Init*(VAR t: BpTree);
BEGIN
    t.root := 0; t.pages := 0; t.free := 0; t.count := 0;
    t.error := Closed; t.generation := 0; t.opened := FALSE;
    t.failed := FALSE; t.w := NIL; t.compare := NIL;
    t.unique := TRUE; t.orderID := 0; t.nextSerial := 1
END Init;

PROCEDURE Error*(VAR t: BpTree): INTEGER;
BEGIN
    RETURN t.error
END Error;

PROCEDURE Count*(VAR t: BpTree): INTEGER;
BEGIN
    RETURN t.count
END Count;

PROCEDURE Fail(VAR t: BpTree; error: INTEGER);
BEGIN
    t.error := error; t.failed := TRUE
END Fail;

PROCEDURE Ready(VAR t: BpTree): BOOLEAN;
BEGIN
    IF ~t.opened THEN t.error := Closed
    ELSIF ~t.failed THEN t.error := OK END;
    RETURN t.opened & ~t.failed
END Ready;

PROCEDURE Allocate(VAR t: BpTree);
VAR i: INTEGER;
BEGIN
    NEW(t.w); NEW(t.w.a); NEW(t.w.b); NEW(t.w.parent);
    t.w.hand := 0;
    FOR i := 0 TO CacheSize - 1 DO NEW(t.w.cached[i]); t.w.cacheID[i] := -1 END
END Allocate;

PROCEDURE Release(VAR t: BpTree);
VAR i: INTEGER;
BEGIN
    IF t.w # NIL THEN
        FOR i := 0 TO CacheSize - 1 DO DISPOSE(t.w.cached[i]) END;
        DISPOSE(t.w.a); DISPOSE(t.w.b); DISPOSE(t.w.parent); DISPOSE(t.w)
    END
END Release;

PROCEDURE Length(s: ARRAY OF CHAR): INTEGER;
VAR n: INTEGER;
BEGIN
    n := 0;
    WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END;
    RETURN n
END Length;

PROCEDURE ValidPath(name: ARRAY OF CHAR): BOOLEAN;
VAR n: INTEGER;
BEGIN
    n := Length(name);
    RETURN (n > 0) & (n < LEN(name)) & (n < 256)
END ValidPath;

PROCEDURE ValidKey(s: ARRAY OF CHAR): BOOLEAN;
VAR i, n, b, c, need, low, high, j: INTEGER; good: BOOLEAN;
BEGIN
    n := Length(s); good := n <= MaxKey; i := 0;
    WHILE good & (i < n) DO
        b := ORD(s[i]); need := 0; low := 128; high := 191;
        IF b < 128 THEN need := 1
        ELSIF (b >= 194) & (b <= 223) THEN need := 2
        ELSIF (b >= 224) & (b <= 239) THEN
            need := 3;
            IF b = 224 THEN low := 160 ELSIF b = 237 THEN high := 159 END
        ELSIF (b >= 240) & (b <= 244) THEN
            need := 4;
            IF b = 240 THEN low := 144 ELSIF b = 244 THEN high := 143 END
        END;
        good := (need > 0) & (i + need <= n);
        IF good & (need > 1) THEN
            c := ORD(s[i + 1]); good := (c >= low) & (c <= high);
            j := 2;
            WHILE good & (j < need) DO
                c := ORD(s[i + j]); good := (c >= 128) & (c <= 191); INC(j)
            END
        END;
        INC(i, need)
    END;
    RETURN good
END ValidKey;

PROCEDURE CopyKey(s: ARRAY OF CHAR; VAR d: Key);
VAR i, n: INTEGER;
BEGIN
    n := Length(s);
    FOR i := 0 TO n - 1 DO d[i] := s[i] END;
    d[n] := 0X
END CopyKey;

(* Always pass terminated, equally sized arrays to an external comparator.
   The callback compares text through the first NUL, never the unused tail. *)
PROCEDURE CompareKeys(VAR t: BpTree; a, b: ARRAY OF CHAR): INTEGER;
VAR x, y: Key;
BEGIN
    CopyKey(a, x); CopyKey(b, y);
    RETURN t.compare(x, y)
END CompareKeys;

PROCEDURE CompareEntry(VAR t: BpTree; a: ARRAY OF CHAR; serialA: INTEGER;
                       b: ARRAY OF CHAR; serialB: INTEGER): INTEGER;
VAR result: INTEGER;
BEGIN
    result := CompareKeys(t, a, b);
    IF result = 0 THEN
        IF serialA < serialB THEN result := -1
        ELSIF serialA > serialB THEN result := 1 END
    END;
    RETURN result
END CompareEntry;

PROCEDURE Zero(VAR t: BpTree);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO PageSize - 1 DO t.w.raw[i] := 0 END
END Zero;

PROCEDURE PutNumber(VAR t: BpTree; offset, size, value: INTEGER);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO size - 1 DO
        t.w.raw[offset + i] := value MOD 256; value := ASR(value, 8)
    END
END PutNumber;

PROCEDURE Number(VAR t: BpTree; offset, size: INTEGER; signed: BOOLEAN): INTEGER;
VAR i, n: INTEGER;
BEGIN
    n := t.w.raw[offset + size - 1];
    IF signed & (n >= 128) THEN DEC(n, 256) END;
    FOR i := size - 2 TO 0 BY -1 DO n := n * 256 + t.w.raw[offset + i] END;
    RETURN n
END Number;

PROCEDURE Checksum(VAR t: BpTree): INTEGER;
VAR i, a, b: INTEGER;
BEGIN
    a := 1; b := 0;
    FOR i := 0 TO PageSize - 5 DO
        a := a + t.w.raw[i];
        IF a >= 251 THEN DEC(a, 251) END;
        IF a >= 251 THEN DEC(a, 251) END;
        INC(b, a); IF b >= 251 THEN DEC(b, 251) END
    END;
    RETURN a + b * 256
END Checksum;

PROCEDURE ReadRaw(VAR t: BpTree; page: INTEGER): BOOLEAN;
VAR n: INTEGER;
BEGIN
    IF (page < 0) OR (page >= t.pages) THEN Fail(t, Corrupt)
    ELSE
        F.Seek(t.file, page * PageSize);
        IF (F.Position(t.file) # page * PageSize) OR ~F.Ok(t.file) THEN Fail(t, IOError)
        ELSE
            n := F.BlockRead(t.file, t.w.raw, PageSize);
            IF n # PageSize THEN Fail(t, IOError)
            ELSIF Number(t, PageSize - 4, 4, FALSE) # Checksum(t) THEN Fail(t, Corrupt) END
        END
    END;
    RETURN ~t.failed
END ReadRaw;

PROCEDURE WriteRaw(VAR t: BpTree; page: INTEGER);
VAR n: INTEGER;
BEGIN
    IF ~t.failed THEN
        PutNumber(t, PageSize - 4, 4, Checksum(t));
        F.Seek(t.file, page * PageSize);
        IF (F.Position(t.file) # page * PageSize) OR ~F.Ok(t.file) THEN Fail(t, IOError)
        ELSE
            n := F.BlockWrite(t.file, t.w.raw, PageSize);
            IF (n # PageSize) OR ~F.Ok(t.file) THEN Fail(t, IOError) END
        END
    END
END WriteRaw;

PROCEDURE PageRef(VAR t: BpTree; id: INTEGER): BOOLEAN;
BEGIN RETURN (id > 0) & (id < t.pages) END PageRef;

PROCEDURE Invalidate(VAR t: BpTree; id: INTEGER);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO CacheSize - 1 DO
        IF t.w.cacheID[i] = id THEN t.w.cacheID[i] := -1 END
    END
END Invalidate;

PROCEDURE Remember(VAR t: BpTree; id: INTEGER; node: Node);
BEGIN
    Invalidate(t, id);
    t.w.cached[t.w.hand]^ := node^; t.w.cacheID[t.w.hand] := id;
    t.w.hand := (t.w.hand + 1) MOD CacheSize
END Remember;

PROCEDURE ReadNode(VAR t: BpTree; id: INTEGER; node: Node): BOOLEAN;
VAR i, j, base, n, hit: INTEGER;
BEGIN
    hit := -1;
    FOR i := 0 TO CacheSize - 1 DO IF t.w.cacheID[i] = id THEN hit := i END END;
    IF id = 0 THEN Fail(t, Corrupt)
    ELSIF hit >= 0 THEN node^ := t.w.cached[hit]^
    ELSIF ReadRaw(t, id) THEN
        node.kind := Number(t, 0, 4, FALSE); node.n := Number(t, 4, 4, FALSE);
        node.next := Number(t, 8, 4, FALSE); node.child[0] := Number(t, 12, 4, FALSE);
        IF ((node.kind # Leaf) & (node.kind # Branch)) OR
           (node.n < 0) OR (node.n > MaxKeys) THEN Fail(t, Corrupt)
        ELSIF (id # t.root) & (node.n < MinKeys) THEN Fail(t, Corrupt)
        ELSIF (node.kind = Branch) & ((node.n = 0) OR (node.next # 0)) THEN Fail(t, Corrupt)
        ELSIF (node.kind = Leaf) & (node.child[0] # 0) THEN Fail(t, Corrupt)
        ELSIF (node.next # 0) & (~PageRef(t, node.next) OR (node.next = id)) THEN Fail(t, Corrupt)
        ELSIF (id = t.root) & (node.kind = Leaf) & (node.next # 0) THEN Fail(t, Corrupt)
        ELSIF (node.kind = Branch) & ~PageRef(t, node.child[0]) THEN Fail(t, Corrupt)
        ELSE
            i := 0;
            WHILE (i < node.n) & ~t.failed DO
                base := 32 + i * 256; n := Number(t, base, 2, FALSE);
                IF n > MaxKey THEN Fail(t, Corrupt)
                ELSE
                    FOR j := 0 TO n - 1 DO node.key[i][j] := CHR(t.w.raw[base + 2 + j]) END;
                    node.key[i][n] := 0X;
                    IF (Length(node.key[i]) # n) OR ~ValidKey(node.key[i]) THEN Fail(t, Corrupt) END;
                    node.serial[i] := Number(t, base + 244, 4, FALSE);
                    IF (t.unique & (node.serial[i] # 0)) OR
                       (~t.unique & ((node.serial[i] <= 0) OR (node.serial[i] >= t.nextSerial))) THEN Fail(t, Corrupt) END;
                    IF (i > 0) & (CompareEntry(t, node.key[i - 1], node.serial[i - 1],
                                              node.key[i], node.serial[i]) >= 0) THEN Fail(t, Corrupt) END;
                    IF node.kind = Leaf THEN node.value[i] := Number(t, base + 248, SYSTEM.SIZE(INTEGER), TRUE)
                    ELSE
                        node.child[i + 1] := Number(t, base + 248, 4, FALSE);
                        IF ~PageRef(t, node.child[i + 1]) THEN Fail(t, Corrupt) END
                    END
                END;
                INC(i)
            END
        END
    END;
    IF ~t.failed & (hit < 0) THEN Remember(t, id, node) END;
    RETURN ~t.failed
END ReadNode;

PROCEDURE WriteNode(VAR t: BpTree; id: INTEGER; node: Node);
VAR i, j, base, n: INTEGER;
BEGIN
    Zero(t); PutNumber(t, 0, 4, node.kind); PutNumber(t, 4, 4, node.n);
    PutNumber(t, 8, 4, node.next);
    IF node.kind = Branch THEN PutNumber(t, 12, 4, node.child[0]) END;
    FOR i := 0 TO node.n - 1 DO
        base := 32 + i * 256; n := Length(node.key[i]); PutNumber(t, base, 2, n);
        FOR j := 0 TO n - 1 DO t.w.raw[base + 2 + j] := ORD(node.key[i][j]) END;
        PutNumber(t, base + 244, 4, node.serial[i]);
        IF node.kind = Leaf THEN PutNumber(t, base + 248, SYSTEM.SIZE(INTEGER), node.value[i])
        ELSE PutNumber(t, base + 248, 4, node.child[i + 1]) END
    END;
    WriteRaw(t, id);
    IF ~t.failed THEN Remember(t, id, node) END
END WriteNode;

PROCEDURE Header(VAR t: BpTree; clean: BOOLEAN);
BEGIN
    Zero(t); PutNumber(t, 0, 4, Magic); PutNumber(t, 4, 4, 2);
    PutNumber(t, 8, 4, SYSTEM.SIZE(INTEGER)); PutNumber(t, 12, 4, t.root);
    PutNumber(t, 16, 4, t.pages); PutNumber(t, 20, 4, t.free);
    PutNumber(t, 24, 4, t.count); PutNumber(t, 28, 4, ORD(clean));
    PutNumber(t, 32, 4, ORD(t.unique)); PutNumber(t, 36, 4, t.orderID);
    PutNumber(t, 40, 4, t.nextSerial);
    WriteRaw(t, 0)
END Header;

PROCEDURE NewPage(VAR t: BpTree): INTEGER;
VAR id: INTEGER;
BEGIN
    id := t.free;
    IF id # 0 THEN
        IF ReadRaw(t, id) THEN
            IF Number(t, 0, 4, FALSE) # Free THEN Fail(t, Corrupt)
            ELSE
                t.free := Number(t, 8, 4, FALSE);
                IF (t.free # 0) & (~PageRef(t, t.free) OR (t.free = id)) THEN Fail(t, Corrupt) END
            END
        END
    ELSIF t.pages >= MaxPages THEN Fail(t, Limit)
    ELSE id := t.pages; INC(t.pages) END;
    RETURN id
END NewPage;

PROCEDURE FreePage(VAR t: BpTree; id: INTEGER);
BEGIN
    Invalidate(t, id); Zero(t); PutNumber(t, 0, 4, Free); PutNumber(t, 8, 4, t.free);
    WriteRaw(t, id); t.free := id
END FreePage;

PROCEDURE Close*(VAR t: BpTree): BOOLEAN;
VAR good: BOOLEAN;
BEGIN
    IF t.opened THEN
        IF ~t.failed THEN Header(t, TRUE) END;
        F.Close(t.file);
        IF ~F.Ok(t.file) THEN Fail(t, IOError) END;
        t.opened := FALSE; Release(t)
    END;
    good := ~t.failed;
    IF good THEN t.error := OK END;
    RETURN good
END Close;

PROCEDURE Create*(VAR t: BpTree; name: ARRAY OF CHAR; unique: BOOLEAN;
                  compare: CompareProc; orderID: INTEGER): BOOLEAN;
BEGIN
    IF t.opened THEN t.error := Busy
    ELSIF (compare = NIL) OR (orderID <= 0) OR (orderID > MaxSerial) THEN t.error := BadOptions
    ELSIF ~ValidPath(name) THEN t.error := BadPath
    ELSIF F.FileExists(name) THEN t.error := Exists
    ELSE
        t.failed := FALSE; t.error := OK;
        IF ~F.ReWrite(t.file, name) THEN t.error := IOError
        ELSE
            F.Close(t.file);
            IF ~F.Ok(t.file) THEN t.error := IOError
            ELSIF ~F.Reset(t.file, name) THEN t.error := IOError
            ELSE
                Allocate(t); t.opened := TRUE; INC(t.generation);
                t.root := 1; t.pages := 2; t.free := 0; t.count := 0;
                t.unique := unique; t.compare := compare; t.orderID := orderID; t.nextSerial := 1;
                Header(t, FALSE);
                t.w.a.kind := Leaf; t.w.a.n := 0; t.w.a.next := 0;
                WriteNode(t, 1, t.w.a);
                IF t.failed THEN F.Close(t.file); t.opened := FALSE; Release(t) END
            END
        END
    END;
    RETURN t.error = OK
END Create;

PROCEDURE Open*(VAR t: BpTree; name: ARRAY OF CHAR; unique: BOOLEAN;
                compare: CompareProc; orderID: INTEGER): BOOLEAN;
VAR size, pages: INTEGER;
BEGIN
    IF t.opened THEN t.error := Busy
    ELSIF (compare = NIL) OR (orderID <= 0) OR (orderID > MaxSerial) THEN t.error := BadOptions
    ELSIF ~ValidPath(name) THEN t.error := BadPath
    ELSE
        t.failed := FALSE; t.error := OK; t.count := 0;
        t.unique := unique; t.compare := compare; t.orderID := orderID;
        IF ~F.Reset(t.file, name) THEN t.error := IOError
        ELSE
            Allocate(t); size := F.Size(t.file);
            t.pages := size DIV PageSize; pages := t.pages;
            IF (size < 2 * PageSize) OR (size MOD PageSize # 0) OR (pages > MaxPages) THEN Fail(t, Corrupt)
            ELSIF ReadRaw(t, 0) THEN
                IF (Number(t, 0, 4, FALSE) # Magic) OR (Number(t, 4, 4, FALSE) # 2) OR
                   (Number(t, 8, 4, FALSE) # SYSTEM.SIZE(INTEGER)) OR
                   (Number(t, 28, 4, FALSE) # 1) OR
                   (Number(t, 32, 4, FALSE) < 0) OR (Number(t, 32, 4, FALSE) > 1) OR
                   (Number(t, 36, 4, FALSE) <= 0) THEN Fail(t, Corrupt)
                ELSIF (Number(t, 32, 4, FALSE) # ORD(unique)) OR
                      (Number(t, 36, 4, FALSE) # orderID) THEN Fail(t, ConfigMismatch)
                ELSE
                    t.nextSerial := Number(t, 40, 4, FALSE);
                    t.root := Number(t, 12, 4, FALSE); t.pages := Number(t, 16, 4, FALSE);
                    t.free := Number(t, 20, 4, FALSE); t.count := Number(t, 24, 4, FALSE);
                    IF (t.nextSerial < 1) OR (t.nextSerial > MaxSerial) OR
                       (t.unique & (t.nextSerial # 1)) OR (t.pages # pages) OR ~PageRef(t, t.root) OR (t.count < 0) OR
                       (t.count > (pages - 1) * MaxKeys) OR
                       ((t.free # 0) & ~PageRef(t, t.free)) THEN Fail(t, Corrupt)
                    ELSIF ReadNode(t, t.root, t.w.a) THEN Header(t, FALSE) END
                END
            END;
            IF t.failed THEN F.Close(t.file); Release(t)
            ELSE t.opened := TRUE; INC(t.generation) END
        END
    END;
    RETURN t.error = OK
END Open;

(* Separators are lower bounds for right subtrees, not necessarily live keys.
   Deleting a minimum need not rewrite ancestors; redistribution updates fences. *)
PROCEDURE Find(VAR t: BpTree; key: ARRAY OF CHAR; serial: INTEGER; VAR depth, id, pos: INTEGER): BOOLEAN;
VAR go: BOOLEAN;
BEGIN
    depth := 0; id := t.root; go := TRUE;
    WHILE go & ~t.failed DO
        IF ReadNode(t, id, t.w.a) THEN
            pos := 0;
            IF t.w.a.kind = Leaf THEN
                WHILE (pos < t.w.a.n) & (CompareEntry(t, t.w.a.key[pos], t.w.a.serial[pos], key, serial) < 0) DO INC(pos) END;
                go := FALSE
            ELSIF depth = Height THEN Fail(t, Corrupt)
            ELSE
                WHILE (pos < t.w.a.n) & (CompareEntry(t, key, serial, t.w.a.key[pos], t.w.a.serial[pos]) >= 0) DO INC(pos) END;
                t.w.path[depth] := id; t.w.slot[depth] := pos; INC(depth);
                id := t.w.a.child[pos]
            END
        END
    END;
    RETURN ~t.failed
END Find;

PROCEDURE Lower(VAR t: BpTree; key: ARRAY OF CHAR; VAR id, pos: INTEGER): BOOLEAN;
VAR depth, visited: INTEGER;
BEGIN
    visited := 0;
    IF Find(t, key, 0, depth, id, pos) THEN
        WHILE (pos = t.w.a.n) & (t.w.a.next # 0) & ~t.failed DO
            id := t.w.a.next; pos := 0; INC(visited);
            IF visited > t.pages THEN Fail(t, Corrupt)
            ELSIF ReadNode(t, id, t.w.a) THEN
                IF t.w.a.kind # Leaf THEN Fail(t, Corrupt) END
            END
        END
    END;
    RETURN ~t.failed
END Lower;

PROCEDURE Get*(VAR t: BpTree; key: ARRAY OF CHAR; VAR value: INTEGER): BOOLEAN;
VAR id, pos: INTEGER; found: BOOLEAN;
BEGIN
    found := FALSE;
    IF Ready(t) THEN
        IF ~ValidKey(key) THEN t.error := BadKey
        ELSIF Lower(t, key, id, pos) THEN
            found := (pos < t.w.a.n) & (CompareKeys(t, t.w.a.key[pos], key) = 0);
            IF found THEN value := t.w.a.value[pos] ELSE t.error := NotFound END
        END
    END;
    RETURN found
END Get;

PROCEDURE WriteEntry(VAR t: BpTree; key: ARRAY OF CHAR; value: INTEGER; replace: BOOLEAN): BOOLEAN;
VAR depth, id, pos, i, mid, right, parentID: INTEGER;
    carry: Key; carrySerial, serial: INTEGER; split: BOOLEAN;
BEGIN
    serial := 0;
    IF ~t.unique THEN serial := t.nextSerial END;
    IF Ready(t) THEN
        IF ~ValidKey(key) THEN t.error := BadKey
        ELSIF ~t.unique & (serial >= MaxSerial) THEN t.error := Limit
        ELSIF Find(t, key, serial, depth, id, pos) THEN
            IF t.unique & (pos < t.w.a.n) & (CompareKeys(t, t.w.a.key[pos], key) = 0) THEN
                IF replace THEN
                    INC(t.generation); t.w.a.value[pos] := value; WriteNode(t, id, t.w.a)
                ELSE t.error := Duplicate END
            ELSE
                INC(t.generation);
                IF ~t.unique THEN INC(t.nextSerial) END;
                FOR i := t.w.a.n TO pos + 1 BY -1 DO
                    t.w.a.key[i] := t.w.a.key[i - 1]; t.w.a.serial[i] := t.w.a.serial[i - 1]; t.w.a.value[i] := t.w.a.value[i - 1]
                END;
                CopyKey(key, t.w.a.key[pos]); t.w.a.serial[pos] := serial; t.w.a.value[pos] := value; INC(t.w.a.n);
                INC(t.count); split := TRUE;
                WHILE split & ~t.failed DO
                    IF t.w.a.n <= MaxKeys THEN WriteNode(t, id, t.w.a); split := FALSE
                    ELSE
                        right := NewPage(t); mid := t.w.a.n DIV 2;
                        t.w.b.kind := t.w.a.kind; t.w.b.next := t.w.a.next;
                        IF t.w.a.kind = Leaf THEN
                            t.w.b.n := t.w.a.n - mid;
                            FOR i := 0 TO t.w.b.n - 1 DO
                                t.w.b.key[i] := t.w.a.key[mid + i]; t.w.b.serial[i] := t.w.a.serial[mid + i]; t.w.b.value[i] := t.w.a.value[mid + i]
                            END;
                            carry := t.w.b.key[0]; carrySerial := t.w.b.serial[0]; t.w.a.next := right
                        ELSE
                            carry := t.w.a.key[mid]; carrySerial := t.w.a.serial[mid]; t.w.b.n := t.w.a.n - mid - 1;
                            t.w.b.child[0] := t.w.a.child[mid + 1];
                            FOR i := 0 TO t.w.b.n - 1 DO
                                t.w.b.key[i] := t.w.a.key[mid + 1 + i]; t.w.b.serial[i] := t.w.a.serial[mid + 1 + i];
                                t.w.b.child[i + 1] := t.w.a.child[mid + 2 + i]
                            END
                        END;
                        t.w.a.n := mid;
                        WriteNode(t, id, t.w.a); WriteNode(t, right, t.w.b);
                        IF depth = 0 THEN
                            parentID := NewPage(t); t.w.a.kind := Branch; t.w.a.n := 1; t.w.a.next := 0;
                            t.w.a.key[0] := carry; t.w.a.serial[0] := carrySerial; t.w.a.child[0] := id; t.w.a.child[1] := right;
                            WriteNode(t, parentID, t.w.a); t.root := parentID; split := FALSE
                        ELSE
                            DEC(depth); parentID := t.w.path[depth]; pos := t.w.slot[depth];
                            IF ReadNode(t, parentID, t.w.a) THEN
                                FOR i := t.w.a.n TO pos + 1 BY -1 DO
                                    t.w.a.key[i] := t.w.a.key[i - 1]; t.w.a.serial[i] := t.w.a.serial[i - 1]; t.w.a.child[i + 1] := t.w.a.child[i]
                                END;
                                t.w.a.key[pos] := carry; t.w.a.serial[pos] := carrySerial; t.w.a.child[pos + 1] := right;
                                INC(t.w.a.n); id := parentID
                            END
                        END
                    END
                END
            END
        END
    END;
    RETURN t.error = OK
END WriteEntry;

PROCEDURE Put*(VAR t: BpTree; key: ARRAY OF CHAR; value: INTEGER): BOOLEAN;
BEGIN RETURN WriteEntry(t, key, value, TRUE) END Put;

PROCEDURE Insert*(VAR t: BpTree; key: ARRAY OF CHAR; value: INTEGER): BOOLEAN;
BEGIN
    RETURN WriteEntry(t, key, value, FALSE)
END Insert;

(* Remove separator k and the child immediately to its right. *)
PROCEDURE DropChild(p: Node; k: INTEGER);
VAR i: INTEGER;
BEGIN
    FOR i := k TO p.n - 2 DO p.key[i] := p.key[i + 1]; p.serial[i] := p.serial[i + 1]; p.child[i + 1] := p.child[i + 2] END;
    DEC(p.n)
END DropChild;

(* Concatenate right onto left, with the parent's separator for branches. *)
PROCEDURE Merge(left, right: Node; fence: ARRAY OF CHAR; serial: INTEGER);
VAR i, start: INTEGER;
BEGIN
    start := left.n;
    IF left.kind = Branch THEN
        CopyKey(fence, left.key[start]); left.serial[start] := serial; left.child[start + 1] := right.child[0]; INC(start)
    ELSE left.next := right.next END;
    FOR i := 0 TO right.n - 1 DO
        left.key[start + i] := right.key[i]; left.serial[start + i] := right.serial[i]; left.value[start + i] := right.value[i];
        left.child[start + i + 1] := right.child[i + 1]
    END;
    left.n := start + right.n
END Merge;

PROCEDURE RemoveEntry(VAR t: BpTree; key: ARRAY OF CHAR; matchValue: BOOLEAN; value: INTEGER): BOOLEAN;
VAR depth, id, pos, i, parentID, sibling, k, old, serial: INTEGER; done, found: BOOLEAN;
BEGIN
    found := FALSE;
    IF Ready(t) THEN
        IF ~ValidKey(key) THEN t.error := BadKey
        ELSIF Lower(t, key, id, pos) THEN
            done := FALSE; i := 0;
            WHILE ~done & ~t.failed DO
                IF pos = t.w.a.n THEN
                    IF t.w.a.next = 0 THEN done := TRUE
                    ELSE
                        id := t.w.a.next; pos := 0; INC(i);
                        IF i > t.pages THEN Fail(t, Corrupt)
                        ELSIF ReadNode(t, id, t.w.a) THEN
                            IF t.w.a.kind # Leaf THEN Fail(t, Corrupt) END
                        END
                    END
                ELSIF CompareKeys(t, t.w.a.key[pos], key) # 0 THEN done := TRUE
                ELSIF ~matchValue OR (t.w.a.value[pos] = value) THEN found := TRUE; done := TRUE
                ELSE INC(pos) END
            END;
            IF found THEN
                serial := t.w.a.serial[pos]; found := Find(t, key, serial, depth, id, pos)
            END;
            IF ~found THEN
                IF ~t.failed THEN t.error := NotFound END
            ELSE
                INC(t.generation); DEC(t.count);
                FOR i := pos TO t.w.a.n - 2 DO
                    t.w.a.key[i] := t.w.a.key[i + 1]; t.w.a.serial[i] := t.w.a.serial[i + 1]; t.w.a.value[i] := t.w.a.value[i + 1]
                END;
                DEC(t.w.a.n); done := FALSE;
                WHILE ~done & ~t.failed DO
                    IF depth = 0 THEN
                        IF (t.w.a.kind = Branch) & (t.w.a.n = 0) THEN
                            t.root := t.w.a.child[0]; FreePage(t, id)
                        ELSE WriteNode(t, id, t.w.a) END;
                        done := TRUE
                    ELSIF t.w.a.n >= MinKeys THEN WriteNode(t, id, t.w.a); done := TRUE
                    ELSE
                        DEC(depth); parentID := t.w.path[depth]; pos := t.w.slot[depth];
                        IF ReadNode(t, parentID, t.w.parent) THEN
                            IF pos > 0 THEN k := pos - 1 ELSE k := pos + 1 END;
                            sibling := t.w.parent.child[k];
                            IF ReadNode(t, sibling, t.w.b) THEN
                                IF t.w.a.kind # t.w.b.kind THEN Fail(t, Corrupt)
                                ELSIF t.w.b.n > MinKeys THEN
                                    IF pos > 0 THEN
                                        FOR i := t.w.a.n TO 1 BY -1 DO
                                            t.w.a.key[i] := t.w.a.key[i - 1]; t.w.a.serial[i] := t.w.a.serial[i - 1]; t.w.a.value[i] := t.w.a.value[i - 1];
                                            t.w.a.child[i + 1] := t.w.a.child[i]
                                        END;
                                        t.w.a.child[1] := t.w.a.child[0];
                                        IF t.w.a.kind = Leaf THEN
                                            t.w.a.key[0] := t.w.b.key[t.w.b.n - 1]; t.w.a.serial[0] := t.w.b.serial[t.w.b.n - 1]; t.w.a.value[0] := t.w.b.value[t.w.b.n - 1];
                                            t.w.parent.key[pos - 1] := t.w.a.key[0]; t.w.parent.serial[pos - 1] := t.w.a.serial[0]
                                        ELSE
                                            t.w.a.key[0] := t.w.parent.key[pos - 1]; t.w.a.serial[0] := t.w.parent.serial[pos - 1];
                                            t.w.a.child[0] := t.w.b.child[t.w.b.n];
                                            t.w.parent.key[pos - 1] := t.w.b.key[t.w.b.n - 1]; t.w.parent.serial[pos - 1] := t.w.b.serial[t.w.b.n - 1]
                                        END;
                                        DEC(t.w.b.n); INC(t.w.a.n)
                                    ELSE
                                        old := t.w.b.n;
                                        IF t.w.a.kind = Leaf THEN
                                            t.w.a.key[t.w.a.n] := t.w.b.key[0]; t.w.a.serial[t.w.a.n] := t.w.b.serial[0]; t.w.a.value[t.w.a.n] := t.w.b.value[0]
                                        ELSE
                                            t.w.a.key[t.w.a.n] := t.w.parent.key[pos]; t.w.a.serial[t.w.a.n] := t.w.parent.serial[pos];
                                            t.w.a.child[t.w.a.n + 1] := t.w.b.child[0];
                                            t.w.parent.key[pos] := t.w.b.key[0]; t.w.parent.serial[pos] := t.w.b.serial[0]
                                        END;
                                        FOR i := 0 TO old - 2 DO
                                            t.w.b.key[i] := t.w.b.key[i + 1]; t.w.b.serial[i] := t.w.b.serial[i + 1]; t.w.b.value[i] := t.w.b.value[i + 1]
                                        END;
                                        FOR i := 0 TO old - 1 DO t.w.b.child[i] := t.w.b.child[i + 1] END;
                                        DEC(t.w.b.n); INC(t.w.a.n);
                                        IF t.w.a.kind = Leaf THEN t.w.parent.key[pos] := t.w.b.key[0]; t.w.parent.serial[pos] := t.w.b.serial[0] END
                                    END;
                                    WriteNode(t, id, t.w.a); WriteNode(t, sibling, t.w.b);
                                    WriteNode(t, parentID, t.w.parent); done := TRUE
                                ELSE
                                    IF pos > 0 THEN
                                        Merge(t.w.b, t.w.a, t.w.parent.key[pos - 1], t.w.parent.serial[pos - 1]);
                                        WriteNode(t, sibling, t.w.b); FreePage(t, id); DropChild(t.w.parent, pos - 1)
                                    ELSE
                                        Merge(t.w.a, t.w.b, t.w.parent.key[pos], t.w.parent.serial[pos]);
                                        WriteNode(t, id, t.w.a); FreePage(t, sibling); DropChild(t.w.parent, pos)
                                    END;
                                    t.w.a^ := t.w.parent^; id := parentID
                                END
                            END
                        END
                    END
                END
            END
        END
    END;
    RETURN found & ~t.failed
END RemoveEntry;

PROCEDURE Remove*(VAR t: BpTree; key: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN RemoveEntry(t, key, FALSE, 0)
END Remove;

PROCEDURE RemoveValue*(VAR t: BpTree; key: ARRAY OF CHAR; value: INTEGER): BOOLEAN;
BEGIN RETURN RemoveEntry(t, key, TRUE, value) END RemoveValue;

PROCEDURE RemoveAll*(VAR t: BpTree; key: ARRAY OF CHAR): INTEGER;
VAR count: INTEGER;
BEGIN
    count := 0;
    WHILE Remove(t, key) DO INC(count) END;
    IF t.error = NotFound THEN t.error := OK END;
    RETURN count
END RemoveAll;

PROCEDURE Seek*(VAR t: BpTree; lower: ARRAY OF CHAR; VAR c: Cursor): BOOLEAN;
VAR id, pos: INTEGER;
BEGIN
    c.owner := NIL;
    IF Ready(t) THEN
        IF ~ValidKey(lower) THEN t.error := BadKey
        ELSIF Lower(t, lower, id, pos) THEN
            c.owner := t.w; c.generation := t.generation;
            c.page := id; c.index := pos; c.visited := 0
        END
    END;
    RETURN t.error = OK
END Seek;

PROCEDURE First*(VAR t: BpTree; VAR c: Cursor): BOOLEAN;
VAR id, depth: INTEGER; done: BOOLEAN;
BEGIN
    c.owner := NIL;
    IF Ready(t) THEN
        id := t.root; depth := 0; done := FALSE;
        WHILE ~done & ~t.failed DO
            IF ReadNode(t, id, t.w.a) THEN
                IF t.w.a.kind = Leaf THEN done := TRUE
                ELSIF depth = Height THEN Fail(t, Corrupt)
                ELSE id := t.w.a.child[0]; INC(depth) END
            END
        END;
        IF ~t.failed THEN
            c.owner := t.w; c.generation := t.generation;
            c.page := id; c.index := 0; c.visited := 0
        END
    END;
    RETURN t.error = OK
END First;

PROCEDURE Next*(VAR t: BpTree; VAR c: Cursor; VAR key: ARRAY OF CHAR; VAR value: INTEGER): BOOLEAN;
VAR good, done: BOOLEAN; n, i: INTEGER;
BEGIN
    good := FALSE; done := FALSE;
    IF Ready(t) THEN
        IF (c.owner # t.w) OR (c.generation # t.generation) THEN t.error := Stale
        ELSE
            WHILE ~done & ~t.failed DO
                IF c.page = 0 THEN t.error := End; done := TRUE
                ELSIF ReadNode(t, c.page, t.w.a) THEN
                    IF t.w.a.kind # Leaf THEN Fail(t, Corrupt)
                    ELSIF c.index < t.w.a.n THEN
                        n := Length(t.w.a.key[c.index]);
                        IF LEN(key) <= n THEN t.error := BufferSmall
                        ELSE
                            FOR i := 0 TO n DO key[i] := t.w.a.key[c.index][i] END;
                            value := t.w.a.value[c.index]; INC(c.index); good := TRUE
                        END;
                        done := TRUE
                    ELSE
                        c.page := t.w.a.next; c.index := 0; INC(c.visited);
                        IF c.visited > t.pages THEN Fail(t, Corrupt) END
                    END
                END
            END
        END
    END;
    RETURN good
END Next;

END BpTrees.
