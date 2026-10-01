MODULE ArchClip;

(*
   Public domain (The Unlicense)

   Copyright (c) 2026-, DosWorld
   All rights reserved.

   The system clipboard, as Windows has one.  The module a program imports is
   lib/common/Clipboard.mod, which forwards everything here: Available answers
   TRUE, so that module is this one and nothing else while the program runs, its
   own buffer is neither written nor read, and the four keys of the sample copy
   and paste through the clipboard the whole machine shares.

   A copy goes out as two formats and a paste comes in as whichever is there.

   CF_UNICODETEXT is the one that is written first and read first, because it
   is the one every modern program reads and because it carries every character
   there is.  Beside it goes CF_TEXT, which is ANSI by definition, for a
   program old enough to ask for that and nothing else: the same text through
   the system code page, so that a Cyrillic letter pastes into such a program
   as that letter and not as the bytes of its UTF-8 encoding.  A character the
   code page does not have is lost in the ANSI block alone, and stays whole in
   the Unicode one.

   The bytes the framework hands over are UTF-8 - that is what microui's
   buffers are, what its renderer's font is indexed by, and what
   lib/common/Input.mod produces from a keystroke - so the conversion to UTF-16
   is lib/common/Strings.mod's, which is portable and knows the whole encoding,
   including the four-byte sequences and the surrogate pairs they become.  The
   conversion to ANSI is Windows', because a code page is Windows' to know.

   CF_TEXT is read through the system code page and only then decoded, so a
   clipboard written by an old program arrives as the text that program meant
   rather than as one byte per letter.  A byte the code page does not define
   becomes the code page's stand-in, which is what Windows does with it
   everywhere else.

   A clipboard handle is memory: allocated movable, filled through a lock, and
   then handed to the system, which owns it from that moment - so a handle that
   went is never freed and never touched again, and one that did not go is ours
   and is freed.  What comes back is the system's as well and is not freed
   either.

   Every call is checked.  Another program holding the clipboard makes
   OpenClipboard answer 0, and text that never went would otherwise be reported
   as gone out.  A refusal is asked again for a bounded while rather than
   believed the first time: the clipboard is the machine's and not this
   process', so a holder that is in the middle of its own copy is a normal
   thing to meet and not a failure - see CLIPTRY, and Get below. *)

IMPORT Strings, SYSTEM;

CONST
    CF_TEXT         = 1;
    CF_UNICODETEXT  = 13;
    GMEM_MOVEABLE   = 2;

    (* CP_ACP: the system ANSI code page, which is what CF_TEXT means.  The
       same number lib/Windows/ArchInput.mod uses to ask about a byte. *)
    CP_ACP = 0;

    (* Code units a copy can carry.  A clip buffer of 256 UTF-8 bytes decodes
       to at most 256 code units - one byte is never fewer than one - so this
       is twice what the largest copy can need, and a paste that finds more on
       the clipboard than this stops here rather than overruns. *)
    WideMax = 512;

    (* Times Get asks for the clipboard before it believes a refusal.  A
       millisecond apart, so this is a fifth of a second: longer than any
       well-behaved holder keeps it, and short enough that a real failure is
       not felt as a hang.  Measured against the sample's own script, which
       pastes a moment after it copied and lost the text in five runs of six
       before this existed. *)
    CLIPTRY = 200;

    (* The byte buffer a CF_TEXT paste is read through before it is decoded.
       One byte per character of the same text, plus room for the terminator
       the loop writes. *)
    AnsiMax = 1024;

    (* The DLL names are ordinary constants here, not keywords: a pragma's
       second field is a constant expression, and the compiler uppercases what
       it finds.  These are the spellings lib/Windows/API.mod uses, and the
       same pair ArchTuiScr declares for its own body. *)
    KERNEL = "kernel32.dll";
    USER   = "user32.dll";


PROCEDURE [windows-, USER, ""] OpenClipboard (hWnd: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] CloseClipboard (): INTEGER;
PROCEDURE [windows-, USER, ""] EmptyClipboard (): INTEGER;
PROCEDURE [windows-, USER, ""] SetClipboardData (fmt, hMem: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] GetClipboardData (fmt: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] GlobalAlloc (flags, bytes: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] Sleep (ms: INTEGER);
PROCEDURE [windows-, KERNEL, ""] GlobalLock (hMem: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] GlobalUnlock (hMem: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] GlobalSize (hMem: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] GlobalFree (hMem: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] WideCharToMultiByte (cp, flags, srcAdr, srcLen,
                                                      dstAdr, dstLen, defAdr,
                                                      usedAdr: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] MultiByteToWideChar (cp, flags, srcAdr, srcLen,
                                                      dstAdr, dstLen: INTEGER): INTEGER;


PROCEDURE Available* (): BOOLEAN;
BEGIN
    RETURN TRUE
END Available;


(* len bytes from srcAdr into the clipboard as fmt, and the handle with them.

   The clipboard has to be open and already emptied, which the caller does once
   for both formats.  A handle the system took is the system's and is not
   touched again; one it refused is still ours and is freed here rather than
   leaked.  len counts the terminator: the text that leaves is always a
   terminated block, which is what every reader of these two formats expects. *)
PROCEDURE Offer (fmt, srcAdr, len: INTEGER): BOOLEAN;
VAR
    h, p: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    h := GlobalAlloc(GMEM_MOVEABLE, len);
    IF h # 0 THEN
        p := GlobalLock(h);
        IF p # 0 THEN
            SYSTEM.MOVE(srcAdr, p, len);
            GlobalUnlock(h);
            IF SetClipboardData(fmt, h) # 0 THEN
                ok := TRUE
            ELSE
                GlobalFree(h)               (* it stayed ours, so give it back *)
            END
        ELSE
            GlobalFree(h)                   (* it can never be filled *)
        END
    END;

    RETURN ok
END Offer;


(* s into the clipboard, as CF_UNICODETEXT and as CF_TEXT.  Answers whether any
   of it went: one format landing is a copy the user can paste somewhere. *)
PROCEDURE Put* (s: ARRAY OF CHAR): BOOLEAN;
VAR
    wn, an: INTEGER;
    w: ARRAY WideMax OF WCHAR;
    a: ARRAY AnsiMax OF CHAR;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    wn := Strings.Utf8To16(s, w);
    IF wn > 0 THEN
        w[wn] := WCHR(0);
        IF OpenClipboard(0) # 0 THEN
            EmptyClipboard();

            (* First, because a clipboard holding Unicode is read by a modern
               program without a code page in between. *)
            ok := Offer(CF_UNICODETEXT, SYSTEM.ADR(w[0]), (wn + 1) * 2);

            (* Then the ANSI block beside it.  The count answered is the bytes
               written and does not include a terminator, so one is added here;
               the destination is one shorter than the buffer so that room for
               it is always there. *)
            an := WideCharToMultiByte(CP_ACP, 0, SYSTEM.ADR(w[0]), wn,
                                      SYSTEM.ADR(a[0]), AnsiMax - 1, 0, 0);
            IF an > 0 THEN
                a[an] := 0X;
                IF Offer(CF_TEXT, SYSTEM.ADR(a[0]), an + 1) THEN
                    ok := TRUE
                END
            END;

            CloseClipboard()
        END
    END;

    RETURN ok
END Put;


(* The clipboard's text into s.  The Unicode block is taken when it is there,
   and the ANSI one is decoded from the system code page when it is not; s is
   filled with UTF-8 either way, and the loop is bounded by s, so a host that
   answered a nonsense size cannot write past the buffer.  Answers whether
   there was any text to take. *)
PROCEDURE Get* (VAR s: ARRAY OF CHAR): BOOLEAN;
VAR
    h, p, n, i, wn, spin: INTEGER;
    w: ARRAY WideMax OF WCHAR;
    a: ARRAY AnsiMax OF CHAR;
    ok, done, opened: BOOLEAN;

BEGIN
    ok := FALSE;
    s[0] := 0X;
    (* Asked again rather than once, because a refusal here is usually
       somebody else's copy in flight and not a clipboard this program cannot
       have: OpenClipboard answers 0 while another process holds it.  One
       paste comes a moment after one copy in the sample's own script, and
       that is exactly the window in which the other half of this module still
       has it. *)
    spin := 0;
    opened := OpenClipboard(0) # 0;
    WHILE ~opened & (spin < CLIPTRY) DO
        INC(spin); Sleep(1);
        opened := OpenClipboard(0) # 0
    END;
    IF opened THEN
        wn := 0;

        h := GetClipboardData(CF_UNICODETEXT);
        IF h # 0 THEN
            n := GlobalSize(h) DIV 2;       (* code units, where the size is bytes *)
            p := GlobalLock(h);
            IF p # 0 THEN
                i := 0; done := FALSE;
                WHILE (i < n) & (i < WideMax - 1) & ~done DO
                    SYSTEM.GET(p + i * 2, w[i]);
                    IF w[i] = WCHR(0) THEN
                        done := TRUE
                    ELSE
                        INC(i)
                    END
                END;
                wn := i;
                GlobalUnlock(h)
            END

        ELSE
            h := GetClipboardData(CF_TEXT);
            IF h # 0 THEN
                n := GlobalSize(h);
                p := GlobalLock(h);
                IF p # 0 THEN
                    i := 0; done := FALSE;
                    WHILE (i < n) & (i < AnsiMax - 1) & ~done DO
                        SYSTEM.GET(p + i, a[i]);
                        IF a[i] = 0X THEN
                            done := TRUE
                        ELSE
                            INC(i)
                        END
                    END;
                    a[i] := 0X;
                    GlobalUnlock(h);
                    IF i > 0 THEN
                        wn := MultiByteToWideChar(CP_ACP, 0, SYSTEM.ADR(a[0]), i,
                                                  SYSTEM.ADR(w[0]), WideMax - 1);
                        IF wn < 0 THEN wn := 0 END
                    END
                END
            END
        END;

        IF wn > 0 THEN
            w[wn] := WCHR(0);
            ok := Strings.Utf16To8(w, s) > 0
        END;

        CloseClipboard()
    END;

    RETURN ok
END Get;


END ArchClip.
