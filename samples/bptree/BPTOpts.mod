MODULE BPTOpts;

IMPORT B := BpTrees, O := BPTOrder, F := Files, Out;

CONST D = 2048; ReverseID = 1001;

VAR t: B.BpTree; c: B.Cursor;
    key, got: ARRAY B.MaxKey + 1 OF CHAR;
    alive: ARRAY D OF BOOLEAN;
    value, total: INTEGER;

PROCEDURE Check(ok: BOOLEAN; label: ARRAY OF CHAR);
BEGIN
    IF ~ok THEN
        Out.String("FAIL: "); Out.String(label); Out.String(" error="); Out.Int(B.Error(t), 0); Out.Ln;
        ASSERT(FALSE)
    END
END Check;

(* A caller-supplied comparator, not one selected inside BpTrees. *)
PROCEDURE Reverse(a, b: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN -O.English(a, b)
END Reverse;

PROCEDURE Key(i: INTEGER);
VAR j: INTEGER;
BEGIN
    key[0] := "k";
    FOR j := 4 TO 1 BY -1 DO key[j] := CHR(ORD("0") + i MOD 10); i := i DIV 10 END;
    key[5] := 0X
END Key;

PROCEDURE Reopen;
BEGIN
    Check(B.Close(t), "close duplicates");
    Check(B.Open(t, "dups.db", FALSE, O.EnglishNoCase, O.EnglishNoCaseID), "open duplicates")
END Reopen;

PROCEDURE Snapshot(name: ARRAY OF CHAR);
BEGIN
    Check(B.Close(t), "snapshot close"); Check(F.Copy("dups.db", name), "snapshot copy");
    Check(B.Open(t, "dups.db", FALSE, O.EnglishNoCase, O.EnglishNoCaseID), "snapshot open")
END Snapshot;

PROCEDURE VerifyGroup;
VAR i: INTEGER;
BEGIN
    Check(B.Seek(t, "aLpHa", c), "seek first duplicate");
    FOR i := 0 TO D - 1 DO
        IF alive[i] THEN
            Check(B.Next(t, c, got, value), "next duplicate");
            Check(O.EnglishNoCase(got, "alpha") = 0, "duplicate group");
            Check(value = i MOD 17, "stable duplicate order");
            IF ODD(i) THEN Check(got = "ALPHA", "original uppercase spelling")
            ELSE Check(got = "Alpha", "original title spelling") END
        END
    END;
    Check(B.Next(t, c, got, value), "after duplicates");
    Check((got = "Zulu") & (value = -2), "successor after duplicates");
    Check(~B.Next(t, c, got, value) & (B.Error(t) = B.End), "duplicate scan end");
    Check(B.Count(t) = total + 2, "duplicate count")
END VerifyGroup;

PROCEDURE Run*;
VAR i, j, v, first: INTEGER;
BEGIN
    B.Init(t);
    Check(O.UkrainianNoCase("ҐАНОК", "ґанок") = 0, "Ukrainian case");
    Check(O.Ukrainian("г", "ґ") < 0, "Ukrainian ghe");
    Check(O.Ukrainian("ґ", "д") < 0, "Ukrainian ghe next");
    Check(O.Ukrainian("е", "є") < 0, "Ukrainian ye");
    Check(O.Ukrainian("и", "і") < 0, "Ukrainian i");
    Check(O.Ukrainian("і", "ї") < 0, "Ukrainian yi");
    Check(O.Ukrainian("ї", "й") < 0, "Ukrainian short i");
    Check(O.Ukrainian("Київ", "київ") < 0, "Ukrainian case sensitive");
    Check(O.CzechNoCase("PŘÍLIŠ ŽLUŤOUČKÝ KŮŇ", "příliš žluťoučký kůň") = 0, "Czech case");
    Check(O.Czech("cz", "č") < 0, "Czech caron primary");
    Check(O.Czech("hz", "ch") < 0, "Czech contraction after h");
    Check(O.Czech("ch", "i") < 0, "Czech contraction before i");
    Check(O.CzechNoCase("CH", "ch") = 0, "Czech contraction folding");
    Check(O.Czech("CH", "Ch") < 0, "Czech contraction case");
    Check(O.Czech("Ch", "cH") < 0, "Czech mixed contraction case");
    Check(O.Czech("cH", "ch") < 0, "Czech lowercase contraction case");
    Check(O.Czech("áa", "ab") < 0, "accent secondary to whole word");
    Check(O.CzechNoCase("a", "á") # 0, "Czech accent distinguishes keys");
    Check(O.GermanNoCase("ÄÖÜẞ", "äöüß") = 0, "German case");
    Check(O.German("äb", "ac") < 0, "German dictionary umlaut");
    Check(O.GermanNoCase("a", "ä") # 0, "German accent distinguishes keys");
    Check(O.GermanNoCase("strasse", "straße") < 0, "German sharp s secondary");
    Check(O.German("straße", "strasz") < 0, "German sharp s expansion");
    Check(O.German("A", "a") < 0, "German case sensitive");
    Check(O.Czech("", "a") < 0, "language empty key");
    Check(B.Create(t, "uk.db", TRUE, O.UkrainianNoCase, O.UkrainianNoCaseID), "Ukrainian create");
    Check(B.Insert(t, "Київ", 42), "Ukrainian insert");
    Check(~B.Insert(t, "КИЇВ", 99) & (B.Error(t) = B.Duplicate), "Ukrainian unique");
    Check(B.Close(t), "Ukrainian close");
    Check(B.Open(t, "uk.db", TRUE, O.UkrainianNoCase, O.UkrainianNoCaseID), "Ukrainian reopen");
    Check(B.Get(t, "київ", value) & (value = 42), "Ukrainian lookup");
    Check(B.Close(t), "Ukrainian final close");
    Check(O.English("Z", "a") < 0, "case-sensitive ASCII order");
    Check(O.English("Apple", "apple") # 0, "case-sensitive equality");
    Check(O.EnglishNoCase("Apple", "aPpLe") = 0, "ASCII folding");
    Check(O.EnglishNoCase("apple", "Banana") < 0, "folded ordering");
    Check(O.EnglishNoCase("К", "к") # 0, "non-ASCII unchanged");
    Check(~B.Create(t, "nil.db", TRUE, NIL, O.EnglishID), "nil comparator");
    Check(B.Error(t) = B.BadOptions, "nil status");
    Check(~B.Create(t, "zero-id.db", TRUE, O.English, 0), "zero order ID");
    Check(B.Create(t, "case.db", TRUE, O.English, O.EnglishID), "sensitive create");
    Check(B.Insert(t, "Apple", 1), "insert first");
    Check(B.Insert(t, "apple", 2), "case distinct");
    Check(B.First(t, c), "first sensitive");
    Check(~B.Insert(t, "Apple", 99), "reject duplicate unique key");
    Check(B.Error(t) = B.Duplicate, "duplicate status");
    Check(B.Next(t, c, got, value) & (got = "Apple") & (value = 1), "rejected insert preserves cursor/value");
    Check(B.Put(t, "Apple", 3), "unique upsert");
    Check(B.Count(t) = 2, "unique count"); Check(B.Close(t), "sensitive close");

    Check(B.Create(t, "fold.db", TRUE, O.EnglishNoCase, O.EnglishNoCaseID), "fold create");
    Check(B.Insert(t, "Alpha", 1), "fold insert");
    Check(~B.Insert(t, "ALPHA", 2), "fold duplicate");
    Check(B.Put(t, "alpha", 3), "fold replace");
    Check(B.Get(t, "aLPHa", value) & (value = 3), "fold get");
    Check(B.First(t, c), "fold first");
    Check(B.Next(t, c, got, value) & (got = "Alpha"), "upsert preserves spelling");
    Check(B.Count(t) = 1, "fold unique count"); Check(B.Close(t), "fold close");
    Check(F.Copy("fold.db", "foldpre.db"), "before mismatch snapshot");
    Check(~B.Open(t, "fold.db", FALSE, O.EnglishNoCase, O.EnglishNoCaseID), "wrong uniqueness");
    Check(B.Error(t) = B.ConfigMismatch, "uniqueness mismatch status");
    Check(~B.Open(t, "fold.db", TRUE, O.English, O.EnglishID), "wrong collation");
    Check(B.Error(t) = B.ConfigMismatch, "collation mismatch status");
    Check(F.Copy("fold.db", "foldpost.db"), "after mismatch snapshot");
    Check(B.Open(t, "fold.db", TRUE, O.EnglishNoCase, O.EnglishNoCaseID), "correct reopen after rejection");
    Check(B.Get(t, "ALPHA", value) & (value = 3), "fold reopen value"); Check(B.Close(t), "fold reclose");

    Check(B.Create(t, "dups.db", FALSE, O.EnglishNoCase, O.EnglishNoCaseID), "nonunique create");
    Check(B.Put(t, "aardvark", -1), "before group"); Check(B.Put(t, "Zulu", -2), "after group");
    FOR i := 0 TO D - 1 DO
        IF ODD(i) THEN key := "ALPHA" ELSE key := "Alpha" END;
        Check(B.Insert(t, key, i MOD 17), "insert duplicate"); alive[i] := TRUE
    END;
    total := D; Reopen; VerifyGroup; Snapshot("dupfull.db");
    Check(B.Get(t, "ALPHA", value) & (value = 0), "get oldest duplicate");
    Check(B.RemoveValue(t, "alpha", 8), "remove one exact value"); alive[8] := FALSE; DEC(total);
    Check(~B.RemoveValue(t, "alpha", 99), "missing value");
    Check(B.Error(t) = B.NotFound, "missing value status");
    Check(B.Remove(t, "ALPHA"), "remove oldest"); alive[0] := FALSE; DEC(total);
    Check(B.Get(t, "alpha", value) & (value = 1), "new oldest");
    FOR j := 0 TO 799 DO
        v := j * 13 MOD 17; first := 0;
        WHILE (first < D) & (~alive[first] OR (first MOD 17 # v)) DO INC(first) END;
        Check(first < D, "oracle has pair");
        Check(B.RemoveValue(t, "aLpHa", v), "remove duplicate across pages");
        alive[first] := FALSE; DEC(total)
    END;
    Reopen; VerifyGroup; Snapshot("dupspars.db");
    Check(B.RemoveAll(t, "alpha") = total, "remove all duplicates"); total := 0;
    Check(B.RemoveAll(t, "alpha") = 0, "remove all absent");
    Check(B.Count(t) = 2, "neighbors survive");
    Reopen; Snapshot("dupempty.db");
    FOR i := 0 TO 99 DO Check(B.Put(t, "Alpha", 7), "put appends even identical pair") END;
    Reopen; Snapshot("dupreuse.db");
    Check(B.RemoveValue(t, "ALPHA", 7), "remove just one identical pair");
    Check(B.Count(t) = 101, "one identical pair removed");
    Check(B.RemoveAll(t, "alpha") = 99, "remove remaining identical pairs");
    Check(B.Close(t), "duplicates close");

    Check(B.Create(t, "reverse.db", FALSE, Reverse, ReverseID), "external comparator create");
    FOR i := 0 TO 999 DO Key(i); Check(B.Put(t, key, i), "reverse insert") END;
    Check(B.Close(t), "reverse close");
    Check(B.Open(t, "reverse.db", FALSE, Reverse, ReverseID), "reverse reopen");
    Check(B.First(t, c), "first independent of comparator");
    FOR i := 999 TO 0 BY -1 DO
        Key(i); Check(B.Next(t, c, got, value), "reverse next");
        Check((got = key) & (value = i), "reverse order")
    END;
    Check(~B.Next(t, c, got, value) & (B.Error(t) = B.End), "reverse end");
    Check(B.Seek(t, "k0500x", c), "reverse lower bound");
    Check(B.Next(t, c, got, value) & (got = "k0500"), "reverse bound value");
    FOR i := 100 TO 899 DO Key(i); Check(B.Remove(t, key), "reverse remove") END;
    Check(B.Close(t), "reverse final close");
    Out.StringLn("BpTrees options OK")
END Run;

END BPTOpts.
