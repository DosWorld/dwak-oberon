(* ********************************************
   Additional functions to the module Math.
   Statistical functions
*********************************************** *)

MODULE MathStat;

IMPORT Math;


(* Minimum value. REAL *)
PROCEDURE MinValue* (data: ARRAY OF REAL; N: INTEGER): REAL;
VAR
    i: INTEGER;
    a: REAL;

BEGIN
    a := data[0];
    FOR i := 1 TO N - 1 DO
        IF data[i] < a THEN
            a := data[i]
        END
    END

    RETURN a
END MinValue;


(* Minimum value. INTEGER *)
PROCEDURE MinIntValue* (data: ARRAY OF INTEGER; N: INTEGER): INTEGER;
VAR
    i: INTEGER;
    a: INTEGER;

BEGIN
    a := data[0];
    FOR i := 1 TO N - 1 DO
        IF data[i] < a THEN
            a := data[i]
        END
    END

    RETURN a
END MinIntValue;


(* Maximum value. REAL *)
PROCEDURE MaxValue* (data: ARRAY OF REAL; N: INTEGER): REAL;
VAR
    i: INTEGER;
    a: REAL;

BEGIN
    a := data[0];
    FOR i := 1 TO N - 1 DO
        IF data[i] > a THEN
            a := data[i]
        END
    END

    RETURN a
END MaxValue;


(* Maximum value. INTEGER *)
PROCEDURE MaxIntValue* (data: ARRAY OF INTEGER; N: INTEGER): INTEGER;
VAR
    i: INTEGER;
    a: INTEGER;

BEGIN
    a := data[0];
    FOR i := 1 TO N - 1 DO
        IF data[i] > a THEN
            a := data[i]
        END
    END

    RETURN a
END MaxIntValue;


(* Sum of the array values *)
PROCEDURE Sum* (data: ARRAY OF REAL; Count: INTEGER): REAL;
VAR
    a: REAL;
    i: INTEGER;

BEGIN
    a := 0.0;
    FOR i := 0 TO Count - 1 DO
        a := a + data[i]
    END

    RETURN a
END Sum;


(* Sum of the INTEGER array values *)
PROCEDURE SumInt* (data: ARRAY OF INTEGER; Count: INTEGER): INTEGER;
VAR
    a: INTEGER;
    i: INTEGER;

BEGIN
    a := 0;
    FOR i := 0 TO Count - 1 DO
        a := a + data[i]
    END

    RETURN a
END SumInt;


(* Sum of squares of the array values *)
PROCEDURE SumOfSquares* (data : ARRAY OF REAL; Count: INTEGER): REAL;
VAR
    a: REAL;
    i: INTEGER;

BEGIN
    a := 0.0;
    FOR i := 0 TO Count - 1 DO
        a := a + Math.sqrr(data[i])
    END

    RETURN a
END SumOfSquares;


(* Sum of the array values and the sum of their squares *)
PROCEDURE SumsAndSquares* (data: ARRAY OF REAL; Count : INTEGER;
                            VAR sum, sumofsquares : REAL);
VAR
    i: INTEGER;
    temp: REAL;

BEGIN
    sumofsquares := 0.0;
    sum := 0.0;
    FOR i := 0 TO Count - 1 DO
        temp := data[i];
        sumofsquares := sumofsquares + Math.sqrr(temp);
        sum := sum + temp
    END
END SumsAndSquares;


(* Mean of the array values *)
PROCEDURE Mean* (data: ARRAY OF REAL; Count: INTEGER): REAL;
    RETURN Sum(data, Count) / FLT(Count)
END Mean;


PROCEDURE MeanAndTotalVariance* (data: ARRAY OF REAL; Count: INTEGER;
                                 VAR mu: REAL; VAR variance: REAL);
VAR
    i: INTEGER;

BEGIN
    mu := Mean(data, Count);
    variance := 0.0;
    FOR i := 0 TO Count - 1 DO
        variance := variance + Math.sqrr(data[i] - mu)
    END
END MeanAndTotalVariance;


(* Computes the statistical variance equal to the sum of squares of the differences
   between each particular value of the array Data and the mean value *)
PROCEDURE TotalVariance* (data: ARRAY OF REAL; Count: INTEGER): REAL;
VAR
    mu, tv: REAL;

BEGIN
    MeanAndTotalVariance(data, Count, mu, tv)
    RETURN tv
END TotalVariance;


(* Sample variance of all the array values *)
PROCEDURE Variance* (data: ARRAY OF REAL; Count: INTEGER): REAL;
VAR
    a: REAL;

BEGIN
    IF Count = 1 THEN
        a := 0.0
    ELSE
        a := TotalVariance(data, Count) / FLT(Count - 1)
    END

    RETURN a
END Variance;


(* Standard deviation *)
PROCEDURE StdDev* (data: ARRAY OF REAL; Count: INTEGER): REAL;
    RETURN Math.sqrt(Variance(data, Count))
END StdDev;


(* Arithmetic mean of all the array values, and the standard deviation *)
PROCEDURE MeanAndStdDev* (data: ARRAY OF REAL; Count: INTEGER;
                            VAR mean: REAL; VAR stdDev: REAL);
VAR
    totalVariance: REAL;

BEGIN
    MeanAndTotalVariance(data, Count, mean, totalVariance);
    IF Count < 2 THEN
        stdDev := 0.0
    ELSE
        stdDev := Math.sqrt(totalVariance / FLT(Count - 1))
    END
END MeanAndStdDev;


(* Euclidean norm of all the array values *)
PROCEDURE Norm* (data: ARRAY OF REAL; Count: INTEGER): REAL;
VAR
    a: REAL;
    i: INTEGER;

BEGIN
    a := 0.0;
    FOR i := 0 TO Count - 1 DO
        a := a + Math.sqrr(data[i])
    END

    RETURN Math.sqrt(a)
END Norm;


END MathStat.