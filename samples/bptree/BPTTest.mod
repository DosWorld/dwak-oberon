MODULE BPTTest;

IMPORT B := BpTrees, O := BPTOrder, Out, F := Files, SYSTEM;

CONST N = 12000;

VAR t, other: B.BpTree; c: B.Cursor;
    key, got: ARRAY B.MaxKey + 1 OF CHAR;
    bad: ARRAY 4 OF CHAR; long: ARRAY B.MaxKey + 2 OF CHAR;
    tiny: ARRAY 1 OF CHAR;
    expected: ARRAY N OF INTEGER;
    live: ARRAY N OF BOOLEAN;
    n, v, size, min, seed: INTEGER;
    ok: BOOLEAN; file: F.File;

PROCEDURE Check(test: BOOLEAN; label: ARRAY OF CHAR);
BEGIN
    IF ~test THEN
        Out.String("FAIL: "); Out.String(label); Out.String(" error="); Out.Int(B.Error(t), 0); Out.Ln;
        ASSERT(FALSE)
    END
END Check;

PROCEDURE Key(i: INTEGER);
VAR j: INTEGER;
BEGIN
    key[0] := "k";
    FOR j := 5 TO 1 BY -1 DO key[j] := CHR(ORD("0") + i MOD 10); i := i DIV 10 END;
    key[6] := 0X
END Key;

PROCEDURE Reopen;
BEGIN
    Check(B.Close(t), "close"); Check(B.Open(t, "tree.db", TRUE, O.English, O.EnglishID), "reopen")
END Reopen;

PROCEDURE Snapshot(name: ARRAY OF CHAR);
BEGIN
    Check(B.Close(t), "snapshot close"); Check(F.Copy("tree.db", name), "snapshot copy");
    Check(B.Open(t, "tree.db", TRUE, O.English, O.EnglishID), "snapshot reopen")
END Snapshot;

PROCEDURE Verify;
VAR i, count: INTEGER;
BEGIN
    count := 0;
    FOR i := 0 TO N - 1 DO
        Key(i); v := 999;
        IF live[i] THEN
            Check(B.Get(t, key, v), "get live"); Check(v = expected[i], "value"); INC(count)
        ELSE
            Check(~B.Get(t, key, v), "get removed"); Check(v = 999, "failure preserves value");
            Check(B.Error(t) = B.NotFound, "not found status")
        END
    END;
    Check(B.Count(t) = count, "count");
    Check(B.Seek(t, "", c), "seek first"); i := 0;
    WHILE B.Next(t, c, got, v) DO
        WHILE (i < N) & ~live[i] DO INC(i) END;
        Check(i < N, "scan extra"); Key(i); Check(got = key, "scan order");
        Check(v = expected[i], "scan value"); INC(i)
    END;
    WHILE (i < N) & ~live[i] DO INC(i) END;
    Check(i = N, "scan missing"); Check(B.Error(t) = B.End, "scan end")
END Verify;

PROCEDURE Run*;
VAR i, j, round: INTEGER;
BEGIN
    B.Init(t); B.Init(other);
    Check(B.Create(t, "tree.db", TRUE, O.English, O.EnglishID), "create");
    Check(~B.Create(other, "tree.db", TRUE, O.English, O.EnglishID), "create must not truncate");
    Check(B.Error(other) = B.Exists, "exists status");
    Check(B.Put(t, "", 0), "empty key"); Check(B.Get(t, "", v) & (v = 0), "get empty");
    Check(B.Put(t, "", -7), "replace"); Check(B.Count(t) = 1, "replace count");
    Check(B.Remove(t, ""), "remove empty");
    Check(~B.Remove(t, ""), "missing remove");
    Check(B.Put(t, "Київ", -123), "UTF8 Cyrillic");
    Check(B.Put(t, "日本語", 456), "UTF8 CJK");
    Check(B.Put(t, "🙂", 789), "UTF8 non-BMP");
    Reopen;
    Check(B.Get(t, "Київ", v) & (v = -123), "reopen Cyrillic");
    Check(B.Get(t, "日本語", v) & (v = 456), "reopen CJK");
    Check(B.Get(t, "🙂", v) & (v = 789), "reopen non-BMP");
    Check(B.Remove(t, "Київ"), "remove Cyrillic"); Check(B.Remove(t, "日本語"), "remove CJK");
    Check(B.Remove(t, "🙂"), "remove non-BMP");
    bad[0] := 0C0X; bad[1] := 0AFX; bad[2] := 0X;
    Check(~B.Put(t, bad, 1), "reject overlong UTF8"); Check(B.Error(t) = B.BadKey, "bad key status");
    bad[0] := 0EDX; bad[1] := 0A0X; bad[2] := 80X; bad[3] := 0X;
    Check(~B.Put(t, bad, 1), "reject surrogate");
    bad[0] := 0F4X; bad[1] := 90X; bad[2] := 80X; bad[3] := 80X;
    Check(~B.Put(t, bad, 1), "reject out of Unicode");
    bad[0] := 0E2X; bad[1] := 0X;
    Check(~B.Put(t, bad, 1), "reject truncated UTF8");
    FOR i := 0 TO B.MaxKey DO long[i] := "x" END; long[B.MaxKey + 1] := 0X;
    Check(~B.Put(t, long, 1), "reject long key"); long[B.MaxKey] := 0X;
    min := ROR(1, 1);
    Check(B.Put(t, long, min), "maximum key and minimum INTEGER");
    Reopen; Check(B.Get(t, long, v) & (v = min), "minimum INTEGER persisted");
    Check(B.Put(t, long, -(min + 1)), "maximum INTEGER");
    Reopen; Check(B.Get(t, long, v) & (v = -(min + 1)), "maximum INTEGER persisted");
    Check(B.Remove(t, long), "remove maximum key");
    bad[0] := "a"; bad[1] := "b"; bad[2] := "c"; bad[3] := "d";
    Check(B.Put(t, bad, 42), "unterminated array"); Check(B.Get(t, "abcd", v) & (v = 42), "unterminated lookup");
    Check(B.Remove(t, "abcd"), "remove unterminated");
    (* Multiplication by a coprime number gives an unordered permutation. *)
    FOR j := 0 TO N - 1 DO
        i := j * 7919 MOD N; Key(i); expected[i] := i * 3 - 9000; live[i] := TRUE;
        Check(B.Put(t, key, expected[i]), "insert permutation")
    END;
    Reopen; Verify; Snapshot("filled.db"); Out.StringLn("insert/reopen/scan OK");
    Check(B.Seek(t, "k00042", c), "lower bound");
    Check(~B.Next(t, c, tiny, v), "small buffer"); Check(B.Error(t) = B.BufferSmall, "small buffer status");
    Check(B.Next(t, c, got, v) & (got = "k00042"), "small buffer did not advance");
    Check(B.Seek(t, "k00042x", c), "between keys");
    Check(B.Next(t, c, got, v) & (got = "k00043"), "lower bound successor");
    Check(B.Put(t, "k00043", 55), "update"); expected[43] := 55;
    Check(~B.Next(t, c, got, v), "stale cursor"); Check(B.Error(t) = B.Stale, "stale status");
    Check(B.Create(other, "other.db", TRUE, O.English, O.EnglishID), "second tree"); Check(B.Put(other, "independent", 123), "second put");
    Check(B.Close(other), "second close");
    FOR i := 0 TO N - 1 DO
        IF i MOD 3 # 0 THEN Key(i); Check(B.Remove(t, key), "delete sparse"); live[i] := FALSE END
    END;
    Reopen; Verify; Snapshot("sparse.db"); Out.StringLn("delete/rebalance OK");
    (* Deterministic churn checked against a small in-memory oracle. *)
    seed := 17;
    FOR round := 0 TO 2 DO
        FOR j := 0 TO N - 1 DO
            seed := (seed * 109 + 89) MOD 65521; i := seed MOD N; Key(i);
            IF seed MOD 3 = 0 THEN
                ok := B.Remove(t, key); Check(ok = live[i], "churn remove"); live[i] := FALSE
            ELSE
                expected[i] := -seed; Check(B.Put(t, key, expected[i]), "churn put"); live[i] := TRUE
            END
        END;
        Reopen; Verify
    END;
    Snapshot("churn.db"); Out.StringLn("churn OK");
    FOR i := N - 1 TO 0 BY -1 DO
        IF live[i] THEN Key(i); Check(B.Remove(t, key), "delete all"); live[i] := FALSE END
    END;
    Reopen; Verify; Snapshot("empty.db");
    Check(B.Close(t), "close empty");
    Check(F.Reset(file, "tree.db"), "file size open"); size := F.Size(file); F.Close(file);
    Check(B.Open(t, "tree.db", TRUE, O.English, O.EnglishID), "open for reuse");
    FOR i := 0 TO 1999 DO Key(i); Check(B.Put(t, key, i), "reuse pages") END;
    Check(B.Close(t), "final close");
    Check(F.Reset(file, "tree.db"), "file size reopen"); n := F.Size(file); F.Close(file);
    Check(n = size, "free pages reused without file growth");
    Check(B.Close(t), "double close");
    Out.StringLn("BpTrees OK")
END Run;

END BPTTest.
