(*
    Public domain

    Copyright (c) 2026-, DosWorld
    All rights reserved.
*)
MODULE Arrays;

IMPORT SYSTEM;

CONST
  Align      = 4;
  InitialCap = 32;

TYPE
  ArrayList* = POINTER TO ArrayListDesc;
  ArrayListDesc = RECORD
    data:      POINTER TO ARRAY OF BYTE;
    size:      INTEGER;
    stride:    INTEGER;
    count:     INTEGER;
    capacity:  INTEGER;
    Reserve*:  PROCEDURE (self: ArrayList; minCap: INTEGER);
    Add*:      PROCEDURE (self: ArrayList; elem: SYSTEM.PTR);
    Insert*:   PROCEDURE (self: ArrayList; i: INTEGER; elem: SYSTEM.PTR);
    Remove*:   PROCEDURE (self: ArrayList; i: INTEGER);
    Clear*:    PROCEDURE (self: ArrayList);
    Put*:      PROCEDURE (self: ArrayList; i: INTEGER; elem: SYSTEM.PTR);
    Get*:      PROCEDURE (self: ArrayList; i: INTEGER): SYSTEM.PTR;
    GetCopy*:  PROCEDURE (self: ArrayList; i: INTEGER; dst: SYSTEM.PTR);
    Pack*:     PROCEDURE (self: ArrayList);
    Count*:    PROCEDURE (self: ArrayList): INTEGER;
    Capacity*: PROCEDURE (self: ArrayList): INTEGER;
    ElemSize*: PROCEDURE (self: ArrayList): INTEGER;
    Done*:     PROCEDURE (self: ArrayList)
  END;

PROCEDURE AlignUp(n: INTEGER): INTEGER;
BEGIN
  RETURN (n + Align - 1) DIV Align * Align
END AlignUp;

PROCEDURE ReserveImpl(self: ArrayList; minCap: INTEGER);
VAR
  newCap, bytes: INTEGER;
  newData: POINTER TO ARRAY OF BYTE;
BEGIN
  IF minCap <= self.capacity THEN RETURN END;
  newCap := self.capacity;
  IF newCap = 0 THEN newCap := InitialCap END;
  WHILE newCap < minCap DO newCap := newCap * 2 END;
  bytes := newCap * self.stride;
  NEW(newData, bytes);
  IF self.count > 0 THEN
    SYSTEM.MOVE(SYSTEM.ADR(self.data[0]), SYSTEM.ADR(newData[0]),
                self.count * self.stride)
  END;
  IF self.data # NIL THEN DISPOSE(self.data) END;
  self.data := newData;
  self.capacity := newCap
END ReserveImpl;

PROCEDURE AddImpl(self: ArrayList; elem: SYSTEM.PTR);
BEGIN
  IF self.count = self.capacity THEN self.Reserve(self, self.count + 64) END;
  SYSTEM.MOVE(elem, SYSTEM.ADR(self.data[self.count * self.stride]),
              self.size);
  INC(self.count)
END AddImpl;

PROCEDURE InsertImpl(self: ArrayList; i: INTEGER; elem: SYSTEM.PTR);
VAR src, dst: SYSTEM.PTR;
BEGIN
  ASSERT((i >= 0) & (i <= self.count));
  IF self.count = self.capacity THEN self.Reserve(self, self.count + 1) END;
  IF i < self.count THEN
    src := SYSTEM.ADR(self.data[i * self.stride]);
    dst := SYSTEM.ADR(self.data[(i + 1) * self.stride]);
    SYSTEM.MOVE(src, dst, (self.count - i) * self.stride)
  END;
  SYSTEM.MOVE(elem, SYSTEM.ADR(self.data[i * self.stride]), self.size);
  INC(self.count)
END InsertImpl;

PROCEDURE RemoveImpl(self: ArrayList; i: INTEGER);
VAR src, dst: SYSTEM.PTR;
BEGIN
  ASSERT((i >= 0) & (i < self.count));
  DEC(self.count);
  IF i < self.count THEN
    src := SYSTEM.ADR(self.data[(i + 1) * self.stride]);
    dst := SYSTEM.ADR(self.data[i * self.stride]);
    SYSTEM.MOVE(src, dst, (self.count - i) * self.stride)
  END
END RemoveImpl;

PROCEDURE ClearImpl(self: ArrayList);
BEGIN
  self.count := 0
END ClearImpl;

PROCEDURE PutImpl(self: ArrayList; i: INTEGER; elem: SYSTEM.PTR);
BEGIN
  ASSERT((i >= 0) & (i < self.count));
  SYSTEM.MOVE(elem, SYSTEM.ADR(self.data[i * self.stride]), self.size)
END PutImpl;

PROCEDURE GetImpl(self: ArrayList; i: INTEGER): SYSTEM.PTR;
BEGIN
  ASSERT((i >= 0) & (i < self.count));
  RETURN SYSTEM.ADR(self.data[i * self.stride])
END GetImpl;

PROCEDURE GetCopyImpl(self: ArrayList; i: INTEGER; dst: SYSTEM.PTR);
BEGIN
  ASSERT((i >= 0) & (i < self.count));
  ASSERT(dst # NIL);
  SYSTEM.MOVE(SYSTEM.ADR(self.data[i * self.stride]), dst, self.size)
END GetCopyImpl;

PROCEDURE PackImpl(self: ArrayList);
VAR newData: POINTER TO ARRAY OF BYTE;
BEGIN
  IF self.count = 0 THEN
    IF self.data # NIL THEN DISPOSE(self.data) END;
    self.data := NIL;
    self.capacity := 0;
    RETURN
  END;
  IF self.count = self.capacity THEN RETURN END;
  NEW(newData, self.count * self.stride);
  SYSTEM.MOVE(SYSTEM.ADR(self.data[0]), SYSTEM.ADR(newData[0]),
              self.count * self.stride);
  DISPOSE(self.data);
  self.data := newData;
  self.capacity := self.count
END PackImpl;

PROCEDURE CountImpl(self: ArrayList): INTEGER;
BEGIN RETURN self.count END CountImpl;

PROCEDURE CapacityImpl(self: ArrayList): INTEGER;
BEGIN RETURN self.capacity END CapacityImpl;

PROCEDURE ElemSizeImpl(self: ArrayList): INTEGER;
BEGIN RETURN self.size END ElemSizeImpl;

PROCEDURE DoneImpl(self: ArrayList);
BEGIN
  IF self.data # NIL THEN DISPOSE(self.data) END;
  self.data := NIL;
  self.count := 0;
  self.capacity := 0;
  DISPOSE(self)
END DoneImpl;

PROCEDURE Init(self: ArrayList);
BEGIN
  self.Reserve  := ReserveImpl;
  self.Add      := AddImpl;
  self.Insert   := InsertImpl;
  self.Remove   := RemoveImpl;
  self.Clear    := ClearImpl;
  self.Put      := PutImpl;
  self.Get      := GetImpl;
  self.GetCopy  := GetCopyImpl;
  self.Pack     := PackImpl;
  self.Count    := CountImpl;
  self.Capacity := CapacityImpl;
  self.ElemSize := ElemSizeImpl;
  self.Done     := DoneImpl
END Init;

PROCEDURE Create*(elemSize: INTEGER): ArrayList;
VAR l: ArrayList;
BEGIN
  ASSERT(elemSize > 0);
  NEW(l);
  l.size := elemSize;
  l.stride := AlignUp(elemSize);
  l.count := 0;
  l.capacity := 0;
  l.data := NIL;
  Init(l);
  RETURN l
END New;

PROCEDURE CreateCapacity*(elemSize, cap: INTEGER): ArrayList;
VAR l: ArrayList;
BEGIN
  l := New(elemSize);
  IF cap > 0 THEN l.Reserve(l, cap) END;
  RETURN l
END CreateCapacity;

END Arrays.