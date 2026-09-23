(* Independent test-only reader for DPB1 version 2. It uses Files directly,
   not BpTrees.Get/Next or the implementation's page decoder/comparator.
   BpTrees is used only to check rejection of deliberately damaged files. *)
MODULE BPTAudit;

IMPORT F := Files, Out, B := BpTrees, O := BPTOrder;

CONST
    PageSize = 4096; KeySize = 241; N = 12000; D = 2048;
    MaxAuditPages = 16384; MaxAuditSerial = 65536;
    Filled = 1; Sparse = 2; Churn = 3; Empty = 4; Reused = 5;
    Other = 6; Sensitive = 7; Folded = 8; DupFull = 9;
    DupSparse = 10; DupEmpty = 11; DupReused = 12; Reverse = 13;

TYPE
    Page = ARRAY PageSize OF BYTE;
    Key = ARRAY KeySize OF CHAR;
    Bound = RECORD present: BOOLEAN; key: Key; serial: INTEGER END;

VAR
    file: F.File; name: ARRAY 256 OF CHAR;
    root, pages, width, nextSerial, sortMode, scenario: INTEGER;
    storedCount, actualCount, expectedCount, modelPos, phase: INTEGER;
    leafDepth, leafNext, leafCount, livePages, freePages: INTEGER;
    unique, havePrevious: BOOLEAN;
    previous: Key; previousSerial: INTEGER;
    seen: ARRAY MaxAuditPages OF BYTE;
    serialSeen: ARRAY MaxAuditSerial OF BOOLEAN;
    live: ARRAY N OF BOOLEAN;
    values: ARRAY N OF INTEGER;
    dupLive: ARRAY D OF BOOLEAN;

PROCEDURE Check(ok: BOOLEAN; message: ARRAY OF CHAR);
BEGIN
    IF ~ok THEN
        Out.String("FAIL audit "); Out.String(name); Out.String(": "); Out.StringLn(message);
        ASSERT(FALSE)
    END
END Check;

PROCEDURE Unsigned(VAR p: Page; offset, bytes: INTEGER): INTEGER;
VAR i, n: INTEGER;
BEGIN
    n := 0;
    FOR i := bytes - 1 TO 0 BY -1 DO n := n * 256 + p[offset + i] END;
    RETURN n
END Unsigned;

PROCEDURE Signed(VAR p: Page; offset, bytes: INTEGER): INTEGER;
VAR i, n: INTEGER;
BEGIN
    n := p[offset + bytes - 1];
    IF n >= 128 THEN DEC(n, 256) END;
    FOR i := bytes - 2 TO 0 BY -1 DO n := n * 256 + p[offset + i] END;
    RETURN n
END Signed;

(* Weighted-sum form, independent of the tree's running checksum algorithm.
   Even for all bytes=255 the second accumulator fits signed INTEGER32:
   4092 + 255*4092*4093/2 = 2135444982. *)
PROCEDURE Checksum(VAR p: Page): INTEGER;
VAR i, a, b: INTEGER;
BEGIN
    a := 1; b := PageSize - 4;
    FOR i := 0 TO PageSize - 5 DO
        INC(a, p[i]); INC(b, p[i] * (PageSize - 4 - i))
    END;
    RETURN a MOD 251 + b MOD 251 * 256
END Checksum;

PROCEDURE ReadPage(id: INTEGER; VAR p: Page);
BEGIN
    Check((id >= 0) & (id < pages), "page reference");
    F.Seek(file, id * PageSize);
    Check(F.Position(file) = id * PageSize, "seek");
    Check(F.BlockRead(file, p, PageSize) = PageSize, "short page");
    Check(Unsigned(p, PageSize - 4, 4) = Checksum(p), "checksum")
END ReadPage;

(* Decode Unicode scalar values rather than reusing BpTrees.ValidKey. *)
PROCEDURE DecodeKey(VAR p: Page; offset: INTEGER; VAR key: Key);
VAR n, i, j, b, length, code, minimum: INTEGER;
BEGIN
    n := Unsigned(p, offset, 2); Check(n <= KeySize - 1, "key length");
    FOR i := 0 TO n - 1 DO
        b := p[offset + 2 + i]; Check(b # 0, "embedded NUL"); key[i] := CHR(b)
    END;
    key[n] := 0X; i := 0;
    WHILE i < n DO
        b := ORD(key[i]); length := 0; code := 0; minimum := 0;
        IF b < 128 THEN length := 1; code := b
        ELSIF (b >= 194) & (b <= 223) THEN length := 2; code := b MOD 32; minimum := 128
        ELSIF (b >= 224) & (b <= 239) THEN length := 3; code := b MOD 16; minimum := 2048
        ELSIF (b >= 240) & (b <= 244) THEN length := 4; code := b MOD 8; minimum := 65536 END;
        Check((length > 0) & (i + length <= n), "UTF8 lead/length");
        FOR j := 1 TO length - 1 DO
            b := ORD(key[i + j]); Check((b >= 128) & (b <= 191), "UTF8 continuation");
            code := code * 64 + b - 128
        END;
        Check((code >= minimum) & (code <= 10FFFFH) &
              ((code < 0D800H) OR (code > 0DFFFH)), "Unicode scalar");
        INC(i, length)
    END
END DecodeKey;

(* Independent reference order: 1=bytes, 2=ASCII-folded, 3=reverse bytes. *)
PROCEDURE Compare(a, b: ARRAY OF CHAR): INTEGER;
VAR i, x, y, result: INTEGER;
BEGIN
    i := 0; result := 0;
    REPEAT
        x := ORD(a[i]); y := ORD(b[i]);
        IF sortMode = 2 THEN
            IF (x >= 65) & (x <= 90) THEN INC(x, 32) END;
            IF (y >= 65) & (y <= 90) THEN INC(y, 32) END
        END;
        IF x < y THEN result := -1 ELSIF x > y THEN result := 1 END;
        INC(i)
    UNTIL (result # 0) OR (x = 0);
    IF sortMode = 3 THEN result := -result END;
    RETURN result
END Compare;

PROCEDURE PairCompare(a: ARRAY OF CHAR; sa: INTEGER; b: ARRAY OF CHAR; sb: INTEGER): INTEGER;
VAR result: INTEGER;
BEGIN
    result := Compare(a, b);
    IF result = 0 THEN
        IF sa < sb THEN result := -1 ELSIF sa > sb THEN result := 1 END
    END;
    RETURN result
END PairCompare;

PROCEDURE NumberKey(i, digits: INTEGER; VAR key: Key);
VAR j: INTEGER;
BEGIN
    key[0] := "k";
    FOR j := digits TO 1 BY -1 DO key[j] := CHR(48 + i MOD 10); i := i DIV 10 END;
    key[digits + 1] := 0X
END NumberKey;

PROCEDURE Model(kind: INTEGER);
VAR i, j, seed, k: INTEGER;
BEGIN
    scenario := kind; expectedCount := 0; modelPos := 0; phase := 0;
    FOR i := 0 TO N - 1 DO
        live[i] := FALSE; values[i] := i * 3 - 9000;
        IF kind = Filled THEN live[i] := TRUE
        ELSIF (kind = Sparse) OR (kind = Churn) THEN live[i] := i MOD 3 = 0
        ELSIF kind = Reused THEN live[i] := i < 2000; values[i] := i
        ELSIF kind = Reverse THEN live[i] := (i < 100) OR ((i >= 900) & (i < 1000)); values[i] := i END
    END;
    IF kind = Churn THEN
        seed := 17;
        FOR j := 0 TO 3 * N - 1 DO
            seed := (seed * 109 + 89) MOD 65521; i := seed MOD N;
            IF seed MOD 3 = 0 THEN live[i] := FALSE
            ELSE live[i] := TRUE; values[i] := -seed END
        END
    END;
    FOR i := 0 TO N - 1 DO IF live[i] THEN INC(expectedCount) END END;
    IF kind = Reverse THEN modelPos := 999 END;
    IF (kind = Other) OR (kind = Folded) THEN expectedCount := 1
    ELSIF kind = Sensitive THEN expectedCount := 2
    ELSIF (kind >= DupFull) & (kind <= DupReused) THEN
        FOR i := 0 TO D - 1 DO dupLive[i] := (kind = DupFull) OR (kind = DupSparse) END;
        IF kind = DupSparse THEN
            dupLive[0] := FALSE; dupLive[8] := FALSE;
            FOR j := 0 TO 799 DO
                k := j * 13 MOD 17; i := 0;
                WHILE (i < D) & (~dupLive[i] OR (i MOD 17 # k)) DO INC(i) END;
                Check(i < D, "duplicate reference model"); dupLive[i] := FALSE
            END
        END;
        expectedCount := 2;
        FOR i := 0 TO D - 1 DO IF dupLive[i] THEN INC(expectedCount) END END;
        IF kind = DupReused THEN expectedCount := 102 END
    END
END Model;

PROCEDURE Expect(key: ARRAY OF CHAR; value: INTEGER);
VAR wanted: Key; v: INTEGER;
BEGIN
    Check(actualCount < expectedCount, "extra record"); v := 0; wanted := "";
    IF (scenario <= Reused) OR (scenario = Reverse) THEN
        IF scenario = Reverse THEN
            WHILE (modelPos >= 0) & ~live[modelPos] DO DEC(modelPos) END;
            Check(modelPos >= 0, "extra reverse record");
            NumberKey(modelPos, 4, wanted); v := values[modelPos]; DEC(modelPos)
        ELSE
            WHILE (modelPos < N) & ~live[modelPos] DO INC(modelPos) END;
            Check(modelPos < N, "extra model record");
            NumberKey(modelPos, 5, wanted); v := values[modelPos]; INC(modelPos)
        END
    ELSIF scenario = Other THEN wanted := "independent"; v := 123
    ELSIF scenario = Sensitive THEN
        IF actualCount = 0 THEN wanted := "Apple"; v := 3 ELSE wanted := "apple"; v := 2 END
    ELSIF scenario = Folded THEN wanted := "Alpha"; v := 3
    ELSE
        IF phase = 0 THEN wanted := "aardvark"; v := -1; phase := 1
        ELSE
            IF scenario = DupReused THEN
                IF modelPos < 100 THEN wanted := "Alpha"; v := 7; INC(modelPos)
                ELSE phase := 2 END
            ELSE
                WHILE (modelPos < D) & ~dupLive[modelPos] DO INC(modelPos) END;
                IF modelPos < D THEN
                    IF ODD(modelPos) THEN wanted := "ALPHA" ELSE wanted := "Alpha" END;
                    v := modelPos MOD 17; INC(modelPos)
                ELSE phase := 2 END
            END;
            IF phase = 2 THEN wanted := "Zulu"; v := -2; phase := 3 END
        END
    END;
    Check(key = wanted, "key differs from reference list");
    Check(value = v, "value differs from reference list"); INC(actualCount)
END Expect;

PROCEDURE Visit(id, depth: INTEGER; VAR low, high: Bound);
VAR p: Page; keys: ARRAY 15 OF Key; serial: ARRAY 15 OF INTEGER;
    children: ARRAY 16 OF INTEGER;
    childLow, childHigh: Bound;
    kind, n, next, i, base, v: INTEGER;
BEGIN
    Check((id > 0) & (id < pages), "child range");
    Check((seen[id] = 0) & (depth < 32), "shared page/cycle/depth");
    seen[id] := 1; INC(livePages); ReadPage(id, p);
    kind := Unsigned(p, 0, 4); n := Unsigned(p, 4, 4); next := Unsigned(p, 8, 4);
    Check((kind = 1) OR (kind = 2), "node kind");
    Check((n >= 0) & (n <= 15), "node size");
    IF id # root THEN Check(n >= 7, "underfull nonroot")
    ELSIF kind = 2 THEN Check(n >= 1, "empty branch root") END;
    children[0] := Unsigned(p, 12, 4);
    FOR i := 0 TO n - 1 DO
        base := 32 + i * 256; DecodeKey(p, base, keys[i]); serial[i] := Unsigned(p, base + 244, 4);
        IF unique THEN Check(serial[i] = 0, "unique serial")
        ELSE Check((serial[i] > 0) & (serial[i] < nextSerial), "duplicate serial range") END;
        IF i > 0 THEN Check(PairCompare(keys[i - 1], serial[i - 1], keys[i], serial[i]) < 0, "node order") END;
        IF low.present THEN Check(PairCompare(low.key, low.serial, keys[i], serial[i]) <= 0, "subtree lower bound") END;
        IF high.present THEN Check(PairCompare(keys[i], serial[i], high.key, high.serial) < 0, "subtree upper bound") END;
        IF kind = 2 THEN children[i + 1] := Unsigned(p, base + 248, 4) END
    END;
    IF kind = 1 THEN
        Check(children[0] = 0, "leaf child0");
        IF leafCount > 0 THEN Check(leafNext = id, "leaf chain order") END;
        leafNext := next; INC(leafCount);
        IF leafDepth < 0 THEN leafDepth := depth ELSE Check(leafDepth = depth, "unbalanced leaves") END;
        FOR i := 0 TO n - 1 DO
            IF havePrevious THEN
                Check(PairCompare(previous, previousSerial, keys[i], serial[i]) < 0, "global entry order")
            END;
            previous := keys[i]; previousSerial := serial[i]; havePrevious := TRUE;
            IF ~unique THEN
                Check(serial[i] < MaxAuditSerial, "audit serial capacity");
                Check(~serialSeen[serial[i]], "reused record serial"); serialSeen[serial[i]] := TRUE
            END;
            v := Signed(p, 32 + i * 256 + 248, width); Expect(keys[i], v)
        END
    ELSE
        Check(next = 0, "branch next pointer");
        FOR i := 0 TO n DO
            childLow := low; childHigh := high;
            IF i > 0 THEN childLow.present := TRUE; childLow.key := keys[i - 1]; childLow.serial := serial[i - 1] END;
            IF i < n THEN childHigh.present := TRUE; childHigh.key := keys[i]; childHigh.serial := serial[i] END;
            Visit(children[i], depth + 1, childLow, childHigh)
        END
    END
END Visit;

PROCEDURE Audit(path: ARRAY OF CHAR; kind: INTEGER; isUnique: BOOLEAN; orderID, mode: INTEGER);
VAR p: Page; size, head, i: INTEGER; low, high: Bound;
BEGIN
    COPY(path, name); unique := isUnique; sortMode := mode; Model(kind);
    Check(F.Reset(file, path), "open audit file"); size := F.Size(file);
    Check((size >= 2 * PageSize) & (size MOD PageSize = 0), "file length");
    pages := size DIV PageSize; Check(pages <= MaxAuditPages, "audit page capacity");
    ReadPage(0, p);
    Check((Unsigned(p, 0, 4) = 31425044H) & (Unsigned(p, 4, 4) = 2), "format version");
    width := Unsigned(p, 8, 4); root := Unsigned(p, 12, 4);
    Check((width = 4) OR (width = 8), "INTEGER width");
    Check(Unsigned(p, 16, 4) = pages, "page count"); head := Unsigned(p, 20, 4);
    storedCount := Unsigned(p, 24, 4); Check(Unsigned(p, 28, 4) = 1, "clean header");
    Check((Unsigned(p, 32, 4) = ORD(unique)) & (Unsigned(p, 36, 4) = orderID), "index configuration");
    nextSerial := Unsigned(p, 40, 4);
    Check((nextSerial >= 1) & (nextSerial <= 2147483647), "next serial");
    IF unique THEN Check(nextSerial = 1, "unique next serial") END;
    IF kind = DupReused THEN Check(nextSerial = 2151, "serial persisted across reopen") END;
    FOR i := 0 TO pages - 1 DO seen[i] := 0 END;
    FOR i := 0 TO MaxAuditSerial - 1 DO serialSeen[i] := FALSE END;
    actualCount := 0; havePrevious := FALSE; leafDepth := -1; leafCount := 0; leafNext := 0;
    livePages := 0; freePages := 0; low.present := FALSE; high.present := FALSE;
    Visit(root, 0, low, high); Check(leafNext = 0, "last leaf next");
    WHILE head # 0 DO
        Check((head > 0) & (head < pages), "free page range");
        Check(seen[head] = 0, "free-list cycle or live/free overlap");
        seen[head] := 2; INC(freePages); ReadPage(head, p);
        Check(Unsigned(p, 0, 4) = 3, "free page kind"); head := Unsigned(p, 8, 4)
    END;
    FOR i := 1 TO pages - 1 DO Check(seen[i] # 0, "orphan page") END;
    Check((actualCount = storedCount) & (actualCount = expectedCount), "record count/reference list");
    F.Close(file); Check(F.Ok(file), "audit close");
    Out.String(path); Out.String(": "); Out.Int(actualCount, 0); Out.String(" records, height ");
    Out.Int(leafDepth + 1, 0); Out.String(", live/free pages "); Out.Int(livePages, 0);
    Out.Char("/"); Out.Int(freePages, 0); Out.Ln
END Audit;

PROCEDURE SameFiles(a, b: ARRAY OF CHAR);
VAR left, right: F.File; x, y: ARRAY 512 OF BYTE; n, m, i: INTEGER;
BEGIN
    COPY(a, name); Check(F.Reset(left, a), "open comparison left");
    Check(F.Reset(right, b), "open comparison right");
    Check(F.Size(left) = F.Size(right), "rejected Open changed file length");
    WHILE F.Position(left) < F.Size(left) DO
        n := F.BlockRead(left, x, LEN(x)); m := F.BlockRead(right, y, LEN(y));
        Check((n > 0) & (n = m), "comparison short read");
        FOR i := 0 TO n - 1 DO Check(x[i] = y[i], "rejected Open changed bytes") END
    END;
    F.Close(left); F.Close(right); Check(F.Ok(left) & F.Ok(right), "comparison close")
END SameFiles;

PROCEDURE WriteU32(VAR p: Page; offset, value: INTEGER);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO 3 DO p[offset + i] := value MOD 256; value := value DIV 256 END
END WriteU32;

PROCEDURE Damage(page, offset, value: INTEGER; fixChecksum: BOOLEAN);
VAR p: Page;
BEGIN
    Check(F.Copy("tree.db", "bad.db"), "copy corruption fixture");
    Check(F.Reset(file, "bad.db"), "open corruption fixture");
    F.Seek(file, page * PageSize); Check(F.Position(file) = page * PageSize, "damage seek");
    Check(F.BlockRead(file, p, PageSize) = PageSize, "damage read");
    WriteU32(p, offset, value);
    IF fixChecksum THEN WriteU32(p, PageSize - 4, Checksum(p)) END;
    F.Seek(file, page * PageSize);
    Check(F.BlockWrite(file, p, PageSize) = PageSize, "damage write");
    F.Close(file); Check(F.Ok(file), "damage flush")
END Damage;

PROCEDURE Corruption;
VAR p: Page; t: B.BpTree; id, count, bytes, i: INTEGER;
BEGIN
    name := "corruption fixtures"; B.Init(t);
    Check(F.Reset(file, "tree.db"), "source open");
    Check(F.BlockRead(file, p, PageSize) = PageSize, "source header");
    id := Unsigned(p, 12, 4); count := Unsigned(p, 16, 4); bytes := Unsigned(p, 8, 4);
    F.Close(file); Check(F.Ok(file), "source close");
    FOR i := 0 TO 13 DO
        CASE i OF
        | 0: Damage(0, 100, 1, FALSE)
        | 1: Damage(0, 4, 99, TRUE)
        | 2: Damage(0, 4, 1, TRUE)
        | 3: Damage(0, 32, 2, TRUE)
        | 4: Damage(0, 36, 0, TRUE)
        | 5: Damage(id, 32 + 244, 1, TRUE)
        | 6: IF bytes = 8 THEN Damage(0, 8, 4, TRUE) ELSE Damage(0, 8, 8, TRUE) END
        | 7: Damage(0, 28, 0, TRUE)
        | 8: Damage(0, 12, count, TRUE)
        | 9: Damage(id, 0, 99, TRUE)
        |10: Damage(id, 4, 16, TRUE)
        |11: Damage(id, 12, count, TRUE)
        |12: Damage(id, 32, 241, TRUE)
        |13: Check(F.Copy("tree.db", "bad.db"), "truncate fixture copy");
             Check(F.Reset(file, "bad.db"), "truncate fixture open");
             F.Seek(file, F.Size(file) - 1); F.Truncate(file);
             F.Close(file); Check(F.Ok(file), "truncate fixture close")
        END;
        Check(~B.Open(t, "bad.db", TRUE, O.English, O.EnglishID), "damaged file accepted");
        Check(B.Error(t) = B.Corrupt, "wrong corruption status")
    END;
    Check(F.Delete("bad.db"), "remove corruption fixture");
    Out.StringLn("BpTrees: 14 corruption cases OK")
END Corruption;

PROCEDURE Run*;
BEGIN
    Audit("filled.db", Filled, TRUE, 1, 1);
    Audit("sparse.db", Sparse, TRUE, 1, 1);
    Audit("churn.db", Churn, TRUE, 1, 1);
    Audit("empty.db", Empty, TRUE, 1, 1);
    Audit("tree.db", Reused, TRUE, 1, 1);
    Audit("other.db", Other, TRUE, 1, 1);
    Audit("case.db", Sensitive, TRUE, 1, 1);
    Audit("fold.db", Folded, TRUE, 2, 2);
    SameFiles("foldpre.db", "foldpost.db");
    Audit("dupfull.db", DupFull, FALSE, 2, 2);
    Audit("dupspars.db", DupSparse, FALSE, 2, 2);
    Audit("dupempty.db", DupEmpty, FALSE, 2, 2);
    Audit("dupreuse.db", DupReused, FALSE, 2, 2);
    Audit("dups.db", DupEmpty, FALSE, 2, 2);
    Audit("reverse.db", Reverse, FALSE, 1001, 3);
    Corruption;
    Out.StringLn("BpTrees independent audit OK")
END Run;

END BPTAudit.
