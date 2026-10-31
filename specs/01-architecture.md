# Pigeon — Architecture

Status: authoritative  
Scope: components, module boundaries, data flow, dependencies, concurrency  
Related: `00-overview.md`, `02-network-api.md`, `03-storage.md`, `04-server.md`, `05-client.md`

## 1. Shape of the system

Pigeon is one Cabal package with a shared library and two executables:

```
pigeon (library)
├── Pigeon.API          shared Servant API types
├── Pigeon.Types        shared domain types
├── Pigeon.Duration     duration parsing/formatting
├── Pigeon.Password     PBKDF2 password hashing wrapper
├── Pigeon.Streaming    gzip/ungzip, counting, Accept-Encoding
├── Pigeon.Config       shared option/env helpers
├── server modules      app monad, database, storage, handlers, web, sweeper, auth, log
└── client modules      API environment, commands, output

pigeon-server (executable)  -> app/Server.hs
pigeon-client (executable)  -> app/Client.hs
```

The API type is defined exactly once in `Pigeon.API` and imported by both binaries. Server handlers and client functions are derived from the same type, so a contract change fails to compile on one side.

## 2. Component responsibilities

| Component | Responsibility | Must not do |
| --- | --- | --- |
| `Pigeon.API` | Servant types, stream aliases, endpoint paths, media types | Contain business logic or database calls |
| `Pigeon.Types` | `FileId`, `FileInfo`, `StoredFile`, `Health`, error DTOs, JSON instances | Perform I/O |
| `Pigeon.Duration` | Parse `7d`, `1d12h`; format remaining time | Know about HTTP or files |
| `Pigeon.Password` | PBKDF2 hashing/verification via the `password` package | Read configuration or log secrets |
| `Pigeon.Streaming` | `gzip`/`ungzip` conduits, byte counters, `Accept-Encoding` parsing | Decide policy |
| `Pigeon.Server.App` | `App` reader monad over `AppEnv`, `MonadLogger` with `askLogger`, safe exception instances | Own configuration or open sockets |
| `Pigeon.Server.Config` | Parse/validate server flags and environment | Open sockets or files |
| `Pigeon.Server.Db` | SQLite connection, schema, migrations, queries | Stream blobs while holding the connection |
| `Pigeon.Server.PathSafety` | Symlink rejection, private directory creation, descriptor-based permissions | Choose storage policy or open network resources |
| `Pigeon.Server.Storage` | Temp files, atomic rename, blob streams, deletion | Authorize requests |
| `Pigeon.Server.Handlers` | Authenticated upload/list/delete/health handlers | Write HTML forms |
| `Pigeon.Server.Web` | `/f/:id` GET/HEAD/POST, HTML form, file streaming | Touch the metadata API endpoints |
| `Pigeon.Server.Sweeper` | Expiry deletion, orphan reconciliation | Block request handlers |
| `Pigeon.Server.Auth` | Bearer token parsing and constant-time check | Log the token |
| `Pigeon.Server.Log` | Request/application logging with redaction | Log headers, queries, passwords |
| `Pigeon.Client.Api` | HTTP manager, Servant client environment, error mapping | Format output |
| `Pigeon.Client.Commands` | Upload/list/delete orchestration | Parse global flags |
| `Pigeon.Client.Output` | Tables, JSON, progress, size/time formatting | Perform network I/O |

## 3. Shared types

```haskell
-- Pigeon.Types

newtype FileId = FileId { unFileId :: Text }
  deriving (Eq, Ord, Show)

data FileInfo = FileInfo
  { fiId          :: FileId
  , fiFilename    :: Text
  , fiSize        :: Int64
  , fiContentType :: Text
  , fiCreatedAt   :: UTCTime
  , fiExpiresAt   :: UTCTime
  , fiHasPassword :: Bool
  , fiUrl         :: Text
  }

data Health = Health
  { healthStatus  :: Text
  , healthVersion :: Text
  }

data ApiError = ApiError
  { aeCode    :: Text
  , aeMessage :: Text
  }

newtype ApiErrorEnvelope = ApiErrorEnvelope { unApiErrorEnvelope :: ApiError }

data StoredFile = StoredFile
  { sfId           :: FileId
  , sfFilename     :: Text
  , sfContentType  :: Text
  , sfSize         :: Int64
  , sfStoredSize   :: Int64
  , sfPasswordHash :: Maybe Text   -- encoded PBKDF2 hash text, or Nothing
  , sfCreatedAt    :: UTCTime
  , sfExpiresAt    :: UTCTime
  }
```

`sfPasswordHash` is the exact `PasswordHash PBKDF2` text returned by the `password` package. It is opaque outside the storage/web layers and is never exposed by the API.

`FileInfo` JSON uses the field names in `02-network-api.md`. `UTCTime` is serialized as RFC3339 UTC with a literal `Z`.

## 4. Streaming types

All file bodies use one alias:

```haskell
-- Pigeon.API
type UploadBody = ConduitT () ByteString (ResourceT IO) ()
```

The API imports `Servant.Conduit ()` so the orphan `ToSourceIO`/`FromSourceIO` instances for `ConduitT` are in scope on both client and server.

Why `ResourceT IO`:

- `Data.Conduit.Combinators.sourceFile`/`sinkFile` require `MonadResource`.
- `servant-conduit` provides the `ToSourceIO`/`FromSourceIO` instances for `ConduitT ... (ResourceT IO) ()`.
- `servant` 0.20 `StreamBody` server handlers receive the stream argument and client calls send it, so no whole-body buffering is needed.

`Pigeon.Streaming` provides:

```haskell
gzipConduit :: ConduitT ByteString ByteString (ResourceT IO) ()
ungzipConduit :: ConduitT ByteString ByteString (ResourceT IO) ()

countBytes :: IORef Int64 -> ConduitT ByteString ByteString (ResourceT IO) ()
-- Increments the ref for every chunk and passes the chunk through unchanged.

data AcceptEncoding = AcceptGzip | AcceptIdentity | NotAcceptable

parseAcceptEncoding :: ByteString -> AcceptEncoding
```

Use `Data.Conduit.Zlib` (`gzip`, `ungzip`) from `conduit-extra`. Do not use lazy `Codec.Compression.GZip` on file content.

## 5. Upload data flow

```
client file
  │  sourceHandle (64 KiB chunks)
  ▼
countBytes (original size + progress)
  │
  ├─ compression enabled? ── yes ──▶ gzipConduit ──▶ Content-Encoding: gzip
  │                        └ no  ──▶ identity
  ▼
HTTP request body (chunked)
  │
  ▼
server handler
  │  auth check before consuming body
  │  validate filename, expiry, content type, password
  ▼
  ├─ Content-Encoding: gzip ──▶ sinkFile temp (bytes as received)
  │                              │
  │                              └─ second streaming pass: ungzip + count original
  │                                 (validates gzip, computes size_original)
  │
  └─ identity ─────────────────▶ countBytes + gzipConduit + sinkFile temp
  ▼
temp file is gzip; fsync temp; rename to files/<id>.gz; fsync files/
  ▼
insert metadata row (short transaction, committed)
  ▼
201 FileInfo
```

The temp file is always written under `data/tmp/` on the same filesystem as `data/files/`. `renameFile` is therefore atomic. A failed temp-file fsync aborts before the rename; a failed directory fsync removes the renamed blob and aborts. Only a recognised unsupported-directory-fsync result warns once and continues. In every failure case the temp file or renamed blob is removed and no metadata row is committed.

## 6. Download data flow

```
GET/HEAD /f/:id
  │
  ├─ lookup live row (short DB read, release lock)
  ├─ no row / expired ──▶ 404
  ├─ password set and GET ──▶ HTML form
  ├─ POST with password ──▶ verify PBKDF2 ──▶ wrong: 401 form
  │                                      └ correct: continue
  ▼
Accept-Encoding gzip?
  ├─ yes ──▶ sourceFile files/<id>.gz ──▶ responseStream (Content-Encoding: gzip)
  └─ no  ──▶ sourceFile .| ungzipConduit ──▶ responseStream (identity)
```

The file handle is opened only after the DB row is fetched and the lock is released. A concurrent delete may unlink the path; on POSIX, an already-open handle continues to stream. If the open fails because the blob is missing, return `404` and log the inconsistency.

## 7. Concurrency model

- Warp runs handlers concurrently.
- There is exactly one SQLite `Connection`, guarded by `MVar Connection`.
- All metadata operations are short. **Never** hold the `MVar` while consuming a request body, writing a blob, or streaming a response.
- Upload writes happen outside the lock; the final insert takes the lock briefly.
- Deletion commits the row removal first, then unlinks the blob outside the lock. Orphan cleanup handles an unlink failure.
- The sweeper is a single background thread. It performs a short delete transaction, then unlinks blobs outside the lock.
- Request handlers never wait for the sweeper.
- `MVar` contention is acceptable because the service is low-throughput and SQLite serializes writes anyway.
- **ARCH-015** Both executables are linked with the default RTS options `-N -A16m`. The threaded RTS therefore uses every available capability, so concurrent compression, decompression, and TLS work is not serialized on one core, and each capability gets a 16 MiB allocation area to reduce minor-GC frequency on streaming paths. A single upload or download still runs on one capability. Operators may override the defaults with `+RTS`, for example `+RTS -N2` in a CPU-quota-limited container or `+RTS -A4m` to reduce resident memory.

## 8. Server startup and shutdown order

Startup:

1. Parse and validate `ServerConfig`.
2. Create `<data-dir>`, `<data-dir>/files`, `<data-dir>/tmp` with mode `0700` where supported.
3. Open SQLite; apply pragmas; run migrations.
4. Reconcile: remove stale temp files, remove old orphan blobs, delete rows whose blob is missing.
5. Start the sweeper thread.
6. Install `SIGINT`/`SIGTERM` handlers.
7. Run Warp (plain) or Warp-TLS.
8. Log the listening address, TLS state, data directory, default expiry, and maximum expiry. Never log the token.

Shutdown:

1. Stop accepting new connections.
2. Wait up to 30 seconds for in-flight requests.
3. Stop the sweeper and wait for its current iteration.
4. Close the SQLite connection.
5. Exit `0`.

If startup validation fails, print a single error to stderr and exit `1` without opening a socket.

## 9. Dependency choices

These are the intended primary dependencies. Use caret/lower-bound constraints compatible with GHC 9.14.1. Do not replace a dependency without updating this spec.

| Dependency | Use | Why |
| --- | --- | --- |
| `servant` 0.20.3 | API types, `StreamBody`, `Raw` | Shared typed contract |
| `servant-server` 0.20.3 | Server handlers | Same API type |
| `servant-client` 0.20.3 | Client calls, including streaming upload | Same API type |
| `servant-conduit` 0.16.1 | `ConduitT` stream instances | Avoid hand-written `SourceIO` adapters |
| `conduit` / `conduit-extra` | File sources/sinks, gzip | Constant-memory streaming |
| `resourcet` | `ResourceT` for stream resources | Required by conduit file functions |
| `warp` / `warp-tls` | HTTP and TLS server | Standard Servant backend |
| `sqlite-simple` | SQLite access | Small, direct, parameterized SQL |
| `aeson` | JSON DTOs | Servant JSON |
| `optparse-applicative` | CLI parsing | Required stack |
| `blaze-html` | Password form | Safe HTML escaping |
| `password` 3.1.1.0 | PBKDF2-HMAC-SHA512 password hashing | Requested password library; established PBKDF2 implementation |
| `base64` 1.0.x | Base64url password header | Correct unpadded URL-safe encoding |
| `crypton` 1.1.x | `Crypto.Random.getRandomBytes` | Maintained successor to `cryptonite` |
| `ram` 0.22.x | `Data.ByteArray.constEq` | Constant-time token comparison |
| `ulid` | `Data.ULID.Base32` for Crockford base32 file ids | ULID generation, timestamps, randomness |
| `http-client` / `http-client-tls` | Client manager and TLS | Streaming HTTP client |
| `wai` / `wai-extra` | `Response`, `responseStream`, optional gzip middleware | Server response control |
| `fast-logger` | Application/request logs | Structured, redacted logging |
| `safe-exceptions` | Exception handling in `App` and IO | Avoid catching asynchronous exceptions |
| `unix` | Signals, file modes | Graceful shutdown, permissions |

`crypton` is the maintained successor to `cryptonite`; `cryptonite` is deprecated and must not be added. `ram` supplies `Data.ByteArray.constEq`. `password` is used only for PBKDF2; its `bcrypt`, `argon2`, and `scrypt` flags are disabled in `cabal.project` to avoid pulling unused algorithms. `ulid` supplies only `Data.ULID.Base32` for encoding file ids; validation stays in `Pigeon.Types.isValidFileId`, because Crockford decoding accepts the ambiguous `i`, `l`, `o`, and `u` aliases that Pigeon rejects.

`password` 3.1.1.0's default backend uses `crypton` 1.1.x and `ram`; do not enable the `cryptonite` flag.

Use a `cabal.project` stanza to compile only the PBKDF2 algorithm:

```cabal
package password
  flags: +pbkdf2 -bcrypt -argon2 -scrypt -cryptonite
```

The `pbkdf2` flag is explicitly enabled; the other algorithm flags are disabled.

### 9.1 TLS/crypton pin

`password` 3.1.1.0 requires `crypton >= 1.1 && < 1.2`. The current `tls` release requires `crypton >= 2.1`, so the TLS stack is pinned to the last generation that shares `crypton` 1.1:

```cabal
constraints: tls ==2.3.0, tls-session-manager <0.1.2
allow-newer: serialise:base, cborg:base
```

`crypton-connection` is constrained to `>= 0.4.6 && < 0.5` because 0.4.6 accepts `tls >= 2.3 && < 2.5`. Do not relax these pins without a dependency review; the alternative is dropping `password`'s PBKDF2 backend, which the security spec forbids.

- **ARCH-020** `cabal.project` pins `tls`, `tls-session-manager`, and `crypton-connection` as above so `password` and `warp-tls` resolve against one `crypton` generation.
- **ARCH-021** If a future `password` release supports `crypton >= 2.1`, update this section and remove the pins in the same change.

## 10. Package layout

```cabal
library
  hs-source-dirs: src
  exposed-modules:
      Pigeon.API
      Pigeon.Types
      Pigeon.Duration
      Pigeon.Password
      Pigeon.Streaming
      Pigeon.Config
      Pigeon.Server.Config
      Pigeon.Server.Db
      Pigeon.Server.PathSafety
      Pigeon.Server.Storage
      Pigeon.Server.App
      Pigeon.Server.Env
      Pigeon.Server.Handlers
      Pigeon.Server.Web
      Pigeon.Server.Sweeper
      Pigeon.Server.Auth
      Pigeon.Server.Log
      Pigeon.Server
      Pigeon.Client.Config
      Pigeon.Client.Api
      Pigeon.Client.Commands
      Pigeon.Client.Output
      Pigeon.Client

executable pigeon-server
  hs-source-dirs: app
  main-is: Server.hs
  build-depends: pigeon, base, optparse-applicative

executable pigeon-client
  hs-source-dirs: app
  main-is: Client.hs
  build-depends: pigeon, base, optparse-applicative

test-suite pigeon-test
  type: exitcode-stdio-1.0
  hs-source-dirs: test
  main-is: Spec.hs
```

Executables are thin: parse arguments, call `Pigeon.Server.run` or `Pigeon.Client.run`, map the result to an exit code. Business logic lives in the library so it can be tested.

## 11. Configuration model

- Both binaries use `optparse-applicative` and environment fallbacks.
- Server options are validated once, producing a `ServerConfig` with parsed values (`UTCTime` durations converted to seconds, `HostPreference`, `Port`, normalized `BaseUrl`).
- Client options are validated once, producing a `ClientConfig` with a normalized base URL, resolved token, timeout, and TLS mode.
- No configuration file is read in v1.
- Precedence for secrets: command-line flag, then file, then environment. Conflicting command-line sources are a usage error.

## 12. Error boundaries

| Layer | Error type | Converted to |
| --- | --- | --- |
| CLI parsing | `optparse-applicative` failure | Usage message, exit `2` |
| Duration/filename validation | `Either Text a` | `400 invalid_request` or client usage error |
| Password hashing | `Either Text StoredPasswordHash` | `400` on malformed submitted input; `500` for a corrupt stored hash |
| SQLite | `SqlError` | `500 internal_error`; details logged |
| Filesystem | `IOException` | `500` (or `404` for a missing blob on download); details logged |
| Servant client | `ClientError` | Mapped to documented client exit codes |
| Web form | `Either FormError` | HTML `400`/`401`/`413` |

No layer returns a raw exception message to an HTTP client.

## 13. Application monad and logging

All server orchestration runs in `App`, a reader monad over `AppEnv`. Handlers, web requests, the sweeper, and reconciliation must not thread `AppEnv` or `Logger` through every function by hand.

```haskell
-- Pigeon.Server.App

newtype App a = App
  { unApp :: ExceptT ServerError (ReaderT AppEnv IO) a
  }

class Monad m => MonadLogger m where
  askLogger :: m Logger

instance MonadLogger App where
  askLogger = asks aeLogger

runApp :: AppEnv -> App a -> IO (Either ServerError a)
```

- **ARCH-009** `App` derives `MonadIO`, `MonadReader AppEnv`, `MonadError ServerError`, and the `safe-exceptions` classes `MonadThrow`, `MonadCatch`, and `MonadMask`.
- **ARCH-010** Application code obtains the logger through `askLogger`; it does not take a `Logger` argument merely to pass it down.
- **ARCH-011** Pure IO layers that must remain testable in IO (`Pigeon.Server.Db`, `Pigeon.Server.Storage`) are called from `App` with `liftIO`; they do not import `Pigeon.Server.App`.
- **ARCH-012** The Servant API handlers are written as `ServerT FullAPI App` and hoisted to `Handler` with `hoistServer`. The raw `/f/:id` route is an `Application` that runs each request through `runApp`.
- **ARCH-013** All exception handling uses `Control.Exception.Safe`. Do not import `Control.Exception` in server or client modules.
- **ARCH-014** `App` failures are `ServerError`; converting an `App` action back to IO yields `Either ServerError a`, which the natural transformation turns into a Servant `Handler`.

## 14. Architecture acceptance criteria

- **ARCH-001** `Pigeon.API` is the only module that defines endpoint paths and the upload body type.
- **ARCH-002** `pigeon-server` and `pigeon-client` compile against the same `PigeonAPI` type.
- **ARCH-003** No module in `src/Pigeon/Server` uses `BS.readFile`, `readFile`, or `strictRequestBody` for file content.
- **ARCH-004** The SQLite `MVar` is not held during any `ConduitT` run or `responseStream`.
- **ARCH-005** `servant-conduit` instances are imported exactly once in the shared API module, and both executables build without orphan-instance warnings.
- **ARCH-006** The client uses `--no-compress` only to change the request encoding; the server still stores gzip.
- **ARCH-007** Killing the process during an upload leaves either no row and no final blob, or a row with a valid blob. It never leaves a row pointing at a partial final blob.
- **ARCH-008** The only browser-facing HTML is the password form and small error pages; there is no management UI.
