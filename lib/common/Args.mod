(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    Copyright (c) 2019-2020, Anton Krotov
    All rights reserved.

    The portable Args: the command line and the environment of a program.

    The two OS families offer different primitives and that is all the split
    below is about.  Linux and macOS start a program with argv and envp
    already laid out as arrays of pointers, so ArchArgs reads them where the
    kernel put them and this module only has to pass the answer on.  Windows
    and DOS start one with a single string - the quoted path of the
    executable, a space, then the arguments - so ArchArgs can only hand that
    string over and the walking of it has to happen here.  That walk used to
    be duplicated verbatim between the Windows Args and the HX-DOS one, and
    it is the same walk in both because the string has the same shape on
    both.

    envc and GetEnv look the same on all four targets, and they are new on
    Windows and DOS, where the old Args had neither.  GetEnv returns the
    whole "NAME=VALUE" entry, not the value alone, so that it answers the
    same thing whichever family the target belongs to.
*)

MODULE Args;

IMPORT SYSTEM, ArchArgs;


CONST

    MAX_PARAM = 1024;


VAR

    argc*: INTEGER;
    envc*: INTEGER;

$IF (WINDOWS | DPMI32)
    (* Each argument as the range of the command line it occupies, filled in
       by ParamParse and read by GetArg. *)
    Params: ARRAY MAX_PARAM, 2 OF INTEGER;
$END


$IF (WINDOWS | DPMI32)
PROCEDURE GetChar (adr: INTEGER): CHAR;
VAR
    res: CHAR;

BEGIN
    SYSTEM.GET(adr, res)

    RETURN res
END GetChar;


(* cond is where in the string the walk has got to: 0 between arguments, 1
   inside one that began without a quote, 4 at the character just after an
   opening quote, 3 inside a quoted stretch of an argument that began
   unquoted, 5 inside an argument that began quoted, 6 at the end of the
   string.  A state change is what tells an argument apart from a space
   inside one, so it is the transitions that the tests below look at rather
   than the characters that cause them.

   ChangeCond answers where one character leads from a state: A for a blank,
   B for a quote, C for anything else, and 6 for the NUL that ends the
   string, whatever the state was.

   Each argument is remembered as the range of the string it occupies; the
   quotes are still in that range and GetArg is what takes them out. *)
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
    p := ArchArgs.CommandLine();
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


(* A negative index is not an argument, and without the test below
   Params[n, 0] would index the array from the far side of its start. *)
PROCEDURE GetArg* (n: INTEGER; VAR s: ARRAY OF CHAR);
VAR
    i, j, len: INTEGER;
    c: CHAR;

BEGIN
    j := 0;
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

$ELSIF (LINUX | MACOS)

(* argv and envp are already arrays of pointers here, so the argument is
   copied out of the one it is and nothing has to be walked. *)
PROCEDURE GetArg* (n: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
    ArchArgs.GetArg(n, s)
END GetArg;

$END


PROCEDURE GetEnv* (n: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
    ArchArgs.GetEnv(n, s)
END GetEnv;


BEGIN

    envc := ArchArgs.envc;
    $IF (WINDOWS | DPMI32)
        ParamParse
    $ELSE
        argc := ArchArgs.argc
    $END

END Args.
