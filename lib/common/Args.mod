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

$IF (WINDOWS | DPMI32 | DOS)
    (* Each argument as the range of the command line it occupies, filled in
       by ParamParse and read by GetArg. *)
    Params: ARRAY MAX_PARAM, 2 OF INTEGER;
$END


$IF (WINDOWS | DPMI32 | DOS)
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
   quotes are still in that range and GetArg is what takes them out.  A
   range that holds nothing but quotes is therefore an empty argument, and
   one is made whenever a quoted stretch is opened and closed before any
   other character belongs to it - which is how "" is one argument, and
   not none.

   The six states are dispatched with an IF chain and not with a CASE over
   cond: a numeric CASE is a statement this dialect has, but not every compiler
   for it implements one, so a module that may be compiled by another has to go
   without.  The two are the same statement here - every label is a single value
   and 6 has an empty body, which is what falling out of the chain does. *)
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
        IF cond = 0 THEN
            (* A quote opens an argument, and an argument may be empty, so
               the quote's own position is remembered as the range's start.
               Every character the quotes then hold overwrites it below; if
               nothing does, the range is the quotes alone and GetArg takes
               them out, which is an empty argument. *)
            IF ChangeCond(0, 4, 1, cond, c) IN {1, 4} THEN Params[count, 0] := p END
        ELSIF cond = 1 THEN
            IF ChangeCond(0, 3, 1, cond, c) IN {0, 6} THEN Params[count, 1] := p - 1; INC(count) END
        ELSIF cond = 3 THEN
            IF ChangeCond(3, 1, 3, cond, c) = 6 THEN Params[count, 1] := p - 1; INC(count) END
        ELSIF cond = 4 THEN
            (* A quote right after the opening one closes an argument that
               held nothing and is still one argument.  The walk goes to
               state 1 rather than back to 0 so that the argument is
               committed by the same code as any other - on the blank or
               the NUL that follows - and so that a character following the
               quotes joins this argument instead of starting another one:
               ""x is x, and "" is the empty argument. *)
            IF ChangeCond(5, 1, 5, cond, c) = 6 THEN
                Params[count, 1] := p - 1; INC(count)
            ELSIF cond = 5 THEN
                Params[count, 0] := p
            END
        ELSIF cond = 5 THEN
            IF ChangeCond(5, 1, 5, cond, c) = 6 THEN Params[count, 1] := p - 1; INC(count) END
        END ;
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
            IF c # 22X THEN
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
    $IF (WINDOWS | DPMI32 | DOS)
        ParamParse
    $ELSE
        argc := ArchArgs.argc
    $END

END Args.
