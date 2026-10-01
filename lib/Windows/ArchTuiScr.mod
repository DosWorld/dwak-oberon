MODULE ArchTuiScr;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The screen itself, which is the one part of the framework that is a target
   and not portable.

   The module a program imports is TuiScr, which keeps the screen's own copy of
   what is on it and the dump, and knows nothing about any of these bodies.

   It is a small seam, five procedures, because there is very little a screen
   has to be able to do: be taken and given back, say what size it is showing,
   take a run of cells, and give a rectangle of them back.

   A cell is two bytes, the character and then its attribute, and every body
   puts the same two bytes in the same order into the same place: a DOS text
   screen wants them that way, and a Windows console cell wants them that way
   too, so a row of cells can be handed over without being taken apart - except
   where two of them disagree, and they disagree in exactly one place, which is
   that a Windows console cell is four bytes rather than two and its character
   is a 16-bit code rather than a byte.  That one difference is settled in the
   two procedures that carry cells across the seam: Write widens a run on its
   way to the screen and Read narrows a rectangle on its way back.

   The size is a proposal rather than a command: Open is handed what the
   application would like and answers with what it got.  Under DOS the video
   mode is not ours to set, so the answer is the BIOS's and the request is
   ignored; on Windows a console buffer is created the size of the window, so
   asking the window for the size first is what gives the application the whole
   screen instead of a corner of somebody else's console.

   Size is the same question asked later, and it exists because a Windows
   console can change size under a running program - somebody drags the frame.
   It answers what is on show now rather than what Open gave, and on a console
   the two are deliberately different numbers: Open's answer is the buffer the
   program made, and Size's is the part of it the window shows.

   Two of the six Windows targets have a screen and the rest have not, so
   this file is two bodies chosen by target name, the way ArchInput's is.  A
   console has a screen buffer of its own to make and put on the screen; a
   window draws through a device context and a DLL has no screen at all, so the
   four targets that are neither win32con nor win64con get the empty body and
   the framework still compiles for them. *)

$IF (win32con | win64con | win32dll | win64dll)

IMPORT SYSTEM, WINAPI, Charset, TuiPage;

CONST
    KERNEL = "kernel32.dll";

    STD_OUTPUT_HANDLE = -11;

    GENERIC_READ_WRITE = 0C0000000H;
    SHARE_RW           = 3;
    OPEN_EXISTING      = 3;

    (* CreateConsoleScreenBuffer's dwFlags: a buffer of text cells, which is the
       only kind there is. *)
    TEXTMODE_BUFFER = 1;

    (* The code page the console is set to, which decides what a *byte* the
       program hands to Out means and what the clipboard's OEM text means.  It
       no longer decides what the screen shows: a canvas cell is a code point
       now and goes out through WriteConsoleOutputW, so what a box character
       looks like is the console font's business and not this number's.  Kept,
       because a program that prints with Out.String is still writing bytes and
       866 is the page it wrote them in. *)
    CP_OEM = 866;

    (* Cells one WriteConsoleOutputW call takes.  A run of changed cells can be
       as long as a row, and a row can be as wide as the console is, so a long
       run goes in chunks of this. *)
    MAXCHUNK = 256;

TYPE
    (* A console cell: CHAR_INFO, four bytes, and four bytes is what a canvas
       cell is - a 16-bit character and a 16-bit attribute, in that order.  The
       two layouts are the same one, which is why a canvas row is handed to
       WriteConsoleOutputW as it stands.  Nothing declares a variable of this
       type any more; it is kept because it is what the addresses passed to
       those two calls are, and a reader who wants to know why a + 4 is a cell
       finds the answer here. *)
    CI = RECORD
        ch, attr: WCHAR
    END;

    Cur = RECORD                    (* CONSOLE_CURSOR_INFO: eight bytes *)
        size, sizeHi, visible, visHi: WCHAR
    END;

VAR
    h: INTEGER;                     (* the console as it was found *)
    buf: INTEGER;                   (* and the buffer this module made *)
    cols, rows: INTEGER;
    savedWin: WINAPI.TSmallRect;
    savedCur: Cur;                  (* the console's cursor, as it was found *)
    park: Cur;                      (* ours: the same shape, parked and hidden *)
    savedCP: INTEGER;
    touchedWin: BOOLEAN;            (* Open set the window, so Close must undo it *)
    info: WINAPI.TConsoleScreenBufferInfo;
    name: ARRAY 16 OF CHAR;
    opened: BOOLEAN;


PROCEDURE [windows-, KERNEL, ""] CreateConsoleScreenBuffer* (access, share, sa, flags, data: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] SetConsoleActiveScreenBuffer* (h: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] SetConsoleWindowInfo* (h, abs: INTEGER; r: WINAPI.TSmallRect): INTEGER;
PROCEDURE [windows-, KERNEL, ""] SetConsoleCursorPosition* (h, pos: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] GetConsoleCursorInfo* (h: INTEGER; c: Cur): INTEGER;
PROCEDURE [windows-, KERNEL, ""] SetConsoleCursorInfo* (h: INTEGER; c: Cur): INTEGER;
PROCEDURE [windows-, KERNEL, ""] GetConsoleOutputCP* (): INTEGER;
PROCEDURE [windows-, KERNEL, ""] SetConsoleOutputCP* (cp: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] WriteConsoleOutputW* (h, buf, bufSize, bufCoord: INTEGER; r: WINAPI.TSmallRect): INTEGER;
PROCEDURE [windows-, KERNEL, ""] ReadConsoleOutputW* (h, buf, bufSize, bufCoord: INTEGER; r: WINAPI.TSmallRect): INTEGER;


(* Tell the page layer what this host is, and it is the only place that knows.

   A Windows console takes code points, so nothing above is converted on the
   way out and Screen is Unicode - the true answer.  It is proposed rather
   than assigned, because it is also the setting that does nothing: Write
   hands the canvas over as it stands, a cell at a time, without asking any
   page, so a program that named another screen page here loses nothing it
   wanted.  What such a program does get is the text page, which is real - the
   bytes its own strings are made of become whatever page it named.

   That page is UTF-8 here, and it used to be 866.  The reason is where a
   non-ASCII byte string on this host comes from: not from the program, whose
   own strings are literals and are ASCII, but from Windows, and Windows
   answers a name in UTF-16 through the W entry point.  A file dialog's listing
   is the case that forced it - a Russian file name reached the dialog as bytes
   of the ANSI code page and was drawn as code page 866, which is a different
   letter for every byte above 7FH, and that is the garbage the reader saw.
   UTF-8 is what the platform layer turns those UTF-16 names into, so UTF-8 is
   what the text page is; Print in TuiCanv has the arm that reads it.

   Nothing moves for a string that is ASCII, and nothing in this repository is
   anything else: 20H..7EH is the same byte in 866, in 437 and in UTF-8.  A
   program that wants the old page still names it - TuiPage.SetText before the
   screen is opened, or DefaultText's caller's-choice rule - and a program that
   reads a code page file and draws it names that file's page, as HelpWin does.

   Out is NOT affected: it writes through the console's own OEM page and never
   asks this setting.  It is the canvas this is about. *)
PROCEDURE Setup*;
BEGIN
    TuiPage.DefaultScreen(Charset.PageUnicode);
    TuiPage.DefaultText(Charset.PageUtf8)
END Setup;


(* The console this process is attached to, if it has one.

   stdout is the handle to start from, and it is the right one when the program
   was started from a console.  It is not right when it was started with its
   output redirected - then stdout is a pipe, it belongs to no console, and
   asking it about a screen buffer fails - so the fallback opens CONOUT$, which
   is the console itself and always answers.  A process with no console at all
   is given one, because the alternative is a sample that draws nowhere. *)
PROCEDURE Attach (): BOOLEAN;
VAR ok: BOOLEAN;
BEGIN
    h := WINAPI.GetStdHandle(STD_OUTPUT_HANDLE);
    ok := WINAPI.GetConsoleScreenBufferInfo(h, info) # 0;
    IF ~ok THEN
        name := "CONOUT$";
        h := WINAPI.CreateFileA(SYSTEM.ADR(name), GENERIC_READ_WRITE, SHARE_RW,
                                NIL, OPEN_EXISTING, 0, 0);
        ok := WINAPI.GetConsoleScreenBufferInfo(h, info) # 0
    END;
    IF ~ok THEN
        ok := WINAPI.AllocConsole();
        IF ok THEN
            h := WINAPI.GetStdHandle(STD_OUTPUT_HANDLE);
            ok := WINAPI.GetConsoleScreenBufferInfo(h, info) # 0
        END
    END;
    RETURN ok
END Attach;


(* Take the screen: make a buffer of our own, put it on the screen, and leave
   the console's own buffer, window, cursor and code page remembered so Close
   can put all four back.

   A buffer of our own is what the DOS side has by construction - it owns video
   memory - and it is the reason the dump means the same thing on both targets:
   reading this buffer back gives the cells the interface put there and nothing
   else, where reading a shared console would give whatever the terminal
   hosting it had scrolled in. *)
PROCEDURE Open* (VAR c, r: INTEGER);
VAR res: INTEGER;
    want: WINAPI.TSmallRect;
    ok: BOOLEAN;
BEGIN
    IF ~opened THEN
        touchedWin := FALSE;
        ok := Attach();
        IF ok THEN
            savedWin := info.srWindow;
            ok := GetConsoleCursorInfo(h, savedCur) # 0
        END;
        IF ok THEN
            (* The window first.  A buffer is created the size of the window and
               cannot well be smaller than it, so asking the window for the size
               the application wants is what makes the application fill the
               screen.  The window cannot always take what it is asked for - a
               console may refuse to grow - and then it keeps its size and the
               application is told what that is. *)
            IF (c > 0) & (r > 0) THEN
                want.Left := WCHR(0); want.Top := WCHR(0);
                want.Right := WCHR(c - 1); want.Bottom := WCHR(r - 1);
                res := SetConsoleWindowInfo(h, 1, want);
                touchedWin := TRUE
            END;
            buf := CreateConsoleScreenBuffer(GENERIC_READ_WRITE, SHARE_RW, 0,
                                             TEXTMODE_BUFFER, 0);
            ok := buf # 0;
            IF ok THEN
                ok := SetConsoleActiveScreenBuffer(buf) # 0
            END;
            IF ok THEN
                ok := WINAPI.GetConsoleScreenBufferInfo(buf, info) # 0
            END
        END;
        IF ok THEN
            savedCP := GetConsoleOutputCP();
            cols := ORD(info.dwSize.X);
            rows := ORD(info.dwSize.Y);
            res := SetConsoleOutputCP(CP_OEM);
            (* the console's cursor parks in the last cell and goes invisible:
               the interface draws its own.

               The shape comes from savedCur and the hiding is done to a copy of
               it.  Writing the hidden flag into savedCur itself - which is what
               this did - destroys the only record of what the console's cursor
               looked like, and Close then put that record back: every run left
               the user's cursor invisible, for good, in a console the program
               had already given back.  The two records are separate because
               they belong to different owners: one is the console's and is only
               read, the other is this module's and is only written. *)
            park := savedCur;
            park.visible := WCHR(0);
            res := SetConsoleCursorPosition(buf, cols - 1 + (rows - 1) * 65536);
            res := SetConsoleCursorInfo(buf, park);
            opened := TRUE;
            c := cols;
            r := rows
        ELSE
            c := 0;
            r := 0
        END
    ELSE
        c := cols;
        r := rows
    END
END Open;


(* Give the console back: its own buffer on the screen again, then the window,
   the cursor and the code page it had.  The order matters - the window belongs
   to the console, not to the buffer, so it is put back after the buffer that
   was covering the screen has been taken away.

   The window goes back only if Open changed it.  A run that asked for a size
   moved the window and must move it back, or it leaves the console the shape it
   liked; a run that asked for nothing took the window as it found it, and
   putting savedWin back then would undo the resizing the user did while the
   program was up - the one thing this module must not do, since a console the
   user has just dragged to suit themselves is not the program's to restore. *)
PROCEDURE Close*;
VAR res: INTEGER;
BEGIN
    IF opened THEN
        res := SetConsoleActiveScreenBuffer(h);
        IF touchedWin THEN
            res := SetConsoleWindowInfo(h, 1, savedWin)
        END;
        res := SetConsoleCursorInfo(h, savedCur);
        res := SetConsoleOutputCP(savedCP);
        res := WINAPI.CloseHandle(buf);
        opened := FALSE;
        touchedWin := FALSE
    END
END Close;


(* n cells at (x, y), from the linear address adr.

   THE CONVERSION THAT USED TO BE HERE IS GONE, and this is the host it was
   worth removing it from.  A canvas cell is a 16-bit code point and a 16-bit
   attribute - four bytes - and that is exactly a Windows CHAR_INFO, so the
   screen this module writes is the canvas itself: no widening loop, no cell
   array, one WriteConsoleOutputW for a run.  It was WriteConsoleOutputA
   before, over a loop that widened each byte of the canvas into a WCHAR, and
   the console then turned the byte into the character again through its code
   page - the same picture arrived by two conversions instead of none.

   The console is asked for code points now, so the code page it is set to no
   longer decides what the screen shows.  It still decides what a *byte* the
   program hands to Out means, which is why Open still sets it.

   A run goes in chunks because the console takes a rectangle of a given size
   and a row can be wider than one call is worth; the source is the canvas row
   itself, offset by the cells already written, and its size is MAKELONG(chunk,
   1) - the low word the width and the high word the height, which is what the
   + 65536 spells. *)
PROCEDURE Write* (x, y, n, adr: INTEGER);
VAR chunk, off, res: INTEGER;
    rect: WINAPI.TSmallRect;
BEGIN
    IF opened & (n > 0) THEN
        off := 0;
        WHILE off < n DO
            chunk := n - off;
            IF chunk > MAXCHUNK THEN chunk := MAXCHUNK END;
            rect.Left := WCHR(x + off); rect.Top := WCHR(y);
            rect.Right := WCHR(x + off + chunk - 1); rect.Bottom := WCHR(y);
            res := WriteConsoleOutputW(buf, adr + off * 4, chunk + 65536, 0, rect);
            off := off + chunk
        END
    END
END Write;


(* A rectangle of cells into adr, whose rows are w cells wide and follow one
   another with no gap.  The screen's rows are cols wide, so a rectangle
   narrower than the screen is taken a row at a time.

   The cells come back four bytes wide and go into adr four, because adr holds
   the screen the way a canvas holds it now - a code point and an attribute,
   four bytes a cell - so the console writes straight into the row the caller
   handed it.  This is the reverse of what Write does and it is the same no-op:
   one ReadConsoleOutputW a chunk. *)
PROCEDURE Read* (x, y, w, h, adr: INTEGER);
VAR i, off, chunk, res: INTEGER;
    rect: WINAPI.TSmallRect;
BEGIN
    IF opened THEN
        FOR i := 0 TO h - 1 DO
            off := 0;
            WHILE off < w DO
                chunk := w - off;
                IF chunk > MAXCHUNK THEN chunk := MAXCHUNK END;
                rect.Left := WCHR(x + off); rect.Top := WCHR(y + i);
                rect.Right := WCHR(x + off + chunk - 1); rect.Bottom := WCHR(y + i);
                res := ReadConsoleOutputW(buf, adr + (i * w + off) * 4,
                                          chunk + 65536, 0, rect);
                off := off + chunk
            END
        END
    END
END Read;


(* What the screen is showing now, in cells: the window, and not the buffer.

   dwSize is the size of the buffer, which is what Open made and what the sample
   draws into; srWindow is the part of that buffer a frame can reach, and the
   difference of its two ends is what the user's window is.  They are the same
   number until the window is made smaller, and after that the buffer is the
   taller of the two by however much of it has been scrolled past - measured on
   a console whose window was 106 by 27 over a buffer of 106 by 36.

   It is asked for rather than remembered from the record that reported the
   change, because that record carries the buffer's size and the two are not the
   same number.  A record saying 106 by 36 arrived for the window above.

   Two IFs rather than one condition, so that nothing rests on a call inside a
   conjunction being evaluated at all. *)
PROCEDURE Size* (VAR c, r: INTEGER);
BEGIN
    IF opened THEN
        IF WINAPI.GetConsoleScreenBufferInfo(buf, info) # 0 THEN
            c := ORD(info.srWindow.Right) - ORD(info.srWindow.Left) + 1;
            r := ORD(info.srWindow.Bottom) - ORD(info.srWindow.Top) + 1
        ELSE
            c := cols;
            r := rows
        END
    ELSE
        c := 0;
        r := 0
    END
END Size;

$ELSE

(* No screen here.  Open answers a size of nothing, which is how TuiScr learns
   that it is not to open at all, Size answers the same nothing, and the other
   three do nothing: the framework compiles for every target and draws on the ones
   that have a screen.

   Setup leaves the page layer at its own default, which is 866 both ways.  A
   DLL has no console and no window, so there is no host to describe - and a
   library that is loaded into somebody else's process has no business
   announcing a screen it cannot draw on. *)

PROCEDURE Setup*;
BEGIN
END Setup;


PROCEDURE Open* (VAR c, r: INTEGER);
BEGIN
    c := 0;
    r := 0
END Open;


PROCEDURE Close*;
BEGIN
END Close;


PROCEDURE Size* (VAR c, r: INTEGER);
BEGIN
    c := 0;
    r := 0
END Size;


PROCEDURE Write* (x, y, n, adr: INTEGER);
BEGIN
END Write;


PROCEDURE Read* (x, y, w, h, adr: INTEGER);
BEGIN
END Read;

$END

END ArchTuiScr.
