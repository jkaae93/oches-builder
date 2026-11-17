"""Isolated subprocess + SQLite experiment; NOT product or provider adapter."""
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

WORKER = "import pathlib,sys,time; time.sleep(float(sys.argv[2])); pathlib.Path(sys.argv[1]).write_text('completed')"

class MiniSupervisor:
    def __init__(self,db,marker): self.db=db;self.marker=marker;self.process=None
    def start(self):
        # Must commit intent before creating an external process.
        with sqlite3.connect(self.db) as c:
            c.execute("INSERT INTO attempt (id,status) VALUES ('a','Starting')")
        self.process=subprocess.Popen([sys.executable,'-c',WORKER,str(self.marker),'10'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        with sqlite3.connect(self.db) as c:c.execute("UPDATE attempt SET status='Running' WHERE id='a'")
        return self.process
    def cancel(self):
        with sqlite3.connect(self.db) as c:c.execute("UPDATE attempt SET status='CancelRequested' WHERE id='a'")
        self.process.terminate();self.process.wait(timeout=5)
        with sqlite3.connect(self.db) as c:c.execute("UPDATE attempt SET status='Cancelled' WHERE id='a'")
    def status(self):
        with sqlite3.connect(self.db) as c:return c.execute("SELECT status FROM attempt WHERE id='a'").fetchone()[0]

class ProcessExperiment(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.db=self.root/'state.db';self.marker=self.root/'marker'
        with sqlite3.connect(self.db) as c:c.execute('CREATE TABLE attempt(id TEXT PRIMARY KEY,status TEXT NOT NULL)')
        self.s=MiniSupervisor(self.db,self.marker)
    def tearDown(self):
        if self.s.process and self.s.process.poll() is None:
            self.s.process.kill();self.s.process.wait(timeout=5)
        self.tmp.cleanup()
    def test_record_start_then_cancel_and_observe_process_exit(self):
        p=self.s.start();self.assertEqual('Running',self.s.status());self.assertIsNone(p.poll())
        self.s.cancel();self.assertIsNotNone(p.poll());self.assertEqual('Cancelled',self.s.status());self.assertFalse(self.marker.exists())
    def test_storage_error_prevents_spawning(self):
        with sqlite3.connect(self.db) as c:c.execute('DROP TABLE attempt')
        with self.assertRaises(sqlite3.OperationalError):self.s.start()
        self.assertIsNone(self.s.process);self.assertFalse(self.marker.exists())
    def test_unconfirmed_recovery_never_launches_automatically(self):
        # No claim about whether the external side effect actually occurred.
        with sqlite3.connect(self.db) as c:c.execute("INSERT INTO attempt VALUES ('a','Starting')")
        with sqlite3.connect(self.db) as c:
            c.execute("UPDATE attempt SET status='Unknown' WHERE id='a' AND status='Starting'")
        self.assertEqual('Unknown',self.s.status());self.assertIsNone(self.s.process)
        self.assertFalse(self.marker.exists())

if __name__=='__main__':unittest.main(verbosity=2)
