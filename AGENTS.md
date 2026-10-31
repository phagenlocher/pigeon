# Pigeon — Agent Guide

Pigeon is a small file-publishing service:

- `pigeon-server` accepts authenticated uploads, stores them gzip-compressed, and publishes them at unguessable public URLs.
- `pigeon-client` is the terminal client used to upload, list, and delete files.
- Browser clients can download files. A file may optionally be protected by a per-file password.

The system is deliberately narrow: one shared upload token, no accounts, no web management UI, no client-side download command in v1.

## Read this first

The specifications in `specs/` are the source of truth. Read them before changing behavior:

1. `specs/00-overview.md` — goals, actors, non-goals
2. `specs/01-architecture.md` — components, modules, dependencies
3. `specs/02-network-api.md` — HTTP contract
4. `specs/03-storage.md` — filesystem and SQLite
5. `specs/04-server.md` — server configuration and lifecycle
6. `specs/05-client.md` — CLI commands and streaming upload
7. `specs/06-security.md` — threat model and security rules
8. `specs/07-testing.md` — test matrix and acceptance criteria

Requirements have stable IDs such as `NET-004`, `STORE-011`, `SRV-003`. Tests and code comments should refer to them when a behavior is non-obvious.

If implementation and specification disagree, **the specification wins** until it is deliberately changed. A behavior change is not complete until the relevant spec is updated in the same change.

## Commands

```bash
cabal build all
cabal test all

cabal run pigeon-server -- --help
cabal run pigeon-client -- --help

# Development server (plain HTTP, explicit opt-in)
cabal run pigeon-server -- \
  --no-tls \
  --token dev-token-at-least-16-chars \
  --data-dir ./data

# Development client
cabal run pigeon-client -- \
  --server http://127.0.0.1:8080 \
  --token dev-token-at-least-16-chars \
  upload ./some-file.bin --expires-in 7d

# Formatting and linting
fourmolu -i src app test
hlint src app test
```

Production-style invocation:

```bash
cabal run pigeon-server -- \
  --host 0.0.0.0 \
  --port 8443 \
  --token-file /etc/pigeon/token \
  --tls-cert /etc/pigeon/tls/fullchain.pem \
  --tls-key /etc/pigeon/tls/privkey.pem \
  --public-url https://files.example.com \
  --data-dir /var/lib/pigeon
```

## Repository map

```
AGENTS.md
fourmolu.yaml                -- formatter style (2-space indent, 100 columns, trailing commas)
pigeon.cabal
app/
  Server.hs                 -- pigeon-server entry point
  Client.hs                 -- pigeon-client entry point
src/Pigeon/
  API.hs                    -- Servant API types shared by client and server
  Types.hs                  -- FileId, FileInfo, errors, health, stored-file types
  Duration.hs               -- duration parser and formatter
  Password.hs               -- PBKDF2 password hashing wrapper
  Streaming.hs              -- gzip/ungzip, byte counting, Accept-Encoding parsing
  Config.hs                 -- shared option/env helpers
  Server/
    App.hs                  -- App reader monad and MonadLogger
    Config.hs               -- server options and validation
    Db.hs                   -- SQLite connection, schema, queries
    Storage.hs              -- temp files, atomic rename, blob streams
    Env.hs                  -- shared AppEnv record
    Handlers.hs             -- authenticated JSON API handlers
    Web.hs                  -- /f/:id download and password form
    Sweeper.hs              -- expiry and orphan cleanup
    Auth.hs                 -- bearer-token check
    Log.hs                  -- request and application logging
  Client/
    Config.hs               -- client options and token resolution
    Api.hs                  -- Servant client environment and error mapping
    Commands.hs             -- upload/list/delete implementations
    Output.hs               -- tables, JSON, progress, formatting
test/
  Spec.hs                   -- hspec entry point
  ...                       -- unit and integration tests
specs/                      -- authoritative specifications
```

## Architecture at a glance

```
pigeon-client ──HTTPS + gzip──▶ pigeon-server ──▶ SQLite metadata
                                      │
                                      ├──▶ data/files/<id>.gz
                                      └──▶ data/tmp/*.part

browser ──HTTPS──▶ /f/<id> ──▶ password form (optional) ──▶ gzip or decompressed stream
```

The server never buffers a whole file. Uploads and downloads use `ConduitT`/`SourceIO` streams. SQLite stores metadata only; blobs live on disk.

## Non-negotiable invariants

- **Stream everything.** No code path may read an entire upload or download into memory. Do not use `readFile`, `BS.readFile`, or `strictRequestBody` for upload/download content.
- **Every stored file has an expiry.** The API may omit `expires_in`, but the server always applies its configured default. There is no "never expires" value.
- **All blobs are gzip on disk.** A gzip upload is stored as received; an identity upload is compressed by the server while streaming to disk.
- **Filenames are metadata, never paths.** Blob paths are derived only from server-generated IDs.
- **Never hold the SQLite lock while streaming.** Fetch or commit short metadata transactions, release the lock, then do file I/O.
- **TLS is the default.** `--no-tls` is an explicit development-only opt-out.
- **Secrets stay out of logs and URLs.** Never log the bearer token, `X-Pigeon-Password`, form passwords, or query strings.
- **No web management UI.** Only the public download page and password form are browser-facing.
- **No Range requests, no resumable downloads, no client download command in v1.**

## Spec index

| Spec | Covers |
| --- | --- |
| `specs/00-overview.md` | Product scope, actors, flows, non-goals |
| `specs/01-architecture.md` | Components, module boundaries, dependencies |
| `specs/02-network-api.md` | Endpoints, headers, status codes, streaming, compression |
| `specs/03-storage.md` | SQLite schema, durability, blob layout, expiry, cleanup |
| `specs/04-server.md` | Configuration, TLS, lifecycle, logging, web route |
| `specs/05-client.md` | CLI grammar, upload pipeline, output, exit codes |
| `specs/06-security.md` | Auth, passwords, path safety, headers, residual risks |
| `specs/07-testing.md` | Unit/integration/TLS/streaming tests, acceptance criteria |

## Development workflow

1. Read the relevant spec and identify the requirement IDs you are implementing.
2. Change the API type in `src/Pigeon/API.hs` first if the contract changes.
3. Implement the smallest change that satisfies the requirement.
4. Add or update tests that name the requirement.
5. Update the spec if behavior or rationale changed.
6. Update `CHANGELOG.md` for user-visible changes.
7. Run `cabal build all`, `cabal test all`, `fourmolu --mode check`, and `hlint`.
8. Confirm no secrets or file contents appear in logs or test output.

## Haskell conventions

- GHC2024, GHC 9.14.x, cabal 3.16.x.
- `-Wall` must stay clean. Do not add blanket `-Wno-*` flags; suppress a specific warning only with a comment explaining why.
- Use `Text` for user-facing text and database text; `ByteString` for bytes and streams; `FilePath` only for local paths.
- Server orchestration runs in `App` (`Pigeon.Server.App`), a reader monad over `AppEnv`. Obtain the logger with `askLogger` from `MonadLogger`; do not thread `Logger` arguments through application code.
- Use `Control.Exception.Safe` for exception handling. Do not import `Control.Exception` in application modules.
- Use `OverloadedStrings` and explicit imports for non-obvious names.
- Prefer total functions. Avoid `head`, `fromJust`, `read`, and unchecked pattern matches in production code. Use `case` or `Maybe`/`Either`.
- `error` and `undefined` are allowed only for genuinely unreachable invariants, with a comment explaining the invariant.
- No `unsafePerformIO`.
- All SQL must be parameterized. Never interpolate user input into SQL.
- All exported functions and non-obvious internal functions get Haddock comments.
- **Local type signatures.** Every definition in a `where` clause gets an explicit type signature, including simple values. A `let`-bound function also gets one, as does a non-trivial value: one whose right-hand side spans multiple lines or is a `case`, `if`, `do`, or lambda. Simple one-line aliases and destructuring bindings may omit it. Class and instance method bodies are exempt because their type comes from the class. Write the concrete type the call sites use, not GHC's inferred polymorphic type, unless the helper is genuinely generic. `-Wmissing-local-signatures` is enabled and must stay clean, but it only catches polymorphic local bindings; the monomorphic majority is enforced by review.
- **Every comment is a Haddock.** Use only `-- |`, `-- ^`, `{- | … -}`, and `-- *` section headings. Do not write plain `--` notes or `-- ----` banners. A note that cannot attach to a declaration, such as one on a local binding or inside a `do` block, is folded into the Haddock of the nearest enclosing declaration.
- **Strict fields:** add `!` only where strictness measurably helps: small counters, hot-loop state, and records used in tight streaming or database loops. Do not add strictness mechanically to every field; laziness is often correct for optional or large values.
- Keep modules focused. API types belong in `Pigeon.API`; shared domain types belong in `Pigeon.Types`.
- Use fourmolu for formatting. Do not hand-format around it. The style lives in `fourmolu.yaml`: 2-space indent, a 100-column limit, trailing commas, sorted constraints and deriving clauses, and `Pigeon.*` imports in their own group. A style change means running `fourmolu -i src app test` in the same commit.

## Error handling

- Server API errors return the JSON shape in `specs/02-network-api.md`.
- Browser-facing errors return small HTML pages; never echo unescaped user input.
- Client errors go to stderr. Human mode uses one concise line; `--json` mode uses the documented JSON error object.
- Never expose SQL errors, filesystem paths, or stack traces to clients.
- Log the detailed cause server-side with the request ID or file ID.

## Security rules

- Compare bearer tokens with a constant-time comparison.
- Passwords use the `password` package's PBKDF2-HMAC-SHA512 implementation as specified in `specs/06-security.md`; do not substitute a fast unkeyed hash or a hand-rolled KDF.
- Never put a password or token in a URL, query string, or log line.
- Sanitize filenames for `Content-Disposition`; use RFC 5987 encoding for non-ASCII names.
- Serve downloads as `Content-Disposition: attachment` with `X-Content-Type-Options: nosniff`.
- Validate IDs before using them in a filesystem path.
- Do not follow symlinks when opening blobs; blobs are created by the server.
- Preserve `synchronous=FULL` and `journal_mode=DELETE`. Do not enable WAL; this project requires committed transactions to be durable in the main database file.

## Testing

- Use `hspec` for unit and integration tests.
- Use QuickCheck for parsers and streaming round-trips where useful.
- Integration tests run a real Warp server on an ephemeral port with a temporary data directory.
- Tests must cover both gzip and identity uploads, password-protected and open downloads, expiry defaults, and deletion.
- Do not weaken tests to make an implementation pass. If a requirement is wrong, change the spec deliberately.

## Definition of done

A change is done when:

- The relevant spec requirement is implemented.
- Unit and integration tests cover the behavior.
- `cabal build all` and `cabal test all` pass.
- `fourmolu --mode check src app test` and `hlint src app test` are clean.
- The spec and `CHANGELOG.md` are updated if behavior changed.
- No secrets, passwords, tokens, or file contents are logged.
- Streaming paths have been checked for accidental whole-file buffering.
