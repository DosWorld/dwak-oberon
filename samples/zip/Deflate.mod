(*
   Public domain
   Copyright (c) 2026-, DosWorld

   Raw DEFLATE compression (RFC 1951), for DWAK Oberon-07: a single fixed-
   Huffman block, greedy LZ77 matching over a hash-chained window.
*)
MODULE Deflate;

IMPORT F := Files, C := CRC32;

CONST
    OK* = 0;
    OutputFull* = 1; BadArgument* = 2; NoMemory* = 3; IOError* = 4;

    WindowBits = 15;
    WindowSize = 32768;      (* 1 << WindowBits: max DEFLATE back-reference distance *)
    WindowMask = WindowSize - 1;
    HashBits = 15;
    HashSize = 32768;        (* 1 << HashBits *)
    HashMask = HashSize - 1;
    MinMatch = 3;
    MaxMatch = 258;
    NoPos = -1;
    MaxChain = 128;          (* hash-chain probes per position: bounds worst-case time *)

TYPE
    (* The hash table and the per-position "previous occurrence of this
       hash" chain are too large for a RECORD's own frame; heap-allocate
       them once per Compressor. *)
    Chains = POINTER TO RECORD
        head: ARRAY HashSize OF INTEGER;
        prev: ARRAY WindowSize OF INTEGER
    END;

    FileWorkspace = POINTER TO RECORD
        data: ARRAY 65536 OF BYTE;
        input: ARRAY 32768 OF BYTE;
        output: ARRAY 40000 OF BYTE
    END;
    BitWriter = RECORD

        bitBuf, bitCnt: INTEGER;
        outPos, outLen: INTEGER
    END;

VAR
    litLen:  ARRAY 288 OF INTEGER;  (* fixed-Huffman code length per literal/length symbol *)
    litCode: ARRAY 288 OF INTEGER;  (* ... and its canonical code, MSB-first as an integer *)
    distLenTbl:  ARRAY 30 OF INTEGER;
    distCodeTbl: ARRAY 30 OF INTEGER;
    lenBase:   ARRAY 29 OF INTEGER;
    lenExtraN: ARRAY 29 OF INTEGER;
    distBase:  ARRAY 30 OF INTEGER;
    distExtraN: ARRAY 30 OF INTEGER;
    tablesReady: BOOLEAN;

PROCEDURE InitTables;
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO 143 DO litLen[i] := 8 END;
    FOR i := 144 TO 255 DO litLen[i] := 9 END;
    FOR i := 256 TO 279 DO litLen[i] := 7 END;
    FOR i := 280 TO 287 DO litLen[i] := 8 END;
    FOR i := 0 TO 29 DO distLenTbl[i] := 5 END;

    (* Canonical codes for the two fixed alphabets: assign in ascending
       (length, symbol) order, exactly as Inflate.BuildHuffman decodes
       them, but computed forward here since the length of every symbol
       is already fixed by RFC 1951 3.2.6 rather than read from a stream. *)
    FOR i := 0 TO 143 DO litCode[i] := 48 + i END;
    FOR i := 144 TO 255 DO litCode[i] := 400 + i - 144 END;
    FOR i := 256 TO 279 DO litCode[i] := i - 256 END;
    FOR i := 280 TO 287 DO litCode[i] := 192 + i - 280 END;

    FOR i := 0 TO 29 DO distCodeTbl[i] := i END; (* all length 5: codes 0..29 in order *)

    (* Length codes 257..285 (index 0..28), RFC 1951 3.2.5. *)
    lenBase[0] := 3;  lenBase[1] := 4;  lenBase[2] := 5;  lenBase[3] := 6;
    lenBase[4] := 7;  lenBase[5] := 8;  lenBase[6] := 9;  lenBase[7] := 10;
    lenBase[8] := 11; lenBase[9] := 13; lenBase[10] := 15; lenBase[11] := 17;
    lenBase[12] := 19; lenBase[13] := 23; lenBase[14] := 27; lenBase[15] := 31;
    lenBase[16] := 35; lenBase[17] := 43; lenBase[18] := 51; lenBase[19] := 59;
    lenBase[20] := 67; lenBase[21] := 83; lenBase[22] := 99; lenBase[23] := 115;
    lenBase[24] := 131; lenBase[25] := 163; lenBase[26] := 195; lenBase[27] := 227;
    lenBase[28] := 258;

    lenExtraN[0] := 0; lenExtraN[1] := 0; lenExtraN[2] := 0; lenExtraN[3] := 0;
    lenExtraN[4] := 0; lenExtraN[5] := 0; lenExtraN[6] := 0; lenExtraN[7] := 0;
    lenExtraN[8] := 1; lenExtraN[9] := 1; lenExtraN[10] := 1; lenExtraN[11] := 1;
    lenExtraN[12] := 2; lenExtraN[13] := 2; lenExtraN[14] := 2; lenExtraN[15] := 2;
    lenExtraN[16] := 3; lenExtraN[17] := 3; lenExtraN[18] := 3; lenExtraN[19] := 3;
    lenExtraN[20] := 4; lenExtraN[21] := 4; lenExtraN[22] := 4; lenExtraN[23] := 4;
    lenExtraN[24] := 5; lenExtraN[25] := 5; lenExtraN[26] := 5; lenExtraN[27] := 5;
    lenExtraN[28] := 0;

    distBase[0] := 1;  distBase[1] := 2;  distBase[2] := 3;  distBase[3] := 4;
    distBase[4] := 5;  distBase[5] := 7;  distBase[6] := 9;  distBase[7] := 13;
    distBase[8] := 17; distBase[9] := 25; distBase[10] := 33; distBase[11] := 49;
    distBase[12] := 65; distBase[13] := 97; distBase[14] := 129; distBase[15] := 193;
    distBase[16] := 257; distBase[17] := 385; distBase[18] := 513; distBase[19] := 769;
    distBase[20] := 1025; distBase[21] := 1537; distBase[22] := 2049; distBase[23] := 3073;
    distBase[24] := 4097; distBase[25] := 6145; distBase[26] := 8193; distBase[27] := 12289;
    distBase[28] := 16385; distBase[29] := 24577;

    distExtraN[0] := 0; distExtraN[1] := 0; distExtraN[2] := 0; distExtraN[3] := 0;
    distExtraN[4] := 1; distExtraN[5] := 1; distExtraN[6] := 2; distExtraN[7] := 2;
    distExtraN[8] := 3; distExtraN[9] := 3; distExtraN[10] := 4; distExtraN[11] := 4;
    distExtraN[12] := 5; distExtraN[13] := 5; distExtraN[14] := 6; distExtraN[15] := 6;
    distExtraN[16] := 7; distExtraN[17] := 7; distExtraN[18] := 8; distExtraN[19] := 8;
    distExtraN[20] := 9; distExtraN[21] := 9; distExtraN[22] := 10; distExtraN[23] := 10;
    distExtraN[24] := 11; distExtraN[25] := 11; distExtraN[26] := 12; distExtraN[27] := 12;
    distExtraN[28] := 13; distExtraN[29] := 13;

    tablesReady := TRUE
END InitTables;

PROCEDURE ASH(x, n: INTEGER): INTEGER;
BEGIN
    IF n >= 0 THEN x := LSL(x, n) ELSE x := LSR(x, -n) END; RETURN x
END ASH;

(* PutBits: append the low n bits of v, LSB-first, matching Inflate's
   GetBit/GetBits reader (RFC 1951's own bit order: extra-value bits are
   packed LSB-first, and a Huffman code's bits are packed MSB-first --
   so codeLen/code below are written one bit at a time, MSB first, via
   n calls each carrying a single bit, while PutBits itself always packs
   its argument LSB-first into the stream). *)
PROCEDURE PutBit(VAR w: BitWriter; VAR out: ARRAY OF BYTE; bit: INTEGER): BOOLEAN;
VAR ok: BOOLEAN;
BEGIN
    ok := TRUE;
    INC(w.bitBuf, bit * ASH(1, w.bitCnt));
    INC(w.bitCnt);
    IF w.bitCnt = 8 THEN
        IF w.outPos >= w.outLen THEN
            ok := FALSE
        ELSE
            out[w.outPos] := w.bitBuf;
            INC(w.outPos);
            w.bitBuf := 0; w.bitCnt := 0
        END
    END;
    RETURN ok
END PutBit;

PROCEDURE PutBits(VAR w: BitWriter; VAR out: ARRAY OF BYTE; v, n: INTEGER): BOOLEAN;
VAR i: INTEGER;
    ok: BOOLEAN;
BEGIN
    ok := TRUE;
    i := 0;
    WHILE ok & (i < n) DO
        ok := PutBit(w, out, ASH(v, -i) MOD 2);
        INC(i)
    END;
    RETURN ok
END PutBits;

(* PutCode: a Huffman code, packed most-significant-bit first (RFC 1951
   3.1.1), as len calls to PutBit each carrying one bit of code. *)
PROCEDURE PutCode(VAR w: BitWriter; VAR out: ARRAY OF BYTE; code, len: INTEGER): BOOLEAN;
VAR i: INTEGER;
    ok: BOOLEAN;
BEGIN
    ok := TRUE;
    i := len - 1;
    WHILE ok & (i >= 0) DO
        ok := PutBit(w, out, ASH(code, -i) MOD 2);
        DEC(i)
    END;
    RETURN ok
END PutCode;

PROCEDURE FlushBits(VAR w: BitWriter; VAR out: ARRAY OF BYTE): BOOLEAN;
VAR ok: BOOLEAN;
BEGIN
    ok := TRUE;
    WHILE ok & (w.bitCnt > 0) DO ok := PutBit(w, out, 0) END;
    RETURN ok
END FlushBits;

PROCEDURE Hash3(VAR data: ARRAY OF BYTE; p: INTEGER): INTEGER;
BEGIN
    (* A bounded polynomial hash of three bytes; only used to seed
       chains, so collisions just cost a wasted chain probe, not
       correctness. *)
    RETURN ((data[p] * 251 + data[p + 1]) * 251 + data[p + 2]) MOD HashSize
END Hash3;

(* FindMatch: the longest run starting at p that also occurs at some
   earlier position within the window, found by walking the hash chain
   for p's 3-byte prefix. Returns the match length (0 if none reaches
   MinMatch) and its distance. *)
PROCEDURE FindMatch(VAR data: ARRAY OF BYTE; dataLen, p: INTEGER; VAR ch: Chains;
                     VAR bestLen, bestDist: INTEGER);
VAR cand, chain, limit, maxLen, n: INTEGER;
    stop: BOOLEAN;
BEGIN
    bestLen := 0; bestDist := 0;
    maxLen := dataLen - p;
    IF maxLen > MaxMatch THEN maxLen := MaxMatch END;
    IF maxLen >= MinMatch THEN
        limit := p - WindowSize;
        IF limit < 0 THEN limit := 0 END;
        cand := ch.head[Hash3(data, p)];
        chain := MaxChain;
        stop := FALSE;
        WHILE ~stop & (cand >= limit) & (chain > 0) DO
            n := 0;
            WHILE (n < maxLen) & (data[cand + n] = data[p + n]) DO INC(n) END;
            IF n > bestLen THEN
                bestLen := n; bestDist := p - cand;
                IF n >= maxLen THEN stop := TRUE END
            END;
            DEC(chain);
            IF ~stop THEN cand := ch.prev[cand MOD WindowSize] END
        END
    END
END FindMatch;

PROCEDURE InsertHash(VAR data: ARRAY OF BYTE; dataLen, p: INTEGER; VAR ch: Chains);
VAR h: INTEGER;
BEGIN
    IF p <= dataLen - 3 THEN
        h := Hash3(data, p);
        ch.prev[p MOD WindowSize] := ch.head[h];
        ch.head[h] := p
    END
END InsertHash;

PROCEDURE EmitLiteral(VAR w: BitWriter; VAR out: ARRAY OF BYTE; b: INTEGER): BOOLEAN;
BEGIN
    RETURN PutCode(w, out, litCode[b], litLen[b])
END EmitLiteral;

PROCEDURE LengthSymbol(len: INTEGER; VAR sym, extra, extraBits: INTEGER);
VAR i: INTEGER;
BEGIN
    sym := 28; (* len = 258, the only base with zero extra bits at the top *)
    IF len < 258 THEN
        i := 0;
        WHILE (i < 28) & (len >= lenBase[i + 1]) DO INC(i) END;
        sym := i
    END;
    extraBits := lenExtraN[sym];
    extra := len - lenBase[sym]
END LengthSymbol;

PROCEDURE DistSymbol(dist: INTEGER; VAR sym, extra, extraBits: INTEGER);
VAR i: INTEGER;
BEGIN
    i := 0;
    WHILE (i < 29) & (dist >= distBase[i + 1]) DO INC(i) END;
    sym := i;
    extraBits := distExtraN[sym];
    extra := dist - distBase[sym]
END DistSymbol;

PROCEDURE EmitMatch(VAR w: BitWriter; VAR out: ARRAY OF BYTE; len, dist: INTEGER): BOOLEAN;
VAR lsym, lextra, lbits, dsym, dextra, dbits: INTEGER;
    ok: BOOLEAN;
BEGIN
    LengthSymbol(len, lsym, lextra, lbits);
    DistSymbol(dist, dsym, dextra, dbits);
    ok := PutCode(w, out, litCode[257 + lsym], litLen[257 + lsym]);
    IF ok & (lbits > 0) THEN ok := PutBits(w, out, lextra, lbits) END;
    IF ok THEN ok := PutCode(w, out, distCodeTbl[dsym], distLenTbl[dsym]) END;
    IF ok & (dbits > 0) THEN ok := PutBits(w, out, dextra, dbits) END;
    RETURN ok
END EmitMatch;

(* Compress: encode src[0 .. srcLen-1] as a single, final, fixed-Huffman
   raw DEFLATE block into dst[0 .. dstLen-1]. Returns the status; written
   receives the number of bytes produced (only meaningful on OK -- unlike
   Inflate.Decompress, a partial compressed prefix is not useful output). *)
PROCEDURE Compress* (VAR src: ARRAY OF BYTE; srcLen: INTEGER;
                      VAR dst: ARRAY OF BYTE; dstLen: INTEGER;
                      VAR written: INTEGER): INTEGER;
VAR w: BitWriter;
    ch: Chains;
    p, matchLen, matchDist, runEnd, i, result: INTEGER;
    ok: BOOLEAN;
BEGIN
    IF ~tablesReady THEN InitTables END;
    written := 0; result := OK;
    IF (srcLen < 0) OR (srcLen > LEN(src)) OR (dstLen < 0) OR (dstLen > LEN(dst)) THEN
        result := BadArgument
    ELSE
        NEW(ch);
        IF ch = NIL THEN result := NoMemory ELSE
            FOR i := 0 TO HashSize - 1 DO ch.head[i] := NoPos END;

            w.bitBuf := 0; w.bitCnt := 0; w.outPos := 0; w.outLen := dstLen;

            ok := PutBits(w, dst, 1, 1);        (* BFINAL = 1: a single block *)
            IF ok THEN ok := PutBits(w, dst, 1, 2) END; (* BTYPE = 1: fixed Huffman *)

            p := 0;
            WHILE ok & (p < srcLen) DO
                FindMatch(src, srcLen, p, ch, matchLen, matchDist);
                IF matchLen >= MinMatch THEN
                    ok := EmitMatch(w, dst, matchLen, matchDist);
                    runEnd := p + matchLen;
                    WHILE ok & (p < runEnd) & (p < srcLen) DO
                        InsertHash(src, srcLen, p, ch);
                        INC(p)
                    END
                ELSE
                    ok := EmitLiteral(w, dst, src[p]);
                    InsertHash(src, srcLen, p, ch);
                    INC(p)
                END
            END;

            IF ok THEN ok := PutCode(w, dst, litCode[256], litLen[256]) END; (* end of block *)
            IF ok THEN ok := FlushBits(w, dst) END;

            written := w.outPos;
            IF ~ok THEN result := OutputFull END;
            DISPOSE(ch)
        END
    END;
    RETURN result
END Compress;

(* Bound: an output size guaranteed to hold Compress's result for any
   srcLen bytes of input (worst case: every byte a literal, longest fixed
   code 9 bits, plus the 3-bit header and 7-bit end-of-block code). *)
PROCEDURE Bound* (srcLen: INTEGER): INTEGER;
BEGIN
    IF (srcLen < 0) OR (srcLen > 1900000000) THEN srcLen := -1
    ELSE srcLen := srcLen + (srcLen + 7) DIV 8 + 8 END;
    RETURN srcLen
END Bound;

(* Fixed blocks share bit state and a 32 KiB history. Hash positions are
   rebased each chunk; neither storage nor position arithmetic grows. *)
PROCEDURE CompressSource(VAR input, output: F.File; VAR source: ARRAY OF BYTE; fromFile: BOOLEAN;
                       srcLen, maxPacked: INTEGER;
                       VAR written, crc: INTEGER): INTEGER;
VAR work: FileWorkspace; ch: Chains; w: BitWriter;
    left, n, history, p, stop, len, dist, total, j, result: INTEGER;
    ok, final: BOOLEAN;
BEGIN
    written := 0; crc := 0; result := OK;
    IF (srcLen < 0) OR (maxPacked < 0) OR
       (fromFile & (srcLen > F.Size(input) - F.Position(input))) OR
       (~fromFile & (srcLen > LEN(source))) THEN result := BadArgument
    ELSE
        IF ~tablesReady THEN InitTables END;
        NEW(work); NEW(ch);
        IF (work = NIL) OR (ch = NIL) THEN result := NoMemory
        ELSE
            left := srcLen; history := 0; w.bitBuf := 0; w.bitCnt := 0;
            REPEAT
                n := left; IF n > 32768 THEN n := 32768 END;
                IF fromFile THEN
                    IF F.BlockRead(input, work.input, n) # n THEN result := IOError END
                ELSE
                    FOR j := 0 TO n - 1 DO work.input[j] := source[srcLen - left + j] END
                END;
                IF result = OK THEN
                    crc := C.Update(crc, work.input, 0, n);
                    FOR j := 0 TO n - 1 DO work.data[history + j] := work.input[j] END;
                    total := history + n; final := left = n;
                    FOR j := 0 TO HashSize - 1 DO ch.head[j] := NoPos END;
                    FOR j := 0 TO history - 1 DO InsertHash(work.data, total, j, ch) END;
                    w.outPos := 0; w.outLen := LEN(work.output);
                    IF final THEN ok := PutBits(w, work.output, 1, 1)
                    ELSE ok := PutBits(w, work.output, 0, 1) END;
                    IF ok THEN ok := PutBits(w, work.output, 1, 2) END;
                    p := history;
                    WHILE ok & (p < total) DO
                        FindMatch(work.data, total, p, ch, len, dist);
                        IF len >= MinMatch THEN
                            ok := EmitMatch(w, work.output, len, dist); stop := p + len
                        ELSE ok := EmitLiteral(w, work.output, work.data[p]); stop := p + 1 END;
                        WHILE p < stop DO InsertHash(work.data, total, p, ch); INC(p) END
                    END;
                    IF ok THEN ok := PutCode(w, work.output, litCode[256], litLen[256]) END;
                    IF ok & final THEN ok := FlushBits(w, work.output) END;
                    IF ~ok OR (w.outPos > maxPacked - written) THEN result := OutputFull
                    ELSIF F.BlockWrite(output, work.output, w.outPos) # w.outPos THEN result := IOError
                    ELSE INC(written, w.outPos) END;
                    history := total; IF history > 32768 THEN history := 32768 END;
                    FOR j := 0 TO history - 1 DO work.data[j] := work.data[total - history + j] END;
                    DEC(left, n)
                END
            UNTIL (left = 0) OR (result # OK);
            IF ~F.Ok(output) THEN result := IOError END
        END;
        IF work # NIL THEN DISPOSE(work) END;
        IF ch # NIL THEN DISPOSE(ch) END
    END;
    RETURN result
END CompressSource;

PROCEDURE CompressFile*(VAR input, output: F.File; srcLen, maxPacked: INTEGER;
                       VAR written, crc: INTEGER): INTEGER;
VAR dummy: ARRAY 1 OF BYTE;
BEGIN
    RETURN CompressSource(input, output, dummy, TRUE, srcLen, maxPacked, written, crc)
END CompressFile;

PROCEDURE CompressToFile*(VAR source: ARRAY OF BYTE; srcLen: INTEGER; VAR output: F.File;
                         maxPacked: INTEGER; VAR written, crc: INTEGER): INTEGER;
VAR input: F.File;
BEGIN
    RETURN CompressSource(input, output, source, FALSE, srcLen, maxPacked, written, crc)
END CompressToFile;

END Deflate.
