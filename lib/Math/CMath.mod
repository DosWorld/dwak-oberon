(* ***********************************************
    Module for complex numbers.
    Vadim Isaev, 2020
*************************************************** *)

MODULE CMath;

IMPORT Math, Out;

TYPE
  complex* = POINTER TO RECORD
    re*: REAL;
    im*: REAL
  END;

VAR
  result: complex;

  i* : complex;
  _0*: complex;

(* Init complex number. *)
PROCEDURE CInit* (re : REAL; im: REAL): complex;
VAR
  temp: complex;
BEGIN
  NEW(temp);
  temp.re:=re;
  temp.im:=im;

  RETURN temp
END CInit;


(* Four base operations  +, -, * , / *)

(* addition : z := z1 + z2 *)
PROCEDURE CAdd* (z1, z2: complex): complex;
BEGIN
  result.re := z1.re + z2.re;
  result.im := z1.im + z2.im;

  RETURN result
END CAdd;

(* addition : z := z1 + r1 *)
PROCEDURE CAdd_r* (z1: complex; r1: REAL): complex;
BEGIN
  result.re := z1.re + r1;
  result.im := z1.im;

  RETURN result
END CAdd_r;

(* addition : z := z1 + i1 *)
PROCEDURE CAdd_i* (z1: complex; i1: INTEGER): complex;
BEGIN
  result.re := z1.re + FLT(i1);
  result.im := z1.im;

  RETURN result
END CAdd_i;

(* Change of sign.
   substraction : z := - z1 *)
PROCEDURE CNeg (z1 : complex): complex;
BEGIN
  result.re := -z1.re;
  result.im := -z1.im;

  RETURN result
END CNeg;

(* substraction : z := z1 - z2 *)
PROCEDURE CSub* (z1, z2 : complex): complex;
BEGIN
  result.re := z1.re - z2.re;
  result.im := z1.im - z2.im;

  RETURN result
END CSub;

(* substraction : z := z1 - r1 *)
PROCEDURE CSub_r1* (z1 : complex; r1 : REAL): complex;
BEGIN
  result.re := z1.re - r1;
  result.im := z1.im;

  RETURN result
END CSub_r1;

(* substraction : z := r1 - z1 *)
PROCEDURE CSub_r2* (r1 : REAL; z1 : complex): complex;
BEGIN
  result.re := r1 - z1.re;
  result.im := - z1.im;

  RETURN result
END CSub_r2;

(* substraction : z := z1 - i1 *)
PROCEDURE CSub_i* (z1 : complex; i1 : INTEGER): complex;
BEGIN
  result.re := z1.re - FLT(i1);
  result.im := z1.im;

  RETURN result
END CSub_i;

(* multiplication : z := z1 * z2 *)
PROCEDURE CMul (z1, z2 : complex): complex;
BEGIN
  result.re := (z1.re * z2.re) - (z1.im * z2.im);
  result.im := (z1.re * z2.im) + (z1.im * z2.re);

  RETURN result
END CMul;

(* multiplication : z := z1 * r1 *)
PROCEDURE CMul_r (z1 : complex; r1 : REAL): complex;
BEGIN
  result.re := z1.re * r1;
  result.im := z1.im * r1;

  RETURN result
END CMul_r;

(* multiplication : z := z1 * i1 *)
PROCEDURE CMul_i (z1 : complex; i1 : INTEGER): complex;
BEGIN
  result.re := z1.re * FLT(i1);
  result.im := z1.im * FLT(i1);

  RETURN result
END CMul_i;

(* division : z := znum / zden *)
PROCEDURE CDiv (z1, z2 : complex): complex;
    (* The following algorithm is used to properly handle
      denominator overflow:

                 |  a + b(d/c)   c - a(d/c)
                 |  ---------- + ---------- I     if |d| < |c|
      a + b I    |  c + d(d/c)   a + d(d/c)
      -------  = |
      c + d I    |  b + a(c/d)   -a+ b(c/d)
                 |  ---------- + ---------- I     if |d| >= |c|
                 |  d + c(c/d)   d + c(c/d)
    *)
VAR
  tmp, denom : REAL;
BEGIN
   IF ( ABS(z2.re) > ABS(z2.im) ) THEN
     tmp := z2.im / z2.re;
     denom := z2.re + z2.im * tmp;
     result.re := (z1.re + z1.im * tmp) / denom;
     result.im := (z1.im - z1.re * tmp) / denom;
   ELSE
     tmp := z2.re / z2.im;
     denom := z2.im + z2.re * tmp;
     result.re := (z1.im + z1.re * tmp) / denom;
     result.im := (-z1.re + z1.im * tmp) / denom;
   END;

   RETURN result
END CDiv;

(* division : z := znum / r1 *)
PROCEDURE CDiv_r* (z1 : complex; r1 : REAL): complex;
BEGIN
  result.re := z1.re / r1;
  result.im := z1.im / r1;

  RETURN result
END CDiv_r;

(* division : z := znum / i1 *)
PROCEDURE CDiv_i* (z1 : complex; i1 : INTEGER): complex;
BEGIN
  result.re := z1.re / FLT(i1);
  result.im := z1.im / FLT(i1);

  RETURN result
END CDiv_i;

(* fonctions elementaires *)

(* out complex number *)
PROCEDURE CPrint* (z: complex; width: INTEGER);
BEGIN
  Out.Real(z.re, width);
  IF z.im>=0.0 THEN
    Out.String("+");
  END;
  Out.Real(z.im, width);
  Out.String("i");
END CPrint;

PROCEDURE CPrintLn* (z: complex; width: INTEGER);
BEGIN
  CPrint(z, width);
  Out.Ln;
END CPrintLn;

(* Output to the screen with a fixed number of digits
   after the decimal point (p) *)
PROCEDURE CPrintFix* (z: complex; width, p: INTEGER);
BEGIN
  Out.FixReal(z.re, width, p);
  IF z.im>=0.0 THEN
    Out.String("+");
  END;
  Out.FixReal(z.im, width, p);
  Out.String("i");
END CPrintFix;

PROCEDURE CPrintFixLn* (z: complex; width, p: INTEGER);
BEGIN
  CPrintFix(z, width, p);
  Out.Ln;
END CPrintFixLn;

(* module : r = |z| *)
PROCEDURE CMod* (z1 : complex): REAL;
BEGIN
  RETURN Math.sqrt((z1.re * z1.re) + (z1.im * z1.im))
END CMod;

(* square : r := z*z *)
PROCEDURE CSqr* (z1: complex): complex;
BEGIN
  result.re := z1.re * z1.re - z1.im * z1.im;
  result.im := 2.0 * z1.re * z1.im;

  RETURN result
END CSqr;

(* square root : r := sqrt(z) *)
PROCEDURE CSqrt* (z1: complex): complex;
VAR
  root, q: REAL;
BEGIN
  IF (z1.re#0.0) OR (z1.im#0.0) THEN
    root := Math.sqrt(0.5 * (ABS(z1.re) + CMod(z1)));
    q := z1.im / (2.0 * root);
    IF z1.re >= 0.0 THEN
      result.re := root;
      result.im := q;
    ELSE
      IF z1.im < 0.0 THEN
        result.re := - q;
        result.im := - root
      ELSE
        result.re :=  q;
        result.im :=  root
      END
    END
  ELSE
    result := z1;
  END;

  RETURN result
END CSqrt;

(* exponantial : r := exp(z) *)
(* exp(x + iy) = exp(x).exp(iy) = exp(x).[cos(y) + i sin(y)] *)
PROCEDURE CExp* (z: complex): complex;
VAR
  expz : REAL;
BEGIN
  expz := Math.exp(z.re);
  result.re := expz * Math.cos(z.im);
  result.im := expz * Math.sin(z.im);

  RETURN result
END CExp;

(* natural logarithm : r := ln(z) *)
(* ln( p exp(i0)) = ln(p) + i0 + 2kpi *)
PROCEDURE CLn* (z: complex): complex;
BEGIN
  result.re := Math.ln(CMod(z));
  result.im := Math.arctan2(z.im, z.re);

  RETURN result
END CLn;

(* exp : z := z1^z2 *)
PROCEDURE CPower* (z1, z2 : complex): complex;
VAR
  a: complex;
BEGIN
   a:=CLn(z1);
   a:=CMul(z2, a);
   result:=CExp(a);

   RETURN result
END CPower;

(* multiplication : z := z1^r *)
PROCEDURE CPower_r* (z1: complex; r: REAL): complex;
VAR
  a: complex;
BEGIN
  a:=CLn(z1);
  a:=CMul_r(a, r);
  result:=CExp(a);

  RETURN result
END CPower_r;

(* inverse : r := 1 / z *)
PROCEDURE CInv* (z: complex): complex;
VAR
  denom : REAL;
BEGIN
  denom := (z.re * z.re) + (z.im * z.im);
  (* generates a fpu exception if denom=0 as for reals *)
  result.re:=z.re/denom;
  result.im:=-z.im/denom;

  RETURN result
END CInv;

(* direct trigonometric functions *)

(* complex cosinus *)
(* cos(x+iy) = cos(x).cos(iy) - sin(x).sin(iy) *)
(* cos(ix) = cosh(x) et sin(ix) = i.sinh(x) *)
PROCEDURE CCos* (z: complex): complex;
BEGIN
  result.re := Math.cos(z.re) * Math.cosh(z.im);
  result.im := - Math.sin(z.re) * Math.sinh(z.im);

  RETURN result
END CCos;

(* sinus complex *)
(* sin(x+iy) = sin(x).cos(iy) + cos(x).sin(iy) *)
(* cos(ix) = cosh(x) et sin(ix) = i.sinh(x) *)
PROCEDURE CSin (z: complex): complex;
BEGIN
  result.re := Math.sin(z.re) * Math.cosh(z.im);
  result.im := Math.cos(z.re) * Math.sinh(z.im);

  RETURN result
END CSin;

(* tangente *)
PROCEDURE CTg* (z: complex): complex;
VAR
  temp1, temp2: complex;
BEGIN
  temp1:=CSin(z);
  temp2:=CCos(z);
  result:=CDiv(temp1, temp2);

  RETURN result
END CTg;

(* inverse complex hyperbolic functions *)

(* hyberbolic arg cosinus *)
(*                          _________  *)
(* argch(z) = -/+ ln(z + i.V 1 - z.z)  *)
PROCEDURE CArcCosh* (z : complex): complex;
BEGIN
  result:=CNeg(CLn(CAdd(z, CMul(i, CSqrt(CSub_r2(1.0, CMul(z, z)))))));

  RETURN result
END CArcCosh;

(* hyperbolic arc sinus       *)
(*                    ________  *)
(* argsh(z) = ln(z + V 1 + z.z) *)
PROCEDURE CArcSinh* (z : complex): complex;
BEGIN
  result:=CLn(CAdd(z, CSqrt(CAdd_r(CMul(z, z), 1.0))));

  RETURN result
END CArcSinh;

(* hyperbolic arc tangent *)
(* argth(z) = 1/2 ln((z + 1) / (1 - z)) *)
PROCEDURE CArcTgh (z : complex): complex;
BEGIN
  result:=CDiv_r(CLn(CDiv(CAdd_r(z, 1.0), CSub_r2(1.0, z))), 2.0);

  RETURN result
END CArcTgh;

(* trigonometriques inverses *)

(* arc cosinus complex *)
(* arccos(z) = -i.argch(z) *)
PROCEDURE CArcCos* (z: complex): complex;
BEGIN
  result := CNeg(CMul(i, CArcCosh(z)));

  RETURN result
END CArcCos;

(* arc sinus complex *)
(* arcsin(z) = -i.argsh(i.z) *)
PROCEDURE CArcSin* (z : complex): complex;
BEGIN
  result := CNeg(CMul(i, CArcSinh(z)));

  RETURN result
END CArcSin;

(* arc tangente complex *)
(* arctg(z) = -i.argth(i.z) *)
PROCEDURE CArcTg* (z : complex): complex;
BEGIN
  result := CNeg(CMul(i, CArcTgh(CMul(i, z))));

  RETURN result
END CArcTg;

BEGIN

  result:=CInit(0.0, 0.0);
  i :=CInit(0.0, 1.0);
  _0:=CInit(0.0, 0.0);

END CMath.
