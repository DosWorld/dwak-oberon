(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2018-2022, Anton Krotov
    All rights reserved.

    Files - buffered file access, shared by every target.

    This module is the one file interface a program should use.  It is
    written against the platform ArchFile module (lib/<target>/ArchFile.mod), which
    every platform supplies, and it adds the two things that module leaves
    out: a page cache and a set of typed accessors.

    The cache is the reason the module exists.  Every read and every write
    goes through an 8 KB buffer, so a program that walks a file byte by byte
    issues one system call per 8192 bytes instead of one per byte.  On
    dpmi32 that is the difference between usable and unusable: each DOS call
    there is a real-mode interrupt through the DPMI host.  8 KB is the size
    that pays for itself without wasting memory on the small targets, and it
    is the size the DOS version of this module used.

    Nothing here is DOS-specific.  The old module talked to EMS, to INT 21h
    and to the DOS file handle directly; all of that is gone, and the only
    platform dependency left is the ArchFile module.

    A File record is small and may be copied by value, but a copy shares
    the page buffer with the original, so only one of the two may be used.
    Open a file with Reset, ReWrite, Append or ReWriteTemp and release it
    with Close.
*)

MODULE Files;

IMPORT ArchFile, Strings, SYSTEM;


CONST

    (* The page cache.  A read or a write crosses into the platform
       ArchFile module once per BUFSIZE bytes, which is what makes
       byte-at-a-time access affordable - see the module comment. *)
    BUFSIZE* = 8192;

    (* BlockCopy stages through this buffer.  It lives on the stack, so it
       must stay small: a multi-kilobyte frame wraps SP on a 64-bit DOS
       build with the default stack and sprays the copied bytes over the
       heap.  Both files are buffered anyway, so a small chunk costs
       almost nothing. *)
    CopyChunk* = 1024;

    (* How the file was opened.  Reset produces ModeRead, ReWrite,
       Append and ReWriteTemp produce ModeWrite. *)
    ModeRead*  = 0;
    ModeWrite* = 1;

    (* Longest path this module remembers, and the size of the array that
       holds a generated temporary name. *)
    MaxPath = 256;
    MaxTemp = 16;

    (* ReadAsciizString reads at most this many bytes before the NUL.  A
       longer string is truncated; no caller in this tree comes close. *)
    MaxAsciiz = 1024;


TYPE

    (* A timestamp in the packed DOS form, which is the form the whole
       tree already speaks and the form every platform's ArchFile module
       converts to and from its own idea of a time.  Keeping it here
       rather than in a platform module means the same call works
       everywhere:
         bits  0..4  seconds DIV 2
         bits  5..10 minutes
         bits 11..15 hours
         bits 16..20 day
         bits 21..24 month
         bits 25..31 year - 1980 *)
    DosTime* = INTEGER;

    (* POINTER TO requires a record base, so the page buffer is wrapped
       in one.  Allocating it on the heap keeps a File record small enough
       to live on a stack.

       A closed file does not give its buffer back to the allocator: the
       buffer joins a free list, and the next file that needs one takes it
       from there.  That is not an optimisation, it is what makes the
       module portable - DISPOSE is a predefined procedure this compiler
       only provides for some targets, and the RVM targets are not among
       them, so a module meant to build everywhere cannot use it.  A
       program that opens files one after another holds one buffer for the
       whole run, and one that opens many at once holds one per file. *)
    FileBuf = RECORD
        next: POINTER TO FileBuf;         (* the free list link *)
        data: ARRAY BUFSIZE OF CHAR
    END;

    File* = RECORD
        handle:     INTEGER;              (* platform handle; -1 when closed *)
        name:       ARRAY MaxPath OF CHAR;
        buf:        POINTER TO FileBuf;   (* the page cache; NIL when closed *)
        page:       INTEGER;              (* which BUFSIZE-aligned page buf
                                             holds; -1 = none *)
        fill:       INTEGER;              (* bytes of buf that carry data *)
        cursor:     INTEGER;              (* where the next byte is read from
                                             or written to *)
        pending:    INTEGER;              (* a byte read ahead and put back,
                                             or -1; see ReadLine *)
        dirty:      BOOLEAN;              (* buf holds writes not yet flushed *)
        wrErr:      BOOLEAN;              (* latched flush failure; poll with Ok *)
        delOnClose: BOOLEAN;
        mode:       INTEGER;
        pos:        INTEGER;              (* logical cursor, absolute *)
        size:       INTEGER               (* logical file size *)
    END;


VAR

    tempSeq: INTEGER;

    (* Page buffers of closed files, ready for reuse.  See FileBuf. *)
    freeBuf: POINTER TO FileBuf;


(* CopyName - remember a path inside the file record.
   Parameters: F - the file; name - the path, up to the first NUL. *)
PROCEDURE CopyName (VAR F: File; name: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE (i < MaxPath - 1) & (i < LEN(name)) & (name[i] # 0X) DO
        F.name[i] := name[i];
        INC(i)
    END;
    F.name[i] := 0X
END CopyName;


(* EmitUtf8 - append the UTF-8 encoding of one code point to a string.
   A code point that is out of range or is a surrogate is written as
   U+FFFD, so the result is always well-formed UTF-8.  Nothing is written
   when the encoding would not fit beside the terminator, which is how
   ReadAsciizString truncates at the caller's array.
   Parameters: u - the code point; dst - the string; j - its length, updated. *)
PROCEDURE EmitUtf8 (u: INTEGER; VAR dst: ARRAY OF CHAR; VAR j: INTEGER);
VAR
    b: INTEGER;

BEGIN
    b := 0;
    IF (u < 0) OR (u > 10FFFFH) OR ((u >= 0D800H) & (u <= 0DFFFH)) THEN
        u := 0FFFDH
    END;

    IF u < 80H THEN
        b := 1
    ELSIF u < 800H THEN
        b := 2
    ELSIF u < 10000H THEN
        b := 3
    ELSE
        b := 4
    END;

    IF j < LEN(dst) - b THEN
        IF b = 1 THEN
            dst[j] := CHR(u)
        ELSIF b = 2 THEN
            dst[j]     := CHR(0C0H + u DIV 40H);
            dst[j + 1] := CHR(80H + u MOD 40H)
        ELSIF b = 3 THEN
            dst[j]     := CHR(0E0H + u DIV 1000H);
            dst[j + 1] := CHR(80H + (u DIV 40H) MOD 40H);
            dst[j + 2] := CHR(80H + u MOD 40H)
        ELSE
            dst[j]     := CHR(0F0H + u DIV 40000H);
            dst[j + 1] := CHR(80H + (u DIV 1000H) MOD 40H);
            dst[j + 2] := CHR(80H + (u DIV 40H) MOD 40H);
            dst[j + 3] := CHR(80H + u MOD 40H)
        END;
        INC(j, b)
    END
END EmitUtf8;


(* SeqLen - how many bytes a UTF-8 sequence starting with b occupies.
   Parameters: b - the lead byte.
   Result: 2, 3 or 4; 0 when b cannot start a sequence. *)
PROCEDURE SeqLen (b: INTEGER): INTEGER;
VAR
    n: INTEGER;

BEGIN
    IF (b >= 0C0H) & (b < 0E0H) THEN
        n := 2
    ELSIF (b >= 0E0H) & (b < 0F0H) THEN
        n := 3
    ELSIF (b >= 0F0H) & (b < 0F8H) THEN
        n := 4
    ELSE
        n := 0
    END;

    RETURN n
END SeqLen;


(* TailOk - whether the continuation bytes of a sequence are well formed.
   Parameters: raw - the bytes; i - index of the lead byte; need - the
   sequence length SeqLen answered.
   Result: TRUE when the need-1 bytes after i are all 80X..0BFX. *)
PROCEDURE TailOk (VAR raw: ARRAY OF BYTE; i, need: INTEGER): BOOLEAN;
VAR
    k: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := TRUE;
    k := 1;
    WHILE ok & (k < need) DO
        IF (raw[i + k] < 80H) OR (raw[i + k] > 0BFH) THEN
            ok := FALSE
        END;
        INC(k)
    END;

    RETURN ok
END TailOk;


(* DecodeUtf16 - decode the code units of a byte order marked string.
   Parameters: raw - the bytes; n - how many of them there are; start -
   where the units begin, past the mark; le - TRUE for little endian;
   dst - receives UTF-8; j - its length, updated.
   A lone surrogate is written as U+FFFD rather than silently dropped. *)
PROCEDURE DecodeUtf16 (VAR raw: ARRAY OF BYTE; n, start: INTEGER; le: BOOLEAN;
                       VAR dst: ARRAY OF CHAR; VAR j: INTEGER);
VAR
    i, u, k: INTEGER;
    done: BOOLEAN;

BEGIN
    i := start;
    done := FALSE;

    WHILE ~done & (i + 1 < n) DO
        IF le THEN
            u := raw[i] + raw[i + 1] * 100H
        ELSE
            u := raw[i] * 100H + raw[i + 1]
        END;
        INC(i, 2);

        IF u = 0 THEN
            done := TRUE
        ELSE
            IF (u >= 0D800H) & (u <= 0DBFFH) & (i + 1 < n) THEN
                (* a high surrogate pairs with the unit that follows *)
                IF le THEN
                    k := raw[i] + raw[i + 1] * 100H
                ELSE
                    k := raw[i] * 100H + raw[i + 1]
                END;
                IF (k >= 0DC00H) & (k <= 0DFFFH) THEN
                    u := 10000H + (u - 0D800H) * 400H + (k - 0DC00H);
                    INC(i, 2);
                    EmitUtf8(u, dst, j)
                ELSE
                    EmitUtf8(0FFFDH, dst, j)
                END
            ELSE
                EmitUtf8(u, dst, j)
            END
        END
    END
END DecodeUtf16;


PROCEDURE BufAlloc (VAR F: File): BOOLEAN;
VAR
    ok: BOOLEAN;

BEGIN
    IF F.buf = NIL THEN
        IF freeBuf # NIL THEN
            F.buf := freeBuf;
            freeBuf := freeBuf.next;
            F.buf.next := NIL
        ELSE
            NEW(F.buf)
        END
    END;
    ok := F.buf # NIL;

    RETURN ok
END BufAlloc;


(* BufRelease - hand the page buffer back for reuse.  The file no longer
   has one afterwards, so this is the last thing Close does with it.
   Parameters: F - the file. *)
PROCEDURE BufRelease (VAR F: File);
BEGIN
    IF F.buf # NIL THEN
        F.buf.next := freeBuf;
        freeBuf := F.buf;
        F.buf := NIL
    END
END BufRelease;


(* BufFlush - write the page cache back to the file when it holds writes.
   A failure is latched in wrErr instead of being raised, so the caller
   sees it at the end through Ok rather than at whatever random write
   happened to hit it.
   Parameters: F - the file. *)
PROCEDURE BufFlush (VAR F: File);
VAR
    n: INTEGER;

BEGIN
    IF F.dirty & ArchFile.Valid(F.handle) THEN
        F.dirty := FALSE;
        IF ArchFile.Seek(F.handle, F.page * BUFSIZE, ArchFile.SEEK_BEG) < 0 THEN
            F.wrErr := TRUE
        ELSE
            n := ArchFile.Write(F.handle, SYSTEM.ADR(F.buf.data[0]), F.fill);
            IF n # F.fill THEN
                F.wrErr := TRUE
            END
        END
    END
END BufFlush;


(* BufFetch - bring one page of the file into the cache, flushing the
   page that is there first.  A page past the end of the file, and any
   page of an empty file, simply leaves the cache empty.
   Parameters: F - the file; page - which page, counted in BUFSIZE units. *)
PROCEDURE BufFetch (VAR F: File; page: INTEGER);
VAR
    n: INTEGER;

BEGIN
    IF page # F.page THEN
        BufFlush(F);
        F.page := page;
        F.fill := 0;
        F.cursor := 0;
        IF ArchFile.Valid(F.handle) & (page >= 0) THEN
            IF ArchFile.Seek(F.handle, page * BUFSIZE, ArchFile.SEEK_BEG) >= 0 THEN
                n := ArchFile.Read(F.handle, SYSTEM.ADR(F.buf.data[0]), BUFSIZE);
                IF n > 0 THEN
                    F.fill := n
                END
            END
        END
    END
END BufFetch;


PROCEDURE NextPage (VAR F: File);
BEGIN
    BufFetch(F, F.page + 1);
    F.cursor := 0
END NextPage;


(* AbsPos - the absolute file offset the cache cursor stands at.
   Parameters: F - the file.
   Result: that offset. *)
PROCEDURE AbsPos (VAR F: File): INTEGER;
BEGIN
    RETURN F.page * BUFSIZE + F.cursor
END AbsPos;


(* SyncPos - carry the cache cursor into the logical position.
   Parameters: F - the file; grow - TRUE to let the file size follow a
   write that ran past the old end. *)
PROCEDURE SyncPos (VAR F: File; grow: BOOLEAN);
VAR
    p: INTEGER;

BEGIN
    IF F.page >= 0 THEN
        p := AbsPos(F);
        F.pos := p;
        IF grow & (p > F.size) THEN
            F.size := p
        END
    END
END SyncPos;


(* Ok - whether every buffered write so far reached the file.  The flag
   survives Close, so `Close(F); IF ~Ok(F) THEN ... END` catches the last
   flush too.
   Parameters: F - the file, open or already closed.
   Result: TRUE when no flush has failed. *)
PROCEDURE Ok* (VAR F: File): BOOLEAN;
BEGIN
    RETURN ~F.wrErr
END Ok;


(* Position - the current read/write cursor.
   Parameters: F - the file.
   Result: the byte offset from the start of the file. *)
PROCEDURE Position* (VAR F: File): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF F.buf = NIL THEN
        res := F.pos
    ELSE
        res := AbsPos(F)
    END;

    RETURN res
END Position;


(* Size - the current size of the file, which is the size it had when it
   was opened plus anything written since.
   Parameters: F - the file.
   Result: the size in bytes. *)
PROCEDURE Size* (VAR F: File): INTEGER;
VAR
    res, p: INTEGER;

BEGIN
    res := F.size;
    IF F.buf # NIL THEN
        p := AbsPos(F);
        IF p > res THEN
            res := p
        END
    END;

    RETURN res
END Size;


(* ClampLen - how much may be read before the end of the file.
   Parameters: F - the file; len - what the caller asked for.
   Result: len, or the bytes left, whichever is smaller. *)
PROCEDURE ClampLen (VAR F: File; len: INTEGER): INTEGER;
VAR
    rem, res: INTEGER;

BEGIN
    rem := Size(F) - Position(F);
    IF rem < 0 THEN
        rem := 0
    END;
    IF len > rem THEN
        res := rem
    ELSE
        res := len
    END;
    IF res < 0 THEN
        res := 0
    END;

    RETURN res
END ClampLen;


(* Seek - move the read/write cursor to an absolute position, clamped to
   the file.  Moving within the cached page costs nothing; moving out of
   it flushes the page and reads the new one.
   Parameters: F - the file; pos - the target byte offset. *)
PROCEDURE Seek* (VAR F: File; pos: INTEGER);
BEGIN
    IF pos < 0 THEN
        pos := 0
    END;
    IF pos > Size(F) THEN
        pos := Size(F)
    END;

    IF F.buf # NIL THEN
        BufFetch(F, pos DIV BUFSIZE);
        F.cursor := pos MOD BUFSIZE
    END;
    F.pos := pos
END Seek;


(* BlockRead - read bytes from the file into a buffer, advancing the
   cursor.  Reads stop at the end of the file.
   Parameters: F - the file; x - receives the bytes; len - how many are
   wanted.
   Result: how many were read, less than len only at end of file. *)
PROCEDURE BlockRead* (VAR F: File; VAR x: ARRAY OF BYTE; len: INTEGER): INTEGER;
VAR
    total, avail, delta, i, base: INTEGER;
    more: BOOLEAN;

BEGIN
    len := ClampLen(F, MIN(len, LEN(x)));
    total := 0;
    more := (F.buf # NIL) & (len > 0);

    WHILE more DO
        avail := F.fill - F.cursor;
        IF avail <= 0 THEN
            IF AbsPos(F) < F.size THEN
                NextPage(F);
                avail := F.fill
            END
        END;

        IF avail <= 0 THEN
            more := FALSE
        ELSE
            delta := len - total;
            IF delta > avail THEN
                delta := avail
            END;
            base := F.cursor;
            i := 0;
            WHILE i < delta DO
                x[total + i] := ORD(F.buf.data[base + i]);
                INC(i)
            END;
            INC(F.cursor, delta);
            INC(total, delta);
            IF total >= len THEN
                more := FALSE
            END
        END
    END;

    SyncPos(F, FALSE);
    RETURN total
END BlockRead;


(* BlockWrite - write bytes from a buffer into the file, advancing the
   cursor and growing the file when the write runs past its end.
   Unlike BlockRead, x is read only: the callee never writes to it, so the
   parameter is a value rather than a VAR.  That is what lets a caller
   forward a buffer it received as a read-only open array of its own - the
   compiler's WRITER.Write does exactly that - and it costs nothing,
   because an open array is passed by reference either way.
   Parameters: F - the file; x - the bytes to write; len - how many.
   Result: how many were taken from x. *)
PROCEDURE BlockWrite* (VAR F: File; x: ARRAY OF BYTE; len: INTEGER): INTEGER;
VAR
    total, room, delta, i, base: INTEGER;

BEGIN
    len := MIN(len, LEN(x));
    total := 0;

    IF (F.buf # NIL) & (len > 0) THEN
        WHILE total < len DO
            IF F.cursor = BUFSIZE THEN
                SyncPos(F, TRUE);
                NextPage(F)
            END;
            room := BUFSIZE - F.cursor;
            delta := len - total;
            IF delta > room THEN
                delta := room
            END;
            base := F.cursor;
            i := 0;
            WHILE i < delta DO
                F.buf.data[base + i] := CHR(x[total + i]);
                INC(i)
            END;
            F.dirty := TRUE;
            INC(F.cursor, delta);
            IF F.cursor > F.fill THEN
                F.fill := F.cursor
            END;
            INC(total, delta)
        END;
        SyncPos(F, TRUE)
    END;

    RETURN total
END BlockWrite;


(* BlockReadText - read bytes into a character buffer.  This is BlockRead
   for callers whose buffer is text, and it is not a convenience wrapper
   around it: the page cache is made of characters, so the bytes move
   across with no conversion at all.
   Parameters: F - the file; x - receives the characters; len - how many
   are wanted.
   Result: how many were read, less than len only at end of file. *)
PROCEDURE BlockReadText* (VAR F: File; VAR x: ARRAY OF CHAR; len: INTEGER): INTEGER;
VAR
    total, avail, delta, i, base: INTEGER;
    more: BOOLEAN;

BEGIN
    len := ClampLen(F, MIN(len, LEN(x)));
    total := 0;
    more := (F.buf # NIL) & (len > 0);

    WHILE more DO
        avail := F.fill - F.cursor;
        IF avail <= 0 THEN
            IF AbsPos(F) < F.size THEN
                NextPage(F);
                avail := F.fill
            END
        END;

        IF avail <= 0 THEN
            more := FALSE
        ELSE
            delta := len - total;
            IF delta > avail THEN
                delta := avail
            END;
            base := F.cursor;
            i := 0;
            WHILE i < delta DO
                x[total + i] := F.buf.data[base + i];
                INC(i)
            END;
            INC(F.cursor, delta);
            INC(total, delta);
            IF total >= len THEN
                more := FALSE
            END
        END
    END;

    SyncPos(F, FALSE);
    RETURN total
END BlockReadText;


(* BlockWriteText - write characters from a buffer, growing the file when
   the write runs past its end.  This is BlockWrite for text, and like
   BlockReadText it moves the characters with no conversion.  As with
   BlockWrite, x is read only.
   Parameters: F - the file; x - the characters to write; len - how many.
   Result: how many were taken from x. *)
PROCEDURE BlockWriteText* (VAR F: File; x: ARRAY OF CHAR; len: INTEGER): INTEGER;
VAR
    total, room, delta, i, base: INTEGER;

BEGIN
    len := MIN(len, LEN(x));
    total := 0;

    IF (F.buf # NIL) & (len > 0) THEN
        WHILE total < len DO
            IF F.cursor = BUFSIZE THEN
                SyncPos(F, TRUE);
                NextPage(F)
            END;
            room := BUFSIZE - F.cursor;
            delta := len - total;
            IF delta > room THEN
                delta := room
            END;
            base := F.cursor;
            i := 0;
            WHILE i < delta DO
                F.buf.data[base + i] := x[total + i];
                INC(i)
            END;
            F.dirty := TRUE;
            INC(F.cursor, delta);
            IF F.cursor > F.fill THEN
                F.fill := F.cursor
            END;
            INC(total, delta)
        END;
        SyncPos(F, TRUE)
    END;

    RETURN total
END BlockWriteText;


(* WriteByte - write one byte at the cursor.  The byte lands in the page
   cache; it reaches the file when the page fills or Close runs.
   Parameters: F - the file; b - the byte.
   Result: 1 when it was buffered, 0 when the file is closed. *)
PROCEDURE WriteByte* (VAR F: File; b: BYTE): INTEGER;
VAR
    n: INTEGER;

BEGIN
    n := 0;
    IF F.buf # NIL THEN
        IF F.cursor = BUFSIZE THEN
            SyncPos(F, TRUE);
            NextPage(F)
        END;
        F.buf.data[F.cursor] := CHR(b);
        F.dirty := TRUE;
        INC(F.cursor);
        IF F.cursor > F.fill THEN
            F.fill := F.cursor;
            SyncPos(F, TRUE)
        END;
        n := 1
    END;

    RETURN n
END WriteByte;


(* WriteWord - write a 16-bit value, low byte first.
   Parameters: F - the file; w - the value.
   Result: 2 when it was written, 0 when the file is closed. *)
PROCEDURE WriteWord* (VAR F: File; w: INTEGER): INTEGER;
VAR
    n: INTEGER;

BEGIN
    n := 0;
    IF F.buf # NIL THEN
        IF F.cursor <= BUFSIZE - 2 THEN
            F.buf.data[F.cursor]     := CHR(w MOD 100H);
            F.buf.data[F.cursor + 1] := CHR((w DIV 100H) MOD 100H);
            F.dirty := TRUE;
            INC(F.cursor, 2);
            IF F.cursor > F.fill THEN
                F.fill := F.cursor
            END;
            SyncPos(F, TRUE);
            n := 2
        ELSE
            n := WriteByte(F, w MOD 100H);
            n := n + WriteByte(F, (w DIV 100H) MOD 100H)
        END
    END;

    RETURN n
END WriteWord;


(* WriteDWord - write a 32-bit value, low byte first.
   Parameters: F - the file; w - the value.
   Result: 4 when it was written, fewer when the file is closed. *)
PROCEDURE WriteDWord* (VAR F: File; w: INTEGER): INTEGER;
VAR
    n: INTEGER;

BEGIN
    n := 0;
    IF F.buf # NIL THEN
        IF F.cursor <= BUFSIZE - 4 THEN
            F.buf.data[F.cursor]     := CHR(w MOD 100H);
            F.buf.data[F.cursor + 1] := CHR((w DIV 100H) MOD 100H);
            F.buf.data[F.cursor + 2] := CHR((w DIV 10000H) MOD 100H);
            F.buf.data[F.cursor + 3] := CHR((w DIV 1000000H) MOD 100H);
            F.dirty := TRUE;
            INC(F.cursor, 4);
            IF F.cursor > F.fill THEN
                F.fill := F.cursor
            END;
            SyncPos(F, TRUE);
            n := 4
        ELSE
            n := WriteByte(F, w MOD 100H);
            n := n + WriteByte(F, (w DIV 100H) MOD 100H);
            n := n + WriteByte(F, (w DIV 10000H) MOD 100H);
            n := n + WriteByte(F, (w DIV 1000000H) MOD 100H)
        END
    END;

    RETURN n
END WriteDWord;


(* ReadByte - read one byte at the cursor.
   Parameters: F - the file; b - receives the byte, 0 at end of file.
   Result: TRUE when a byte was read. *)
PROCEDURE ReadByte* (VAR F: File; VAR b: BYTE): BOOLEAN;
VAR
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    b := 0;

    IF F.pending >= 0 THEN
        b := F.pending;
        F.pending := -1;
        ok := TRUE
    ELSIF F.buf # NIL THEN
        IF F.cursor >= F.fill THEN
            IF AbsPos(F) < F.size THEN
                NextPage(F);
                SyncPos(F, FALSE)
            END
        END;
        IF F.cursor < F.fill THEN
            b := ORD(F.buf.data[F.cursor]);
            INC(F.cursor);
            SyncPos(F, FALSE);
            ok := TRUE
        END
    END;

    RETURN ok
END ReadByte;


(* ReadWord - read a 16-bit value, low byte first.
   Parameters: F - the file; w - receives the value, 0 at end of file.
   Result: TRUE when both bytes were read. *)
PROCEDURE ReadWord* (VAR F: File; VAR w: INTEGER): BOOLEAN;
VAR
    lo, hi: BYTE;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    w := 0;

    IF (F.buf # NIL) & (F.cursor + 2 <= F.fill) THEN
        w := ORD(F.buf.data[F.cursor]) +
             ORD(F.buf.data[F.cursor + 1]) * 100H;
        INC(F.cursor, 2);
        SyncPos(F, FALSE);
        ok := TRUE
    ELSIF ReadByte(F, lo) & ReadByte(F, hi) THEN
        w := lo + hi * 100H;
        ok := TRUE
    END;

    RETURN ok
END ReadWord;


(* ReadDWord - read a 32-bit value, low byte first.
   Parameters: F - the file; w - receives the value, 0 at end of file.
   Result: TRUE when all four bytes were read. *)
PROCEDURE ReadDWord* (VAR F: File; VAR w: INTEGER): BOOLEAN;
VAR
    w1, w2: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    w := 0;

    IF (F.buf # NIL) & (F.cursor + 4 <= F.fill) THEN
        w1 := ORD(F.buf.data[F.cursor]) +
              ORD(F.buf.data[F.cursor + 1]) * 100H;
        w2 := ORD(F.buf.data[F.cursor + 2]) +
              ORD(F.buf.data[F.cursor + 3]) * 100H;
        INC(F.cursor, 4);
        SyncPos(F, FALSE);
        w := w1 + w2 * 10000H;
        ok := TRUE
    ELSIF ReadWord(F, w1) & ReadWord(F, w2) THEN
        w := w1 + w2 * 10000H;
        ok := TRUE
    END;

    RETURN ok
END ReadDWord;


(* ReadAsciizString - read a NUL-terminated string and hand it back as
   UTF-8, which is the encoding this tree uses for text everywhere.

   The bytes on disk decide how that is done.  A string that opens with a
   byte order mark is UTF-16 and is decoded; anything else is taken to be
   UTF-8 already, and is copied across with every malformed sequence
   replaced by U+FFFD.  So the result is valid UTF-8 whatever was in the
   file, and a caller never has to check.

   Parameters: f - the file; dst - receives the string, always terminated,
   truncated to fit. *)
PROCEDURE ReadAsciizString* (VAR f: File; VAR dst: ARRAY OF CHAR);
VAR
    raw: ARRAY MaxAsciiz OF BYTE;
    n, i, j, u, need: INTEGER;
    b: BYTE;
    done: BOOLEAN;

BEGIN
    n := 0;
    done := FALSE;
    WHILE ~done & (n < MaxAsciiz) DO
        IF ReadByte(f, b) & (b # 0) THEN
            raw[n] := b;
            INC(n)
        ELSE
            done := TRUE
        END
    END;

    j := 0;
    IF (n >= 2) & (raw[0] = 0FFH) & (raw[1] = 0FEH) THEN
        DecodeUtf16(raw, n, 2, TRUE, dst, j)
    ELSIF (n >= 2) & (raw[0] = 0FEH) & (raw[1] = 0FFH) THEN
        DecodeUtf16(raw, n, 2, FALSE, dst, j)
    ELSE
        i := 0;
        WHILE i < n DO
            IF raw[i] < 80H THEN
                EmitUtf8(raw[i], dst, j);
                INC(i)
            ELSE
                need := SeqLen(raw[i]);
                IF (need > 0) & (i + need <= n) & TailOk(raw, i, need) THEN
                    IF need = 2 THEN
                        u := raw[i] - 0C0H
                    ELSIF need = 3 THEN
                        u := raw[i] - 0E0H
                    ELSE
                        u := raw[i] - 0F0H
                    END;
                    u := u * 40H + (raw[i + 1] - 80H);
                    IF need >= 3 THEN
                        u := u * 40H + (raw[i + 2] - 80H)
                    END;
                    IF need = 4 THEN
                        u := u * 40H + (raw[i + 3] - 80H)
                    END;
                    EmitUtf8(u, dst, j);
                    INC(i, need)
                ELSE
                    EmitUtf8(0FFFDH, dst, j);
                    INC(i)
                END
            END
        END
    END;

    IF j < LEN(dst) THEN
        dst[j] := 0X
    END
END ReadAsciizString;


(* ReadLine - read one line as text, stopping at LF, at CR, or at end of
   file.  The terminator is consumed and not stored.  The LF of a CRLF
   pair is consumed with the CR, and a byte that follows a lone CR is put
   back, so the next line starts where it should.
   Parameters: f - the file; buf - receives the line, always terminated;
   maxLen - how much of buf may be used.
   Result: the number of characters stored, excluding the terminator. *)
PROCEDURE ReadLine* (VAR f: File; VAR buf: ARRAY OF CHAR; maxLen: INTEGER): INTEGER;
VAR
    b: BYTE;
    len, cap: INTEGER;
    done: BOOLEAN;

BEGIN
    len := 0;
    cap := maxLen;
    IF cap > LEN(buf) - 1 THEN
        cap := LEN(buf) - 1
    END;
    done := FALSE;

    WHILE ~done DO
        IF ~ReadByte(f, b) THEN
            done := TRUE
        ELSIF b = 0DH THEN
            IF ReadByte(f, b) & (b # 0AH) THEN
                f.pending := b
            END;
            done := TRUE
        ELSIF b = 0AH THEN
            done := TRUE
        ELSIF len < cap THEN
            buf[len] := CHR(b);
            INC(len)
        ELSE
            (* the line is longer than the caller's buffer: stop, and leave
               the rest of it unread rather than discarding it silently *)
            done := TRUE
        END
    END;

    buf[len] := 0X;
    RETURN len
END ReadLine;


(* WriteLn - write a CRLF line terminator.
   Parameters: f - the file.
   Result: the number of bytes written. *)
PROCEDURE WriteLn* (VAR f: File): INTEGER;
BEGIN
    RETURN WriteWord(f, 0A0DH)
END WriteLn;


(* Write - write a string's characters, with no terminator.
   Parameters: f - the file; line - the string.
   Result: the number of bytes written. *)
PROCEDURE Write* (VAR f: File; line: ARRAY OF CHAR): INTEGER;
VAR
    buf: ARRAY CopyChunk OF BYTE;
    len, n, i, total: INTEGER;
    done: BOOLEAN;

BEGIN
    len := Strings.Length(line);
    total := 0;
    done := FALSE;

    WHILE ~done & (total < len) DO
        n := len - total;
        IF n > CopyChunk THEN
            n := CopyChunk
        END;
        i := 0;
        WHILE i < n DO
            buf[i] := ORD(line[total + i]);
            INC(i)
        END;
        IF BlockWrite(f, buf, n) # n THEN
            done := TRUE
        ELSE
            INC(total, n)
        END
    END;

    RETURN total
END Write;


(* WriteLine - write a string followed by a CRLF.
   Parameters: f - the file; line - the string.
   Result: the number of bytes written, terminator included. *)
PROCEDURE WriteLine* (VAR f: File; line: ARRAY OF CHAR): INTEGER;
BEGIN
    RETURN Write(f, line) + WriteLn(f)
END WriteLine;


(* Eof - whether the cursor stands at the end of the file.
   Parameters: F - the file.
   Result: TRUE at end of file. *)
PROCEDURE Eof* (VAR F: File): BOOLEAN;
BEGIN
    RETURN Size(F) <= Position(F)
END Eof;


(* Truncate - cut the file off at the cursor, discarding what follows it.
   Parameters: F - the open file. *)
PROCEDURE Truncate* (VAR F: File);
VAR
    pos: INTEGER;
    ok: BOOLEAN;

BEGIN
    pos := Position(F);
    BufFlush(F);

    IF F.buf # NIL THEN
        IF pos > F.page * BUFSIZE THEN
            F.fill := pos - F.page * BUFSIZE
        ELSE
            F.fill := 0
        END;
        F.cursor := F.fill
    END;
    F.size := pos;
    F.pos := pos;

    IF ArchFile.Valid(F.handle) THEN
        ok := ArchFile.Truncate(F.handle, pos);
        IF ~ok THEN
            F.wrErr := TRUE
        END
    END
END Truncate;


(* MakeTempName - build a temporary file's name from a counter, so that
   two files opened in one run cannot collide.
   Parameters: dst - receives the name, always terminated. *)
PROCEDURE MakeTempName (VAR dst: ARRAY OF CHAR);
VAR
    i, v: INTEGER;

BEGIN
    INC(tempSeq);
    v := tempSeq;
    i := 0;
    WHILE i < 8 DO
        dst[7 - i] := CHR(ORD("0") + v MOD 10);
        v := v DIV 10;
        INC(i)
    END;
    dst[8] := "."; dst[9] := "T"; dst[10] := "M"; dst[11] := "P"; dst[12] := 0X
END MakeTempName;


(* Reset - open an existing file for reading and writing, positioned at
   the start.
   Parameters: F - the file record to set up; name - the path.
   Result: TRUE when the file was opened. *)
PROCEDURE Reset* (VAR F: File; name: ARRAY OF CHAR): BOOLEAN;
VAR
    h: INTEGER;
    ok: BOOLEAN;

BEGIN
    F.handle := -1;
    F.buf := NIL;
    F.page := -1;
    F.fill := 0;
    F.cursor := 0;
    F.pending := -1;
    F.dirty := FALSE;
    F.wrErr := FALSE;
    F.delOnClose := FALSE;
    F.mode := ModeRead;
    F.pos := 0;
    F.size := 0;
    CopyName(F, name);

    h := ArchFile.Open(name, ArchFile.OPEN_RW);
    IF ~ArchFile.Valid(h) THEN
        (* A read-write open is asked for first because that is what makes
           IncB, DecB and Truncate work on a file this call returned.  A
           file that is merely read only is not an error here, though:
           Reset is a read, so it is opened read only and the file still
           reads.  A write to it then fails at the flush and shows up
           through Ok. *)
        h := ArchFile.Open(name, ArchFile.OPEN_R)
    END;
    ok := ArchFile.Valid(h);

    IF ok THEN
        F.handle := h;
        F.size := ArchFile.Seek(h, 0, ArchFile.SEEK_END);
        IF F.size < 0 THEN
            F.size := 0
        END;
        IF ArchFile.Seek(h, 0, ArchFile.SEEK_BEG) < 0 THEN
            F.size := 0
        END;
        ok := BufAlloc(F);
        IF ok THEN
            BufFetch(F, 0)
        ELSE
            ArchFile.Close(h);
            F.handle := -1
        END
    END;

    RETURN ok
END Reset;


(* ReWrite - create a file, or empty it if it is already there, and open
   it for writing.
   Parameters: F - the file record to set up; name - the path.
   Result: TRUE when the file was created. *)
PROCEDURE ReWrite* (VAR F: File; name: ARRAY OF CHAR): BOOLEAN;
VAR
    h: INTEGER;
    ok: BOOLEAN;

BEGIN
    F.handle := -1;
    F.buf := NIL;
    F.page := 0;
    F.fill := 0;
    F.cursor := 0;
    F.pending := -1;
    F.dirty := FALSE;
    F.wrErr := FALSE;
    F.delOnClose := FALSE;
    F.mode := ModeWrite;
    F.pos := 0;
    F.size := 0;
    CopyName(F, name);

    h := ArchFile.Create(name);
    ok := ArchFile.Valid(h);

    IF ok THEN
        F.handle := h;
        ok := BufAlloc(F);
        IF ~ok THEN
            ArchFile.Close(h);
            F.handle := -1
        END
    END;

    RETURN ok
END ReWrite;


(* Append - open a file for writing at its end, creating it if it is not
   there yet.
   Parameters: F - the file record to set up; name - the path.
   Result: TRUE when the file is ready for writing. *)
PROCEDURE Append* (VAR F: File; name: ARRAY OF CHAR): BOOLEAN;
VAR
    ok: BOOLEAN;

BEGIN
    IF ArchFile.Exists(name) THEN
        ok := Reset(F, name);
        IF ok THEN
            F.mode := ModeWrite;
            Seek(F, Size(F))
        END
    ELSE
        ok := ReWrite(F, name)
    END;

    RETURN ok
END Append;


(* ReWriteTemp - create a temporary file for writing, named after a
   counter in the current directory and removed by Close.
   Parameters: F - the file record to set up.
   Result: TRUE when the file was created. *)
PROCEDURE ReWriteTemp* (VAR F: File): BOOLEAN;
VAR
    name: ARRAY MaxTemp OF CHAR;
    ok: BOOLEAN;

BEGIN
    MakeTempName(name);
    ok := ReWrite(F, name);
    IF ok THEN
        F.delOnClose := TRUE
    END;

    RETURN ok
END ReWriteTemp;


(* Delete - remove a file.
   Parameters: FileName - the path.
   Result: TRUE when it was removed. *)
PROCEDURE Delete* (FileName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN ArchFile.Delete(FileName)
END Delete;


(* SetDeleteOnClose - arrange for Close to remove the file.
   Parameters: F - the open file; delOnClose - TRUE to remove it. *)
PROCEDURE SetDeleteOnClose* (VAR F: File; delOnClose: BOOLEAN);
BEGIN
    F.delOnClose := delOnClose
END SetDeleteOnClose;


(* Close - write the page cache back to the file, release the file and the
   cache, and remove the file when SetDeleteOnClose asked for it.  A file
   that is not open is left alone, so closing twice is safe.
   Parameters: F - the file. *)
PROCEDURE Close* (VAR F: File);
BEGIN
    IF ArchFile.Valid(F.handle) THEN
        BufFlush(F);
        ArchFile.Close(F.handle);
        F.handle := -1;
        IF F.delOnClose THEN
            F.delOnClose := FALSE;
            IF ~ArchFile.Delete(F.name) THEN
                F.wrErr := TRUE
            END
        END
    END;

    IF F.buf # NIL THEN
        BufRelease(F);
        F.page := -1
    END
END Close;


(* Rename - rename or move a file.
   Parameters: OldName - the current path; NewName - the new path.
   Result: TRUE when the rename succeeded. *)
PROCEDURE Rename* (OldName, NewName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN ArchFile.Rename(OldName, NewName)
END Rename;


(* BlockCopy - copy len bytes from one open file to another, staged through
   a small stack buffer (see CopyChunk for why it must stay small).  Both
   files are cached, so the small chunk costs almost nothing.
   Parameters: src - read from its cursor; dst - written from its cursor;
   len - how many bytes.
   Result: TRUE when all len bytes were copied. *)
PROCEDURE BlockCopy* (VAR src, dst: File; len: INTEGER): BOOLEAN;
VAR
    buf: ARRAY CopyChunk OF BYTE;
    n, left: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := TRUE;
    left := len;

    WHILE ok & (left > 0) DO
        n := left;
        IF n > CopyChunk THEN
            n := CopyChunk
        END;
        n := BlockRead(src, buf, n);
        IF n = 0 THEN
            ok := FALSE
        ELSIF BlockWrite(dst, buf, n) # n THEN
            ok := FALSE
        ELSE
            DEC(left, n)
        END
    END;

    RETURN ok
END BlockCopy;


(* Copy - copy a whole file to another path.
   Parameters: src - the path to read; dst - the path to write.
   Result: TRUE when the copy completed. *)
PROCEDURE Copy* (src, dst: ARRAY OF CHAR): BOOLEAN;
VAR
    fSrc, fDst: File;
    res: BOOLEAN;

BEGIN
    IF Reset(fSrc, src) THEN
        IF ReWrite(fDst, dst) THEN
            res := BlockCopy(fSrc, fDst, Size(fSrc));
            Close(fDst)
        ELSE
            res := FALSE
        END;
        Close(fSrc)
    ELSE
        res := FALSE
    END;

    RETURN res
END Copy;


(* ReplaceExt - build a path with its extension replaced: everything from
   the last dot after the last separator is dropped and newExt put in its
   place.  A path with no extension simply gets newExt appended.
   Parameters: path - the source path; newExt - the new extension,
   including its leading dot; dst - receives the result. *)
PROCEDURE ReplaceExt* (path, newExt: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR
    i, dot, sep, n: INTEGER;

BEGIN
    dot := -1;
    sep := -1;
    i := 0;
    WHILE (i < LEN(path)) & (path[i] # 0X) DO
        IF path[i] = "." THEN
            dot := i
        ELSIF (path[i] = "/") OR (path[i] = "\") OR (path[i] = ":") THEN
            sep := i
        END;
        INC(i)
    END;
    IF dot <= sep THEN
        dot := i
    END;

    n := 0;
    WHILE (n < dot) & (n < LEN(dst) - 1) DO
        dst[n] := path[n];
        INC(n)
    END;

    i := 0;
    WHILE (i < LEN(newExt)) & (newExt[i] # 0X) & (n < LEN(dst) - 1) DO
        dst[n] := newExt[i];
        INC(n);
        INC(i)
    END;

    dst[n] := 0X
END ReplaceExt;


(* FileExists - whether a file exists.
   Parameters: FileName - the path.
   Result: TRUE when it is there. *)
PROCEDURE FileExists* (FileName: ARRAY OF CHAR): BOOLEAN;
BEGIN
    RETURN ArchFile.Exists(FileName)
END FileExists;


(* GetFTime - read the file's last-modified timestamp.
   Parameters: f - the file; time - receives the packed DOS date/time, 0
   when the file is not open or the platform could not answer. *)
PROCEDURE GetFTime* (VAR f: File; VAR time: DosTime);
BEGIN
    time := 0;
    IF ArchFile.Valid(f.handle) & ~ArchFile.GetTime(f.name, time) THEN
        time := 0
    END
END GetFTime;


(* SetFTime - set the file's last-modified timestamp.  A platform that
   cannot set one answers FALSE and this is a no-op, which is what the
   DOS original did too.
   Parameters: f - the file; time - the packed DOS date/time to set. *)
PROCEDURE SetFTime* (VAR f: File; time: DosTime);
BEGIN
    IF ArchFile.Valid(f.handle) & ~ArchFile.SetTime(f.name, time) THEN
        (* nothing to do: the platform refused, and a timestamp is not
           worth failing the caller's work over *)
    END
END SetFTime;


(* IncB - add a byte to the byte at an offset, leaving the cursor where it
   was.  A byte that overflows wraps, which is what makes this usable for
   check digits and the like.
   Parameters: f - the file; ofs - the offset to change; b - what to add. *)
PROCEDURE IncB* (VAR f: File; ofs: INTEGER; b: BYTE);
VAR
    p, cp: INTEGER;

BEGIN
    IF (b # 0) & (f.buf # NIL) THEN
        p := Position(f);
        Seek(f, ofs);
        cp := f.cursor;
        f.buf.data[cp] := CHR((ORD(f.buf.data[cp]) + b) MOD 100H);
        f.dirty := TRUE;
        Seek(f, p)
    END
END IncB;


(* DecB - subtract a byte from the byte at an offset, leaving the cursor
   where it was.
   Parameters: f - the file; ofs - the offset to change; b - what to
   subtract. *)
PROCEDURE DecB* (VAR f: File; ofs: INTEGER; b: BYTE);
VAR
    p, cp: INTEGER;

BEGIN
    IF (b # 0) & (f.buf # NIL) THEN
        p := Position(f);
        Seek(f, ofs);
        cp := f.cursor;
        f.buf.data[cp] := CHR((ORD(f.buf.data[cp]) + 100H - b) MOD 100H);
        f.dirty := TRUE;
        Seek(f, p)
    END
END DecB;


BEGIN
    tempSeq := 0
END Files.
