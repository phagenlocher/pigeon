# Revision history for pigeon

## Unreleased

* Added user tokens. The configured `--token` is now the admin token; the admin
  can create, list, and delete user tokens with `pigeon-client token` or the
  `/api/v1/tokens` endpoints. User tokens can upload, list, and delete only
  their own files, and the admin list shows each file's owning token
  (OV-032…OV-040, NET-140…NET-152, CLI-160…CLI-168).

* User tokens have an optional expiry. Deleting or expiring a token deletes all
  files it owns, including their blobs and URLs.

* Blobs are now stored per owner under `data/files/<owner-id>/<file-id>.gz`
  instead of directly under `data/files/`. The schema remains at
  `user_version = 1`; there is no migration, so an existing development data
  directory must be recreated (STORE-A13).

* Existing admin uploads now carry `owner: "admin"` in `FileInfo`; user uploads
  carry their token ID.

## 0.1.2.0 -- 2026-11-15

* Gzip uploads are now validated as exactly one complete gzip member. A stream
  that ends before the member trailer, or that has bytes after the member
  (including a second concatenated member), is rejected with `400
  invalid_request` and leaves no row, blob, or temp file. Previously a
  truncated upload could be published and later downloaded as a silently
  short or empty file, and a second member bypassed `--max-upload-size` and
  the reported `size` (NET-023, NET-024, STORE-062, SEC-113).

* Upload expiry now starts when the upload body has finished storing, not when
  the request starts. `created_at` and `expires_at` are both anchored at
  completion, so a slow upload keeps its full advertised lifetime (NET-021,
  STORE-100, SRV-081).

## 0.1.1.0 -- 2026-11-07

* `pigeon-client` reads defaults from a TOML configuration file. Use
  `--config FILE`, or place it at `$XDG_CONFIG_HOME/pigeon/config.toml`
  (`~/.config/pigeon/config.toml` by default). Supported keys are `server`,
  `token`, `token-file`, `insecure`, and `no-http-warning`. Precedence is CLI
  flag, then environment variable, then config file, then built-in default
  (CLI-044 to CLI-049).

* Config file errors never echo `token` or `token-file` values, and `~` in a
  config path expands to the home directory (CLI-045, CLI-048).

* `pigeon-client upload FILE` works with no flags or environment variables
  when the config file supplies `server` and a token (CLI-A18).

* Download streaming catches client disconnects inside the response body
  callback, so HTTP/2 per-stream failures no longer escape to the sender
  thread, and the blob handle is closed even when a transfer aborts
  (SRV-127).

* The release-notes CI job sets `GH_REPO`, so it can call `gh` without a
  repository checkout.

* Added `README.md` documenting server and client usage, environment
  variables, and the client config file.

* `pigeonVersion` is read from Cabal's generated `Paths_pigeon` module, so the
  `version` field in `pigeon.cabal` is the single source for `/healthz`,
  `pigeon-server --version`, and `pigeon-client --version`.

## 0.1.0.0 -- 2026-10-31

* First implementation of the Pigeon file-publishing service.

* `pigeon-server` accepts `PIGEON_NO_TLS` as the environment fallback for
  `--no-tls`, so containers can disable TLS without changing the entrypoint.
