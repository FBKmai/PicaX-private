"""Durable jobs; only generated UUID directories and fixed page IDs reach disk."""
import json
import os
import shutil
import sqlite3
import threading
import time
import uuid
from pathlib import Path

from .protocol import (ProtocolError, canonical, digest_file, identifier, PAGE_RE,
                       MAX_INPUT_BYTES, MAX_OUTPUT_BYTES, MAX_PIXELS, png_dimensions,
                       validate_spec, validate_result)


class JobStore:
    def __init__(self, root, job_quota=8 * 1024**3, total_quota=16 * 1024**3):
        if Path(root).is_symlink():
            raise ProtocolError("Storage root must not be a symlink")
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.files = self.root / "jobs"
        self.files.mkdir(exist_ok=True)
        if self.files.is_symlink():
            raise ProtocolError("Job root must not be a symlink")
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(self.root / "jobs.sqlite3"), check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.job_quota, self.total_quota = job_quota, total_quota
        with self.db:
            self.db.executescript("""
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, client TEXT NOT NULL,
                    spec TEXT NOT NULL, state TEXT NOT NULL, created REAL NOT NULL,
                    updated REAL NOT NULL, reserved INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS pages (job TEXT NOT NULL, id TEXT NOT NULL,
                    state TEXT NOT NULL, result TEXT, error TEXT, ack INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(job,id));
            """)
            self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('serverID', ?)", (str(uuid.uuid4()),))
        self.server_id = self.db.execute("SELECT value FROM metadata WHERE key='serverID'").fetchone()[0]

    def close(self):
        self.db.close()

    def directory(self, job_id):
        identifier(job_id)
        directory = self.files / job_id
        if directory.is_symlink() or directory.resolve().parent != self.files:
            raise ProtocolError("Unsafe job directory")
        return directory

    def path(self, job_id, page_id, suffix):
        if not isinstance(page_id, str) or not PAGE_RE.fullmatch(page_id) or suffix not in ("source.png", "result.png", "source.part", "result.part"):
            raise ProtocolError("Invalid page path")
        result = self.directory(job_id) / (page_id + "." + suffix)
        if result.is_symlink():
            raise ProtocolError("Symlink in job directory")
        return result

    def _job(self, job_id, client_id=None):
        identifier(job_id)
        row = self.db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        if not row or (client_id is not None and row["client"] != client_id):
            raise ProtocolError("Job not found", 404)
        return row

    def create(self, client_id, spec, maximum_side, maximum_pixels):
        validate_spec(spec, maximum_side, maximum_pixels)
        encoded = canonical(spec)
        # Include duplicate-upload staging and a conservative RGBA PNG bound.
        scale = spec["deliveryScale"]
        reserved = sum(p["bytes"] * 2 + p["width"] * p["height"] * scale**2 * 4 + 65536 for p in spec["pages"])
        with self.lock, self.db:
            existing = self.db.execute("SELECT * FROM jobs WHERE id=?", (spec["jobID"],)).fetchone()
            if existing:
                if existing["client"] != client_id:
                    raise ProtocolError("Job not found", 404)
                if existing["spec"] != encoded:
                    raise ProtocolError("Job ID reused with different inputs", 409)
                return self.status(spec["jobID"], client_id)
            gib = 1024**3
            if reserved > self.job_quota:
                raise ProtocolError(
                    f"单任务磁盘配额不足：{len(spec['pages'])} 页预计需要 {reserved / gib:.2f} GiB，"
                    f"单任务上限 {self.job_quota / gib:.2f} GiB。"
                    "请拆分任务或提高电脑端 --job-quota-gib；清理旧任务不会解除单任务上限。", 507)
            total = self.db.execute("SELECT COALESCE(SUM(reserved),0) FROM jobs").fetchone()[0]
            if reserved + total > self.total_quota:
                raise ProtocolError(
                    f"任务总磁盘配额不足：已有任务预留 {total / gib:.2f} GiB，"
                    f"新任务需要 {reserved / gib:.2f} GiB，总上限 {self.total_quota / gib:.2f} GiB。"
                    "请清理不再需要的旧任务或提高电脑端 --total-quota-gib。", 507)
            free = shutil.disk_usage(self.root).free
            if free < reserved + 128 * 1024**2:
                raise ProtocolError(
                    f"电脑磁盘实际剩余空间不足：剩余 {free / gib:.2f} GiB，"
                    f"新任务预计需要 {reserved / gib:.2f} GiB，另需保留 128 MiB。"
                    "请释放空间；提高任务配额不能解决实际磁盘不足。", 507)
            if self.db.execute("SELECT COUNT(*) FROM jobs WHERE state IN ('uploading','queued','running')").fetchone()[0] >= 8:
                raise ProtocolError("Server queue is full", 429)
            directory = self.directory(spec["jobID"])
            directory.mkdir(exist_ok=True)
            now = time.time()
            self.db.execute("INSERT INTO jobs VALUES (?,?,?,?,?,?,?)", (spec["jobID"], client_id, encoded, "uploading", now, now, reserved))
            self.db.executemany("INSERT INTO pages(job,id,state) VALUES (?,?,'missing')", [(spec["jobID"], p["id"]) for p in spec["pages"]])
            return self.status(spec["jobID"], client_id)

    def status(self, job_id, client_id):
        with self.lock:
            job = self._job(job_id, client_id)
            pages = self.db.execute("SELECT * FROM pages WHERE job=? ORDER BY id", (job_id,)).fetchall()
            return {"jobID": job_id, "state": job["state"], "pages": [
                {"id": p["id"], "state": p["state"], "result": json.loads(p["result"]) if p["result"] else None,
                 "error": p["error"], "acknowledged": bool(p["ack"])} for p in pages]}

    def page(self, job_id, client_id, page_id):
        with self.lock:
            job = self._job(job_id, client_id)
            spec = json.loads(job["spec"])
            for page in spec["pages"]:
                if page["id"] == page_id:
                    return dict(page), job["state"]
            raise ProtocolError("Page not found", 404)

    def spec(self, job_id, client_id=None):
        with self.lock:
            return json.loads(self._job(job_id, client_id)["spec"])

    def state(self, job_id):
        with self.lock:
            return self._job(job_id)["state"]

    def accept_upload(self, job_id, client_id, page_id, temporary):
        with self.lock, self.db:
            page, state = self.page(job_id, client_id, page_id)
            destination = self.path(job_id, page_id, "source.png")
            if temporary != self.path(job_id, page_id, "source.part"):
                raise ProtocolError("Unexpected upload staging path")
            if temporary.stat().st_size != page["bytes"] or digest_file(temporary) != page["sha256"]:
                raise ProtocolError("Input size/SHA-256 mismatch", 422)
            if png_dimensions(temporary, MAX_INPUT_BYTES, MAX_PIXELS) != (page["width"], page["height"]):
                raise ProtocolError("Input dimensions mismatch", 422)
            if state != "uploading":
                if state != "cancelled" and destination.is_file() and digest_file(destination) == page["sha256"]:
                    return  # Retry after a lost HTTP response must not reset a page.
                raise ProtocolError("Job is no longer accepting uploads", 409)
            # Windows FlushFileBuffers requires a write-capable descriptor.
            with temporary.open("r+b") as stream:
                os.fsync(stream.fileno())
            temporary.replace(destination)
            self.db.execute("UPDATE pages SET state='uploaded' WHERE job=? AND id=? AND state='missing'", (job_id, page_id))
            self.db.execute("UPDATE jobs SET updated=? WHERE id=?", (time.time(), job_id))

    def commit(self, job_id, client_id):
        with self.lock, self.db:
            job = self._job(job_id, client_id)
            if job["state"] == "uploading":
                if self.db.execute("SELECT COUNT(*) FROM pages WHERE job=? AND state='missing'", (job_id,)).fetchone()[0]:
                    raise ProtocolError("Upload all pages before committing", 409)
                self.db.execute("UPDATE jobs SET state='queued',updated=? WHERE id=?", (time.time(), job_id))
            elif job["state"] == "cancelled":
                raise ProtocolError("Job cancelled", 409)
            return self.status(job_id, client_id)

    def cancel(self, job_id, client_id):
        with self.lock, self.db:
            self._job(job_id, client_id)
            self.db.execute("UPDATE jobs SET state='cancelled',updated=? WHERE id=?", (time.time(), job_id))
            return self.status(job_id, client_id)

    def next_page(self):
        with self.lock, self.db:
            row = self.db.execute("SELECT jobs.id AS job, jobs.spec, pages.id FROM jobs JOIN pages ON jobs.id=pages.job WHERE jobs.state IN ('queued','running') AND pages.state='uploaded' ORDER BY jobs.created,pages.id LIMIT 1").fetchone()
            if not row:
                return None
            self.db.execute("UPDATE jobs SET state='running',updated=? WHERE id=?", (time.time(), row["job"]))
            self.db.execute("UPDATE pages SET state='running' WHERE job=? AND id=?", (row["job"], row["id"]))
            page = next(p for p in json.loads(row["spec"])["pages"] if p["id"] == row["id"])
            return row["job"], page

    def finish_page(self, job_id, page_id, result=None, error=None):
        with self.lock, self.db:
            job = self._job(job_id)
            if job["state"] == "cancelled":
                return
            if result is not None:
                spec = json.loads(job["spec"])
                page = next(p for p in spec["pages"] if p["id"] == page_id)
                validate_result(result, spec, page)
            self.db.execute("UPDATE pages SET state=?,result=?,error=? WHERE job=? AND id=?", (
                "succeeded" if result else "failed", canonical(result) if result else None,
                str(error)[:1024] if error else None, job_id, page_id))
            remaining = self.db.execute("SELECT COUNT(*) FROM pages WHERE job=? AND state IN ('uploaded','running')", (job_id,)).fetchone()[0]
            failed = self.db.execute("SELECT COUNT(*) FROM pages WHERE job=? AND state='failed'", (job_id,)).fetchone()[0]
            state = "running" if remaining else ("partial" if failed else "completed")
            self.db.execute("UPDATE jobs SET state=?,updated=? WHERE id=?", (state, time.time(), job_id))

    def acknowledge(self, job_id, client_id, page_id, sha256):
        with self.lock, self.db:
            self._job(job_id, client_id)
            row = self.db.execute("SELECT result FROM pages WHERE job=? AND id=? AND state='succeeded'", (job_id, page_id)).fetchone()
            if not row or json.loads(row[0])["sha256"] != sha256:
                raise ProtocolError("Cannot acknowledge an unverified result", 409)
            self.db.execute("UPDATE pages SET ack=1 WHERE job=? AND id=?", (job_id, page_id))
            self.db.execute("UPDATE jobs SET updated=? WHERE id=?", (time.time(), job_id))
            remaining = self.db.execute("SELECT COUNT(*) FROM pages WHERE job=? AND ack=0", (job_id,)).fetchone()[0]
            if not remaining:
                self.db.execute("UPDATE jobs SET state='acknowledged',updated=? WHERE id=? AND state!='cancelled'", (time.time(), job_id))
            return {"ok": True}

    def recover(self):
        """A result file is not committed until its hash and database row agree."""
        with self.lock, self.db:
            # Staging files are never authoritative. A killed upload/worker can
            # leave them behind; remove only these fixed, validated page paths.
            for row in self.db.execute("SELECT id,spec FROM jobs").fetchall():
                for page in json.loads(row["spec"])["pages"]:
                    for suffix in ("source.part", "result.part"):
                        self.path(row["id"], page["id"], suffix).unlink(missing_ok=True)
            jobs = self.db.execute("SELECT * FROM jobs WHERE state!='cancelled'").fetchall()
            for job in jobs:
                for page in json.loads(job["spec"])["pages"]:
                    row = self.db.execute("SELECT * FROM pages WHERE job=? AND id=?", (job["id"], page["id"])).fetchone()
                    if row["state"] == "succeeded":
                        result = json.loads(row["result"])
                        path = self.path(job["id"], page["id"], "result.png")
                        if path.is_file() and digest_file(path) == result["sha256"]:
                            continue
                        if row["ack"]:
                            continue  # Client already durably owns this output.
                    elif row["state"] == "failed":
                        continue
                    source = self.path(job["id"], page["id"], "source.png")
                    valid = source.is_file() and source.stat().st_size == page["bytes"] and digest_file(source) == page["sha256"]
                    self.db.execute("UPDATE pages SET state=?,result=NULL,ack=0 WHERE job=? AND id=?", ("uploaded" if valid else "missing", job["id"], page["id"]))
                states = [r[0] for r in self.db.execute("SELECT state FROM pages WHERE job=?", (job["id"],))]
                if "missing" in states:
                    state = "uploading"
                elif "uploaded" in states:
                    state = "uploading" if job["state"] == "uploading" else "queued"
                else:
                    acknowledged = all(r[0] for r in self.db.execute("SELECT ack FROM pages WHERE job=?", (job["id"],)))
                    state = "partial" if "failed" in states else ("acknowledged" if acknowledged else "completed")
                self.db.execute("UPDATE jobs SET state=? WHERE id=?", (state, job["id"]))

    def retry_failed(self, job_id, client_id):
        with self.lock, self.db:
            job = self._job(job_id, client_id)
            if job["state"] != "partial":
                raise ProtocolError("Only a partially failed job can be retried", 409)
            spec = json.loads(job["spec"])
            for page in spec["pages"]:
                row = self.db.execute("SELECT state FROM pages WHERE job=? AND id=?", (job_id, page["id"])).fetchone()
                if row[0] != "failed":
                    continue
                source = self.path(job_id, page["id"], "source.png")
                if not source.is_file() or digest_file(source) != page["sha256"]:
                    raise ProtocolError("Stored source missing; submit a new job", 409)
                self.db.execute("UPDATE pages SET state='uploaded',error=NULL WHERE job=? AND id=?", (job_id, page["id"]))
            self.db.execute("UPDATE jobs SET state='queued',updated=? WHERE id=?", (time.time(), job_id))
            return self.status(job_id, client_id)

    def cleanup(self, retention_seconds=86400):
        with self.lock, self.db:
            rows = self.db.execute("SELECT id FROM jobs WHERE updated<? AND state NOT IN ('queued','running')", (time.time() - retention_seconds,)).fetchall()
            for row in rows:
                directory = self.directory(row[0])
                if directory.exists():
                    shutil.rmtree(directory)
                self.db.execute("DELETE FROM pages WHERE job=?", (row[0],))
                self.db.execute("DELETE FROM jobs WHERE id=?", (row[0],))
