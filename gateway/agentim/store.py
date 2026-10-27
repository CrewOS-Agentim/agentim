"""Per-chat history and settings in SQLite."""

import os
import sqlite3
import threading
import time


class Store:
    def __init__(self, path):
        if path != ":memory:":
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.lock = threading.Lock()
        with self.lock, self.db:
            self.db.execute("""CREATE TABLE IF NOT EXISTS chats (
                key TEXT PRIMARY KEY, agent TEXT, pinned_model TEXT)""")
            self.db.execute("""CREATE TABLE IF NOT EXISTS messages (
                key TEXT, role TEXT, content TEXT, model TEXT, ts REAL)""")
            self.db.execute("CREATE INDEX IF NOT EXISTS messages_key ON messages (key, ts)")

    def _chat(self, key):
        row = self.db.execute("SELECT agent, pinned_model FROM chats WHERE key = ?", (key,)).fetchone()
        return row or (None, None)

    def agent(self, key):
        with self.lock:
            return self._chat(key)[0]

    def pinned(self, key):
        with self.lock:
            return self._chat(key)[1]

    def set_agent(self, key, agent):
        with self.lock, self.db:
            self.db.execute("""INSERT INTO chats (key, agent) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET agent = excluded.agent""", (key, agent))

    def set_pinned(self, key, model):
        with self.lock, self.db:
            self.db.execute("""INSERT INTO chats (key, pinned_model) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET pinned_model = excluded.pinned_model""", (key, model))

    def add(self, key, role, content, model=None):
        with self.lock, self.db:
            self.db.execute("INSERT INTO messages VALUES (?, ?, ?, ?, ?)", (key, role, content, model, time.time()))

    def history(self, key, limit=20):
        with self.lock:
            rows = self.db.execute(
                "SELECT role, content FROM messages WHERE key = ? ORDER BY ts DESC, rowid DESC LIMIT ?",
                (key, limit)).fetchall()
        return [{"role": role, "content": content} for role, content in reversed(rows)]

    def reset(self, key):
        with self.lock, self.db:
            self.db.execute("DELETE FROM messages WHERE key = ?", (key,))
