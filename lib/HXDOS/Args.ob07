(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2019-2020, Anton Krotov
    All rights reserved.

    HXDOS port of the Args module. No Win32 DLL imports: the program path
    comes from the PE loader and the arguments from the DOS command tail, and
    the two are stitched back into the single string the parser below expects.
*)

MODULE Args;

IMPORT SYSTEM, DOS;


CONST

    MAX_PARAM = 1024;
    MAX_CMD   = 1024;
    MAX_TAIL  = 128;                    (* DOS counts the tail with one byte *)


VAR

    Params: ARRAY MAX_PARAM, 2 OF INTEGER;
    cmd:  ARRAY MAX_CMD OF CHAR;
    tail: ARRAY MAX_TAIL OF CHAR;
    argc*: INTEGER;


PROCEDURE GetChar (adr: INTEGER): CHAR;
VAR
    res: CHAR;

BEGIN
    SYSTEM.GET(adr, res)
    RETURN res
END GetChar;


(* Win32 hands a program one string: the quoted path of the executable, a
   space, then the arguments as the shell wrote them. DOS keeps the two
   apart - the path is what the loader knows the module by, the arguments are
   the command tail in the PSP - so the string is put back together here. The
   arguments keep their numbers either way, and quoting the path keeps a
   directory with a space in it in one piece. *)
PROCEDURE BuildCmdLine;
VAR
    len, tlen, n, i: INTEGER;

BEGIN
    n := 0;
    cmd[n] := '"'; INC(n);
    DOS.ProgPath(SYSTEM.ADR(cmd[n]), MAX_CMD DIV 2, len);
    IF len < 0 THEN
        (* The loader did not answer, so the name is not to be had. Leave a
           stand-in in place rather than let the first argument be mistaken
           for the program. *)
        cmd[n] := 'p'; INC(n); cmd[n] := 'r'; INC(n); cmd[n] := 'o'; INC(n);
        cmd[n] := 'g'; INC(n); cmd[n] := 'r'; INC(n); cmd[n] := 'a'; INC(n);
        cmd[n] := 'm'; INC(n); cmd[n] := '.'; INC(n); cmd[n] := 'e'; INC(n);
        cmd[n] := 'x'; INC(n); cmd[n] := 'e'; INC(n)
    ELSE
        INC(n, len)
    END;
    cmd[n] := '"'; INC(n);

    DOS.CmdLine(SYSTEM.ADR(tail[0]), tlen);
    IF (tlen > 0) & (tail[0] # " ") THEN
        cmd[n] := " "; INC(n)
    END;
    i := 0;
    WHILE (i < tlen) & (n < MAX_CMD - 1) DO
        cmd[n] := tail[i];
        INC(n);
        INC(i)
    END;
    cmd[n] := 0X
END BuildCmdLine;


PROCEDURE ParamParse;
VAR
    p, count, cond: INTEGER;
    c: CHAR;


    PROCEDURE ChangeCond (A, B, C: INTEGER; VAR cond: INTEGER; c: CHAR): INTEGER;
    BEGIN
        IF (c <= 20X) & (c # 0X) THEN
            cond := A
        ELSIF c = 22X THEN
            cond := B
        ELSIF c = 0X THEN
            cond := 6
        ELSE
            cond := C
        END

        RETURN cond
    END ChangeCond;


BEGIN
    p := SYSTEM.ADR(cmd[0]);
    cond := 0;
    count := 0;
    WHILE (count < MAX_PARAM) & (cond # 6) DO
        c := GetChar(p);
        CASE cond OF
        |0: IF ChangeCond(0, 4, 1, cond, c) = 1 THEN Params[count, 0] := p END
        |1: IF ChangeCond(0, 3, 1, cond, c) IN {0, 6} THEN Params[count, 1] := p - 1; INC(count) END
        |3: IF ChangeCond(3, 1, 3, cond, c) = 6 THEN Params[count, 1] := p - 1; INC(count) END
        |4: IF ChangeCond(5, 0, 5, cond, c) = 5 THEN Params[count, 0] := p END
        |5: IF ChangeCond(5, 1, 5, cond, c) = 6 THEN Params[count, 1] := p - 1; INC(count) END
        |6:
        END;
        INC(p)
    END;
    argc := count
END ParamParse;


PROCEDURE GetArg* (n: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    i, j, len: INTEGER;
    c: CHAR;

BEGIN
    j := 0;
    (* A negative index is not an argument; without the test below Params[n, 0]
       would index the array from the far side of its start. *)
    IF (n >= 0) & (n < argc) THEN
        i := Params[n, 0];
        len := LEN(s) - 1;
        WHILE (j < len) & (i <= Params[n, 1]) DO
            c := GetChar(i);
            IF c # '"' THEN
                s[j] := c;
                INC(j)
            END;
            INC(i)
        END
    END;
    s[j] := 0X
END GetArg;


BEGIN
    BuildCmdLine;
    ParamParse
END Args.
