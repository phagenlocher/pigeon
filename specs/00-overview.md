# Pigeon — Overview

Status: authoritative  
Scope: product behavior, actors, flows, non-goals  
Related: `01-architecture.md`, `02-network-api.md`, `03-storage.md`, `04-server.md`, `05-client.md`, `06-security.md`, `07-testing.md`

## 1. Purpose

Pigeon is a self-hosted file-publishing service. An authenticated terminal client uploads a file; the server stores it compressed and publishes it at an unguessable URL. A browser can download it until it expires. Optionally, the download is protected by a per-file password.

Pigeon is intentionally small. It replaces ad-hoc file sharing with a predictable, auditable service: one server, one shared upload token, expiring links, optional download passwords, and no web management surface.

## 2. Actors

| Actor | Capability |
| --- | --- |
| Operator | Runs `pigeon-server`, configures TLS, token, data directory, expiry policy. Has filesystem access to the data directory. |
| Uploader | Runs `pigeon-client` with the shared token. Can upload, list, and delete files. |
| Web visitor | Uses a normal browser or HTTP client to download a file from `/f/:id`. May need to enter a password. |
| Sweeper | Internal server component that deletes expired rows and blobs. Not an external actor. |

There are no user accounts, no per-user ownership, and no roles. Anyone with the upload token has full control of the metadata API.

## 3. Product requirements

### 3.1 Upload

- **OV-001** An uploader MUST be able to upload a local file of arbitrary size, including files larger than available RAM.
- **OV-002** An upload MUST be associated with an expiry time. The API may omit the expiry; in that case the server MUST apply its configured default expiry.
- **OV-003** An uploader SHOULD be able to set a per-file download password. The password MUST NOT be required to upload the file.
- **OV-004** An uploader MUST be able to set a display filename and content type different from the local path.
- **OV-005** The server MUST return a stable ID and a public URL for every successful upload.
- **OV-006** Upload traffic SHOULD be gzip-compressed when the client enables compression.
- **OV-007** The server MUST store every blob gzip-compressed on disk, regardless of whether the upload arrived compressed.
- **OV-008** An upload MUST be rejected if it exceeds the configured maximum upload size, when a limit is configured.
- **OV-009** An upload MUST be rejected if its expiry exceeds the configured maximum expiry, when a limit is configured.

### 3.2 Listing

- **OV-010** An uploader MUST be able to list all live (non-expired) files.
- **OV-011** The list MUST include, for each file: ID, display filename, original size, creation time, expiry time, password presence, and public URL.
- **OV-012** Expired files MUST NOT appear in the list, even if the sweeper has not removed them yet.

### 3.3 Deletion

- **OV-013** An uploader MUST be able to delete a file by ID.
- **OV-014** Deleting a file MUST remove its metadata and make its URL stop working.
- **OV-015** Deleting a missing file MUST return `404` rather than silently succeeding.

### 3.4 Download

- **OV-016** A web visitor MUST be able to download a live file from its public URL without authentication, unless the file has a password.
- **OV-017** If a file has a password, the visitor MUST be presented with an HTML password form and MUST submit the correct password before the file is streamed.
- **OV-018** A download MUST stream the file without loading it fully into server memory.
- **OV-019** A download MUST support both gzip-compressed transfer and identity transfer, chosen by `Accept-Encoding`.
- **OV-020** A deleted, expired, or unknown file MUST return `404`. The response MUST NOT reveal whether the file existed previously.
- **OV-021** The server MUST set `Content-Disposition: attachment` and must not serve user content inline.

### 3.5 Expiry and cleanup

- **OV-022** Every stored file MUST have a non-null expiry timestamp.
- **OV-023** A download request for an expired file MUST fail even if the sweeper has not run.
- **OV-024** The server MUST periodically delete expired metadata rows and their blobs.
- **OV-025** The server MUST reconcile orphan blobs and metadata rows with missing blobs without deleting recent in-flight uploads.

### 3.6 Operations

- **OV-026** TLS MUST be enabled by default.
- **OV-027** Plain HTTP MUST require an explicit `--no-tls` opt-out for development.
- **OV-028** The server MUST expose an unauthenticated health endpoint for process supervision.
- **OV-029** The server MUST shut down gracefully on `SIGINT`/`SIGTERM`.
- **OV-030** The server MUST NOT log bearer tokens, file passwords, or query strings.
- **OV-031** The server MUST persist committed metadata durably in the main SQLite database file. WAL mode is not used.

## 4. Primary flows

### 4.1 Upload with default expiry

1. Uploader runs `pigeon-client upload report.pdf`.
2. Client reads the file as a stream, optionally gzip-compresses it, and sends it to `POST /api/v1/files`.
3. Client omits `expires_in`.
4. Server applies `--default-expiry` (default `7d`), streams the body to a temp file, stores a gzip blob, and inserts metadata.
5. Server returns `201` with `FileInfo`, including the absolute public URL and the computed `expiresAt`.
6. Client prints the URL and expiry.

### 4.2 Upload with password and explicit expiry

1. Uploader runs `pigeon-client upload secret.zip --expires-in 24h --password`.
2. Client prompts for the password without echo (or reads it with `--password-stdin`).
3. Client sends the password in `X-Pigeon-Password` as base64url(UTF-8).
4. Server computes a salted PBKDF2-HMAC-SHA512 password hash with the `password` package and stores only the encoded hash string.
5. The file is downloadable only through the password form.

### 4.3 Browser download without password

1. Visitor opens `https://files.example.com/f/7q3m9x2k4v8p1c6d`.
2. Server looks up the live row.
3. If the browser accepts gzip, the server streams the stored gzip bytes with `Content-Encoding: gzip`; otherwise it decompresses on the fly.
4. Browser saves the file under the original filename.

### 4.4 Browser download with password

1. Visitor opens the URL.
2. Server returns a small HTML form.
3. Visitor submits the password to `POST /f/:id` as `application/x-www-form-urlencoded`.
4. On success, the server streams the file in the POST response.
5. On failure, the server returns `401` and re-renders the form with a generic error.

### 4.5 Expiry

1. Sweeper wakes every `--sweep-interval` (default `60s`).
2. It deletes rows whose `expires_at <= now`, then unlinks their blobs.
3. Any download request checks `expires_at` independently and returns `404` for expired files.
4. Orphan blobs older than the grace period are removed; metadata rows with missing blobs are removed at startup.

## 5. Non-goals

The following are explicitly out of scope for v1. Do not implement them without a new specification.

- **OV-N01** Web management UI, dashboard, upload form, or file browser.
- **OV-N02** User accounts, roles, per-user ownership, or multiple upload tokens.
- **OV-N03** Client-side download command.
- **OV-N04** Range requests, resumable downloads, or multi-part uploads.
- **OV-N05** Deduplication or content-addressed storage.
- **OV-N06** Encryption of blobs at rest. gzip is compression, not encryption.
- **OV-N07** Antivirus scanning, content moderation, or file-type validation beyond content-type sanitization.
- **OV-N08** Quotas, billing, or per-user storage limits.
- **OV-N09** S3 or other object-storage backends.
- **OV-N10** Public API documentation generation, SDKs, or webhooks.
- **OV-N11** Email delivery, QR codes, or link shortening.
- **OV-N12** Password recovery. A lost password means the file is inaccessible; delete and re-upload.
- **OV-N13** Rate limiting. The deployment should use a reverse proxy if brute-force protection is required.

## 6. Glossary

| Term | Meaning |
| --- | --- |
| Blob | The gzip-compressed bytes stored at `data/files/<id>.gz`. |
| File | A metadata row plus its blob. |
| Live file | A file whose `expires_at` is in the future. |
| Expiry | Absolute UTC timestamp after which the file is no longer downloadable. |
| Default expiry | Server policy applied when an upload omits `expires_in`. |
| Maximum expiry | Server policy bounding any explicit `expires_in`. |
| Upload token | Shared bearer token that authorizes the metadata API. |
| File password | Optional per-file secret required before download. It is not the upload token. |
| PBKDF2 | Password-based key-derivation function used to turn a file password into a stored hash. |
| Sweeper | Background task that removes expired files and reconciles storage. |

## 7. Success criteria

A deployment is correct when all of the following hold:

1. A 1 GiB file can be uploaded and downloaded with server memory staying well below the file size.
2. Every uploaded file has a visible expiry; omitting `--expires-in` still produces an expiry.
3. A gzip upload and an identity upload both result in a `.gz` blob that decompresses to the original bytes.
4. A password-protected file cannot be downloaded with a wrong or missing password.
5. A deleted file returns `404` immediately after deletion.
6. An expired file returns `404` even before the sweeper runs, and is removed by the sweeper afterward.
7. Killing the server after a successful upload leaves the metadata row and blob intact after restart.
8. The server starts with TLS and refuses to start with TLS enabled but no certificate/key.
9. Tokens and passwords do not appear in logs.
10. The CLI exits with the documented code for success, auth failure, not found, network failure, and local file failure.

## 8. Assumptions

- The target platform is Linux (or a POSIX system with atomic `rename` within a filesystem).
- The operator controls the data directory and TLS material.
- The server is the authoritative clock for expiry.
- Clients and browsers can handle gzip content encoding.
- The upload token is distributed out of band.
- The service is low-to-moderate throughput; SQLite serialized writes are acceptable.

## 9. Spec map

| Spec | Read when |
| --- | --- |
| `01-architecture.md` | Choosing modules, dependencies, or startup order |
| `02-network-api.md` | Changing endpoints, headers, status codes, or JSON |
| `03-storage.md` | Changing schema, durability, blob layout, expiry, or cleanup |
| `04-server.md` | Changing configuration, TLS, logging, or lifecycle |
| `05-client.md` | Changing commands, output, progress, or exit codes |
| `06-security.md` | Touching auth, passwords, filenames, headers, or secrets |
| `07-testing.md` | Adding tests or checking acceptance criteria |
