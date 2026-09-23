(*
   BSD 2-Clause License
   Copyright (c) 2026-, DosWorld

   Independent classic ZIP container. Single owner; no ZIP64/encryption.
   Init once, do not copy Archive, always check Close.
*)
MODULE Zip;

IMPORT F := Files, C := CRC32, D := Deflate, I := Inflate;

CONST
    OK* = 0; IOError* = 1; BadData* = 2; Unsupported* = 3;
    Limit* = 4; BadArgument* = 5; Closed* = 6; Exists* = 7;
    BufferSmall* = 8; CRCError* = 9; NoMemory* = 10; WrongMode* = 11;
    Stored* = 0; Deflated* = 8;
    MaxEntry* = 2147483647; MaxEntries* = 1024; MaxName* = 255;
    MaxFile = 2147483647;

TYPE
    Entry* = RECORD
        name*: ARRAY MaxName + 1 OF CHAR;
        size*, packed*, method*, crc*: INTEGER;
        flags, offset: INTEGER
    END;
    Directory = POINTER TO RECORD entries: ARRAY MaxEntries OF Entry END;
    Chunk = POINTER TO RECORD data: ARRAY 32768 OF BYTE END;
    Archive* = RECORD
        file: F.File;
        entries: Directory;
        count, error, directoryOffset, length: INTEGER;
        opened, writing, failed: BOOLEAN
    END;

PROCEDURE Init*(VAR z: Archive);
BEGIN
    z.entries := NIL; z.count := 0; z.error := Closed;
    z.opened := FALSE; z.writing := FALSE; z.failed := FALSE
END Init;

PROCEDURE Error*(VAR z: Archive): INTEGER;
BEGIN
    RETURN z.error
END Error;

PROCEDURE Count*(VAR z: Archive): INTEGER;
BEGIN
    RETURN z.count
END Count;

PROCEDURE Fail(VAR z: Archive; error: INTEGER);
BEGIN z.error := error; z.failed := TRUE END Fail;

PROCEDURE Ready(VAR z: Archive; writing: BOOLEAN): BOOLEAN;
BEGIN
    IF ~z.opened THEN z.error := Closed
    ELSIF z.writing # writing THEN z.error := WrongMode
    ELSIF ~z.failed THEN z.error := OK END;
    RETURN z.opened & (z.writing = writing) & ~z.failed
END Ready;

PROCEDURE Length(s: ARRAY OF CHAR): INTEGER;
VAR n: INTEGER;
BEGIN
    n := 0; WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END;
    RETURN n
END Length;

(* UTF-8 names on write; legacy unflagged byte names on read. Relative paths
   only. Extraction takes a caller-specified path, never joins an entry name. *)
PROCEDURE ValidName(s: ARRAY OF CHAR; utf8: BOOLEAN): BOOLEAN;
VAR i, n, start, x, more, code, minimum, b: INTEGER; ok: BOOLEAN;
BEGIN
    n := Length(s); ok := (n > 0) & (n <= MaxName) & (n < LEN(s));
    i := 0; start := 0;
    WHILE ok & (i < n) DO
        x := ORD(s[i]);
        IF (x < 32) OR (x = 127) OR (s[i] = "\") OR (s[i] = ":") THEN ok := FALSE END;
        IF s[i] = "/" THEN
            IF (i = start) OR ((i - start = 1) & (s[start] = ".")) OR
               ((i - start = 2) & (s[start] = ".") & (s[start + 1] = ".")) THEN ok := FALSE END;
            start := i + 1
        END;
        INC(i);
        IF utf8 & (x >= 128) THEN
            more := 0; minimum := 0; code := 0;
            IF (x >= 194) & (x <= 223) THEN more := 1; minimum := 128; code := x MOD 32
            ELSIF (x >= 224) & (x <= 239) THEN more := 2; minimum := 2048; code := x MOD 16
            ELSIF (x >= 240) & (x <= 244) THEN more := 3; minimum := 65536; code := x MOD 8
            ELSE ok := FALSE END;
            WHILE ok & (more > 0) DO
                IF i >= n THEN ok := FALSE
                ELSE b := ORD(s[i]); INC(i);
                    IF (b < 128) OR (b > 191) THEN ok := FALSE
                    ELSE code := code * 64 + b - 128; DEC(more) END
                END
            END;
            IF (code < minimum) OR (code > 1114111) OR ((code >= 55296) & (code <= 57343)) THEN ok := FALSE END
        END
    END;
    IF ((n - start = 1) & (s[start] = ".")) OR
       ((n - start = 2) & (s[start] = ".") & (s[start + 1] = ".")) THEN ok := FALSE END;
    RETURN ok
END ValidName;

PROCEDURE Get(VAR z: Archive; bytes: INTEGER): INTEGER;
VAR b: BYTE; i, value: INTEGER;
BEGIN
    value := 0;
    FOR i := 0 TO bytes - 1 DO
        IF z.error = OK THEN
            IF ~F.ReadByte(z.file, b) THEN Fail(z, BadData)
            ELSE
                IF (i = 3) & (b >= 128) THEN INC(value, (b - 256) * 16777216)
                ELSE INC(value, LSL(b, i * 8)) END
            END
        END
    END;
    RETURN value
END Get;

PROCEDURE Put(VAR z: Archive; value, bytes: INTEGER);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO bytes - 1 DO
        IF z.error = OK THEN
            IF F.WriteByte(z.file, value MOD 256) # 1 THEN Fail(z, IOError) END;
            value := value DIV 256
        END
    END
END Put;

PROCEDURE WriteName(VAR z: Archive; name: ARRAY OF CHAR);
BEGIN
    IF F.Write(z.file, name) # Length(name) THEN Fail(z, IOError) END
END WriteName;

PROCEDURE ReadName(VAR z: Archive; n: INTEGER; VAR name: ARRAY OF CHAR);
VAR i: INTEGER; b: BYTE;
BEGIN
    i := 0;
    IF (n < 1) OR (n > MaxName) THEN Fail(z, Limit)
    ELSE
        WHILE (i < n) & (z.error = OK) DO
            IF ~F.ReadByte(z.file, b) THEN Fail(z, BadData)
            ELSIF b = 0 THEN Fail(z, BadData)
            ELSE name[i] := CHR(b); INC(i) END
        END
    END;
    name[i] := 0X
END ReadName;

PROCEDURE Allocate(VAR z: Archive): BOOLEAN;
BEGIN
    NEW(z.entries);
    IF z.entries = NIL THEN z.error := NoMemory END;
    RETURN z.error = OK
END Allocate;

PROCEDURE Release(VAR z: Archive);
BEGIN
    IF z.entries # NIL THEN DISPOSE(z.entries); z.entries := NIL END
END Release;

PROCEDURE Create*(VAR z: Archive; path: ARRAY OF CHAR): BOOLEAN;
BEGIN
    z.error := OK;
    IF z.opened THEN z.error := WrongMode
    ELSIF (Length(path) = 0) OR (Length(path) > 255) OR (Length(path) = LEN(path)) THEN z.error := BadArgument
    ELSIF F.FileExists(path) THEN z.error := Exists
    ELSIF Allocate(z) THEN
        IF ~F.ReWrite(z.file, path) THEN z.error := IOError
        ELSE z.opened := TRUE; z.writing := TRUE; z.failed := FALSE; z.count := 0 END
    END;
    IF ~z.opened THEN Release(z) END;
    RETURN z.error = OK
END Create;

PROCEDURE Supported(VAR e: Entry): BOOLEAN;
BEGIN
    RETURN ((e.method = Stored) OR (e.method = Deflated)) &
        (ORD(BITS(e.flags) * BITS(0FFFFH - 080EH)) = 0) &
        ((e.method = Deflated) OR (e.flags MOD 8 = 0))
END Supported;

PROCEDURE Open*(VAR z: Archive; path: ARRAY OF CHAR): BOOLEAN;
VAR p, lower, found, comment, disk, disk2, n, total, size, offset, endCD,
    signature, version, extra, nameLen, skip, unused: INTEGER;
    e: Entry;
BEGIN
    z.error := OK;
    IF z.opened THEN z.error := WrongMode
    ELSIF (Length(path) = 0) OR (Length(path) > 255) OR (Length(path) = LEN(path)) THEN z.error := BadArgument
    ELSIF Allocate(z) THEN
        IF ~F.Reset(z.file, path) THEN z.error := IOError
        ELSE
            z.opened := TRUE; z.writing := FALSE; z.failed := FALSE; z.count := 0;
            z.length := F.Size(z.file); found := -1;
            IF z.length > MaxFile THEN Fail(z, Limit) END;
            p := z.length - 22; lower := z.length - 65557; IF lower < 0 THEN lower := 0 END;
            WHILE (p >= lower) & (found < 0) & (z.error = OK) DO
                F.Seek(z.file, p); signature := Get(z, 4);
                IF signature = 06054B50H THEN
                    F.Seek(z.file, p + 20); comment := Get(z, 2);
                    IF comment = z.length - p - 22 THEN found := p END
                END;
                DEC(p)
            END;
            IF z.error # OK THEN (* Preserve the earlier size/read error. *)
            ELSIF found < 0 THEN Fail(z, BadData)
            ELSE
                F.Seek(z.file, found + 4);
                disk := Get(z, 2); disk2 := Get(z, 2); n := Get(z, 2); total := Get(z, 2);
                size := Get(z, 4); offset := Get(z, 4);
                IF (disk # 0) OR (disk2 # 0) OR (n # total) OR (total = 65535) OR
                   (size < 0) OR (offset < 0) THEN Fail(z, Unsupported)
                ELSIF total > MaxEntries THEN Fail(z, Limit)
                ELSIF (offset > found) OR (size # found - offset) THEN Fail(z, BadData)
                ELSE
                    z.directoryOffset := offset; endCD := found; F.Seek(z.file, offset);
                    WHILE (z.count < total) & (z.error = OK) DO
                        IF endCD - F.Position(z.file) < 46 THEN Fail(z, BadData) END;
                        signature := Get(z, 4); unused := Get(z, 2); version := Get(z, 2);
                        e.flags := Get(z, 2); e.method := Get(z, 2); unused := Get(z, 4);
                        e.crc := Get(z, 4); e.packed := Get(z, 4); e.size := Get(z, 4);
                        nameLen := Get(z, 2); extra := Get(z, 2); comment := Get(z, 2);
                        disk := Get(z, 2); unused := Get(z, 2); unused := Get(z, 4); e.offset := Get(z, 4);
                        IF z.error = OK THEN
                            IF signature # 02014B50H THEN Fail(z, BadData)
                            ELSIF (version > 20) OR (disk # 0) OR ~Supported(e) OR
                                  (e.size < 0) OR (e.packed < 0) OR (e.offset < 0) THEN Fail(z, Unsupported)
                            ELSIF (e.offset > offset) OR (offset - e.offset < 30) OR
                                  (nameLen + extra + comment > endCD - F.Position(z.file)) OR
                                  ((e.method = Stored) & (e.size # e.packed)) THEN Fail(z, BadData)
                            ELSE
                                ReadName(z, nameLen, e.name);
                                IF ~ValidName(e.name, e.flags DIV 2048 MOD 2 # 0) THEN Fail(z, BadData) END;
                                IF z.error = OK THEN
                                    skip := F.Position(z.file) + extra + comment; F.Seek(z.file, skip);
                                    z.entries.entries[z.count] := e; INC(z.count)
                                END
                            END
                        END
                    END;
                    IF (z.error = OK) & (F.Position(z.file) # endCD) THEN Fail(z, BadData) END
                END
            END;
            IF z.error # OK THEN F.Close(z.file); z.opened := FALSE END
        END
    END;
    IF ~z.opened THEN Release(z); z.count := 0 END;
    RETURN z.error = OK
END Open;

PROCEDURE EntryAt*(VAR z: Archive; index: INTEGER; VAR entry: Entry): BOOLEAN;
BEGIN
    IF Ready(z, FALSE) THEN
        IF (index < 0) OR (index >= z.count) THEN z.error := BadArgument
        ELSE entry := z.entries.entries[index] END
    END;
    RETURN z.error = OK
END EntryAt;

PROCEDURE StartEntry(VAR z: Archive; name: ARRAY OF CHAR; size, method: INTEGER;
                     VAR e: Entry; VAR budget: INTEGER);
VAR j: INTEGER;
BEGIN
    e.offset := F.Position(z.file);
    budget := MaxFile - e.offset - 30 - Length(name) - 16 - (z.count + 1) * (46 + MaxName) - 22;
    IF (size < 0) OR (size > MaxEntry) OR (budget < 0) OR ((method = Stored) & (size > budget)) THEN z.error := Limit
    ELSE
        FOR j := 0 TO Length(name) DO e.name[j] := name[j] END;
        e.method := method; e.size := size; e.flags := 2056; e.packed := 0; e.crc := 0;
        Put(z, 04034B50H, 4); Put(z, 20, 2); Put(z, e.flags, 2); Put(z, method, 2);
        Put(z, 0, 2); Put(z, 33, 2); Put(z, 0, 4); Put(z, 0, 4); Put(z, 0, 4);
        Put(z, Length(name), 2); Put(z, 0, 2); WriteName(z, name)
    END
END StartEntry;

PROCEDURE FinishEntry(VAR z: Archive; VAR e: Entry);
BEGIN
    IF z.error = OK THEN
        Put(z, 08074B50H, 4); Put(z, e.crc, 4); Put(z, e.packed, 4); Put(z, e.size, 4);
        IF ~F.Ok(z.file) THEN Fail(z, IOError) END;
        IF z.error = OK THEN z.entries.entries[z.count] := e; INC(z.count) END
    END
END FinishEntry;

PROCEDURE CompressStatus(VAR z: Archive; status: INTEGER);
BEGIN
    IF status = D.NoMemory THEN Fail(z, NoMemory)
    ELSIF status = D.OutputFull THEN Fail(z, Limit)
    ELSIF status # D.OK THEN Fail(z, IOError) END
END CompressStatus;

PROCEDURE Add*(VAR z: Archive; name: ARRAY OF CHAR; VAR data: ARRAY OF BYTE;
               length, method: INTEGER): BOOLEAN;
VAR e: Entry; budget, status: INTEGER;
BEGIN
    IF Ready(z, TRUE) THEN
        IF ~ValidName(name, TRUE) OR (length < 0) OR (length > LEN(data)) THEN z.error := BadArgument
        ELSIF (method # Stored) & (method # Deflated) THEN z.error := Unsupported
        ELSIF z.count = MaxEntries THEN z.error := Limit
        ELSE
            StartEntry(z, name, length, method, e, budget);
            IF z.error = OK THEN
                IF method = Stored THEN
                    e.crc := C.Of(data, length); e.packed := length;
                    IF F.BlockWrite(z.file, data, length) # length THEN Fail(z, IOError) END
                ELSE
                    status := D.CompressToFile(data, length, z.file, budget, e.packed, e.crc);
                    CompressStatus(z, status)
                END;
                FinishEntry(z, e)
            END
        END
    END;
    RETURN z.error = OK
END Add;

(* Explicit memory-source name; Add remains a compatible shorthand. *)
PROCEDURE AddMemory*(VAR z: Archive; name: ARRAY OF CHAR; VAR data: ARRAY OF BYTE;
                     length, method: INTEGER): BOOLEAN;
BEGIN
    RETURN Add(z, name, data, length, method)
END AddMemory;

(* Validate local framing, position at entry payload. Shared by both extraction APIs. *)
PROCEDURE Locate(VAR z: Archive; VAR e: Entry);
VAR name: ARRAY MaxName + 1 OF CHAR;
    signature, version, flags, method, crc, packed, size, n, extra, unused, pos: INTEGER;
BEGIN
    F.Seek(z.file, e.offset); signature := Get(z, 4); version := Get(z, 2);
    flags := Get(z, 2); method := Get(z, 2); unused := Get(z, 4);
    crc := Get(z, 4); packed := Get(z, 4); size := Get(z, 4); n := Get(z, 2); extra := Get(z, 2);
    IF z.error = OK THEN
        IF (signature # 04034B50H) OR (version > 20) OR (flags # e.flags) OR (method # e.method) OR
           (n + extra > z.directoryOffset - e.offset - 30) THEN Fail(z, BadData)
        ELSIF (flags DIV 8 MOD 2 = 0) & ((crc # e.crc) OR (packed # e.packed) OR (size # e.size)) THEN Fail(z, BadData)
        ELSE
            ReadName(z, n, name);
            IF (z.error = OK) & (name # e.name) THEN Fail(z, BadData) END;
            pos := e.offset + 30 + n + extra;
            IF (z.error = OK) & (e.packed > z.directoryOffset - pos) THEN Fail(z, BadData) END;
            IF z.error = OK THEN F.Seek(z.file, pos) END
        END
    END
END Locate;

PROCEDURE Descriptor(VAR z: Archive; VAR e: Entry);
VAR crc, packed, size: INTEGER;
BEGIN
    IF (z.error = OK) & (e.flags DIV 8 MOD 2 # 0) THEN
        IF z.directoryOffset - F.Position(z.file) < 12 THEN Fail(z, BadData)
        ELSE
            crc := Get(z, 4); packed := Get(z, 4); size := Get(z, 4);
            IF (crc = 08074B50H) & ((crc # e.crc) OR (packed # e.packed) OR (size # e.size)) THEN
                IF z.directoryOffset - F.Position(z.file) < 4 THEN Fail(z, BadData) END;
                crc := packed; packed := size; size := Get(z, 4)
            END;
            IF (z.error = OK) & ((crc # e.crc) OR (packed # e.packed) OR (size # e.size)) THEN Fail(z, BadData) END
        END
    END
END Descriptor;

PROCEDURE Extract*(VAR z: Archive; index: INTEGER; VAR data: ARRAY OF BYTE;
                   VAR written: INTEGER): BOOLEAN;
VAR e: Entry; status, consumed: INTEGER;
BEGIN
    written := 0;
    IF Ready(z, FALSE) THEN
        IF (index < 0) OR (index >= z.count) THEN z.error := BadArgument
        ELSE
            e := z.entries.entries[index];
            IF LEN(data) < e.size THEN z.error := BufferSmall
            ELSE
                Locate(z, e);
                IF z.error = OK THEN
                    IF e.method = Stored THEN
                        written := F.BlockRead(z.file, data, e.size);
                        IF written # e.size THEN Fail(z, IOError) END
                    ELSE
                        status := I.DecompressToMemory(z.file, e.packed, data, e.size, written, consumed);
                        IF status = I.NoMemory THEN z.error := NoMemory
                        ELSIF (status # I.OK) OR (written # e.size) OR (consumed # e.packed) THEN Fail(z, BadData) END
                    END;
                    IF (z.error = OK) & (C.Of(data, written) # e.crc) THEN Fail(z, CRCError) END;
                    Descriptor(z, e)
                END
            END
        END
    END;
    IF z.error # OK THEN written := 0 END;
    RETURN z.error = OK
END Extract;

PROCEDURE ExtractMemory*(VAR z: Archive; index: INTEGER; VAR data: ARRAY OF BYTE;
                         VAR written: INTEGER): BOOLEAN;
BEGIN
    RETURN Extract(z, index, data, written)
END ExtractMemory;

(* Incremental stored copy with CRC. Both files stay owned by the caller. *)
PROCEDURE CopyStored(VAR input, output: F.File; size: INTEGER; VAR crc: INTEGER): BOOLEAN;
VAR b: Chunk; left, n: INTEGER; ok: BOOLEAN;
BEGIN
    NEW(b); ok := b # NIL; left := size; crc := 0;
    IF ok THEN
        WHILE ok & (left > 0) DO
            n := left; IF n > 32768 THEN n := 32768 END;
            IF F.BlockRead(input, b.data, n) # n THEN ok := FALSE
            ELSIF F.BlockWrite(output, b.data, n) # n THEN ok := FALSE
            ELSE crc := C.Update(crc, b.data, 0, n); DEC(left, n) END
        END;
        DISPOSE(b)
    END;
    RETURN ok & F.Ok(output)
END CopyStored;

PROCEDURE AddFile*(VAR z: Archive; name, path: ARRAY OF CHAR; method: INTEGER): BOOLEAN;
VAR f: F.File; e: Entry; n, budget, status: INTEGER;
BEGIN
    IF Ready(z, TRUE) THEN
        IF ~ValidName(name, TRUE) OR (Length(path) = 0) OR (Length(path) > 255) OR
           (Length(path) = LEN(path)) THEN z.error := BadArgument
        ELSIF (method # Stored) & (method # Deflated) THEN z.error := Unsupported
        ELSIF z.count = MaxEntries THEN z.error := Limit
        ELSIF ~F.Reset(f, path) THEN z.error := IOError
        ELSE
            n := F.Size(f); StartEntry(z, name, n, method, e, budget);
            IF z.error = OK THEN
                IF method = Stored THEN
                    IF ~CopyStored(f, z.file, n, e.crc) THEN Fail(z, IOError) ELSE e.packed := n END
                ELSE
                    status := D.CompressFile(f, z.file, n, budget, e.packed, e.crc);
                    CompressStatus(z, status)
                END;
                FinishEntry(z, e)
            END;
            F.Close(f)
        END
    END;
    RETURN z.error = OK
END AddFile;

PROCEDURE ExtractFile*(VAR z: Archive; index: INTEGER; path: ARRAY OF CHAR): BOOLEAN;
VAR f: F.File; e: Entry; written, consumed, crc, status: INTEGER; deleted: BOOLEAN;
BEGIN
    IF Ready(z, FALSE) THEN
        IF (index < 0) OR (index >= z.count) OR (Length(path) = 0) OR
           (Length(path) > 255) OR (Length(path) = LEN(path)) THEN z.error := BadArgument
        ELSIF F.FileExists(path) THEN z.error := Exists
        ELSE
            e := z.entries.entries[index]; Locate(z, e);
            IF z.error = OK THEN
                IF ~F.ReWrite(f, path) THEN z.error := IOError
                ELSE
                    IF e.method = Stored THEN
                        IF ~CopyStored(z.file, f, e.size, crc) THEN Fail(z, IOError) END
                    ELSE
                        status := I.DecompressFile(z.file, f, e.packed, e.size, written, consumed, crc);
                        IF status = I.IOError THEN Fail(z, IOError)
                        ELSIF status = I.NoMemory THEN z.error := NoMemory
                        ELSIF (status # I.OK) OR (written # e.size) OR (consumed # e.packed) THEN Fail(z, BadData) END
                    END;
                    IF (z.error = OK) & (crc # e.crc) THEN Fail(z, CRCError) END;
                    Descriptor(z, e); F.Close(f);
                    IF ~F.Ok(f) THEN Fail(z, IOError) END;
                    IF z.error # OK THEN
                        deleted := F.Delete(path);
                        IF ~deleted THEN Fail(z, IOError) END
                    END
                END
            END
        END
    END;
    RETURN z.error = OK
END ExtractFile;

PROCEDURE Close*(VAR z: Archive): BOOLEAN;
VAR j, start, size: INTEGER; e: Entry; ok: BOOLEAN;
BEGIN
    ok := ~z.failed;
    IF z.opened THEN
        IF z.writing & ~z.failed THEN
            z.error := OK; start := F.Position(z.file);
            FOR j := 0 TO z.count - 1 DO
                e := z.entries.entries[j];
                IF z.error = OK THEN
                    Put(z, 02014B50H, 4); Put(z, 20, 2); Put(z, 20, 2);
                    Put(z, e.flags, 2); Put(z, e.method, 2); Put(z, 0, 2); Put(z, 33, 2);
                    Put(z, e.crc, 4); Put(z, e.packed, 4); Put(z, e.size, 4);
                    Put(z, Length(e.name), 2); Put(z, 0, 2); Put(z, 0, 2);
                    Put(z, 0, 2); Put(z, 0, 2); Put(z, 0, 4); Put(z, e.offset, 4); WriteName(z, e.name)
                END
            END;
            size := F.Position(z.file) - start;
            Put(z, 06054B50H, 4); Put(z, 0, 2); Put(z, 0, 2);
            Put(z, z.count, 2); Put(z, z.count, 2); Put(z, size, 4); Put(z, start, 4); Put(z, 0, 2)
        END;
        F.Close(z.file);
        IF ~F.Ok(z.file) THEN Fail(z, IOError) END;
        ok := ~z.failed; z.opened := FALSE
    END;
    Release(z);
    RETURN ok
END Close;

END Zip.
