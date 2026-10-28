#!/usr/bin/env python3
import json, os, pathlib, subprocess, tempfile, unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
class IndexerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(dir="/private/tmp")
        cls.base = pathlib.Path(cls.temp.name)
        cls.exe = cls.base / 'Indexer'
        (cls.base / 'main.swift').write_text((ROOT / 'Sources/Indexer.swift').read_text())
        subprocess.run(['swiftc', '-D', 'TESTING', '-module-cache-path', str(cls.base / 'cache'), str(ROOT / 'Sources/SharedSources.swift'), str(cls.base / 'main.swift'), '-o', str(cls.exe)], check=True)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp(dir=self.base))
        self.home = self.dir / 'home'; self.home.mkdir()
        self.share = self.dir / 'network'; self.share.mkdir()
        self.data = self.dir / 'data'
        (self.home / 'local.txt').write_text('a')
        (self.home / 'Library').mkdir(); (self.home / 'Library' / 'hidden.txt').write_text('x')
        (self.share / 'shared.txt').write_text('b')
    def run_index(self, mounts):
        env = os.environ.copy(); env.update(EVERYTHING_TEST_DATA=str(self.data), EVERYTHING_TEST_HOME=str(self.home), EVERYTHING_TEST_MOUNTS=json.dumps(mounts))
        subprocess.run([self.exe], env=env, check=True)
        return json.loads((self.data / 'index.json').read_text())
    def test_offline_preserves_and_reconnected_refreshes(self):
        identity = 'a' * 64
        first = self.run_index([[str(self.share), identity]])
        self.assertIn(str(self.home / 'local.txt'), first['paths'])
        self.assertNotIn(str(self.home / 'Library' / 'hidden.txt'), first['paths'])
        self.assertIn(str(self.share / 'shared.txt'), first['paths'])
        (self.share / 'shared.txt').unlink()
        offline = self.run_index([])
        self.assertIn(str(self.share / 'shared.txt'), offline['paths'])
        self.assertIn('未连接', (self.data / 'status.json').read_text())
        online = self.run_index([[str(self.share), identity]])
        self.assertNotIn(str(self.share / 'shared.txt'), online['paths'])
    def test_same_path_new_server_does_not_reuse_old_results(self):
        self.run_index([[str(self.share), 'a' * 64]])
        (self.share / 'shared.txt').unlink()
        changed = self.run_index([[str(self.share), 'b' * 64]])
        self.assertNotIn(str(self.share / 'shared.txt'), changed['paths'])
    def test_disabled_share_keeps_cache_but_skips_scan(self):
        mounts = [[str(self.share), 'one']]
        self.run_index(mounts)
        (self.data / 'shared-selection.json').write_text(json.dumps(['one']))
        (self.share / 'new.txt').write_text('new')
        disabled = self.run_index(mounts)
        self.assertIn(str(self.share / 'shared.txt'), disabled['paths'])
        self.assertNotIn(str(self.share / 'new.txt'), disabled['paths'])
        (self.data / 'shared-selection.json').write_text('[]')
        enabled = self.run_index(mounts)
        self.assertIn(str(self.share / 'new.txt'), enabled['paths'])
if __name__ == '__main__': unittest.main()
