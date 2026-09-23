(* Public domain. Copyright (c) 2026-, DosWorld.

   IEEE CRC-32, signed 32-bit result on both 32- and 64-bit targets.
   Use Update(0, ...) to start; every returned prefix CRC is finalized and
   can be supplied to the next Update. Bounds are a caller precondition.
*)
MODULE CRC32;

VAR table: ARRAY 256 OF INTEGER;

PROCEDURE Xor32(a, b: INTEGER): INTEGER;
VAR x, hi: INTEGER;
BEGIN
    x := ORD(BITS(a) / BITS(b)); hi := LSR(x, 16) MOD 65536;
    IF hi >= 32768 THEN DEC(hi, 65536) END;
    RETURN hi * 65536 + x MOD 65536
END Xor32;

PROCEDURE BuildTable;
VAR i, j, c, bit: INTEGER;
BEGIN
    FOR i := 0 TO 255 DO
        c := i;
        FOR j := 0 TO 7 DO
            bit := c MOD 2;
            IF c < 0 THEN c := c DIV 2 + 2147483647 + 1 ELSE c := c DIV 2 END;
            IF bit # 0 THEN c := Xor32(c, -306674912) END
        END;
        table[i] := c
    END
END BuildTable;

PROCEDURE Update*(crc: INTEGER; VAR data: ARRAY OF BYTE; ofs, len: INTEGER): INTEGER;
VAR i, c: INTEGER;
BEGIN
    ASSERT((ofs >= 0) & (ofs <= LEN(data)) & (len >= 0) & (len <= LEN(data) - ofs));
    c := Xor32(crc, -1);
    FOR i := ofs TO ofs + len - 1 DO
        c := Xor32(table[Xor32(c, data[i]) MOD 256], LSR(c, 8) MOD 16777216)
    END;
    RETURN Xor32(c, -1)
END Update;

PROCEDURE Of*(VAR data: ARRAY OF BYTE; len: INTEGER): INTEGER;
BEGIN
    RETURN Update(0, data, 0, len)
END Of;

BEGIN
    BuildTable
END CRC32.