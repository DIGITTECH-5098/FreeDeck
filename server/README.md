# FreeDeck Server

Deliverable 2 of the [FreeDeck](../../README.md) project — an open-source fork of
FreeDeck/LiveContainer for iOS that offloads app/game storage to a Linux server
(240GB) reachable over Tailscale MagicDNS (e.g. `freedeck.tailnet.ts.net`).

FastAPI + uvicorn backend with nginx as an optional production fast path.
Dependency-light: `fastapi`, `uvicorn`, and the Python standard library
(`urllib` for downloads, `zipfile` for extraction).

## Storage layout

Everything lives under `FREEDECK_STORAGE_ROOT` (default `/freedeck_storage`):

```
/freedeck_storage/
├── ipa/          downloaded .ipa archives
├── apps/         unpacked .app bundles (auto-extracted from zips)
├── webports/     HTML5/WASM builds (index.html, .wasm, .pak, .data, ...)
└── library.json  catalog of entries
```

Catalog entries: `id`, `name`, `type` (`ipa` | `app` | `webport`), `size`,
`version`, `description`, `icon` (URL), `path`, `added` (ISO date).

## API

| Method | Path | Description |
|---|---|---|
| GET | `/api/health` | Health check |
| GET | `/api/library` | List catalog entries |
| GET | `/api/library/ENTRY` | Entry detail |
| POST | `/api/install` | Download a remote IPA/zip (JSON body: `url`, `name`, `type`) into storage; runs in a background thread with progress |
| GET | `/api/tasks/TASKID` | Download task status + progress (0–100) |
| DELETE | `/api/library/ENTRY` | Remove entry + files |
| POST | `/api/cache/evict-notify` | iOS client logs locally-cached/evicted entries (access patterns) |
| GET | `/stream/ENTRY/PATH` | Byte-range streaming of any file in an entry |
| GET | `/webport/ENTRY/` | Serve an HTML5/WASM web-port build (`index.html` default) |

### Streaming

`GET /stream/ENTRY/PATH` and `GET /webport/ENTRY/...` implement full HTTP Range
support in Python (only the requested byte range is read from disk):

- `Accept-Ranges: bytes` on every response
- `Range: bytes=0-99` → `206 Partial Content`, exactly 100 bytes,
  `Content-Range: bytes 0-99/<size>`
- Suffix ranges (`bytes=-100`) and open ranges (`bytes=100-`) supported
- `416` with `Content-Range: bytes */<size>` for unsatisfiable ranges

In production nginx serves `/stream/` and `/webport/` **directly** from the
storage root (`alias`), with native byte-range support, `mp4`/`wasm`/
`webmanifest` MIME types, `Cache-Control` headers, and gzip disabled for
range-served binaries. An X-Accel-Redirect alternative is documented in
`nginx.conf`.

### Auth

Set `FREEDECK_TOKEN` to require `Authorization: Bearer <token>` on `/api/*`
and `/stream/*` (and `/webport/` when going through uvicorn). Unset/empty
disables auth — fine on a Tailscale-only network.

## Run without Docker (verification / bare metal)

```sh
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
export FREEDECK_STORAGE_ROOT=/freedeck_storage   # or any writable dir
.venv/bin/uvicorn server:app --host 0.0.0.0 --port 8000
```

## Run with Docker Compose (production)

```sh
cp .env.example .env    # set FREEDECK_TOKEN / FREEDECK_HTTP_PORT if desired
docker compose up -d --build
```

Services:

- `web` — uvicorn/FastAPI app on the internal network
- `nginx` — reverse-proxies `/api/` to the app and serves `/stream/` +
  `/webport/` directly from the shared `freedeck_storage` volume, published on
  `${FREEDECK_HTTP_PORT:-8080}:80`

Both have restart policies and healthchecks. On the iOS client, point at
`http://freedeck.tailnet.ts.net:8080/` (MagicDNS + Tailscale).

`docker-compose.yml` is valid Compose YAML (validated with a strict YAML
parser); Docker itself is not required for the test suite.

## Tests

See the verification evidence in the project log: health check, catalog
registration, library listing, 100-byte Range request (`206` + `Content-Range`),
and web-port `index.html` serving were all curl-tested against a live uvicorn
instance in `.venv`.
