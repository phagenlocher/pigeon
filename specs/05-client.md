# Pigeon — Client

Status: authoritative  
Scope: `pigeon-client` CLI grammar, upload streaming, output, exit codes  
Related: `02-network-api.md`, `05-client.md` (this file), `06-security.md`

## 1. Client responsibilities

`pigeon-client` is a terminal client. It can:

- Upload a local file.
- List live files.
- Delete files by ID.

It cannot download files in v1. Browser downloads use `/f/:id`.

The executable is thin:

```haskell
-- app/Client.hs
main :: IO ()
main = do
  cfg <- parseClientConfig
  runClient cfg >>= exitWith
```

`runClient` lives in `Pigeon.Client`.

## 2. Command grammar

```text
pigeon-client [GLOBAL OPTIONS] COMMAND [COMMAND OPTIONS]

Commands:
  upload FILE [--expires-in DURATION] [--name NAME] [--content-type TYPE]
              [--password | --password-stdin] [--no-compress]
  list
  delete ID... [--yes]

Global options:
  --server URL             Server base URL (env: PIGEON_SERVER)
  --token TOKEN            Bearer token (env: PIGEON_TOKEN)
  --token-file FILE        Read the token from the first line of FILE
  --insecure               Disable TLS certificate validation (development only)
  --timeout DURATION       Request timeout (default: 1h)
  --json                   Machine-readable output
  --quiet                  Suppress progress and informational messages
  --verbose                Debug output on stderr
  --version                Print version
  --help                   Print help
```

- **CLI-001** Global options appear before the command. `pigeon-client upload --help` prints upload-specific help.
- **CLI-002** `--json` is global and affects `upload`, `list`, and `delete`.
- **CLI-003** `--quiet` and `--verbose` are mutually exclusive.
- **CLI-004** Unknown commands and options are usage errors with exit code `2`.
- **CLI-005** The client never downloads a file in v1.
- **CLI-006** `--help` and `--version` exit `0`. Parser failures must be mapped to exit `2` (use `execParserPure` and handle `ParserFailure` explicitly if the default `execParser` exit code differs).

## 3. Global configuration

### 3.1 Server URL

- **CLI-010** `--server` defaults to `PIGEON_SERVER`, then `http://127.0.0.1:8080`.
- **CLI-011** The URL must be absolute with scheme `http` or `https`, a host, an optional port, and no path, query, or fragment other than `/`.
- **CLI-012** A trailing `/` is removed before use.
- **CLI-013** The base URL is parsed with `servant-client`'s `parseBaseUrl`; a parse failure is a usage error.
- **CLI-014** If the scheme is `http` and a token will be sent, print this warning to stderr, even with `--quiet`:
  ```
  warning: sending the upload token over plain HTTP; use TLS outside development
  ```

### 3.2 Token

- **CLI-020** A token is required for `upload`, `list`, and `delete`.
- **CLI-021** Sources are `--token`, `--token-file`, and `PIGEON_TOKEN`.
- **CLI-022** If both `--token` and `--token-file` are supplied, that is a usage error.
- **CLI-023** Precedence is `--token`, then `--token-file`, then `PIGEON_TOKEN`.
- **CLI-024** Token validation matches the server: 16–512 printable ASCII characters, no whitespace.
- **CLI-025** `--token-file` reads the first line, strips trailing `\r`/`\n`, and rejects an empty result.
- **CLI-026** The token is held in a `Secret` newtype and never printed, even by `--verbose`.
- **CLI-027** A missing token is a usage error before any network call.

### 3.3 TLS

- **CLI-030** Certificate validation is enabled by default.
- **CLI-031** `--insecure` disables certificate validation for HTTPS and prints:
  ```
  warning: TLS certificate validation is disabled
  ```
- **CLI-032** `--insecure` has no effect on `http://` URLs.
- **CLI-033** Custom CA files are not supported in v1; use the system trust store or `--insecure` for development.
- **CLI-034** The HTTP manager sets `redirectCount = 0` so a token cannot be forwarded to another host.
- **CLI-035** The manager uses `tlsManagerSettings` by default and `mkManagerSettings (TLSSettingsSimple True False False) Nothing` with `--insecure`.

### 3.4 Timeout

- **CLI-040** `--timeout` defaults to `1h`.
- **CLI-041** The value uses the duration grammar in section 9 and must be at least `1s`.
- **CLI-042** The timeout is applied as the HTTP manager's response timeout. Large uploads should use the default or a larger value.
- **CLI-043** A timeout is a network failure (exit `5`).

## 4. `upload`

```text
pigeon-client [GLOBAL] upload FILE
  [--expires-in DURATION]
  [--name NAME]
  [--content-type TYPE]
  [--password | --password-stdin]
  [--no-compress]
```

### 4.1 Arguments and options

- **CLI-050** `FILE` is required and must be an existing regular file, readable by the client.
- **CLI-051** `--expires-in` is optional. If omitted, the client omits `expires_in` and the server applies its default expiry.
- **CLI-052** `--expires-in` accepts the duration grammar in section 9 and must be greater than zero. The server enforces its maximum expiry.
- **CLI-053** `--name` overrides the display filename. It defaults to `takeFileName FILE`. An empty name is a usage error.
- **CLI-054** `--content-type` overrides the original content type. It defaults to `application/octet-stream`. CR, LF, and other control characters are rejected locally.
- **CLI-055** `--password` prompts for a password without echo. It requires an interactive terminal.
- **CLI-056** `--password-stdin` reads one line from stdin. It is intended for scripts and tests.
- **CLI-057** `--password` and `--password-stdin` are mutually exclusive.
- **CLI-058** There is no `--password VALUE` option, to avoid leaking passwords into shell history and process lists.
- **CLI-059** `--no-compress` sends the body as identity. The default is gzip level 6.

### 4.2 Password input

- **CLI-060** A password is byte-exact UTF-8. Do not trim, case-fold, or normalize.
- **CLI-061** Strip only the trailing line ending from `--password-stdin`.
- **CLI-062** Reject an empty password and passwords longer than 1024 UTF-8 bytes.
- **CLI-063** Prompt on stderr, disable echo with `hSetEcho False`, and restore echo in a `bracket` even on exception.
- **CLI-064** Encode the password for the wire as unpadded base64url and send it in `X-Pigeon-Password`.
- **CLI-065** Never print the password in errors, debug output, or process arguments.

### 4.3 Upload pipeline

- **CLI-070** Open the file with `withBinaryFile path ReadMode` and use `sourceHandleChunked` with 128 KiB reads inside a `ConduitT () ByteString (ResourceT IO) ()`.
- **CLI-071** Count original bytes before compression, so progress and `size` reflect the local file.
- **CLI-072** If compression is enabled, pipe the stream through `parallelGzipConduit` and set `Content-Encoding: gzip`. It compresses 1 MiB blocks concurrently and emits one standard gzip stream (one header and trailer), never concatenated members. Progress and `size` are counted before compression.
- **CLI-073** If `--no-compress`, send identity and do not set `Content-Encoding`.
- **CLI-074** Send `filename`, `expires_in` (only if supplied), and `content_type` as query parameters, properly URL-encoded.
- **CLI-075** Send the body via the Servant `StreamBody` endpoint. Do not read the whole file first.
- **CLI-076** Do not set a `Content-Length`; the request is chunked.
- **CLI-077** The response is decoded as `FileInfo`. On success, print the result.
- **CLI-078** On failure, decode the standard API error body when present and map it to an exit code.
- **CLI-079** The file handle is closed after `runClientM` returns, whether the upload succeeded or failed.

### 4.4 Progress

- **CLI-080** Progress is shown only when stderr is a TTY, `--quiet` is not set, and `--json` is not set.
- **CLI-081** Progress is written to stderr, never stdout.
- **CLI-082** Format:
  ```
  Uploading report.pdf: 12.3 MiB / 45.6 MiB (27%)
  ```
  Every update begins with `\r` followed by `ESC[2K` (return to column 0 and erase the entire line) and emits no newline, so a shorter update cannot leave characters from a longer one. No final progress line or newline is printed.
- **CLI-083** Redraw at most every 75 ms (`progressIntervalMs`). When the upload finishes, whether it succeeded or failed, erase the progress line with `\r` followed by `ESC[2K` (erase entire line) before any other output, so the terminal is left with only the command's result or error.
- **CLI-084** If the file size is zero, the body has no chunks, so no progress line is displayed; the command prints only its result or error.
- **CLI-085** `--verbose` prints a start line before the body is sent and an end line once the response completes. Both go to stderr, prefixed `verbose:`, and may include the local path, display filename, byte size, server URL, content type, compression mode, file id, and elapsed milliseconds. The end line is printed after the progress line is erased. They never include the token, the password, or file contents.

### 4.5 Output

Human mode:

```
Uploaded report.pdf (12.4 MiB)
  id:       7q3m9x2k4v8p1c6d
  expires:  2026-11-07 10:00:00 UTC (6d 23h)
  password: yes
  url:      https://files.example.com/f/7q3m9x2k4v8p1c6d
```

- **CLI-090** Timestamps are displayed in UTC with `YYYY-MM-DD HH:MM:SS UTC`.
- **CLI-091** Remaining time is humanized: `6d 23h`, `23h 59m`, `59m`, `<1m`.
- **CLI-092** Sizes use binary units with one decimal: `0 B`, `1.0 KiB`, `12.4 MiB`, `1.2 GiB`.
- **CLI-093** `password` is `yes` or `no`.
- **CLI-094** The `url` is printed exactly as returned by the server.

JSON mode:

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

- **CLI-095** JSON is a single object, compact or pretty, followed by a newline.
- **CLI-096** JSON output goes to stdout; warnings and errors remain on stderr.

## 5. `list`

```text
pigeon-client [GLOBAL] list
```

- **CLI-100** Fetches `GET /api/v1/files`.
- **CLI-101** The server already filters expired files.
- **CLI-102** Human mode prints a table:
  ```
  ID                NAME                           SIZE      EXPIRES (UTC)        LEFT      PW
  7q3m9x2k4v8p1c6d  report.pdf                     12.4 MiB  2026-11-07 10:00:00  6d 23h    yes
  8r4n0y3l5w9q2d7e  photo.jpg                      2.1 MiB   2026-11-01 08:30:00  22h 30m   no
  ```
- **CLI-103** Columns are separated by two spaces. Names longer than 40 display characters are truncated with `...`; `--json` contains the full name.
- **CLI-104** If the list is empty, print `No files.`
- **CLI-105** `--json` prints a JSON array of `FileInfo` objects, `[]` when empty.
- **CLI-106** The table goes to stdout. No progress is shown.
- **CLI-107** The client does not sort locally; it preserves server order.

## 6. `delete`

```text
pigeon-client [GLOBAL] delete ID... [--yes]
```

- **CLI-110** At least one ID is required.
- **CLI-111** IDs are passed to the server unchanged; the server validates them.
- **CLI-112** Without `--yes`, prompt on stderr:
  ```
  Delete 2 files? [y/N]
  ```
- **CLI-113** When stdin is a TTY, accept `y` or `yes` case-insensitively. Anything else, empty input, or EOF means cancel.
- **CLI-114** If stdin is not a TTY and `--yes` is not supplied, exit `2` with a usage error instead of blocking.
- **CLI-115** Canceled deletion exits `8` and deletes nothing.
- **CLI-116** Deletes are attempted sequentially. A failure does not stop later IDs.
- **CLI-117** Exit `0` only if every delete succeeds; otherwise exit `1`, or the mapped error code if exactly one distinct failure class occurred.
- **CLI-118** Human success output:
  ```
  Deleted 7q3m9x2k4v8p1c6d
  ```
- **CLI-119** Human failure output:
  ```
  error: 7q3m9x2k4v8p1c6d: file not found
  ```
- **CLI-120** JSON mode:
  ```json
  {
    "deleted": ["7q3m9x2k4v8p1c6d"],
    "failed": [
      {"id": "8r4n0y3l5w9q2d7e", "code": "not_found", "message": "File not found"}
    ]
  }
  ```
- **CLI-121** JSON goes to stdout even on partial failure; the exit code still reflects failure.

## 7. Error handling and exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Generic failure (bad request, partial delete failure, unexpected response) |
| `2` | Usage error: bad flags, missing token, missing file argument, non-TTY confirmation without `--yes` |
| `3` | Authentication failure (`401`/`403`) |
| `4` | Not found (`404`) |
| `5` | Network, DNS, timeout, or TLS failure |
| `6` | Server error (`5xx`) |
| `7` | Local file error: missing, unreadable, not a regular file, permission denied |
| `8` | User canceled a confirmation |

- **CLI-130** HTTP `401`/`403` maps to `3` and prints the server message if available.
- **CLI-131** HTTP `404` maps to `4`.
- **CLI-132** HTTP `5xx` maps to `6`.
- **CLI-133** Other HTTP `4xx` maps to `1` with the server's `error.message`.
- **CLI-134** `ClientError` connection/TLS exceptions map to `5`; do not print raw exception types unless `--verbose`.
- **CLI-135** Local file exceptions map to `7`.
- **CLI-136** Human errors are one line on stderr:
  ```
  error: <message>
  ```
- **CLI-137** JSON errors are a single object on stderr:
  ```json
  {"error":{"code":"unauthorized","message":"Missing or invalid bearer token"}}
  ```
- **CLI-138** `--verbose` may print stack context, but never the token or password.
- **CLI-139** `SIGINT` uses the default process behavior; no custom exit code is required.

## 8. HTTP client details

- **CLI-140** The client uses `servant-client` with `PigeonAPI`.
- **CLI-141** A single `Manager` is created per process.
- **CLI-142** `managerResponseTimeout` is set from `--timeout`.
- **CLI-143** `redirectCount = 0`.
- **CLI-144** `Authorization: Bearer <token>` is attached to all API calls.
- **CLI-145** `Accept-Encoding: gzip` is sent by the HTTP library for JSON responses; the client transparently decompresses them.
- **CLI-146** Upload responses are small JSON; buffering them is acceptable.
- **CLI-147** List responses are small JSON; buffering them is acceptable.
- **CLI-148** `--verbose` logs method, path, status, and duration to stderr, but not headers or bodies.

## 9. Duration grammar

Both `--expires-in` and `--timeout` use:

```
duration := unit+
unit     := integer ("s" | "m" | "h" | "d" | "w")
```

- **CLI-150** Units are case-insensitive.
- **CLI-151** No whitespace, decimals, or signs.
- **CLI-152** Examples: `30m`, `12h`, `7d`, `2w`, `1d12h`.
- **CLI-153** The total must be greater than zero and fit in a signed 64-bit second count.
- **CLI-154** `1d12h` is 129600 seconds.
- **CLI-155** The server's duration parser accepts the same grammar for its configuration options.

## 10. Examples

```bash
# Upload with the server's default expiry
pigeon-client --server https://files.example.com --token-file ~/.pigeon-token \
  upload ./report.pdf

# Upload with a one-day expiry and a prompted password
pigeon-client --server https://files.example.com --token-file ~/.pigeon-token \
  upload ./secret.zip --expires-in 24h --password

# Upload without network compression
pigeon-client --server https://files.example.com --token-file ~/.pigeon-token \
  upload ./already-compressed.tar.gz --expires-in 7d --no-compress

# Password from stdin for scripts
printf '%s\n' 'correct horse battery staple' |
  pigeon-client --server https://files.example.com --token "$PIGEON_TOKEN" \
    upload ./secret.zip --expires-in 1d --password-stdin

# List
pigeon-client --server https://files.example.com --token-file ~/.pigeon-token list

# List as JSON
pigeon-client --json --server https://files.example.com --token-file ~/.pigeon-token list

# Delete one file
pigeon-client --server https://files.example.com --token-file ~/.pigeon-token \
  delete 7q3m9x2k4v8p1c6d

# Delete without confirmation in a script
pigeon-client --server https://files.example.com --token "$PIGEON_TOKEN" \
  delete 7q3m9x2k4v8p1c6d 8r4n0y3l5w9q2d7e --yes
```

## 11. Client acceptance criteria

- **CLI-A01** A 1 GiB upload succeeds without the client reading the file into memory.
- **CLI-A02** Default `upload` omits `expires_in` and the server applies its default expiry.
- **CLI-A03** `--expires-in 7d` sends `expires_in=604800`.
- **CLI-A04** `--no-compress` sends no `Content-Encoding` and the upload still succeeds.
- **CLI-A05** A password of 200 UTF-8 bytes is accepted and works for download; there is no legacy 72-byte truncation.
- **CLI-A06** A wrong password for download is not a client concern in v1; the browser form handles it.
- **CLI-A07** `--json` upload output is a valid `FileInfo` object.
- **CLI-A08** `list` with `--json` outputs a valid array and preserves server order.
- **CLI-A09** `delete` without `--yes` prompts on a TTY; answering `n` exits `8` and deletes nothing.
- **CLI-A10** `delete` with a non-TTY stdin and no `--yes` exits `2`.
- **CLI-A11** Missing token exits `2` before any network request.
- **CLI-A12** Wrong token exits `3`.
- **CLI-A13** Unknown delete ID exits `4`.
- **CLI-A14** A server `500` exits `6`.
- **CLI-A15** A missing local file exits `7`.
- **CLI-A16** A token is never visible in process arguments when `--token-file` or `PIGEON_TOKEN` is used.
- **CLI-A17** The client refuses to follow HTTP redirects.
