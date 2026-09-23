# File-backed B+ trees for DWAK Oberon-07

`BPTREES.MOD` stores UTF-8 keys and `INTEGER` values in a single external file.
It supports unique indexes, duplicate keys, caller-defined ordering, range scans,
and balanced deletion. The public tree type is `BpTrees.BpTree`.

## Quick start

This complete example creates a unique index, updates an entry, and reads it:

```oberon
MODULE Names;
IMPORT B := BpTrees, O := BPTOrder, Out;
VAR tree: B.BpTree; value: INTEGER;
BEGIN
    B.Init(tree);
    IF B.Create(tree, "names.db", TRUE, O.English, O.EnglishID) THEN
        ASSERT(B.Insert(tree, "Alice", 101));
        ASSERT(B.Put(tree, "Alice", 202));
        IF B.Get(tree, "Alice", value) THEN
            Out.Int(value, 0); Out.Ln
        END;
        ASSERT(B.Close(tree))
    ELSE
        Out.String("Create failed: "); Out.Int(B.Error(tree), 0); Out.Ln
    END
END Names.
```

Create refuses to overwrite an existing file. To reopen it, use:

```oberon
IF B.Open(tree, "names.db", TRUE, O.English, O.EnglishID) THEN
    (* Read or change entries here. *)
    ASSERT(B.Close(tree))
END
```

Call `Init` once on a new tree record. The record owns file and memory resources:
**do not copy it or pass it by value**. All tree operations take a `VAR` parameter.
Use `Close`, not `Init`, to release an open tree. After closing, the same record
can be opened again. Multiple trees may be open if they refer to different files.

## Ordering and duplicate keys

A comparison procedure defines both ordering and equality:

```oberon
TYPE CompareProc = PROCEDURE (a, b: ARRAY OF CHAR): INTEGER;
```

Return a negative number when `a` precedes `b`, zero for equivalent keys, and a
positive number when `a` follows `b`. Arguments are NUL-terminated arrays of
`MaxKey + 1` characters; ignore bytes after NUL. Ordering must be deterministic,
transitive, and unchanged throughout the file's lifetime. Do not call operations
on the same tree from its comparator.

`BPTOrder` supplies two English/ASCII comparators:

| Comparator | ID | Behavior |
|---|---|---|
| `English` | `EnglishID = 1` | Case-sensitive UTF-8 byte order; `Apple` and `apple` differ. |
| `EnglishNoCase` | `EnglishNoCaseID = 2` | Folds ASCII A–Z to a–z; `Apple` and `aPpLe` are equal. |

These are not locale-aware Unicode collations: non-ASCII bytes are unchanged,
and there is no normalization, Unicode case folding, or numeric sorting.
Keys retain their original spelling. In a unique index, updating an equivalent
key with `Put` changes its value but retains the stored spelling.

Pass `FALSE` to create a nonunique index:

```oberon
ASSERT(B.Create(tree, "dups.db", FALSE,
                O.EnglishNoCase, O.EnglishNoCaseID));
ASSERT(B.Put(tree, "Smith", 101));
ASSERT(B.Put(tree, "SMITH", 202));
ASSERT(B.Put(tree, "Smith", 101));  (* Identical pairs are allowed. *)
ASSERT(B.Get(tree, "smith", value));  (* Returns 101, the oldest entry. *)
ASSERT(B.RemoveValue(tree, "smith", 202));  (* Removes one matching pair. *)
ASSERT(B.Close(tree));
```

Equivalent keys are adjacent and retain insertion order, including across splits
and reopenings. An internal serial number distinguishes duplicates. It is never
reused: a nonunique file permits 2,147,483,646 successful insertions over its
lifetime. Deletion does not reset this counter.

For custom ordering, supply a compatible procedure and a distinct positive ID
(use IDs from 1000 for application-defined rules). For example:

```oberon
PROCEDURE Reverse(a, b: ARRAY OF CHAR): INTEGER;
BEGIN RETURN -O.English(a, b) END Reverse;

(* After B.Init(tree): *)
ASSERT(B.Create(tree, "reverse.db", TRUE, Reverse, 1001));
```

The file stores `orderID` and uniqueness, not a procedure address. `Open` requires
matching settings and rejects mismatches without changing the file. The caller
must ensure that an ID always identifies the same comparison rules; the module
cannot detect a different callback supplied with the same ID. Changing ordering
or uniqueness requires rebuilding the index.

### Ukrainian, Czech and German

`BPTOrder` also exports the following deterministic UTF-8 comparators:

| Case-sensitive / case-insensitive | IDs |
|---|---|
| `Ukrainian` / `UkrainianNoCase` | `UkrainianID = 3` / `UkrainianNoCaseID = 4` |
| `Czech` / `CzechNoCase` | `CzechID = 5` / `CzechNoCaseID = 6` |
| `German` / `GermanNoCase` | `GermanID = 7` / `GermanNoCaseID = 8` |

```oberon
ASSERT(B.Create(tree, "cities.db", TRUE,
                O.UkrainianNoCase, O.UkrainianNoCaseID));
ASSERT(B.Insert(tree, "Київ", 1));
ASSERT(B.Get(tree, "КИЇВ", value));  (* Same key. *)
ASSERT(B.Close(tree));
```

Ukrainian follows `абвгґдеєжзиіїйклмнопрстуфхцчшщьюя`.
Czech places `č`, `ř`, `š`, `ž` after their unaccented letters and treats
`ch` (including `CH`, `Ch`, `cH`) as one letter between `h` and `i`.
Other Czech accents are secondary: `a < á`, `e < é < ě`, `u < ú < ů`;
similarly for `ď`, `í`, `ň`, `ó`, `ť`, `ý`.
German uses dictionary-style grouping: `ä`, `ö`, `ü` have the primary weights
of `a`, `o`, `u`; `ß` and `ẞ` have the primary weights of two `s` letters.
Accents and sharp-s remain secondary distinctions: `a` and `ä`, or `ss` and
`ß`, are **different keys even with NoCase**. This is not phonebook ordering
(`ä` is not expanded to `ae`).

The entire primary sequence is compared before accents, then case. Thus `äb`
precedes `ac`. Case-sensitive variants put uppercase before lowercase when
the preceding comparison levels tie. NoCase ignores case, not accents.
The language-specific alphabets come first; other characters follow in scalar
order after the explicit case mappings (ASCII, Latin-1 and selected Cyrillic/
Czech letters). Punctuation is significant, and numbers sort lexically.

These are small, fixed application collations, **not full Unicode/CLDR
implementations**. Use precomposed text: no normalization is performed, so
`ä` and `a` followed by U+0308 are distinct. Combining marks and unsupported
letters use the fallback order. Comparators expect valid UTF-8, which BpTrees
validates for stored/input keys. Their behavior does not depend on the OS locale.
The general distinction between dictionary and phonebook collations is described
in the [Unicode collation FAQ](https://unicode.org/faq/collation.html).
Changing these rules in an application requires a new ID and index rebuild.

## Scanning entries

Declare `cursor: B.Cursor`, `key: ARRAY B.MaxKey + 1 OF CHAR`, and `value: INTEGER`.
Use `First` for a full scan:

```oberon
ASSERT(B.First(tree, cursor));
WHILE B.Next(tree, cursor, key, value) DO
    Out.String(key); Out.String(" = "); Out.Int(value, 0); Out.Ln
END;
ASSERT(B.Error(tree) = B.End);
```

For a lower-bound scan, replace `First` with `Seek(tree, "Smith", cursor)`.
It positions the cursor before the first key greater than or equal to the bound
according to the comparator. To enumerate one duplicate group:

```oberon
ASSERT(B.Seek(tree, "smith", cursor));
WHILE B.Next(tree, cursor, key, value) DO
    IF O.EnglishNoCase(key, "smith") # 0 THEN EXIT END;
    Out.Int(value, 0); Out.Ln
END;
ASSERT((B.Error(tree) = B.OK) OR (B.Error(tree) = B.End));
```

Use the tree's actual comparator when testing a range boundary. An empty string
need not sort first under a custom comparator, so use `First` for a full scan.

Successful mutations, including value replacement, invalidate existing cursors;
`Next` then reports `Stale`. Rejected duplicate insertions do not invalidate them.
Reads and other cursors do not interfere. Closing/reopening invalidates cursors.
Results are copied into caller-owned buffers, with no exposed page pointers.

## API reference

All operations below take `VAR tree: BpTree` first.

| Operation | Result and semantics |
|---|---|
| `Init(tree)` | Initialize a new record without allocating storage. |
| `Create(tree, path, unique, compare, orderID): BOOLEAN` | Create a new file; refuse an existing one. Not an atomic exclusive-create operation. |
| `Open(tree, path, unique, compare, orderID): BOOLEAN` | Validate format, configuration, and root; open for reading and writing. |
| `Close(tree): BOOLEAN` | Flush the header, close the file, and release workspace. Repeated closing is safe. Always check the result. |
| `Insert(tree, key, value): BOOLEAN` | Add a pair; return `Duplicate` for an equivalent key in a unique index. |
| `Put(tree, key, value): BOOLEAN` | Unique: insert or update. Nonunique: append a new pair. |
| `Get(tree, key, VAR value): BOOLEAN` | Read the oldest surviving equivalent key. Leave value unchanged on failure. |
| `Remove(tree, key): BOOLEAN` | Remove the oldest surviving equivalent key. |
| `RemoveValue(tree, key, value): BOOLEAN` | Remove the oldest equivalent key with this exact INTEGER value. |
| `RemoveAll(tree, key): INTEGER` | Remove all equivalent keys; return the number removed. Check `Error` even when the count is nonzero. |
| `Count(tree): INTEGER` | Number of pairs in an open, healthy tree, including duplicates. |
| `First(tree, VAR cursor): BOOLEAN` | Position before the first entry. |
| `Seek(tree, lower, VAR cursor): BOOLEAN` | Position at the lower bound; an empty result is not a positioning error. |
| `Next(tree, VAR cursor, VAR key, VAR value): BOOLEAN` | Read the next pair. A small key buffer does not advance the cursor. |
| `Error(tree): INTEGER` | Read the last operation's status. |

Status constants: `OK`, `NotFound`, `BadKey`, `IOError`, `Corrupt`, `Closed`,
`Exists`, `Limit`, `End`, `Stale`, `BufferSmall`, `Busy`, `BadPath`,
`ConfigMismatch`, `BadOptions`, and `Duplicate`.

A NIL comparator or an ID outside 1..2147483647 gives `BadOptions`. Ordinary
lookup, validation, and cursor errors allow subsequent operations. I/O errors,
detected page corruption, or exhaustion of the page limit disable further work
until close; closing such a tree fails and does not mark it clean. Exhausting the
duplicate serial counter rejects insertion before changing the tree, so reads
and deletions remain available.

## Data limits and storage

- Keys contain at most **240 UTF-8 bytes**, excluding NUL. Empty keys are valid.
  Input ends at the first NUL or the array length; an input terminator is optional.
  Output buffers need space for the terminator. Embedded NUL is not supported.
- UTF-8 is validated, including overlong encodings, surrogate code points,
  truncated sequences, and the U+10FFFF limit.
- Values cover the full native `INTEGER` range. The format records its width
  (4 or 8 bytes); opening a file with a different width is rejected.
- Paths are nonempty NUL-terminated strings of at most 255 bytes.
- Pages are 4096 bytes, with at most 15 keys per node and at least 7 in a nonroot
  node. All leaves have equal depth and are linked for sequential scans.
- The tree borrows or merges pages on deletion. Freed pages are reused, but
  **deletion does not shrink the file**. There is no pack or bulk-load operation.
- Each open tree allocates three work nodes, eight cached nodes, a page buffer,
  and a search path of at most 32 levels. There is no allocation per entry.
  Close releases this workspace; Files may retain buffers in its own pool.
- Search, insertion, and deletion visit O(height) pages. `RemoveValue` also
  scans the equivalent-key group. `RemoveAll` repeats balanced deletion.
- The file limit is 524287 pages, below 2 GiB, on both integer widths.

The cache is write-through to `Files`, which has its own buffering. Each file
must have one owner: no concurrent handles, threads, or processes may modify it.
There are no locks, transactions, WAL, or recovery from interrupted mutations.
Always check `Close`: a successful mutation alone does not guarantee persistence.
Open/Create mark the file unfinished; successful Close marks it clean. Checksums
and the clean flag detect some failures but do not provide atomicity or fsync.
Files does not expose system close/fsync errors; the module checks `Files.Ok`.

Open validates the header and root, not every page. Other corruption may be
reported when the affected page is read. This is not a hardened parser for
hostile files. The test suite independently audits the entire page graph.

## File format: DPB1 version 2

Numbers are little-endian; records are serialized explicitly. Page 0 is the
header; a zero page reference means no page. Version 1 is rejected and requires
export/rebuild with the old implementation.

The final four bytes of every page hold a u32 checksum. Start with `a=1, b=0`;
for bytes 0..4091, compute `a=(a+byte) MOD 251; b=(b+a) MOD 251`. Store `a+b*256`.
This detects accidental corruption and is not a cryptographic checksum.

Header fields are u32:

| Offset | Field |
|---|---|
| 0 | Magic bytes `DPB1` |
| 4 | Version: 2 |
| 8 | INTEGER width in bytes |
| 12 | Root page ID |
| 16 | Page count, including header |
| 20 | Free-list head |
| 24 | Entry count |
| 28 | Clean flag: 0 or 1 |
| 32 | Unique flag: 0 or 1 |
| 36 | Comparator ID |
| 40 | Next duplicate serial |

Node headers contain u32 kind at offset 0 (`1=leaf`, `2=branch`, `3=free`),
key count at 4, next leaf/free page at 8, and first child at 12. Key slots start
at offset 32 with a stride of 256 bytes:

| Slot offset | Field |
|---|---|
| +0 | UTF-8 byte length, u16 |
| +2 | Key bytes, up to 240 |
| +244 | Serial, u32; zero in unique indexes |
| +248 | Leaf: signed native-width value. Branch: right child ID, u32. |

Branch separators are lower bounds for the right subtree, ordered by
`(comparison result, serial)`; a separator need not remain an existing leaf key
after deletion. Branches do not use next, leaves do not use first child.
Free pages contain only kind and next-free ID. Unused bytes are zero.

## Tests: Oberon only

Source files and generated test database names follow DOS 8.3.

Build and run the full suite from the project root:

```sh
bin/m64oc samples/bptree/BPTAll.mod macos64 -l lib -out /tmp/bpttest -stk 2
chmod +x /tmp/bpttest
bpt_test_dir=$(mktemp -d /tmp/bptXXXXX)
(cd "$bpt_test_dir" && /tmp/bpttest)
```

The suite must finish with **`BpTrees ALL TESTS OK`**, with no `FAIL` or assertion
message. Do not rely on the process exit code alone. Use a fresh empty directory
for every run: tests create database snapshots and leave them for inspection.
Existing `tree.db` is deliberately not overwritten.

All test logic, including independent file decoding and damaged-file checks,
is written in Oberon. `BPTAll` calls these three modules:

| Module | Coverage |
|---|---|
| `BPTTest` | 12000 shuffled keys; 36000 deterministic model-checked operations; reopenings; UTF-8 and INTEGER boundaries; cursors; multiple trees; deletion, emptying, and page reuse. |
| `BPTOpts` | Both English comparators and a custom reverse comparator; configuration rejection without file changes; uniqueness and upsert; 2048 equivalent keys across multiple levels; duplicate pairs and removal by value. |
| `BPTAudit` | Independent decoding, checksums, UTF-8, ordering and expected contents; subtree bounds, equal leaf depth, leaf chain, free-list and orphan detection; 14 damaged-file cases. |

The audit uses its own comparison and ordered-entry model, preserving duplicates.
Its fixture limits are 16384 pages and 65536 serial slots; these are test limits,
not limits of the tree implementation. Test modules expose `Run`; use the combined
main module above to execute all checks in the required order.
