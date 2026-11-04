"""Release ledger: which image passed or failed its canary, in which environment.

This is the memory the app layer doesn't carry. Telemetry stays low-cardinality
(pod-template-hash only); the ledger maps hash <-> image <-> commit <-> PR <-> verdict.
It is fed by Argo Rollouts notifications (on-rollout-completed / on-rollout-aborted).
"""
import json
import sqlite3
import threading
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS releases (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts REAL NOT NULL,
  env TEXT NOT NULL,
  image TEXT NOT NULL,
  git_sha TEXT,
  pod_hash TEXT,
  stable_hash TEXT,
  verdict TEXT NOT NULL,          -- passed | failed
  source_pr TEXT,
  source_branch TEXT
);
CREATE TABLE IF NOT EXISTS investigations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts REAL NOT NULL,
  env TEXT NOT NULL,
  image TEXT NOT NULL,
  status TEXT NOT NULL,           -- running | done | error | skipped
  event TEXT NOT NULL,
  steps TEXT NOT NULL DEFAULT '[]',
  report TEXT,
  error TEXT
);
"""


class Ledger:
    def __init__(self, path: str):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript(SCHEMA)

    def _exec(self, sql, args=()):
        with self._lock:
            cur = self._db.execute(sql, args)
            self._db.commit()
            return cur

    def _rows(self, sql, args=()):
        with self._lock:
            return [dict(r) for r in self._db.execute(sql, args).fetchall()]

    # ── releases ────────────────────────────────────────────────────────────
    def record(self, ev: dict, verdict: str) -> None:
        last = self._rows(
            "SELECT verdict FROM releases WHERE env=? AND image=? AND pod_hash=? ORDER BY id DESC LIMIT 1",
            (ev["env"], ev["image"], ev.get("canaryHash")),
        )
        if last and last[0]["verdict"] == verdict:
            return  # duplicate notification
        self._exec(
            "INSERT INTO releases (ts, env, image, git_sha, pod_hash, stable_hash, verdict, source_pr, source_branch)"
            " VALUES (?,?,?,?,?,?,?,?,?)",
            (time.time(), ev["env"], ev["image"], ev.get("gitSha"), ev.get("canaryHash"),
             ev.get("stableHash"), verdict, ev.get("sourcePR"), ev.get("sourceBranch")),
        )

    def releases(self, limit: int = 50) -> list[dict]:
        return self._rows("SELECT * FROM releases ORDER BY id DESC LIMIT ?", (limit,))

    def image_history(self, image: str) -> list[dict]:
        return self._rows("SELECT * FROM releases WHERE image=? ORDER BY id", (image,))

    # ── investigations ──────────────────────────────────────────────────────
    def recent_investigation(self, env: str, image: str, within_s: int = 1800) -> dict | None:
        rows = self._rows(
            "SELECT * FROM investigations WHERE env=? AND image=? AND status IN ('running','done') AND ts>?"
            " ORDER BY id DESC LIMIT 1",
            (env, image, time.time() - within_s),
        )
        return rows[0] if rows else None

    def start_investigation(self, ev: dict) -> int:
        cur = self._exec(
            "INSERT INTO investigations (ts, env, image, status, event) VALUES (?,?,?,?,?)",
            (time.time(), ev["env"], ev["image"], "running", json.dumps(ev)),
        )
        return cur.lastrowid

    def add_step(self, inv_id: int, step: dict) -> None:
        with self._lock:
            row = self._db.execute("SELECT steps FROM investigations WHERE id=?", (inv_id,)).fetchone()
            steps = json.loads(row["steps"]) + [{"t": time.time(), **step}]
            self._db.execute("UPDATE investigations SET steps=? WHERE id=?", (json.dumps(steps), inv_id))
            self._db.commit()

    def finish_investigation(self, inv_id: int, status: str, report: dict | None = None, error: str | None = None):
        self._exec(
            "UPDATE investigations SET status=?, report=?, error=? WHERE id=?",
            (status, json.dumps(report) if report else None, error, inv_id),
        )

    def investigations(self, limit: int = 10) -> list[dict]:
        rows = self._rows("SELECT * FROM investigations ORDER BY id DESC LIMIT ?", (limit,))
        for r in rows:
            r["event"] = json.loads(r["event"])
            r["steps"] = json.loads(r["steps"])
            r["report"] = json.loads(r["report"]) if r["report"] else None
        return rows
