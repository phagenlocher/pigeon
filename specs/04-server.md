# Pigeon — Server

Status: authoritative  
Scope: server configuration, TLS, lifecycle, handlers, web route, logging  
Related: `01-architecture.md`, `02-network-api.md`, `03-storage.md`, `06-security.md`

## 1. Server responsibilities

`pigeon-server`:

- Parses and validates configuration.
- Opens the data directory and SQLite database.
- Serves the authenticated metadata API.
- Serves the public download page and password form.
- Starts and stops the expiry sweeper.
- Logs requests and lifecycle events without secrets.
- Shuts down gracefully.

The server executable is thin:

```haskell
-- app/Server.hs
main :: IO ()
main = do
  cfg <- parseServerConfig
  runServer cfg
```

`runServer` lives in `Pigeon.Server` and is testable without spawning a process.

## 2. Configuration

### 2.1 Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--host` | `127.0.0.1` | Bind address (`HostPreference`). |
| `--port` | `8080` | TCP port. |
| `--data-dir` | `./data` | Root for database, blobs, and temp files. |
| `--db` | `<data-dir>/pigeon.db` | SQLite path override. |
| `--token` | none | Shared bearer token. |
| `--token-file` | none | File containing the bearer token on its first line. |
| `--tls-cert` | none | PEM certificate chain. |
| `--tls-key` | none | PEM private key (unencrypted). |
| `--no-tls` | off | Explicitly disable TLS for development. |
| `--public-url` | derived | Public base URL used to build share links. |
| `--default-expiry` | `7d` | Applied when an upload omits `expires_in`. |
| `--max-expiry` | `365d` | Upper bound for any expiry. |
| `--sweep-interval` | `60s` | Expiry sweep period. Minimum `1s`. |
| `--max-upload-size` | `0` | Maximum bytes; `0` means unlimited. Applies to stored and original bytes. |
| `--password-hash-iterations` | `600000` | PBKDF2 iterations for new password hashes. |
| `--quiet` | off | Suppress request logs; errors still logged. |
| `--verbose` | off | Enable debug logs. |
| `--version` | — | Print version and exit. |
| `--help` | — | Print usage and exit. |

### 2.2 Environment fallbacks

Each flag has an environment fallback. Command-line flags take precedence.

| Flag | Environment |
| --- | --- |
| `--host` | `PIGEON_HOST` |
| `--port` | `PIGEON_PORT` |
| `--data-dir` | `PIGEON_DATA_DIR` |
| `--db` | `PIGEON_DB` |
| `--token` | `PIGEON_TOKEN` |
| `--tls-cert` | `PIGEON_TLS_CERT` |
| `--tls-key` | `PIGEON_TLS_KEY` |
| `--public-url` | `PIGEON_PUBLIC_URL` |
| `--default-expiry` | `PIGEON_DEFAULT_EXPIRY` |
| `--max-expiry` | `PIGEON_MAX_EXPIRY` |
| `--sweep-interval` | `PIGEON_SWEEP_INTERVAL` |
| `--max-upload-size` | `PIGEON_MAX_UPLOAD_SIZE` |
| `--password-hash-iterations` | `PIGEON_PASSWORD_HASH_ITERATIONS` |

### 2.3 Token resolution

- **SRV-001** A token is mandatory. The server refuses to start without one.
- **SRV-002** Token sources are `--token`, `--token-file`, and `PIGEON_TOKEN`.
- **SRV-003** If both `--token` and `--token-file` are supplied, that is a usage error.
- **SRV-004** Precedence is command-line token, then token file, then environment.
- **SRV-005** The token must be 16–512 printable ASCII characters with no whitespace.
- **SRV-006** `--token-file` reads the first line, strips trailing `\r`/`\n`, and rejects an empty result.
- **SRV-007** The token is stored in a `Secret` newtype whose `Show` instance prints `<redacted>`.
- **SRV-008** The token is never written to logs, error messages, or the database.

### 2.4 Expiry policy

- **SRV-010** `--default-expiry` defaults to `7d`.
- **SRV-011** `--max-expiry` defaults to `365d`.
- **SRV-012** Both values must be greater than zero.
- **SRV-013** `default_expiry <= max_expiry` must hold; otherwise startup fails.
- **SRV-014** Uploads that omit `expires_in` use `default_expiry`.
- **SRV-015** Uploads that supply `expires_in` must be in `1 .. max_expiry_seconds`.
- **SRV-016** There is no "never expires" option. Every row has an `expires_at`.
- **SRV-017** The server uses its own UTC clock for `created_at` and `expires_at`.

### 2.5 Public URL

- **SRV-020** `--public-url` must be an absolute `http` or `https` URL with no query or fragment.
- **SRV-021** A trailing slash is removed during normalization.
- **SRV-022** If omitted, the default is:
  - `http://127.0.0.1:<port>` when TLS is disabled;
  - `https://127.0.0.1:<port>` when TLS is enabled.
- **SRV-023** If the default is used and `--host` is not a loopback address, log a warning that share links may be wrong.
- **SRV-024** `X-Forwarded-*` headers are not trusted. Behind a reverse proxy, set `--public-url` explicitly.
- **SRV-025** `FileInfo.url` is `<public-url>/f/<id>`.

### 2.6 Other validation

- **SRV-030** `--port` must be `1 .. 65535`.
- **SRV-031** `--sweep-interval` must be at least `1s`.
- **SRV-032** `--password-hash-iterations` must be `100000 .. 10000000`.
- **SRV-033** `--max-upload-size` is a non-negative integer byte count; `0` means unlimited.
- **SRV-034** `--no-tls` is mutually exclusive with `--tls-cert` and `--tls-key`.
- **SRV-035** If TLS is enabled, both `--tls-cert` and `--tls-key` are required and readable.
- **SRV-036** The database parent directory must exist or be creatable, must be owned by the service user or root, and must not be writable by group or other users.
- **SRV-037** The data directory must be writable; otherwise startup fails.
- **SRV-038** `files/` and `tmp/` must be on the same filesystem, and all configured storage and database path components must be symlink-free (see `03-storage.md`).
- **SRV-039** Configuration errors print one concise message to stderr and exit `1` (or `2` for argument parsing) without opening a socket.

## 3. TLS

- **SRV-040** TLS is enabled by default.
- **SRV-041** Use `warp-tls` with the certificate chain and key from configuration.
- **SRV-042** The key must be an unencrypted PEM private key. Encrypted keys are not supported in v1.
- **SRV-043** TLS certificate material is read once at startup. Rotation requires a restart.
- **SRV-044** Do not weaken `warp-tls` defaults (protocol versions, cipher suites).
- **SRV-045** `--no-tls` logs a prominent warning: `WARNING: TLS disabled; tokens and passwords are transmitted in plaintext`.
- **SRV-046** When the public URL is `https`, send `Strict-Transport-Security: max-age=31536000` on HTML and API responses.
- **SRV-047** A certificate/key read failure is a startup error.
- **SRV-048** The server does not request client certificates.

## 4. Warp settings

```haskell
settings =
  setPort (scPort cfg)
    . setHost (scHost cfg)
    . setServerName "pigeon"
    . setTimeout 300
    . setGracefulShutdownTimeout (Just 30)
    . setInstallShutdownHandler installShutdown
    . setOnException logWarpException
    $ defaultSettings
```

- **SRV-050** `setTimeout 300` is an idle/connection timeout in seconds. It must not cut off an active large upload or download.
- **SRV-051** Graceful shutdown waits up to 30 seconds for in-flight requests.
- **SRV-052** `SIGINT` and `SIGTERM` trigger graceful shutdown.
- **SRV-053** Warp exceptions are logged server-side without exposing details to clients.
- **SRV-054** The `Server` header is `pigeon`, not the Warp version.
- **SRV-055** The server binds only the configured host. The default loopback bind is intentional.

## 5. Application wiring

```haskell
data AppEnv = AppEnv
  { aeConfig  :: ServerConfig
  , aeDb      :: Db
  , aeStorage :: Storage
  , aeLogger  :: Logger
  , aeStart   :: UTCTime
  }

runServer :: ServerConfig -> IO ()
mkApp    :: AppEnv -> Application
```

All server orchestration runs in `App` (`Pigeon.Server.App`), a reader monad over `AppEnv` with `MonadIO`, `MonadReader AppEnv`, `MonadError ServerError`, and the `safe-exceptions` classes. The logger is obtained through `askLogger`, not passed as an argument.

`mkApp` composes:

1. Request logging middleware (redacted).
2. Optional gzip middleware for API JSON and HTML.
3. `hoistServer (Proxy :: Proxy FullAPI) (appToHandler env) (server env)`, then `serve`.

`server` returns the handlers in the same order as `FullAPI`:

```haskell
server :: AppEnv -> ServerT FullAPI App
server env =
       uploadHandler
  :<|> listHandler
  :<|> deleteHandler
  :<|> healthHandler
  :<|> webHandler env          -- Raw: FileId -> Application
  :<|> robotsHandler
```

`appToHandler :: AppEnv -> App :~> Handler` runs `runApp env` and lifts the resulting `Either ServerError a` into `Handler`.

- **SRV-060** `uploadHandler` checks auth before touching the body.
- **SRV-061** All API handlers set `Cache-Control: no-store`.
- **SRV-062** The web handler owns all response construction for `/f/:id`.
- **SRV-063** `robotsHandler` returns the fixed `robots.txt` body.
- **SRV-064** The gzip middleware is applied only to `/api/` and HTML responses; it is skipped for `/f/` file responses.
- **SRV-065** Request logging uses the path without the query string.
- **SRV-066** Handlers, the web route, the sweeper, and reconciliation use `askLogger` from `MonadLogger`; they never receive a `Logger` parameter.
- **SRV-067** The raw `/f/:id` application runs each request through `runApp` so DB lookups, password verification, and logging use the same `App` environment.
- **SRV-068** Exception handling in server code imports `Control.Exception.Safe`, not `Control.Exception`.
- **SRV-069** A `ServerError` thrown inside `App` becomes the same HTTP response as one thrown from `Handler`; no exception text reaches the client.

## 6. Upload handler

Signature follows the API order:

```haskell
uploadHandler
  :: Maybe Text          -- Authorization
  -> Maybe Text          -- filename
  -> Maybe Int64         -- expires_in
  -> Maybe Text          -- content_type
  -> Maybe Text          -- Content-Encoding
  -> Maybe Text          -- X-Pigeon-Password
  -> UploadBody
  -> App FileInfo
```

Algorithm:

1. **SRV-070** Require a valid bearer token. Return `401` before reading the body.
2. **SRV-071** Resolve `expires_in`: supplied value, or `default_expiry`. Validate against `max_expiry`.
3. **SRV-072** Sanitize `filename`. If absent or empty after sanitization, use `file`.
4. **SRV-073** Validate `content_type`. Absent means `application/octet-stream`. Invalid means `400`.
5. **SRV-074** Decode `X-Pigeon-Password` if present to bytes, validate base64url and 1–1024 byte length, and decode as UTF-8 without normalization. Invalid UTF-8 is `400 invalid_request`.
6. **SRV-075** Hash the password with `Pigeon.Password.hashPassword` (PBKDF2-HMAC-SHA512 from the `password` package) using `password_hash_iterations`. This happens before the body is stored so a hashing failure cannot leave a blob.
7. **SRV-076** Validate `Content-Encoding`: absent/`identity`/`gzip`; otherwise `415`.
8. **SRV-077** Call `storeUpload` with the stream, metadata, expiry, and encoded password hash.
9. **SRV-078** Map `StorageError`:
   - bad gzip → `400 invalid_request`
   - size limit → `413 payload_too_large`
   - IO/database failure → `500 internal_error`
10. **SRV-079** Build `FileInfo` with `url = publicUrl <> "/f/" <> id`.
11. **SRV-080** Return `201` with `Cache-Control: no-store`.

Password hashing cost happens only when a password is supplied. An upload without a password does not run PBKDF2.

## 7. List and delete handlers

### 7.1 List

- **SRV-090** Require auth.
- **SRV-091** Use `now` from the server clock.
- **SRV-092** Call `listLiveFiles db now`.
- **SRV-093** Map each row to `FileInfo` and return `200`.
- **SRV-094** Do not include `password_hash`, its salt, or its derived key in any response.

### 7.2 Delete

- **SRV-095** Require auth.
- **SRV-096** Look up the row. If absent, return `404 not_found`.
- **SRV-097** Delete the row in a committed transaction, then unlink the blob outside the DB lock.
- **SRV-098** Return `204` even if the blob was already missing or the unlink failed; log the failure.
- **SRV-099** Do not delete an arbitrary path. Only `files/<validated-id>.gz`.

## 8. Web route

`webHandler` receives the parsed `FileId` and returns a WAI `Application`:

```haskell
webHandler :: AppEnv -> FileId -> Application
webHandler env fid req respond = runApp env (handleRequest fid req) >>= respond
```

### 8.1 GET and HEAD

1. **SRV-100** Look up the row. If absent or `expires_at <= now`, respond `404` with a static HTML page.
2. **SRV-101** If the row has no password, stream the file.
3. **SRV-102** If the row has a password, respond `200 text/html` with the password form.
4. **SRV-103** `HEAD` uses the same status and headers as `GET`, with no body.
5. **SRV-104** Unknown methods return `405` with `Allow: GET, HEAD, POST`.

### 8.2 POST

1. **SRV-110** Require `Content-Type: application/x-www-form-urlencoded`; otherwise `415` HTML.
2. **SRV-111** Read at most 8192 bytes of form body; otherwise `413` HTML.
3. **SRV-112** Parse exactly one `password` field. Missing/duplicate → failed attempt.
4. **SRV-113** If no password is configured, stream the file.
5. **SRV-114** Otherwise parse the stored value with `Pigeon.Password.parseStoredPasswordHash`; a malformed or unsupported hash is `500 internal_error` and is logged. Verify the submitted password with `Pigeon.Password.verifyPassword`.
6. **SRV-115** Wrong password → `401 text/html` with the form and a generic error.
7. **SRV-116** Correct password → stream the file.
8. **SRV-117** Never reflect the submitted password.

### 8.3 File streaming

```haskell
responseStream status200 headers $ \send flush ->
  runResourceT $ runConduit $
    sourceHandle handle
      .| (if gzipAccepted then id else ungzipConduit)
      .| mapM_C (\chunk -> liftIO (send chunk >> flush))
```

- **SRV-120** Use `responseStream`, not `responseLBS`.
- **SRV-121** Open the blob with `O_NOFOLLOW` after the DB lookup and after releasing the DB lock.
- **SRV-122** Gzip passthrough sends `Content-Encoding: gzip` and `Content-Length: size_stored`.
- **SRV-123** Identity sends no `Content-Length` and uses chunked transfer.
- **SRV-124** Always set `Vary: Accept-Encoding`.
- **SRV-125** Always set `Content-Disposition: attachment` with ASCII fallback and RFC 5987 `filename*`.
- **SRV-126** Always set `X-Content-Type-Options: nosniff`, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex, nofollow`, and `X-Frame-Options: DENY`.
- **SRV-127** If the client disconnects, the streaming exception is caught/ignored at the request boundary; the file handle is closed by `ResourceT`.
- **SRV-128** A missing blob returns `404`.

### 8.4 HTML form

- **SRV-130** Use `blaze-html` or an equivalent escaping builder. Do not concatenate unescaped text.
- **SRV-131** The page includes `<!doctype html>`, UTF-8 charset, viewport metadata, and a small inline stylesheet.
- **SRV-132** The form posts to the same `/f/<id>` URL.
- **SRV-133** The password input is `type="password"`, `name="password"`, `required`, `autofocus`, `autocomplete="current-password"`, `maxlength="1024"`.
- **SRV-134** The page includes a generic error paragraph only after a failed attempt.
- **SRV-135** The page sets:
  ```
  Content-Type: text/html; charset=utf-8
  Cache-Control: no-store
  Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'
  X-Frame-Options: DENY
  Referrer-Policy: no-referrer
  X-Robots-Tag: noindex, nofollow
  ```
- **SRV-136** The 404 page is static: `File not found or expired.` It does not echo the ID.
- **SRV-137** The 405 page includes only the allowed methods.
- **SRV-138** The 413 page says the form submission is too large.
- **SRV-139** The 415 page says the form content type is not supported.

## 9. Health handler

- **SRV-140** `GET /healthz` is public.
- **SRV-141** Run `SELECT 1` against SQLite.
- **SRV-142** Success: `200 {"status":"ok","version":"<version>"}`.
- **SRV-143** Failure: `503 {"status":"unavailable","version":"<version>"}`, with details logged server-side only.
- **SRV-144** Health responses set `Cache-Control: no-store`.
- **SRV-145** Health must not open a blob or run a sweep.

## 10. Logging

Use `fast-logger` for application logs and a small redacting request middleware.

### 10.1 Request log

One line per request:

```
2026-10-31T10:00:00Z INFO request method=POST path=/api/v1/files status=201 duration_ms=123 response_bytes=4567
```

- **SRV-150** Log the path **without** the query string.
- **SRV-151** Never log headers, `Authorization`, `X-Pigeon-Password`, cookies, or form bodies.
- **SRV-152** Never log the token or password anywhere.
- **SRV-153** `--quiet` disables request logs but not startup or error logs.
- **SRV-154** `--verbose` enables debug logs (for example, sweep timings).
- **SRV-155** Response byte counts are logged when known; do not buffer a response to measure it.

### 10.2 Application log

Examples:

```
INFO startup host=127.0.0.1 port=8080 tls=on data_dir=/var/lib/pigeon default_expiry=604800 max_expiry=31536000 token=<redacted>
INFO upload id=7q3m9x2k4v8p1c6d size_original=12345678 size_stored=4567890 expires_at=... password=yes
INFO delete id=7q3m9x2k4v8p1c6d
INFO sweep expired_rows=2 expired_blobs=2 orphan_blobs=0 errors=0
ERROR request id=... cause="..."
```

- **SRV-156** Upload logs include ID, sizes, expiry, and password presence, but not the filename.
- **SRV-157** Delete logs include only the ID.
- **SRV-158** Unexpected errors log the exception type and message server-side; clients get a generic response.
- **SRV-159** Startup logs redact the token.

## 11. Graceful shutdown

- **SRV-160** Install handlers for `SIGINT` and `SIGTERM`.
- **SRV-161** On signal: stop accepting connections, wait up to 30 seconds for in-flight requests, stop the sweeper, close the database, exit `0`.
- **SRV-162** A second signal may force immediate exit.
- **SRV-163** If shutdown exceeds the grace period, log a warning and exit `1`.
- **SRV-164** The sweeper is cancelled and awaited before the database is closed.
- **SRV-165** Do not close the database while a handler still holds a connection.

## 12. Operational notes

- **SRV-170** Run behind a TLS-terminating reverse proxy only when `--public-url` is set to the external HTTPS URL.
- **SRV-171** The reverse proxy should forward the original request body without buffering limits below the configured maximum upload size.
- **SRV-172** Back up `pigeon.db` and `files/` together (see `03-storage.md`).
- **SRV-173** Use a process supervisor that restarts on failure and forwards `SIGTERM`.
- **SRV-174** The health endpoint is suitable for container and systemd checks.
- **SRV-175** Certificate rotation requires a restart in v1.

## 13. Server acceptance criteria

- **SRV-A01** Starting without a token exits non-zero with a clear message.
- **SRV-A02** Starting with TLS enabled and no cert/key exits non-zero.
- **SRV-A03** Starting with `--no-tls` logs the plaintext warning and serves HTTP.
- **SRV-A04** `--default-expiry 7d` causes an upload without `expires_in` to expire in about seven days.
- **SRV-A05** `--max-expiry` rejects explicit lifetimes above the limit.
- **SRV-A06** The upload handler returns `401` before writing a temp file when the token is wrong.
- **SRV-A07** A password upload stores only the encoded PBKDF2 hash text, never the plaintext.
- **SRV-A08** The download route streams both gzip and identity responses without buffering.
- **SRV-A09** The password form rejects a wrong password with `401` and does not stream bytes.
- **SRV-A10** The form rejects bodies over 8192 bytes with `413`.
- **SRV-A11** `SIGTERM` drains in-flight requests and exits cleanly.
- **SRV-A12** Request logs contain no query strings, tokens, passwords, or filenames.
- **SRV-A13** `/healthz` returns `503` when SQLite is unavailable.
- **SRV-A14** `robots.txt` disallows all crawling.
