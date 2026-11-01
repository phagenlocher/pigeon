# Pigeon — Testing

Status: authoritative  
Scope: unit, storage, HTTP, TLS, CLI, streaming, durability, security tests  
Related: all other specs

## 1. Strategy

Tests are layered so a failure points at one boundary:

| Layer | Tool | Purpose |
| --- | --- | --- |
| Unit | `hspec`, QuickCheck | Parsers, formatting, PBKDF2, IDs, headers |
| Storage | `hspec` + temp directories | SQLite durability, gzip blobs, cleanup |
| HTTP integration | real Warp server + `http-client`/Servant client | API contract, streaming, forms |
| TLS integration | `warp-tls` + test certs | Default verification and `--insecure` |
| CLI integration | `System.Process` + built binary | Commands, output, exit codes |
| Manual | shell + browser | 1 GiB streaming, crash durability, UX |

Tests must assert behavior, not implementation details. Do not weaken a test to make a broken implementation pass.

## 2. Test harness

- **TEST-001** `test/Spec.hs` is the `hspec` entry point.
- **TEST-002** Shared helpers live in `test/Support.hs`:
  - `withTempDataDir :: (FilePath -> IO a) -> IO a`
  - `withTestServer :: (ServerConfig -> Port -> IO a) -> IO a`
  - `withTlsTestServer :: (ServerConfig -> Port -> IO a) -> IO a`
  - `uploadRaw :: ClientEnv -> Text -> ByteString -> IO FileInfo`
  - `uploadGzip :: ClientEnv -> Text -> ByteString -> IO FileInfo`
  - `download :: Port -> FileId -> [RequestHeader] -> IO (Response ByteString)`
  - `postForm :: Port -> FileId -> ByteString -> IO (Response ByteString)`
- **TEST-003** Plain HTTP tests use `Network.Wai.Handler.Warp.testWithApplication` with a random port.
- **TEST-004** TLS tests use `openFreePort`, `async`, and `runTLS` with committed test-only certificates.
- **TEST-005** Every test gets a fresh data directory; no test shares a database.
- **TEST-006** Tests that need fast password hashing set `--password-hash-iterations 100000` (the minimum).
- **TEST-007** Tests that need short expiry set `--default-expiry 1h` and use explicit `expires_in` where possible.
- **TEST-008** Tests that need fast sweeping set `--sweep-interval 1s` and poll with a bounded timeout.
- **TEST-009** Integration tests must not depend on the developer's `~/.pigeon` or environment. Clear `PIGEON_*` variables in the child environment.
- **TEST-010** Test certificates live in `test/fixtures/tls/` and are clearly marked test-only. They cover `localhost` and `127.0.0.1` and have a long validity period.

## 3. Unit tests

### 3.1 Duration parser (`Pigeon.Duration`)

- **TEST-020** `30m` = 1800 seconds.
- **TEST-021** `12h` = 43200.
- **TEST-022** `7d` = 604800.
- **TEST-023** `2w` = 1209600.
- **TEST-024** `1d12h` = 129600.
- **TEST-025** Case-insensitive: `7D` works.
- **TEST-026** Reject: empty, `0`, `-1h`, `1.5h`, `1h `, `h`, `1x`, `1h2`, overflow beyond `Int64`.
- **TEST-027** QuickCheck: any accepted duration round-trips through seconds and back to a normalized form.

### 3.2 Filename and content-type sanitization

- **TEST-030** `../../etc/passwd` becomes a safe display name; no path separators remain.
- **TEST-031** CR/LF/NUL and other control characters become `_`.
- **TEST-032** Leading/trailing spaces are trimmed.
- **TEST-033** `...` becomes `file`.
- **TEST-034** A 300-byte UTF-8 name is truncated at a character boundary to <= 255 bytes.
- **TEST-035** An empty name becomes `file`.
- **TEST-036** `text/plain\r\nX-Evil: yes` becomes `application/octet-stream`.
- **TEST-037** Unicode filenames survive storage and appear correctly in `filename*`.

### 3.3 File IDs

- **TEST-040** A generated ID matches `^[0-9a-hjkmnp-tv-z]{16}$`.
- **TEST-041** 10,000 generated IDs are unique in practice.
- **TEST-042** IDs never contain `i`, `l`, `o`, or `u`.
- **TEST-043** Invalid IDs are rejected: wrong length, uppercase, `i`, symbols, empty.
- **TEST-044** `FileId` JSON and HTTP path encoding round-trip.

### 3.4 Password hashing (PBKDF2)

- **TEST-050** A frozen vector in `test/fixtures/pbkdf2-vector.json` contains:
  - password UTF-8 text (`foobar`),
  - salt (`abcdefghijklmnop`, 16 bytes),
  - algorithm (`sha512`),
  - iterations (`25000`),
  - output length (`64`),
  - expected hash text:
    `sha512:25000:YWJjZGVmZ2hpamtsbW5vcA==:JRElYYrOMe9OIV4LDxaLTgO9ho8fFBVofXoQcdngi7AcuH6Amvmlj2B0y6y1UtQciXXBepSCS+rpy8/vDDQvoA==`
- **TEST-051** `parseStoredPasswordHash` accepts the fixture hash and `verifyPassword "foobar"` returns `True`.
- **TEST-052** `verifyPassword` rejects a wrong password; `checkPassword` returns `PasswordCheckFail`.
- **TEST-053** Two `hashPassword` calls with the same password produce different salts and different hash text.
- **TEST-054** A 200-byte password and a 1024-byte password both work; there is no legacy 72-byte truncation.
- **TEST-055** Empty passwords are rejected by the API layer.
- **TEST-056** Passwords are byte-exact: `"päss"` and `"pass"` are different; NFC/NFD forms are not normalized.
- **TEST-057** `parseStoredPasswordHash` / `StoredPasswordHash` round-trips the exact `sha512:<iterations>:<base64-salt>:<base64-key>` text.
- **TEST-058** Reject malformed hashes: wrong algorithm, non-numeric iterations, invalid Base64, wrong salt/key length, missing or extra fields, and iterations above `100000000`.
- **TEST-059** The package's `checkPassword` performs the digest comparison; a code review confirms no `==` on hashes.
- **TEST-060** The iteration count and algorithm are preserved in the encoded hash.
- **TEST-061** The hash string never contains the plaintext password.
- **TEST-062** The production `hashPassword` uses SHA512, a 16-byte salt, and a 64-byte key.

### 3.5 Base64url password header

- **TEST-070** Encode/decode ASCII, Unicode, 1-byte, and 1024-byte passwords.
- **TEST-071** Decode rejects `+`, `/`, `=`, whitespace, invalid length, and non-canonical trailing bits.
- **TEST-072** A malformed header maps to `400 invalid_request`.
- **TEST-073** A decoded password over 1024 bytes maps to `400`.

### 3.6 Accept-Encoding

- **TEST-080** `gzip` → gzip.
- **TEST-081** `identity` → identity.
- **TEST-082** Empty/absent → identity.
- **TEST-083** `gzip;q=0` → identity if identity is allowed.
- **TEST-084** `gzip;q=0, identity;q=0` → not acceptable (`406`).
- **TEST-085** `*;q=0.5` → gzip if no explicit gzip entry.
- **TEST-086** `br, gzip` → gzip.
- **TEST-087** `br` only → identity (unsupported encodings are ignored).
- **TEST-088** Malformed q-values do not crash; fall back to identity.

### 3.7 Content-Disposition

- **TEST-090** ASCII name: `attachment; filename="report.pdf"; filename*=UTF-8''report.pdf`.
- **TEST-091** Unicode name: ASCII fallback replaces non-ASCII; `filename*` percent-encodes UTF-8.
- **TEST-092** Quote/backslash/CR/LF cannot break out of the header.

### 3.8 JSON

- **TEST-100** `FileInfo` serializes to the exact field names and RFC3339 timestamps in `02-network-api.md`.
- **TEST-101** `Health` serializes to `{"status":"ok","version":"..."}`.
- **TEST-102** `ApiErrorEnvelope` serializes to `{"error":{"code":"...","message":"..."}}`.
- **TEST-103** No API response contains `password_hash`, salt, digest, or `size_stored`.

## 4. Storage tests

### 4.1 SQLite configuration and durability

- **TEST-110** After `openDb`, `PRAGMA journal_mode` is `delete`.
- **TEST-111** `PRAGMA synchronous` is `2` (`FULL`).
- **TEST-112** `PRAGMA foreign_keys` is `1`.
- **TEST-113** `PRAGMA busy_timeout` is `5000`.
- **TEST-114** `migrate` on a fresh database creates the schema and sets `user_version = 1`.
- **TEST-115** `migrate` twice is idempotent.
- **TEST-116** A database with `user_version = 2` is rejected at startup.
- **TEST-117** Insert a row, close the database, reopen it, and read the row back.
- **TEST-118** A committed upload has no `-wal` file and the row is present in `pigeon.db`.
- **TEST-119** Crash test: spawn the server, upload, wait for `201`, `SIGKILL`, restart, and verify the row and blob still exist. This may be a CI/manual test if process spawning is unavailable.
- **TEST-141** A symlinked data directory, `files/`, `tmp/`, database file, or database parent causes startup failure without changing the symlink target.
- **TEST-142** New data directories and blobs use mode `0700`/`0600` as applicable, and the database file is tightened to `0600` through an open descriptor.
- **TEST-143** A database parent writable by group or other users is refused at startup.

### 4.2 Blob round-trips

- **TEST-120** Identity upload of empty, 1-byte, 1 KiB, 10 MiB, and random bytes produces a valid gzip blob.
- **TEST-121** `gzip -t` passes for every stored blob.
- **TEST-122** `gzip -dc` of the blob equals the original bytes.
- **TEST-123** Gzip upload of the same fixtures produces identical decompressed bytes.
- **TEST-124** `size_original` and `size_stored` are correct for both upload modes.
- **TEST-125** A gzip upload with a corrupted stream returns `400` and leaves no row/final blob.
- **TEST-126** A gzip upload that decompresses beyond `max_upload_size` returns `413` and leaves no row/final blob.
- **TEST-127** An identity upload beyond `max_upload_size` returns `413` while streaming, not after buffering.
- **TEST-128** A zero-byte file stores a valid gzip stream and downloads as zero bytes with identity encoding.

### 4.3 Deletion and expiry

- **TEST-130** Deleting a row removes it and unlinks the blob.
- **TEST-131** Deleting an already-missing blob still removes the row.
- **TEST-132** Deleting an expired row returns `204`.
- **TEST-133** The sweeper removes rows with `expires_at <= now`.
- **TEST-134** The sweeper unlinks the corresponding blobs.
- **TEST-135** A download of an expired row returns `404` before the sweeper runs.
- **TEST-136** `listLiveFiles` excludes expired rows even if they still exist.
- **TEST-137** A row whose blob is missing is reported and removed by startup reconciliation.
- **TEST-138** An orphan blob older than 1 hour is removed; one newer than 1 hour is kept.
- **TEST-139** A temp file older than 24 hours is removed; a recent one is kept.
- **TEST-140** Reconciliation never removes a blob whose ID exists in the database.

### 4.4 Concurrency

- **TEST-150** Four concurrent uploads all succeed and produce four distinct rows/blobs.
- **TEST-151** Concurrent upload, list, and delete do not deadlock.
- **TEST-152** The database lock is not held while a blob is streamed; a slow download does not block an upload or list.
- **TEST-153** A delete during a download either lets the open stream finish or returns `404` to a new request; it never serves partial corrupt data.

### 4.5 Synchronization failures

Failures are injected through `StorageHooks` so the tests do not depend on a particular filesystem.

- **TEST-154** A temp-file fsync failure makes the upload fail, leaves no metadata row, no final blob, and no temp file, and logs the cause.
- **TEST-155** A directory-fsync failure makes the upload fail, leaves no metadata row and no final blob when cleanup succeeds.
- **TEST-156** A simulated unsupported-directory-fsync result lets the upload succeed and emits the warning exactly once per process, even across repeated uploads.
- **TEST-157** When post-rename cleanup also fails, the upload still fails, no row is inserted, the blob is left for the sweeper, and the orphan is logged.

## 5. HTTP integration tests

### 5.1 Authentication

- **TEST-160** Missing `Authorization` → `401`, no temp file, no row.
- **TEST-161** Wrong token → `401`, no temp file, no row.
- **TEST-162** Malformed scheme (`Token ...`, `Bearer` with no token) → `401`.
- **TEST-163** Correct token with lowercase `bearer` → success.
- **TEST-164** Token in a query parameter is ignored and the request is `401`.
- **TEST-165** `/healthz` works without a token.

### 5.2 Upload and list

- **TEST-170** Upload without `expires_in` returns `expiresAt` approximately `now + default_expiry`.
- **TEST-171** Upload with `expires_in = 604800` returns the expected expiry.
- **TEST-172** `expires_in = 0`, negative, non-integer, and above `max_expiry` → `400`.
- **TEST-173** `filename` defaults to `file` when omitted.
- **TEST-174** `content_type` defaults to `application/octet-stream`.
- **TEST-175** A Unicode filename round-trips through upload and list.
- **TEST-176** List returns newest first and excludes expired files.
- **TEST-177** List is empty for a fresh server.
- **TEST-178** Delete removes the file from subsequent lists.
- **TEST-179** Delete unknown ID → `404`.

### 5.3 Download

- **TEST-180** `GET /f/:id` with `Accept-Encoding: gzip` returns `Content-Encoding: gzip`, `Content-Length = size_stored`, and decompresses to the original.
- **TEST-181** `GET /f/:id` with `Accept-Encoding: identity` returns the original bytes, no `Content-Encoding`, and no `Content-Length`.
- **TEST-182** `HEAD /f/:id` returns the same headers as `GET` and an empty body.
- **TEST-183** Unknown/deleted/expired ID → `404` HTML with no ID echo.
- **TEST-184** `Content-Disposition` is attachment and includes `filename*`.
- **TEST-185** `X-Content-Type-Options`, `Cache-Control`, `Referrer-Policy`, `X-Robots-Tag`, `X-Frame-Options`, and `Vary` are present.
- **TEST-186** A request with `Range` returns `200` and the full file.
- **TEST-187** An unsupported method (`PUT`) → `405` with `Allow: GET, HEAD, POST`.
- **TEST-188** `robots.txt` returns the disallow-all body.

### 5.4 Password form

- **TEST-190** GET on a password file returns `200 text/html`, not the file.
- **TEST-191** GET on an open file returns the file.
- **TEST-192** POST with the wrong password returns `401` and no file bytes.
- **TEST-193** POST with the correct password returns the file bytes.
- **TEST-194** POST with no `password` field returns `401`.
- **TEST-195** POST with duplicate `password` fields returns `401`.
- **TEST-196** POST with `text/plain` returns `415`.
- **TEST-197** POST with a body over 8192 bytes returns `413`.
- **TEST-198** The form response contains the CSP, frame, and referrer headers.
- **TEST-199** A filename containing `<script>` is HTML-escaped on the form page.
- **TEST-200** A 200-byte password works through the form.
- **TEST-201** The form page never contains the submitted password.

### 5.5 Health

- **TEST-210** Healthy server returns `200` with `status: ok`.
- **TEST-211** A closed/broken database returns `503` with `status: unavailable`.
- **TEST-212** Health does not require authentication.
- **TEST-213** Health does not run a sweep.

## 6. TLS integration tests

- **TEST-220** With TLS enabled and the test certificate, the server serves HTTPS.
- **TEST-221** The default client rejects the self-signed test certificate.
- **TEST-222** The client with `--insecure` succeeds against the test certificate and prints the warning.
- **TEST-223** TLS enabled without cert/key fails at startup.
- **TEST-224** `--no-tls` serves plain HTTP and logs the plaintext warning.
- **TEST-225** `--no-tls` combined with cert/key is a usage error.
- **TEST-226** An HTTPS public URL causes HSTS on HTML/API responses.
- **TEST-227** A large upload and download work over TLS.

## 7. CLI integration tests

Run the built `pigeon-client` against a test server. Use `readProcessWithExitCode` and a sanitized environment.

- **TEST-230** `upload FILE` succeeds with exit `0`, prints the URL, and omits `expires_in`.
- **TEST-231** `upload --expires-in 7d` sends `expires_in=604800`.
- **TEST-232** `upload --no-compress` succeeds; the server still stores gzip.
- **TEST-233** `upload --password-stdin` with a 200-byte password succeeds; the file is password-protected.
- **TEST-234** `upload --password` on a TTY prompts without echo. This is manual or uses a PTY helper.
- **TEST-235** Missing local file exits `7`.
- **TEST-236** Missing token exits `2` before any request.
- **TEST-237** Wrong token exits `3`.
- **TEST-238** Unknown delete ID exits `4`.
- **TEST-239** `list` prints a table with ID, name, size, expiry, remaining, and password.
- **TEST-240** `--json list` prints a valid array and preserves order.
- **TEST-241** `--json upload` prints a valid `FileInfo` object.
- **TEST-242** `delete --yes` removes the file and exits `0`.
- **TEST-243** `delete` with a PTY answering `n` exits `8` and deletes nothing. Use a PTY helper; this may be marked manual if the test environment cannot allocate one.
- **TEST-244** `delete` with a non-TTY stdin and no `--yes` exits `2`.
- **TEST-245** `delete` continues after one failure and reports all results.
- **TEST-246** A plain HTTP server URL with a token prints the warning.
- **TEST-247** `--quiet` suppresses progress but not errors or the plaintext warning.
- **TEST-248** Token from `--token-file` is not present in process arguments; inspect the child argv.
- **TEST-249** `--server` with a path/query/fragment exits `2`.

## 8. Streaming and memory tests

- **TEST-250** Automated: upload and download a 32 MiB random file; byte equality and gzip validity hold.
- **TEST-251** Automated: run the 32 MiB test with `+RTS -M128m` for client and server where practical. If the RTS limit makes the test flaky, record the reason and keep the manual 1 GiB test.
- **TEST-252** Manual: 1 GiB upload with `pigeon-client`; monitor server RSS. It must not grow linearly with file size.
- **TEST-253** Manual: 1 GiB download with `curl`; monitor server RSS.
- **TEST-254** Manual: 1 GiB upload with `--no-compress`; verify the server compresses at rest and memory stays bounded.
- **TEST-255** Manual: 1 GiB gzip upload from a precompressed stream; verify single-pass validation computes the correct original size with bounded memory.
- **TEST-256** Interrupt a large download mid-stream; the server stays healthy and the temp/blob state is unchanged.
- **TEST-257** Interrupt a large upload mid-stream; no metadata row is committed and the temp file is cleaned up after the grace period.
- **TEST-288** A payload spanning several 1 MiB blocks round-trips through `parallelGzipConduit` and decodes with plain `ungzip`: the output starts with the gzip magic and is one member, not concatenated members.
- **TEST-289** A block-parallel gzip stream passes `gzip -t` and is fully decoded by a zlib-based client (`curl --compressed`); record the command in the manual benchmark.
- **TEST-290** A corrupted block-parallel gzip stream returns `400 invalid_request` and leaves no metadata row, blob, or temp file.
- **TEST-291** An identity upload larger than one block is stored as one gzip member; identity download is byte-equal and gzip passthrough returns the stored bytes with a matching `Content-Length`.
- **TEST-292** A zero-byte upload produces a valid gzip stream and `size = 0`; block-parallel compression of an empty stream does not produce an empty body.
- **TEST-293** A 32 MiB round-trip succeeds under a bounded heap (`+RTS -M192m`, or record why a tighter cap is flaky per `TEST-251`).

## 9. Security tests

- **TEST-260** Token/password/query strings never appear in logs. Capture logs during a password upload, list, delete, and form login.
- **TEST-261** A filename with `../`, CR/LF, and quotes cannot escape the blob directory or inject headers.
- **TEST-262** An uploaded HTML file downloads with `Content-Disposition: attachment` and `nosniff`.
- **TEST-263** A password file's GET response contains no file bytes.
- **TEST-264** A wrong password response contains no file bytes and no password reflection.
- **TEST-265** A malformed stored hash returns `500` and does not authenticate.
- **TEST-266** Client redirects are disabled; a test server returning `302` is not followed.
- **TEST-267** `--insecure` prints a warning; default TLS validation fails for the self-signed test cert.
- **TEST-268** `--no-tls` prints the plaintext warning.
- **TEST-269** The database contains `sha512:<iterations>:<base64-salt>:<base64-key>`, not plaintext passwords.
- **TEST-270** Two files with the same password have different salts/hashes.
- **TEST-271** Base64url rejects non-canonical encodings.
- **TEST-272** Constant-time comparison is used for tokens and PBKDF2 hash checks; this is a code-review checklist item, not a timing test.

## 10. CI

```bash
cabal build all
cabal test all --test-show-details=direct
fourmolu --mode check src app test
hlint src app test
```

- **TEST-280** CI must fail on a `-Wall` warning.
- **TEST-281** CI must fail if `fourmolu --mode check` or `hlint` reports issues.
- **TEST-282** CI must not print secrets. Test fixtures contain only test passwords and test keys.
- **TEST-283** TLS tests may be skipped only if the platform cannot bind a second port; the skip must be explicit and logged.

### 10.1 App monad and logging

- **TEST-284** `askLogger` returns the logger from the ambient `AppEnv`; a test runs `App` against a recording logger and observes the same logger instance.
- **TEST-285** A `ServerError` thrown inside `App` is converted by `appToHandler` into the corresponding HTTP status and JSON error body.
- **TEST-286** Modules do not import `Control.Exception` or `Control.Exception.Base`; `.hlint.yaml` restricts them, so `hlint` fails if they do.
- **TEST-287** A request handled through the raw `/f/:id` application runs in `App` and logs through `askLogger` without a `Logger` argument.

## 11. Acceptance matrix

| Requirement area | Primary tests |
| --- | --- |
| Upload, auth, expiry default | TEST-160…179, TEST-230…233 |
| List | TEST-176, TEST-177, TEST-239, TEST-240 |
| Delete | TEST-130…132, TEST-178, TEST-179, TEST-242…245 |
| Download and compression | TEST-180…188, TEST-250…257, TEST-288…293 |
| Password form and PBKDF2 | TEST-050…062, TEST-190…201, TEST-260…271 |
| Expiry and cleanup | TEST-133…140 |
| Durability | TEST-110…119 |
| Streaming | TEST-250…257, TEST-288…293 |
| TLS | TEST-220…227, TEST-267, TEST-268 |
| CLI | TEST-230…249 |
| Security headers and logs | TEST-185, TEST-198, TEST-260…271 |

## 12. Manual QA checklist

Run before a release:

1. Start the server with TLS and a real certificate.
2. Upload a small file with `pigeon-client` and open the URL in a browser.
3. Upload a password-protected file; verify the form, wrong password, and correct password.
4. Upload a 1 GiB file; watch server RSS and `gzip -t` the blob.
5. Download the 1 GiB file with `curl`; verify the checksum.
6. Upload with `--no-compress`; verify the blob is gzip and the download is correct.
7. Upload without `--expires-in`; verify the expiry equals the server default.
8. Upload with an expiry above `--max-expiry`; verify `400`.
9. Let a short-expiry file expire; verify `404` and eventual row/blob removal.
10. Delete a file; verify the URL is `404` and the blob is gone.
11. `SIGKILL` the server right after a `201`; restart and verify the file is listed and downloadable.
12. Inspect logs for tokens, passwords, query strings, and filenames; there must be none.
13. Run `curl -I` on a file and verify the security headers.
14. Verify `robots.txt` and `X-Robots-Tag`.
15. Run the CLI against a plain HTTP dev server; verify the warning.
16. Verify `--insecure` against a self-signed certificate and that the default fails.
17. Verify `delete` confirmation, `--yes`, and non-TTY behavior.
18. Verify `--json` output with `jq`.
