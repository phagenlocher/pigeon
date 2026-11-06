# Revision history for pigeon

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
