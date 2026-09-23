(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    A CSV round trip in UTF-8: four rows are written and read back.

    A field holds text in UTF-8 and the module treats it as bytes, so a
    field with a Cyrillic letter or a currency sign is simply more bytes
    than it has characters.  Every field is printed with both numbers side
    by side, and that is where a multi-byte character shows: the six
    letters of the Russian city are twelve bytes, and the euro sign is
    three bytes on its own.

    The text is printed through the W entry points, CSV.FieldW and
    Out.StringW, because a Windows console takes UTF-16 directly and would
    otherwise show the bytes of the UTF-8 encoding in whatever code page it
    happens to be using.  A redirected run loses that text on Windows for
    the same reason: there is no console to take it.

    This is one of the two samples in the tree allowed to hold Cyrillic,
    the other being samples/Windows/Console/HelloRus.mod.
*)

MODULE TestCSV;

IMPORT CSV, Out, Strings;


CONST

    SEP = 09X;
    NFIELDS = 3;
    FILE_NAME = "testcsv.csv";


VAR

    h: CSV.Handle;
    rows: ARRAY NFIELDS OF ARRAY 64 OF CHAR;
    field: ARRAY 256 OF CHAR;
    wide: ARRAY 256 OF WCHAR;
    n, i, units: INTEGER;
    ok: BOOLEAN;


(* PutW - print one field, as UTF-16, so that a console shows the letters
   rather than the bytes of their UTF-8 encoding. *)
PROCEDURE PutW (w: ARRAY OF WCHAR);
BEGIN
    Out.String("  ");
    Out.StringW(w)
END PutW;


BEGIN

    (* Write.  The last row carries a separator inside a field and a quote
       inside a field, so both quoting rules are exercised as well. *)
    h := CSV.Open(FILE_NAME, CSV.Write, SEP);
    IF h >= 0 THEN
        rows[0] := "Name"; rows[1] := "City"; rows[2] := "Note";
        ok := CSV.WriteRow(h, rows, NFIELDS);
        rows[0] := "Honza"; rows[1] := "Kraków"; rows[2] := "accented";
        ok := CSV.WriteRow(h, rows, NFIELDS) & ok;
        rows[0] := "Аня"; rows[1] := "Суми"; rows[2] := "€ 12,50";
        ok := CSV.WriteRow(h, rows, NFIELDS) & ok;
        rows[0] := "Вячеслав"; rows[1] := "Kyiv; UA"; rows[2] := 'quote " inside';
        ok := CSV.WriteRow(h, rows, NFIELDS) & ok;
        CSV.Close(h);
        IF ok THEN
            Out.StringLn("4 rows written")
        ELSE
            Out.StringLn("writing failed")
        END
    ELSE
        Out.StringLn("cannot create the file")
    END;

    (* Read back, a byte at a time, printing each field with the length it
       has in bytes and the number of characters those bytes hold. *)
    h := CSV.Open(FILE_NAME, CSV.Read, SEP);
    IF h >= 0 THEN
        n := 1;
        WHILE n > 0 DO
            n := CSV.ReadRow(h);
            IF n > 0 THEN
                Out.String("row of ");
                Out.Int(n, 0);
                Out.StringLn(" fields:");
                i := 0;
                WHILE i < n DO
                    IF CSV.Field(h, i, field) THEN
                        units := Strings.Utf8To16(field, wide);
                        PutW(wide);
                        Out.String("  [");
                        Out.Int(Strings.Length(field), 0);
                        Out.String(" bytes, ");
                        Out.Int(units, 0);
                        Out.StringLn(" chars]")
                    END;
                    INC(i)
                END
            END
        END;
        CSV.Close(h)
    ELSE
        Out.StringLn("cannot open the file for reading")
    END;

    (* FieldW, on the row that holds the Russian city. *)
    h := CSV.Open(FILE_NAME, CSV.Read, SEP);
    IF h >= 0 THEN
        n := CSV.ReadRow(h);
        n := CSV.ReadRow(h);
        n := CSV.ReadRow(h);
        IF CSV.FieldW(h, 1, wide) THEN
            units := 0;
            WHILE wide[units] # WCHR(0) DO
                INC(units)
            END;
            Out.String("as UTF-16, field 1 of row 3: ");
            Out.Int(units, 0);
            Out.StringLn(" units")
        END;
        CSV.Close(h)
    END

END TestCSV.
