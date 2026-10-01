(*
    BSD 2-Clause License

    Copyright (c) 2019-2021, Anton Krotov
    All rights reserved.
*)

MODULE WINAPI;

IMPORT SYSTEM, API;


CONST

    OFS_MAXPATHNAME* = 128;

    KERNEL = "kernel32.dll";
    USER   = "user32.dll";
    MSVCRT = "msvcrt.dll";


TYPE

    DLL_ENTRY* = API.DLL_ENTRY;

    STRING = ARRAY 260 OF CHAR;

    TCoord* = RECORD

        X*, Y*: WCHAR

    END;

    TSmallRect* = RECORD

        Left*, Top*, Right*, Bottom*: WCHAR

    END;

    TConsoleScreenBufferInfo* = RECORD

        dwSize*:               TCoord;
        dwCursorPosition*:     TCoord;
        wAttributes*:          WCHAR;
        srWindow*:             TSmallRect;
        dwMaximumWindowSize*:  TCoord

    END;

    TSystemTime* = RECORD

        Year*,
        Month*,
        DayOfWeek*,
        Day*,
        Hour*,
        Min*,
        Sec*,
        MSec*:  WCHAR

    END;

    tm* = RECORD

        sec*,
        min*,
        hour*,
        mday*,
        mon*,
        year*,
        wday*,
        yday*,
        isdst*: SYSTEM.CARD32

    END;

    PSecurityAttributes* = POINTER TO TSecurityAttributes;

    TSecurityAttributes* = RECORD

        nLength*:               SYSTEM.CARD32;
        lpSecurityDescriptor*:  INTEGER;
        bInheritHandle*:        SYSTEM.CARD32 (* BOOL *)

    END;

    TFileTime* = RECORD

        dwLowDateTime*,
        dwHighDateTime*: SYSTEM.CARD32

    END;

    TWin32FindData* = RECORD

        dwFileAttributes*:    SYSTEM.CARD32;
        ftCreationTime*:      TFileTime;
        ftLastAccessTime*:    TFileTime;
        ftLastWriteTime*:     TFileTime;
        nFileSizeHigh*:       SYSTEM.CARD32;
        nFileSizeLow*:        SYSTEM.CARD32;
        dwReserved0*:         SYSTEM.CARD32;
        dwReserved1*:         SYSTEM.CARD32;
        cFileName*:           STRING;
        cAlternateFileName*:  ARRAY 14 OF CHAR;
        dwFileType*:          SYSTEM.CARD32;
        dwCreatorType*:       SYSTEM.CARD32;
        wFinderFlags*:        WCHAR

    END;

    (* The wide form of the same record, and a record of its own rather than a
       widened TWin32FindData: FindFirstFileW writes WCHAR arrays all the way
       down, so the two layouts differ from the first name onwards and sharing
       one of them would put the name in the wrong place.  The three fields
       past cAlternateFileName are not part of the Win32 record and are here
       for the same reason they are in the narrow one - the buffer an API
       writes is the caller's, and a little room past what it writes costs
       nothing. *)
    TWin32FindDataW* = RECORD

        dwFileAttributes*:    SYSTEM.CARD32;
        ftCreationTime*:      TFileTime;
        ftLastAccessTime*:    TFileTime;
        ftLastWriteTime*:     TFileTime;
        nFileSizeHigh*:       SYSTEM.CARD32;
        nFileSizeLow*:        SYSTEM.CARD32;
        dwReserved0*:         SYSTEM.CARD32;
        dwReserved1*:         SYSTEM.CARD32;
        cFileName*:           ARRAY 260 OF WCHAR;
        cAlternateFileName*:  ARRAY 14 OF WCHAR;
        dwFileType*:          SYSTEM.CARD32;
        dwCreatorType*:       SYSTEM.CARD32;
        wFinderFlags*:        WCHAR

    END;

    OFSTRUCT* = RECORD

        cBytes*:      BYTE;
        fFixedDisk*:  BYTE;
        nErrCode*:    WCHAR;
        Reserved1*:   WCHAR;
        Reserved2*:   WCHAR;
        szPathName*:  ARRAY OFS_MAXPATHNAME OF CHAR

    END;

    POverlapped* = POINTER TO OVERLAPPED;

    OVERLAPPED* = RECORD

        Internal*:      INTEGER;
        InternalHigh*:  INTEGER;
        Offset*:        SYSTEM.CARD32;
        OffsetHigh*:    SYSTEM.CARD32;
        hEvent*:        INTEGER

    END;


PROCEDURE [windows-, KERNEL, ""] SetConsoleCursorPosition* (hConsoleOutput, dwCursorPosition: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GetConsoleScreenBufferInfo* (hConsoleOutput: INTEGER; ConsoleScreenBufferInfo: TConsoleScreenBufferInfo): INTEGER;

PROCEDURE [windows-, KERNEL, ""] FillConsoleOutputCharacterA* (hConsoleOutput, cCaracter, nLength, dwWriteCoord, lpNumberOfCharsWritten: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] FillConsoleOutputAttribute* (hConsoleOutput, wAttribute, nLength, dwWriteCoord, lpNumberOfAttrsWritten: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] SetConsoleTextAttribute* (hConsoleOutput, wAttributes: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GetStdHandle* (nStdHandle: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] CloseHandle* (hObject: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] WriteFile* (hFile, Buffer, nNumberOfBytesToRead, lpNumberOfBytesRead: INTEGER; lpOverlapped: POverlapped): INTEGER;

PROCEDURE [windows-, KERNEL, ""] ReadFile* (hFile, Buffer, nNumberOfBytesToRead, lpNumberOfBytesRead: INTEGER; lpOverlapped: POverlapped): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GetCommandLineA* (): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GlobalAlloc* (uFlags, dwBytes: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GlobalFree* (hMem: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] ExitProcess* (code: INTEGER);

PROCEDURE [windows-, KERNEL, ""] GetTickCount* (): INTEGER;

PROCEDURE [windows-, KERNEL, ""] Sleep* (dwMilliseconds: INTEGER);

PROCEDURE [windows-, KERNEL, ""] FreeLibrary* (hLibModule: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GetProcAddress* (hModule, name: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] LoadLibraryA* (name: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] AllocConsole* (): BOOLEAN;

PROCEDURE [windows-, KERNEL, ""] FreeConsole* (): BOOLEAN;

PROCEDURE [windows-, KERNEL, ""] GetLocalTime* (T: TSystemTime);

PROCEDURE [windows-, KERNEL, ""] RemoveDirectoryA* (lpPathName: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] RemoveDirectoryW* (lpPathName: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GetCurrentDirectoryA* (nBufferLength: INTEGER; lpBuffer: INTEGER): INTEGER;

(* The same, in WCHARs - nBufferLength counts them, and so does the answer. *)
PROCEDURE [windows-, KERNEL, ""] GetCurrentDirectoryW* (nBufferLength: INTEGER; lpBuffer: INTEGER): INTEGER;

(* GetLogicalDrives - one bit per drive letter, bit 0 for A:, so that a test
   reads `i IN WinAPI.GetLogicalDrives()`.  A bit that is clear is a drive
   that is not there; the call itself has no failure to report. *)
PROCEDURE [windows-, KERNEL, ""] GetLogicalDrives* (): SET;

PROCEDURE [windows-, KERNEL, ""] GetFileAttributesA* (lpPathName: INTEGER): SET;

PROCEDURE [windows-, KERNEL, ""] GetFileAttributesW* (lpPathName: INTEGER): SET;

PROCEDURE [windows-, KERNEL, ""] CreateDirectoryA* (lpPathName: INTEGER; lpSecurityAttributes: PSecurityAttributes): INTEGER;

PROCEDURE [windows-, KERNEL, ""] CreateDirectoryW* (lpPathName: INTEGER; lpSecurityAttributes: PSecurityAttributes): INTEGER;

PROCEDURE [windows-, KERNEL, ""] FindFirstFileA* (lpFileName: INTEGER; lpFindFileData: TWin32FindData): INTEGER;

PROCEDURE [windows-, KERNEL, ""] FindNextFileA* (hFindFile: INTEGER; lpFindFileData: TWin32FindData): INTEGER;

PROCEDURE [windows-, KERNEL, ""] FindFirstFileW* (lpFileName: INTEGER; lpFindFileData: TWin32FindDataW): INTEGER;

PROCEDURE [windows-, KERNEL, ""] FindNextFileW* (hFindFile: INTEGER; lpFindFileData: TWin32FindDataW): INTEGER;

PROCEDURE [windows-, KERNEL, ""] DeleteFileA* (lpFileName: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] DeleteFileW* (lpFileName: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] FindClose* (hFindFile: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] CreateFileA* (
        lpFileName, dwDesiredAccess, dwShareMode: INTEGER;
        lpSecurityAttributes: PSecurityAttributes;
        dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] CreateFileW* (
        lpFileName, dwDesiredAccess, dwShareMode: INTEGER;
        lpSecurityAttributes: PSecurityAttributes;
        dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] OpenFile* (lpFileName: INTEGER; lpReOpenBuff: OFSTRUCT; uStyle: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] SetFilePointer* (hFile, lDistanceToMove, lpDistanceToMoveHigh, dwMoveMethod: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] MoveFileA* (lpExistingFileName, lpNewFileName: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] MoveFileW* (lpExistingFileName, lpNewFileName: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] SetEndOfFile* (hFile: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GetFileTime* (hFile, lpCreationTime, lpLastAccessTime, lpLastWriteTime: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] SetFileTime* (hFile, lpCreationTime, lpLastAccessTime, lpLastWriteTime: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] FileTimeToLocalFileTime* (lpFileTime, lpLocalFileTime: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] LocalFileTimeToFileTime* (lpLocalFileTime, lpFileTime: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] FileTimeToSystemTime* (lpFileTime, lpSystemTime: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] SystemTimeToFileTime* (lpSystemTime, lpFileTime: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] ReadConsoleA* (hConsoleInput, lpBuffer, nNumberOfCharsToRead, lpNumberOfCharsRead, lpReserved: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] WriteConsoleW* (hConsoleOutput, lpBuffer, nNumberOfCharsToWrite, lpNumberOfCharsWritten, lpReserved: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] WriteConsoleA* (hConsoleOutput, lpBuffer, nNumberOfCharsToWrite, lpNumberOfCharsWritten, lpReserved: INTEGER): INTEGER;

PROCEDURE [windows-, KERNEL, ""] GetEnvironmentStringsA* (): INTEGER;

PROCEDURE [windows-, KERNEL, ""] FreeEnvironmentStringsA* (penv: INTEGER): INTEGER;

PROCEDURE [windows-, USER,   ""] MessageBoxA* (hWnd, lpText, lpCaption, uType: INTEGER): INTEGER;

PROCEDURE [windows-, USER,   ""] MessageBoxW* (hWnd, lpText, lpCaption, uType: INTEGER): INTEGER;

PROCEDURE [windows-, USER,   ""] CreateWindowExA* (
        dwExStyle, lpClassName, lpWindowName, dwStyle, X, Y,
        nWidth, nHeight, hWndParent, hMenu, hInstance, lpParam: INTEGER): INTEGER;

PROCEDURE [ccall-, MSVCRT, ""] time* (ptr: INTEGER): INTEGER;

PROCEDURE [ccall-, MSVCRT, ""] mktime* (time: tm): INTEGER;


PROCEDURE SetDllEntry* (process_detach, thread_detach, thread_attach: DLL_ENTRY);
BEGIN
    API.SetDll(process_detach, thread_detach, thread_attach)
END SetDllEntry;


END WINAPI.