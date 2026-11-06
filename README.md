# Pigeon

File publishing with expiring, unguessable URLs.

- `pigeon-server` — accepts authenticated uploads, stores them gzipped, serves them at `/f/<id>`
- `pigeon-client` — upload, list, delete

## Server

    cabal run pigeon-server -- \
      --no-tls \
      --token dev-token-at-least-16-chars \
      --data-dir ./data

Options also read from the environment:

| Variable | Default | Description |
| --- | --- | --- |
| `PIGEON_HOST` | `127.0.0.1` | Bind address |
| `PIGEON_PORT` | `8080` | TCP port |
| `PIGEON_TOKEN` | — | Shared bearer token |
| `PIGEON_DATA_DIR` | `./data` | Data directory |
| `PIGEON_DB` | `<data-dir>/pigeon.db` | SQLite database path |
| `PIGEON_TLS_CERT` | — | PEM certificate chain |
| `PIGEON_TLS_KEY` | — | PEM private key |
| `PIGEON_NO_TLS` | `false` | Disable TLS (development only) |
| `PIGEON_PUBLIC_URL` | derived from host and port | Public base URL for share links |
| `PIGEON_DEFAULT_EXPIRY` | `7d` | Expiry when an upload omits it |
| `PIGEON_MAX_EXPIRY` | `365d` | Maximum allowed expiry |
| `PIGEON_SWEEP_INTERVAL` | `60s` | Expiry sweep period |
| `PIGEON_MAX_UPLOAD_SIZE` | `0` (unlimited) | Maximum upload bytes |
| `PIGEON_PASSWORD_HASH_ITERATIONS` | `600000` | PBKDF2 iterations |

## Client

    cabal run pigeon-client -- \
      --server https://files.example.com \
      --token-file ~/.pigeon-token \
      upload ./report.pdf

Options also read from the environment:

| Variable | Default | Description |
| --- | --- | --- |
| `PIGEON_SERVER` | `http://127.0.0.1:8080` | Server base URL |
| `PIGEON_TOKEN` | — | Shared bearer token |

## Config file

Put defaults in `~/.config/pigeon/config.toml` (or `--config FILE`) so you can
just run `pigeon-client upload ./report.pdf`:

    server = "https://files.example.com"
    token-file = "~/.pigeon-token"
    insecure = true
    no-http-warning = true
