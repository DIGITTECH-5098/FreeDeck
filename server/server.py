"""FreeDeck server backend.

FastAPI + uvicorn remote-storage service for the FreeDeck iOS client.
Stores IPA / unpacked .app bundles / HTML5 web-port builds on the server
and streams them to iPhones over Tailscale with full HTTP Range support.

Storage layout under FREEDECK_STORAGE_ROOT (default /freedeck_storage):
    ipa/        downloaded .ipa archives
    apps/       unpacked .app bundles (extracted from zips/ipas)
    webports/   HTML5/WASM builds (index.html, .wasm, .pak, .data, ...)
    library.json  catalog of entries

Run:  uvicorn server:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import hashlib
import json
import mimetypes
import os
import re
import shutil
import threading
import time
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote
from urllib.request import Request, urlopen

from fastapi import Depends, FastAPI, HTTPException, Request as FastAPIRequest
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

STORAGE_ROOT = Path(os.environ.get("FREEDECK_STORAGE_ROOT", "/freedeck_storage")).resolve()
AUTH_TOKEN = os.environ.get("FREEDECK_TOKEN", "").strip()
DOWNLOAD_CHUNK = 1024 * 256  # 256 KiB download chunks
STREAM_CHUNK = 1024 * 64     # 64 KiB streaming chunks

IPA_DIR = STORAGE_ROOT / "ipa"
APPS_DIR = STORAGE_ROOT / "apps"
WEBPORTS_DIR = STORAGE_ROOT / "webports"
LIBRARY_FILE = STORAGE_ROOT / "library.json"

CATALOG_TYPES = {"ipa", "app", "webport"}

# Entry types that live under webports/ (served at /webport/ENTRY/) vs the
# generic /stream/ENTRY/ path.
WEBPORT_TYPE = "webport"

app = FastAPI(title="FreeDeck Server", version="1.0.0")

# In-memory task registry for background downloads: task_id -> dict
_tasks: dict[str, dict] = {}
_tasks_lock = threading.Lock()

# Access log for cache-evict notifications (keep it simple, bounded)
_access_log: list[dict] = []
_access_lock = threading.Lock()
ACCESS_LOG_MAX = 1000


# ---------------------------------------------------------------------------
# Catalog helpers
# ---------------------------------------------------------------------------

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_library() -> dict:
    """Load library.json. Format: {"entries": {id: entry, ...}} (dict for
    O(1) lookups) — tolerant of a plain list on disk."""
    if not LIBRARY_FILE.exists():
        return {"entries": {}}
    try:
        with LIBRARY_FILE.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {"entries": {}}
    if isinstance(data, dict) and isinstance(data.get("entries"), dict):
        return {"entries": dict(data["entries"])}
    if isinstance(data, list):
        return {"entries": {e["id"]: e for e in data if isinstance(e, dict) and "id" in e}}
    return {"entries": {}}


def _save_library(lib: dict) -> None:
    STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    tmp = LIBRARY_FILE.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(lib, fh, indent=2, ensure_ascii=False)
    tmp.replace(LIBRARY_FILE)


def _dir_size(path: Path) -> int:
    total = 0
    if path.is_file():
        return path.stat().st_size
    for p in path.rglob("*"):
        if p.is_file():
            total += p.stat().st_size
    return total


def _entry_public(entry: dict) -> dict:
    """Return the catalog view of an entry (id, name, type, size, version,
    description, icon URL, path, added date)."""
    return {
        "id": entry["id"],
        "name": entry.get("name", entry["id"]),
        "type": entry.get("type", "ipa"),
        "size": entry.get("size", 0),
        "version": entry.get("version", ""),
        "description": entry.get("description", ""),
        "icon": entry.get("icon", ""),
        "path": entry.get("path", ""),
        "added": entry.get("added", ""),
    }


def _get_entry_or_404(entry_id: str) -> dict:
    lib = _load_library()
    entry = lib["entries"].get(entry_id)
    if entry is None:
        raise HTTPException(status_code=404, detail=f"entry not found: {entry_id}")
    return entry


def _resolve_entry_dir(entry: dict) -> Path:
    """Resolve the on-disk directory for an entry, confined to STORAGE_ROOT."""
    rel = entry.get("path", "")
    base = {
        "ipa": IPA_DIR,
        "app": APPS_DIR,
        "webport": WEBPORTS_DIR,
    }.get(entry.get("type", "ipa"), STORAGE_ROOT)
    target = (base / rel).resolve() if rel else base
    # Path confinement: must stay inside STORAGE_ROOT
    if not str(target).startswith(str(STORAGE_ROOT)):
        raise HTTPException(status_code=400, detail="invalid entry path")
    return target


def _resolve_file(entry: dict, rel_path: str) -> Path:
    """Resolve a relative file path inside an entry's directory (or the entry
    file itself when the entry points at a single file)."""
    base = _resolve_entry_dir(entry)
    if base.is_file():
        # Single-file entry (e.g. an .ipa): PATH must address the file itself
        # or be empty.
        if rel_path in ("", base.name):
            return base
        raise HTTPException(status_code=404, detail="file not found in entry")
    target = (base / rel_path).resolve()
    if not str(target).startswith(str(base)):
        raise HTTPException(status_code=403, detail="path escapes entry directory")
    return target


# ---------------------------------------------------------------------------
# Auth (optional bearer token, for use over Tailscale)
# ---------------------------------------------------------------------------

async def require_auth(request: FastAPIRequest) -> None:
    if not AUTH_TOKEN:
        return  # auth disabled
    header = request.headers.get("authorization", "")
    if not header.startswith("Bearer "):
        raise HTTPException(
            status_code=401,
            detail="missing bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    token = header[len("Bearer "):].strip()
    # Constant-time-ish comparison
    if not (len(token) == len(AUTH_TOKEN)
            and hashlib.sha256(token.encode()).digest()
            == hashlib.sha256(AUTH_TOKEN.encode()).digest()):
        raise HTTPException(
            status_code=403,
            detail="invalid token",
            headers={"WWW-Authenticate": "Bearer"},
        )


# ---------------------------------------------------------------------------
# Byte-range helpers (manual Range handling for /stream and /webport)
# ---------------------------------------------------------------------------

_RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")


def parse_range(range_header: str, file_size: int) -> tuple[int, int, bool]:
    """Parse a single-range `Range: bytes=a-b` header.

    Returns (start, end, satisfiable_range) with start/end inclusive.
    Raises HTTPException(416) on unsatisfiable ranges; returns
    (0, file_size - 1, False) when the header is absent/invalid per RFC 9110
    (invalid Range headers are ignored -> full 200 response). The third value
    is True when a valid Range was applied (-> 206, even if it spans the whole
    file).
    """
    if file_size <= 0:
        return (0, 0, False)
    if not range_header:
        return (0, file_size - 1, False)
    m = _RANGE_RE.match(range_header.strip())
    if not m:
        return (0, file_size - 1, False)  # malformed -> ignore, full response
    start_s, end_s = m.groups()
    if start_s == "" and end_s == "":
        return (0, file_size - 1, True)
    if start_s == "":
        # suffix range: last N bytes
        length = int(end_s)
        if length <= 0:
            raise HTTPException(status_code=416, detail="unsatisfiable range",
                                headers={"Content-Range": f"bytes */{file_size}"})
        start = max(0, file_size - length)
        end = file_size - 1
    else:
        start = int(start_s)
        end = int(end_s) if end_s != "" else file_size - 1
        if start >= file_size:
            raise HTTPException(status_code=416, detail="unsatisfiable range",
                                headers={"Content-Range": f"bytes */{file_size}"})
        end = min(end, file_size - 1)
        if start > end:
            raise HTTPException(status_code=416, detail="unsatisfiable range",
                                headers={"Content-Range": f"bytes */{file_size}"})
    return (start, end, True)


def range_file_response(path: Path, request: FastAPIRequest,
                        media_type: str | None = None) -> StreamingResponse | FileResponse:
    """Serve a file with full HTTP Range support (206 / Accept-Ranges /
    Content-Range), reading only the requested byte range from disk."""
    if not path.is_file():
        raise HTTPException(status_code=404, detail=f"file not found: {path}")
    file_size = path.stat().st_size
    if media_type is None:
        media_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"

    range_header = request.headers.get("range", "")
    start, end, ranged = parse_range(range_header, file_size)
    length = end - start + 1 if file_size > 0 else 0

    def iter_range():
        with path.open("rb") as fh:
            fh.seek(start)
            remaining = length
            while remaining > 0:
                chunk = fh.read(min(STREAM_CHUNK, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk

    headers = {
        "Accept-Ranges": "bytes",
        "Content-Length": str(length),
        "Content-Disposition": f'inline; filename="{path.name}"',
    }
    if ranged and range_header:
        headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"
        status = 206
    else:
        status = 200

    return StreamingResponse(iter_range(), status_code=status,
                             media_type=media_type, headers=headers)


# ---------------------------------------------------------------------------
# Background download / install tasks
# ---------------------------------------------------------------------------

def _set_task(task_id: str, **fields) -> None:
    with _tasks_lock:
        t = _tasks.get(task_id)
        if t is not None:
            t.update(fields)
            t["updated"] = _now_iso()


def _register_download(entry_id: str, url: str, name: str, etype: str) -> str:
    task_id = uuid.uuid4().hex[:12]
    with _tasks_lock:
        _tasks[task_id] = {
            "id": task_id,
            "entry_id": entry_id,
            "url": url,
            "name": name,
            "type": etype,
            "status": "pending",       # pending | downloading | extracting | done | error
            "progress": 0.0,           # 0..100
            "downloaded_bytes": 0,
            "total_bytes": 0,
            "error": None,
            "created": _now_iso(),
            "updated": _now_iso(),
        }
    return task_id


def _find_app_bundles(root: Path) -> list[Path]:
    return [p for p in root.rglob("*.app") if p.is_dir()]


def _extract_zip(zip_path: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.namelist():
            # Guard against zip-slip
            target = (dest / member).resolve()
            if not str(target).startswith(str(dest.resolve())):
                raise RuntimeError(f"zip entry escapes destination: {member}")
        zf.extractall(dest)


def _run_download(task_id: str, entry_id: str, url: str, name: str,
                  etype: str) -> None:
    """Background worker: download a remote IPA/zip into storage, optionally
    extract .app bundles, then register the catalog entry."""
    try:
        _set_task(task_id, status="downloading", progress=0.0)
        ext = ".ipa" if etype == "ipa" else ".zip"
        filename = f"{entry_id}{ext}"
        if etype == "ipa":
            dest = IPA_DIR / filename
        elif etype == "app":
            dest = APPS_DIR / filename
        else:
            dest = WEBPORTS_DIR / filename
        dest.parent.mkdir(parents=True, exist_ok=True)

        req = Request(url, headers={"User-Agent": "FreeDeck/1.0"})
        with urlopen(req, timeout=60) as resp:
            total = int(resp.headers.get("Content-Length") or 0)
            _set_task(task_id, total_bytes=total)
            downloaded = 0
            with dest.open("wb") as out:
                while True:
                    chunk = resp.read(DOWNLOAD_CHUNK)
                    if not chunk:
                        break
                    out.write(chunk)
                    downloaded += len(chunk)
                    pct = (downloaded / total * 100.0) if total else 0.0
                    _set_task(task_id, downloaded_bytes=downloaded,
                              progress=round(pct, 2))

        size = dest.stat().st_size

        # Auto-extract zips that contain .app bundles (type "app")
        if etype == "app" and zipfile.is_zipfile(dest):
            _set_task(task_id, status="extracting", progress=100.0)
            app_dir = APPS_DIR / entry_id
            _extract_zip(dest, app_dir)
            bundles = _find_app_bundles(app_dir)
            if bundles:
                size = _dir_size(app_dir)
            else:
                # No .app inside; keep the archive as-is
                app_dir = dest
        elif etype == "webport" and zipfile.is_zipfile(dest):
            _set_task(task_id, status="extracting", progress=100.0)
            web_dir = WEBPORTS_DIR / entry_id
            _extract_zip(dest, web_dir)
            size = _dir_size(web_dir)
        else:
            if etype == "ipa":
                app_dir = dest  # single .ipa file entry
            elif etype == "webport":
                web_dir = dest
            else:
                app_dir = dest

        if etype == "ipa":
            rel_path = filename
            base = IPA_DIR
        elif etype == "app":
            rel_path = str(app_dir.relative_to(APPS_DIR))
            base = APPS_DIR
        else:
            rel_path = str(web_dir.relative_to(WEBPORTS_DIR))
            base = WEBPORTS_DIR

        entry = {
            "id": entry_id,
            "name": name,
            "type": etype,
            "size": size,
            "version": "",
            "description": f"Downloaded from {url}",
            "icon": "",
            "path": rel_path,
            "added": _now_iso(),
        }
        with _tasks_lock:
            lib = _load_library()
            lib["entries"][entry_id] = entry
            _save_library(lib)
        _set_task(task_id, status="done", progress=100.0,
                  downloaded_bytes=size, entry_id=entry_id)
    except Exception as exc:  # noqa: BLE001 - report any failure to the client
        _set_task(task_id, status="error", error=str(exc))


# ---------------------------------------------------------------------------
# API routes
# ---------------------------------------------------------------------------

@app.get("/api/health")
async def health() -> dict:
    return {"ok": True, "service": "freedeck", "time": _now_iso(),
            "storage_root": str(STORAGE_ROOT)}


@app.get("/api/library")
async def get_library(_auth: None = Depends(require_auth)) -> dict:
    lib = _load_library()
    entries = [_entry_public(e) for e in lib["entries"].values()]
    entries.sort(key=lambda e: e.get("name", ""))
    return {"entries": entries, "count": len(entries)}


@app.get("/api/library/{entry_id}")
async def get_library_entry(entry_id: str, _auth: None = Depends(require_auth)) -> dict:
    entry = _get_entry_or_404(entry_id)
    return _entry_public(entry)


@app.post("/api/install")
async def install(request: FastAPIRequest, _auth: None = Depends(require_auth)) -> dict:
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="invalid JSON body")
    url = (body.get("url") or "").strip()
    name = (body.get("name") or "").strip()
    etype = (body.get("type") or "ipa").strip().lower()
    if not url or not url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="url must be http(s)")
    if etype not in CATALOG_TYPES:
        raise HTTPException(status_code=400,
                            detail=f"type must be one of {sorted(CATALOG_TYPES)}")
    if not name:
        name = unquote(url.rsplit("/", 1)[-1]) or "unnamed"

    entry_id = hashlib.sha1(f"{url}|{time.time()}".encode()).hexdigest()[:10]
    task_id = _register_download(entry_id, url, name, etype)
    t = threading.Thread(target=_run_download,
                         args=(task_id, entry_id, url, name, etype),
                         daemon=True)
    t.start()
    return {"task_id": task_id, "entry_id": entry_id, "status": "pending"}


@app.get("/api/tasks/{task_id}")
async def get_task(task_id: str, _auth: None = Depends(require_auth)) -> dict:
    with _tasks_lock:
        t = _tasks.get(task_id)
        if t is None:
            raise HTTPException(status_code=404, detail="task not found")
        return dict(t)


@app.delete("/api/library/{entry_id}")
async def delete_entry(entry_id: str, _auth: None = Depends(require_auth)) -> dict:
    entry = _get_entry_or_404(entry_id)
    target = _resolve_entry_dir(entry)
    if target.exists():
        if target.is_file():
            target.unlink()
        else:
            shutil.rmtree(target, ignore_errors=True)
    # If an .ipa file entry points at a filename inside ipa/, also remove it
    lib = _load_library()
    lib["entries"].pop(entry_id, None)
    _save_library(lib)
    return {"deleted": entry_id}


@app.post("/api/cache/evict-notify")
async def cache_evict_notify(request: FastAPIRequest,
                             _auth: None = Depends(require_auth)) -> dict:
    """The iOS client posts which server entries it has cached locally (and
    which it evicted) so the server can log access patterns."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    record = {
        "time": _now_iso(),
        "entries": body.get("entries", []) if isinstance(body, dict) else [],
        "evicted": body.get("evicted", []) if isinstance(body, dict) else [],
    }
    with _access_lock:
        _access_log.append(record)
        if len(_access_log) > ACCESS_LOG_MAX:
            del _access_log[: len(_access_log) - ACCESS_LOG_MAX]
    return {"ok": True, "logged": True}


# ---------------------------------------------------------------------------
# Streaming + web-port routes (also behind nginx in production)
# ---------------------------------------------------------------------------

@app.get("/stream/{entry_id}/{file_path:path}")
async def stream_file(entry_id: str, file_path: str,
                      request: FastAPIRequest,
                      _auth: None = Depends(require_auth)):
    entry = _get_entry_or_404(entry_id)
    target = _resolve_file(entry, unquote(file_path))
    return range_file_response(target, request)


@app.get("/webport/{entry_id}/{file_path:path}")
@app.get("/webport/{entry_id}")
async def webport(entry_id: str, request: FastAPIRequest,
                  file_path: str = "",
                  _auth: None = Depends(require_auth)):
    entry = _get_entry_or_404(entry_id)
    rel = unquote(file_path) or "index.html"
    target = _resolve_file(entry, rel)
    if target.is_dir():
        target = target / "index.html"
        if not target.is_file():
            alt = target.with_name("index.htm")
            if alt.is_file():
                target = alt
    media = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
    # wasm/pak/data need explicit types some clients rely on
    if target.suffix == ".wasm":
        media = "application/wasm"
    elif target.suffix == ".webmanifest":
        media = "application/manifest+json"
    return range_file_response(target, request, media_type=media)


@app.get("/")
async def root() -> JSONResponse:
    return JSONResponse({"service": "FreeDeck server",
                         "docs": "/docs",
                         "health": "/api/health"})
