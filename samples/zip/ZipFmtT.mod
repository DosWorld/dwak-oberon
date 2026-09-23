(* Independently constructed ZIP records: no writer-under-test for fixtures. *)
MODULE ZipFmtT;

IMPORT Z := Zip, F := Files, Out;

VAR bytes: ARRAY 1024 OF BYTE; output: ARRAY 8 OF BYTE;
    position: INTEGER; archive: Z.Archive;

PROCEDURE Check(ok: BOOLEAN; label: ARRAY OF CHAR);
BEGIN
    IF ~ok THEN Out.String("FAIL ZIP format: "); Out.StringLn(label); ASSERT(FALSE) END
END Check;

PROCEDURE Number(value, count: INTEGER);
VAR j: INTEGER;
BEGIN
    FOR j := 0 TO count - 1 DO bytes[position] := value MOD 256; INC(position); value := value DIV 256 END
END Number;

PROCEDURE Fixture(descriptor, damage: INTEGER);
VAR f: F.File; flags, crc, version, size, directory, dirSize, n: INTEGER;
BEGIN
    position := 0; flags := 2048; crc := 352441C2H; version := 20; size := 3;
    IF descriptor # 0 THEN INC(flags, 8) END;
    IF damage = 1 THEN INC(crc) END;
    IF damage = 4 THEN INC(flags) END;
    IF damage = 5 THEN version := 45 END;
    IF damage = 6 THEN size := 1048577 END;
    Number(04034B50H, 4); Number(version, 2); Number(flags, 2); Number(0, 2); Number(0, 2); Number(33, 2);
    IF descriptor # 0 THEN Number(0, 4); Number(0, 4); Number(0, 4)
    ELSE Number(crc, 4); IF damage = 8 THEN Number(4, 4) ELSE Number(3, 4) END; Number(size, 4) END;
    Number(1, 2); Number(4, 2); (* Four bytes of local extra: empty unknown TLV. *)
    IF damage = 2 THEN Number(98, 1) ELSE Number(97, 1) END;
    Number(1234, 2); Number(0, 2);
    Number(97, 1); Number(98, 1); Number(99, 1);
    IF descriptor # 0 THEN
        IF descriptor = 2 THEN Number(08074B50H, 4) END;
        IF damage = 9 THEN Number(crc + 1, 4) ELSE Number(crc, 4) END;
        Number(3, 4); Number(3, 4)
    END;
    directory := position;
    Number(02014B50H, 4); Number(20, 2); Number(version, 2); Number(flags, 2); Number(0, 2);
    Number(0, 2); Number(33, 2); Number(crc, 4); Number(3, 4); Number(size, 4);
    Number(1, 2); Number(4, 2); Number(1, 2); Number(0, 2); Number(0, 2); Number(0, 4); Number(0, 4);
    IF damage = 10 THEN Number(255, 1) ELSE Number(97, 1) END;
    Number(1234, 2); Number(0, 2); Number(120, 1); dirSize := position - directory;
    Number(06054B50H, 4); Number(0, 2); Number(0, 2); Number(1, 2); Number(1, 2);
    Number(dirSize, 4);
    IF damage = 3 THEN Number(directory + 1, 4) ELSE Number(directory, 4) END;
    Number(3, 2); Number(122, 1); Number(105, 1); Number(112, 1);
    n := position; IF damage = 7 THEN DEC(n) END;
    Check(F.ReWrite(f, "format.zip"), "fixture create");
    Check(F.BlockWrite(f, bytes, n) = n, "fixture write"); F.Close(f); Check(F.Ok(f), "fixture close")
END Fixture;

PROCEDURE Run*;
VAR j, n, expected, descriptor: INTEGER; ok: BOOLEAN;
    tiny: ARRAY 2 OF BYTE;
BEGIN
    Z.Init(archive);
    FOR descriptor := 0 TO 2 DO
        Fixture(descriptor, 0);
        Check(Z.Open(archive, "format.zip"), "open extras/comments/descriptor");
        Check(~Z.Extract(archive, 0, tiny, n) & (Z.Error(archive) = Z.BufferSmall), "small output");
        Check(Z.Extract(archive, 0, output, n), "extract descriptor");
        Check((n = 3) & (output[0] = 97) & (output[2] = 99), "fixture contents");
        Check(Z.ExtractFile(archive, 0, "fmtout.bin"), "descriptor file extraction");
        Check(F.Delete("fmtout.bin"), "remove test output");
        Check(Z.Close(archive), "valid close")
    END;
    FOR j := 1 TO 10 DO
        IF j = 9 THEN descriptor := 2 ELSE descriptor := 0 END;
        Fixture(descriptor, j); expected := Z.BadData;
        IF j = 1 THEN expected := Z.CRCError
        ELSIF (j = 4) OR (j = 5) THEN expected := Z.Unsupported
        END;
        ok := Z.Open(archive, "format.zip");
        IF ok THEN ok := Z.Extract(archive, 0, output, n) END;
        Check(~ok & (Z.Error(archive) = expected), "reject corrupt/unsupported ZIP");
        ok := Z.Close(archive);
        ok := Z.Open(archive, "format.zip");
        IF ok THEN ok := Z.ExtractFile(archive, 0, "badout.bin") END;
        Check(~ok & (Z.Error(archive) = expected), "reject streaming corruption");
        Check(~F.FileExists("badout.bin"), "failed output removed");
        ok := Z.Close(archive)
    END;
    Out.StringLn("ZIP FORMAT/CORRUPTION TESTS OK")
END Run;

END ZipFmtT.
