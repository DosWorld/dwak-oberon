# ZIP archives for DWAK Oberon-07

`Zip.mod` reads and writes classic `.zip` archives using the project's `Files`
API. It supports stored entries (method 0), DEFLATE (method 8), listing,
buffer/file input and output, UTF-8 names, and CRC-32 verification.
The original incompatible `Zip.mod` was removed; this is its replacement.

`AddFile` and `ExtractFile` are streaming: file size does not determine working
memory. `AddMemory` compresses an existing byte array directly to the archive;
`ExtractMemory` decodes directly into caller-owned memory. **The old 1 MiB entry
limit has been removed.** Classic ZIP sizes/offsets are currently limited to
signed 32-bit values (below 2 GiB for the archive); there are at most 1024 entries.
ZIP64, encryption, split archives, and in-place updates are not supported.

## Command-line example

Build from the project root:

```sh
bin/m64oc samples/zip/ZipTool.mod macos64 -l lib -out /tmp/ziptool -stk 4
chmod +x /tmp/ziptool
```

```sh
# Create an archive; arguments are pairs of archive name and input path.
/tmp/ziptool c demo.zip hello.txt input.txt notes.txt notes.txt

# Use method 0 instead of compression.
/tmp/ziptool s raw.zip data.bin input.bin

# List entries and their original/compressed sizes.
/tmp/ziptool l demo.zip

# Extract one named entry to an explicit output path.
/tmp/ziptool e demo.zip hello.txt output.txt

# Independent format and checksum verification.
unzip -t demo.zip
```

Archive and output files must not already exist. Parent directories must exist.
The tool prints `ZIP OK` on success or `ZIP FAILED, error N` on failure; callers
should inspect this message rather than rely on the runtime's exit status.
Names inside archives may contain UTF-8 or relative subdirectories even though
this sample's physical file names use DOS 8.3. Extraction does not create an
archive's directory tree automatically. Duplicate member names are permitted;
the tool extracts the first match, while the library addresses entries by index.

## Library example

```oberon
MODULE Example;
IMPORT Z := Zip;
VAR archive: Z.Archive; entry: Z.Entry; i: INTEGER;
BEGIN
    Z.Init(archive);
    ASSERT(Z.Create(archive, "demo.zip"));
    ASSERT(Z.AddFile(archive, "hello.txt", "input.txt", Z.Deflated));
    ASSERT(Z.Close(archive));

    ASSERT(Z.Open(archive, "demo.zip"));
    FOR i := 0 TO Z.Count(archive) - 1 DO
        ASSERT(Z.EntryAt(archive, i, entry));
        (* entry.name, entry.size, entry.packed, entry.method, entry.crc *)
    END;
    ASSERT(Z.ExtractFile(archive, 0, "output.txt"));
    ASSERT(Z.Close(archive))
END Example.
```

For memory buffers, use `AddMemory(archive, name, bytes, length, method)` and
`ExtractMemory(archive, index, bytes, written)`. `Add` and `Extract` remain compatible shorthand names. Extract checks the decompressed length
and CRC before reporting success. On failure `written` is zero; the buffer may
have been modified and must not be used as verified data. `ExtractFile` writes incrementally and checks CRC at the end. On any failure it
closes and deletes the newly created partial output (a deletion failure reports IOError).

### Compress memory into a ZIP

```oberon
(* bytes: ARRAY ... OF BYTE; length: number of initialized bytes *)
Z.Init(archive);
ASSERT(Z.Create(archive, "memory.zip"));
ASSERT(Z.AddMemory(archive, "data.bin", bytes, length, Z.Deflated));
ASSERT(Z.Close(archive));
```

No intermediate file or full compressed-result buffer is used. `Stored` is also
available. To extract, first call `EntryAt` to obtain `entry.size`, provide an
array with at least that many bytes, then call:

```oberon
ASSERT(Z.Open(archive, "memory.zip"));
ASSERT(Z.EntryAt(archive, 0, entry));
ASSERT(entry.size <= LEN(bytes));
ASSERT(Z.ExtractMemory(archive, 0, bytes, written));
ASSERT(Z.Close(archive));
```

The caller owns the output array and any heap record containing it. If the array
is too small, the operation returns `BufferSmall` without decoding; retry with a
larger array. The memory API cannot make an array larger automatically. Use
`ExtractFile` when the contents should not reside entirely in memory.

The archive record owns resources. Initialize a fresh record once, never copy
it or pass it by value, and always close an open archive. Separate archive
records can operate on different files. Reuse a closed record with Open/Create;
do not call Init instead of Close. Close also releases allocations after an
error. Failed Open/Create release their own temporary resources.

## ZIP API

All archive operations take `VAR archive: Archive`. Indices are zero-based.

| Procedure | Meaning |
|---|---|
| `Init(archive)` | Initialize a new owning record. |
| `Create(archive, path): BOOLEAN` | Create a new archive, refusing an existing file. |
| `Open(archive, path): BOOLEAN` | Read EOCD and central directory, validate supported metadata, open for reading. |
| `AddMemory(archive, name, VAR bytes, length, method): BOOLEAN` | Compress a memory buffer directly to a writer; method is `Stored` or `Deflated`. `Add` is equivalent. |
| `AddFile(archive, name, path, method): BOOLEAN` | Stream a file into the archive, with incremental CRC and bounded workspace. |
| `Count(archive): INTEGER` | Number of entries in an open archive. |
| `EntryAt(archive, index, VAR entry): BOOLEAN` | Copy a reader's entry metadata. Does not extract or verify its CRC. |
| `ExtractMemory(archive, index, VAR bytes, VAR written): BOOLEAN` | Stream compressed input into the supplied array and verify the entry. `Extract` is equivalent. |
| `ExtractFile(archive, index, path): BOOLEAN` | Stream to a new explicit path; refuse overwrite and delete partial output on failure. |
| `Close(archive): BOOLEAN` | Writer: emit central directory and EOCD, then close. Reader: close. Release memory in both cases. |
| `Error(archive): INTEGER` | Read the most recent operation's status. |

`Entry` exports `name` (256 CHAR buffer), `size`, `packed`, `method`, and `crc`.
CRC is a **signed 32-bit bit pattern**, also on 64-bit targets. Negative CRC
values are normal. Treat it as bits, not as a file size.

Status values:

| Value | Constant | Meaning |
|---|---|---|
| 0 | `OK` | Success. |
| 1 | `IOError` | File operation failed. |
| 2 | `BadData` | Invalid structure, metadata disagreement, or malformed compressed data. |
| 3 | `Unsupported` | Unsupported method, flags, version, ZIP64-sized fields, or multiple disks. |
| 4 | `Limit` | Entry/name/count/size exceeds this implementation's bounds. |
| 5 | `BadArgument` | Invalid name, path, length, or entry index. |
| 6 | `Closed` | Operation on a closed archive. |
| 7 | `Exists` | Refused to overwrite a file. |
| 8 | `BufferSmall` | Output array cannot hold the entry. |
| 9 | `CRCError` | Extracted bytes disagree with the stored CRC. |
| 10 | `NoMemory` | Allocation returned NIL. |
| 11 | `WrongMode` | Reader/writer mismatch, or Open/Create on an open record. |

Argument errors and small buffers are recoverable. Structural, decompression,
CRC, and archive-write errors latch a failed state: close the archive afterward.
Close returns FALSE for such a failed archive. On a healthy writer, Close may
succeed after a rejected Add; previously added entries remain valid. A failed
creation sequence may leave a partial file, which the caller must handle.
Files buffers writes: **always check Close**, even if every Add succeeded.
Overwrite refusal is a check followed by creation, not atomic exclusive-create.
There are no transactions, concurrent-file protection, fsync guarantees, or
rollback after filesystem write failure.

## Codec modules

The codecs are independent of the container and use caller-supplied byte arrays.

| API | Contract |
|---|---|
| `CRC32.Of(VAR bytes, length): INTEGER` | IEEE/PKZIP CRC-32 of a buffer. |
| `CRC32.Update(crc, VAR bytes, offset, length): INTEGER` | Start with zero or continue from a previous finalized result. Valid slice bounds are a checked precondition. |
| `Deflate.Bound(length): INTEGER` | Safe output capacity; returns -1 for negative or overly large input lengths. |
| `Deflate.Compress(VAR src, srcLen, VAR dst, dstLen, VAR written): INTEGER` | Raw DEFLATE; `OK`, `OutputFull`, `BadArgument`, or `NoMemory`. Output is usable only on OK. |
| `Inflate.Decompress(VAR src, srcLen, VAR dst, dstLen, VAR written): INTEGER` | Decode the first raw stream; `OK`, `BadData`, `OutputFull`, `InputTruncated`, or `BadArgument`. |
| `Inflate.DecompressUsed(..., VAR written, VAR consumed): INTEGER` | Same, also reporting consumed bytes, including the final partial byte. Also available in the file-input variants for strict framing. |

File codec APIs use already open `Files.File` records at their current positions;
the caller retains ownership and must close/check the files:

- `Deflate.CompressFile(VAR input, output, srcLen, maxPacked, VAR written, crc)`:
  bounded file-to-file compression; never emit more than `maxPacked` bytes.
- `Deflate.CompressToFile(VAR bytes, srcLen, VAR output, maxPacked, VAR written, crc)`:
  the same compression engine with a memory source.
- `Inflate.DecompressFile(VAR input, output, srcLen, dstLen, VAR written, consumed, crc)`:
  file-to-file decoding with bounded input/output lengths.
- `Inflate.DecompressToMemory(VAR input, srcLen, VAR bytes, dstLen, VAR written, consumed)`:
  file-to-memory decoding. No buffer proportional to compressed size.

File variants additionally report `IOError`/`NoMemory`. Decoder consumption
includes the final partial byte; file input is positioned immediately after those
bytes even if the decoder buffered ahead. Zip enforces both exact compressed
consumption and exact uncompressed size before accepting an entry.

`Deflate.Compress` emits one fixed-Huffman block into a memory array. File-output
variants emit fixed-Huffman blocks over 32 KiB input chunks, preserving bit state
and the previous 32 KiB of LZ77 history across chunks. Hash positions are rebased
per chunk to avoid arithmetic growth. The greedy matcher allows at most 128
probes per position. Decompression shares one validated decoder for memory/file
inputs and outputs; streamed output retains a 32 KiB ring window and 4 KiB I/O
buffers. Stored, fixed and dynamic blocks, overlap, and cross-block matches are
supported. No zlib/gzip wrapper. Compression can enlarge input; it does not
automatically switch to stored mode.

## Format support and limits

- Classic single-disk ZIP, methods 0 and 8, required versions up to 2.0.
  Flags accepted: UTF-8, data descriptor, and DEFLATE option bits. Encryption,
  patched data and other features are rejected rather than silently ignored.
- Reader accepts local and central extra fields, entry comments, archive comments,
  and both signed and signatureless 32-bit data descriptors. Unknown extra fields
  are skipped. ZIP64, central-directory signatures and self-extracting offset
  rebasing are not implemented.
- Central directory is checked at Open; local headers and contents at Extract.
  Unsupported entries cause Open to reject the archive as a whole; large entries
  within the signed-32-bit bounds are accepted regardless of available memory.
- Entry sizes and compressed lengths: at most **2147483647 bytes** (`MaxEntry`).
  Archive offsets/length stay within the same bound, so headers and the directory
  reduce the largest possible stored entry. Maximum entries: **1024**.
  There is no 1 MiB limit on memory or file operations. Actual near-2-GiB files
  have not been runtime-tested; regression files exceed 3 MiB.
- Writer names are validated UTF-8, 1..255 bytes, with flag 11 set. Reader validates
  UTF-8 when flagged; unflagged legacy name bytes are preserved without code-page
  conversion. Unsafe relative components (`.`/`..`), absolute names, backslashes,
  colons, NUL and ASCII control characters are rejected. No Unicode normalization.
- Paths passed to the file API are NUL-terminated, nonempty and at most 255 bytes.
  The archive never constructs an output path from an entry name. Filesystem
  symlinks/attributes and directory entries are not restored; output is regular data.
- Writers use signed data descriptors (flag 3) for incremental CRC and sizes.
  Writer timestamps use 1980-01-01. Original timestamps, permissions, extra fields
  and comments are not preserved when creating a new archive.
- Each open archive owns a fixed metadata directory (about 300 KiB on macOS64).
  Stored file copying uses a 32 KiB temporary buffer. Compression uses about
  650 KiB on macOS64 for hash chains, history, input and output; streamed decoding
  uses a 40 KiB workspace plus Huffman tables. These allocations do not grow with
  file size and are released after each operation. Memory APIs additionally use
  the caller's array, which is neither allocated nor freed by Zip.
- Buffers must not alias codec input/output. Archive records require a single owner.
  This parser has bounds checks and malformed-input tests, but has not undergone
  exhaustive fuzzing or a security audit.

## Tests

Build and run in a fresh directory. No Python or external test framework is needed:

```sh
bin/m64oc samples/zip/ZipTests.mod macos64 -l lib -out /tmp/ziptest -stk 4
chmod +x /tmp/ziptest
zip_test_dir=$(mktemp -d /tmp/zip.XXXXXX)
cp samples/zip/fixtures/*.zip "$zip_test_dir/"
(cd "$zip_test_dir" && /tmp/ziptest)
```

Require the final message **`ZIP ALL TESTS OK`**, with no FAIL/assertion message.
`EXTERNAL ZIP OK` and `EXTERNAL LARGE ZIP OK` confirm both independent fixtures were tested. The fixture
is optional only for running without any auxiliary files; use it for full review.
Tests leave their files in the temporary directory for inspection.

- `ZipTests`: known and incremental CRC, empty/tiny/mixed/repetitive buffers,
  70000-byte round trips, bounds, stored/deflated ZIP entries, UTF-8, large caller
  name buffers, file helpers, overwrite refusal, empty archives and external ZIP.
- `CodecT`: malformed/oversubscribed/incomplete Huffman trees, overlong repeat
  runs, missing EOB, legal single-EOB/no-distance alphabet, stored/fixed mixed
  blocks, reserved symbols, invalid distances, every truncated prefix of a sample,
  output exhaustion and all match-length transitions.
- `ZipFmtT`: independently assembled ZIP records, extras/comments, descriptor
  variants and ten corrupted/unsupported archive cases.

- `StreamT`: 3 MiB + 137-byte files, streaming stored/deflated reads and writes,
  memory reads/writes of both methods, empty files and an external large dynamic
  ZIP. Contents are compared byte-for-byte. `ZipFmtT` also verifies that failed
  streamed extraction leaves no partial output.

`fixtures/external.zip` was generated using `/usr/bin/zip -9 -X external.zip
source.bin`, independently of these codecs. The Oberon test regenerates its
70000-byte expected payload using the documented test recurrence and compares
all extracted bytes. This exercises dynamic Huffman decoding. `fixtures/bigext.zip` was created with
`zip -9 -X bigext.zip large.bin` from the deterministic `StreamT` source; it
exercises the same independent decoder path across many I/O/window boundaries.

For independent verification of archives produced by the test:

```sh
(cd "$zip_test_dir" && unzip -t written.zip)
(cd "$zip_test_dir" && unzip -t stream.zip && unzip -t memory.zip)
(cd "$zip_test_dir" && unzip -p written.zip stored.bin > check0.bin)
(cd "$zip_test_dir" && unzip -p written.zip 'folder/*' > check8.bin)
(cd "$zip_test_dir" && cmp source.bin check0.bin && cmp source.bin check8.bin)
```

Both test and tool were compiled for macOS64; tests were also cross-compiled for
Win32. Cross-compilation alone is not a Win32 runtime test.

## Implementation references

The implementation follows [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951)
and the [PKWARE ZIP specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT).
The match finder, canonical decoder, container code and tests here are independently expressed in Oberon.
