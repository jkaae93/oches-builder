"""Isolated SQLite concurrency experiment, not the Oches authentication system."""
import multiprocessing
from pathlib import Path
import sqlite3
import tempfile
import unittest


def attempt(path, nonce, queue):
    db = sqlite3.connect(str(path), timeout=10, isolation_level=None)
    try:
        db.execute('BEGIN IMMEDIATE')
        used = db.execute('UPDATE nonce SET used=1 WHERE id=? AND used=0', (nonce,)).rowcount
        if not used:
            db.rollback()
            queue.put('REPLAY')
            return
        previous = db.execute('SELECT result FROM request WHERE id=?', ('request-1',)).fetchone()
        if previous is None:
            db.execute('INSERT INTO request VALUES (?,?)', ('request-1', 'accepted'))
            db.execute('INSERT INTO effect VALUES (?)', ('intent',))
            result = 'FIRST'
        else:
            result = 'RETRIEVED'
        db.commit()
        queue.put(result)
    finally:
        db.close()


class NonceRetryExperiment(unittest.TestCase):
    def test_distinct_challenges_deduplicate_and_each_is_single_use(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.db'
            with sqlite3.connect(str(path)) as db:
                db.executescript('''
                    CREATE TABLE nonce(id TEXT PRIMARY KEY, used INTEGER NOT NULL);
                    CREATE TABLE request(id TEXT PRIMARY KEY, result TEXT NOT NULL);
                    CREATE TABLE effect(name TEXT NOT NULL);
                    INSERT INTO nonce VALUES ('n1',0),('n2',0);
                ''')
            queue = multiprocessing.Queue()
            processes = [multiprocessing.Process(target=attempt, args=(path, n, queue))
                         for n in ('n1', 'n1', 'n2')]
            for process in processes:
                process.start()
            for process in processes:
                process.join(10)
                self.assertEqual(0, process.exitcode)
            self.assertCountEqual(['FIRST', 'RETRIEVED', 'REPLAY'],
                                  [queue.get(timeout=2) for _ in processes])
            with sqlite3.connect(str(path)) as db:
                self.assertEqual(1, db.execute('SELECT COUNT(*) FROM effect').fetchone()[0])
                self.assertEqual(2, db.execute('SELECT COUNT(*) FROM nonce WHERE used=1').fetchone()[0])


if __name__ == '__main__':
    unittest.main()
