(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.
*)

MODULE SHA256;

(* FIPS 180-4 SHA-256, used to build the ad-hoc code-signature digests and
   the load-command UUID of a Mach-O image (see MACHO.mod). Every word is
   kept in a 64-bit INTEGER and masked to 32 bits after each addition; ROTR
   and SHR follow the standard directly since Oberon has no 32-bit type. *)

IMPORT CHL := CHUNKLISTS;


CONST

    M32 = 100000000H;

    H0 = 06A09E667H; H1 = 0BB67AE85H; H2 = 03C6EF372H; H3 = 0A54FF53AH;
    H4 = 0510E527FH; H5 = 09B05688CH; H6 = 01F83D9ABH; H7 = 05BE0CD19H;


TYPE

    STATE = ARRAY 8 OF INTEGER;

    DIGEST* = ARRAY 32 OF BYTE;


VAR

    K: ARRAY 64 OF INTEGER;


PROCEDURE Shr (x, n: INTEGER): INTEGER;
    RETURN (x MOD M32) DIV LSL(1, n)
END Shr;


(* Right-rotate a 32-bit word held in a 64-bit INTEGER: shift the low bits
   right and bring the N bits that fall off back in at the top. *)
PROCEDURE Rotr (x, n: INTEGER): INTEGER;
BEGIN
    x := x MOD M32
    RETURN (x DIV LSL(1, n) + LSL(x MOD LSL(1, n), 32 - n)) MOD M32
END Rotr;


(* The byte at position I of the padded (length, 1-bit, zeros, 64-bit
   big-endian bit length) message whose real content is the first
   TOTALLEN bytes of LIST. TOTALLEN < 2^32 always holds here (a compiled
   image never approaches 4 GiB), so the high half of the length is 0. *)
PROCEDURE GetByte (list: CHL.BYTELIST; totalLen, i: INTEGER): BYTE;
VAR
    zeroEnd, res: INTEGER;

BEGIN
    IF i < totalLen THEN
        res := CHL.GetByte(list, i)
    ELSIF i = totalLen THEN
        res := 80H
    ELSE
        zeroEnd := ((totalLen + 1 + 8 + 63) DIV 64) * 64 - 8;
        IF i < zeroEnd THEN
            res := 0
        ELSIF i < zeroEnd + 4 THEN
            res := 0
        ELSE
            res := (totalLen * 8) DIV LSL(1, 8 * (zeroEnd + 7 - i)) MOD 256
        END
    END

    RETURN res
END GetByte;


PROCEDURE PaddedLen (totalLen: INTEGER): INTEGER;
    RETURN ((totalLen + 1 + 8 + 63) DIV 64) * 64
END PaddedLen;


(* Hashes the first N bytes of LIST (list-backed, for use inside MACHO.mod
   where the whole image already lives in a CHL.BYTELIST) into DIGEST. *)
PROCEDURE HashList* (list: CHL.BYTELIST; n: INTEGER; VAR digest: DIGEST);
VAR
    h: STATE;
    w: ARRAY 64 OF INTEGER;
    a, b, c, d, e, f, g, hh, t1, t2, s0, s1, ch, maj: INTEGER;
    block, i, j, blocks, base: INTEGER;

BEGIN
    h[0] := H0; h[1] := H1; h[2] := H2; h[3] := H3;
    h[4] := H4; h[5] := H5; h[6] := H6; h[7] := H7;

    blocks := PaddedLen(n) DIV 64;

    FOR block := 0 TO blocks - 1 DO
        base := block * 64;

        FOR i := 0 TO 15 DO
            w[i] := 0;
            FOR j := 0 TO 3 DO
                w[i] := w[i] * 256 + GetByte(list, n, base + i * 4 + j)
            END
        END;

        FOR i := 16 TO 63 DO
            s0 := ORD(BITS(Rotr(w[i-15], 7)) / (BITS(Rotr(w[i-15], 18)) / BITS(Shr(w[i-15], 3))));
            s1 := ORD(BITS(Rotr(w[i-2], 17)) / (BITS(Rotr(w[i-2], 19)) / BITS(Shr(w[i-2], 10))));
            w[i] := (w[i-16] + (s0 + (w[i-7] + s1))) MOD M32
        END;

        a := h[0]; b := h[1]; c := h[2]; d := h[3];
        e := h[4]; f := h[5]; g := h[6]; hh := h[7];

        FOR i := 0 TO 63 DO
            s1  := ORD(BITS(Rotr(e, 6)) / (BITS(Rotr(e, 11)) / BITS(Rotr(e, 25))));
            ch  := ORD((BITS(e) * BITS(f)) + (({0..31} - BITS(e)) * BITS(g)));
            t1  := (hh + (s1 + (ch + (K[i] + w[i])))) MOD M32;
            s0  := ORD(BITS(Rotr(a, 2)) / (BITS(Rotr(a, 13)) / BITS(Rotr(a, 22))));
            maj := ORD((BITS(a) * BITS(b)) + ((BITS(a) + BITS(b)) * BITS(c)));
            t2  := (s0 + maj) MOD M32;

            hh := g; g := f; f := e;
            e  := (d + t1) MOD M32;
            d  := c; c := b; b := a;
            a  := (t1 + t2) MOD M32
        END;

        h[0] := (h[0] + a) MOD M32; h[1] := (h[1] + b) MOD M32;
        h[2] := (h[2] + c) MOD M32; h[3] := (h[3] + d) MOD M32;
        h[4] := (h[4] + e) MOD M32; h[5] := (h[5] + f) MOD M32;
        h[6] := (h[6] + g) MOD M32; h[7] := (h[7] + hh) MOD M32
    END;

    FOR i := 0 TO 7 DO
        digest[i*4]   := (h[i] DIV 1000000H) MOD 256;
        digest[i*4+1] := (h[i] DIV 10000H) MOD 256;
        digest[i*4+2] := (h[i] DIV 100H) MOD 256;
        digest[i*4+3] := h[i] MOD 256
    END
END HashList;


BEGIN
    K[0]:=0428A2F98H; K[1]:=071374491H; K[2]:=0B5C0FBCFH; K[3]:=0E9B5DBA5H;
    K[4]:=03956C25BH; K[5]:=059F111F1H; K[6]:=0923F82A4H; K[7]:=0AB1C5ED5H;
    K[8]:=0D807AA98H; K[9]:=012835B01H; K[10]:=0243185BEH; K[11]:=0550C7DC3H;
    K[12]:=072BE5D74H; K[13]:=080DEB1FEH; K[14]:=09BDC06A7H; K[15]:=0C19BF174H;
    K[16]:=0E49B69C1H; K[17]:=0EFBE4786H; K[18]:=00FC19DC6H; K[19]:=0240CA1CCH;
    K[20]:=02DE92C6FH; K[21]:=04A7484AAH; K[22]:=05CB0A9DCH; K[23]:=076F988DAH;
    K[24]:=0983E5152H; K[25]:=0A831C66DH; K[26]:=0B00327C8H; K[27]:=0BF597FC7H;
    K[28]:=0C6E00BF3H; K[29]:=0D5A79147H; K[30]:=006CA6351H; K[31]:=014292967H;
    K[32]:=027B70A85H; K[33]:=02E1B2138H; K[34]:=04D2C6DFCH; K[35]:=053380D13H;
    K[36]:=0650A7354H; K[37]:=0766A0ABBH; K[38]:=081C2C92EH; K[39]:=092722C85H;
    K[40]:=0A2BFE8A1H; K[41]:=0A81A664BH; K[42]:=0C24B8B70H; K[43]:=0C76C51A3H;
    K[44]:=0D192E819H; K[45]:=0D6990624H; K[46]:=0F40E3585H; K[47]:=0106AA070H;
    K[48]:=019A4C116H; K[49]:=01E376C08H; K[50]:=02748774CH; K[51]:=034B0BCB5H;
    K[52]:=0391C0CB3H; K[53]:=04ED8AA4AH; K[54]:=05B9CCA4FH; K[55]:=0682E6FF3H;
    K[56]:=0748F82EEH; K[57]:=078A5636FH; K[58]:=084C87814H; K[59]:=08CC70208H;
    K[60]:=090BEFFFAH; K[61]:=0A4506CEBH; K[62]:=0BEF9A3F7H; K[63]:=0C67178F2H
END SHA256.
