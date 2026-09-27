#!/usr/bin/env python3
# ==========================================================================
#  moonraker-db-shim  —  2025 Creality K1C / K1 Max
#
#  Creality's `nexusp` is a closed C reimplementation of Moonraker. It
#  implements database get_item / post_item / delete_item but returns
#  403 "Method unimplemented" for:
#
#      server.database.list
#      server.database.compact
#      server.database.post_backup
#      server.database.delete_backup
#      server.database.restore
#
#  So Fluidd's System -> "Moonraker Database" panel is dead: no namespace
#  list, and the Create Backup / Compact buttons do nothing.
#
#  nexusp is a stripped MIPS binary, SCBT-encrypted at rest and decrypted
#  into tmpfs at boot, so the methods cannot be added to it. This is a
#  transparent websocket proxy that implements them itself and relays
#  everything else untouched. To Fluidd the methods simply exist.
#
#  TOPOLOGY  (Creality's own path is NOT altered)
#      vectorp (touchscreen) ─────────────────────────> nexusp:7125
#      Fluidd ──> nginx:4408 ──> THIS SHIM:4409 ──────> nexusp:7125
#
#  nginx is configured with nexusp as a backup upstream, so if this process
#  dies Fluidd falls through to nexusp directly: the five methods go back to
#  failing, but the UI keeps working.
#
#  Deliberately conservative:
#    * binds loopback only
#    * sqlite work runs in a thread, never blocking the relay
#    * refuses compact/restore while a print is running (as Moonraker does)
#    * unknown/!JSON frames are relayed verbatim, never parsed destructively
# ==========================================================================

import asyncio
import json
import logging
import os
import shutil
import sqlite3
import sys
import time
import uuid
from logging.handlers import RotatingFileHandler
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import threading

sys.path.insert(0, "/usr/data/wsshim/lib")
import websockets  # noqa: E402
from websockets.exceptions import ConnectionClosed  # noqa: E402

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 4409
HTTP_PORT = 4410
UPSTREAM = "ws://127.0.0.1:7125/websocket"
DB_PATH = "/usr/data/printer_data/database/nexusp-sql.db"
BACKUP_DIR = "/usr/data/db_backups"
LOG_PATH = "/usr/data/wsshim/shim.log"
KLIPPY_STATE_URL = "http://127.0.0.1:7125/printer/objects/query?print_stats"

# Namespaces Moonraker hides from the normal (non-debug) list request.
FORBIDDEN_NS = {"moonraker", "authorized_users"}

log = logging.getLogger("db-shim")


# ----------------------------------------------------------------- utils --
def _connect_db():
    # short timeout: nexusp holds this db open; we must not hang the relay
    return sqlite3.connect(DB_PATH, timeout=5.0)


def _backup_dir():
    os.makedirs(BACKUP_DIR, exist_ok=True)
    return BACKUP_DIR


def _safe_backup_path(filename):
    """Resolve filename inside BACKUP_DIR, refusing traversal."""
    if not filename:
        raise ValueError("filename is required")
    base = os.path.realpath(_backup_dir())
    path = os.path.realpath(os.path.join(base, filename))
    if not path.startswith(base + os.sep):
        raise ValueError("invalid filename %r" % filename)
    return path


def _is_printing():
    """Mirror Moonraker: refuse destructive ops mid-print. Fail open."""
    try:
        import urllib.request

        with urllib.request.urlopen(KLIPPY_STATE_URL, timeout=3) as r:
            d = json.loads(r.read().decode())
        st = d["result"]["status"]["print_stats"]["state"]
        return st in ("printing", "paused")
    except Exception:
        return False


# -------------------------------------------------------------- handlers --
def h_list(params):
    con = _connect_db()
    try:
        rows = con.execute("SELECT DISTINCT namespace FROM namespace_store").fetchall()
    finally:
        con.close()
    namespaces = sorted({r[0] for r in rows} - FORBIDDEN_NS)
    d = _backup_dir()
    backups = sorted(
        f for f in os.listdir(d) if os.path.isfile(os.path.join(d, f))
    )
    return {"namespaces": namespaces, "backups": backups}


def h_compact(params):
    if _is_printing():
        raise RuntimeError("Cannot compact while printing")
    prev = os.path.getsize(DB_PATH)
    con = _connect_db()
    try:
        con.execute("VACUUM")
        con.commit()
    finally:
        con.close()
    new = os.path.getsize(DB_PATH)
    log.info("compact: %d -> %d bytes", prev, new)
    return {"previous_size": prev, "new_size": new}


def h_post_backup(params):
    if _is_printing():
        raise RuntimeError("Cannot backup while printing")
    name = params.get("filename") or time.strftime("sqldb-backup-%Y%m%d-%H%M%S.db")
    path = _safe_backup_path(name)
    src = _connect_db()
    try:
        dst = sqlite3.connect(path)
        try:
            src.backup(dst)  # online backup API, safe on a live db
        finally:
            dst.close()
    finally:
        src.close()
    chk = sqlite3.connect(path)
    try:
        ok = chk.execute("PRAGMA integrity_check").fetchone()[0]
    finally:
        chk.close()
    if ok != "ok":
        os.unlink(path)
        raise RuntimeError("backup failed integrity_check: %s" % ok)
    os.chmod(path, 0o644)
    log.info("backup -> %s (%d bytes)", path, os.path.getsize(path))
    return {"backup_path": path}


def h_delete_backup(params):
    path = _safe_backup_path(params.get("filename"))
    if not os.path.isfile(path):
        raise RuntimeError("Backup file does not exist")
    os.unlink(path)
    log.info("deleted backup %s", path)
    return {"backup_path": path}


def h_restore(params):
    if _is_printing():
        raise RuntimeError("Cannot restore while printing")
    path = _safe_backup_path(params.get("filename"))
    if not os.path.isfile(path):
        raise RuntimeError("Backup file does not exist")
    chk = sqlite3.connect(path)
    try:
        if chk.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("refusing to restore a corrupt backup")
        tables = [
            r[0]
            for r in chk.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        ]
    finally:
        chk.close()
    shutil.copy2(DB_PATH, DB_PATH + ".before-restore")
    shutil.copy2(path, DB_PATH)
    try:
        os.chmod(DB_PATH, 0o644)
    except OSError:
        pass
    log.warning("restored %s -> %s (restart klipper/nexusp to load it)", path, DB_PATH)
    return {"restored_tables": tables, "backup_path": path}


# ----------------------------------------------------------- webcams --
# nexusp has no webcam component at all: every server.webcams.* call comes
# back "Method not found" (-32601). So Fluidd never learns about a camera and
# its (already enabled) camera card stays empty -- and the moment anything
# DOES try to write a camera, the error surfaces in the UI.
#
# So implement the whole Moonraker webcam API here, not just the read half.
# Nothing may relay to nexusp: it would fail.
#
# We only ADVERTISE a stream; nothing here opens the camera. quintusp owns
# /dev/video0 exclusively -- it is the only capture interface on this board
# (video1 is a UVC metadata node) -- and fans H264 out over
# /tmp/h264_uds_chassis to any number of clients. thirteenthp is one such
# client and turns it into WebRTC on :8000, which nginx re-serves at /webrtc/.
# So Creality Print and the touchscreen are unaffected.
#
# NOTE for future edits: do NOT point a second consumer at /dev/video0
# (mjpg_streamer is installed and tempting). Holding it would break the
# touchscreen and Creality Print camera.
#
# stream_url is deliberately RELATIVE: Fluidd runs it through
# buildAbsoluteUrl() against the host the browser is already using, so this
# survives the printer changing IP and works over <hostname>.local too.
WEBCAM_PATH = "/usr/data/wsshim/webcams.json"
WEBCAM_LOCK = threading.Lock()

DEFAULT_WEBCAM = {
    "name": "Chassis",
    "location": "printer",
    "service": "iframe",
    "enabled": True,
    "icon": "mdiWebcam",
    "target_fps": 15,
    "target_fps_idle": 5,
    "stream_url": "/webrtc/",
    "snapshot_url": "",
    "flip_horizontal": False,
    "flip_vertical": False,
    "rotation": 0,
    "aspect_ratio": "16:9",
    # "database" (not "config") so Fluidd offers Edit/Delete -- we implement
    # post_item/delete_item below, so those buttons actually work.
    "source": "database",
    "uid": "creality-chassis-cam",
}


def _webcams_load():
    """Read the store, seeding it with the Creality camera on first run."""
    try:
        with open(WEBCAM_PATH) as fh:
            cams = json.load(fh)
        if isinstance(cams, list):
            return [c for c in cams if isinstance(c, dict) and c.get("uid")]
    except (OSError, ValueError):
        pass
    return [dict(DEFAULT_WEBCAM)]


def _webcams_save(cams):
    tmp = WEBCAM_PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(cams, fh, indent=2)
    os.replace(tmp, WEBCAM_PATH)      # atomic; never a half-written store


def h_webcams_list(params):
    with WEBCAM_LOCK:
        return {"webcams": _webcams_load()}


def h_webcams_get(params):
    uid = params.get("uid")
    with WEBCAM_LOCK:
        for c in _webcams_load():
            if c["uid"] == uid:
                return {"webcam": c}
    raise RuntimeError("Webcam %s not found" % uid)


def h_webcams_post(params):
    """Create or update. Moonraker matches on uid, falling back to name."""
    with WEBCAM_LOCK:
        cams = _webcams_load()
        uid = params.get("uid")
        name = params.get("name")
        idx = next(
            (i for i, c in enumerate(cams)
             if (uid and c["uid"] == uid) or (not uid and c.get("name") == name)),
            None,
        )
        if idx is None:
            cam = dict(DEFAULT_WEBCAM)
            cam.update({k: v for k, v in params.items() if v is not None})
            cam["uid"] = uid or uuid.uuid4().hex
            cam["source"] = "database"
            cams.append(cam)
        else:
            cam = dict(cams[idx])
            cam.update({k: v for k, v in params.items() if v is not None})
            cam["source"] = "database"
            cams[idx] = cam
        _webcams_save(cams)
    log.info("webcam saved: %s (%s)", cam.get("name"), cam["uid"])
    return {"webcam": cam}


def h_webcams_delete(params):
    uid = params.get("uid")
    with WEBCAM_LOCK:
        cams = _webcams_load()
        idx = next((i for i, c in enumerate(cams) if c["uid"] == uid), None)
        if idx is None:
            raise RuntimeError("Webcam %s not found" % uid)
        cam = cams.pop(idx)
        _webcams_save(cams)
    log.info("webcam deleted: %s (%s)", cam.get("name"), uid)
    return {"webcam": cam}


def h_webcams_test(params):
    """Fluidd's "test" button. We cannot probe an iframe/WebRTC endpoint
    meaningfully, so report reachable rather than fail the call."""
    uid = params.get("uid")
    with WEBCAM_LOCK:
        cam = next((c for c in _webcams_load() if c["uid"] == uid), None)
    if cam is None:
        raise RuntimeError("Webcam %s not found" % uid)
    return {
        "name": cam.get("name"),
        "snapshot_reachable": bool(cam.get("snapshot_url")),
        "stream_reachable": True,
    }


HANDLERS = {
    "server.database.list": h_list,
    "server.database.compact": h_compact,
    "server.database.post_backup": h_post_backup,
    "server.database.delete_backup": h_delete_backup,
    "server.database.restore": h_restore,
    "server.webcams.list": h_webcams_list,
    "server.webcams.get_item": h_webcams_get,
    "server.webcams.post_item": h_webcams_post,
    "server.webcams.delete_item": h_webcams_delete,
    "server.webcams.test": h_webcams_test,
}


# ----------------------------------------------------------------- proxy --
_DEC = json.JSONDecoder()


def _split_frames(raw):
    """Moonraker's websocket protocol is one JSON document per frame. If an
    upstream frame carries several concatenated documents (or \\x03-delimited
    ones), a browser's JSON.parse() throws on the second document and the
    client's onmessage handler dies. Split such frames so each document is
    delivered on its own. Returns [raw] unchanged when there is nothing to fix.
    """
    if not isinstance(raw, str):
        return [raw]
    try:
        json.loads(raw)
        return [raw]                      # already exactly one document
    except ValueError:
        pass
    out, idx, n = [], 0, len(raw)
    while idx < n:
        while idx < n and raw[idx] in " \t\r\n\x03":
            idx += 1
        if idx >= n:
            break
        try:
            _, end = _DEC.raw_decode(raw, idx)
        except ValueError:
            return [raw]                  # not cleanly splittable; pass through
        out.append(raw[idx:end])
        idx = end
    return out or [raw]


async def _maybe_handle(raw, send, loop):
    """Return True if we answered locally; False to relay upstream."""
    if not isinstance(raw, str):
        return False
    try:
        msg = json.loads(raw)
    except (ValueError, TypeError):
        return False
    if not isinstance(msg, dict):
        return False
    method = msg.get("method")
    if method not in HANDLERS:
        return False
    req_id = msg.get("id")
    if req_id is None:
        return False  # a notification; not ours to answer
    params = msg.get("params") or {}
    if not isinstance(params, dict):
        params = {}

    try:
        result = await loop.run_in_executor(None, HANDLERS[method], params)
        reply = {"jsonrpc": "2.0", "id": req_id, "result": result}
        log.info("handled %s", method)
    except Exception as e:
        log.error("%s failed: %s", method, e)
        reply = {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": 400, "message": str(e)},
        }
    await send(json.dumps(reply))
    return True


async def handle_client(client, path=None):
    loop = asyncio.get_event_loop()
    peer = getattr(client, "remote_address", None)
    try:
        upstream = await websockets.connect(
            UPSTREAM, ping_interval=None, max_size=None, open_timeout=10
        )
    except Exception as e:
        log.error("upstream connect failed: %s", e)
        await client.close(code=1011, reason="upstream unavailable")
        return
    log.info("client %s connected", peer)

    # One writer at a time. Both the local-handler path and the relay path
    # write to this socket; serialise them so frames can never interleave.
    send_lock = asyncio.Lock()

    async def send(data):
        async with send_lock:
            await client.send(data)

    async def c2u():
        async for raw in client:
            if await _maybe_handle(raw, send, loop):
                continue
            await upstream.send(raw)

    async def u2c():
        async for raw in upstream:
            parts = _split_frames(raw)
            if len(parts) > 1:
                log.warning(
                    "BATCHED upstream frame: len=%d split into %d docs; "
                    "first=%r boundary=%r",
                    len(raw), len(parts), raw[:80], raw[110:170],
                )
            for p in parts:
                await send(p)

    t1 = asyncio.ensure_future(c2u())
    t2 = asyncio.ensure_future(u2c())
    try:
        done, pending = await asyncio.wait(
            [t1, t2], return_when=asyncio.FIRST_COMPLETED
        )
        for t in pending:
            t.cancel()
    except ConnectionClosed:
        pass
    except Exception as e:
        log.error("relay error: %s", e)
    finally:
        for t in (t1, t2):
            if not t.done():
                t.cancel()
        try:
            await upstream.close()
        except Exception:
            pass
        log.info("client %s disconnected", peer)


def _setup_logging():
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    h = RotatingFileHandler(LOG_PATH, maxBytes=512 * 1024, backupCount=2)
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(h)
    log.setLevel(logging.INFO)



# ------------------------------------------------------------------ HTTP --
# Fluidd calls some of these over the REST API, not the websocket. nginx
# routes /server/... to nexusp by default, so those requests never reached
# the relay above and came back 403. This serves the same five handlers over
# HTTP, in Moonraker's response shape: {"result": <data>}.
HTTP_ROUTES = {
    ("GET", "/server/database/list"): h_list,
    ("POST", "/server/database/compact"): h_compact,
    ("POST", "/server/database/backup"): h_post_backup,
    ("DELETE", "/server/database/backup"): h_delete_backup,
    ("POST", "/server/database/restore"): h_restore,
    ("GET", "/server/webcams/list"): h_webcams_list,
    ("GET", "/server/webcams/item"): h_webcams_get,
}


class _DbHTTP(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):  # keep BaseHTTPRequestHandler off stderr
        log.debug("http %s", fmt % a)

    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _params(self):
        q = parse_qs(urlparse(self.path).query)
        params = {k: v[0] for k, v in q.items()}
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            raw = self.rfile.read(n)
            try:
                body = json.loads(raw)
                if isinstance(body, dict):
                    params.update(body)
            except (ValueError, TypeError):
                pass
        return params

    def _dispatch(self, method):
        path = urlparse(self.path).path
        fn = HTTP_ROUTES.get((method, path))
        if fn is None:
            return self._reply(404, {"error": {"code": 404, "message": "Not found"}})
        try:
            result = fn(self._params())
            log.info("http handled %s %s", method, path)
            self._reply(200, {"result": result})
        except Exception as e:
            log.error("http %s %s failed: %s", method, path, e)
            self._reply(400, {"error": {"code": 400, "message": str(e)}})

    def do_GET(self):    self._dispatch("GET")
    def do_POST(self):   self._dispatch("POST")
    def do_DELETE(self): self._dispatch("DELETE")


def start_http():
    srv = ThreadingHTTPServer((LISTEN_HOST, HTTP_PORT), _DbHTTP)
    srv.daemon_threads = True
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    log.info("http listening on %s:%d", LISTEN_HOST, HTTP_PORT)
    return srv


async def main():
    _setup_logging()
    log.info("starting: ws %s:%d -> %s", LISTEN_HOST, LISTEN_PORT, UPSTREAM)
    start_http()
    async with websockets.serve(
        handle_client,
        LISTEN_HOST,
        LISTEN_PORT,
        ping_interval=None,
        max_size=None,
    ):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
