import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "repair_dsh_projections", Path(__file__).resolve().parents[1] / "repair_dsh_projections.py"
)
repair = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(repair)


class RepairDSHProjectionsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.relay_path = root / "relay.db"
        self.daemon_path = root / "daemon.db"
        self.backups = root / "backup"
        with sqlite3.connect(self.relay_path) as db:
            db.executescript("""
                CREATE TABLE workspaces(id TEXT PRIMARY KEY, terminal_id TEXT);
                CREATE TABLE sessions(id TEXT PRIMARY KEY, workspace_id TEXT, account_id TEXT,
                    provider TEXT, status TEXT, archived_at_unix_ms INTEGER DEFAULT 0,
                    last_seq INTEGER DEFAULT 0, origin TEXT DEFAULT 'managed', visibility TEXT DEFAULT 'default');
                CREATE TABLE commands(id TEXT PRIMARY KEY, session_id TEXT, kind TEXT, status TEXT);
                CREATE TABLE session_events(session_id TEXT, event_type TEXT, body TEXT);
                INSERT INTO workspaces VALUES('w','t');
                INSERT INTO sessions(id,workspace_id,account_id,provider,status,last_seq)
                    VALUES('original','w','a','dsh','idle',2);
                INSERT INTO sessions(id,workspace_id,account_id,provider,status,origin,visibility)
                    VALUES('imported','w','a','dsh','idle','dsh_import','history');
                INSERT INTO commands VALUES('cmd','original','session.start','succeeded');
                INSERT INTO session_events VALUES('original','session.created','{}');
                INSERT INTO session_events VALUES('original','user.message','original ciphertext');
                INSERT INTO session_events VALUES('imported','user.message','imported ciphertext');
            """)
        with sqlite3.connect(self.daemon_path) as db:
            db.execute("CREATE TABLE local_state(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            for sid in ("original", "imported"):
                db.execute("INSERT INTO local_state VALUES(?,?)", (
                    "instance:" + sid,
                    json.dumps({"provider": "dsh", "workspace_root": "/private/project", "instance_id": "source"}),
                ))
            db.execute("INSERT INTO local_state VALUES(?,?)", ("dshthread:/private/project:source", "imported"))

    def inspect(self):
        with repair.connect(self.relay_path) as relay, repair.connect(self.daemon_path) as daemon:
            return repair.inspect(relay, daemon)

    def test_preview_is_readonly_and_does_not_expose_paths(self):
        before = self.relay_path.read_bytes(), self.daemon_path.read_bytes()
        plan = self.inspect()
        self.assertEqual(len(plan["changes"]), 1)
        self.assertEqual(plan["changes"][0]["canonical"], "original")
        self.assertNotIn("/private/project", json.dumps(repair.public_plan(plan)))
        self.assertEqual(before, (self.relay_path.read_bytes(), self.daemon_path.read_bytes()))

    def test_apply_preserves_events_and_is_idempotent_then_restorable(self):
        result = repair.apply(self.relay_path, self.daemon_path, self.backups)
        self.assertTrue(result["applied"])
        with repair.connect(self.relay_path) as relay, repair.connect(self.daemon_path) as daemon:
            self.assertEqual(relay.execute("SELECT visibility FROM sessions WHERE id='original'").fetchone()[0], "default")
            self.assertEqual(relay.execute("SELECT visibility FROM sessions WHERE id='imported'").fetchone()[0], "duplicate")
            self.assertEqual(relay.execute("SELECT count(*) FROM sessions").fetchone()[0], 2)
            self.assertEqual(relay.execute("SELECT count(*) FROM session_events").fetchone()[0], 3)
            self.assertEqual(daemon.execute("SELECT value FROM local_state WHERE key LIKE 'dshthread:%'").fetchone()[0], "original")
        self.assertFalse(repair.apply(self.relay_path, self.daemon_path, self.backups)["applied"])
        self.assertTrue(repair.restore(self.backups / "repair-journal.json")["restored"])
        self.assertEqual(len(self.inspect()["changes"]), 1)
        with repair.connect(self.backups / "relay.db") as original:
            self.assertEqual(original.execute("SELECT visibility FROM sessions WHERE id='imported'").fetchone()[0], "history")

    def test_refuses_independently_used_import(self):
        with sqlite3.connect(self.relay_path) as db:
            db.execute("INSERT INTO commands VALUES('other','imported','session.send','succeeded')")
        self.assertEqual(self.inspect()["conflicts"][0]["reason"], "duplicate_has_independent_activity")
        with self.assertRaises(ValueError):
            repair.apply(self.relay_path, self.daemon_path, self.backups)
        self.assertFalse(self.backups.exists())

    def test_refuses_scope_mismatch(self):
        with sqlite3.connect(self.relay_path) as db:
            db.execute("UPDATE sessions SET account_id='other' WHERE id='imported'")
        self.assertEqual(self.inspect()["conflicts"][0]["reason"], "scope_mismatch")

    def test_refuses_running_commands_and_sessions(self):
        with sqlite3.connect(self.relay_path) as db:
            db.execute("UPDATE commands SET status='accepted'")
        with self.assertRaises(ValueError):
            repair.apply(self.relay_path, self.daemon_path, self.backups)
        with sqlite3.connect(self.relay_path) as db:
            db.execute("UPDATE commands SET status='succeeded'")
            db.execute("UPDATE sessions SET status='running' WHERE id='original'")
        self.assertEqual(self.inspect()["conflicts"][0]["reason"], "session_not_quiescent")

    def test_last_seq_zero_does_not_delete_imported_events(self):
        repair.apply(self.relay_path, self.daemon_path, self.backups)
        with repair.connect(self.relay_path) as db:
            self.assertEqual(db.execute("SELECT body FROM session_events WHERE session_id='imported'").fetchone()[0], "imported ciphertext")
            self.assertEqual(db.execute("SELECT last_seq FROM sessions WHERE id='imported'").fetchone()[0], 0)

    def test_restore_refuses_subsequent_changes(self):
        repair.apply(self.relay_path, self.daemon_path, self.backups)
        with sqlite3.connect(self.relay_path) as db:
            db.execute("INSERT INTO session_events VALUES('imported','user.message','later')")
        with self.assertRaises(ValueError):
            repair.restore(self.backups / "repair-journal.json")

    def test_refuses_missing_visibility_schema(self):
        with sqlite3.connect(self.relay_path) as db:
            db.execute("ALTER TABLE sessions DROP COLUMN visibility")
        self.assertFalse(self.inspect()["schema_ready"])
        with self.assertRaises(ValueError):
            repair.apply(self.relay_path, self.daemon_path, self.backups)


if __name__ == "__main__":
    unittest.main()
