#!/usr/bin/env python3
"""Bounded fixture tests; no disk images or applications are launched."""
import importlib
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

common = importlib.import_module('dmg_common')
config = importlib.import_module('update-config').update_config()


class DmgTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / 'Dotist.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        self.info = dict(config, CFBundleIdentifier='com.dotist.app', CFBundleExecutable='dotist',
                         CFBundleShortVersionString='1.2.3', CFBundleVersion='1.2.3')
        self.write_info()
        (self.root / 'Applications').symlink_to('/Applications')

    def write_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    @staticmethod
    def fake_run(*args):
        class Result:
            stdout = b'arm64\n'
        return Result()

    def test_valid_bundle_and_layout(self):
        with patch.object(common, 'run', side_effect=self.fake_run):
            self.assertEqual(common.validate_app(self.app, '1.2.3'), '1.2.3')
            common.validate_layout(self.root, '1.2.3')

    def test_identity_version_and_configuration_rejected(self):
        for key, value in [('CFBundleIdentifier', 'qa'), ('CFBundleVersion', '1.2.4'),
                           ('SUPublicEDKey', 'wrong'), ('CFBundleShortVersionString', '1.2')]:
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = value
                self.write_info()
                with self.assertRaises(ValueError):
                    common.validate_app(self.app, '1.2.3')
                self.info[key] = original

    def test_wrong_architecture_and_signature_rejected(self):
        class Result:
            stdout = b'arm64 x86_64\n'
        with patch.object(common, 'run', return_value=Result()):
            with self.assertRaises(ValueError):
                common.validate_app(self.app)
        with patch.object(common, 'run', side_effect=RuntimeError('bad signature')):
            with self.assertRaises(RuntimeError):
                common.validate_app(self.app)

    def test_unexpected_layout_and_link_rejected(self):
        (self.root / 'extra').touch()
        with self.assertRaises(ValueError):
            common.validate_layout(self.root, '1.2.3')
        (self.root / 'extra').unlink()
        (self.root / 'Applications').unlink()
        (self.root / 'Applications').symlink_to('/tmp')
        with self.assertRaises(ValueError):
            common.validate_layout(self.root, '1.2.3')

    def test_checksum_changes_with_contents(self):
        path = self.root / 'image'
        path.write_bytes(b'first')
        first = common.checksum(path)
        path.write_bytes(b'second')
        self.assertNotEqual(first, common.checksum(path))


if __name__ == '__main__':
    unittest.main()
