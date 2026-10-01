MODULE Streams;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   Byte streams.  A stream here is an object in the Oberon sense: a record
   whose methods are procedure-typed fields, reached through a pointer.
   Input and Output are the interfaces - they say what a stream can do and
   they name no file, no platform and no Arch* module.  Two implementations
   of them live here: FileInput and FileOutput, over Files, and MemInput and
   MemOutput, over ByteArr.

   EVERY ONE OF THEM IS AN `Oberon.Object`, AND THAT IS WHERE `Done` COMES
   FROM.  The root type and the destructor are in `lib/common/Oberon.mod`,
   which is the module that describes what an object is in this dialect and
   why a destructor is not optional.  `InputDesc` and `OutputDesc` extend
   `Oberon.ObjectDesc`, so the four classes inherit a `Done` field and each
   of them binds it; a caller that holds only an `Oberon.Object` can still
   end a stream with `Oberon.Done`.  There was a `Closeable` interface here
   once, with a `Close` field of its own, and it was deleted when the root
   arrived: two names for one destructor is one name too many, and a caller
   that has to know which of them a given object answers to has been told
   nothing about it.

   WHY THE POINTER TYPES COME FIRST.  A record type may not be mentioned
   before it is declared, with exactly one exception: the base of a pointer
   type.  `Input = POINTER TO InputDesc` therefore stands above `InputDesc`
   although it names it, and the method fields below can take `Input`.  A
   method field taking the interface it lives in - `Read: PROCEDURE (s:
   Input)` inside `InputDesc` - is not a cycle only because the pointer was
   declared first; put the same field inside a record whose pointer has not
   been written yet and the compiler answers `identifier expected` on it.
   Hence the pointer types first, then the records in dependency order.  The
   root's own field is no longer an instance of this: it lives in Oberon,
   whose `Object` pointer is declared above `ObjectDesc` there.

   THE LAST FIELD OF A RECORD TAKES NO SEMICOLON.  The field list is
   `IdentList ":" type {";" IdentList ":" type}` and there is no trailing
   separator in it, so a semicolon before END is not accepted and is
   reported on the END, which is where the parser wanted a field name:
   `error (22) identifier expected`.  This is the mirror image of CONST,
   where the last declaration does need one, and it is easy to get wrong
   because a record with two fields hides it - the separator is legal
   between fields and only the last one is refused.  Measured: a record of
   one `n: INTEGER;` is refused, and the same field with the semicolon
   followed by a second field is accepted.

   NO IMPLICIT RECEIVER.  Oberon has none, so a method is called as
   `s.Read(s, b)` and never as `s.Read(b)`; `Oberon.Done` spells out what an
   object language would have hidden.

   WHAT IS BEHIND THE FILE STREAMS.  Files, and only Files - the portable
   module, not an Arch* one, so this file compiles for every target the
   compiler can emit.  Files is byte-oriented already: there is no rider
   here, no line splitting and no character conversion.  What the interface
   adds over Files is a place to keep the "which file am I" state of an
   object, and the -1 that says end of stream.

   WHAT IS BEHIND THE MEMORY STREAMS, AND WHO OWNS THE ARRAY.  ByteArr, and
   only ByteArr - also portable, also in lib/common, and for the same reason:
   this file has to compile for every target.  A ByteArray is a growable byte
   array that carries its methods the way this stream carries its own, so the
   memory pair needs one field of state where the file pair needs a Files.File
   plus a cursor: the cursor, which for the input is where reading has got to
   and for the output is where writing has got to.

   THE ARRAY BELONGS TO WHOEVER CREATED IT, AND THIS MODULE IS NOT THAT
   CALLER.  So Done on either memory stream gives back the stream and
   nothing else - it does not call ByteArr's Done, it does not empty the
   array, it does not shorten it, and it does not free a block of it.  The
   record Done does dispose of is this module's own, the one NEW made in
   the constructor; the array was made by the caller and is still the
   caller's after the destroy.  A caller that wants the bytes it wrote asks
   the array for them, and a caller that is finished with the array calls
   Done on it itself.  This is the one place the memory pair differs from
   the file pair in what Done MEANS rather than in what it reaches: closing
   a file stream hands the file back to the system, and there is no system
   here to hand anything back to.

   DONE IS A DESTRUCTOR, AND WHAT IT DISPOSES OF IS GONE.  Done ends by
   handing the record NEW made back to the allocator, on all four classes,
   so a second Done on the same pointer is a use of freed memory rather than
   a free no-op, and the pointer the caller still holds is left dangling.
   It is not set to NIL for the caller, and it cannot be: the destructor
   reaches the object through a value parameter, which cannot carry an
   assignment back out.  A caller that means to keep using its variable sets
   that variable to NIL itself, after Done and not instead of it.

   THE ORDER INSIDE Done IS THE POINT OF THE FILE HALF.  The file is closed
   FIRST and the record is freed second, and the two cannot be swapped:
   Files.Close is what releases the page cache the open file was holding
   (BufRelease, under the `buf # NIL` test), so freeing the stream first
   would free the only field that still pointed at that cache and leak it.
   That close is unconditional, and it is allowed to be: a stream that
   exists at all is a stream whose file opened, because the constructor
   answers NIL rather than a stream with no file behind it.

   AND DISPOSE IS NOT ON EVERY TARGET THIS LANGUAGE HAS.  It is missing on
   msp430, stm32cm3, rvm32i and rvm64i - those runtimes ship no `_dispose` -
   so this module cannot be compiled for them.  It could not be built for
   them before this change either, and the reasons were already here, in the
   imports: measured 2026-10-01 by compiling a module that imports nothing
   but Streams, `msp430` and `stm32cm3` stop in Files with
   `Files.mod(35:8):29 module not found` - no ArchFile partner exists for
   those two - and `rvm32i` and `rvm64i` stop in Heap with
   `Heap.mod(175:38):48 undeclared identifier`, which is DISPOSE again, one
   level down.  What this change adds is a third reason, and it would still
   bite if those two were ever cured: the four classes now need DISPOSE for
   themselves, on a target where Heap does not already need it for them.
   `Oberon` itself needs it too, so the root is missing there as well - which
   is the same limit stated once, one module further up.

   A NIL ARRAY IS NIL, NOT A CLOSED STREAM.  OpenMemInput and OpenMemOutput
   are handed the array, and a caller that has none to hand them gets NIL
   back - the same answer, from the same place, that a file which would not
   open gives.  So nothing here answers "empty" on behalf of a stream that
   has nothing behind it, and no method has to test its array before using
   it: a method is only reachable through a stream that has one.

   THE OUTPUT STREAM WRITES WHERE A FILE STREAM WOULD, AND GROWS THE ARRAY.
   The cursor starts at 0, so writing lands on top of what the array already
   holds rather than after it - OpenMemOutput is OpenFileOutput, and the tail
   beyond what is written survives, exactly as it does in a file.  Writing
   past the end of the array lengthens it, zero-filling the gap as
   ByteArr.SetLength does.  An array the caller emptied first therefore gives
   the append-only behaviour such a stream usually has, and a caller who
   wants that always gets it by asking for it, while a caller who wants to
   patch the front of a buffer can.  There is no CreateMemOutput to match
   CreateFileOutput: a file has to be created and an array cannot be, so a
   caller who wants the array emptied empties it, one call, on the object the
   caller already holds.

   A FAILED OPEN IS NIL, AND THAT IS THE WHOLE OF THE BAD NEWS A CALLER GETS.
   The constructor answers NIL, so a file that would not open cannot be
   mistaken for an empty one - which is exactly what a stream that "closed
   itself" invited, because such a stream answered 0 available and -1 from
   every reader, the same answers a file merely at its end gives.
   `Oberon.Done` takes NIL and ignores it, so the closing half of the same
   code needs no test either, and the whole idiom is

       s := Streams.OpenFileInput(name);
       IF s # NIL THEN ... END;
       Oberon.Done(s);

   That is the one place this interface asks a caller to look at an answer,
   and it was a choice rather than a limitation: the alternative on the table
   was to keep the flag and export it, and answering NIL is what was asked
   for.  It has a price worth naming, because it is the one thing a caller
   can now get wrong that used to be survivable - calling a method on a NIL
   stream traps, where a born-closed stream would have answered -1 forever.

   WHAT IS STILL SILENT IS A WRITE.  Done, Flush, Write, WritePart and
   WriteByte answer nothing, and the count Files.BlockWrite answers with is
   dropped on the floor, so a caller of this interface cannot learn that a
   write was refused.  `PROCEDURE Ok* (s: FileOutput): BOOLEAN` over
   Files.Ok was raised and turned down: write errors are Files' business and
   stay in Files, where Files.Ok is reached directly.  The memory output is
   silent about a different refusal - an array stops at ByteArr.MaxBytes, and
   a write that would go past that ceiling writes what fits and drops the
   rest - the same silence, over a limit no interface here can name. *)

IMPORT ByteArr, Files, Oberon, SYSTEM;

CONST
    (* How many bytes ReadPart and WritePart move in one call into Files.
       They need a buffer at all because neither BlockRead nor BlockWrite
       takes an offset into the caller's array, so a partial transfer has
       to be staged; Files' own page cache works in 8 KB pages and its
       CopyChunk is 1024, so a few hundred bytes here costs nothing and
       keeps the stack frame small on the 64-bit DOS targets, where the
       stack is the scarce resource. *)
    ChunkSize = 512;

TYPE
    Input* = POINTER TO InputDesc;
    Output* = POINTER TO OutputDesc;
    FileInput* = POINTER TO FileInputDesc;
    FileOutput* = POINTER TO FileOutputDesc;
    MemInput* = POINTER TO MemInputDesc;
    MemOutput* = POINTER TO MemOutputDesc;

    (* `Done` is not written here and must not be: it is `Oberon.ObjectDesc`'s
       field, inherited by both interfaces below and by all four classes, and
       re-declaring it would be a second name for the one destructor every
       object has.  What each class supplies is a procedure that takes
       `Oberon.Object`, and Install* binds it into this inherited field. *)
    InputDesc* = RECORD (Oberon.ObjectDesc)
        Available*:     PROCEDURE (s: Input) : INTEGER; (* Returns an estimate of the number of bytes that can be read (or skipped over) from this input stream without blocking by the next invocation of a method for this input stream. *)
        Skip*:     PROCEDURE (s: Input; n : INTEGER) : INTEGER; (* Skips over and discards n bytes of data from this input stream. *)
        Read*:     PROCEDURE (s: Input; VAR b : ARRAY OF BYTE) : INTEGER; (* Reads some number of bytes from the input stream and stores them into the buffer array b. *)
        ReadPart*: PROCEDURE (s: Input; VAR b : ARRAY OF BYTE; off, len : INTEGER) : INTEGER; (* Reads up to len bytes of data from the input stream into an array of bytes. *)
        ReadByte*: PROCEDURE (s: Input) : INTEGER (* Reads the next byte of data from the input stream. *)
    END;

    (* The four writers take an Output.  They were written with the input
       pointer here, which cannot be right - a method of an output stream
       cannot be handed an input stream - and no constructor could have
       installed a procedure of that shape anyway. *)
    OutputDesc* = RECORD (Oberon.ObjectDesc)
        Flush*:     PROCEDURE (s: Output); (* Flushes this output stream and forces any buffered output bytes to be written out. *)
        Write*:     PROCEDURE (s: Output; VAR b : ARRAY OF BYTE); (* Writes b.length bytes from the specified byte array to this output stream. *)
        WritePart*: PROCEDURE (s: Output; VAR b : ARRAY OF BYTE; off, len : INTEGER); (* Writes len bytes from the specified byte array starting at offset off to this output stream. *)
        WriteByte*: PROCEDURE (s: Output; b : BYTE) (* Writes the specified byte to this output stream. *)
    END;

    (* The file-backed pair.  One field of state each and no more - the open
       file.  There is no flag beside it to say whether the file opened,
       because that question is answered once, by the constructor, and by
       NIL: a caller never holds a FileInput whose file is not open, so a
       method has nothing to test before it uses `file`.  The header has the
       whole of that decision and its price.

       `file` is a Files.File, which is a RECORD and not a pointer, so it
       travels with the stream and needs no separate allocation.  It is
       always handed to Files.Reset or Files.ReWrite exactly once, in the
       constructor, and never skipped - which is what makes it safe to hand
       to Files.Close later.  A Files.File that no open has touched is zeroed
       by NEW and its handle is 0, which ArchFile.Valid counts as a VALID
       handle; Reset and ReWrite both set the handle to -1 first precisely so
       that a failed open leaves a record nothing will be called on.  Never
       let this field be closed or reopened without going through one of the
       two. *)
    FileInputDesc* = RECORD (InputDesc)
        file:   Files.File
    END;

    FileOutputDesc* = RECORD (OutputDesc)
        file:   Files.File
    END;

    (* The memory-backed pair.  Two fields of state each - the array and the
       cursor - because a ByteArray carries its own length and its own
       methods, so there is nothing else to keep.  A NIL array is answered
       with NIL by the constructor, as the header describes, so `data` is
       never NIL in a stream that exists and no method tests it.

       `data` is a ByteArr.ByteArray, the object and not the bytes: it is a
       pointer, so the stream shares the caller's array and never owns it.
       Close therefore leaves it exactly as it found it; the header explains
       why, and why that is the one thing about the pair that is not the file
       pair over again.

       `pos` is the cursor, and it is the whole of the difference between the
       two directions: an input reads at it and advances it, an output writes
       at it and advances it.  It is never negative and never past the array's
       length, because every method that moves it clamps to that length;
       nothing here trusts it to have been kept. *)
    MemInputDesc* = RECORD (InputDesc)
        data:   ByteArr.ByteArray;
        pos:    INTEGER
    END;

    MemOutputDesc* = RECORD (OutputDesc)
        data:   ByteArr.ByteArray;
        pos:    INTEGER
    END;

(* ------------------------------------------------------------------ *)
(* The methods of FileInput.                                          *)
(* ------------------------------------------------------------------ *)

(* DoneFileInput - release the file, then release the stream itself.  There
   is no test around the close because there is nothing left to test: a
   FileInput the caller can hold is one whose file opened, since OpenFileInput
   answers NIL rather than a stream with no file behind it.  A constructor
   that failed therefore never arrives here at all - Oberon.Done ignores NIL.

   The parameter is `Oberon.Object` and not `FileInput`, and the guard below
   is why: the inherited field's declared type is `PROCEDURE (self: Object)`,
   a procedure variable has to match its field's type exactly, and so every
   destructor in this tree takes the root and guards its way back down.
   `Oberon.mod` has the whole of that rule; `_probe/ObjInh.mod` measures it.

   Files.Close is what flushes the page cache and releases it, so it has to
   come first: DISPOSE frees the record NEW made, and with it the Files.File
   that travels inside it, which is the only thing left pointing at that
   cache.  Swap the two statements and it leaks - the header says why.
   Nothing is leaked by the constructor either, and that was read out of
   Files rather than assumed: Reset and ReWrite put handle to -1 and buf to
   NIL before they open anything, the only BufAlloc either of them makes runs
   after the open has succeeded, and that one closes the handle itself and
   puts -1 back when it fails.  So a FALSE from either leaves no handle and
   no page cache behind for anyone to free.
   Parameters: self - the stream, as the root type sees it. *)
PROCEDURE DoneFileInput (self: Oberon.Object);
VAR s: FileInput;
BEGIN
    s := self(FileInput);
    Files.Close(s.file);
    DISPOSE(s)
END DoneFileInput;

(* AvailableInput - how many bytes lie between the cursor and the end of
   file.  The subtraction cannot go negative while the cursor is truthful,
   but Files.Seek clamps and this does not read the cursor back, so it is
   clamped anyway rather than trusted.
   Parameters: s - the stream.  Result: the count, never negative. *)
PROCEDURE AvailableInput (s: Input): INTEGER;
VAR f: FileInput; n: INTEGER;
BEGIN
    f := s(FileInput);
    n := Files.Size(f.file) - Files.Position(f.file);
    IF n < 0 THEN n := 0 END;
    RETURN n
END AvailableInput;

(* SkipInput - move the cursor n bytes forward, discarding what is passed.
   Files.Seek clamps to the end of the file, so skipping past it lands on
   the end rather than failing, and a skip of zero or less is no move at
   all.  The answer is measured and not assumed: the cursor is read back
   after the seek, so a skip that ran into the end reports how far it
   really got.
   Parameters: s - the stream; n - how many bytes to drop.
   Result: how many bytes were actually skipped - n, or less at the end of
   the file, or 0 for a skip of n <= 0. *)
PROCEDURE SkipInput (s: Input; n: INTEGER): INTEGER;
VAR f: FileInput; before, moved: INTEGER;
BEGIN
    f := s(FileInput);
    moved := 0;
    IF n > 0 THEN
        before := Files.Position(f.file);
        Files.Seek(f.file, before + n);
        moved := Files.Position(f.file) - before
    END;
    RETURN moved
END SkipInput;

(* ReadInput - fill the caller's array from the stream.  It reads until b
   is full or the file ends, which is what Files.BlockRead does and what
   Oberon callers expect of a bulk read; a Java reader stops at whatever
   one underlying read returns, and there is no reason to be that shy.
   Parameters: s - the stream; b - receives the bytes.
   Result: how many bytes were stored, or -1 if the stream was at the end
   of the file and nothing at all was read. *)
PROCEDURE ReadInput (s: Input; VAR b: ARRAY OF BYTE): INTEGER;
VAR f: FileInput; n: INTEGER;
BEGIN
    f := s(FileInput);
    n := -1;
    IF LEN(b) > 0 THEN
        n := Files.BlockRead(f.file, b, LEN(b));
        IF n = 0 THEN n := -1 END
    END;
    RETURN n
END ReadInput;

(* ReadPartInput - ReadInput into a window of the caller's array, from
   b[off] to b[off + len).  The window is what forces the staging buffer:
   Files.BlockRead fills from the start of an array, and this dialect has
   no way to name a slice of one, so the bytes make one extra hop.  len is
   clamped to what is left of the array above off, and a window that lies
   outside it entirely reads nothing.
   Parameters: s - the stream; b - receives the bytes; off - where in b
   the first byte goes; len - how many are wanted.
   Result: how many bytes were stored, or -1 if nothing at all was read
   because the stream was at the end of the file. *)
PROCEDURE ReadPartInput (s: Input; VAR b: ARRAY OF BYTE; off, len: INTEGER): INTEGER;
VAR
    f: FileInput;
    n, want, got, i: INTEGER;
    more: BOOLEAN;
    tmp: ARRAY ChunkSize OF BYTE;
BEGIN
    f := s(FileInput);
    n := 0;
    IF (off >= 0) & (len > 0) & (off < LEN(b)) THEN
        IF len > LEN(b) - off THEN len := LEN(b) - off END;
        more := TRUE;
        WHILE more & (n < len) DO
            want := len - n;
            IF want > ChunkSize THEN want := ChunkSize END;
            got := Files.BlockRead(f.file, tmp, want);
            IF got <= 0 THEN
                more := FALSE
            ELSE
                i := 0;
                WHILE i < got DO
                    b[off + n] := tmp[i];
                    INC(i);
                    INC(n)
                END
            END
        END
    END;
    IF n = 0 THEN n := -1 END;
    RETURN n
END ReadPartInput;

(* ReadByteInput - the next byte, as an INTEGER.
   Parameters: s - the stream.
   Result: 0..255, or -1 at the end of the file.
   The BOOLEAN Files.ReadByte answers with is what is tested, and not the
   value: it zeroes its out parameter at the end of the file, so a byte of
   0 and the end of file are the same BYTE and only the flag tells them
   apart.  That is exactly why this answers -1 and not 0. *)
PROCEDURE ReadByteInput (s: Input): INTEGER;
VAR f: FileInput; v: BYTE; n: INTEGER;
BEGIN
    f := s(FileInput);
    n := -1;
    IF Files.ReadByte(f.file, v) THEN n := v END;
    RETURN n
END ReadByteInput;

(* ------------------------------------------------------------------ *)
(* The methods of FileOutput.                                         *)
(* ------------------------------------------------------------------ *)

(* DoneFileOutput - flush what is buffered, release the file, then release
   the stream.  The flush is Files.Close's own; Files.Flush is for a stream
   that stays open.  As on the input side the close is unconditional, and for
   the same reason: a stream that exists has an open file behind it.
   DoneFileInput gives the reason the two statements are in this order and
   not the other, and the reason the parameter is the root type.
   Parameters: self - the stream, as the root type sees it. *)
PROCEDURE DoneFileOutput (self: Oberon.Object);
VAR s: FileOutput;
BEGIN
    s := self(FileOutput);
    Files.Close(s.file);
    DISPOSE(s)
END DoneFileOutput;

(* FlushOutput - write out whatever the page cache still holds, leaving
   the stream open.  This is what a caller wants after writing a record it
   means some other process to see.
   Parameters: s - the stream. *)
PROCEDURE FlushOutput (s: Output);
VAR f: FileOutput;
BEGIN
    f := s(FileOutput);
    Files.Flush(f.file)
END FlushOutput;

(* WriteOutput - append the whole of b to the stream.  The count
   Files.BlockWrite answers with is dropped: the interface has nowhere to
   put it.  See the note at the head of the module.
   Parameters: s - the stream; b - the bytes to write. *)
PROCEDURE WriteOutput (s: Output; VAR b: ARRAY OF BYTE);
VAR f: FileOutput; written: INTEGER;
BEGIN
    f := s(FileOutput);
    IF LEN(b) > 0 THEN
        written := Files.BlockWrite(f.file, b, LEN(b))
    END
END WriteOutput;

(* WritePartOutput - WriteOutput of b[off] to b[off + len), through the
   staging buffer that ReadPartInput explains.  len is clamped to what is
   left of the array above off.
   Parameters: s - the stream; b - the bytes; off - where in b to start;
   len - how many to write. *)
PROCEDURE WritePartOutput (s: Output; VAR b: ARRAY OF BYTE; off, len: INTEGER);
VAR
    f: FileOutput;
    n, chunk, i, written: INTEGER;
    tmp: ARRAY ChunkSize OF BYTE;
BEGIN
    f := s(FileOutput);
    IF (off >= 0) & (len > 0) & (off < LEN(b)) THEN
        IF len > LEN(b) - off THEN len := LEN(b) - off END;
        n := 0;
        WHILE n < len DO
            chunk := len - n;
            IF chunk > ChunkSize THEN chunk := ChunkSize END;
            i := 0;
            WHILE i < chunk DO
                tmp[i] := b[off + n + i];
                INC(i)
            END;
            written := Files.BlockWrite(f.file, tmp, chunk);
            INC(n, chunk)
        END
    END
END WritePartOutput;

(* WriteByteOutput - one byte.
   Parameters: s - the stream; b - the byte. *)
PROCEDURE WriteByteOutput (s: Output; b: BYTE);
VAR f: FileOutput; written: INTEGER;
BEGIN
    f := s(FileOutput);
    written := Files.WriteByte(f.file, b)
END WriteByteOutput;

(* ------------------------------------------------------------------ *)
(* The constructors, and the wiring they share.                       *)
(* ------------------------------------------------------------------ *)

(* There is no `Streams.Done` here, and its absence is the point.  There was
   one - a wrapper over the old `Closeable` interface - and it was deleted
   along with the interface when the classes began to extend `Oberon.Object`.
   `Oberon.Done` does exactly what it did, for streams and for everything
   else, and it is the only destructor a caller has to remember.  The four
   destructors above are named here rather than in a wrapper of their own:
   each is bound into the `Done` field its class inherits, in the Install
   procedure below, and reached through that field from then on. *)

(* InstallInput - wire a new FileInput to its methods.  Written once
   because both constructors need the same assignments, and a constructor
   that forgot one would leave a NIL method field for a caller to trap on.
   Parameters: s - the stream, just allocated. *)
PROCEDURE InstallInput (s: FileInput);
BEGIN
    s.Done := DoneFileInput;
    s.Available := AvailableInput;
    s.Skip := SkipInput;
    s.Read := ReadInput;
    s.ReadPart := ReadPartInput;
    s.ReadByte := ReadByteInput
END InstallInput;

(* InstallOutput - the same for FileOutput.
   Parameters: s - the stream, just allocated. *)
PROCEDURE InstallOutput (s: FileOutput);
BEGIN
    s.Done := DoneFileOutput;
    s.Flush := FlushOutput;
    s.Write := WriteOutput;
    s.WritePart := WritePartOutput;
    s.WriteByte := WriteByteOutput
END InstallOutput;

(* OpenFileInput - open an existing file, and answer a stream on it.  The
   file is opened read-write when the platform allows it, so a stream made
   here can also be written to; Files.Reset falls back to read-only when
   it cannot.
   Parameters: name - the file's path.
   Result: the stream, or NIL if the file could not be opened. *)
PROCEDURE OpenFileInput* (name: ARRAY OF CHAR): FileInput;
VAR s: FileInput;
BEGIN
    s := NIL;
    NEW(s);
    IF Files.Reset(s.file, name) THEN
        InstallInput(s)
    ELSE
        DISPOSE(s);
        s := NIL
    END;
    RETURN s
END OpenFileInput;

(* OpenFileOutput - open an existing file for writing, WITHOUT truncating
   it: the cursor starts at 0, so what is written lands on top of what is
   there and the tail beyond it survives.  That is the difference from
   CreateFileOutput, and it is a real one - a stream that rewrites a fixed
   header of a file it does not own needs this and not the other.
   Parameters: name - the file's path.
   Result: the stream, or NIL if the file could not be opened. *)
PROCEDURE OpenFileOutput* (name: ARRAY OF CHAR): FileOutput;
VAR s: FileOutput;
BEGIN
    s := NIL;
    NEW(s);
    IF Files.Reset(s.file, name) THEN
        InstallOutput(s)
    ELSE
        DISPOSE(s);
        s := NIL
    END;
    RETURN s
END OpenFileOutput;

(* CreateFileOutput - create the file, or empty it if it is already there,
   and answer a stream on it.
   Parameters: name - the file's path.
   Result: the stream, or NIL if the file could not be created. *)
PROCEDURE CreateFileOutput* (name: ARRAY OF CHAR): FileOutput;
VAR s: FileOutput;
BEGIN
    s := NIL;
    NEW(s);
    IF Files.ReWrite(s.file, name) THEN
        InstallOutput(s)
    ELSE
        DISPOSE(s);
        s := NIL
    END;
    RETURN s
END CreateFileOutput;

(* ------------------------------------------------------------------ *)
(* The methods of MemInput.                                           *)
(* ------------------------------------------------------------------ *)

(* DoneMemInput - release the stream, and nothing else.  There is no handle
   to hand back and the array is the caller's, so the whole of this is the
   DISPOSE: it frees the record NEW made and stops there.  It does not call
   ByteArr's Done, it does not empty the array and it does not shorten it -
   a caller that wants the bytes it wrote still has them, and a caller that
   is finished with the array calls Done on the array itself.  The header
   says who owns what and why.
   Parameters: self - the stream, as the root type sees it. *)
PROCEDURE DoneMemInput (self: Oberon.Object);
VAR s: MemInput;
BEGIN
    s := self(MemInput);
    DISPOSE(s)
END DoneMemInput;

(* AvailableMemInput - how many bytes lie between the cursor and the end of
   the array.  Clamped at zero rather than trusted: every method here keeps
   the cursor inside the array, but this one reads it without moving it, and a
   count that is allowed to come back negative is a bug waiting for the one
   caller who gets it there.
   Parameters: s - the stream.  Result: the count, never negative. *)
PROCEDURE AvailableMemInput (s: Input): INTEGER;
VAR m: MemInput; n: INTEGER;
BEGIN
    m := s(MemInput);
    n := m.data.Length(m.data) - m.pos;
    IF n < 0 THEN n := 0 END;
    RETURN n
END AvailableMemInput;

(* SkipMemInput - move the cursor n bytes forward, discarding what is passed.
   Where the file stream asks Files to seek and reads the cursor back, this
   one does its own arithmetic and clamps it to the end of the array, so a
   skip past the end lands on the end and reports how far it really got.
   Parameters: s - the stream; n - how many bytes to drop.
   Result: how many bytes were actually skipped - n, or less at the end of the
   array, or 0 for a skip of n <= 0. *)
PROCEDURE SkipMemInput (s: Input; n: INTEGER): INTEGER;
VAR m: MemInput; len, moved: INTEGER;
BEGIN
    m := s(MemInput);
    moved := 0;
    IF n > 0 THEN
        len := m.data.Length(m.data);
        moved := n;
        IF m.pos + moved > len THEN moved := len - m.pos END;
        IF moved < 0 THEN moved := 0 END;
        INC(m.pos, moved)
    END;
    RETURN moved
END SkipMemInput;

(* ReadPartMemInput - copy b[off] to b[off + len) out of the array, from the
   cursor forward, and advance the cursor by what was copied.  The file pair
   needs a staging buffer here, because Files.BlockRead fills from the start
   of an array and this dialect cannot name a slice of one; ByteArr can be
   handed the destination address itself and CopyTo walks the array's blocks,
   so this is one call and no ChunkSize.  That is the one place the memory
   pair comes out shorter than the file pair rather than longer.

   len is clamped to what is left of the caller's array above off and then to
   what is left of the stream, and the second clamp decides the answer: at the
   end of the array nothing is copied and the answer is -1, exactly as it is
   for a window that lies outside the caller's array altogether.
   Parameters: s - the stream; b - receives the bytes; off - where in b the
   first byte goes; len - how many are wanted.
   Result: how many bytes were stored, or -1 if nothing at all was read. *)
PROCEDURE ReadPartMemInput (s: Input; VAR b: ARRAY OF BYTE; off, len: INTEGER): INTEGER;
VAR m: MemInput; n: INTEGER;
BEGIN
    m := s(MemInput);
    n := 0;
    IF (off >= 0) & (len > 0) & (off < LEN(b)) THEN
        IF len > LEN(b) - off THEN len := LEN(b) - off END;
        n := m.data.Length(m.data) - m.pos;
        IF n > len THEN n := len END;
        IF n > 0 THEN
            m.data.CopyTo(m.data, m.pos, n, SYSTEM.ADR(b[off]));
            INC(m.pos, n)
        END
    END;
    IF n < 0 THEN n := 0 END;
    IF n = 0 THEN n := -1 END;
    RETURN n
END ReadPartMemInput;

(* ReadMemInput - fill the caller's array, which is ReadPartMemInput from 0
   over the whole of it, and the same -1 at the end of the array.
   Parameters: s - the stream; b - receives the bytes.
   Result: how many bytes were stored, or -1 if nothing at all was read. *)
PROCEDURE ReadMemInput (s: Input; VAR b: ARRAY OF BYTE): INTEGER;
BEGIN
    RETURN ReadPartMemInput(s, b, 0, LEN(b))
END ReadMemInput;

(* ReadByteMemInput - the next byte, as an INTEGER.
   Parameters: s - the stream.
   Result: 0..255, or -1 at the end of the array.
   ByteArr.Get8 asserts that its index is inside the array, and a trap is not
   an answer, so the test is made here rather than left to it. *)
PROCEDURE ReadByteMemInput (s: Input): INTEGER;
VAR m: MemInput; n: INTEGER;
BEGIN
    m := s(MemInput);
    n := -1;
    IF m.pos < m.data.Length(m.data) THEN
        n := m.data.Get8(m.data, m.pos);
        INC(m.pos)
    END;
    RETURN n
END ReadByteMemInput;

(* ------------------------------------------------------------------ *)
(* The methods of MemOutput.                                          *)
(* ------------------------------------------------------------------ *)

(* DoneMemOutput - the same single DISPOSE DoneMemInput is, for the same
   reason: the array outlives the stream and nothing here may touch it.
   Parameters: self - the stream, as the root type sees it. *)
PROCEDURE DoneMemOutput (self: Oberon.Object);
VAR s: MemOutput;
BEGIN
    s := self(MemOutput);
    DISPOSE(s)
END DoneMemOutput;

(* FlushMemOutput - nothing, and the empty body is the honest one: there is no
   buffer between the caller and the array, so every write is already in it.
   The method exists because the interface has it, and a method field left NIL
   is a trap reached by writing correct code.
   Parameters: s - the stream. *)
PROCEDURE FlushMemOutput (s: Output);
BEGIN
END FlushMemOutput;

(* GrowMemOutput - make the array long enough to hold a byte at index n, and
   answer the length it has afterwards.  This is what makes writing past the
   end of the array work: ByteArr.SetLength grows the array and zero-fills the
   bytes it opens, so a stretch the cursor skipped over reads as zero rather
   than as whatever the allocator had left there.

   The array's ceiling is ByteArr.MaxBytes and SetLength asserts that it is
   never asked to go past it.  The clamp below is therefore not politeness:
   without it, a write that outgrew the array would trip that assertion, and a
   caller of this interface has no way to be told.  So a write past the
   ceiling writes what fits and drops the rest - the memory side's half of the
   silence about write failures that the header describes.
   Parameters: m - the stream; n - one past the last index that has to exist.
   Result: the array's length now, which the caller clamps its count to. *)
PROCEDURE GrowMemOutput (m: MemOutput; n: INTEGER): INTEGER;
VAR len: INTEGER;
BEGIN
    len := m.data.Length(m.data);
    IF n > len THEN
        IF n > ByteArr.MaxBytes THEN n := ByteArr.MaxBytes END;
        m.data.SetLength(m.data, n);
        len := n
    END;
    RETURN len
END GrowMemOutput;

(* WritePartMemOutput - copy b[off] to b[off + len) into the array at the
   cursor, growing the array if the write reaches past its end, and advance
   the cursor by what was written.  The file pair stages the bytes through a
   buffer for the reason ReadPartMemInput gives; here the array is grown
   first, so the destination bytes exist, and CopyMem walks the blocks.

   len is clamped to the caller's array first and to the ceiling second, and
   what is left of it is what goes in.
   Parameters: s - the stream; b - the bytes; off - where in b to start;
   len - how many to write. *)
PROCEDURE WritePartMemOutput (s: Output; VAR b: ARRAY OF BYTE; off, len: INTEGER);
VAR m: MemOutput; at, len0: INTEGER;
BEGIN
    m := s(MemOutput);
    IF (off >= 0) & (len > 0) & (off < LEN(b)) THEN
        IF len > LEN(b) - off THEN len := LEN(b) - off END;
        at := m.pos;
        len0 := GrowMemOutput(m, at + len);
        IF len0 < at + len THEN len := len0 - at END;
        IF len > 0 THEN
            m.data.CopyMem(m.data, at, SYSTEM.ADR(b[off]), len);
            INC(m.pos, len)
        END
    END
END WritePartMemOutput;

(* WriteMemOutput - write the whole of b at the cursor, which is
   WritePartMemOutput over the whole of it.
   Parameters: s - the stream; b - the bytes to write. *)
PROCEDURE WriteMemOutput (s: Output; VAR b: ARRAY OF BYTE);
BEGIN
    WritePartMemOutput(s, b, 0, LEN(b))
END WriteMemOutput;

(* WriteByteMemOutput - one byte.
   Parameters: s - the stream; b - the byte.
   ByteArr.Put8 asserts that its index is inside the array, which is why the
   array is grown before it is written to and why the length is tested: at the
   ceiling the write is dropped rather than trapped. *)
PROCEDURE WriteByteMemOutput (s: Output; b: BYTE);
VAR m: MemOutput; len0: INTEGER;
BEGIN
    m := s(MemOutput);
    len0 := GrowMemOutput(m, m.pos + 1);
    IF len0 > m.pos THEN
        m.data.Put8(m.data, m.pos, b);
        INC(m.pos)
    END
END WriteByteMemOutput;

(* InstallMemInput - wire a new MemInput to its methods, for the reason
   InstallInput gives: a constructor that forgot one would leave a NIL method
   field for a caller to trap on.
   Parameters: s - the stream, just allocated. *)
PROCEDURE InstallMemInput (s: MemInput);
BEGIN
    s.Done := DoneMemInput;
    s.Available := AvailableMemInput;
    s.Skip := SkipMemInput;
    s.Read := ReadMemInput;
    s.ReadPart := ReadPartMemInput;
    s.ReadByte := ReadByteMemInput
END InstallMemInput;

(* InstallMemOutput - the same for MemOutput.
   Parameters: s - the stream, just allocated. *)
PROCEDURE InstallMemOutput (s: MemOutput);
BEGIN
    s.Done := DoneMemOutput;
    s.Flush := FlushMemOutput;
    s.Write := WriteMemOutput;
    s.WritePart := WritePartMemOutput;
    s.WriteByte := WriteByteMemOutput
END InstallMemOutput;

(* OpenMemInput - read from the front of an array the caller already has.  The
   array is not copied and it is not taken over: the stream holds the object,
   the caller keeps every right over it, and closing the stream exercises none
   of them.
   Parameters: data - the array, or NIL.
   Result: the stream, or NIL if data was NIL.  Nothing is allocated on the
   failing path - there is no record to free, because none was made. *)
PROCEDURE OpenMemInput* (data: ByteArr.ByteArray): MemInput;
VAR s: MemInput;
BEGIN
    s := NIL;
    IF data # NIL THEN
        NEW(s);
        s.data := data;
        s.pos := 0;
        InstallMemInput(s)
    END;
    RETURN s
END OpenMemInput;

(* OpenMemOutput - write into an array the caller already has, at its front
   and not after its end, so this is OpenFileOutput over memory and not an
   appending stream: what is written lands on top of what is there and the
   tail beyond it survives.  Writing past the end lengthens the array, which
   is the one thing a file stream cannot be asked to do and the one thing an
   array can.  A caller who wants to start from nothing empties the array
   first - one call, on the object the caller already holds - and a caller who
   wants an appending stream does exactly that.
   Parameters: data - the array, or NIL.
   Result: the stream, or NIL if data was NIL.  As in OpenMemInput, the
   failing path allocates nothing. *)
PROCEDURE OpenMemOutput* (data: ByteArr.ByteArray): MemOutput;
VAR s: MemOutput;
BEGIN
    s := NIL;
    IF data # NIL THEN
        NEW(s);
        s.data := data;
        s.pos := 0;
        InstallMemOutput(s)
    END;
    RETURN s
END OpenMemOutput;

END Streams.
