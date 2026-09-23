MODULE CodecT;

IMPORT I := Inflate, D := Deflate, Out;

VAR bits: ARRAY 100000 OF BYTE; source, target: ARRAY 70000 OF BYTE; bitPos: INTEGER;

PROCEDURE Check(ok: BOOLEAN; label: ARRAY OF CHAR);
BEGIN
    IF ~ok THEN Out.String("FAIL codec: "); Out.StringLn(label); ASSERT(FALSE) END
END Check;

PROCEDURE Bits(value, count: INTEGER);
VAR i: INTEGER;
BEGIN
    FOR i := 0 TO count - 1 DO
        IF bitPos MOD 8 = 0 THEN bits[bitPos DIV 8] := 0 END;
        INC(bits[bitPos DIV 8], (value MOD 2) * LSL(1, bitPos MOD 8));
        value := value DIV 2; INC(bitPos)
    END
END Bits;

PROCEDURE Header(a, b, c, d: INTEGER);
BEGIN
    bitPos := 0; Bits(1, 1); Bits(2, 2); Bits(0, 5); Bits(0, 5); Bits(0, 4);
    Bits(a, 3); Bits(b, 3); Bits(c, 3); Bits(d, 3)
END Header;

PROCEDURE Reject(label: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
    Check(I.Decompress(bits, (bitPos + 7) DIV 8, target, LEN(target), n) = I.BadData, label)
END Reject;

PROCEDURE Run*;
VAR n, m, j, length: INTEGER;
BEGIN
    Header(1, 1, 1, 1); Reject("oversubscribed code lengths");
    Header(0, 0, 1, 0); Reject("incomplete code lengths");
    Header(0, 0, 1, 1); Bits(1, 1); Bits(127, 7); Bits(1, 1); Bits(127, 7);
    Reject("repeat exceeds alphabet");
    Header(1, 0, 0, 1); Bits(1, 1); Bits(0, 2); Reject("repeat without previous length");
    Header(0, 0, 1, 1); Bits(1, 1); Bits(127, 7); Bits(1, 1); Bits(109, 7);
    Reject("missing end symbol");
    (* Valid dynamic empty block, one-bit EOB and no distance codes. *)
    bitPos := 0; Bits(1, 1); Bits(2, 2); Bits(0, 5); Bits(0, 5); Bits(14, 4);
    FOR j := 0 TO 17 DO
        IF j = 2 THEN Bits(1, 3) ELSIF (j = 3) OR (j = 17) THEN Bits(2, 3)
        ELSE Bits(0, 3) END
    END;
    Bits(0, 1); Bits(127, 7); Bits(0, 1); Bits(107, 7);
    Bits(3, 2); Bits(1, 2); Bits(0, 1);
    Check(I.Decompress(bits, (bitPos + 7) DIV 8, target, 0, n) = I.OK, "single EOB no distances");
    Check(n = 0, "empty dynamic length");
    (* Nonfinal stored ABC followed by final fixed empty block. *)
    bits[0] := 0; bits[1] := 3; bits[2] := 0; bits[3] := 252; bits[4] := 255;
    bits[5] := 65; bits[6] := 66; bits[7] := 67; bits[8] := 3; bits[9] := 0;
    Check(I.Decompress(bits, 10, target, LEN(target), n) = I.OK, "mixed blocks");
    Check((n = 3) & (target[0] = 65) & (target[2] = 67), "stored contents");
    bits[3] := 251; Check(I.Decompress(bits, 10, target, LEN(target), n) = I.BadData, "stored complement");
    (* Reserved literal 286: canonical 11000110, packed MSB-first. *)
    bitPos := 0; Bits(3, 3); Bits(99, 8); Reject("reserved literal");
    bitPos := 0; Bits(3, 3); Bits(64, 7); Bits(0, 5); Reject("distance before start");
    FOR j := 0 TO 69999 DO source[j] := (j * 37 + j DIV 97) MOD 256 END;
    Check(D.Compress(source, 70000, bits, LEN(bits), n) = D.OK, "window crossing");
    FOR j := 0 TO n - 1 DO
        Check(I.Decompress(bits, j, target, LEN(target), m) # I.OK, "every truncated prefix")
    END;
    Check(I.Decompress(bits, n, target, 69999, m) = I.OutputFull, "output bound");
    Check(m = 69999, "partial prefix length");
    (* Exercise every match length, including all extra-bit transitions. *)
    FOR length := 3 TO 258 DO
        FOR j := 0 TO length - 1 DO source[j] := 65 END;
        Check(D.Compress(source, length, bits, D.Bound(length), n) = D.OK, "length encode");
        Check(I.Decompress(bits, n, target, length, m) = I.OK, "length decode");
        Check(m = length, "match length");
        FOR j := 0 TO m - 1 DO Check(target[j] = 65, "match bytes") END
    END;
    Out.StringLn("CODEC MALFORMED/BOUNDARY TESTS OK")
END Run;

END CodecT.
