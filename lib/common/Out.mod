(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The portable Out module: every target writes its output through this one
    module, and the platform differences are confined to ArchOut.

    There used to be six Out modules in three unrelated families.  Windows and
    Linux handed every conversion to C printf, HX-DOS had a formatter of its
    own, and macOS and the two RVM interpreters carried two more variants of a
    formatter written in Oberon.  The same program therefore printed different
    digits on different targets, and a real could come out with ten significant
    digits on one and fifteen on another.

    The Oberon formatter is the one kept, because it is the only one that does
    not depend on a C library being present and linked.  Its reference is the
    macOS source, with the 32-bit variants taken from the RVM32I one.

    Two facts about the target decide which of those variants is compiled, and
    they are not the same fact:

      BITS_32 / BITS_64   the width of an INTEGER, which sets how many digits
                          an integer can have and how the smallest one - the
                          only negative number with no positive twin - is
                          tested for.

      REAL_32 / REAL_64   the width of a REAL.  Win32, Linux32 and HX-DOS run
                          a 32-bit INTEGER beside a 64-bit REAL, so the width
                          of a real cannot be read off the width of an integer.
                          A 4-byte real carries 10 significant digits and a
                          2-digit exponent, an 8-byte one 15 digits and 3.

    Wide characters are the other divided thing.  Windows and HX-DOS have a
    console call that takes UTF-16 directly, so they keep it; every other
    target encodes to UTF-8 in CharW below, which is why only those two carry
    a CharW in their ArchOut.
*)

MODULE Out;

IMPORT SYSTEM, ArchOut;


CONST

(* The smallest INTEGER, whose digits cannot be computed: negating it would
   overflow, so the text is stored and copied instead. *)
$IF (BITS_64)
    MinIntText = "-9223372036854775808";
    MinIntLen  = 20;                    (* characters in MinIntText *)
$ELSE
    MinIntText = "-2147483648";
    MinIntLen  = 11;
$END


PROCEDURE Open*;
BEGIN
    ArchOut.Open
END Open;


PROCEDURE Char* (c: CHAR);
BEGIN
    ArchOut.Char(c)
END Char;


(* CharW - write one UTF-16 code unit.  Only the basic multilingual plane is
   handled: a surrogate pair is not recombined, which matches what the rest of
   the library does with wide text (Strings.Utf8To16 decodes up to three bytes
   only).  A code unit below 80H is one byte, below 800H two, and anything else
   three - the same encoding Utf8To16 reads back. *)
$IF (WINDOWS | DPMI32)
PROCEDURE CharW* (c: WCHAR);
BEGIN
    ArchOut.CharW(c)
END CharW;
$ELSIF (BITS_32 | BITS_64)
PROCEDURE CharW* (c: WCHAR);
VAR
    u, n, i: INTEGER;
    buf: ARRAY 4 OF CHAR;

BEGIN
    u := ORD(c);
    IF u < 80H THEN
        buf[0] := CHR(u);
        n := 1
    ELSIF u < 800H THEN
        buf[0] := CHR(0C0H + u DIV 40H);
        buf[1] := CHR(80H + u MOD 40H);
        n := 2
    ELSE
        buf[0] := CHR(0E0H + u DIV 1000H);
        buf[1] := CHR(80H + (u DIV 40H) MOD 40H);
        buf[2] := CHR(80H + u MOD 40H);
        n := 3
    END;

    FOR i := 0 TO n - 1 DO
        Char(buf[i])
    END
END CharW;
$END


(* String - write a 0X terminated string.  LENGTH of an open array is the
   length the array was declared with, not the length of the text in it, so the
   scan stops at the terminator: the NUL is part of the array and is not output.
   Windows and Linux used to reach the same result through printf's "%.*s",
   which also stops at the terminator, but macOS and the RVM interpreters wrote
   the whole array and so emitted the terminator as a byte. *)
PROCEDURE String* (s: ARRAY OF CHAR);
VAR
    i, n: INTEGER;

BEGIN
    i := 0;
    n := LENGTH(s);
    WHILE (i < n) & (s[i] # 0X) DO
        Char(s[i]);
        INC(i)
    END
END String;


$IF (BITS_32 | BITS_64)
PROCEDURE StringW* (s: ARRAY OF WCHAR);
VAR
    i, n: INTEGER;

BEGIN
    i := 0;
    n := LENGTH(s);
    WHILE (i < n) & (s[i] # WCHR(0)) DO
        CharW(s[i]);
        INC(i)
    END
END StringW;
$END


(* A line ends the way the target's own tools expect it to, which is the same
   question HOST.eol answers: Linux and macOS write the lone line feed their
   terminals and filters assume, and every other target writes a carriage
   return first, so that a program's output looks the same in a DOS or Windows
   text window as it does in a file.

   The RVM targets run on the host rather than on the machine that compiled
   them, so they are the one case the target name cannot settle: compiling one
   with -def host_linux is what says a line feed is wanted.  Undefined means
   the carriage return, which is what HOST.eol there assumes as well. *)
PROCEDURE Ln*;
BEGIN
$IF (LINUX | MACOS | host_linux)
    Char(0AX)
$ELSE
    Char(0DX);
    Char(0AX)
$END
END Ln;


(* The two together, which is how most lines of a report are written. *)
PROCEDURE StringLn* (s: ARRAY OF CHAR);
BEGIN
    String(s);
    Ln
END StringLn;


PROCEDURE Int* (x, width: INTEGER);
VAR
    i, a: INTEGER;
    str: ARRAY MinIntLen + 1 OF CHAR;

BEGIN
$IF (BITS_64)
    IF x = ROR(1, 1) THEN
$ELSE
    IF x = 80000000H THEN
$END
        COPY(MinIntText, str);
        DEC(width, MinIntLen)
    ELSE
        i := 0;
        IF x < 0 THEN
            x := -x;
            i := 1;
            str[0] := "-"
        END;

        (* Count the digits first, so the field can be padded on the left. *)
        a := x;
        REPEAT
            INC(i);
            a := a DIV 10
        UNTIL a = 0;

        str[i] := 0X;
        DEC(width, i);

        (* Then fill them in from the back. *)
        REPEAT
            DEC(i);
            str[i] := CHR(x MOD 10 + ORD("0"));
            x := x DIV 10
        UNTIL x = 0
    END;

    WHILE width > 0 DO
        Char(20X);
        DEC(width)
    END;

    String(str)
END Int;


(* IsNan - TRUE when x is not a number.  The bits are read rather than the
   value compared, because comparing a NaN with anything is false by
   definition, which leaves no comparison to test it with.

   The two halves are read as separate 32-bit sets so that this works whether
   the target's INTEGER is 32 or 64 bits wide: reading the whole real into one
   INTEGER would need the two to be the same size, and on win32, Linux32 and
   HX-DOS the real is the wider of the two.

   An 8-byte real keeps its exponent in bits 62..52, which land in bits 30..20
   of the high half, and an all-ones exponent with a mantissa that is not zero
   is a NaN. *)
$IF (REAL_64)
PROCEDURE IsNan (x: REAL): BOOLEAN;
VAR
    h, l: SET;

BEGIN
    SYSTEM.GET(SYSTEM.ADR(x), l);
    SYSTEM.GET(SYSTEM.ADR(x) + 4, h)

    RETURN (h * {20..30} = {20..30}) & ((h * {0..19} # {}) OR (l * {0..31} # {}))
END IsNan;
$ELSE
PROCEDURE IsNan (x: REAL): BOOLEAN;
VAR
    h: SET;

BEGIN
    SYSTEM.GET(SYSTEM.ADR(x), h)

    RETURN (h * {23..30} = {23..30}) & (h * {0..22} # {})
END IsNan;
$END


(* Inf - write the name of an infinity or of a NaN, in a field of the width
   given.  A NaN goes out as " Nan": printf spells it "nan", and a name that
   starts with a space keeps it in the same column as the signed forms. *)
PROCEDURE Inf (x: REAL; width: INTEGER);
VAR
    s: ARRAY 5 OF CHAR;

BEGIN
    DEC(width, 4);
    IF IsNan(x) THEN
        s := " Nan"
    ELSIF x = SYSTEM.INF() THEN
        s := "+Inf"
    ELSIF x = -SYSTEM.INF() THEN
        s := "-Inf"
    END;

    WHILE width > 0 DO
        Char(20X);
        DEC(width)
    END;

    String(s)
END Inf;


(* unpk10 - split x into a mantissa in [1, 10) and a decimal exponent, both
   returned through the parameters: x becomes the mantissa and n the exponent.
   Parameters: x - the value to split, which must be positive; n - receives the
   exponent. *)
PROCEDURE unpk10 (VAR x: REAL; VAR n: INTEGER);
VAR
    a, b: REAL;

BEGIN
    ASSERT(x > 0.0);
    n := 0;
    WHILE x < 1.0 DO
        x := x * 10.0;
        DEC(n)
    END;

    a := 10.0;
    b := 1.0;

    WHILE a <= x DO
        b := a;
        a := a * 10.0;
        INC(n)
    END;
    x := x / b
END unpk10;


(* _Real - the general case of Real: a value that is neither zero, NaN nor an
   infinity.  The mantissa and exponent come from unpk10, the digit before the
   point is written whole, and the remaining ones are taken off one at a time by
   subtracting the digit just written and scaling what is left back up.

   How many digits to keep and how wide the exponent is come from the width of
   the real: 8 bytes of REAL carries about 15 significant decimal digits and a
   decimal exponent that can reach three digits, 4 bytes carries 10 and two. *)
PROCEDURE _Real (x: REAL; width: INTEGER);
VAR
    n, k, p: INTEGER;

BEGIN
$IF (REAL_64)
    p := MIN(MAX(width - 8, 1), 15);

    width := width - p - 8;
$ELSE
    p := MIN(MAX(width - 7, 1), 10);

    width := width - p - 7;
$END
    WHILE width > 0 DO
        Char(20X);
        DEC(width)
    END;

    IF x < 0.0 THEN
        Char("-");
        x := -x
    ELSE
        Char(20X)
    END;

    unpk10(x, n);

    k := FLOOR(x);
    Char(CHR(k + 30H));
    Char(".");

    WHILE p > 0 DO
        x := (x - FLT(k)) * 10.0;
        k := FLOOR(x);
        Char(CHR(k + 30H));
        DEC(p)
    END;

    Char("E");
    IF n >= 0 THEN
        Char("+")
    ELSE
        Char("-")
    END;
    n := ABS(n);
$IF (REAL_64)
    Char(CHR(n DIV 100 + 30H)); n := n MOD 100;
$END
    Char(CHR(n DIV 10 + 30H));
    Char(CHR(n MOD 10 + 30H))
END _Real;


PROCEDURE Real* (x: REAL; width: INTEGER);
BEGIN
    IF IsNan(x) OR (ABS(x) = SYSTEM.INF()) THEN
        Inf(x, width)
    ELSIF x = 0.0 THEN
        (* Zero has no mantissa to split, so it is written here: the same
           " d.d" then the exponent field of _Real, padded to the same width.
           The digits between the point and the exponent are zeros. *)
$IF (REAL_64)
        WHILE width > 23 DO
            Char(20X);
            DEC(width)
        END;
        DEC(width, 9);
$ELSE
        WHILE width > 17 DO
            Char(20X);
            DEC(width)
        END;
        DEC(width, 8);
$END
        String(" 0.0");
        WHILE width > 0 DO
            Char("0");
            DEC(width)
        END;
$IF (REAL_64)
        String("E+000")
$ELSE
        String("E+00")
$END
    ELSE
        _Real(x, width)
    END
END Real;


(* _FixReal - the general case of FixReal: x is positive on entry, its sign
   having been taken off by the caller, and p is the number of digits to keep
   after the point.  unpk10 gives the position of the point, counted as the
   number of digits before it; from there the digits are written off one at a
   time, in front of the point when it has not been passed and behind it once it
   has. *)
PROCEDURE _FixReal (x: REAL; width, p: INTEGER);
VAR
    n, k: INTEGER;
    minus: BOOLEAN;

BEGIN
    minus := x < 0.0;
    IF minus THEN
        x := -x
    END;

    unpk10(x, n);

    DEC(width, 3 + MAX(p, 0) + MAX(n, 0));
    WHILE width > 0 DO
        Char(20X);
        DEC(width)
    END;

    IF minus THEN
        Char("-")
    ELSE
        Char(20X)
    END;

    IF n < 0 THEN
        (* The point falls before the first significant digit, so the digits
           before it are zeros and the ones kept come from a mantissa that has
           to be stepped back up to the point first. *)
        INC(n);
        Char("0");
        Char(".");
        WHILE (n < 0) & (p > 0) DO
            Char("0");
            INC(n);
            DEC(p)
        END
    ELSE
        WHILE n >= 0 DO
            k := FLOOR(x);
            Char(CHR(k + 30H));
            x := (x - FLT(k)) * 10.0;
            DEC(n)
        END;
        Char(".")
    END;

    WHILE p > 0 DO
        k := FLOOR(x);
        Char(CHR(k + 30H));
        x := (x - FLT(k)) * 10.0;
        DEC(p)
    END

END _FixReal;


PROCEDURE FixReal* (x: REAL; width, p: INTEGER);
BEGIN
    IF IsNan(x) OR (ABS(x) = SYSTEM.INF()) THEN
        Inf(x, width)
    ELSIF x = 0.0 THEN
        DEC(width, 3 + MAX(p, 0));
        WHILE width > 0 DO
            Char(20X);
            DEC(width)
        END;
        String(" 0.");
        WHILE p > 0 DO
            Char("0");
            DEC(p)
        END
    ELSE
        _FixReal(x, width, p)
    END
END FixReal;


END Out.
