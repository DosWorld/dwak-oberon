(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   A chunk heap with a page granularity, shared by every target.

   A chunk is a whole number of pages, rounded up to a power of two - and it
   is the chunk that is counted, header and payload together,
   not the payload on its own: class c is exactly PageSize*2^c bytes from
   the first byte of its header to the last byte of its payload, so no chunk
   straddles a page boundary and two chunks of the same class are
   interchangeable.  MaxChunk is the largest of them.  The payload a chunk
   hands out is that size less the header in front of it, MinPayload for the
   smallest class.  Alloc(n) serves any n from 1 to MaxPayload from the
   smallest class that holds it, so a caller can ask for a buffer whose size
   it only learns at run time - the fixed-length ARRAY a record has to
   declare is not the limit.  On a 16-bit target the page is 256 bytes and
   the largest chunk 4096, because a 4096-byte chunk is the whole of the RAM
   an MSP430 has.

   A chunk carries a header in front of its payload, and Alloc returns the
   address of the payload, not the address of the chunk: write at the value
   Alloc returned, and hand that value back to Free and Usable unchanged.
   The header keeps the class, which is what Usable reads and what tells
   Free which chunk it is being given back.  It is one word long, which is
   also what keeps a payload word-aligned - the property a caller depends on
   when it lays fixed-size elements out in a chunk.

   There is no free list of this module's own.  Free hands the chunk straight
   back to the target's allocator with DISPOSE, so a chunk that a structure
   gives up is available to the next request at once, of any class, without
   this module holding a list of them.  A chunk must be given back once: Free
   reads the class from the header, which a second Free would be reading from
   memory the allocator has already taken back.

   Requires SYSTEM and DISPOSE, which the Windows, Linux, DPMI32 and macOS
   targets provide; the targets that have no DISPOSE (MSP430, STM32, RVM)
   cannot build this module.  Not thread safe.
*)
MODULE Heap;

IMPORT SYSTEM;

CONST
    (* HeaderSize is the one word the header takes: the payload of class c is
       PageSize*2^c - HeaderSize, so that the chunk it belongs to - header and
       payload together - measures a whole number of pages. *)
    $IF (BITS_16)
        PageSize*   = 256;
        Classes*    = 5;
        HeaderSize* = 2;
        MaxChunk*   = 4096;         (* PageSize * 2^(Classes - 1) *)
    $ELSIF (BITS_64)
        PageSize*   = 4096;
        Classes*    = 13;
        HeaderSize* = 8;
        MaxChunk*   = 16777216;     (* PageSize * 2^(Classes - 1) *)
    $ELSE
        PageSize*   = 4096;
        Classes*    = 13;
        HeaderSize* = 4;
        MaxChunk*   = 16777216;     (* PageSize * 2^(Classes - 1) *)
    $END
    MinPayload* = PageSize - HeaderSize;    (* what the smallest chunk holds *)
    MaxPayload* = MaxChunk - HeaderSize;    (* and what the largest one holds *)

TYPE
    Header = RECORD
        tag: INTEGER
    END;
    HeaderPtr = POINTER TO Header;

    (* One type per class, because NEW takes a type and not a size.  Each is
       the header plus the payload that makes the chunk PageSize*2^c. *)
    $IF (BITS_16)
    P0  = POINTER TO RECORD h: Header; d: ARRAY PageSize - HeaderSize OF BYTE END;
    P1  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 2 - HeaderSize OF BYTE END;
    P2  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 4 - HeaderSize OF BYTE END;
    P3  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 8 - HeaderSize OF BYTE END;
    P4  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 16 - HeaderSize OF BYTE END;
    $ELSE
    P0  = POINTER TO RECORD h: Header; d: ARRAY PageSize - HeaderSize OF BYTE END;
    P1  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 2 - HeaderSize OF BYTE END;
    P2  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 4 - HeaderSize OF BYTE END;
    P3  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 8 - HeaderSize OF BYTE END;
    P4  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 16 - HeaderSize OF BYTE END;
    P5  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 32 - HeaderSize OF BYTE END;
    P6  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 64 - HeaderSize OF BYTE END;
    P7  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 128 - HeaderSize OF BYTE END;
    P8  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 256 - HeaderSize OF BYTE END;
    P9  = POINTER TO RECORD h: Header; d: ARRAY PageSize * 512 - HeaderSize OF BYTE END;
    P10 = POINTER TO RECORD h: Header; d: ARRAY PageSize * 1024 - HeaderSize OF BYTE END;
    P11 = POINTER TO RECORD h: Header; d: ARRAY PageSize * 2048 - HeaderSize OF BYTE END;
    P12 = POINTER TO RECORD h: Header; d: ARRAY PageSize * 4096 - HeaderSize OF BYTE END;
    $END

(* The smallest class whose payload holds n bytes.  The comparison is against
   the whole chunk, PageSize*2^c, and not against the payload, which is
   HeaderSize shorter: a request for one page needs a chunk of two, because a
   one-page chunk holds a page less the header.  Range-checked by Alloc. *)
PROCEDURE Class (n: INTEGER): INTEGER;
VAR
    size, c: INTEGER;

BEGIN
    size := PageSize; c := 0;
    WHILE size < n + HeaderSize DO
        size := size * 2; INC(c)
    END

    RETURN c
END Class;

(* A payload of n bytes.  What is returned is the payload; the chunk it
   belongs to begins HeaderSize bytes lower. *)
PROCEDURE Alloc* (n: INTEGER): INTEGER;
VAR
    c, a: INTEGER;
    h: HeaderPtr;
    $IF (BITS_16)
    p0: P0; p1: P1; p2: P2; p3: P3; p4: P4;
    $ELSE
    p0: P0; p1: P1; p2: P2; p3: P3; p4: P4; p5: P5;
    p6: P6; p7: P7; p8: P8; p9: P9; p10: P10; p11: P11; p12: P12;
    $END

BEGIN
    ASSERT((n > 0) & (n <= MaxPayload));
    c := Class(n);

    CASE c OF
    |0: NEW(p0); a := SYSTEM.VAL(INTEGER, p0)
    |1: NEW(p1); a := SYSTEM.VAL(INTEGER, p1)
    |2: NEW(p2); a := SYSTEM.VAL(INTEGER, p2)
    |3: NEW(p3); a := SYSTEM.VAL(INTEGER, p3)
    |4: NEW(p4); a := SYSTEM.VAL(INTEGER, p4)
    $IF (BITS_16)
    $ELSE
    |5: NEW(p5); a := SYSTEM.VAL(INTEGER, p5)
    |6: NEW(p6); a := SYSTEM.VAL(INTEGER, p6)
    |7: NEW(p7); a := SYSTEM.VAL(INTEGER, p7)
    |8: NEW(p8); a := SYSTEM.VAL(INTEGER, p8)
    |9: NEW(p9); a := SYSTEM.VAL(INTEGER, p9)
    |10: NEW(p10); a := SYSTEM.VAL(INTEGER, p10)
    |11: NEW(p11); a := SYSTEM.VAL(INTEGER, p11)
    |12: NEW(p12); a := SYSTEM.VAL(INTEGER, p12)
    $END
    END;

    h := SYSTEM.VAL(HeaderPtr, a);
    h.tag := c;

    RETURN a + HeaderSize
END Alloc;

(* Give the chunk whose payload starts at adr back to the target's allocator.
   The address must be one Alloc returned and must not be used afterwards. *)
PROCEDURE Free* (adr: INTEGER);
VAR
    block, c: INTEGER;
    h: HeaderPtr;
    $IF (BITS_16)
    p0: P0; p1: P1; p2: P2; p3: P3; p4: P4;
    $ELSE
    p0: P0; p1: P1; p2: P2; p3: P3; p4: P4; p5: P5;
    p6: P6; p7: P7; p8: P8; p9: P9; p10: P10; p11: P11; p12: P12;
    $END

BEGIN
    ASSERT(adr > HeaderSize);
    block := adr - HeaderSize;
    h := SYSTEM.VAL(HeaderPtr, block);
    c := h.tag;
    ASSERT((c >= 0) & (c < Classes));

    CASE c OF
    |0: p0 := SYSTEM.VAL(P0, block); DISPOSE(p0)
    |1: p1 := SYSTEM.VAL(P1, block); DISPOSE(p1)
    |2: p2 := SYSTEM.VAL(P2, block); DISPOSE(p2)
    |3: p3 := SYSTEM.VAL(P3, block); DISPOSE(p3)
    |4: p4 := SYSTEM.VAL(P4, block); DISPOSE(p4)
    $IF (BITS_16)
    $ELSE
    |5: p5 := SYSTEM.VAL(P5, block); DISPOSE(p5)
    |6: p6 := SYSTEM.VAL(P6, block); DISPOSE(p6)
    |7: p7 := SYSTEM.VAL(P7, block); DISPOSE(p7)
    |8: p8 := SYSTEM.VAL(P8, block); DISPOSE(p8)
    |9: p9 := SYSTEM.VAL(P9, block); DISPOSE(p9)
    |10: p10 := SYSTEM.VAL(P10, block); DISPOSE(p10)
    |11: p11 := SYSTEM.VAL(P11, block); DISPOSE(p11)
    |12: p12 := SYSTEM.VAL(P12, block); DISPOSE(p12)
    $END
    END
END Free;

(* The payload size of the chunk whose payload starts at adr: at least the
   size the chunk was asked for, and less than twice it.  Add HeaderSize to it
   and the chunk is a whole number of pages. *)
PROCEDURE Usable* (adr: INTEGER): INTEGER;
VAR
    block: INTEGER;
    h: HeaderPtr;

BEGIN
    ASSERT(adr > HeaderSize);
    block := adr - HeaderSize;
    h := SYSTEM.VAL(HeaderPtr, block);
    ASSERT((h.tag >= 0) & (h.tag < Classes));

    RETURN LSL(PageSize, h.tag) - HeaderSize
END Usable;

END Heap.
