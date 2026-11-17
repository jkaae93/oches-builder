"""SQLite candidate experiments in disposable DBs; NOT Oches product tests."""
import sqlite3
import tempfile
import unittest
from pathlib import Path

class BackupExperiments(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.path=self.root/'source.db';self.backup=self.root/'backup.db'
        self.db=sqlite3.connect(str(self.path), isolation_level=None)
        self.db.execute('PRAGMA journal_mode=WAL');self.db.execute('PRAGMA synchronous=FULL')
        self.db.executescript('CREATE TABLE state(id TEXT PRIMARY KEY, value TEXT); CREATE TABLE event(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO state VALUES (\'a\',\'before\');')
    def tearDown(self):self.db.close();self.tmp.cleanup()
    def copy(self):
        target=sqlite3.connect(str(self.backup))
        try:self.db.backup(target)
        finally:target.close()
    def test_backup_snapshot_has_consistent_state_and_event(self):
        self.db.execute('BEGIN IMMEDIATE');self.db.execute("UPDATE state SET value='committed'");self.db.execute("INSERT INTO event VALUES (1,'committed')");self.db.commit()
        self.copy()
        self.db.execute('BEGIN IMMEDIATE');self.db.execute("UPDATE state SET value='later'");self.db.execute("INSERT INTO event VALUES (2,'later')");self.db.commit()
        old=sqlite3.connect(str(self.backup))
        try:
            self.assertEqual(('committed',),old.execute('SELECT value FROM state').fetchone())
            self.assertEqual([(1,'committed')],old.execute('SELECT id,value FROM event').fetchall())
            self.assertEqual([('ok',)],old.execute('PRAGMA integrity_check').fetchall())
        finally:old.close()
    def test_backup_can_resurrect_deleted_data_without_external_ledger(self):
        self.copy();self.db.execute("DELETE FROM state WHERE id='a'")
        self.assertEqual([],self.db.execute('SELECT * FROM state').fetchall())
        old=sqlite3.connect(str(self.backup))
        try:self.assertEqual([('a','before')],old.execute('SELECT * FROM state').fetchall())
        finally:old.close()
    def test_integrity_check_does_not_replace_foreign_key_check(self):
        self.db.executescript('PRAGMA foreign_keys=OFF; CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(p INTEGER REFERENCES parent(id)); INSERT INTO child VALUES (123);')
        self.assertEqual([('ok',)],self.db.execute('PRAGMA integrity_check').fetchall())
        self.assertTrue(self.db.execute('PRAGMA foreign_key_check').fetchall())
    def test_sqlite_full_rolls_back_transaction(self):
        self.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        page_count=self.db.execute('PRAGMA page_count').fetchone()[0]
        self.db.execute(f'PRAGMA max_page_count={page_count+2}')
        self.db.execute('BEGIN IMMEDIATE')
        try:
            self.db.execute("UPDATE state SET value='partial'")
            with self.assertRaises(sqlite3.OperationalError) as failure:self.db.execute('INSERT INTO state VALUES (?,?)',('big','x'*1048576))
            self.assertIn('full', str(failure.exception).lower())
        finally:self.db.rollback()
        self.assertEqual([('a','before')],self.db.execute('SELECT id,value FROM state').fetchall())
        self.assertEqual([],self.db.execute('SELECT * FROM event').fetchall())

if __name__=='__main__': unittest.main(verbosity=2)
