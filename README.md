# Pigeon

File publishing with expiring, unguessable URLs.

- `pigeon-server` — accepts authenticated uploads, stores them gzipped, serves them at `/f/<id>`
- `pigeon-client` — upload, list, delete, and manage user tokens

The configured `--token` is the **admin token**. It can upload, list every file,
delete any file, and create or delete user tokens. A **user token** can upload,
list, and delete only its own files. Tokens can optionally expire; deleting or
expiring a token also deletes all files it owns.

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
| `PIGEON_TOKEN` | — | Admin bearer token |
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

Blobs are stored per owner under `<data-dir>/files/<owner-id>/<file-id>.gz`.
The admin owner directory is `files/admin/`. The schema remains version 1; a
data directory from before user tokens must be recreated.

## Client

    cabal run pigeon-client -- \
      --server https://files.example.com \
      --token-file ~/.pigeon-token \
      upload ./report.pdf

Options also read from the environment:

| Variable | Default | Description |
| --- | --- | --- |
| `PIGEON_SERVER` | `http://127.0.0.1:8080` | Server base URL |
| `PIGEON_TOKEN` | — | Admin or user bearer token |

## User tokens

Create a token with the admin token. The plaintext token is printed once:

    pigeon-client --server https://files.example.com --token "$PIGEON_ADMIN_TOKEN" \
      token create --expires-in 30d

List or delete tokens:

    pigeon-client --server https://files.example.com --token "$PIGEON_ADMIN_TOKEN" token list
    pigeon-client --server https://files.example.com --token "$PIGEON_ADMIN_TOKEN" \
      token delete 7q3m9x2k4v8p1c6d

Use a user token exactly like the admin token for upload, list, and delete. The
user sees only its own files; the admin's `list` includes an `OWNER` column.

## Config file

Put defaults in `~/.config/pigeon/config.toml` (or `--config FILE`) so you can
just run `pigeon-client upload ./report.pdf`:

    server = "https://files.example.com"
    token-file = "~/.pigeon-token"
    insecure = true
    no-http-warning = true
