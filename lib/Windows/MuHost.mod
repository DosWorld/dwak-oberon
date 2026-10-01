(* MuHost - the microui port's window, on Windows.

   A port of rxi's microui 2.02 (https://github.com/rxi/microui, MIT licence)
   to Oberon-07.  This is the one module of the port that names an operating
   system.  Everything above it is portable: MuBase, MuAtlas, Microui and
   MuRender know nothing about a window, and this module is what turns a window
   into the callbacks and the input calls those four want.  A port to another
   system writes another MuHost and changes nothing else - lib/Linux and
   lib/dpmi32 will each have their own.

   What it does, in the order the reference demo does it: register a window
   class, put up a window, hand each of its messages to the shared input layer,
   and, once per pass of the loop, let the application build a frame, draw it
   with MuRender and blit the framebuffer into the client area.

   The input is not read here.  lib/common/Events.mod is the tree's one
   vocabulary of input and lib/common/Input.mod is the one way in; this module
   is a window, so it reads that way in - Input.FromMessage for each message the
   window procedure is sent - and lib/common/MuInput.mod is what turns an event
   into the library's own calls.  Neither of the two knows what a device is, and
   between them they hold the three things this host used to do for itself:
   which scancode is which key, how many bytes a typed character occupies, and
   how a button message differs from the press it means.  A second host writes
   none of that again, and that is the point of its being shared with the
   console toolkit rather than copied.

   The Win32 declarations live here rather than in WINAPI.  WINAPI is the
   runtime's binding to the calls the runtime itself makes - the console, the
   files, the clock - and it has no window API in it at all.  A host is a
   self-contained thing by design, so that reading this one file says what a
   Windows host needs and nothing else; the X11 and DOS hosts will read the
   same way.

   Windows 95.  Every call here is in Win32 as it stood in 1995: the ANSI
   window calls, StretchDIBits with a 32-bit BI_RGB DIB, no layered windows, no
   DWM, no SetWindowLongPtr.  The library's own state lives in module variables
   for the same reason, so that no per-window pointer has to be hidden in the
   window's extra bytes.  DPI awareness is deliberately not asked for: the call
   that asks is newer than the systems this port set out to run on, and a
   window scaled by the system is a blurred window rather than a broken one.

   The font.  A glyph is rasterised by GDI, on demand, the first time its
   character is drawn, and handed to Font as a cell of coverage.  That is
   what makes text here Unicode rather than 96 characters wide: a face is asked
   for the code point, and what it answers is what is drawn - so the coverage
   is the face's, not a table's.  F2 and F3 step through the list of fonts the
   application offered, which is how the size is chosen without rebuilding the
   program, and `gdi:<face>:<height>` is the specification that list is made of.

   There is a second provider, and it is not Windows at all.  `file:<path>`
   hands the font to FontFile, which is portable lib/common code reading a
   bitmap font out of a file - BDF, PCF, Unifont HEX, PSF1 or PSF2.  So a
   program that wants a particular face at a particular size, or wants one at
   all without Windows being asked, can name a file instead of an installed
   face.  The hook is the same one GDI is behind: a procedure that fills a cell
   of coverage for a code point, which is all Font ever sees.  This is the
   shape the X11 and DOS hosts will use, and on those systems it is the only
   provider there is.

   The third provider is not a file and not a device.  `builtin:` is the font
   compiled into the program - lib/common/FontBuiltin.mod, which imports one
   of the generated FontI8x*.mod and hands its tables to
   FontFile.FromTable - and `auto:` is that same font unless there is a
   `font.pcf` in the directory this image was loaded from, in which case it is
   that file.  A program that names nothing gets `auto:`, so dropping a font
   file next to the .exe under that name is the whole of how a custom font is
   installed, and a font.pcf that cannot be read leaves the compiled-in font in
   place rather than a window with nothing in it.  Both resolve to a store and
   a paint procedure, which is all Font and MuRender ever see, so this is
   also what will give the X11 and DOS hosts a font on the day their window
   opens - before either of them has any font code at all.
*)
MODULE MuHost;

IMPORT SYSTEM, MuBase, Microui, Font, MuRender, FontFile,
       FontBuiltin, Input, Clipboard, Events, MuInput, MuTheme;


CONST
    (* class styles *)
    CS_VREDRAW = 1;
    CS_HREDRAW = 2;

    (* window styles.  WS_OVERLAPPEDWINDOW spelled out, because 00CF0000H as
       one literal is a positive number here and a negative one in C, and there
       is no reason to make a reader work that out. *)
    WS_CAPTION     = 00C00000H;
    WS_SYSMENU     =   80000H;
    WS_THICKFRAME  =   40000H;
    WS_MINIMIZEBOX =   20000H;
    WS_MAXIMIZEBOX =   10000H;
    WS_OVERLAPPEDWINDOW = WS_CAPTION + WS_SYSMENU + WS_THICKFRAME +
                          WS_MINIMIZEBOX + WS_MAXIMIZEBOX;

    SW_SHOW = 5;
    IDC_ARROW = 32512;

    (* messages.  The five this host acts on itself, and the two the input layer
       reads but can have nothing to say about - a wheel that did not reach a
       notch and a character that is not text.  The mouse, the keys and the
       wheel's own constant are not here: Events names them once for every host
       and Windows' numbers for them live there, with the rest of the reading. *)
    WM_DESTROY     =    2H;
    WM_SIZE        =    5H;
    WM_CLOSE       =   10H;
    WM_PAINT       =   0FH;
    WM_ERASEBKGND  =   14H;
    WM_CHAR        =  102H;
    WM_MOUSEWHEEL  =  20AH;

    (* There is no table of virtual keys here any more, and that is the point of
       the shared layer.  A virtual key is the key's name on the current layout,
       which is not what a program can match on: two layouts put two different
       keys in one place, and the scancode is the same key on every layout there
       is.  So the layer reads bits 16 to 23 of lParam - the scancode - and
       lib/common/MuInput.mod turns it into a microui key bit, once, for every
       host there is.  It lives there and not here because a console host and an
       X11 host would otherwise each write the same table and then disagree
       about it. *)

    (* GDI, for the font.  GGO_BITMAP is 1: GGO_NATIVE is 2 and answers the
       unhinted outline in GDI's own format, which is not a bitmap at all. *)
    GGO_BITMAP         = 1;
    ANSI_CHARSET       = 0;
    OUT_DEFAULT_PRECIS = 0;
    CLIP_DEFAULT_PRECIS = 0;
    DEFAULT_QUALITY    = 0;
    FF_MODERN          = 48;
    DEFAULT_PITCH      = 0;
    FW_NORMAL          = 400;
    GDI_ERROR          = 0FFFFFFFFH;

    (* How large a glyph may be before the host gives up on it.  The buffer is
       a module variable rather than an allocation because a glyph is small and
       is rasterised once: the largest cell the image budget can hold is a few
       hundred bytes of packed bits, so this is room to spare. *)
    GlyphBufSize = 4096;

    (* The fonts an application may offer.  A specification is at most 127
       characters.  That was 63 while a specification could only be a face name
       and a height; it is a file path now as well, and a path worth naming
       (`C:\Program Files\fonts\ttyp0-8x16.bdf`) does not fit in 63. *)
    MaxFonts = 16;
    MaxSpec  = 128;

    PM_REMOVE      = 1;
    DIB_RGB_COLORS = 0;
    BI_RGB         = 0;
    SRCCOPY        = 00CC0020H;

    (* The system ANSI code page.  CP_ACP is zero in the Win32 headers and is
       not itself a code page number: it means "whichever one this machine is
       set to".  It is the page the host's own strings are widened through on
       the way to the Unicode window - and the page an ANSI window's WM_CHAR
       arrives in, which is no longer this module's business: the character a
       message carries is read in lib/Windows/ArchInput.mod, which knows the
       same flag this one hands it. *)
    CP_ACP = 0;

    (* UTF-16 surrogates were spelled out here while the host decoded typed
       characters itself.  It no longer does - a WM_CHAR goes to the input layer
       whole, and the layer is where a code point above the BMP is put back
       together out of the two messages it arrives in. *)

    (* One notch of a wheel is 120 and the reference demo scrolls 30 a notch,
       away from the user being upwards.  Both numbers are the input layer's
       now, for the same reason: a wheel message is read there, and the two
       constants convert it once for every host rather than once per host. *)

    USER   = "user32.dll";
    GDI    = "gdi32.dll";
    KERNEL = "kernel32.dll";


TYPE
    (* A window procedure.  It carries the Win32 convention, which is what
       makes the address Windows is handed a callable one: [windows-] is
       stdcall on the 32-bit targets and the single Win64 convention on the
       64-bit one, exactly as the imported calls below are. *)
    WNDPROC = PROCEDURE [windows-] (hwnd, msg, wParam, lParam: INTEGER): INTEGER;

    (* The Windows structures a window needs.  Their fields are the C ones: a
       DWORD is SYSTEM.CARD32 and a handle or a pointer is INTEGER, which is 4
       bytes on a 32-bit target and 8 on a 64-bit one.  The layout then matches
       the C layout on both, because a field is aligned to its own size.
       Measured, not assumed.

       A CARD32 is given a value with SYSTEM.PUT32 and read with SYSTEM.GET32.
       This compiler will not assign between CARD32 and INTEGER in either
       direction, which is the point of the type: a Windows DWORD is unsigned
       and 32 bits wide on every target, and an INTEGER here is neither. *)
    POINT = RECORD
        x, y: SYSTEM.CARD32
    END;

    RECT = RECORD
        left, top, right, bottom: SYSTEM.CARD32
    END;

    MSG = RECORD
        hwnd:    INTEGER;
        message: SYSTEM.CARD32;
        wParam:  INTEGER;
        lParam:  INTEGER;
        time:    SYSTEM.CARD32;
        pt:      POINT
    END;

    PAINTSTRUCT = RECORD
        hdc:         INTEGER;
        fErase:      SYSTEM.CARD32;
        rcPaint:     RECT;
        fRestore:    SYSTEM.CARD32;
        fIncUpdate:  SYSTEM.CARD32;
        rgbReserved: ARRAY 32 OF BYTE
    END;

    WNDCLASSA = RECORD
        style:         SYSTEM.CARD32;
        lpfnWndProc:   WNDPROC;
        cbClsExtra:    SYSTEM.CARD32;
        cbWndExtra:    SYSTEM.CARD32;
        hInstance:     INTEGER;
        hIcon:         INTEGER;
        hCursor:       INTEGER;
        hbrBackground: INTEGER;
        lpszMenuName:  INTEGER;
        lpszClassName: INTEGER
    END;

    BITMAPINFOHEADER = RECORD
        biSize:          SYSTEM.CARD32;
        biWidth:         SYSTEM.CARD32;
        biHeight:        SYSTEM.CARD32;
        biPlanes:        WCHAR;
        biBitCount:      WCHAR;
        biCompression:   SYSTEM.CARD32;
        biSizeImage:     SYSTEM.CARD32;
        biXPelsPerMeter: SYSTEM.CARD32;
        biYPelsPerMeter: SYSTEM.CARD32;
        biClrUsed:       SYSTEM.CARD32;
        biClrImportant:  SYSTEM.CARD32
    END;

    (* What StretchDIBits is told the pixels are.  BI_RGB with 32 bits means
       one 0x00RRGGBB word a pixel in the framebuffer's own order; the top byte
       of each word is ignored. *)
    BITMAPINFO = RECORD
        bmiHeader: BITMAPINFOHEADER;
        bmiColors: SYSTEM.CARD32
    END;

    (* What GDI says about a face, in the order the C structure has it.  Only
       the leading LONGs are read: the height of a line, where the baseline
       sits in it, and how wide one character of a monospaced face is.  The
       nine bytes that follow describe the character set and are not used, so
       the trailing padding after them does not matter. *)
    TEXTMETRICA = RECORD
        tmHeight, tmAscent, tmDescent, tmInternalLeading, tmExternalLeading,
        tmAveCharWidth, tmMaxCharWidth, tmWeight, tmOverhang,
        tmDigitizedAspectX, tmDigitizedAspectY: SYSTEM.CARD32;
        tmFirstChar, tmLastChar, tmDefaultChar, tmBreakChar,
        tmItalic, tmUnderlined, tmStruckOut, tmPitchAndFamily,
        tmCharSet: BYTE
    END;

    (* What GDI says about one glyph: the size of its ink, where that ink sits
       relative to the pen - `origin` is the top left of the ink, y measured
       upwards from the baseline - and how far the pen moves.  POINT is two
       LONGs, so the origin is 4 bytes on both targets and is read through
       Short rather than as an INTEGER, which is eight bytes on the 64-bit
       target.  It is also signed, and a glyph's ink can start left of the pen
       - `j` does - so reading it unsigned would put that ink tens of thousands
       of pixels to the right and clip it away. *)
    GLYPHMETRICS = RECORD
        gmBlackBoxX, gmBlackBoxY: SYSTEM.CARD32;
        gmOriginX, gmOriginY:     SYSTEM.CARD32;
        gmCellIncX, gmCellIncY:   WCHAR
    END;

    (* The transform handed to GetGlyphOutlineW.  Four FIXEDs - a WORD of
       fraction then a short of value, so 1.0 in little-endian bytes is
       00 00 01 00 - and the identity is the only one this host asks for, since
       the rasterising is GDI's to do rather than a transform's. *)
    MAT2 = RECORD
        eM11, eM12, eM21, eM22: SYSTEM.CARD32
    END;

    (* What the application is asked to build, once per pass of the loop.  It
       does what main.c's process_frame does: mu_begin, the windows, mu_end. *)
    FrameProc* = PROCEDURE (ctx: Microui.Context);


(* The declarations of the Win32 calls, then this module's own variables.  The
   order is the language's: a VAR section comes before the procedure
   declarations, and an imported call is a procedure declaration. *)
VAR
    (* The context every message is fed to, and the window it belongs to. *)
    ctx*: Microui.Context;
    hwnd*: INTEGER;
    quit: BOOLEAN;

    (* The application's frame procedure, which Run was given and which
       WM_PAINT has to be able to call: a window that is being resized is
       resized inside Windows' own modal loop, where this module's loop is
       parked inside Dispatch and cannot draw a frame of its own. *)
    frameProc: FrameProc;

    (* TRUE once the framebuffer has been resized and before the frame in it
       has been built again, so the next WM_PAINT builds a frame rather than
       blitting a picture that no longer fits the window. *)
    needFrame: BOOLEAN;

    (* The colour the framebuffer is cleared to before the command list is
       drawn on it: the desktop the windows sit on.  microui has no colour for
       it - it belongs to the host - so it starts as Run's `bg` argument and an
       application is free to assign to it from inside its frame procedure.
       The clear happens after that procedure returns, so a change made there
       shows in the same frame. *)
    backdrop*: MuBase.Color;

    (* The class name and the caption.  Windows keeps the pointer it is given
       to each for the life of the window, so neither can be a string literal
       in read-only memory: they are variables here. *)
    className: ARRAY 32 OF CHAR;
    caption: ARRAY 128 OF CHAR;

    (* The same two strings again as UTF-16, for the Unicode window: Windows
       takes the class name and the caption as wide strings in the W calls and
       as bytes in the A ones, and a window needs one pair or the other.  Both
       are built every time and only one is used, because which one that is
       cannot be known until the Unicode window has been tried. *)
    classNameW: ARRAY 32 OF WCHAR;
    captionW: ARRAY 128 OF WCHAR;

    (* Whether this run has a Unicode window.  This one flag decides all of it,
       and it is set in Open before a message can arrive: which default
       procedure an unhandled message goes to, which pair of calls pumps the
       queue, and - through Input.WideChars, which is told once, where the class
       is registered - how a typed character is read: one UTF-16 code unit if it
       is set, one byte of the system code page if it is not.  Which of the two
       a message holds cannot be read out of the message, so it is the one fact
       about the window the input layer has to be given. *)
    wide: BOOLEAN;

    bmi: BITMAPINFO;

    (* The fonts the application offered, and which one is in use.  curFont is
       -1 when there is none, which is the state the port was in before any of
       this existed: the generated atlas alone. *)
    fonts: ARRAY MaxFonts OF ARRAY MaxSpec OF CHAR;
    nFonts: INTEGER;
    curFont: INTEGER;

    (* Where the glyphs of the font in use actually came from, said in words:
       an installed face, the path a `file:` entry named, `font.pcf`, or the
       font compiled into the program and its own face name.

       FontName answers the specification and this answers the outcome, and
       they differ exactly where it matters: an `auto:` entry is answered
       `auto:` by FontName whether or not there was a font.pcf beside the .exe,
       and only this says which of the two was taken.  Nothing draws with it -
       it is for a program that wants to show, or a person who wants to know,
       what a program started with. *)
    fontSource: ARRAY 48 OF CHAR;

    (* Bumped every time a font is taken into use.  Switching is the host's own
       business - F2 and F3 are handled inside the message loop and never reach
       the application - so this and FontName are the only way a program learns
       that the text it is about to draw changed size underneath it.  A program
       that wants to show which font is in use remembers the value it last saw
       and compares. *)
    fontSerial*: INTEGER;

    (* The device context a glyph is rasterised through, the font selected into
       it, and the original object, which is the DC's own one-pixel bitmap and
       is not ours to delete. *)
    fontDC: INTEGER;
    fontHandle: INTEGER;
    fontOld: INTEGER;

    (* The cell the current font draws in, and where its baseline sits in a
       cell: the numbers the apportioning of a glyph needs.  Both providers
       answer these, and the rest of the host does not care which one did. *)
    fontCellW: INTEGER;
    fontCellH: INTEGER;
    fontAscent: INTEGER;

    (* The glyph store of a `file:` font, NIL while a `gdi:` one is in use.
       It is the context PaintGlyph and PaintFile are handed and the thing that
       has to be given back when the font goes away; Select drops whatever is
       here before it builds anything, so a switch from a file to a face - or
       from one file to another - frees the old store rather than leaving it. *)
    fontStore: FontFile.Store;

    tm: TEXTMETRICA;
    gm: GLYPHMETRICS;
    mat: MAT2;
    glyphBuf: ARRAY GlyphBufSize OF BYTE;


(* Every call that writes through a pointer takes the pointer as an INTEGER and
   is handed SYSTEM.ADR(...), rather than being declared with a VAR parameter.

   This is not a matter of taste.  A VAR parameter on a procedure imported from
   a DLL is mis-passed by this compiler - measured on the 32-bit target, where
   the callee received something that was not the record's address and faulted
   on the first field it followed.  It goes unnoticed in the rest of the tree
   because no other DLL import there has one: the runtime's VAR-parameter
   imports are all [stdcall]/[oberon] procedures written in Oberon, where the
   parameter works as it should.  A pointer spelled out as an address is what
   the C prototype says anyway, and it is right on both widths. *)
PROCEDURE [windows-, USER, ""] RegisterClassA (wcadr: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] CreateWindowExA (dwExStyle, lpClassName, lpWindowName, dwStyle, X, Y, nWidth, nHeight, hWndParent, hMenu, hInstance, lpParam: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] DefWindowProcA (hwnd, msg, wParam, lParam: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] PeekMessageA (madr, hwnd, filterMin, filterMax, remove: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] TranslateMessage (madr: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] DispatchMessageA (madr: INTEGER): INTEGER;

(* The same calls in their Unicode form: the class registration, the window
   creation, the default procedure and the two halves of the pump.

   A window belongs to one world or the other, and it is the registration that
   decides which: a class registered with RegisterClassW makes every window of
   it a Unicode window, and a Unicode window is handed UTF-16.  The messages
   are the same messages and the procedure is the same procedure either way -
   what changes is that one field of WM_CHAR carries a code unit instead of a
   byte of the system code page.

   Which set is used is settled once, in Open, by whether the Unicode window
   could be created at all, and nothing else in the host asks.  Windows 95 has
   no Unicode window manager and answers 0, which is what the ANSI window
   underneath it is for.

   Both sets are imported by name and neither is resolved lazily: a procedure
   that is never called still has to be in the DLL for the image to load.
   That is the one assumption this rests on, and it is the assumption
   GetGlyphOutlineW already rests on - see the note on the GDI provider in
   doc/microui-port.md. *)
PROCEDURE [windows-, USER, ""] RegisterClassW (wcadr: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] CreateWindowExW (dwExStyle, lpClassName, lpWindowName, dwStyle, X, Y, nWidth, nHeight, hWndParent, hMenu, hInstance, lpParam: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] DefWindowProcW (hwnd, msg, wParam, lParam: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] PeekMessageW (madr, hwnd, filterMin, filterMax, remove: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] DispatchMessageW (madr: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] PostQuitMessage (code: INTEGER);
PROCEDURE [windows-, USER, ""] ShowWindow (hwnd, cmd: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] UpdateWindow (hwnd: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] InvalidateRect (hwnd, lpRect, erase: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] BeginPaint (hwnd, psadr: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] EndPaint (hwnd, psadr: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] GetDC (hwnd: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] ReleaseDC (hwnd, hdc: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] AdjustWindowRect (radr, style, menu: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] LoadCursorA (hInstance, name: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] DestroyWindow (hwnd: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] UnregisterClassA (name, hInstance: INTEGER): INTEGER;
PROCEDURE [windows-, USER, ""] WaitMessage (): INTEGER;

PROCEDURE [windows-, GDI, ""] StretchDIBits (hdc, xDest, yDest, wDest, hDest, xSrc, ySrc, wSrc, hSrc, bits, lpbmi, usage, rop: INTEGER): INTEGER;
PROCEDURE [windows-, GDI, ""] CreateCompatibleDC (hdc: INTEGER): INTEGER;
PROCEDURE [windows-, GDI, ""] CreateFontA (h, w, esc, orient, weight, italic, underline, strikeout, charset, outprec, clipprec, quality, pitchfam, face: INTEGER): INTEGER;
PROCEDURE [windows-, GDI, ""] SelectObject (hdc, obj: INTEGER): INTEGER;
PROCEDURE [windows-, GDI, ""] DeleteObject (obj: INTEGER): INTEGER;
PROCEDURE [windows-, GDI, ""] DeleteDC (hdc: INTEGER): INTEGER;
PROCEDURE [windows-, GDI, ""] GetTextMetricsA (hdc, tmadr: INTEGER): INTEGER;
PROCEDURE [windows-, GDI, ""] GetGlyphOutlineW (hdc, ch, fmt, gmadr, cjbuf, bufadr, matadr: INTEGER): INTEGER;
PROCEDURE [windows-, GDI, ""] GetGlyphOutlineA (hdc, ch, fmt, gmadr, cjbuf, bufadr, matadr: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GetModuleHandleA (name: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] GetModuleFileNameA (hModule, lpFilename, nSize: INTEGER): INTEGER;
PROCEDURE [windows-, KERNEL, ""] MultiByteToWideChar (cp, flags, srcAdr, srcLen, dstAdr, dstLen: INTEGER): INTEGER;


(*============================================================================
   the framebuffer on the screen
   ==========================================================================*)

PROCEDURE SetUpDIB (w, h: INTEGER);
BEGIN
    SYSTEM.PUT32(SYSTEM.ADR(bmi.bmiHeader.biSize), SYSTEM.SIZE(BITMAPINFOHEADER));
    SYSTEM.PUT32(SYSTEM.ADR(bmi.bmiHeader.biWidth), w);
    (* Negative, so that the first row of the framebuffer is the top row of
       the window rather than the bottom one. *)
    SYSTEM.PUT32(SYSTEM.ADR(bmi.bmiHeader.biHeight), -h);
    SYSTEM.PUT16(SYSTEM.ADR(bmi.bmiHeader.biPlanes), 1);
    SYSTEM.PUT16(SYSTEM.ADR(bmi.bmiHeader.biBitCount), 32);
    SYSTEM.PUT32(SYSTEM.ADR(bmi.bmiHeader.biCompression), BI_RGB);
    SYSTEM.PUT32(SYSTEM.ADR(bmi.bmiHeader.biSizeImage), 0);
    SYSTEM.PUT32(SYSTEM.ADR(bmi.bmiHeader.biXPelsPerMeter), 0);
    SYSTEM.PUT32(SYSTEM.ADR(bmi.bmiHeader.biYPelsPerMeter), 0);
    SYSTEM.PUT32(SYSTEM.ADR(bmi.bmiHeader.biClrUsed), 0);
    SYSTEM.PUT32(SYSTEM.ADR(bmi.bmiHeader.biClrImportant), 0)
END SetUpDIB;


(* Blit - the framebuffer onto a device context, at its own size.  The header
   is rewritten each time because the source rectangle of a DIB is measured
   against the width in the header, and a resized window has a different one. *)
PROCEDURE Blit (hdc: INTEGER);
VAR
    n: INTEGER;

BEGIN
    SetUpDIB(MuRender.Width, MuRender.Height);
    n := StretchDIBits(hdc, 0, 0, MuRender.Width, MuRender.Height,
                       0, 0, MuRender.Width, MuRender.Height,
                       MuRender.Address(), SYSTEM.ADR(bmi),
                       DIB_RGB_COLORS, SRCCOPY)
END Blit;


(* Present - Blit through the window's own device context, which is what the
   loop uses once a frame has been built. *)
PROCEDURE Present (wnd: INTEGER);
VAR
    hdc, n: INTEGER;

BEGIN
    hdc := GetDC(wnd);
    IF hdc # 0 THEN
        Blit(hdc);
        n := ReleaseDC(wnd, hdc)
    END
END Present;


(* BuildFrame - one whole frame: the application's procedure, which fills the
   command list, then that list drawn onto a cleared framebuffer.  The order of
   the three calls is the whole of it - the list is built first, the clear wipes
   what the last frame left, and only then are the commands drawn on top of the
   backdrop - and it is written here once because there are two callers now:
   the run loop, for every frame it draws, and WM_PAINT, for the first frame
   after the framebuffer has been resized.

   The clipboard is carried across the frame here, and this is the only place
   in the host that knows microui has one at all.  The library fills its mirror
   and reports what the frame did with it; the platform call is the host's,
   because a clipboard is a service and lib/common is not allowed to know one.
   A frame therefore hands the library the clipboard as it stands and, when the
   frame says it produced something, puts what it produced back where the next
   frame - of this program or of any other - will find it. *)
PROCEDURE BuildFrame;
BEGIN
    needFrame := FALSE;
    Clipboard.Get(ctx.clip);
    frameProc(ctx);
    IF ctx.clipReq # Microui.ClipNone THEN
        Clipboard.Put(ctx.clip);
        ctx.clipReq := Microui.ClipNone
    END;
    MuRender.Clear(backdrop);
    MuRender.ProcessCommands(ctx)
END BuildFrame;


(*============================================================================
   the window procedure
   ==========================================================================*)

(* LoWord and HiWord - the two halves of an lParam, as C sees them.  A window
   wider than 32767 pixels is not a case worth handling, but a negative
   coordinate is, so both sign-extend. *)
PROCEDURE LoWord (v: INTEGER): INTEGER;
VAR
    r: INTEGER;

BEGIN
    r := v MOD 10000H;
    IF r >= 8000H THEN r := r - 10000H END;

    RETURN r
END LoWord;


PROCEDURE HiWord (v: INTEGER): INTEGER;
VAR
    r: INTEGER;

BEGIN
    r := (v DIV 10000H) MOD 10000H;
    IF r >= 8000H THEN r := r - 10000H END;

    RETURN r
END HiWord;


(*============================================================================
   the font

   A glyph comes from GDI.  The cell Font draws in is asked of the face
   itself - how tall a line is, where the baseline sits in it, how wide one
   character is - and each character's picture is made the first time it is
   drawn.  Nothing here is a table of characters, so a face that has a glyph
   has it drawn and a face that has none answers the empty box; which scripts
   a program can show is decided by the font installed, not by this code.

   CreateFontA is asked for a negative height.  That is the convention for
   "this many pixels of cell"; a positive height asks for the character height
   of the em instead and comes out taller than asked for.
   ==========================================================================*)

PROCEDURE Get32 (adr: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    SYSTEM.GET32(adr, v);

    RETURN v
END Get32;


(* Short - a LONG's low 16 bits, sign included.  The origin of a glyph is a
   LONG, but its magnitude is bounded by the cell it is drawn in - Windows does
   not answer a glyph whose ink starts a mile from the pen - so the low word
   carries the value and bit 15 carries its sign, and this is written in terms
   of 16 bits rather than 32 because 100000000H does not fit an INTEGER on the
   32-bit target this module is also built for. *)
PROCEDURE Short (v: INTEGER): INTEGER;
VAR
    r: INTEGER;

BEGIN
    r := v MOD 10000H;
    IF r >= 8000H THEN r := r - 10000H END;

    RETURN r
END Short;


(* Scheme - which provider a specification names: 0 for `gdi:`, 1 for
   `file:`, 2 for `builtin:`, 3 for `auto:`, -1 for none of them.

   `builtin:` is the font compiled into the program - the 8x16 in
   lib/common/FontBuiltin.mod, or whichever of the three a -def chose - and
   needs nothing beside the image.  `auto:` is that same font *unless* there is
   a `font.pcf` in the directory the program was loaded from, in which case it
   is that file.  A program started with no font of its own gets `auto:`, so
   dropping a font.pcf next to an .exe is the whole of how a custom font is
   installed, and a font.pcf that cannot be read leaves the compiled-in one in
   place rather than a window with nothing in it.

   The format of a file is not part of the specification, and that is the point
   of FontFile.Sniff: it reads the file's own first bytes, so a program that
   hands over `file:whatever.bdf` and one that hands over a PSF2 renamed to
   `.bdf` get the same font.  A specification naming a format would only be a
   second place for that answer to be wrong.

   The characters are tested one at a time rather than by comparing the whole
   string, because what LENGTH answers for a string literal passed as an open
   array is one of two things and this does not have to care which: a literal
   is an ARRAY n + 1 OF CHAR with a terminator, and whether the parameter sees
   n or n + 1 is not written down anywhere this file can point at.  Both were
   tried and both got the comparison wrong, so the comparison is gone.

   n is counted first so that no character past the terminator is read. *)
PROCEDURE Scheme (s: ARRAY OF CHAR): INTEGER;
VAR
    res, n: INTEGER;

BEGIN
    n := 0;
    WHILE (n < LENGTH(s)) & (s[n] # 0X) DO INC(n) END;
    res := -1;
    IF n >= 5 THEN
        IF (s[0] = "g") & (s[1] = "d") & (s[2] = "i") & (s[3] = ":") THEN
            res := 0
        ELSIF (s[0] = "f") & (s[1] = "i") & (s[2] = "l") &
              (s[3] = "e") & (s[4] = ":") THEN
            res := 1
        ELSIF (s[0] = "a") & (s[1] = "u") & (s[2] = "t") & (s[3] = "o") &
              (s[4] = ":") THEN
            res := 3
        END
    END;
    IF (res < 0) & (n >= 8) THEN
        IF (s[0] = "b") & (s[1] = "u") & (s[2] = "i") & (s[3] = "l") &
           (s[4] = "t") & (s[5] = "i") & (s[6] = "n") & (s[7] = ":") THEN
            res := 2
        END
    END;

    RETURN res
END Scheme;


(* Field - the part of a specification from ofs up to the next `:` or its end,
   copied into out, and the offset just past that colon.

   `cap` is out's capacity in characters, and it has to be passed in: LENGTH of
   a CHAR array is the length of the string it holds and not the room it has,
   so an empty out measures 0 and a copy guarded by LENGTH(out) copies nothing.
   That is what the first version of this did, and it left every face name
   empty while still returning the right offset. *)
PROCEDURE Field (s: ARRAY OF CHAR; ofs: INTEGER;
                 VAR out: ARRAY OF CHAR; cap: INTEGER): INTEGER;
VAR
    k: INTEGER;

BEGIN
    k := 0;
    WHILE (ofs < LENGTH(s)) & (s[ofs] # 0X) & (s[ofs] # ":") DO
        IF k < cap - 1 THEN
            out[k] := s[ofs]; INC(k)
        END;
        INC(ofs)
    END;
    out[k] := 0X;
    IF (ofs < LENGTH(s)) & (s[ofs] = ":") THEN INC(ofs) END;

    RETURN ofs
END Field;


(* Num - the decimal number at ofs, or 0 if there is not one. *)
PROCEDURE Num (s: ARRAY OF CHAR; ofs: INTEGER): INTEGER;
VAR
    v: INTEGER;

BEGIN
    v := 0;
    WHILE (ofs < LENGTH(s)) & (s[ofs] >= "0") & (s[ofs] <= "9") DO
        v := v * 10 + (ORD(s[ofs]) - ORD("0"));
        INC(ofs)
    END;

    RETURN v
END Num;


(* PaintGlyph - one code point, as the cell Font asked for.  This is the
   PaintFn the whole arrangement hangs on.

   What GDI answers is a packed run of lines, one bit to a pixel, and two
   things about it were measured rather than assumed.  The lines run top down -
   the first line in the buffer is the top of the glyph: `L` was dumped at three
   faces and two heights each and its bar came out last every time.  And a line
   is padded out to a whole DWORD: the size GDI asks for is exactly
   ((blackBoxX + 31) DIV 32) * 4 * blackBoxY, which is 40 bytes for a 6x10
   glyph at Consolas 16 and 4 of them to the line.

   A glyph of no ink comes back as a size of zero, and that is the space: the
   character has an advance and no picture, so it is answered as a success with
   an empty cell rather than as a refusal, which would take the advance away
   with it and run every word together.

   The empty box is what a face with no glyph for the code point produces, and
   it is the right answer: a character this font cannot draw is better shown as
   the box the port has always shown for one, than as a letter that is not the
   one typed. *)
PROCEDURE PaintGlyph (ctx, cp, cellW, cellH, bufAdr: INTEGER): BOOLEAN;
VAR
    n, i, k, bbw, bbh, stride, row, col, sx, sy, dx, dy, v, bit: INTEGER;
    ok: BOOLEAN;

BEGIN
    (* Every byte of the cell is written, because Font copies the whole cell
       into its image: what this leaves alone would be the glyph before. *)
    k := 0;
    WHILE k < cellW * cellH DO
        SYSTEM.PUT8(bufAdr + k, 0);
        INC(k)
    END;
    ok := FALSE;
    IF (fontHandle # 0) & (cp >= 0) & (cp <= 0FFFFH) THEN
        n := GetGlyphOutlineW(ctx, cp, GGO_BITMAP, SYSTEM.ADR(gm), 0, 0,
                              SYSTEM.ADR(mat));
        (* Windows 95 answers the W call only for a face it holds as Unicode,
           so a refusal falls back to the ANSI call for the code points one
           byte can name.  Above 0FFH there is nothing to fall back to. *)
        IF (n = GDI_ERROR) & (cp < 100H) THEN
            n := GetGlyphOutlineA(ctx, cp, GGO_BITMAP, SYSTEM.ADR(gm), 0, 0,
                                  SYSTEM.ADR(mat))
        END;
        IF n = 0 THEN
            ok := TRUE
        ELSIF (n # GDI_ERROR) & (n <= GlyphBufSize) THEN
            n := GetGlyphOutlineW(ctx, cp, GGO_BITMAP, SYSTEM.ADR(gm), n,
                                  SYSTEM.ADR(glyphBuf[0]), SYSTEM.ADR(mat));
            IF (n = GDI_ERROR) & (cp < 100H) THEN
                n := GetGlyphOutlineA(ctx, cp, GGO_BITMAP, SYSTEM.ADR(gm),
                                      GlyphBufSize, SYSTEM.ADR(glyphBuf[0]),
                                      SYSTEM.ADR(mat))
            END;
            IF n # GDI_ERROR THEN
                ok := TRUE;
                bbw := Get32(SYSTEM.ADR(gm.gmBlackBoxX));
                bbh := Get32(SYSTEM.ADR(gm.gmBlackBoxY));
                stride := ((bbw + 31) DIV 32) * 4;
                (* origin is where the ink starts, x from the pen and y up from
                   the baseline, so down from the top of the cell it is the
                   ascent less that. *)
                sx := Short(Get32(SYSTEM.ADR(gm.gmOriginX)));
                sy := fontAscent - Short(Get32(SYSTEM.ADR(gm.gmOriginY)));
                row := 0;
                WHILE row < bbh DO
                    dy := sy + row;
                    IF (dy >= 0) & (dy < cellH) THEN
                        col := 0;
                        WHILE col < bbw DO
                            dx := sx + col;
                            IF (dx >= 0) & (dx < cellW) THEN
                                i := row * stride + col DIV 8;
                                SYSTEM.GET8(SYSTEM.ADR(glyphBuf[i]), v);
                                (* the leftmost pixel of a byte is its most
                                   significant bit *)
                                bit := 7 - col MOD 8;
                                WHILE bit > 0 DO
                                    v := v DIV 2; DEC(bit)
                                END;
                                IF v MOD 2 = 1 THEN
                                    SYSTEM.PUT8(bufAdr + dy * cellW + dx, 0FFH)
                                END
                            END;
                            INC(col)
                        END
                    END;
                    INC(row)
                END
            END
        END
    END;

    RETURN ok
END PaintGlyph;


(* DropFont - give back whatever the font in use was made of.

   Both providers are released here and neither is conditional on which one is
   in use: the other one's state is zero, or NIL, by the time this is reached,
   and asking for it costs nothing.  Order matters only in that the store has
   to go while PaintFile can still name it, which is to say before anything
   else could rebuild a font.

   This is the only place a store is freed, so a font that is switched away
   from is freed by the same code that frees one at exit. *)
PROCEDURE DropFont;
BEGIN
    IF fontStore # NIL THEN
        FontFile.Release(fontStore)
    END;
    IF fontHandle # 0 THEN
        fontHandle := DeleteObject(fontHandle);
        fontHandle := 0
    END;
    IF fontDC # 0 THEN
        IF fontOld # 0 THEN fontOld := SelectObject(fontDC, fontOld) END;
        fontDC := DeleteDC(fontDC);
        fontDC := 0;
        fontOld := 0
    END;
    fontCellW := 0; fontCellH := 0; fontAscent := 0
END DropFont;


(* Reset - no font, and the generated atlas back in its place.

   This is what a failed selection leaves behind, and it is deliberately the
   state the port was in before any of this existed rather than nothing at all:
   a program whose every font was refused draws the 96 characters of the atlas
   and boxes for the rest, which is a worse picture than it wanted and not a
   blank window. *)
PROCEDURE Reset;
VAR
    ok: BOOLEAN;

BEGIN
    DropFont;
    ok := Font.Init(NIL, 0, 0, 0)
END Reset;


(* SelectGDI - build the `gdi:` entry i's face, and answer whether it could be
   built.

   GDI has to produce a face with a usable cell - a name that is not installed
   is still answered by a substituted face, so what is checked is the metrics
   rather than the name - and Font has to accept that cell, which it refuses
   when the cell is taller than the room its image budget leaves below the
   generated atlas. *)
PROCEDURE SelectGDI (i: INTEGER): BOOLEAN;
VAR
    face: ARRAY MaxSpec OF CHAR;
    p, height, sd: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := FALSE;
    p := Field(fonts[i], 4, face, MaxSpec);
    height := Num(fonts[i], p);
    IF (height > 0) & (face[0] # 0X) THEN
        sd := GetDC(0);
        fontDC := CreateCompatibleDC(sd);
        p := ReleaseDC(0, sd);
        IF fontDC # 0 THEN
            (* GetGlyphOutlineW transforms the outline before hinting it, and a
               matrix of zeros is degenerate: GDI answers GDI_ERROR for every
               glyph rather than drawing anything.  The identity is 1.0 on the
               diagonal and nothing elsewhere, and a FIXED of 1.0 is a fraction
               word of 0 and a value word of 1. *)
            SYSTEM.PUT32(SYSTEM.ADR(mat.eM11), 10000H);
            SYSTEM.PUT32(SYSTEM.ADR(mat.eM12), 0);
            SYSTEM.PUT32(SYSTEM.ADR(mat.eM21), 0);
            SYSTEM.PUT32(SYSTEM.ADR(mat.eM22), 10000H);
            fontHandle := CreateFontA(-height, 0, 0, 0, FW_NORMAL,
                                      0, 0, 0, ANSI_CHARSET,
                                      OUT_DEFAULT_PRECIS,
                                      CLIP_DEFAULT_PRECIS,
                                      DEFAULT_QUALITY,
                                      FF_MODERN + DEFAULT_PITCH,
                                      SYSTEM.ADR(face[0]));
            IF fontHandle # 0 THEN
                fontOld := SelectObject(fontDC, fontHandle);
                IF GetTextMetricsA(fontDC, SYSTEM.ADR(tm)) # 0 THEN
                    fontCellH := Get32(SYSTEM.ADR(tm.tmHeight));
                    fontAscent := Get32(SYSTEM.ADR(tm.tmAscent));
                    fontCellW := Get32(SYSTEM.ADR(tm.tmAveCharWidth));
                    IF fontCellW <= 0 THEN
                        fontCellW := Get32(SYSTEM.ADR(tm.tmMaxCharWidth))
                    END;
                    IF (fontCellW > 0) & (fontCellH > 0) &
                       (fontAscent > 0) & (fontAscent <= fontCellH) THEN
                        ok := Font.Init(PaintGlyph, fontDC,
                                          fontCellW, fontCellH);
                        IF ok THEN COPY(fonts[i], fontSource) END
                    END
                END
            END
        END
    END;

    RETURN ok
END SelectGDI;


(* ProgramDir - the directory the running image was loaded from, with the
   separator on the end and nothing after it.

   GetModuleFileNameA and not argv[0]: an image started by a full path, by a
   bare name found on the PATH and by a shell that changed its mind all answer
   the same thing here, and none of the three has to be parsed.  A name that
   comes back with no separator in it at all - which the API does not promise
   never to do - is left as the empty string, and a path built on that is
   `font.pcf` in the current directory, which is the right answer for it. *)
PROCEDURE ProgramDir (VAR dir: ARRAY OF CHAR);
VAR
    n, k, last: INTEGER;

BEGIN
    dir[0] := 0X;
    n := GetModuleFileNameA(0, SYSTEM.ADR(dir[0]), LEN(dir));
    IF (n > 0) & (n < LEN(dir)) THEN
        dir[n] := 0X;
        last := -1;
        k := 0;
        WHILE k < n DO
            IF (dir[k] = "\") OR (dir[k] = "/") THEN last := k END;
            INC(k)
        END;
        IF last >= 0 THEN
            dir[last + 1] := 0X
        ELSE
            dir[0] := 0X
        END
    ELSE
        dir[0] := 0X
    END
END ProgramDir;


(* BesideFont - the path of `font.pcf` in the program's own directory, or the
   bare `font.pcf` when there is no directory to put it in, which is what the
   current directory means. *)
PROCEDURE BesideFont (VAR path: ARRAY OF CHAR);
VAR
    dir: ARRAY 268 OF CHAR;
    name: ARRAY 12 OF CHAR;
    i, base, k, cap: INTEGER;

BEGIN
    ProgramDir(dir);
    COPY("font.pcf", name);
    base := 0;
    WHILE dir[base] # 0X DO INC(base) END;
    cap := LEN(path) - 1;
    i := 0;
    WHILE (i < base) & (i < cap) DO
        path[i] := dir[i]; INC(i)
    END;
    k := 0;
    WHILE (k < 8) & (i < cap) DO
        path[i] := name[k];
        INC(i); INC(k)
    END;
    path[i] := 0X
END BesideFont;


(* StoreFrom - the store FontFile.Paint will be handed, out of whichever of
   the two sources is wanted, and the cell that goes with it.

   The compiled-in font and a file answer the same way, which is the point:
   both end as a store and neither the renderer nor Font knows which it
   got.  The cell is the font's own in both cases - a bitmap font is a fixed
   grid and has no other size. *)
PROCEDURE StoreFrom (useFile: BOOLEAN; VAR st: FontFile.Store;
                     VAR w, h, ascent: INTEGER): BOOLEAN;
VAR
    path: ARRAY 272 OF CHAR;
    name: ARRAY 40 OF CHAR;
    ok, fromFile: BOOLEAN;
    i, k: INTEGER;

BEGIN
    st := NIL;
    w := 0; h := 0; ascent := 0;
    ok := FALSE;
    fromFile := FALSE;
    IF useFile THEN
        BesideFont(path);
        ok := FontFile.Load(path, st);
        fromFile := ok
    END;
    IF ~ok THEN
        ok := FontBuiltin.Load(st)
    END;
    IF ok THEN
        FontFile.Metric(st, w, h);
        ascent := st.ascent;
        IF (w <= 0) & (h <= 0) THEN
            (* Load answers TRUE only for something it read glyphs out of, and
               a store with no glyphs has no cell either; Font would refuse
               the cell anyway, but saying so here is cheaper than building an
               image to throw away. *)
            FontFile.Release(st);
            st := NIL;
            ok := FALSE
        END
    END;
    IF ok THEN
        IF fromFile THEN
            (* The name the path has, not the one the file may carry: what a
               person checking this wants to see is whether the font.pcf they
               put down was the one taken, and the file is not asked for a
               name of its own. *)
            COPY("font.pcf", fontSource)
        ELSE
            FontBuiltin.Name(name);
            COPY("compiled-in ", fontSource);
            i := 12; k := 0;
            WHILE (name[k] # 0X) & (i < LEN(fontSource) - 1) DO
                fontSource[i] := name[k];
                INC(i); INC(k)
            END;
            fontSource[i] := 0X
        END
    END;

    RETURN ok
END StoreFrom;


(* SelectFile - build the `file:` entry i's store, and answer whether it could
   be built.

   The cell comes from the file and not from a request: a bitmap font is a
   fixed grid, and the only size it has is the one it was drawn at.  That is
   the whole difference between the two providers - here the size is a
   consequence of the font chosen, and with GDI it is an instruction to it.
   Hence a `file:` specification names the path and nothing else.

   `FontFile.Paint` is handed to Font directly rather than through a
   wrapper of this module's, because that is exactly the signature Font
   wants.  The store is the context it is given back on every call, which is
   why it has to outlive the Font image and is kept in a module variable
   rather than in a local of this procedure. *)
PROCEDURE SelectFile (i: INTEGER): BOOLEAN;
VAR
    path: ARRAY MaxSpec OF CHAR;
    p: INTEGER;
    ok: BOOLEAN;

BEGIN
    p := Field(fonts[i], 5, path, MaxSpec);
    ok := FontFile.Load(path, fontStore);
    IF ok THEN
        COPY(path, fontSource);
        FontFile.Metric(fontStore, fontCellW, fontCellH);
        fontAscent := fontStore.ascent;
        IF (fontCellW <= 0) & (fontCellH <= 0) THEN
            (* Load answers TRUE only for a file it read glyphs out of, and a
               store with no glyphs has no cell either.  One of the two is
               enough to say the store is not usable; Font would refuse the
               cell anyway, but it is cheaper to say so here than to build an
               image out of it and throw it away. *)
            ok := FALSE
        END
    END;
    IF ok THEN
        ok := Font.Init(FontFile.Paint, SYSTEM.VAL(INTEGER, fontStore),
                          fontCellW, fontCellH)
    END;

    RETURN ok
END SelectFile;


(* SelectBuiltin - the compiled-in font, or the font.pcf beside the program
   when the entry says so.  Both end in the same place: a store in fontStore
   and Font built on it. *)
PROCEDURE SelectBuiltin (useFile: BOOLEAN): BOOLEAN;
VAR
    st: FontFile.Store;
    w, h, ascent: INTEGER;
    ok: BOOLEAN;

BEGIN
    ok := StoreFrom(useFile, st, w, h, ascent);
    IF ok THEN
        fontStore := st;
        fontCellW := w;
        fontCellH := h;
        fontAscent := ascent;
        ok := Font.Init(FontFile.Paint, SYSTEM.VAL(INTEGER, fontStore),
                          fontCellW, fontCellH)
    END;

    RETURN ok
END SelectBuiltin;


(* Select - make entry i the current font, and answer whether it could be made.

   The entry fails if either half fails, and an entry that fails is stepped
   over by NextFont rather than becoming a font that draws nothing.

   Reset is unconditional and comes first, so whatever the last font was made
   of is given back before another is built - including the swap from one
   `file:` entry to another, which is where a store would otherwise be lost.
   Font.Init is then only reached with a cell its image has room for. *)
PROCEDURE Select (i: INTEGER): BOOLEAN;
VAR
    scheme: INTEGER;
    ok: BOOLEAN;

BEGIN
    Reset;
    fontSource[0] := 0X;
    ok := FALSE;
    IF (i >= 0) & (i < nFonts) THEN
        scheme := Scheme(fonts[i]);
        IF scheme = 0 THEN
            ok := SelectGDI(i)
        ELSIF scheme = 1 THEN
            ok := SelectFile(i)
        ELSIF scheme = 2 THEN
            ok := SelectBuiltin(FALSE)
        ELSIF scheme = 3 THEN
            ok := SelectBuiltin(TRUE)
        END
    END;
    IF ~ok THEN Reset END;
    IF ok THEN INC(fontSerial) END;

    RETURN ok
END Select;


(* AddFont - offer a font to the list.  A specification names who provides it:
   `gdi:<face>:<height>` is an installed face at that many pixels of cell,
   `file:<path>` is a bitmap font in a file, `builtin:` is the font compiled
   into the program and `auto:` is that same font unless there is a `font.pcf`
   beside the .exe.  Nothing is opened here - a specification that names a file
   which cannot be read is listed all the same and refused by Select, which is
   the same treatment a face name that is not installed gets.

   Every scheme Select knows is accepted here, and the test is spelled as
   `sch >= 0` rather than as a list of the schemes: an entry this refuses is an
   entry that is silently not in the list, and a default that is silently
   dropped is a default that does not happen.  (That is exactly how `auto:`
   came to be listed by InstallDefaults and still lose to the GDI ladder - the
   test here named the two original schemes one by one.)  What this does refuse
   is a specification naming no provider at all, because no later step could do
   anything with it. *)
PROCEDURE AddFont* (spec: ARRAY OF CHAR): BOOLEAN;
VAR
    res: BOOLEAN;
    sch, i: INTEGER;

BEGIN
    res := FALSE;
    sch := Scheme(spec);
    IF (nFonts < MaxFonts) & (sch >= 0) THEN
        i := 0;
        WHILE (i < LENGTH(spec)) & (i < MaxSpec - 1) & (spec[i] # 0X) DO
            fonts[nFonts][i] := spec[i]; INC(i)
        END;
        fonts[nFonts][i] := 0X;
        INC(nFonts);
        res := TRUE
    END;

    RETURN res
END AddFont;


(* NextFont - step delta places through the list and take the first entry that
   can actually be built.  An entry that cannot is stepped over rather than
   becoming a font that draws nothing.  A list that offers nothing that works
   leaves the previous font where it was. *)
PROCEDURE NextFont* (delta: INTEGER): BOOLEAN;
VAR
    i, step, prev: INTEGER;
    res: BOOLEAN;

BEGIN
    res := FALSE;
    IF (nFonts > 0) & (delta # 0) THEN
        prev := curFont;
        i := curFont;
        step := 0;
        WHILE (step < nFonts) & ~res DO
            i := i + delta;
            WHILE i >= nFonts DO i := i - nFonts END;
            WHILE i < 0 DO i := i + nFonts END;
            INC(step);
            IF Select(i) THEN
                curFont := i;
                res := TRUE
            END
        END;
        IF ~res & (prev >= 0) THEN
            res := Select(prev)
        END
    END;

    RETURN res
END NextFont;


(* FontSource - where the glyphs in use came from, in words.  See the note
   on the variable: this is the outcome, FontName is the specification, and
   they answer differently for an `auto:` entry. *)
PROCEDURE FontSource* (VAR s: ARRAY OF CHAR);
BEGIN
    COPY(fontSource, s)
END FontSource;


(* FontName - the specification of the font in use, for an application that
   wants to show it.  "(none)" is the generated atlas. *)
PROCEDURE FontName* (VAR s: ARRAY OF CHAR);
BEGIN
    IF (curFont >= 0) & (curFont < nFonts) THEN
        COPY(fonts[curFont], s)
    ELSE
        COPY("(none)", s)
    END
END FontName;


(* FontCell* - the cell the font in use draws in, and the height of a line of
   its text.  The cell is the font's own; the line height is one more, which is
   the leading Font keeps. *)
PROCEDURE FontCell* (VAR w, h: INTEGER);
BEGIN
    w := fontCellW;
    h := fontCellH
END FontCell;


(* InstallDefaults - the fonts a program that offered none is run with.

   `auto:` comes first and is therefore what such a program starts on: the
   compiled-in 8x16, or a font.pcf beside the .exe when there is one.  It is
   the default on every platform and it needs no file, no installed face and
   no GDI, which is what makes the same picture available on a machine that
   has none of those.

   The GDI ladder follows for the one thing the bitmap font cannot do - be
   bigger than it was drawn.  Five heights of one face, so that F2 is the way
   to make the text larger without rebuilding anything, and Consolas first
   because it is monospaced and present on every Windows from Vista on.  A
   face that is not there is substituted by GDI rather than refused, and the
   pitch request in SelectGDI is what keeps the substitute monospaced. *)
PROCEDURE InstallDefaults;
VAR
    ok: BOOLEAN;

BEGIN
    ok := AddFont("auto:");
    ok := AddFont("gdi:Consolas:16");
    ok := AddFont("gdi:Consolas:20");
    ok := AddFont("gdi:Consolas:24");
    ok := AddFont("gdi:Consolas:32");
    ok := AddFont("gdi:Consolas:40")
END InstallDefaults;


(* The keys the host keeps for itself: F2 and F3 step through the fonts the
   application offered.  The input layer hands every key on and microui answers
   FALSE for these two, because it has no name for a function key - so this is
   reached only for a key the library did not take, and a host that binds
   nothing else never calls it.

   Switching rebuilds the font and re-lays the atlas out here, inside the
   message, so the frame drawn when this pass returns is already the new one.
   The answer to NextFont is not needed: a list with nothing left that can be
   built leaves the font where it was. *)
PROCEDURE HostKey (VAR e: Events.Event);
BEGIN
    IF e.kind = Events.KEYBOARD THEN
        IF e.scan = Events.K_F2 THEN
            IF NextFont(1) THEN END
        ELSIF e.scan = Events.K_F3 THEN
            IF NextFont(-1) THEN END
        END
    END
END HostKey;


(* The messages that are this module's own and not the input layer's: the
   paint, the resize, the close, and the default procedure for everything
   else.  See WndProc below for why they are here and not there. *)
PROCEDURE HostMessage (wnd, msg, wParam, lParam: INTEGER): INTEGER;
VAR
    res, hdc: INTEGER;
    ps: PAINTSTRUCT;

BEGIN
    res := 0;
    CASE msg OF
        WM_SIZE:
            (* The client area changed, so the framebuffer has to be exactly
               that size: Init gives the old chunk back and asks for one that
               holds the new area, so a window dragged larger is drawn whole
               instead of in the corner of a buffer that stopped growing - the
               defect that left most of a maximised window black.  A minimised
               window asks for nothing and is given a single pixel.

               The frame itself is built in WM_PAINT rather than here, for two
               reasons: Windows keeps sending that one while a border is being
               dragged, and this message arrives with the client size already
               changed, so the two always come as a pair. *)
            MuRender.Init(LoWord(lParam), HiWord(lParam));
            needFrame := TRUE;
            res := InvalidateRect(wnd, 0, 0);
            res := 0

      | WM_PAINT:
            (* A repaint is the last frame blitted again - Windows asks for one
               whenever the window is uncovered, and redrawing the interface
               for that would double every control's hover state - unless the
               framebuffer has been resized since that frame was built, which
               is the one case where what is in it is not the picture.  Then a
               whole frame is built first, so that the last thing a drag leaves
               on the screen is the interface laid out for the size it now
               has.  Before any frame at all this paints the backdrop the host
               cleared to. *)
            IF needFrame THEN BuildFrame END;
            hdc := BeginPaint(wnd, SYSTEM.ADR(ps));
            Blit(hdc);
            res := EndPaint(wnd, SYSTEM.ADR(ps));
            res := 0

      | WM_ERASEBKGND:
            (* Nothing to erase: the framebuffer covers every pixel, and an
               erase would only be a flash of the class background first. *)
            res := 1

      | WM_CLOSE:
            res := DestroyWindow(wnd)

      | WM_DESTROY:
            quit := TRUE;
            PostQuitMessage(0)

      ELSE
            (* The two do the same thing for everything the host leaves alone,
               and differ only in what they make of a message that carries
               text - which the host never sends.  The one belonging to this
               window is used anyway, so that a message is never translated
               from one world to the other on its way out. *)
            IF wide THEN
                res := DefWindowProcW(wnd, msg, wParam, lParam)
            ELSE
                res := DefWindowProcA(wnd, msg, wParam, lParam)
            END
    END;

    RETURN res
END HostMessage;


(* WndProc - every message the window is sent, given to the input layer first.

   What this procedure no longer does is the whole point of the shared layer:
   there is no table from a virtual key to a microui key bit here, no widening
   of a typed character and no UTF-8 encoder, because those three are not facts
   about this window.  They are facts about what a *keyboard* is, and
   lib/common/MuInput.mod holds them once for every host there is, so a second
   Windows host - a console one, an X11 one - does not write them a second time
   and then disagree.

   The three answers FromMessage can give are told apart here by asking what
   the message is, and the middle one is worth naming.  A message the layer
   reads and has no event to make of answers FALSE like any other message that
   is not its own, and there are exactly two of those: a WM_CHAR carrying a
   control character, which is not text, and a wheel that did not reach a whole
   notch.  Neither belongs to the default procedure either - a WM_CHAR handed
   to it is the system's beep - so both are named and both end here.

   What the library does not take is the host's, and the only keys that reach
   that are the two the fonts answer to. *)
PROCEDURE [windows-] WndProc (wnd, msg, wParam, lParam: INTEGER): INTEGER;
VAR
    res: INTEGER;
    e: Events.Event;

BEGIN
    res := 0;
    IF Input.FromMessage(msg, wParam, lParam, e) THEN
        IF ~MuInput.Route(ctx, e) THEN HostKey(e) END
    ELSIF (msg = WM_CHAR) OR (msg = WM_MOUSEWHEEL) THEN
        res := 0
    ELSE
        res := HostMessage(wnd, msg, wParam, lParam)
    END;

    RETURN res
END WndProc;


(*============================================================================
   the window
   ==========================================================================*)

(* Widen - one of the host's own strings, as UTF-16.

   The class name is a literal and the caption is the one the application
   passed to Run.  Neither is promised to be ASCII and neither is promised to
   be well-formed UTF-8 either, so this asks Windows instead of decoding: going
   through the system code page means a caption reads under the Unicode window
   exactly as it would have read under the ANSI one, rather than as the bytes
   of its UTF-8 encoding.  A byte the code page does not define is dropped by
   the conversion, and the destination is bounded so that a long caption stops
   rather than overruns. *)
PROCEDURE Widen (s: ARRAY OF CHAR; VAR d: ARRAY OF WCHAR);
VAR
    n: INTEGER;

BEGIN
    n := 0;
    WHILE (n < LEN(s)) & (n < LEN(d) - 1) & (s[n] # 0X) DO INC(n) END;
    IF n > 0 THEN
        n := MultiByteToWideChar(CP_ACP, 0, SYSTEM.ADR(s[0]), n,
                                 SYSTEM.ADR(d[0]), LEN(d) - 1)
    ELSE
        n := 0
    END;
    IF n < 0 THEN n := 0 END;
    d[n] := WCHR(0)
END Widen;


PROCEDURE Open (name: ARRAY OF CHAR; w, h: INTEGER);
VAR
    wc: WNDCLASSA;
    r: RECT;
    inst, n, cw, ch, k: INTEGER;

BEGIN
    Input.Open;
    COPY("MuOberonWindow", className);
    k := 0;
    WHILE (k < LENGTH(name)) & (k < 127) DO
        caption[k] := name[k];
        INC(k)
    END;
    caption[k] := 0X;

    Widen(className, classNameW);
    Widen(caption, captionW);

    inst := GetModuleHandleA(0);

    SYSTEM.PUT32(SYSTEM.ADR(wc.style), CS_HREDRAW + CS_VREDRAW);
    wc.lpfnWndProc := WndProc;
    SYSTEM.PUT32(SYSTEM.ADR(wc.cbClsExtra), 0);
    SYSTEM.PUT32(SYSTEM.ADR(wc.cbWndExtra), 0);
    wc.hInstance := inst;
    wc.hIcon := 0;
    wc.hCursor := LoadCursorA(0, IDC_ARROW);
    wc.hbrBackground := 0;
    wc.lpszMenuName := 0;

    (* The client area is what the framebuffer is sized to, so the window has
       to be asked for that much plus its own frame.  This is the same either
       way and is done before either window is tried. *)
    SYSTEM.PUT32(SYSTEM.ADR(r.left), 0);
    SYSTEM.PUT32(SYSTEM.ADR(r.top), 0);
    SYSTEM.PUT32(SYSTEM.ADR(r.right), w);
    SYSTEM.PUT32(SYSTEM.ADR(r.bottom), h);
    n := AdjustWindowRect(SYSTEM.ADR(r), WS_OVERLAPPEDWINDOW, 0);
    SYSTEM.GET32(SYSTEM.ADR(r.right), cw);
    SYSTEM.GET32(SYSTEM.ADR(r.left), k);
    cw := cw - k;
    SYSTEM.GET32(SYSTEM.ADR(r.bottom), ch);
    SYSTEM.GET32(SYSTEM.ADR(r.top), k);
    ch := ch - k;

    (* The Unicode window first, because it is the one that lets the keyboard
       reach past the system code page.  WNDCLASSA and WNDCLASSW have the same
       layout - the last two fields are a pointer either way, and only what is
       pointed at differs - so one record serves both registrations and only
       the class name changes.

       `wide` is settled HERE, from the registration and before any window
       exists, and not from whether the window could be created.  The window
       procedure runs INSIDE CreateWindowEx - WM_NCCREATE and WM_CREATE are
       delivered before the call returns - and the caption is applied through
       the default procedure the procedure delegates to.  A Unicode window
       whose default procedure is the ANSI one therefore takes its own wide
       caption as bytes and keeps one letter of it: measured as a title of "U"
       for a window called "UInput", with the class name - which RegisterClassW
       reads itself and no default procedure touches - coming through whole.
       So the flag has to be true before the window can be told anything. *)
    wc.lpszClassName := SYSTEM.ADR(classNameW[0]);
    wide := RegisterClassW(SYSTEM.ADR(wc)) # 0;
    (* The one fact about this window the input layer cannot read out of a
       message, told where it becomes true.  See the note on `wide`. *)
    Input.WideChars(wide);
    hwnd := 0;
    IF wide THEN
        hwnd := CreateWindowExW(0, SYSTEM.ADR(classNameW[0]),
                                SYSTEM.ADR(captionW[0]), WS_OVERLAPPEDWINDOW,
                                100, 100, cw, ch, 0, 0, inst, 0)
    END;

    IF hwnd = 0 THEN
        (* Either the Unicode class or the Unicode window was refused.  A
           window belongs to the Unicode world if its class does, whichever
           call made it, so a failed window does not clear `wide` when the
           class was registered: the ANSI call below looks that same class up
           by name - the two spellings share one atom space - and the window it
           creates is a Unicode window all the same.  Only a system with no
           Unicode class at all leaves `wide` clear, and that is what the ANSI
           registration and the ANSI class name are for; this answer is not
           inspected, because a registration that fails for "class already
           exists" is not a failure. *)
        IF ~wide THEN
            wc.lpszClassName := SYSTEM.ADR(className[0]);
            n := RegisterClassA(SYSTEM.ADR(wc))
        END;
        hwnd := CreateWindowExA(0, SYSTEM.ADR(className[0]),
                                SYSTEM.ADR(caption[0]), WS_OVERLAPPEDWINDOW,
                                100, 100, cw, ch, 0, 0, inst, 0)
    END;

    IF hwnd # 0 THEN
        n := ShowWindow(hwnd, SW_SHOW);
        n := UpdateWindow(hwnd)
    END
END Open;


(* SetBackdrop - change the desktop colour from inside a frame procedure.

   This is a procedure rather than an assignment to `backdrop` because an
   imported variable is read-only in this language: the compiler marks every
   variable reached through a module qualifier, so `MuHost.backdrop := c` is
   `error (94) read only variable`.  A setter is the way across, and the value
   still takes effect in the frame it was set in - the host clears to it after
   the frame procedure has returned. *)
PROCEDURE SetBackdrop* (c: MuBase.Color);
BEGIN
    backdrop := c
END SetBackdrop;


(* Peek / Dispatch - the two queue calls that come in pairs, each pair named
   once from the window the run turned out to have.

   A Unicode window is pumped with the Unicode calls.  The message functions
   translate at the boundary, and the ANSI ones translate to ANSI, so a message
   that carries text is converted on the way in and dropped outright if the
   conversion fails - which is the very loss this is here to prevent.  Nothing
   the host reads carries a pointer, so the two are equivalent in practice for
   these messages; the pair belonging to the window is still the correct pair,
   and choosing it costs two small procedures.

   TranslateMessage has no such pair: it is the same call either way and makes
   the character message the window's own kind by itself. *)
PROCEDURE Peek (madr, hwnd, filterMin, filterMax, remove: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF wide THEN
        res := PeekMessageW(madr, hwnd, filterMin, filterMax, remove)
    ELSE
        res := PeekMessageA(madr, hwnd, filterMin, filterMax, remove)
    END;

    RETURN res
END Peek;


PROCEDURE Dispatch (madr: INTEGER): INTEGER;
VAR
    res: INTEGER;

BEGIN
    IF wide THEN
        res := DispatchMessageW(madr)
    ELSE
        res := DispatchMessageA(madr)
    END;

    RETURN res
END Dispatch;


(* Run - the whole of the reference demo's main loop.  Drain the queue, build
   and draw a frame, put it on the screen, then sleep until there is something
   to do: an immediate-mode interface has nothing to animate, so a pass with no
   message in it would draw the same picture over the same picture. *)
PROCEDURE Run* (ctx0: Microui.Context; name: ARRAY OF CHAR; w, h: INTEGER;
                bg: MuBase.Color; frame: FrameProc);
VAR
    msg: MSG;
    more, n: INTEGER;
    deskCol: MuBase.Color;

BEGIN
    ctx := ctx0;
    quit := FALSE;
    ctx.textWidth  := MuRender.TextWidth;
    ctx.textHeight := MuRender.TextHeight;
    ctx.drawFrame  := MuRender.DrawFrame;

    (* The colours, if the program has a theme file beside its own image.  The
       caller has already run Microui.Init, so what is in the style here is the
       default palette and a theme is an overlay on it rather than a
       replacement for it - which is what lets a theme name three colours and
       leave the other eleven alone.  MuTheme's own module body read the file
       before this procedure ran; this is the one call that puts what it read
       where it is drawn from.  A program with no .ini beside it, or one whose
       .ini names no theme, reaches here with nothing set and `Apply` answers
       FALSE, which is the ordinary case and not an error.

       Here and not in the samples: Run is the only way this host opens a
       window, so a theme given to one program is given to every program that
       runs on this host, including the modules the form designer exports. *)
    IF MuTheme.Apply(ctx.style) THEN END;

    (* The font before anything is drawn with it: MuRender.Init asks Font for
       the line height, and every layout in the frame takes its size from that.
       A program that offered no font is given the default list, and if not one
       entry of the list can be built Font is left with the generated atlas,
       which is what this host drew before it had fonts at all. *)
    IF nFonts = 0 THEN InstallDefaults END;
    curFont := -1;
    IF ~NextFont(1) THEN curFont := -1 END;

    (* The window's own background, which is the one colour a theme keeps
       outside the style - a style has no background, the window's is the
       host's and a program hands it in as `bg`.  A theme that names
       `desktop` therefore overrides the argument rather than the argument
       overriding the theme, and a theme that names none leaves `bg` exactly
       as it was.  The same one call, for the same reason: Run is the only
       way this host opens a window.

       A program that sets its own backdrop every frame still wins, because
       SetBackdrop is exported and this is only the first frame: the Demo
       sample drives its background from three sliders and is meant to.  A
       program that hands `bg` in here and never touches it again - Hello,
       the form designer, and every module the designer exports - gets the
       theme's desktop. *)
    backdrop := bg;
    IF MuTheme.Desktop(deskCol) THEN backdrop := deskCol END;

    frameProc := frame;
    needFrame := FALSE;
    MuRender.Init(w, h);
    (* Cleared before the window exists, because creating one sends a paint
       into the procedure below, and NEW does not zero what it allocates: the
       first thing on the screen would otherwise be whatever the heap held. *)
    MuRender.Clear(backdrop);
    SetUpDIB(MuRender.Width, MuRender.Height);
    Open(name, w, h);

    WHILE ~quit DO
        more := Peek(SYSTEM.ADR(msg), 0, 0, 0, PM_REMOVE);
        WHILE more # 0 DO
            more := TranslateMessage(SYSTEM.ADR(msg));
            more := Dispatch(SYSTEM.ADR(msg));
            more := Peek(SYSTEM.ADR(msg), 0, 0, 0, PM_REMOVE)
        END;

        IF ~quit THEN
            BuildFrame;
            Present(hwnd);
            more := WaitMessage()
        END
    END;

    (* The loop is over, so everything this run took has to be handed back: the
       window class, which belongs to Windows; the device context and the font
       itself, which belong to GDI, or the glyph store, which belongs to
       FontFile; the glyph image, which belongs to Font; and the
       framebuffer, which belongs to MuRender.  The context is not one of them
       - the caller allocated it, and the caller disposes of it. *)
    DropFont;
    Font.Done;
    MuRender.Done;
    Input.Close;
    n := UnregisterClassA(SYSTEM.ADR(className[0]), GetModuleHandleA(0))
END Run;


END MuHost.
