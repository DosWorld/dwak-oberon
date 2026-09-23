MODULE ZipTool;

IMPORT Z := Zip, Args, Out;

VAR archive: Z.Archive; entry: Z.Entry;
    command, path, name, file: ARRAY 1024 OF CHAR;
    i, index, method, error: INTEGER; ok, closed: BOOLEAN;

BEGIN
    Z.Init(archive); ok := FALSE; error := Z.BadArgument;
    Args.GetArg(1, command); Args.GetArg(2, path);
    IF (command = "l") & (Args.argc = 3) THEN
        ok := Z.Open(archive, path);
        IF ok THEN
            i := 0;
            WHILE ok & (i < Z.Count(archive)) DO
                ok := Z.EntryAt(archive, i, entry);
                IF ok THEN
                    Out.Int(entry.size, 10); Out.String(" bytes  ");
                    Out.Int(entry.packed, 10); Out.String(" packed  "); Out.StringLn(entry.name)
                END;
                INC(i)
            END
        END;
        error := Z.Error(archive)
    ELSIF ((command = "c") OR (command = "s")) & (Args.argc >= 5) & ODD(Args.argc) THEN
        method := Z.Deflated; IF command = "s" THEN method := Z.Stored END;
        ok := Z.Create(archive, path); i := 3;
        WHILE ok & (i < Args.argc) DO
            Args.GetArg(i, name); Args.GetArg(i + 1, file);
            ok := Z.AddFile(archive, name, file, method); INC(i, 2)
        END;
        error := Z.Error(archive)
    ELSIF (command = "e") & (Args.argc = 5) THEN
        Args.GetArg(3, name); Args.GetArg(4, file);
        ok := Z.Open(archive, path); index := -1; i := 0;
        WHILE ok & (i < Z.Count(archive)) & (index < 0) DO
            ok := Z.EntryAt(archive, i, entry);
            IF ok & (entry.name = name) THEN index := i END;
            INC(i)
        END;
        IF ok THEN ok := Z.ExtractFile(archive, index, file) END;
        error := Z.Error(archive)
    ELSE
        Out.StringLn("Usage:");
        Out.StringLn("  ziptool l archive.zip");
        Out.StringLn("  ziptool c archive.zip member input-file [member input-file ...]");
        Out.StringLn("  ziptool s archive.zip member input-file [member input-file ...]");
        Out.StringLn("  ziptool e archive.zip member output-file")
    END;
    closed := Z.Close(archive);
    IF ~closed THEN error := Z.Error(archive) END;
    IF ok & closed THEN Out.StringLn("ZIP OK")
    ELSE Out.String("ZIP FAILED, error "); Out.Int(error, 0); Out.Ln END
END ZipTool.
