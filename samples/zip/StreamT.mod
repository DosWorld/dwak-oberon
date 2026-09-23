MODULE StreamT;

IMPORT Z := Zip, F := Files, Out;

CONST
Size = 3 * 1024 * 1024 + 137;

TYPE
Memory = POINTER TO RECORD data: ARRAY Size OF BYTE END;

VAR
archive: Z.Archive; block, other: ARRAY 32768 OF BYTE;

PROCEDURE Check(ok: BOOLEAN; label: ARRAY OF CHAR);
BEGIN
    IF ~ok THEN Out.String("FAIL stream: "); Out.String(label);
        Out.String(" error="); Out.Int(Z.Error(archive), 0); Out.Ln; ASSERT(FALSE) END
END Check;

PROCEDURE MakeFile;
VAR f: F.File; left, n, j, seq, seed: INTEGER;
BEGIN
    Check(F.ReWrite(f, "large.bin"), "create large source");
    left := Size; seq := 0; seed := 13;
    WHILE left > 0 DO
        n := left; IF n > LEN(block) THEN n := LEN(block) END;
        FOR j := 0 TO n - 1 DO
            seed := (seed * 109 + 89) MOD 65521;
            IF seq MOD 4 = 0 THEN block[j] := j MOD 251
            ELSIF seq MOD 4 = 1 THEN block[j] := seed MOD 256
            ELSIF seq MOD 4 = 2 THEN block[j] := 65
            ELSE block[j] := (j DIV 257) MOD 256 END
        END;
        Check(F.BlockWrite(f, block, n) = n, "write large source"); DEC(left, n); INC(seq)
    END;
    F.Close(f); Check(F.Ok(f), "close large source")
END MakeFile;

PROCEDURE CompareFile(path: ARRAY OF CHAR);
VAR a, b: F.File; n, m, j: INTEGER;
BEGIN
    Check(F.Reset(a, "large.bin"), "reference open"); Check(F.Reset(b, path), "result open");
    Check(F.Size(b) = Size, "result size");
    REPEAT
        n := F.BlockRead(a, block, LEN(block)); m := F.BlockRead(b, other, LEN(other));
        Check(n = m, "chunk length");
        FOR j := 0 TO n - 1 DO Check(block[j] = other[j], "file contents") END
    UNTIL n = 0;
    F.Close(a); F.Close(b)
END CompareFile;

PROCEDURE CheckMemory(index: INTEGER);
VAR m: Memory; f: F.File; written, n, j, offset: INTEGER;
BEGIN
    NEW(m); Check(m # NIL, "allocate caller memory");
    Check(~Z.Extract(archive, index, block, written) & (Z.Error(archive) = Z.BufferSmall), "small memory buffer");
    Check(Z.ExtractMemory(archive, index, m.data, written), "large memory extraction");
    Check(written = Size, "memory size");
    Check(F.Reset(f, "large.bin"), "memory reference open"); offset := 0;
    REPEAT
        n := F.BlockRead(f, block, LEN(block));
        FOR j := 0 TO n - 1 DO Check(block[j] = m.data[offset + j], "memory contents") END;
        INC(offset, n)
    UNTIL n = 0;
    F.Close(f); DISPOSE(m)
END CheckMemory;

PROCEDURE MemoryWrite;
VAR m: Memory; f: F.File;
BEGIN
    NEW(m); Check(m # NIL, "memory source allocation");
    Check(F.Reset(f, "large.bin"), "memory input open");
    Check(F.BlockRead(f, m.data, Size) = Size, "memory input read"); F.Close(f);
    Check(Z.Create(archive, "memory.zip"), "memory writer create");
    Check(Z.AddMemory(archive, "stored.bin", m.data, Size, Z.Stored), "large stored memory add");
    Check(Z.AddMemory(archive, "deflate.bin", m.data, Size, Z.Deflated), "large compressed memory add");
    Check(Z.Close(archive), "memory writer close"); DISPOSE(m);
    Check(Z.Open(archive, "memory.zip"), "memory archive open"); CheckMemory(0); CheckMemory(1);
    Check(Z.ExtractFile(archive, 1, "outm.bin"), "memory archive file extraction"); CompareFile("outm.bin");
    Check(Z.Close(archive), "memory archive close")
END MemoryWrite;

PROCEDURE Run*;
VAR f: F.File; entry: Z.Entry; written: INTEGER;
BEGIN
    Z.Init(archive); MakeFile;
    Check(F.ReWrite(f, "zero.bin"), "empty source"); F.Close(f);
    Check(Z.Create(archive, "stream.zip"), "stream writer");
    Check(Z.AddFile(archive, "stored.bin", "large.bin", Z.Stored), "stored large add");
    Check(Z.AddFile(archive, "deflate.bin", "large.bin", Z.Deflated), "deflated large add");
    Check(Z.AddFile(archive, "zero.bin", "zero.bin", Z.Deflated), "empty stream add");
    Check(Z.Close(archive), "stream finalization");
    Check(Z.Open(archive, "stream.zip"), "large archive open");
    Check(Z.Count(archive) = 3, "large count");
    Check(Z.EntryAt(archive, 1, entry) & (entry.size = Size), "large metadata");
    Check(Z.ExtractFile(archive, 0, "out0.bin"), "stored large extraction"); CompareFile("out0.bin");
    Check(Z.ExtractFile(archive, 1, "out8.bin"), "deflated large extraction"); CompareFile("out8.bin");
    CheckMemory(0); CheckMemory(1);
    Check(Z.ExtractFile(archive, 2, "outz.bin"), "empty file extraction");
    Check(Z.Extract(archive, 2, block, written) & (written = 0), "empty memory extraction");
    Check(Z.Close(archive), "large reader close");
    IF F.FileExists("bigext.zip") THEN
        Check(Z.Open(archive, "bigext.zip"), "external large open");
        Check(Z.ExtractFile(archive, 0, "oute.bin"), "external large stream"); CompareFile("oute.bin");
        CheckMemory(0); Check(Z.Close(archive), "external large close");
        Out.StringLn("EXTERNAL LARGE ZIP OK")
    END;
    MemoryWrite; Out.StringLn("STREAM AND MEMORY TESTS OK")
END Run;

END StreamT.
