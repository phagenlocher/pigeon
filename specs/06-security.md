# Pigeon — Security

Status: authoritative  
Scope: authentication, PBKDF2 password hashing, path safety, headers, TLS, residual risks  
Related: `02-network-api.md`, `03-storage.md`, `04-server.md`, `05-client.md`

## 1. Security model

Pigeon has three trust boundaries:

1. **Uploader → server.** Protected by a shared bearer token over TLS.
2. **Web visitor → server.** Public downloads are protected by unguessable IDs; optionally by a per-file password.
3. **Server → filesystem.** Blobs and metadata are only accessible to the server's OS user.

Pigeon is not a multi-tenant service. A valid upload token grants full control over the metadata API. File passwords gate downloads only; they are not upload credentials and do not encrypt the blob.

## 2. What Pigeon does and does not protect

- **SEC-001** TLS protects upload/download traffic in transit when enabled.
- **SEC-002** The per-file password prevents casual download without the password. It does not encrypt the file at rest.
- **SEC-003** gzip is compression, not encryption. The server and anyone with filesystem access can read every blob.
- **SEC-004** At-rest confidentiality is the operator's responsibility (disk encryption, restricted filesystem access, backups).
- **SEC-005** There is no protection against an attacker who has the upload token and server access; that is full compromise.
- **SEC-006** There is no antivirus, content moderation, or safe-preview mode. Downloads are always attachments.

## 3. Bearer token

- **SEC-010** The token is a shared secret, at least 16 and at most 512 printable ASCII characters, with no whitespace.
- **SEC-011** The server refuses to start without a token.
- **SEC-012** The token is compared with `Data.ByteArray.constEq` over the UTF-8 bytes. Do not use `==` on `Text` or `String`.
- **SEC-013** The `Authorization` scheme is parsed case-insensitively; the token itself is case-sensitive.
- **SEC-014** The token is accepted only from the `Authorization: Bearer ...` header. It is never read from a query parameter, cookie, or form field.
- **SEC-015** The token is never logged, stored in the database, included in error messages, or echoed in HTML.
- **SEC-016** The server wraps the token in a `Secret` newtype whose `Show` prints `<redacted>`.
- **SEC-017** The client accepts the token from `--token`, `--token-file`, or `PIGEON_TOKEN`. Production deployments should prefer `--token-file` or the environment to avoid process-list exposure.
- **SEC-018** `--token-file` must be readable only by the service user; the server does not enforce file permissions, but operators should use `0600`.
- **SEC-019** Token rotation is performed by restarting the server with a new token. There is no multi-token or grace-period support in v1.
- **SEC-020** The client refuses to follow HTTP redirects, so the token cannot be forwarded to another host.
- **SEC-021** The client warns when it sends a token over plain HTTP. The warning is printed even with `--quiet`.

## 4. File passwords

### 4.1 Scope

- **SEC-030** A file password is optional and per-file.
- **SEC-031** Passwords are byte-exact UTF-8. No trimming, case folding, Unicode normalization, or character-class restrictions.
- **SEC-032** The minimum is 1 byte and the maximum is 1024 bytes. There is no legacy 72-byte truncation.
- **SEC-033** The password is never placed in a URL, query string, cookie, or log.
- **SEC-034** The password is never stored in plaintext. Only the encoded PBKDF2 hash text is stored.
- **SEC-035** A lost password cannot be recovered. The operator can delete the file and re-upload it.

### 4.2 PBKDF2 design

Pigeon uses `Data.Password.PBKDF2` from the `password` package (version 3.1.1.0) with PBKDF2-HMAC-SHA512. Do not hand-roll a KDF.

Public module surface (`Pigeon.Password`):

```haskell
newtype StoredPasswordHash = StoredPasswordHash
  { unStoredPasswordHash :: Text
  }

hashPassword          :: Int -> Text -> IO StoredPasswordHash
verifyPassword        :: Text -> StoredPasswordHash -> Bool
parseStoredPasswordHash :: Text -> Either Text StoredPasswordHash
```

`hashPassword iterations passwordText` builds:

```haskell
params = defaultParams
  { pbkdf2Salt        = 16
  , pbkdf2Algorithm   = PBKDF2_SHA512
  , pbkdf2Iterations  = fromIntegral iterations
  , pbkdf2OutputLength = 64
  }
```

and calls `hashPasswordWithParams params (mkPassword passwordText)`. The package generates a fresh 16-byte salt and returns a `PasswordHash PBKDF2`; `Pigeon.Password` wraps `unPasswordHash` in `StoredPasswordHash`.

`verifyPassword submitted (StoredPasswordHash stored)` calls `checkPassword (mkPassword submitted) (PasswordHash stored)` and returns `True` only for `PasswordCheckSuccess`.

`parseStoredPasswordHash` uses `extractParams`:

- reject `Nothing` (malformed hash);
- reject text that does not start with `sha512:` or does not have exactly four colon-separated fields;
- reject an algorithm other than `PBKDF2_SHA512`;
- reject iterations above `100000000`;
- reject a salt length other than 16 bytes or an output length other than 64 bytes;
- otherwise accept the exact text.

- **SEC-040** Use `Data.Password.PBKDF2` with `PBKDF2_SHA512`. Do not use `PBKDF2_MD5` or `PBKDF2_SHA1`.
- **SEC-041** Salt length is 16 bytes, generated by the `password` package.
- **SEC-042** Output length is 64 bytes. New hashes use `--password-hash-iterations` (default `600000`, allowed range `100000 .. 10000000`). Verification accepts `1 .. 100000000` so hashes with a different policy still work, with a hard cap to bound work.
- **SEC-043** `hashPasswordWithParams` MUST be used for new hashes; do not supply a fixed salt in production.
- **SEC-044** The stored value is the exact `sha512:<iterations>:<base64-salt>:<base64-key>` text returned by the package.
- **SEC-045** The package's `checkPassword` performs the comparison; it uses a constant-time comparison internally. Do not compare hashes with `==`.
- **SEC-046** The encoded hash carries the algorithm, iteration count, and salt, so parameter changes do not invalidate old files.
- **SEC-047** Verification MUST parse the stored hash with `extractParams` before calling `checkPassword`; a malformed or unsupported stored hash is a server-side data error.
- **SEC-048** A malformed stored hash is a server-side data error (`500`), not an authentication failure. Log the file ID; do not log the stored value.
- **SEC-049** A malformed submitted password (invalid base64url header, empty, or too long from either transport) is a client error (`400` for the API, `401` for the form).

### 4.3 Security properties and limitations

- **SEC-050** The salt prevents identical passwords from producing identical stored hashes.
- **SEC-051** The iteration count makes each guess more expensive; it is stored per hash so it can be raised later without invalidating old files.
- **SEC-052** PBKDF2-HMAC-SHA512 is a standard, widely reviewed construction. It is not memory-hard, so it is weaker than Argon2 or scrypt against GPU/ASIC cracking. This is a deliberate, documented trade-off.
- **SEC-053** The default 600000 iterations is a starting point. Operators handling high-value files should raise `--password-hash-iterations` and measure the latency on their hardware.
- **SEC-054** There is no rate limiting in v1. A public deployment SHOULD place the server behind a reverse proxy with per-IP rate limiting on `POST /f/:id`.
- **SEC-055** Passwords should be strong. The service cannot enforce entropy; client documentation should recommend a long random passphrase.
- **SEC-056** PBKDF2 is CPU-bound, not memory-hard. It does not provide GPU/ASIC resistance comparable to Argon2.
- **SEC-057** Do not replace PBKDF2 with a single unkeyed hash, a hand-rolled loop, or a fast hash. Use the `password` package.

### 4.4 Storage encoding

```
sha512:600000:<base64-salt>:<base64-key>
```

Example from the package documentation (25000 iterations; production uses the configured count):

```
sha512:25000:YWJjZGVmZ2hpamtsbW5vcA==:JRElYYrOMe9OIV4LDxaLTgO9ho8fFBVofXoQcdngi7AcuH6Amvmlj2B0y6y1UtQciXXBepSCS+rpy8/vDDQvoA==
```

- **SEC-058** Fields are separated by `:`; exactly four fields are accepted.
- **SEC-059** The algorithm field MUST be `sha512`.
- **SEC-060** `iterations` is decimal without leading `+` or whitespace.
- **SEC-061** Salt and key use standard Base64 with padding. The salt decodes to 16 bytes; the key decodes to 64 bytes.
- **SEC-062** The encoded value is stored in `files.password_hash`; it is never returned by the API.

### 4.5 Password transport

- **SEC-063** API upload: `X-Pigeon-Password: <unpadded base64url(UTF-8 password)>`.
- **SEC-064** Browser form: `application/x-www-form-urlencoded` field `password=<percent-encoded UTF-8>`.
- **SEC-065** Base64url uses `A-Z a-z 0-9 - _`, no padding. Reject `+`, `/`, `=`, whitespace, and invalid trailing bits.
- **SEC-066** The form body is limited to 8192 bytes; the password field is limited to 1024 decoded bytes.
- **SEC-067** The form re-renders with a generic `Incorrect password.` message for a wrong or malformed password. The page never includes the submitted value, the file ID, or details about why verification failed.
- **SEC-068** A password-protected file's GET response is the form, not the file. The file bytes are sent only after a successful POST.

## 5. TLS

- **SEC-070** TLS is enabled by default.
- **SEC-071** `--no-tls` is an explicit development-only option and logs a prominent warning.
- **SEC-072** The server uses `warp-tls` defaults and does not enable obsolete protocol versions or weak cipher suites.
- **SEC-073** The certificate must match the public hostname. The server does not validate this; it is the operator's responsibility.
- **SEC-074** The client validates certificates by default. `--insecure` disables validation and prints a warning.
- **SEC-075** `--insecure` is intended for local development and self-signed test certificates only.
- **SEC-076** The server does not request or require client certificates.
- **SEC-077** HSTS is sent when the configured public URL is `https`.
- **SEC-078** TLS key material is read once at startup; rotation requires a restart.
- **SEC-079** Private keys must be unencrypted PEM in v1. Protect them with filesystem permissions.

## 6. Path and filename safety

- **SEC-080** File IDs are validated against `^[0-9a-hjkmnp-tv-z]{16}$` before being used in a path.
- **SEC-081** Blob paths are always `files/<id>.gz`; the display filename is never part of a path.
- **SEC-082** The data directory is created with mode `0700`; blobs and the database use `0600`.
- **SEC-083** Blobs are opened with `O_NOFOLLOW` where available.
- **SEC-084** The server does not follow symlinks when opening blobs, storage directories, or the database. Configured path components are checked before use, permissions are applied through open descriptors rather than path-based chmod calls, and the database parent must not be writable by group or other users.
- **SEC-085** Filenames are sanitized for storage and headers:
  - replace `/`, `\`, NUL, CR, LF, and other control characters with `_`;
  - trim leading/trailing spaces;
  - collapse a name that is only dots to `file`;
  - truncate to at most 255 UTF-8 bytes at a character boundary;
  - if the result is empty, use `file`.
- **SEC-086** `Content-Disposition` is built from the sanitized filename and always uses `attachment`.
- **SEC-087** The ASCII fallback replaces non-ASCII, quotes, backslashes, CR, and LF with `_`; the RFC 5987 `filename*` value percent-encodes the UTF-8 name.
- **SEC-088** Content types are sanitized: printable ASCII only, maximum 255 characters, no CR/LF. Invalid values become `application/octet-stream`.
- **SEC-089** HTML is generated with `blaze-html` or an equivalent escaping builder. Never concatenate filenames or error text into raw HTML.

## 7. HTTP security headers

File responses:

```
Content-Disposition: attachment; ...
X-Content-Type-Options: nosniff
Cache-Control: no-store
Referrer-Policy: no-referrer
X-Robots-Tag: noindex, nofollow
X-Frame-Options: DENY
Vary: Accept-Encoding
```

HTML pages:

```
Content-Type: text/html; charset=utf-8
Cache-Control: no-store
Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: no-referrer
X-Robots-Tag: noindex, nofollow
```

- **SEC-090** There is no CORS support and no `Access-Control-Allow-Origin` header.
- **SEC-091** There are no cookies, so there is no cookie-based CSRF surface.
- **SEC-092** The password form does not change server state; CSRF tokens are not required for it.
- **SEC-093** `robots.txt` disallows all crawling, and `/f/` responses carry `X-Robots-Tag`.
- **SEC-094** File content is never served inline. This prevents HTML/JS uploads from executing in the service origin.
- **SEC-095** Do not add `Content-Disposition: inline` without a new security review.

## 8. Logging and error hygiene

- **SEC-100** Never log the bearer token, password, password hash, salt, `Authorization` header, or `X-Pigeon-Password`.
- **SEC-101** Never log query strings. Upload query parameters include the filename and content type.
- **SEC-102** Request logs include method, path without query, status, duration, and response bytes when known.
- **SEC-103** Application logs may include file IDs, sizes, expiry, and password presence. They do not include filenames.
- **SEC-104** Error responses do not include SQL, filesystem paths, stack traces, or exception messages.
- **SEC-105** Server-side error logs include enough detail to diagnose the failure, but still exclude secrets.
- **SEC-106** Do not include the submitted password in validation errors or HTML.
- **SEC-107** `--verbose` must not bypass redaction.

## 9. Denial-of-service considerations

- **SEC-110** Upload bodies are streamed; the server never buffers a whole file.
- **SEC-111** `--max-upload-size` can cap both stored and decompressed bytes. `0` means unlimited and is a deliberate risk.
- **SEC-112** Gzip decompression is streamed and aborts once the configured limit is exceeded.
- **SEC-113** Incoming gzip is validated; a corrupt stream is rejected and its temp file removed.
- **SEC-114** The password form body is limited to 8192 bytes.
- **SEC-115** The password KDF is CPU-expensive by design; a public deployment should rate-limit password attempts at the proxy.
- **SEC-116** SQLite writes are serialized through one connection. A malicious uploader cannot create unbounded concurrent write transactions, but a valid token holder can still fill the disk.
- **SEC-117** The server should run with a filesystem quota or disk-space monitoring in production.
- **SEC-118** Warp's idle timeout is 300 seconds. An active large transfer is not cut off solely by duration.

## 10. Residual risks

- **SEC-120** A valid upload token grants full control: upload, list, and delete. There is no per-user authorization.
- **SEC-121** Anyone with a file URL can download an unprotected file. IDs are unguessable but are not access control once shared.
- **SEC-122** Password-protected links can be brute-forced if the password is weak and no external rate limit exists.
- **SEC-123** PBKDF2-HMAC-SHA512 is not memory-hard; without rate limiting, weak passwords remain vulnerable to offline GPU cracking.
- **SEC-124** Blobs are not encrypted at rest.
- **SEC-125** There is no audit trail beyond logs; logs are not tamper-evident.
- **SEC-126** There is no malware scanning; recipients download at their own risk.
- **SEC-127** TLS certificate validation is disabled by `--insecure`; a man-in-the-middle can read tokens and passwords.
- **SEC-128** `--no-tls` exposes tokens, passwords, and file contents on the network.

## 11. Security acceptance criteria

- **SEC-A01** A wrong bearer token returns `401` and writes no temp file or metadata row.
- **SEC-A02** Token comparison uses `constEq`; a code review finds no `==` comparison of the token.
- **SEC-A03** No log line contains the token, a password, `Authorization`, `X-Pigeon-Password`, or a query string.
- **SEC-A04** A 200-byte password can be uploaded and successfully used for download.
- **SEC-A05** Two files with the same password have different salts and different stored hashes.
- **SEC-A06** A file password is never stored in plaintext; the database contains only `sha512:<iterations>:<base64-salt>:<base64-key>`.
- **SEC-A07** A malformed stored hash produces `500` and a server-side log, not a successful download.
- **SEC-A08** `../` in a filename cannot escape `files/`; the blob path remains `files/<id>.gz`.
- **SEC-A09** A filename containing CR/LF cannot inject a header.
- **SEC-A10** An uploaded HTML file downloads as an attachment and does not render in the service origin.
- **SEC-A11** `/f/:id` responses include `X-Content-Type-Options: nosniff`, `Content-Disposition: attachment`, and `Cache-Control: no-store`.
- **SEC-A12** The password form includes the documented CSP and frame/referrer headers.
- **SEC-A13** The client refuses redirects and prints a plaintext-HTTP warning.
- **SEC-A14** Changing PBKDF2 parameters does not break existing hashes; the algorithm and iteration count are carried in the stored hash text, and old hashes still verify.
