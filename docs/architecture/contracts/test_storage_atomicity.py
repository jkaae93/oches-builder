"""SQLite design experiment in isolated temp databases; not Oches product storage."""
import multiprocessing
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

SCHEMA = '''
PRAGMA journal_mode = DELETE;
PRAGMA synchronous = FULL;
CREATE TABLE state(id TEXT PRIMARY KEY, version INTEGER NOT NULL, value TEXT NOT NULL);
CREATE TABLE event(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL, value TEXT NOT NULL);
CREATE TABLE request(scope TEXT NOT NULL, op TEXT NOT NULL, input TEXT NOT NULL, result TEXT NOT NULL, PRIMARY KEY(scope, op));
INSERT INTO state VALUES ('task',0,'ready');
'''

def open_db(path):
    return sqlite3.connect(str(path), timeout=5, isolation_level=None)

def transition(path, op, value, expected=0, scope='workspace/actor'):
    c=open_db(path)
    normalized=json.dumps({'value': value, 'expected': expected},sort_keys=True,separators=(',',':'))
    try:
        c.execute('BEGIN IMMEDIATE')
        previous=c.execute('SELECT input,result FROM request WHERE scope=? AND op=?',(scope,op)).fetchone()
        if previous:
            c.rollback()
            return previous[1] if previous[0]==normalized else 'IDEMPOTENCY_CONFLICT'
        changed=c.execute('UPDATE state SET version=version+1,value=? WHERE id=? AND version=?',(value,'task',expected)).rowcount
        if changed!=1:
            c.rollback(); return 'VERSION_CONFLICT'
        c.execute('INSERT INTO event(op,value) VALUES (?,?)',(op,value))
        c.execute('INSERT INTO request(scope,op,input,result) VALUES (?,?,?,?)',(scope,op,normalized,'OK'))
        c.commit(); return 'OK'
    finally: c.close()

def kill_after(path, phase):
    c=open_db(path); c.execute('BEGIN IMMEDIATE')
    c.execute("UPDATE state SET version=1,value='running' WHERE id='task'")
    if phase=='state': os._exit(71)
    c.execute("INSERT INTO event(op,value) VALUES ('x','running')")
    if phase=='event': os._exit(72)
    c.execute('INSERT INTO request(scope,op,input,result) VALUES (?,?,?,?)',('workspace/actor','x',json.dumps({'value':'running','expected':0},sort_keys=True,separators=(',',':')),'OK'))
    if phase=='request': os._exit(73)
    c.commit();os._exit(0)

def worker(path, op, q):
    q.put(transition(path,op,'running'))

class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.path=Path(self.tmp.name)/'test.db'
        c=open_db(self.path);c.executescript(SCHEMA);c.close()
    def tearDown(self):self.tmp.cleanup()
    def snapshot(self):
        c=open_db(self.path)
        try:return (c.execute('SELECT version,value FROM state').fetchone(), c.execute('SELECT op,value FROM event').fetchall(),c.execute('SELECT op,input,result FROM request').fetchall())
        finally:c.close()
    def test_idempotency_and_conflicts(self):
        self.assertEqual('OK',transition(self.path,'x','running'))
        self.assertEqual('OK',transition(self.path,'x','running'))
        self.assertEqual('IDEMPOTENCY_CONFLICT',transition(self.path,'x','other'))
        self.assertEqual('IDEMPOTENCY_CONFLICT',transition(self.path,'x','running',expected=1))
        self.assertEqual('VERSION_CONFLICT',transition(self.path,'y','other'))
        self.assertEqual(((1,'running'),[('x','running')],[('x','{\"expected\":0,\"value\":\"running\"}','OK')]),self.snapshot())
    def test_process_crash_before_commit(self):
        for phase,expected_code in [('state',71),('event',72),('request',73)]:
            with self.subTest(phase=phase):
                p=multiprocessing.Process(target=kill_after,args=(self.path,phase));p.start();p.join(10)
                self.assertEqual(expected_code,p.exitcode)
                self.assertEqual(((0,'ready'),[],[]),self.snapshot())
    def test_simultaneous_competing_writers(self):
        q=multiprocessing.Queue(); processes=[multiprocessing.Process(target=worker,args=(self.path,op,q)) for op in ('x','y')]
        for p in processes:p.start()
        for p in processes:p.join(10);self.assertEqual(0,p.exitcode)
        self.assertCountEqual(['OK','VERSION_CONFLICT'],[q.get(timeout=2),q.get(timeout=2)])
        state,events,requests=self.snapshot();self.assertEqual((1,'running'),state);self.assertEqual(1,len(events));self.assertEqual(1,len(requests))
    def test_concurrent_duplicate_request_has_one_effect(self):
        q=multiprocessing.Queue(); processes=[multiprocessing.Process(target=worker,args=(self.path,'same',q)) for _ in range(2)]
        for p in processes:p.start()
        for p in processes:p.join(10);self.assertEqual(0,p.exitcode)
        self.assertEqual(['OK','OK'],[q.get(timeout=2),q.get(timeout=2)])
        state,events,requests=self.snapshot();self.assertEqual((1,'running'),state);self.assertEqual(1,len(events));self.assertEqual(1,len(requests))

    def test_consistent_snapshot_and_cursor_during_write(self):
        setup=open_db(self.path); setup.execute('PRAGMA journal_mode=WAL'); setup.close()
        reader=open_db(self.path)
        try:
            reader.execute('BEGIN')
            state=reader.execute('SELECT version,value FROM state').fetchone()
            self.assertEqual('OK',transition(self.path,'x','running'))
            cursor=reader.execute('SELECT COALESCE(MAX(seq),0) FROM event').fetchone()[0]
            self.assertEqual(((0,'ready'),0),(state,cursor))
            reader.commit()
            replay=reader.execute('SELECT seq,op,value FROM event WHERE seq>? ORDER BY seq',(cursor,)).fetchall()
            self.assertEqual([(1,'x','running')],replay)
        finally:reader.close()

    def test_committed_survives_process_exit(self):
        p=multiprocessing.Process(target=kill_after,args=(self.path,'commit'));p.start();p.join(10)
        self.assertEqual(0,p.exitcode)
        self.assertEqual(((1,'running'),[('x','running')],[('x','{\"expected\":0,\"value\":\"running\"}','OK')]),self.snapshot())

if __name__=='__main__':unittest.main(verbosity=2)
