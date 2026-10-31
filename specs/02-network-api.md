# Pigeon — Network API

Status: authoritative  
Scope: HTTP contract, Servant types, headers, status codes, streaming, compression  
Related: `00-overview.md`, `01-architecture.md`, `03-storage.md`, `04-server.md`, `06-security.md`

## 1. Base rules

- **NET-001** The metadata API is versioned under `/api/v1`.
- **NET-002** API requests and responses use UTF-8 JSON, except upload/download bodies.
- **NET-003** All timestamps in JSON are RFC3339 UTC with second precision and a literal `Z`, for example `2026-11-07T10:00:00Z`.
- **NET-004** Upload and download bodies are streamed. No endpoint may buffer a complete file.
- **NET-005** API responses set `Cache-Control: no-store`.
- **NET-006** There is no CORS support. Browser cross-origin calls are not expected.
- **NET-007** There are no redirects. Clients must set `redirectCount = 0`.
- **NET-008** Range requests are not supported. A `Range` header is ignored and the full file is returned with `200`.
- **NET-009** The only accepted request content encodings for uploads are identity (absent or `identity`) and `gzip`.

## 2. Servant API types

`Pigeon.API` defines exactly this contract. Server and client must both use it.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Pigeon.API
  ( PigeonAPI
  , WebAPI
  , FullAPI
  , UploadBody
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import Servant
import Servant.API.ContentTypes (OctetStream)
import Servant.API.Stream (NoFraming, StreamBody)
import Servant.Conduit ()          -- ConduitT ToSourceIO/FromSourceIO instances
import Data.Conduit (ConduitT)
import Control.Monad.Trans.Resource (ResourceT)
import qualified Data.ByteString as BS

import Pigeon.Types (FileId, FileInfo, Health)

type UploadBody = ConduitT () BS.ByteString (ResourceT IO) ()

type PigeonAPI =
       "api" :> "v1" :> "files"
         :> Header "Authorization" Text
         :> QueryParam "filename" Text
         :> QueryParam "expires_in" Int64
         :> QueryParam "content_type" Text
         :> Header "Content-Encoding" Text
         :> Header "X-Pigeon-Password" Text
         :> StreamBody NoFraming OctetStream UploadBody
         :> PostCreated '[JSON] FileInfo

  :<|> "api" :> "v1" :> "files"
         :> Header "Authorization" Text
         :> Get '[JSON] [FileInfo]

  :<|> "api" :> "v1" :> "files" :> Capture "id" FileId
         :> Header "Authorization" Text
         :> DeleteNoContent

  :<|> "healthz"
         :> Get '[JSON] Health

-- The public browser route is a Raw application so one handler can return
-- either an HTML form or a streamed file with the correct status and headers.
type WebAPI =
       "f" :> Capture "id" FileId :> Raw
  :<|> "robots.txt" :> Get '[PlainText] Text

type FullAPI = PigeonAPI :<|> WebAPI
```

`WebAPI` is server-only. The client imports `PigeonAPI`, not `FullAPI`.

The server handler for `Capture "id" FileId :> Raw` has the shape:

```haskell
webHandler :: AppEnv -> FileId -> Application
```

`robotsHandler :: Handler Text` returns `User-agent: *\nDisallow: /\n`.

## 3. Authentication

- **NET-010** Every `/api/v1` endpoint requires `Authorization: Bearer <token>`.
- **NET-011** The scheme name is case-insensitive; exactly one ASCII space separates it from the token.
- **NET-012** The token is compared byte-for-byte with a constant-time comparison.
- **NET-013** Missing, malformed, or incorrect credentials return `401` with `WWW-Authenticate: Bearer realm="pigeon"` and the standard API error body.
- **NET-014** `/healthz`, `/f/:id`, and `/robots.txt` do not require authentication.
- **NET-015** The token is never accepted from a query parameter or cookie.

## 4. Endpoints

### 4.1 `POST /api/v1/files`

Upload a file.

Query parameters:

| Name | Type | Required | Meaning |
| --- | --- | --- | --- |
| `filename` | UTF-8 text | No | Display filename. Default `file`. Sanitized by the server. |
| `expires_in` | integer seconds | No | Lifetime. If omitted, the server's default expiry applies. |
| `content_type` | ASCII text | No | Original content type. Default `application/octet-stream`. |

Headers:

| Name | Required | Meaning |
| --- | --- | --- |
| `Authorization` | Yes | `Bearer <token>` |
| `Content-Encoding` | No | `gzip` or `identity`/absent |
| `X-Pigeon-Password` | No | Unpadded base64url of the UTF-8 password, 1–1024 bytes decoded |
| `Content-Type` | Yes | `application/octet-stream` (the body type, not the file type) |

Body: raw octet stream, optionally gzip-compressed.

Semantics:

- **NET-020** Authentication is checked before the request body is consumed. An unauthenticated request must not write a temp file.
- **NET-021** If `expires_in` is absent, the server computes `expires_at = now + default_expiry`.
- **NET-022** If `expires_in` is present, it MUST be an integer in `1 .. max_expiry_seconds`; otherwise `400 invalid_request`.
- **NET-023** The server always stores the blob gzip-compressed:
  - `Content-Encoding: gzip`: received bytes are written to a temp file as-is while the same chunks are streamed through `ungzip`, in one pass, to validate the stream and compute the original size.
  - absent/`identity`: received bytes are counted and gzip-compressed while writing to the temp file.
- **NET-024** Invalid gzip data returns `400 invalid_request` and removes the temp file.
- **NET-025** If `max_upload_size > 0`, the server enforces it against both received bytes and decompressed original bytes. Exceeding it returns `413 payload_too_large` and removes the temp file.
- **NET-026** The final blob is `data/files/<id>.gz`; metadata is committed only after the temp file has been renamed.
- **NET-027** The response is `201 Created` with a `FileInfo` object.
- **NET-028** The `url` field is absolute, built from the server's configured public URL and the file ID.
- **NET-029** A malformed `X-Pigeon-Password` (invalid base64url, empty decoded value, or more than 1024 decoded bytes) returns `400 invalid_request`.
- **NET-030** Passwords are byte-exact UTF-8; no trimming, case folding, or Unicode normalization is performed.

Response headers:

```
Cache-Control: no-store
Content-Type: application/json; charset=utf-8
```

Response body:

```json
{
  "id": "7q3m9x2k4v8p1c6d",
  "filename": "report.pdf",
  "size": 12345678,
  "contentType": "application/pdf",
  "createdAt": "2026-10-31T10:00:00Z",
  "expiresAt": "2026-11-07T10:00:00Z",
  "hasPassword": true,
  "url": "https://files.example.com/f/7q3m9x2k4v8p1c6d"
}
```

### 4.2 `GET /api/v1/files`

List live files.

- **NET-031** Requires authentication.
- **NET-032** Returns only files with `expires_at > now`.
- **NET-033** Results are ordered by `created_at DESC, id ASC`.
- **NET-034** The response is `200` with a JSON array of `FileInfo`. An empty result is `[]`.
- **NET-035** `size` is the original uncompressed size. The compressed size is not exposed in v1.

### 4.3 `DELETE /api/v1/files/{id}`

Delete a file.

- **NET-036** Requires authentication.
- **NET-037** A valid, existing ID returns `204 No Content`.
- **NET-038** An existing but already-expired row may be deleted and returns `204`.
- **NET-039** An unknown ID returns `404 not_found`.
- **NET-040** A malformed ID returns `400 invalid_request` on the API. The browser route treats malformed IDs as `404`.
- **NET-041** The metadata row is removed in a committed transaction before the blob is unlinked. If unlink fails, the response is still `204`; the orphan is cleaned later.
- **NET-042** The response has no body and `Cache-Control: no-store`.

### 4.4 `GET /healthz`

- **NET-043** Public, no authentication.
- **NET-044** Checks the SQLite connection with `SELECT 1`.
- **NET-045** Healthy: `200` with `{"status":"ok","version":"0.1.0.0"}`.
- **NET-046** Unhealthy: `503` with `{"status":"unavailable","version":"0.1.0.0"}`.
- **NET-047** Health responses set `Cache-Control: no-store`.

### 4.5 `GET /f/{id}`

Public download page.

- **NET-050** Unknown, expired, or malformed ID returns `404` with a small HTML page: `File not found or expired.` The response must not reveal whether the ID ever existed.
- **NET-051** If the file has no password, the server returns the file stream with the headers in section 5.
- **NET-052** If the file has a password, the server returns `200 text/html` with a password form. The form posts to the same URL.
- **NET-053** `HEAD` returns the same status and headers as `GET` but no body.
- **NET-054** Methods other than `GET`, `HEAD`, and `POST` return `405` with `Allow: GET, HEAD, POST`.

### 4.6 `POST /f/{id}`

Password form submission.

- **NET-060** Content type MUST be `application/x-www-form-urlencoded`; otherwise `415` with an HTML error page.
- **NET-061** The request body is limited to 8192 bytes. Larger bodies return `413` with an HTML error page.
- **NET-062** The form field is `password`. It must appear exactly once. Missing or duplicate fields are treated as a failed attempt (`401`).
- **NET-063** If the file has no password, the file is streamed regardless of the submitted value.
- **NET-064** If the file has a password, the server verifies it with the stored KDF parameters. A wrong password returns `401 text/html` and re-renders the form with `Incorrect password.`
- **NET-065** A correct password streams the file with the headers in section 5.
- **NET-066** Password comparison is constant-time at the digest comparison step.
- **NET-067** The password value is never logged, reflected in HTML, or placed in a URL.
- **NET-068** POST responses set `Cache-Control: no-store`.

### 4.7 `GET /robots.txt`

- **NET-069** Returns `text/plain; charset=utf-8` with:
  ```
  User-agent: *
  Disallow: /
  ```

## 5. File response headers

Every successful `/f/{id}` file response sets:

```
Content-Type: <sanitized stored content type>
Content-Disposition: attachment; filename="<ascii fallback>"; filename*=UTF-8''<percent-encoded UTF-8 filename>
X-Content-Type-Options: nosniff
Cache-Control: no-store
Referrer-Policy: no-referrer
X-Robots-Tag: noindex, nofollow
X-Frame-Options: DENY
Vary: Accept-Encoding
```

- **NET-070** `Content-Disposition` is always `attachment`.
- **NET-071** The ASCII fallback replaces non-ASCII, quote, backslash, CR, and LF characters with `_`.
- **NET-072** The `filename*` value is RFC 5987 percent-encoded UTF-8.
- **NET-073** The stored content type is sanitized at upload time. If it contains control characters, CR, LF, or non-ASCII bytes, the server substitutes `application/octet-stream`.
- **NET-074** A `Content-Encoding: gzip` response includes `Content-Length: <size_stored>`.
- **NET-075** An identity response has no `Content-Length` and is sent with chunked transfer encoding.

## 6. Compression negotiation

### 6.1 Upload

- **NET-080** `Content-Encoding: gzip` means the request body is a valid gzip stream.
- **NET-081** Absent or `Content-Encoding: identity` means raw bytes.
- **NET-082** Any other value returns `415 unsupported_media_type`.
- **NET-083** The server does not trust the declared original size. It computes the original size by decompressing the gzip stream once, in the same pass that writes the received bytes.

### 6.2 Download

- **NET-084** The server parses `Accept-Encoding` including q-values and the `*` wildcard.
- **NET-085** If gzip is acceptable (`q > 0`), the stored gzip bytes are streamed unchanged with `Content-Encoding: gzip`.
- **NET-086** If gzip is not acceptable but identity is, the blob is decompressed on the fly and streamed as identity.
- **NET-087** If neither gzip nor identity is acceptable, return `406 Not Acceptable`.
- **NET-088** `Vary: Accept-Encoding` is always set on file responses.
- **NET-089** Only `gzip` and `identity` are supported. `br` and `zstd` are not negotiated in v1.

### 6.3 JSON and HTML

- **NET-090** API JSON and HTML responses MAY be gzip-compressed by middleware when the client accepts gzip.
- **NET-091** The gzip middleware MUST NOT be applied to `/f/{id}` file streams; those responses set their own `Content-Encoding`.
- **NET-092** A response that already has `Content-Encoding` must not be compressed again.

## 7. Error model

API errors use this body:

```json
{
  "error": {
    "code": "invalid_request",
    "message": "expires_in must be an integer between 1 and 31536000 seconds"
  }
}
```

- **NET-100** `Content-Type: application/json; charset=utf-8`.
- **NET-101** No stack traces, SQL text, filesystem paths, or internal exception messages.
- **NET-102** Errors set `Cache-Control: no-store`.

Codes:

| HTTP | `code` | When |
| --- | --- | --- |
| 400 | `invalid_request` | Bad query value, bad gzip, malformed password header, malformed ID, bad form field |
| 401 | `unauthorized` | Missing/invalid bearer token; wrong file password on POST |
| 404 | `not_found` | Unknown, deleted, or expired file |
| 405 | `method_not_allowed` | Unsupported method on `/f/{id}` |
| 406 | `not_acceptable` | No acceptable response encoding |
| 413 | `payload_too_large` | Upload or form exceeds a limit |
| 415 | `unsupported_media_type` | Unsupported upload/content encoding or form content type |
| 500 | `internal_error` | Unhandled server failure |
| 503 | `unavailable` | Health check failure |

`401` API responses include `WWW-Authenticate: Bearer realm="pigeon"`. The browser password form returns HTML, not the JSON error body.

Browser error pages are static, escaped, and never include the requested ID, password, or exception text.

## 8. Examples

### 8.1 Upload with default expiry

```bash
curl -sS \
  -H "Authorization: Bearer $PIGEON_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @report.pdf \
  "https://files.example.com/api/v1/files?filename=report.pdf&content_type=application%2Fpdf"
```

### 8.2 Upload with explicit expiry and gzip

```bash
gzip -c report.pdf | curl -sS \
  -H "Authorization: Bearer $PIGEON_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  -H "Content-Encoding: gzip" \
  --data-binary @- \
  "https://files.example.com/api/v1/files?filename=report.pdf&expires_in=604800"
```

### 8.3 Upload with password

```bash
PW_B64=$(printf '%s' 'correct horse battery staple' | base64 -w0 | tr '+/' '-_' | tr -d '=')
curl -sS \
  -H "Authorization: Bearer $PIGEON_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  -H "X-Pigeon-Password: $PW_B64" \
  --data-binary @secret.zip \
  "https://files.example.com/api/v1/files?filename=secret.zip&expires_in=86400"
```

### 8.4 List

```bash
curl -sS \
  -H "Authorization: Bearer $PIGEON_TOKEN" \
  https://files.example.com/api/v1/files
```

### 8.5 Delete

```bash
curl -sS -X DELETE \
  -H "Authorization: Bearer $PIGEON_TOKEN" \
  https://files.example.com/api/v1/files/7q3m9x2k4v8p1c6d
```

### 8.6 Download

```bash
curl -sS -OJ https://files.example.com/f/7q3m9x2k4v8p1c6d
```

### 8.7 Password-protected download

```bash
curl -sS -OJ \
  --data-urlencode 'password=correct horse battery staple' \
  https://files.example.com/f/7q3m9x2k4v8p1c6d
```

### 8.8 Health

```bash
curl -sS https://files.example.com/healthz
```

## 9. Password header encoding

`X-Pigeon-Password` is the unpadded base64url encoding of the UTF-8 password bytes:

```
X-Pigeon-Password: Y29ycmVjdCBob3JzZSBiYXR0ZXJ5IHN0YXBsZQ
```

- **NET-110** Alphabet: `A-Z`, `a-z`, `0-9`, `-`, `_`; no `=`.
- **NET-111** `+` and `/` are not accepted.
- **NET-112** Decoding must reject invalid characters, invalid length, and non-canonical trailing bits.
- **NET-113** The decoded password must be 1–1024 bytes.
- **NET-114** The header is never logged or included in error messages.

## 10. Compatibility and versioning

- **NET-120** Adding an optional query parameter or response field is backward compatible within `v1`.
- **NET-121** Removing/renaming a field, changing a status code, or changing compression semantics requires `/api/v2`.
- **NET-122** File IDs are opaque. Clients must not parse them beyond validating the alphabet for local sanity checks.
- **NET-123** The `url` field is authoritative for sharing; clients must not construct URLs from the base URL and ID when `url` is present.

## 11. Network acceptance criteria

- **NET-A01** An unauthenticated upload returns `401` and leaves no temp file or row.
- **NET-A02** An upload without `expires_in` returns an `expiresAt` approximately `now + default_expiry`.
- **NET-A03** An upload with `expires_in = 0`, negative, or above `max_expiry` returns `400`.
- **NET-A04** A gzip upload and an identity upload of the same bytes produce identical downloads and identical original sizes.
- **NET-A05** A download with `Accept-Encoding: gzip` returns `Content-Encoding: gzip`; with `identity` it returns the original bytes without `Content-Encoding`.
- **NET-A06** A wrong password returns `401` and does not stream any file bytes.
- **NET-A07** A correct password streams the exact original file.
- **NET-A08** A deleted or expired file returns `404` on both the API delete and the public URL.
- **NET-A09** `HEAD /f/{id}` returns the same headers as `GET` and no body.
- **NET-A10** `Content-Disposition` contains both an ASCII fallback and RFC 5987 `filename*` for Unicode names.
