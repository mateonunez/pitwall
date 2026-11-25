"""Private, disposable snapshots for dashboard views. A slow older read cannot undo a newer one."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time


class Snapshot:
    def __init__(self, slot, identity):
        self.slot = slot
        self.bind(identity)
        self.started = time.time_ns()
        root = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
        self.directory = root / "pitwall" / "panels"

    def bind(self, identity):
        self.owner = hashlib.sha256(json.dumps(identity).encode()).hexdigest()

    @contextlib.contextmanager
    def database(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = self.directory / "views.sqlite"
        os.close(os.open(path, os.O_CREAT | os.O_RDWR, 0o600))
        with contextlib.closing(sqlite3.connect(path, timeout=0.2)) as db, db:
            db.execute("CREATE TABLE IF NOT EXISTS views "
                       "(slot TEXT PRIMARY KEY, owner TEXT, started INTEGER, records TEXT)")
            yield db

    def read(self):
        try:
            with self.database() as db:
                row = db.execute("SELECT records FROM views WHERE slot=? AND owner=?",
                                 (self.slot, self.owner)).fetchone()
                return row[0] if row else None
        except (OSError, sqlite3.Error):
            return None

    def save(self, records):
        try:
            with self.database() as db:
                db.execute("INSERT INTO views VALUES (?, ?, ?, ?) ON CONFLICT(slot) DO UPDATE SET "
                           "owner=excluded.owner, started=excluded.started, records=excluded.records "
                           "WHERE excluded.started >= views.started",
                           (self.slot, self.owner, self.started, records))
        except (OSError, sqlite3.Error):
            pass  # A live view still works with an unavailable cache.


def preview(path, records):
    if path:
        try:
            with tempfile.NamedTemporaryFile(mode="w", dir=Path(path).parent, delete=False) as f:
                try:
                    f.write(records)
                    f.flush()
                    os.replace(f.name, path)
                finally:
                    Path(f.name).unlink(missing_ok=True)
        except OSError:
            pass
