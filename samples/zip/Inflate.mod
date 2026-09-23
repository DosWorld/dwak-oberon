(*
   Public domain
   Copyright (c) 2026-, DosWorld

   Raw DEFLATE decompression (RFC 1951), for DWAK Oberon-07.

*)
MODULE Inflate;

IMPORT F := Files, C := CRC32;

CONST
    OK* = 0;
    BadData* = 1;        (* malformed block header, code, or back-reference *)
    OutputFull* = 2;      (* uncompressed size exceeds the caller's buffer *)
    BadArgument* = 4; IOError* = 5; NoMemory* = 6;
    InputTruncated* = 3;  (* ran out of input bits before an END-OF-BLOCK *)

    MaxBits = 15;
    MaxLitSyms = 288;
    MaxDistSyms = 32;
    MaxCLenSyms = 19;

TYPE
    (* A canonical Huffman decode table for at most MaxLitSyms symbols
       with codes no longer than MaxBits, built per RFC 1951's appendix. *)
    HuffTable = RECORD
        count:  ARRAY MaxBits + 1 OF INTEGER; (* codes of each length *)
        first:  ARRAY MaxBits + 1 OF INTEGER; (* first canonical code of that length *)
        index:  ARRAY MaxBits + 1 OF INTEGER; (* symbol[] index of that length's first entry *)
        symbol: ARRAY MaxLitSyms OF INTEGER    (* symbols, grouped by length then code order *)
    END;

    Workspace = POINTER TO RECORD
        input, output: ARRAY 4096 OF BYTE;
        window: ARRAY 32768 OF BYTE;
        readPos, readLen, pending, crc: INTEGER
    END;
    State = RECORD

        srcLen, pos, bitBuf, bitCnt: INTEGER; (* byte counts, no large bit offsets *)
        dstLen, out: INTEGER;
        err: INTEGER;
        w: Workspace; (* non-NIL for buffered file input *)
        fileOut: BOOLEAN
    END;

VAR
    clOrder:   ARRAY MaxCLenSyms OF INTEGER;
    lenBase:   ARRAY 29 OF INTEGER;
    lenExtra:  ARRAY 29 OF INTEGER;
    distBase:  ARRAY MaxDistSyms OF INTEGER;
    distExtra: ARRAY MaxDistSyms OF INTEGER;
    tablesReady: BOOLEAN;

PROCEDURE InitTables;
BEGIN
    (* RFC 1951 3.2.7: order in which code-length-alphabet lengths appear. *)
    clOrder[0] := 16; clOrder[1] := 17; clOrder[2] := 18; clOrder[3] := 0;
    clOrder[4] := 8;  clOrder[5] := 7;  clOrder[6] := 9;  clOrder[7] := 6;
    clOrder[8] := 10; clOrder[9] := 5;  clOrder[10] := 11; clOrder[11] := 4;
    clOrder[12] := 12; clOrder[13] := 3; clOrder[14] := 13; clOrder[15] := 2;
    clOrder[16] := 14; clOrder[17] := 1; clOrder[18] := 15;

    (* RFC 1951 3.2.5: length codes 257..285 (index 0..28). *)
    lenBase[0] := 3;  lenBase[1] := 4;  lenBase[2] := 5;  lenBase[3] := 6;
    lenBase[4] := 7;  lenBase[5] := 8;  lenBase[6] := 9;  lenBase[7] := 10;
    lenBase[8] := 11; lenBase[9] := 13; lenBase[10] := 15; lenBase[11] := 17;
    lenBase[12] := 19; lenBase[13] := 23; lenBase[14] := 27; lenBase[15] := 31;
    lenBase[16] := 35; lenBase[17] := 43; lenBase[18] := 51; lenBase[19] := 59;
    lenBase[20] := 67; lenBase[21] := 83; lenBase[22] := 99; lenBase[23] := 115;
    lenBase[24] := 131; lenBase[25] := 163; lenBase[26] := 195; lenBase[27] := 227;
    lenBase[28] := 258;

    lenExtra[0] := 0; lenExtra[1] := 0; lenExtra[2] := 0; lenExtra[3] := 0;
    lenExtra[4] := 0; lenExtra[5] := 0; lenExtra[6] := 0; lenExtra[7] := 0;
    lenExtra[8] := 1; lenExtra[9] := 1; lenExtra[10] := 1; lenExtra[11] := 1;
    lenExtra[12] := 2; lenExtra[13] := 2; lenExtra[14] := 2; lenExtra[15] := 2;
    lenExtra[16] := 3; lenExtra[17] := 3; lenExtra[18] := 3; lenExtra[19] := 3;
    lenExtra[20] := 4; lenExtra[21] := 4; lenExtra[22] := 4; lenExtra[23] := 4;
    lenExtra[24] := 5; lenExtra[25] := 5; lenExtra[26] := 5; lenExtra[27] := 5;
    lenExtra[28] := 0;

    (* RFC 1951 3.2.5: distance codes 0..29. *)
    distBase[0] := 1;  distBase[1] := 2;  distBase[2] := 3;  distBase[3] := 4;
    distBase[4] := 5;  distBase[5] := 7;  distBase[6] := 9;  distBase[7] := 13;
    distBase[8] := 17; distBase[9] := 25; distBase[10] := 33; distBase[11] := 49;
    distBase[12] := 65; distBase[13] := 97; distBase[14] := 129; distBase[15] := 193;
    distBase[16] := 257; distBase[17] := 385; distBase[18] := 513; distBase[19] := 769;
    distBase[20] := 1025; distBase[21] := 1537; distBase[22] := 2049; distBase[23] := 3073;
    distBase[24] := 4097; distBase[25] := 6145; distBase[26] := 8193; distBase[27] := 12289;
    distBase[28] := 16385; distBase[29] := 24577;

    distExtra[0] := 0; distExtra[1] := 0; distExtra[2] := 0; distExtra[3] := 0;
    distExtra[4] := 1; distExtra[5] := 1; distExtra[6] := 2; distExtra[7] := 2;
    distExtra[8] := 3; distExtra[9] := 3; distExtra[10] := 4; distExtra[11] := 4;
    distExtra[12] := 5; distExtra[13] := 5; distExtra[14] := 6; distExtra[15] := 6;
    distExtra[16] := 7; distExtra[17] := 7; distExtra[18] := 8; distExtra[19] := 8;
    distExtra[20] := 9; distExtra[21] := 9; distExtra[22] := 10; distExtra[23] := 10;
    distExtra[24] := 11; distExtra[25] := 11; distExtra[26] := 12; distExtra[27] := 12;
    distExtra[28] := 13; distExtra[29] := 13;

    tablesReady := TRUE
END InitTables;

(* GetBit: the next input bit, LSB-first within each byte as DEFLATE
   requires. Sets st.err to InputTruncated (once) past the last bit and
   returns 0 from then on so a caller that keeps reading degrades safely. *)
PROCEDURE GetBit(VAR st: State; VAR src: ARRAY OF BYTE; VAR input, output: F.File): INTEGER;
VAR n, result: INTEGER;
BEGIN
    result := 0;
    IF (st.err = OK) & (st.bitCnt = 0) THEN
        IF st.pos = st.srcLen THEN st.err := InputTruncated
        ELSE
            IF st.w = NIL THEN st.bitBuf := src[st.pos]
            ELSE
                IF st.w.readPos = st.w.readLen THEN
                    n := st.srcLen - st.pos; IF n > 4096 THEN n := 4096 END;
                    st.w.readLen := F.BlockRead(input, st.w.input, n); st.w.readPos := 0;
                    IF st.w.readLen # n THEN st.err := InputTruncated END
                END;
                IF st.err = OK THEN st.bitBuf := st.w.input[st.w.readPos]; INC(st.w.readPos) END
            END;
            IF st.err = OK THEN INC(st.pos); st.bitCnt := 8 END
        END
    END;
    IF st.err = OK THEN result := st.bitBuf MOD 2; st.bitBuf := st.bitBuf DIV 2; DEC(st.bitCnt) END;
    RETURN result
END GetBit;

PROCEDURE GetBits(VAR st: State; VAR src: ARRAY OF BYTE; VAR input, output: F.File; n: INTEGER): INTEGER;
VAR i, v: INTEGER;
BEGIN
    v := 0;
    FOR i := 0 TO n - 1 DO INC(v, GetBit(st, src, input, output) * LSL(1, i)) END;
    RETURN v
END GetBits;

(* BuildHuffman: turn an array of code lengths (0 = symbol unused) into a
   canonical decode table -- RFC 1951 appendix ("count[]"/"first code of
   each length", symbols listed in length-then-code order). *)
PROCEDURE BuildHuffman(VAR lens: ARRAY OF INTEGER; n: INTEGER; VAR t: HuffTable): BOOLEAN;
VAR i, len, code, ok, left, used: INTEGER;
BEGIN
    ok := 1;
    FOR i := 0 TO MaxBits DO t.count[i] := 0 END;
    FOR i := 0 TO n - 1 DO
        IF (lens[i] < 0) OR (lens[i] > MaxBits) THEN ok := 0
        ELSIF lens[i] > 0 THEN INC(t.count[lens[i]]) END
    END;

    left := 1; used := 0;
    FOR len := 1 TO MaxBits DO
        left := left * 2 - t.count[len]; INC(used, t.count[len]);
        IF left < 0 THEN ok := 0 END
    END;
    (* A missing distance alphabet is legal until a match needs it. *)
    IF (left > 0) & (used # 0) & ~((used = 1) & (t.count[1] = 1)) THEN ok := 0 END;
    code := 0; t.first[0] := 0; t.index[0] := 0;
    FOR len := 1 TO MaxBits DO
        code := (code + t.count[len - 1]) * 2;
        t.first[len] := code;
        t.index[len] := t.index[len - 1] + t.count[len - 1]
    END;

    FOR len := 1 TO MaxBits DO
        FOR i := 0 TO n - 1 DO
            IF lens[i] = len THEN
                t.symbol[t.index[len]] := i;
                INC(t.index[len])
            END
        END
    END;

    (* index[] was consumed while filling symbol[]; rebuild it for the
       decoder, which needs the *first* index of each length again. *)
    t.index[0] := 0;
    FOR len := 1 TO MaxBits DO t.index[len] := t.index[len - 1] + t.count[len - 1] END;

    RETURN ok = 1
END BuildHuffman;

(* DecodeSymbol: extend a running code one bit at a time until it matches
   a canonical code of the current length: compare against
   first[len] .. first[len] + count[len] - 1 after each new bit. *)
PROCEDURE DecodeSymbol(VAR st: State; VAR src: ARRAY OF BYTE; VAR input, output: F.File; VAR t: HuffTable): INTEGER;
VAR len, code, sym: INTEGER;
    found: BOOLEAN;
BEGIN
    len := 0; code := 0; sym := -1; found := FALSE;
    WHILE ~found & (len < MaxBits) & (st.err = OK) DO
        code := code * 2 + GetBit(st, src, input, output);
        INC(len);
        IF (t.count[len] > 0) & (code >= t.first[len]) & (code - t.first[len] < t.count[len]) THEN
            sym := t.symbol[t.index[len] + (code - t.first[len])];
            found := TRUE
        END
    END;
    IF ~found & (st.err = OK) THEN st.err := BadData END;
    RETURN sym
END DecodeSymbol;

PROCEDURE FlushOutput(VAR st: State; VAR output: F.File);
BEGIN
    IF (st.err = OK) & (st.w.pending > 0) THEN
        IF F.BlockWrite(output, st.w.output, st.w.pending) # st.w.pending THEN st.err := IOError
        ELSE st.w.crc := C.Update(st.w.crc, st.w.output, 0, st.w.pending); st.w.pending := 0 END
    END
END FlushOutput;

PROCEDURE EmitByte(VAR st: State; VAR dst: ARRAY OF BYTE; VAR input, output: F.File; b: INTEGER);
BEGIN
    IF st.err = OK THEN
        IF st.out >= st.dstLen THEN st.err := OutputFull
        ELSE
            IF ~st.fileOut THEN dst[st.out] := b
            ELSE
                st.w.window[st.out MOD 32768] := b;
                st.w.output[st.w.pending] := b; INC(st.w.pending);
                IF st.w.pending = 4096 THEN FlushOutput(st, output) END
            END;
            INC(st.out)
        END
    END
END EmitByte;

PROCEDURE CopyMatch(VAR st: State; VAR dst: ARRAY OF BYTE; VAR input, output: F.File; dist, len: INTEGER);
VAR i, b: INTEGER;
BEGIN
    IF (dist <= 0) OR (dist > st.out) OR (dist > 32768) THEN st.err := BadData
    ELSE
        i := 0;
        WHILE (i < len) & (st.err = OK) DO
            IF ~st.fileOut THEN b := dst[st.out - dist]
            ELSE b := st.w.window[(st.out - dist) MOD 32768] END;
            EmitByte(st, dst, input, output, b); INC(i)
        END
    END
END CopyMatch;

PROCEDURE InflateBlockData(VAR st: State; VAR src, dst: ARRAY OF BYTE; VAR input, output: F.File; VAR lit, dist: HuffTable);
VAR sym, lenSym, distSym, len, d: INTEGER;
    stop: BOOLEAN;
BEGIN
    stop := FALSE;
    WHILE ~stop & (st.err = OK) DO
        sym := DecodeSymbol(st, src, input, output, lit);
        IF st.err # OK THEN stop := TRUE
        ELSIF sym < 256 THEN EmitByte(st, dst, input, output, sym)
        ELSIF sym = 256 THEN stop := TRUE
        ELSE
            lenSym := sym - 257;
            IF (lenSym < 0) OR (lenSym > 28) THEN
                st.err := BadData; stop := TRUE
            ELSE
                len := lenBase[lenSym] + GetBits(st, src, input, output, lenExtra[lenSym]);
                distSym := DecodeSymbol(st, src, input, output, dist);
                IF (st.err = OK) & ((distSym < 0) OR (distSym > 29)) THEN
                    st.err := BadData
                END;
                IF st.err = OK THEN
                    d := distBase[distSym] + GetBits(st, src, input, output, distExtra[distSym]);
                    IF st.err = OK THEN CopyMatch(st, dst, input, output, d, len) END
                END
            END
        END
    END
END InflateBlockData;

PROCEDURE FixedTables(VAR lit, dist: HuffTable);
VAR lens: ARRAY MaxLitSyms OF INTEGER;
    dlens: ARRAY MaxDistSyms OF INTEGER;
    i: INTEGER;
BEGIN
    FOR i := 0 TO 143 DO lens[i] := 8 END;
    FOR i := 144 TO 255 DO lens[i] := 9 END;
    FOR i := 256 TO 279 DO lens[i] := 7 END;
    FOR i := 280 TO 287 DO lens[i] := 8 END;
    FOR i := 0 TO 31 DO dlens[i] := 5 END;
    ASSERT(BuildHuffman(lens, 288, lit));
    ASSERT(BuildHuffman(dlens, 32, dist))
END FixedTables;

PROCEDURE DynamicTables(VAR st: State; VAR src: ARRAY OF BYTE; VAR input, output: F.File; VAR lit, dist: HuffTable);
VAR hlit, hdist, hclen, i, n, sym, rep, prev: INTEGER;
    clLens: ARRAY MaxCLenSyms OF INTEGER;
    clTable: HuffTable;
    allLens: ARRAY MaxLitSyms + MaxDistSyms OF INTEGER;
BEGIN
    hlit := 257 + GetBits(st, src, input, output, 5);
    hdist := 1 + GetBits(st, src, input, output, 5);
    hclen := 4 + GetBits(st, src, input, output, 4);

    IF (st.err = OK) & (hlit > 286) THEN st.err := BadData END;
    FOR i := 0 TO MaxCLenSyms - 1 DO clLens[i] := 0 END;
    FOR i := 0 TO hclen - 1 DO clLens[clOrder[i]] := GetBits(st, src, input, output, 3) END;

    IF st.err = OK THEN
        IF ~BuildHuffman(clLens, MaxCLenSyms, clTable) OR
           (clTable.first[MaxBits] + clTable.count[MaxBits] # LSL(1, MaxBits)) THEN st.err := BadData END
    END;

    n := 0; prev := 0;
    WHILE (n < hlit + hdist) & (st.err = OK) DO
        sym := DecodeSymbol(st, src, input, output, clTable);
        IF st.err # OK THEN (* stop: loop condition ends it *)
        ELSIF sym < 16 THEN
            allLens[n] := sym; prev := sym; INC(n)
        ELSIF sym = 16 THEN
            IF n = 0 THEN
                st.err := BadData
            ELSE
                rep := 3 + GetBits(st, src, input, output, 2);
                IF rep > hlit + hdist - n THEN st.err := BadData END;
                WHILE (rep > 0) & (n < hlit + hdist) DO
                    allLens[n] := prev; INC(n); DEC(rep)
                END
            END
        ELSIF sym = 17 THEN
            rep := 3 + GetBits(st, src, input, output, 3);
            IF rep > hlit + hdist - n THEN st.err := BadData END;
            WHILE (rep > 0) & (n < hlit + hdist) DO
                allLens[n] := 0; INC(n); DEC(rep)
            END;
            prev := 0
        ELSIF sym = 18 THEN
            rep := 11 + GetBits(st, src, input, output, 7);
            IF rep > hlit + hdist - n THEN st.err := BadData END;
            WHILE (rep > 0) & (n < hlit + hdist) DO
                allLens[n] := 0; INC(n); DEC(rep)
            END;
            prev := 0
        ELSE
            st.err := BadData
        END
    END;

    IF st.err = OK THEN
        IF (allLens[256] = 0) OR ~BuildHuffman(allLens, hlit, lit) THEN st.err := BadData END
    END;
    IF st.err = OK THEN
        FOR i := 0 TO hdist - 1 DO allLens[i] := allLens[hlit + i] END;
        IF ~BuildHuffman(allLens, hdist, dist) THEN st.err := BadData END
    END
END DynamicTables;

PROCEDURE InflateStored(VAR st: State; VAR src, dst: ARRAY OF BYTE; VAR input, output: F.File);
VAR len, nlen, i, b: INTEGER;
BEGIN
    st.bitCnt := 0; st.bitBuf := 0;
    len := GetBits(st, src, input, output, 16); nlen := GetBits(st, src, input, output, 16);
    IF st.err = OK THEN
        IF len + nlen # 65535 THEN st.err := BadData
        ELSIF len > st.srcLen - st.pos THEN st.err := InputTruncated
        ELSE
            i := 0;
            WHILE (i < len) & (st.err = OK) DO
                b := GetBits(st, src, input, output, 8);
                EmitByte(st, dst, input, output, b); INC(i)
            END
        END
    END
END InflateStored;

PROCEDURE Decode(VAR st: State; VAR src, dst: ARRAY OF BYTE; VAR input, output: F.File);
VAR final, btype: INTEGER; lit, dist: HuffTable; stop: BOOLEAN;
BEGIN
    IF ~tablesReady THEN InitTables END;
    st.pos := 0; st.out := 0; st.bitBuf := 0; st.bitCnt := 0;
    stop := FALSE;
    WHILE ~stop & (st.err = OK) DO
        final := GetBit(st, src, input, output); btype := GetBits(st, src, input, output, 2);
        IF st.err = OK THEN
            CASE btype OF
              0: InflateStored(st, src, dst, input, output)
            | 1: FixedTables(lit, dist); InflateBlockData(st, src, dst, input, output, lit, dist)
            | 2: DynamicTables(st, src, input, output, lit, dist);
                 IF st.err = OK THEN InflateBlockData(st, src, dst, input, output, lit, dist) END
            ELSE st.err := BadData
            END
        END;
        IF (st.err = OK) & (final = 1) THEN stop := TRUE END
    END
END Decode;

PROCEDURE DecompressUsed*(VAR src: ARRAY OF BYTE; srcLen: INTEGER;
                         VAR dst: ARRAY OF BYTE; dstLen: INTEGER;
                         VAR written, consumed: INTEGER): INTEGER;
VAR st: State; input, output: F.File;
BEGIN
    st.srcLen := srcLen; st.dstLen := dstLen; st.err := OK; st.w := NIL; st.fileOut := FALSE;
    IF (srcLen < 0) OR (srcLen > LEN(src)) OR (dstLen < 0) OR (dstLen > LEN(dst)) THEN st.err := BadArgument END;
    Decode(st, src, dst, input, output);
    written := st.out; consumed := st.pos;
    RETURN st.err
END DecompressUsed;

PROCEDURE Decompress*(VAR src: ARRAY OF BYTE; srcLen: INTEGER;
                      VAR dst: ARRAY OF BYTE; dstLen: INTEGER; VAR written: INTEGER): INTEGER;
VAR consumed: INTEGER;
BEGIN RETURN DecompressUsed(src, srcLen, dst, dstLen, written, consumed) END Decompress;

(* Decode from the current input position; never read beyond srcLen. History
   survives every I/O and DEFLATE block boundary. Caller owns/closes both files. *)
PROCEDURE DecompressFile*(VAR input, output: F.File; srcLen, dstLen: INTEGER;
                         VAR written, consumed, crc: INTEGER): INTEGER;
VAR st: State; dummy: ARRAY 1 OF BYTE; start: INTEGER;
BEGIN
    written := 0; consumed := 0; crc := 0; st.err := OK; st.w := NIL;
    st.fileOut := TRUE; start := F.Position(input);
    IF (srcLen < 0) OR (dstLen < 0) OR (srcLen > F.Size(input) - start) THEN st.err := BadArgument
    ELSE
        NEW(st.w);
        IF st.w = NIL THEN st.err := NoMemory
        ELSE
            st.srcLen := srcLen; st.dstLen := dstLen;
            st.w.readPos := 0; st.w.readLen := 0; st.w.pending := 0; st.w.crc := 0;
            Decode(st, dummy, dummy, input, output); FlushOutput(st, output);
            written := st.out; consumed := st.pos; crc := st.w.crc;
            F.Seek(input, start + consumed);
            IF ~F.Ok(output) THEN st.err := IOError END;
            DISPOSE(st.w)
        END
    END;
    RETURN st.err
END DecompressFile;

(* Decode from a file directly into caller-owned memory without buffering
   the whole compressed entry. No file output is used by this variant. *)
PROCEDURE DecompressToMemory*(VAR input: F.File; srcLen: INTEGER;
                             VAR dst: ARRAY OF BYTE; dstLen: INTEGER;
                             VAR written, consumed: INTEGER): INTEGER;
VAR st: State; output: F.File; dummy: ARRAY 1 OF BYTE; start: INTEGER;
BEGIN
    written := 0; consumed := 0; st.err := OK; st.w := NIL; st.fileOut := FALSE;
    start := F.Position(input);
    IF (srcLen < 0) OR (srcLen > F.Size(input) - start) OR
       (dstLen < 0) OR (dstLen > LEN(dst)) THEN st.err := BadArgument
    ELSE
        NEW(st.w);
        IF st.w = NIL THEN st.err := NoMemory
        ELSE
            st.srcLen := srcLen; st.dstLen := dstLen;
            st.w.readPos := 0; st.w.readLen := 0;
            Decode(st, dummy, dst, input, output);
            written := st.out; consumed := st.pos; F.Seek(input, start + consumed);
            DISPOSE(st.w)
        END
    END;
    RETURN st.err
END DecompressToMemory;

END Inflate.
