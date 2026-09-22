(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.
*)

MODULE MACHO;

(* A minimal x86_64 Mach-O executable for macOS: dyld as the loader,
   /usr/lib/libSystem.B.dylib named as a dependency (the kernel refuses a
   static executable and dyld refuses one that names no libSystem), an
   empty chained-fixups table (nothing is actually imported - the runtime
   makes raw BSD syscalls, see lib/macOS/API.mod), and an ad-hoc
   LC_CODE_SIGNATURE so Gatekeeper/AMFI accept it.

   Three segments: __TEXT holds the header, the load commands and the
   code; __DATA follows on the next page and holds the globals, string
   literals and a demand-zero bss; __LINKEDIT holds the chained-fixups
   header, the exports trie, the symbol table and the signature.

   The image is built in memory (an image list, byte-patchable at any
   offset) because the UUID and the signature are hashes of everything
   that precedes them and so can only be filled in once the rest of the
   file is final; WRITER only ever appends, so the whole image is
   assembled here and handed to CHL.WriteToFile in one pass at the end. *)

IMPORT BIN, WR := WRITER, CHL := CHUNKLISTS, PE32, UTILS, SHA256;


CONST

    VMBASE     = 100000000H;
    SEGALIGN   = 1000H;   (* 4K: page granularity used throughout, incl. code-signing pages *)
    PAGESIZE   = 4096;

    CODEOFF    = 760;     (* the code follows the load commands *)
    NCMDS      = 17;
    SIZEOFCMDS = 728;     (* 32 + SIZEOFCMDS = CODEOFF *)

    (* mach_header_64 *)
    MH_MAGIC_64  = 0FEEDFACFH;
    CPU_TYPE_X86_64 = 01000007H;
    CPU_SUBTYPE_X86_64_ALL = 3;
    MH_EXECUTE = 2;
    MH_FLAGS   = 0200085H;  (* MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE *)

    LC_SEGMENT_64          = 019H;
    LC_SYMTAB              = 002H;
    LC_DYSYMTAB            = 00BH;
    LC_LOAD_DYLINKER       = 00EH;
    LC_UUID                = 01BH;
    LC_CODE_SIGNATURE      = 01DH;
    LC_SOURCE_VERSION      = 02AH;
    LC_FUNCTION_STARTS     = 026H;
    LC_DATA_IN_CODE        = 029H;
    LC_BUILD_VERSION       = 032H;
    LC_LOAD_DYLIB          = 00CH;
    LC_MAIN                = 080000028H;
    LC_DYLD_EXPORTS_TRIE   = 080000033H;
    LC_DYLD_CHAINED_FIXUPS = 080000034H;

    DYLIB = "/usr/lib/libSystem.B.dylib";
    DYLINKER = "/usr/lib/dyld";
    IDENT = "dwak-oberon";


PROCEDURE StringSize (s: ARRAY OF CHAR): INTEGER;
    RETURN LENGTH(s) + 1
END StringSize;


PROCEDURE RoundUp (n, align: INTEGER): INTEGER;
    RETURN ((n + align - 1) DIV align) * align
END RoundUp;


PROCEDURE U8 (img: CHL.BYTELIST; at, v: INTEGER);
BEGIN
    CHL.SetByte(img, at, v MOD 256)
END U8;


PROCEDURE U16 (img: CHL.BYTELIST; at, v: INTEGER);
BEGIN
    CHL.SetByte(img, at,     v MOD 256);
    CHL.SetByte(img, at + 1, (v DIV 256) MOD 256)
END U16;


PROCEDURE U32 (img: CHL.BYTELIST; at, v: INTEGER);
VAR
    i: INTEGER;

BEGIN
    FOR i := 0 TO 3 DO
        CHL.SetByte(img, at + i, UTILS.Byte(v, i))
    END
END U32;


PROCEDURE U64 (img: CHL.BYTELIST; at, v: INTEGER);
VAR
    i: INTEGER;

BEGIN
    FOR i := 0 TO 7 DO
        CHL.SetByte(img, at + i, UTILS.Byte(v, i))
    END
END U64;


PROCEDURE BE32 (img: CHL.BYTELIST; at, v: INTEGER);
VAR
    i: INTEGER;

BEGIN
    FOR i := 0 TO 3 DO
        CHL.SetByte(img, at + i, UTILS.Byte(v, 3 - i))
    END
END BE32;


PROCEDURE BE64 (img: CHL.BYTELIST; at, v: INTEGER);
VAR
    i: INTEGER;

BEGIN
    FOR i := 0 TO 7 DO
        CHL.SetByte(img, at + i, UTILS.Byte(v, 7 - i))
    END
END BE64;


PROCEDURE Ascii (img: CHL.BYTELIST; at: INTEGER; s: ARRAY OF CHAR);
VAR
    i: INTEGER;

BEGIN
    i := 0;
    WHILE s[i] # 0X DO
        CHL.SetByte(img, at + i, ORD(s[i]));
        INC(i)
    END
END Ascii;


PROCEDURE Grow (img: CHL.BYTELIST; total: INTEGER);
BEGIN
    WHILE CHL.Length(img) < total DO
        CHL.PushByte(img, 0)
    END
END Grow;


(* A 32-bit segment load command, with room left for NSECTS 80-byte
   section headers right after it (written separately by the caller). *)
PROCEDURE Segment64 (img: CHL.BYTELIST; at: INTEGER; name: ARRAY OF CHAR;
                      vmaddr, vmsize, fileoff, filesize, prot, nsects: INTEGER);
BEGIN
    U32(img, at, LC_SEGMENT_64);
    U32(img, at + 4, 72 + 80 * nsects);
    Ascii(img, at + 8, name);
    U64(img, at + 24, vmaddr);
    U64(img, at + 32, vmsize);
    U64(img, at + 40, fileoff);
    U64(img, at + 48, filesize);
    U32(img, at + 56, prot);
    U32(img, at + 60, prot);
    U32(img, at + 64, nsects)
END Segment64;


PROCEDURE DataCmd (img: CHL.BYTELIST; at, cmd, off, size: INTEGER);
BEGIN
    U32(img, at, cmd);
    U32(img, at + 4, 16);
    U32(img, at + 8, off);
    U32(img, at + 12, size)
END DataCmd;


(* ULEB128 of a value known to fit in two bytes (128 <= v < 16384) - the
   entry offset, here always well inside that range. *)
PROCEDURE Uleb2 (img: CHL.BYTELIST; at, v: INTEGER);
BEGIN
    CHL.SetByte(img, at, 128 + v MOD 128);
    CHL.SetByte(img, at + 1, (v DIV 128) MOD 128)
END Uleb2;


PROCEDURE PutHex (img: CHL.BYTELIST; at: INTEGER; digest: SHA256.DIGEST; n: INTEGER);
VAR
    i: INTEGER;

BEGIN
    FOR i := 0 TO n - 1 DO
        CHL.SetByte(img, at + i, digest[i])
    END
END PutHex;


PROCEDURE Copy (dst, src: CHL.BYTELIST; off, n: INTEGER);
VAR
    i: INTEGER;

BEGIN
    FOR i := 0 TO n - 1 DO
        CHL.SetByte(dst, i, CHL.GetByte(src, off + i))
    END
END Copy;


(* True when the whole page at OFF..OFF+4095 lies inside [from, upto), so
   its content is known to be zero without touching the image (padding
   between the end of the code and the data segment, or after the data). *)
PROCEDURE IsZeroPage (off, from, upto: INTEGER): BOOLEAN;
    RETURN (off >= from) & (off + PAGESIZE <= upto)
END IsZeroPage;


PROCEDURE write* (program: BIN.PROGRAM; FileName: ARRAY OF CHAR);
VAR
    img, scratch: CHL.BYTELIST;

    codelen, datalen, bsslen: INTEGER;
    dataAt, dataoff, textsize, datasize, linkedit: INTEGER;
    fixups, trie, starts, symoff, stroff, sigoff: INTEGER;
    idlen, nslots, hashoff, cdlen, siglen, total: INTEGER;
    cd: INTEGER;

    codeEnd, dataEnd: INTEGER;
    k, off, n, pageBase: INTEGER;
    zeroHex, digest: SHA256.DIGEST;

    Address: PE32.VIRTUAL_ADDR;

BEGIN
    codelen := CHL.Length(program.code);
    datalen := CHL.Length(program.data);
    bsslen  := program.bss;

    dataAt   := RoundUp(CODEOFF + codelen, SEGALIGN) - CODEOFF;
    dataoff  := CODEOFF + dataAt;
    textsize := dataoff;

    datasize := RoundUp(datalen + bsslen, SEGALIGN);
    IF datasize = 0 THEN
        datasize := SEGALIGN
    END;

    linkedit := dataoff + datasize;

    fixups := linkedit;
    trie   := linkedit + 56;
    starts := linkedit + 104;
    symoff := linkedit + 112;
    stroff := linkedit + 144;
    sigoff := linkedit + 176;

    idlen   := StringSize(IDENT);
    nslots  := (sigoff + PAGESIZE - 1) DIV PAGESIZE;
    hashoff := 88 + idlen;
    cdlen   := hashoff + nslots * 32;
    siglen  := 20 + cdlen;
    total   := sigoff + siglen;

    img := CHL.CreateByteList();
    Grow(img, total);

    (* mach_header_64 *)
    U32(img, 0, MH_MAGIC_64);
    U32(img, 4, CPU_TYPE_X86_64);
    U32(img, 8, CPU_SUBTYPE_X86_64_ALL);
    U32(img, 12, MH_EXECUTE);
    U32(img, 16, NCMDS);
    U32(img, 20, SIZEOFCMDS);
    U32(img, 24, MH_FLAGS);
    U32(img, 28, 0); (* reserved *)

    Segment64(img, 32, "__PAGEZERO", 0, VMBASE, 0, 0, 0, 0);

    Segment64(img, 104, "__TEXT", VMBASE, textsize, 0, textsize, 5, 1);
    Ascii(img, 176, "__text");
    Ascii(img, 192, "__TEXT");
    U64(img, 208, VMBASE + CODEOFF);
    U64(img, 216, codelen);
    U32(img, 224, CODEOFF);
    U32(img, 228, 4);           (* align: 2^4 = 16 *)
    U32(img, 232, 0);           (* reloff *)
    U32(img, 236, 0);           (* nreloc *)
    U32(img, 240, 0080000400H); (* S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS *)
    U32(img, 244, 0); U32(img, 248, 0); U32(img, 252, 0); (* reserved1..3 *)

    Segment64(img, 256, "__DATA", VMBASE + dataoff, datasize, dataoff, datasize, 3, 0);

    Segment64(img, 328, "__LINKEDIT", VMBASE + linkedit,
        RoundUp(total - linkedit, SEGALIGN), linkedit, total - linkedit, 1, 0);

    DataCmd(img, 400, LC_DYLD_CHAINED_FIXUPS, fixups, 56);
    DataCmd(img, 416, LC_DYLD_EXPORTS_TRIE, trie, 48);

    U32(img, 432, LC_SYMTAB);
    U32(img, 436, 24);
    U32(img, 440, symoff);
    U32(img, 444, 2);
    U32(img, 448, stroff);
    U32(img, 452, 32);

    U32(img, 456, LC_DYSYMTAB);
    U32(img, 460, 80);
    U32(img, 464, 0); U32(img, 468, 0);   (* ilocalsym, nlocalsym *)
    U32(img, 472, 0);                     (* iextdefsym *)
    U32(img, 476, 2);                     (* nextdefsym *)
    U32(img, 480, 2);                     (* iundefsym *)
    U32(img, 484, 0);                     (* nundefsym *)
    (* tocoff..nlocrel all zero, already grown as zero *)

    U32(img, 536, LC_LOAD_DYLINKER);
    U32(img, 540, 32);
    U32(img, 544, 12);
    Ascii(img, 548, DYLINKER);

    U32(img, 568, LC_UUID);
    U32(img, 572, 24);
    (* 16 bytes at 576, filled in once the code is in *)

    U32(img, 592, LC_BUILD_VERSION);
    U32(img, 596, 24);
    U32(img, 600, 1);          (* PLATFORM_MACOS *)
    U32(img, 604, 0000C0000H); (* minos 12.0 *)
    U32(img, 608, 0000C0000H); (* sdk 12.0 *)
    U32(img, 612, 0);          (* ntools *)

    U32(img, 616, LC_SOURCE_VERSION);
    U32(img, 620, 16);

    U32(img, 632, LC_MAIN);
    U32(img, 636, 24);
    U64(img, 640, CODEOFF);
    U64(img, 648, 0);          (* stacksize: default *)

    U32(img, 656, LC_LOAD_DYLIB);
    U32(img, 660, 56);
    U32(img, 664, 24);         (* name offset within this command *)
    U32(img, 668, 2);          (* timestamp *)
    U32(img, 672, 00010000H);  (* current_version *)
    U32(img, 676, 00010000H);  (* compatibility_version *)
    Ascii(img, 680, DYLIB);

    DataCmd(img, 712, LC_FUNCTION_STARTS, starts, 8);
    DataCmd(img, 728, LC_DATA_IN_CODE, symoff, 0);
    DataCmd(img, 744, LC_CODE_SIGNATURE, sigoff, siglen);

    (* the code, then the data a page later *)
    Address.Code   := VMBASE + CODEOFF;
    Address.Data   := VMBASE + dataoff;
    Address.Bss    := VMBASE + dataoff + datalen;
    Address.Import := 0;

    PE32.fixup(program, Address, TRUE);

    FOR k := 0 TO codelen - 1 DO
        CHL.SetByte(img, CODEOFF + k, CHL.GetByte(program.code, k))
    END;
    FOR k := 0 TO datalen - 1 DO
        CHL.SetByte(img, dataoff + k, CHL.GetByte(program.data, k))
    END;

    (* chained fixups: the header, and a start table for four segments
       with no fixups in any of them (nothing is ever actually imported) *)
    U32(img, fixups + 4, 020H);   (* starts_offset *)
    U32(img, fixups + 8, 034H);   (* imports_offset *)
    U32(img, fixups + 12, 034H);  (* symbols_offset *)
    U32(img, fixups + 20, 1);     (* DYLD_CHAINED_IMPORT *)
    U32(img, fixups + 32, 4);     (* includes __PAGEZERO and __LINKEDIT *)

    (* the exports trie: __mh_execute_header at 0, _start at the entry *)
    U8(img, trie, 0);       U8(img, trie + 1, 1);
    U8(img, trie + 2, 05FH); U8(img, trie + 3, 0);
    U8(img, trie + 4, 18);
    U8(img, trie + 5, 0); U8(img, trie + 6, 0); U8(img, trie + 7, 0); U8(img, trie + 8, 0);
    U8(img, trie + 9, 2);
    U8(img, trie + 10, 0); U8(img, trie + 11, 0); U8(img, trie + 12, 0);
    U8(img, trie + 13, 3); U8(img, trie + 14, 0);
    Uleb2(img, trie + 15, CODEOFF);
    U8(img, trie + 17, 0); U8(img, trie + 18, 0); U8(img, trie + 19, 2);
    Ascii(img, trie + 20, "_mh_execute_header");
    U8(img, trie + 39, 9);
    Ascii(img, trie + 40, "start");
    U8(img, trie + 46, 13);

    (* function starts: the entry *)
    Uleb2(img, starts, CODEOFF);

    (* the symbol table and its strings *)
    U32(img, symoff, 2);            (* __mh_execute_header: name index *)
    U8(img, symoff + 4, 00FH);      (* N_SECT | N_EXT *)
    U8(img, symoff + 5, 1);
    U16(img, symoff + 6, 010H);     (* REFERENCED_DYNAMICALLY *)
    U64(img, symoff + 8, VMBASE);
    U32(img, symoff + 16, 22);      (* _start: name index *)
    U8(img, symoff + 20, 00FH);
    U8(img, symoff + 21, 1);
    U16(img, symoff + 22, 0);
    U64(img, symoff + 24, VMBASE + CODEOFF);

    U8(img, stroff, 020H);
    Ascii(img, stroff + 2, "__mh_execute_header");
    Ascii(img, stroff + 22, "_start");

    (* the UUID: sixteen bytes of a digest of the header, commands and code *)
    SHA256.HashList(img, CODEOFF + codelen, digest);
    PutHex(img, 576, digest, 16);

    (* the signature *)
    cd := sigoff + 20;
    BE32(img, sigoff, 0FADE0CC0H);   (* CSMAGIC_EMBEDDED_SIGNATURE *)
    BE32(img, sigoff + 4, siglen);
    BE32(img, sigoff + 8, 1);
    U32(img, sigoff + 12, 0);        (* slot 0 type, native order (it's zero either way) *)
    BE32(img, sigoff + 16, 20);      (* slot 0 offset: the CodeDirectory *)

    BE32(img, cd, 0FADE0C02H);       (* CSMAGIC_CODEDIRECTORY *)
    BE32(img, cd + 4, cdlen);
    BE32(img, cd + 8, 020400H);
    BE32(img, cd + 12, 2);           (* adhoc *)
    BE32(img, cd + 16, hashoff);
    BE32(img, cd + 20, 88);          (* identifier offset *)
    BE32(img, cd + 24, 0);           (* n_special_slots *)
    BE32(img, cd + 28, nslots);
    BE32(img, cd + 32, sigoff);      (* codeLimit *)
    U8(img, cd + 36, 32);            (* hashSize: SHA-256 *)
    U8(img, cd + 37, 2);             (* hashType: SHA-256 *)
    U8(img, cd + 38, 0);             (* platform *)
    U8(img, cd + 39, 12);            (* pageSize: log2(4096) *)
    U32(img, cd + 40, 0);            (* spare2 *)
    BE64(img, cd + 72, textsize);    (* execSegLimit *)
    BE64(img, cd + 80, 1);           (* execSegFlags: CS_EXECSEG_MAIN_BINARY *)
    Ascii(img, cd + 88, IDENT);

    (* Every 4096-byte page below sigoff, hashed; the last one short. A
       page fully inside the code/data padding gaps is known to be zero
       and its digest is computed once and reused. *)
    codeEnd := RoundUp(CODEOFF + codelen, PAGESIZE);
    dataEnd := RoundUp(dataoff + datalen, PAGESIZE);
    scratch := CHL.CreateByteList();
    Grow(scratch, PAGESIZE);
    SHA256.HashList(scratch, PAGESIZE, zeroHex);

    FOR k := 0 TO nslots - 1 DO
        pageBase := k * PAGESIZE;
        IF k = 0 THEN
            SHA256.HashList(img, PAGESIZE, digest)
        ELSIF IsZeroPage(pageBase, codeEnd, dataoff) OR IsZeroPage(pageBase, dataEnd, linkedit) THEN
            digest := zeroHex
        ELSE
            IF sigoff - pageBase < PAGESIZE THEN
                n := sigoff - pageBase
            ELSE
                n := PAGESIZE
            END;
            Copy(scratch, img, pageBase, n);
            IF n < PAGESIZE THEN
                FOR off := n TO PAGESIZE - 1 DO
                    CHL.SetByte(scratch, off, 0)
                END
            END;
            SHA256.HashList(scratch, n, digest)
        END;
        PutHex(img, cd + hashoff + k * 32, digest, 32)
    END;

    WR.Create(FileName);
    CHL.WriteToFile(img);
    WR.Close;
    UTILS.chmod(FileName);
    CHL.Free(scratch); CHL.Free(img)
END write;


END MACHO.
