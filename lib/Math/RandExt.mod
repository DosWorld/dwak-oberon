(* ************************************************************
   Additional generators of pseudorandom numbers.
   Vadim Isaev, 2020
   ************************************************************ *)

MODULE RandExt;

IMPORT HOST, MathRound, MathBits;

CONST
  (* For the Mersenne Twister algorithm *)
  N          = 624;
  M          = 397;
  MATRIX_A   = 9908B0DFH;  (* constant vector a *)
  UPPER_MASK = 80000000H;  (* most significant w-r bits *)
  LOWER_MASK = 7FFFFFFFH;  (* least significant r bits *)
  INT_MAX    = 4294967295;


TYPE
(* data structure for the mrg32k3a algorithm *)
  random_t = RECORD
    mrg32k3a_seed       : REAL;
    mrg32k3a_x          : ARRAY 3 OF REAL;
    mrg32k3a_y          : ARRAY 3 OF REAL
  END;

  (* For the Mersenne Twister algorithm *)
  MTKeyArray = ARRAY N OF INTEGER;

VAR
  (* For the mrg32k3a algorithm *)
  prndl: random_t;
  (* For the Mersenne Twister algorithm *)
  mt  : MTKeyArray;  (* the array for the state vector *)
  mti : INTEGER;     (* mti == N+1 means mt[N] is not initialized *)

(* ---------------------------------------------------------------------------
   Generator of pseudorandom numbers in the range [a,b].
   Algorithm 133b from the book "Ageev et al. - Library of algorithms 101b-150b",
   page 53.
   Converted from Algol to Oberon and revised, Vadim Isayev, 2020

   Generator pseudorandom numbers, algorithm 133b from
   Comm ACM 5,10 (Oct 1962) 553.
   Convert from Algol to Oberon Vadim Isaev, 2020.

   Input parameters:
     a - initial computed value, type REAL;
     b - final computed value, type REAL;
     seed - initial value for random number generation.
            It must be in the range from 10 000 000 000 to 34 359 738 368 (2^35),
            and it must be odd.
   --------------------------------------------------------------------------- *)
PROCEDURE alg133b* (a, b: REAL; VAR seed: INTEGER): REAL;
CONST
  m35 = 34359738368;
  m36 = 68719476736;
  m37 = 137438953472;

VAR
  x: INTEGER;
BEGIN
  IF seed # 0 THEN
    IF  (seed MOD 2 = 0) THEN
      seed := seed + 1
    END;
    x:=seed;
    seed:=0;
  END;

  x:=5*x;
  IF x>=m37 THEN
    x:=x-m37
  END;
  IF x>=m36 THEN
    x:=x-m36
  END;
  IF x>=m35 THEN
    x:=x-m35
  END;

  RETURN FLT(x) / FLT(m35) * (b - a) + a
END alg133b;

(* ----------------------------------------------------------
   Generator pseudorandom numbers,
   algorithm mrg32k3a.

   Convert from FreePascal to Oberon, Vadim Isaev, 2020
   ---------------------------------------------------------- *)
(* Initialization of the generator.

   Input parameters:
     seed  - value for initialization. Any value. If zero is passed,
             then the number of processor ticks is substituted
             instead of zero. *)
PROCEDURE mrg32k3a_init* (seed: REAL);
BEGIN
  prndl.mrg32k3a_x[0] := 1.0;
  prndl.mrg32k3a_x[1] := 1.0;
  prndl.mrg32k3a_y[0] := 1.0;
  prndl.mrg32k3a_y[1] := 1.0;
  prndl.mrg32k3a_y[2] := 1.0;

  IF seed # 0.0 THEN
    prndl.mrg32k3a_x[2] := seed;
  ELSE
    prndl.mrg32k3a_x[2] := FLT(HOST.GetTickCount());
  END;

END mrg32k3a_init;

(* Generator of pseudorandom numbers from 0.0 to 1.0. *)
PROCEDURE mrg32k3a* (): REAL;

CONST
  (* random MRG32K3A algorithm constants *)
  MRG32K3A_NORM = 2.328306549295728E-10;
  MRG32K3A_M1   = 4294967087.0;
  MRG32K3A_M2   = 4294944443.0;
  MRG32K3A_A12  = 1403580.0;
  MRG32K3A_A13  = 810728.0;
  MRG32K3A_A21  = 527612.0;
  MRG32K3A_A23  = 1370589.0;
  RAND_BUFSIZE  = 512;

VAR

  xn, yn, result: REAL;

BEGIN
  (* Part 1 *)
  xn := MRG32K3A_A12 * prndl.mrg32k3a_x[1] - MRG32K3A_A13 * prndl.mrg32k3a_x[2];
  xn := xn - MathRound.trunc(xn / MRG32K3A_M1) * MRG32K3A_M1;
  IF xn < 0.0 THEN
    xn := xn + MRG32K3A_M1;
  END;

  prndl.mrg32k3a_x[2] := prndl.mrg32k3a_x[1];
  prndl.mrg32k3a_x[1] := prndl.mrg32k3a_x[0];
  prndl.mrg32k3a_x[0] := xn;

  (* Part 2 *)
  yn := MRG32K3A_A21 * prndl.mrg32k3a_y[0] - MRG32K3A_A23 * prndl.mrg32k3a_y[2];
  yn := yn - MathRound.trunc(yn / MRG32K3A_M2) * MRG32K3A_M2;
  IF yn < 0.0 THEN
    yn := yn + MRG32K3A_M2;
  END;

  prndl.mrg32k3a_y[2] := prndl.mrg32k3a_y[1];
  prndl.mrg32k3a_y[1] := prndl.mrg32k3a_y[0];
  prndl.mrg32k3a_y[0] := yn;

  (* Combining the parts *)
  IF xn <= yn THEN
    result := ((xn - yn + MRG32K3A_M1) * MRG32K3A_NORM)
  ELSE
    result := (xn - yn) * MRG32K3A_NORM;
  END;

  RETURN result
END mrg32k3a;


(* -------------------------------------------------------------------
    Mersenne Twister Random Number Generator.

    A C-program for MT19937, with initialization improved 2002/1/26.
    Coded by Takuji Nishimura and Makoto Matsumoto.

    Adapted for DMath by Jean Debord - Feb. 2007
    Adapted for Oberon-07 by Vadim Isaev - May 2020
  ------------------------------------------------------------ *)
(* Initializes MT generator with a seed *)
PROCEDURE InitMT(Seed : INTEGER);
VAR
  i : INTEGER;
BEGIN
  mt[0] := MathBits.iand(Seed, INT_MAX);
  FOR i := 1 TO N-1 DO
      mt[i] := (1812433253 * MathBits.ixor(mt[i-1], LSR(mt[i-1], 30)) + i);
        (* See Knuth TAOCP Vol2. 3rd Ed. P.106 For multiplier.
          In the previous versions, MSBs of the seed affect
          only MSBs of the array mt[].
          2002/01/09 modified by Makoto Matsumoto *)
      mt[i] := MathBits.iand(mt[i], INT_MAX);
        (* For >32 Bit machines *)
  END;
  mti := N;
END InitMT;

(* Initialize MT generator with an array InitKey[0..(KeyLength - 1)] *)
PROCEDURE InitMTbyArray(InitKey : MTKeyArray; KeyLength : INTEGER);
VAR
  i, j, k, k1 : INTEGER;
BEGIN
  InitMT(19650218);

  i := 1;
  j := 0;

  IF N > KeyLength THEN
    k1 := N
  ELSE
    k1 := KeyLength;
  END;

  FOR k := k1 TO 1 BY -1 DO
    (* non linear *)
    mt[i] := MathBits.ixor(mt[i], (MathBits.ixor(mt[i-1], LSR(mt[i-1], 30)) * 1664525)) + InitKey[j] + j;
    mt[i] := MathBits.iand(mt[i], INT_MAX); (* for WORDSIZE > 32 machines *)
    INC(i);
    INC(j);
    IF i >= N THEN
      mt[0] := mt[N-1];
      i := 1;
    END;
    IF j >= KeyLength THEN
      j := 0;
    END;
  END;

  FOR k := N-1 TO 1 BY -1 DO
    (* non linear *)
    mt[i] := MathBits.ixor(mt[i], (MathBits.ixor(mt[i-1], LSR(mt[i-1], 30)) * 1566083941)) - i;
    mt[i] := MathBits.iand(mt[i], INT_MAX); (* for WORDSIZE > 32 machines *)
    INC(i);
    IF i >= N THEN
      mt[0] := mt[N-1];
      i := 1;
    END;
  END;

  mt[0] := UPPER_MASK; (* MSB is 1; assuring non-zero initial array *)

END InitMTbyArray;

(* Generates a integer Random number on [-2^31 .. 2^31 - 1] interval *)
PROCEDURE IRanMT(): INTEGER;
VAR
  mag01 : ARRAY 2 OF INTEGER;
  y,k   : INTEGER;
BEGIN
  IF mti >= N THEN  (* generate N words at one Time *)
    (* If IRanMT() has not been called, a default initial seed is used *)
    IF mti = N + 1 THEN
      InitMT(5489);
    END;

    FOR k := 0 TO (N-M)-1 DO
      y := MathBits.ior(MathBits.iand(mt[k], UPPER_MASK), MathBits.iand(mt[k+1], LOWER_MASK));
      mt[k] := MathBits.ixor(MathBits.ixor(mt[k+M], LSR(y, 1)), mag01[MathBits.iand(y, 1H)]);
    END;

    FOR k := (N-M) TO (N-2) DO
      y := MathBits.ior(MathBits.iand(mt[k], UPPER_MASK), MathBits.iand(mt[k+1], LOWER_MASK));
      mt[k] := MathBits.ixor(mt[k - (N - M)], MathBits.ixor(LSR(y, 1), mag01[MathBits.iand(y, 1H)]));
    END;

    y := MathBits.ior(MathBits.iand(mt[N-1], UPPER_MASK), MathBits.iand(mt[0], LOWER_MASK));
    mt[N-1] := MathBits.ixor(mt[M-1], MathBits.ixor(LSR(y, 1), mag01[MathBits.iand(y, 1H)]));

    mti := 0;
  END;

  y := mt[mti];
  INC(mti);

  (* Tempering *)
  y := MathBits.ixor(y, LSR(y, 11));
  y := MathBits.ixor(y, MathBits.iand(LSL(y,  7), 9D2C5680H));
  y := MathBits.ixor(y, MathBits.iand(LSL(y, 15), 4022730752));
  y := MathBits.ixor(y, LSR(y, 18));

  RETURN y
END IRanMT;

(* Generates a real Random number on [0..1] interval *)
PROCEDURE RRanMT(): REAL;
BEGIN
  RETURN FLT(IRanMT())/FLT(INT_MAX)
END RRanMT;


END RandExt.
