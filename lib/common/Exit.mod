(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    End the program, with a code the operating system can read.

    Nothing in the language does this and nothing in the language needs to:
    every image the i386 and amd64 back ends emit already ends by calling its
    runtime's _exit with 0 - the compiler puts that call at the end of the
    module body itself.  What is missing is only a way for the program to name
    that call and to choose the code, and that name is this module.

    The partner is ArchExit, one per target, and it is the only thing that
    knows what ending means there.  That is the whole reason this module exists
    rather than a call to the platform written into each caller: a program says
    Exit, in a module of lib/common, and stays portable.

    A target with no operating system to return a code to has no ArchExit, so a
    program that says Exit does not build for it.  That is the honest answer,
    and it arrives as `module not found` naming ArchExit - a build error with
    the missing half in it, and not a silent no-op.
*)

MODULE Exit;

IMPORT ArchExit;


(* Ends the program.  The call does not return, and nothing is flushed for it:
   what a program wants written, it must have written.  On a target whose
   subsystem is the GUI one this is also how its window goes away, the process
   being what owned it. *)
PROCEDURE Now* (code: INTEGER);
BEGIN
    ArchExit.Now(code)
END Now;

END Exit.
