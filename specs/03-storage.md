# Pigeon — Storage

Status: authoritative  
Scope: filesystem layout, SQLite schema, durability, compression at rest, expiry, cleanup  
Related: `01-architecture.md`, `02-network-api.md`, `04-server.md`, `06-security.md`

## 1. Storage principles

- **STORE-001** Metadata lives in SQLite. Blobs live on the filesystem. No blob bytes are stored in SQLite.
- **STORE-002** Every blob is gzip-compressed on disk.
- **STORE-003** Every metadata row has a non-null `expires_at`.
- **STORE-004** A blob path is derived only from a server-generated file ID. User filenames never become paths.
- **STORE-005** Uploads are written to a temp file and atomically renamed into the blob directory only after the write succeeds.
- **STORE-006** A metadata row is committed only after the final blob exists.
- **STORE-007** Committed metadata must be durable in the main SQLite database file. WAL mode is explicitly not used.
- **STORE-008** The SQLite lock is never held while streaming a request body, writing a blob, or streaming a response.

## 2. Filesystem layout

```
<data-dir>/
├── pigeon.db                 SQLite database (rollback journal mode)
├── pigeon.db-journal         transient, only during a write transaction
├── files/
│   ├── 7q3m9x2k4v8p1c6d.gz
│   └── ...
└── tmp/
    ├── 7q3m9x2k4v8p1c6d.a1b2c3d4.part
    └── ...
```

- **STORE-010** `<data-dir>` defaults to `./data` but is configurable with `--data-dir`.
- **STORE-011** The database path defaults to `<data-dir>/pigeon.db` and can be overridden with `--db`.
- **STORE-012** Blob files are `<data-dir>/files/<id>.gz`.
- **STORE-013** Temp files are `<data-dir>/tmp/<id>.<random>.part`.
- **STORE-014** `files/` and `tmp/` MUST be on the same filesystem. At startup, compare their device IDs; refuse to start if they differ.
- **STORE-015** The server creates `<data-dir>`, `files/`, and `tmp/` with mode `0700` where the platform supports it.
- **STORE-016** Blob and database files are created with mode `0600` where the platform supports it.
- **STORE-017** The server resolves the data directory to an absolute path at startup and uses that path for all operations.
- **STORE-018** The server does not follow symlinks when opening blobs, storage directories, or the database. Use `O_NOFOLLOW` (`nofollow = True`) where available.
- **STORE-019** Every component of the configured data directory, `files/`, `tmp/`, database parent, and database path MUST be symlink-free. Existing directories must be real directories, and the database parent must not be writable by group or other users. Startup fails rather than changing permissions through a symlink or using an untrusted database parent. Missing directories are created with mode `0700` before the database is opened.

## 3. SQLite configuration

Apply these pragmas when opening the connection:

```sql
PRAGMA journal_mode = DELETE;
PRAGMA synchronous = FULL;
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;
```

- **STORE-020** Do not enable WAL. WAL keeps recent commits in a separate `-wal` file and defers checkpointing; Pigeon requires committed transactions to be reflected in the main database file.
- **STORE-021** `synchronous=FULL` is required. Do not lower it to `NORMAL` or `OFF`.
- **STORE-022** Use `journal_mode=DELETE` (rollback journal). The journal is transient and removed after a successful commit.
- **STORE-023** There is exactly one `sqlite-simple` `Connection`, guarded by `MVar Connection`.
- **STORE-024** Write operations use `BEGIN IMMEDIATE` so lock acquisition happens at transaction start, not at the first write.
- **STORE-025** A failed transaction is rolled back and the exception is propagated as a storage error. Never commit a partially written row.
- **STORE-026** `busy_timeout=5000` is a safety net; with a single connection it should not normally be hit.

### 3.1 Why not WAL

WAL improves concurrent read/write throughput, but a commit can remain in `pigeon.db-wal` until a checkpoint. The operator expectation for Pigeon is that a committed upload is present in `pigeon.db` after the `201` response and after a crash. `journal_mode=DELETE` plus `synchronous=FULL` gives that behavior with simpler backup and inspection semantics. The service is low-throughput, so the write cost is acceptable.

## 4. Schema

```sql
CREATE TABLE IF NOT EXISTS files (
    id           TEXT    PRIMARY KEY NOT NULL,
    filename     TEXT    NOT NULL,
    content_type TEXT    NOT NULL,
    size_original INTEGER NOT NULL CHECK (size_original >= 0),
    size_stored  INTEGER NOT NULL CHECK (size_stored >= 0),
    password_hash TEXT,
    created_at   INTEGER NOT NULL,
    expires_at   INTEGER NOT NULL,
    CHECK (expires_at > created_at),
    CHECK (password_hash IS NULL OR length(password_hash) > 0)
);

CREATE INDEX IF NOT EXISTS idx_files_expires_at
    ON files (expires_at);

CREATE INDEX IF NOT EXISTS idx_files_created_at
    ON files (created_at DESC);

PRAGMA user_version = 1;
```

- **STORE-030** `id` is the 16-character lowercase Crockford base32 ID. It is the primary key.
- **STORE-031** `filename` is the sanitized display name, stored as UTF-8 text.
- **STORE-032** `content_type` is the sanitized content type, stored as ASCII text.
- **STORE-033** `size_original` is the uncompressed byte length. It is at least 0.
- **STORE-034** `size_stored` is the gzip blob length. It is at least 0.
- **STORE-035** `password_hash` is `NULL` when the file has no password. Otherwise it uses the format in section 5.
- **STORE-036** `created_at` and `expires_at` are Unix epoch seconds in UTC, stored as SQLite `INTEGER`.
- **STORE-037** `expires_at` MUST be strictly greater than `created_at`.
- **STORE-038** The expiry index supports the sweeper and the live-list query.
- **STORE-039** The creation index supports newest-first listing.

## 5. Password hash format

`password_hash` is the exact self-describing text produced by `Data.Password.PBKDF2`:

```
<algorithm>:<iterations>:<base64-salt>:<base64-key>
```

Example from the `password` package documentation (PBKDF2-HMAC-SHA512, 25000 iterations; production uses the configured count):

```
sha512:25000:YWJjZGVmZ2hpamtsbW5vcA==:JRElYYrOMe9OIV4LDxaLTgO9ho8fFBVofXoQcdngi7AcuH6Amvmlj2B0y6y1UtQciXXBepSCS+rpy8/vDDQvoA==
```

- **STORE-040** The algorithm field is `sha512` for all hashes created by Pigeon v1.
- **STORE-041** `iterations` is a base-10 integer. New hashes use `100000 .. 10000000` from configuration. Verification accepts `1 .. 100000000` so older hashes remain verifiable, with a hard cap to bound work.
- **STORE-042** The salt field is standard Base64 with padding, decoding to 16 bytes.
- **STORE-043** The key field is standard Base64 with padding, decoding to 64 bytes.
- **STORE-044** The value is stored exactly as produced and parsed by the `password` package; do not re-encode or shorten it.
- **STORE-045** `password` package hashes include the algorithm, iteration count, and salt, so future parameter changes do not break old files.
- **STORE-046** Hashing and verification are defined in `06-security.md`. Do not duplicate the PBKDF2 implementation in the storage layer.

## 6. File ID rules

- **STORE-050** IDs are 16 characters from the lowercase Crockford base32 alphabet: `0123456789abcdefghjkmnpqrstvwxyz`.
- **STORE-051** The alphabet excludes `i`, `l`, `o`, and `u` to avoid visual ambiguity.
- **STORE-052** IDs carry 80 random bits, generated from 10 bytes of `Crypto.Random.getRandomBytes`.
- **STORE-053** IDs match `^[0-9a-hjkmnp-tv-z]{16}$`.
- **STORE-054** Generation retries on collision up to 5 times.
- **STORE-055** If the database insert fails with a unique-constraint violation, the just-renamed blob is unlinked and the upload is retried with a new ID, up to the retry limit.
- **STORE-056** IDs are opaque to clients. They are not sequential and carry no metadata.

## 7. Upload storage pipeline

### 7.1 Inputs

```haskell
data StoreRequest = StoreRequest
  { srFilename        :: Text
  , srContentType     :: Text
  , srExpiresAt       :: UTCTime
  , srPasswordHash    :: Maybe Text       -- encoded PBKDF2 hash text, or Nothing
  , srContentEncoding :: Maybe ByteString -- Nothing / "identity" / "gzip"
  , srMaxUploadSize   :: Int64           -- 0 = unlimited
  , srBody            :: UploadBody
  }
```

`UploadBody` is `ConduitT () ByteString (ResourceT IO) ()` from `Pigeon.API`.

### 7.2 Algorithm

1. **STORE-060** Generate a candidate `FileId`.
2. **STORE-061** Create a temp file `tmp/<id>.<random>.part` with mode `0600`, opened with `O_NOFOLLOW` and exclusive create.
3. **STORE-062** If `srContentEncoding` is `gzip`:
   - Stream the request body into the temp file exactly as received.
   - Count received (stored) bytes.
   - If `max_upload_size > 0` and received bytes exceed it, abort with `payload_too_large`.
   - After the body ends, stream the temp file through `ungzip` into a counting sink.
   - If `ungzip` throws, abort with `invalid_request` (bad gzip).
   - If `max_upload_size > 0` and the decompressed byte count exceeds it, abort with `payload_too_large`.
   - The decompressed count is `size_original`.
4. **STORE-063** If `srContentEncoding` is absent or `identity`:
   - Stream the request body through a counter, then through `gzip` (level 6), then into the temp file.
   - Count original bytes before compression.
   - Enforce `max_upload_size` against original bytes while streaming.
   - After the body ends, `size_stored` is the temp file size.
5. **STORE-064** Flush and close the temp handle.
6. **STORE-065** `fsync` the temp file with `fileSynchronise`. Failure aborts the upload, removes the temp file, and commits no metadata row. The descriptor is closed on both success and failure; a close error must never mask the synchronization error.
7. **STORE-066** Atomically rename the temp file to `files/<id>.gz`.
8. **STORE-067** `fsync` the `files/` directory before inserting metadata. If opening or synchronizing the directory fails with any ordinary I/O error, remove the renamed blob, do not insert, and return a storage error. Only an error that explicitly means the platform does not support directory fsync (`EINVAL`/`EOPNOTSUPP`, surfaced as `InvalidArgument`/`UnsupportedOperation`) takes the documented exception path: log one warning per process and continue with the documented reduced crash durability. Do not treat every `IOException` as unsupported. If the post-rename cleanup itself fails, log the orphan blob ID for later reconciliation and still do not insert a row.
9. **STORE-068** Insert the metadata row in a `BEGIN IMMEDIATE` transaction and commit.
10. **STORE-069** Return the `StoredFile` with `size_original`, `size_stored`, and the final path.

If any step before the rename fails, remove the temp file. If the insert fails after the rename, remove the final blob and return an error. If the process crashes between rename and insert, the orphan sweeper removes the blob after the grace period.

### 7.3 Why a second pass for gzip uploads

The client sends compressed bytes. The server must know the original size for listing and for the upload-size policy. The gzip trailer's `ISIZE` field is only 32-bit and is not reliable for files larger than 4 GiB. A single streaming decompression pass after the write is simple, validates the gzip stream, and keeps memory constant. The extra read is acceptable for a low-throughput service.

### 7.4 Size limits

- **STORE-070** `max_upload_size = 0` means unlimited.
- **STORE-071** When non-zero, the limit applies to both:
  - the number of bytes received (stored/compressed), and
  - the number of decompressed original bytes.
- **STORE-072** Exceeding either limit returns `413 payload_too_large` and removes the temp file.
- **STORE-073** The limit is checked while streaming, not after buffering the whole body.

## 8. Download storage pipeline

- **STORE-080** `openBlob` resolves the path from `FileId`, opens it with `O_NOFOLLOW`, and returns a binary handle.
- **STORE-081** The caller wraps the handle in `sourceHandle` inside `ResourceT`, so the handle closes on success, exception, or client disconnect.
- **STORE-082** The download handler releases the database lock before calling `openBlob`.
- **STORE-083** A missing blob for a live row returns `404` and logs an inconsistency. The row is removed by reconciliation later.
- **STORE-084** Gzip passthrough streams the file bytes unchanged.
- **STORE-085** Identity download runs the file through `ungzip` before sending.
- **STORE-086** No download path may call `BS.readFile` or otherwise materialize the blob.

## 9. Deletion

### 9.1 API delete

1. **STORE-090** Look up the row by ID. If absent, return `not_found`.
2. **STORE-091** Delete the row in a `BEGIN IMMEDIATE` transaction and commit.
3. **STORE-092** Unlink `files/<id>.gz` outside the database lock.
4. **STORE-093** If unlink fails because the file is missing, treat it as success.
5. **STORE-094** If unlink fails for another reason, log a warning and return success; the orphan sweeper retries.
6. **STORE-095** An in-flight download on POSIX keeps its open handle and may finish after the unlink. New requests get `404`.

### 9.2 Expiry delete

The sweeper follows the same order: commit row deletion first, then unlink blobs.

## 10. Expiry and sweeper

- **STORE-100** `expires_at` is computed by the server as `now + lifetime`, where `lifetime` is `expires_in` if supplied or `default_expiry` otherwise.
- **STORE-101** All comparisons use the server's UTC clock.
- **STORE-102** The sweeper runs every `sweep_interval` (default `60s`, minimum `1s`).
- **STORE-103** Each sweep:
  1. Computes `now`.
  2. Selects IDs with `expires_at <= now`.
  3. Deletes those rows in one `BEGIN IMMEDIATE` transaction and commits.
  4. Unlinks the corresponding blobs outside the lock.
  5. Logs the number of rows and blobs removed, plus unlink failures.
- **STORE-104** A sweeper exception is logged and does not terminate the process. The next interval retries.
- **STORE-105** Download and list handlers independently treat `expires_at <= now` as gone, regardless of sweeper state.

### 10.1 Orphan reconciliation

- **STORE-110** At startup, remove temp files older than 24 hours.
- **STORE-111** At startup, list `files/*.gz`, parse IDs from filenames, and remove blobs that have no metadata row and whose mtime is older than 1 hour.
- **STORE-112** At startup, delete metadata rows whose blob is missing. Log each removed ID.
- **STORE-113** During normal sweeps, remove old orphan blobs with the same 1-hour grace period.
- **STORE-114** During normal sweeps, remove temp files older than 24 hours.
- **STORE-115** The grace period prevents deleting a blob that was renamed just before its metadata insert, and prevents deleting a temp file from a long-running upload.
- **STORE-116** Orphan cleanup must never delete a blob whose ID is present in the database, even if the row is expired; expiry deletion is handled by the expiry path.

## 11. Consistency guarantees

- **STORE-120** A successful `201` implies:
  - the final blob exists and is readable,
  - the metadata row is committed,
  - `size_original` and `size_stored` match the stored content,
  - the temp-file fsync and the `files/` directory fsync completed, or the recognised unsupported-directory-fsync path was taken.
- **STORE-121** A crash before the rename leaves a temp file and no row. Startup removes the temp file after 24 hours.
- **STORE-122** A crash after the rename but before the insert leaves an orphan blob and no row. The sweeper removes it after 1 hour.
- **STORE-123** A crash during the insert leaves either no row or a fully committed row; SQLite rollback journal guarantees no partial row.
- **STORE-124** A crash after the commit but before the response leaves a complete file; the client may retry and create a second file. That is acceptable; there is no idempotency key in v1.
- **STORE-125** A temp-file fsync failure or an ordinary directory-open/directory-fsync failure never produces a committed metadata row or a successful upload response. The failure maps to the existing generic `500 internal_error`, while the detailed cause is logged server-side.
- **STORE-126** If post-rename cleanup cannot remove the blob, the upload still fails and inserts no row; the orphan blob ID is logged and the orphan sweeper removes the blob after its grace period.

## 12. Database API

The storage layer exposes a small, testable interface:

```haskell
data Storage = Storage
  { stRoot           :: FilePath
  , stFilesDir       :: FilePath
  , stTmpDir         :: FilePath
  , stHooks          :: StorageHooks   -- injectable sync/removal/log primitives
  , stDirSyncWarned  :: IORef Bool     -- warn-once state for STORE-067
  }

data DirSyncResult = DirSyncSucceeded | DirSyncUnsupported

data StorageHooks = StorageHooks
  { shSyncFile   :: FilePath -> IO ()
  , shSyncDir    :: FilePath -> IO DirSyncResult
  , shRemoveBlob :: FilePath -> IO ()
  , shWarn       :: Text -> IO ()
  , shError      :: Text -> IO ()
  }

initStorage :: StorageHooks -> FilePath -> IO Storage

data Db

data StorageError
  = StorageTooLarge
  | StorageBadGzip
  | StorageIdCollision
  | StorageIo Text
  | StorageCorrupt Text

openDb  :: FilePath -> IO Db
closeDb :: Db -> IO ()

migrate :: Db -> IO ()

storeUpload :: Storage -> Db -> StoreRequest -> IO (Either StorageError StoredFile)

insertFile     :: Db -> StoredFile -> IO ()
lookupFile     :: Db -> FileId -> IO (Maybe StoredFile)
listLiveFiles  :: Db -> UTCTime -> IO [StoredFile]
deleteFileRow  :: Db -> FileId -> IO Bool
expiredIds     :: Db -> UTCTime -> IO [FileId]
allIds         :: Db -> IO (Set FileId)
deleteRowsMissingBlob :: Db -> (FileId -> IO Bool) -> IO [FileId]
```

- **STORE-130** All functions take the `MVar` internally for the shortest possible time.
- **STORE-131** `listLiveFiles` filters `expires_at > now` in SQL, not in Haskell.
- **STORE-132** `deleteFileRow` returns `True` if a row was deleted.
- **STORE-133** Database rows are mapped to `StoredFile` without exposing `password_hash` in API responses.
- **STORE-134** `migrate` is idempotent. It reads `PRAGMA user_version`; version 0 creates the schema and sets 1; a version greater than 1 is a startup error.

## 13. Backup and inspection

- **STORE-140** The database and `files/` directory must be backed up together.
- **STORE-141** Copying `pigeon.db` while the server is writing is not a consistent backup. Stop the server or use SQLite's backup mechanism.
- **STORE-142** Blobs are immutable after creation; a backup may copy `files/` while the server is running, but the database must be captured consistently with it.
- **STORE-143** Operators can inspect blobs with `gzip -t` and `gzip -dc`; every blob must pass `gzip -t`.

## 14. Storage acceptance criteria

- **STORE-A01** `PRAGMA journal_mode` returns `delete`, and `PRAGMA synchronous` returns `2` (`FULL`).
- **STORE-A02** After a successful upload, `pigeon.db` contains the row without relying on a `-wal` file.
- **STORE-A03** Killing the server (`SIGKILL`) immediately after a `201` and reopening the database still shows the row.
- **STORE-A04** A gzip upload and an identity upload of the same bytes produce blobs whose `gzip -dc` output is identical to the input.
- **STORE-A05** An invalid gzip upload returns `400` and leaves no row and no final blob.
- **STORE-A06** An upload above `max_upload_size` returns `413` and leaves no row and no final blob, whether the limit is exceeded before or after decompression.
- **STORE-A07** A deleted file has no row and no final blob after the delete completes.
- **STORE-A08** The sweeper removes expired rows and blobs, and a download of an expired file returns `404` even before the sweep.
- **STORE-A09** A temp file and an orphan blob older than their grace periods are removed by reconciliation.
- **STORE-A10** A blob whose row is missing is not served; a row whose blob is missing returns `404` and is logged.
- **STORE-A11** `files/` and `tmp/` on different filesystems cause startup to fail with a clear error.
- **STORE-A12** Data directories and blobs have restrictive permissions on POSIX.
