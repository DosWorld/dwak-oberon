(* ************************************
   Generator pseudorandom numbers,
   Linear congruential generator,
   Algorithm by D. H. Lehmer.
   Vadim Isaev, 2020
*************************************** *)

MODULE Rand;

IMPORT HOST, Math;


CONST

    RAND_MAX = 2147483647;


VAR
    seed: INTEGER;


PROCEDURE Randomize*;
BEGIN
    seed := HOST.GetTickCount()
END Randomize;


(* Pseudorandom integers 0..RAND_MAX-1 *)
PROCEDURE RandomI* (): INTEGER;
CONST
    a = 630360016;

BEGIN
    seed := (a * seed) MOD RAND_MAX
    RETURN seed
END RandomI;


(* Pseudorandom floating-point numbers in [0, 1) *)
PROCEDURE RandomR* (): REAL;
    RETURN FLT(RandomI()) / FLT(RAND_MAX)
END RandomR;


(* Return a random number in a range 0..aTo-1 *)
PROCEDURE RandomITo* (aTo: INTEGER): INTEGER;
    RETURN FLOOR(RandomR() * FLT(aTo))
END RandomITo;


(* Return a random number in a range *)
PROCEDURE RandomIRange* (aFrom, aTo: INTEGER): INTEGER;
    RETURN FLOOR(RandomR() * FLT(aTo - aFrom + 1)) + aFrom
END RandomIRange;


(* Pseudorandom number. Gaussian distribution *)
PROCEDURE RandG* (mean, stddev: REAL): REAL;
VAR
    U, S: REAL;

BEGIN
    REPEAT
        U := 2.0 * RandomR() - 1.0;
        S := Math.sqrr(U) + Math.sqrr(2.0 * RandomR() - 1.0)
    UNTIL (1.0E-20 < S) & (S <= 1.0)

    RETURN Math.sqrt(-2.0 * Math.ln(S) / S) * U * stddev + mean
END RandG;


BEGIN
    seed := 654321
END Rand.