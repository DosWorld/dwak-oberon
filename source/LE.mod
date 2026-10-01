(*
    BSD 2-Clause License
    Copyright (c) 2026-, DosWorld

    OS/2 Linear Executable (LE). See doc/LE.TXT.
    Object 1: code. Object 2: initialized data, zero-filled BSS and stack.
    All absolute addresses have loader fixups; no preferred-address shortcut.
*)
MODULE LE;

IMPORT BIN, CHL := CHUNKLISTS, WR := WRITER, ERRORS, Files;

CONST
    pageSize = 4096;
    headerSize = 0C4H;

PROCEDURE Byte (list: CHL.BYTELIST; x: INTEGER);
BEGIN
    CHL.PushByte(list, x MOD 256)
END Byte;

PROCEDURE Word (list: CHL.BYTELIST; x: INTEGER);
BEGIN
    Byte(list, x); Byte(list, ASR(x, 8))
END Word;

PROCEDURE Dword (list: CHL.BYTELIST; x: INTEGER);
BEGIN
    Word(list, x); Word(list, ASR(x, 16))
END Dword;

PROCEDURE Object (size, base, flags, first, pages: INTEGER);
BEGIN
    WR.Write32LE(size); WR.Write32LE(base); WR.Write32LE(flags);
    WR.Write32LE(first); WR.Write32LE(pages); WR.Write32LE(0)
END Object;

PROCEDURE Fixup (program: BIN.PROGRAM; records: CHL.BYTELIST;
                 rel: BIN.RELOC; page, bss: INTEGER);
VAR
    obj, dest: INTEGER;
BEGIN
    dest := BIN.get32le(program.code, rel.offset);
    CASE rel.opcode OF
    |BIN.RCODE: obj := 1; dest := BIN.GetLabel(program, dest)
    |BIN.RDATA: obj := 2
    |BIN.RBSS:  obj := 2; INC(dest, bss)
    ELSE
        obj := 0; ERRORS.Error(209)
    END;
    Byte(records, 7);          (* source: 32-bit offset, single source *)
    Byte(records, 10H);        (* internal reference, 32-bit target offset *)
    Word(records, rel.offset - page * pageSize); (* signed page-relative offset *)
    Byte(records, obj);
    Dword(records, dest)
END Fixup;

(* LoadStub reads the whole DOS stub file (the default D32LE.EXE, or a
   -stub override) into a byte list, as-is, and patches the field at file
   offset 3CH -- where the bundled 4gs.exe-derived stub kept its LE header
   offset -- to point at the LE header written right after it. *)
PROCEDURE LoadStub (StubPath: ARRAY OF CHAR): CHL.BYTELIST;
CONST
    BUFSIZE = 4096;
VAR
    f:      Files.File;
    got, i: INTEGER;
    buf:    ARRAY BUFSIZE OF BYTE;
    list:   CHL.BYTELIST;
    size:   INTEGER;

BEGIN
    IF ~Files.Reset(f, StubPath) THEN
        ERRORS.FileNotFound(StubPath, "", "")
    END;

    list := CHL.CreateByteList();

    REPEAT
        got := Files.BlockRead(f, buf, BUFSIZE);
        FOR i := 0 TO got - 1 DO
            CHL.PushByte(list, buf[i])
        END
    UNTIL got < BUFSIZE;

    Files.Close(f);

    IF CHL.Length(list) < 40H THEN
        ERRORS.Error(201)
    END;

    size := CHL.Length(list);
    CHL.SetByte(list, 3CH, size MOD 256);
    CHL.SetByte(list, 3DH, (size DIV 256) MOD 256);
    CHL.SetByte(list, 3EH, (size DIV 10000H) MOD 256);
    CHL.SetByte(list, 3FH, (size DIV 1000000H) MOD 256)

    RETURN list
END LoadStub;


PROCEDURE write* (program: BIN.PROGRAM; FileName, StubPath: ARRAY OF CHAR);
VAR
    codeSize, dataSize, codePages, dataPages, pages, bss, stackTop: INTEGER;
    mapOff, namesOff, entryOff, fixPageOff, fixRecOff, importsOff, dataOff: INTEGER;
    page, i, previous: INTEGER;
    rel, crossing: BIN.RELOC;
    records, header: CHL.BYTELIST;
    fixPages: CHL.INTLIST;
    stub: CHL.BYTELIST;
    stubSize: INTEGER;
BEGIN
    stub := LoadStub(StubPath);
    stubSize := CHL.Length(stub);
    IF program.imp_list.first # NIL THEN ERRORS.Error(209) END;
    codeSize := CHL.Length(program.code);
    dataSize := CHL.Length(program.data);
    IF (codeSize <= 0) OR (dataSize <= 0) THEN ERRORS.Error(203) END;
    codePages := WR.align(codeSize, pageSize) DIV pageSize;
    dataPages := WR.align(dataSize, pageSize) DIV pageSize;
    pages := codePages + dataPages;
    IF pages > 0FFFFFFH THEN ERRORS.Error(203) END;
    bss := WR.align(dataSize, 16);
    stackTop := WR.align(bss + program.bss, 16) + program.stack;
    IF (stackTop < bss) OR (program.stack <= 0) THEN ERRORS.Error(203) END;

    (* I386 emits relocations in increasing source order. A dword straddling
       two pages must occur in both lists, negative in the second page. *)
    records := CHL.CreateByteList();
    fixPages := CHL.CreateIntList();
    rel := program.rel_list.first(BIN.RELOC);
    crossing := NIL;
    previous := -4;
    FOR page := 0 TO pages - 1 DO
        CHL.PushInt(fixPages, CHL.Length(records));
        IF crossing # NIL THEN
            Fixup(program, records, crossing, page, bss);
            crossing := NIL
        END;
        WHILE (rel # NIL) & (rel.offset < (page + 1) * pageSize) DO
            IF (rel.offset < previous + 4) OR (rel.offset > codeSize - 4) THEN
                ERRORS.Error(209)
            END;
            Fixup(program, records, rel, page, bss);
            IF rel.offset + 4 > (page + 1) * pageSize THEN crossing := rel END;
            previous := rel.offset;
            rel := rel.next(BIN.RELOC)
        END
    END;
    IF (rel # NIL) OR (crossing # NIL) THEN ERRORS.Error(209) END;
    CHL.PushInt(fixPages, CHL.Length(records));

    mapOff := headerSize + 2 * 24;
    namesOff := mapOff + pages * 4;
    entryOff := namesOff + 1;
    fixPageOff := WR.align(entryOff + 1, 4);
    fixRecOff := fixPageOff + (pages + 1) * 4;
    importsOff := fixRecOff + CHL.Length(records);
    dataOff := WR.align(stubSize + importsOff + 1, 512);

    header := CHL.CreateByteList();
    FOR i := 0 TO headerSize - 1 DO Byte(header, 0) END;
    CHL.SetByte(header, 0, 4CH); CHL.SetByte(header, 1, 45H); (* LE *)
    CHL.SetByte(header, 8, 2); (* 80386 *)
    CHL.SetByte(header, 0AH, 1); (* OS/2 LE convention used by DOS/4GW *)
    BIN.put32le(header, 0CH, ORD(program.vmajor) * 65536 + ORD(program.vminor));
    BIN.put32le(header, 10H, 200H); (* executable, internal fixups present *)
    BIN.put32le(header, 14H, pages);
    BIN.put32le(header, 18H, 1); (* entry object 1, EIP offset 0 *)
    BIN.put32le(header, 20H, 2);
    BIN.put32le(header, 24H, stackTop);
    BIN.put32le(header, 28H, pageSize);
    BIN.put32le(header, 2CH, pageSize); (* LE: bytes on last page, NOT LX shift *)
    BIN.put32le(header, 30H, importsOff + 1 - fixPageOff);
    BIN.put32le(header, 38H, fixPageOff - headerSize);
    BIN.put32le(header, 40H, headerSize);
    BIN.put32le(header, 44H, 2);
    BIN.put32le(header, 48H, mapOff);
    BIN.put32le(header, 58H, namesOff);
    BIN.put32le(header, 5CH, entryOff);
    BIN.put32le(header, 68H, fixPageOff);
    BIN.put32le(header, 6CH, fixRecOff);
    BIN.put32le(header, 70H, importsOff); (* zero imported modules *)
    BIN.put32le(header, 78H, importsOff); (* empty import names *)
    BIN.put32le(header, 80H, dataOff); (* absolute FILE offset *)
    BIN.put32le(header, 84H, pages);
    BIN.put32le(header, 94H, 2); (* automatic data object *)
    BIN.put32le(header, 0ACH, program.stack);

    WR.Create(FileName);
    CHL.WriteToFile(stub);
    CHL.Free(stub);
    CHL.WriteToFile(header);
    Object(codeSize, 10000H, 2005H, 1, codePages);
    Object(stackTop, 10000H + codePages * pageSize, 2003H, codePages + 1, dataPages);
    FOR page := 1 TO pages DO
        (* LE uses a 24-bit page number, most significant byte first, then
           flags. LX instead has offset/size/flags in an eight-byte record. *)
        WR.WriteByte(page DIV 65536);
        WR.WriteByte(page DIV 256 MOD 256);
        WR.WriteByte(page MOD 256);
        WR.WriteByte(0) (* ordinary physical page *)
    END;
    WR.WriteByte(0); (* resident-name terminator *)
    WR.WriteByte(0); (* entry-table terminator: not a DLL *)
    WHILE WR.counter < stubSize + fixPageOff DO WR.WriteByte(0) END;
    FOR i := 0 TO pages DO WR.Write32LE(CHL.GetInt(fixPages, i)) END;
    CHL.WriteToFile(records);
    WR.WriteByte(0); (* import procedure names terminator *)
    WHILE WR.counter < dataOff DO WR.WriteByte(0) END;
    CHL.WriteToFile(program.code);
    WHILE WR.counter < dataOff + codePages * pageSize DO WR.WriteByte(0) END;
    CHL.WriteToFile(program.data);
    WHILE WR.counter < dataOff + pages * pageSize DO WR.WriteByte(0) END;
    WR.Close;
    CHL.Free(header); CHL.Free(records); CHL.Free(fixPages)
END write;

END LE.
