#!/usr/bin/env python3
"""Ensure failed/incomplete native harnesses cannot become successful collections."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('nightly_native', Path(__file__).with_name('nightly-native.py'))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativeCollection(unittest.TestCase):
    def test_lit_failures_are_explicit_observations(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'results.json').write_text(json.dumps({'tests': [{'name': 'a', 'code': 'FAIL'}]}))
            self.assertEqual(native.outcomes('clang', root, 1), {'FAIL': 1})
            with self.assertRaises(ValueError):
                native.outcomes('clang', root, 2)

    def test_empty_duplicate_or_unexplained_failure_is_broken(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for tests, rc in (([], 0), ([{'name': 'a', 'code': 'PASS'}] * 2, 0),
                              ([{'name': 'a', 'code': 'PASS'}], 1)):
                (root / 'results.json').write_text(json.dumps({'tests': tests}))
                with self.assertRaises(ValueError):
                    native.outcomes('clang', root, rc)

    def test_dejagnu_requires_completed_workers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'combined.sum').write_text('PASS: a\nFAIL: b\n')
            with self.assertRaises(ValueError):
                native.outcomes('gcc', root, 1)
            worker = root / 'worker-1'
            worker.mkdir()
            (worker / 'harness.exit').write_text('0\n')
            self.assertEqual(native.outcomes('gcc', root, 1), {'FAIL': 1, 'PASS': 1})
            (root / 'combined.sum').write_text('ERROR: cannot find compiler\n')
            with self.assertRaises(ValueError):
                native.outcomes('gcc', root, 1)


unittest.main()
