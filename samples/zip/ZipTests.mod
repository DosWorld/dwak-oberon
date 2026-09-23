MODULE ZipTests;

IMPORT StreamT, CodecT, ZipFmtT, D := Deflate, I := Inflate, C := CRC32, Z := Zip, F := Files, Out;

VAR src, packed, dst: ARRAY 100000 OF BYTE; n, m, j, k: INTEGER;
    longName: ARRAY 1024 OF CHAR;
    archive: Z.Archive; entry: Z.Entry; f: F.File;

PROCEDURE Check(ok: BOOLEAN; message: ARRAY OF CHAR);
BEGIN
    IF ~ok THEN Out.String("FAIL: "); Out.StringLn(message); ASSERT(FALSE) END
END Check;

PROCEDURE RoundTrip(len: INTEGER);
VAR j: INTEGER;
BEGIN
    Check(D.Compress(src, len, packed, LEN(packed), n) = D.OK, "compress");
    Check(I.Decompress(packed, n, dst, LEN(dst), m) = I.OK, "inflate");
    Check(m = len, "length");
    FOR j := 0 TO len - 1 DO Check(src[j] = dst[j], "content") END
END RoundTrip;

BEGIN
    FOR j := 0 TO 8 DO src[j] := ORD("1") + j END;
    Check(C.Of(src, 9) = -873187034, "CRC known vector");
    Check(C.Update(C.Update(0, src, 0, 4), src, 4, 5) = C.Of(src, 9), "CRC incremental");
    RoundTrip(0); RoundTrip(1); RoundTrip(2); RoundTrip(9);
    FOR j := 0 TO 69999 DO src[j] := j MOD 256 END; RoundTrip(70000);
    FOR j := 0 TO 69999 DO src[j] := 65 END; RoundTrip(70000);
    k := 7; FOR j := 0 TO 69999 DO k := (k * 109 + 89) MOD 65521; src[j] := k MOD 256 END;
    RoundTrip(70000);
    Check(D.Compress(src, 100, packed, 0, n) = D.OutputFull, "small compression buffer");
    Check(D.Compress(src, -1, packed, LEN(packed), n) = D.BadArgument, "negative source");
    Check(I.Decompress(packed, LEN(packed) + 1, dst, LEN(dst), m) = I.BadArgument, "inflate bounds");
    packed[0] := 7;
    Check(I.Decompress(packed, 1, dst, LEN(dst), m) = I.BadData, "reserved block");
    Out.StringLn("CODEC TESTS OK"); CodecT.Run;
    Z.Init(archive);
    Check(F.ReWrite(f, "source.bin"), "source create");
    Check(F.BlockWrite(f, src, 70000) = 70000, "source write"); F.Close(f); Check(F.Ok(f), "source close");
    Check(Z.Create(archive, "written.zip"), "archive create");
    Check(Z.Add(archive, "empty", src, 0, Z.Deflated), "add empty");
    Check(Z.Add(archive, "stored.bin", src, 70000, Z.Stored), "add stored");
    longName := "folder/дані.bin";
    Check(Z.AddFile(archive, longName, "source.bin", Z.Deflated), "add compressed file");
    Check(~Z.Add(archive, "../escape", src, 1, Z.Stored), "reject unsafe name");
    Check(Z.Close(archive), "archive finalize");
    Check(~Z.Create(archive, "written.zip") & (Z.Error(archive) = Z.Exists), "refuse overwrite");
    Check(Z.Open(archive, "written.zip"), "archive open");
    Check(Z.Count(archive) = 3, "entry count");
    Check(Z.EntryAt(archive, 2, entry) & (entry.name = "folder/дані.bin"), "list entry");
    Check(Z.Extract(archive, 0, dst, m) & (m = 0), "extract empty");
    FOR k := 1 TO 2 DO
        Check(Z.Extract(archive, k, dst, m) & (m = 70000), "extract entry");
        FOR j := 0 TO m - 1 DO Check(dst[j] = src[j], "ZIP content") END
    END;
    Check(Z.ExtractFile(archive, 2, "out.bin"), "extract file");
    Check(~Z.ExtractFile(archive, 2, "out.bin") & (Z.Error(archive) = Z.Exists), "extract refuses overwrite");
    Check(Z.Close(archive), "archive close");
    Check(Z.Create(archive, "empty.zip"), "empty archive create"); Check(Z.Close(archive), "empty archive close");
    Check(Z.Open(archive, "empty.zip") & (Z.Count(archive) = 0), "empty archive read"); Check(Z.Close(archive), "empty reader close");
    IF F.FileExists("external.zip") THEN
        Check(Z.Open(archive, "external.zip"), "external open");
        FOR k := 0 TO Z.Count(archive) - 1 DO
            Check(Z.Extract(archive, k, dst, m), "external extract");
            Check(m = 70000, "external length");
            FOR j := 0 TO m - 1 DO Check(dst[j] = src[j], "external content") END
        END;
        Check(Z.Close(archive), "external close"); Out.StringLn("EXTERNAL ZIP OK")
    END;
    ZipFmtT.Run; StreamT.Run; Out.StringLn("ZIP ALL TESTS OK")

END ZipTests.
