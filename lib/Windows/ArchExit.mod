(*
    BSD 2-Clause License

    Copyright (c) 2026-, DosWorld
    All rights reserved.

    The Windows primitive behind the portable Exit: end the process, with a
    code its parent can read.

    The call goes through the runtime's own _exit and not to ExitProcess
    directly.  Every Windows image already carries that procedure - it is what
    the compiler puts at the end of a module body, as a pushed 0 and a call -
    so this adds a call site and nothing else, where naming kernel32 here would
    bind a second library for a program that may never have wanted one.  The
    path is the same either way: RTL._exit calls API.exit calls ExitProcess.

    One file covers both subsystems.  There is no console variant to write:
    ExitProcess ends the process the same way whether it owns a console or a
    window, and the window goes with it.
*)

MODULE ArchExit;

IMPORT RTL;


(* Ends the process.  Nothing after the call runs, no window procedure gets a
   last message, and no buffered writer is flushed - what a program wants
   written, it must have written. *)
PROCEDURE Now* (code: INTEGER);
BEGIN
    RTL._exit(code)
END Now;

END ArchExit.
