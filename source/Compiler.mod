(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2018-2023, 2025, Anton Krotov
    All rights reserved.
*)

MODULE Compiler;

IMPORT ST := STATEMENTS, PARS, UTILS, PATHS, PROG, TARGETS, SCAN, TEXTDRV,
       ERRORS, Strings, WRITER, MSP430, THUMB, Out;


CONST

    DEF_DWAK_OBERON = "DWAK_OBERON";

    DEF_WINDOWS   = "WINDOWS";
    DEF_DOS       = "DOS";
    DEF_DPMI32    = "DPMI32";
    DEF_LINUX     = "LINUX";
    DEF_MACOS     = "MACOS";

    DEF_CPU_I386  = "CPU_I386";
    DEF_CPU_AMD64 = "CPU_AMD64";

    DEF_BITS_16   = "BITS_16";
    DEF_BITS_32   = "BITS_32";
    DEF_BITS_64   = "BITS_64";

    DEF_REAL_32   = "REAL_32";
    DEF_REAL_64   = "REAL_64";


PROCEDURE keys (VAR options: PROG.OPTIONS; VAR out, lib, stub: PARS.PATH);
VAR
    param: PARS.PATH;
    i, j:  INTEGER;
    _end:  BOOLEAN;
    value: INTEGER;
    minor,
    major: INTEGER;
    checking: SET;


    PROCEDURE getVal (VAR i: INTEGER; VAR value: INTEGER);
    VAR
        param: PARS.PATH;
        val: INTEGER;
    BEGIN
        INC(i);
        UTILS.GetArg(i, param);
        IF Strings.ToInt(param, val) THEN
            value := val
        END;
        IF param[0] = "-" THEN
            DEC(i)
        END
    END getVal;


BEGIN
    options.lower := TRUE;
    out := "";
    lib := "";
    stub := "";
    checking := options.checking;
    _end := FALSE;
    i := 3;
    REPEAT
        UTILS.GetArg(i, param);

        IF param = "-stk" THEN
            INC(i);
            UTILS.GetArg(i, param);
            IF Strings.ToInt(param, value) & (1 <= value) & (value <= 32) THEN
                options.stack := value
            END;
            IF param[0] = "-" THEN
                DEC(i)
            END

        ELSIF param = "-fa" THEN
            getVal(i, options.PE32FileAlignment)

        ELSIF param = "-out" THEN
            INC(i);
            UTILS.GetArg(i, param);
            IF param[0] = "-" THEN
                DEC(i)
            ELSE
                out := param
            END

        ELSIF param = "-l" THEN
            INC(i);
            UTILS.GetArg(i, param);
            IF param[0] = "-" THEN
                DEC(i)
            ELSE
                lib := param
            END

        ELSIF param = "-stub" THEN
            INC(i);
            UTILS.GetArg(i, param);
            IF param[0] = "-" THEN
                DEC(i)
            ELSE
                stub := param
            END

        ELSIF param = "-tab" THEN
            getVal(i, options.tab)

        ELSIF param = "-ram" THEN
            getVal(i, options.ram)

        ELSIF param = "-rom" THEN
            getVal(i, options.rom)

        ELSIF param = "-nochk" THEN
            INC(i);
            UTILS.GetArg(i, param);

            IF param[0] = "-" THEN
                DEC(i)
            ELSE
                j := 0;
                WHILE param[j] # 0X DO

                    IF    param[j] = "p" THEN
                        EXCL(checking, ST.chkPTR)
                    ELSIF param[j] = "t" THEN
                        EXCL(checking, ST.chkGUARD)
                    ELSIF param[j] = "i" THEN
                        EXCL(checking, ST.chkIDX)
                    ELSIF param[j] = "b" THEN
                        EXCL(checking, ST.chkBYTE)
                    ELSIF param[j] = "c" THEN
                        EXCL(checking, ST.chkCHR)
                    ELSIF param[j] = "w" THEN
                        EXCL(checking, ST.chkWCHR)
                    ELSIF param[j] = "r" THEN
                        EXCL(checking, ST.chkCHR);
                        EXCL(checking, ST.chkWCHR);
                        EXCL(checking, ST.chkBYTE)
                    ELSIF param[j] = "s" THEN
                        EXCL(checking, ST.chkSTK)
                    ELSIF param[j] = "a" THEN
                        checking := {}
                    END;

                    INC(j)
                END;

            END

        ELSIF param = "-ver" THEN
            INC(i);
            UTILS.GetArg(i, param);
            IF Strings.StrToVer(param, major, minor) THEN
                options.version := major * 65536 + minor
            END;
            IF param[0] = "-" THEN
                DEC(i)
            END

        ELSIF param = "-lower" THEN
            options.lower := TRUE

        ELSIF param = "-upper" THEN
            options.lower := FALSE

        ELSIF param = "-pic" THEN
            options.pic := TRUE

        ELSIF param = "-uses" THEN
            options.uses := TRUE

        ELSIF param = "-def" THEN
            INC(i);
            UTILS.GetArg(i, param);
            SCAN.NewDef(param)

        ELSIF param = "" THEN
            _end := TRUE

        ELSE
            ERRORS.BadParam(param)
        END;

        INC(i)
    UNTIL _end;

    options.checking := checking
END keys;


PROCEDURE OutTargetItem (target: INTEGER; text: ARRAY OF CHAR);
VAR
    width: INTEGER;

BEGIN
    width := 15;
    width := width - LENGTH(TARGETS.Targets[target].ComLinePar) - 4;
    Out.String("  '"); Out.String(TARGETS.Targets[target].ComLinePar); Out.String("'");
    WHILE width > 0 DO
        Out.Char(20X);
        DEC(width)
    END;
    Out.StringLn(text)
END OutTargetItem;


PROCEDURE main;
VAR
    path:       PARS.PATH;
    inname:     PARS.PATH;
    ext:        PARS.PATH;
    app_path:   PARS.PATH;
    lib_path:   PARS.PATH;
    common_lib_path: PARS.PATH;
    lib_dir:    PARS.PATH;
    lib_root:   PARS.PATH;
    stub_arg:   PARS.PATH;
    modname:    PARS.PATH;
    outname:    PARS.PATH;
    param:      PARS.PATH;
    temp:       PARS.PATH;
    target:     INTEGER;
    time:       INTEGER;
    options:    PROG.OPTIONS;

BEGIN
    options.stack := 2;
    options.tab := TEXTDRV.defTabSize;
    options.version := 65536;
    options.pic := FALSE;
    options.lower := FALSE;
    options.uses := FALSE;
    options.checking := ST.chkALL;

    PATHS.GetCurrentDirectory(app_path);

    UTILS.GetArg(0, temp);
    PATHS.split(temp, path, modname, ext);
    IF PATHS.isRelative(path) THEN
        PATHS.RelPath(app_path, path, temp);
        path := temp
    END;
    lib_path := path;
    common_lib_path := path;

    UTILS.GetArg(1, inname);
    Strings.ReplaceChar(inname, "\", UTILS.slash);
    Strings.ReplaceChar(inname, "/", UTILS.slash);

    Out.String("DWAK Oberon Compiler v"); Out.Int(UTILS.vMajor, 0); Out.String("."); UTILS.Int2(UTILS.vMinor);
        Out.String(" ("); Out.Int(UTILS.bit_depth, 0); Out.String("-bit) " + UTILS.Date);
    Out.StringLn(". Copyright (c) 2026, DosWord  (c) 2018-2025, Anton Krotov");

    IF inname = "" THEN
        Out.Ln;
        Out.StringLn("Usage: Compiler <main module> <target> [optional settings]"); Out.Ln;
        Out.StringLn("target =");
        IF UTILS.bit_depth = 64 THEN
            OutTargetItem(TARGETS.Win64C, "Windows64 Console");
            OutTargetItem(TARGETS.Win64GUI, "Windows64 GUI");
            OutTargetItem(TARGETS.Win64DLL, "Windows64 DLL");
            OutTargetItem(TARGETS.Linux64, "Linux64 Exec");
            OutTargetItem(TARGETS.Linux64SO, "Linux64 SO");
            OutTargetItem(TARGETS.MacOS64, "macOS64 Console")
        END;
        IF UTILS.bit_depth > 16 THEN
            OutTargetItem(TARGETS.Win32C, "Windows32 Console");
            OutTargetItem(TARGETS.Win32GUI, "Windows32 GUI");
            OutTargetItem(TARGETS.Win32DLL, "Windows32 DLL");
            OutTargetItem(TARGETS.Linux32, "Linux32 Exec");
            OutTargetItem(TARGETS.Linux32SO, "Linux32 SO");
            OutTargetItem(TARGETS.DPMI32PE, "DOS PE-executable (HX-DOS Extender)");
            OutTargetItem(TARGETS.DPMI32DLL, "DOS DLL (HX-DOS Extender)");
            OutTargetItem(TARGETS.DPMI32LE, "DOS LE-executable (old DOS-extenders)");
            OutTargetItem(TARGETS.STM32CM3, "STM32 Cortex-M3 microcontrollers")
        END;
        OutTargetItem(TARGETS.MSP430, "MSP430x{1,2}xx microcontrollers");
        Out.Ln;
        Out.StringLn("optional settings:"); Out.Ln;
        Out.StringLn("  -out <file name>      output");
        Out.StringLn("  -l <path>             set path to the lib directory");
        Out.StringLn("                        (default: lib next to the exe)");
        Out.StringLn("  -stub <file>          set custom PE/LE DOS stub file");
        Out.StringLn("                        (default: W32PE.EXE/D32PE.EXE/D32LE.EXE in lib)");
        Out.StringLn("  -stk <size>           set size of stack in Mbytes (Windows, Linux, HX-DOS, LE-DOS)");
        Out.StringLn("  -nochk <'ptibcwra'>   disable runtime checking (pointers, types, indexes,");
        Out.StringLn("                        BYTE, CHR, WCHR)");
        Out.StringLn("  -lower                allow lower case for keywords (default)");
        Out.StringLn("  -upper                only upper case for keywords");
        Out.StringLn("  -def <identifier>     define conditional compilation symbol");
        Out.StringLn("  -ver <major.minor>    set version of program (LE-DOS)");
        Out.StringLn("  -ram <size>           set size of RAM in bytes (MSP430) or Kbytes (STM32)");
        Out.StringLn("  -rom <size>           set size of ROM in bytes (MSP430) or Kbytes (STM32)");
        Out.StringLn("  -tab <width>          set width for tabs");
        Out.StringLn("  -uses                 list imported modules");
        Out.StringLn("  -fa <size>            set PE32 file alignment {512 (def.), 1024, 2048, 4096}");
        UTILS.Exit(0)
    END;

    PATHS.split(inname, path, modname, ext);

    IF ext # UTILS.FILE_EXT THEN
        ERRORS.Error(207)
    END;

    IF PATHS.isRelative(path) THEN
        PATHS.RelPath(app_path, path, temp);
        path := temp
    END;

    UTILS.GetArg(2, param);
    IF param = "" THEN
        ERRORS.Error(205)
    END;

    SCAN.NewDef(param);

    IF TARGETS.Select(param) THEN
        target := TARGETS.target
    ELSE
        ERRORS.Error(206)
    END;

    IF TARGETS.CPU = TARGETS.cpuMSP430 THEN
        options.ram := MSP430.minRAM;
        options.rom := MSP430.minROM
    END;

    IF (TARGETS.CPU = TARGETS.cpuTHUMB) & (TARGETS.OS = TARGETS.osNONE) THEN
        options.ram := THUMB.minRAM;
        options.rom := THUMB.minROM
    END;

    IF UTILS.bit_depth < TARGETS.BitDepth THEN
        ERRORS.Error(206)
    END;

    keys(options, outname, lib_dir, stub_arg);

    IF lib_dir = "" THEN
        (* No -l.  lib_path was seeded with the directory argv[0] names, so
           the library is looked for next to the compiler itself. *)
        ASSERT(Strings.Append("lib", lib_path));
        ASSERT(Strings.Append(UTILS.slash, lib_path));

        ASSERT(Strings.Append("lib", common_lib_path));
        ASSERT(Strings.Append(UTILS.slash, common_lib_path))
    ELSE
        (* -l <path>: the named directory is the lib directory itself, so it
           stands in for the "lib" component rather than being a parent of
           it.  Which is the point: a compiler built somewhere other than
           the repository root -- a build directory, say -- can be told
           where lib is instead of having to sit beside it. *)
        Strings.ReplaceChar(lib_dir, "\", UTILS.slash);
        Strings.ReplaceChar(lib_dir, "/", UTILS.slash);

        IF lib_dir[LENGTH(lib_dir) - 1] # UTILS.slash THEN
            ASSERT(Strings.Append(UTILS.slash, lib_dir))
        END;

        COPY(lib_dir, lib_path);
        COPY(lib_dir, common_lib_path)
    END;

    (* lib_path is still the plain lib directory here, common to every
       target; the PE/LE DOS stub files (W32PE.EXE, D32PE.EXE, D32LE.EXE)
       live there, not under a target subdirectory. *)
    lib_root := lib_path;

    IF stub_arg # "" THEN
        Strings.ReplaceChar(stub_arg, "\", UTILS.slash);
        Strings.ReplaceChar(stub_arg, "/", UTILS.slash);
        IF PATHS.isRelative(stub_arg) THEN
            PATHS.RelPath(app_path, stub_arg, temp);
            options.stub := temp
        ELSE
            options.stub := stub_arg
        END
    ELSE
        options.stub := lib_root;
        CASE target OF
        |TARGETS.DPMI32PE: ASSERT(Strings.Append("D32PE.EXE", options.stub))
        |TARGETS.DPMI32LE: ASSERT(Strings.Append("D32LE.EXE", options.stub))
        ELSE                ASSERT(Strings.Append("W32PE.EXE", options.stub))
        END
    END;

    ASSERT(Strings.Append(TARGETS.LibDir, lib_path));
    ASSERT(Strings.Append(UTILS.slash, lib_path));

    ASSERT(Strings.Append("common", common_lib_path));
    ASSERT(Strings.Append(UTILS.slash, common_lib_path));

    TEXTDRV.setTabSize(options.tab);
    IF outname = "" THEN
        outname := path;
        ASSERT(Strings.Append(modname, outname));
        ASSERT(Strings.Append(TARGETS.FileExt, outname))
    ELSE
        IF PATHS.isRelative(outname) THEN
            PATHS.RelPath(app_path, outname, temp);
            outname := temp
        END
    END;

    PARS.init(options);

    SCAN.NewDef(DEF_DWAK_OBERON);

    CASE TARGETS.OS OF
    |TARGETS.osNONE:
    |TARGETS.osWIN32,
     TARGETS.osWIN64:   SCAN.NewDef(DEF_WINDOWS)
    |TARGETS.osDPMI32:  SCAN.NewDef(DEF_DOS); SCAN.NewDef(DEF_DPMI32)
    |TARGETS.osLINUX32,
     TARGETS.osLINUX64: SCAN.NewDef(DEF_LINUX)
    |TARGETS.osMACOS64: SCAN.NewDef(DEF_MACOS)
    END;

    CASE TARGETS.CPU OF
    |TARGETS.cpuI386P:  SCAN.NewDef(DEF_CPU_I386); SCAN.NewDef(DEF_BITS_32)
    |TARGETS.cpuAMD64:  SCAN.NewDef(DEF_CPU_AMD64); SCAN.NewDef(DEF_BITS_64)
    |TARGETS.cpuMSP430: SCAN.NewDef(DEF_BITS_16)
    |TARGETS.cpuTHUMB:  SCAN.NewDef(DEF_BITS_32)
    |TARGETS.cpuRVM32I: SCAN.NewDef(DEF_BITS_32)
    |TARGETS.cpuRVM64I: SCAN.NewDef(DEF_BITS_64)
    END;

    (* The width of a REAL is not the width of an INTEGER.  Win32, Linux32 and
       the HX-DOS targets run a 32-bit INTEGER beside a 64-bit REAL, and the
       small CPUs run both narrow, so neither BITS_32 nor BITS_64 says how many
       digits a real can hold.  TARGETS.RealSize is the one thing that does, and
       REAL_32/REAL_64 spell it out for a library that has to format one: 4
       bytes of REAL needs 10 significant digits, 8 bytes needs 15.  A target
       with no REAL at all - MSP430, whose RealSize is 0 - gets neither symbol. *)
    CASE TARGETS.RealSize OF
    |4: SCAN.NewDef(DEF_REAL_32)
    |8: SCAN.NewDef(DEF_REAL_64)
    END;

    ST.compile(path, lib_path, common_lib_path, modname, outname, target, options);

    time := UTILS.GetTickCount() - UTILS.time;
    Out.Int(PARS.lines, 0); Out.String(" lines, ");
    Out.Int(time DIV 100, 0); Out.String("."); UTILS.Int2(time MOD 100); Out.String(" sec, ");
    Out.Int(WRITER.counter, 0); Out.StringLn(" bytes");

    UTILS.Exit(0)
END main;


BEGIN
    main
END Compiler.