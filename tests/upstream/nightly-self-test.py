#!/usr/bin/env python3
"""Ensure failed/incomplete native harnesses cannot become successful collections."""
import importlib.util
import json
import os
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

    def test_shard_argument_is_validated(self):
        for text in ('', '0/3', '4/3', '1/0', '1', 'a/3', '1/3/4'):
            with self.assertRaises(ValueError):
                native.parse_shard(text)
        self.assertEqual(native.parse_shard('2/3'), (2, 3))

    def test_libstdcxx_shards_partition_directories_and_drivers(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / 'testsuite'
            for name in ('libstdc++-dg/conformance.exp', 'libstdc++-abi/abi.exp',
                         'libstdc++-prettyprinters/prettyprinters.exp', 'libstdc++-xmethods/xmethods.exp'):
                (src / name).parent.mkdir(parents=True, exist_ok=True)
                (src / name).write_text('')
            for unit, count in (('20_util', 5), ('21_strings', 3), ('std', 2), ('experimental', 1),
                                ('abi', 1), ('90_extra', 4)):
                for i in range(count):
                    (src / unit / 'nested').mkdir(parents=True, exist_ok=True)
                    (src / unit / 'nested' / f'{i}.cc').write_text('')
            (src / '20_util' / 'notes.txt').write_text('')
            plans = [native.libstdcxx_plan(src, index, 3) for index in (1, 2, 3)]
            self.assertEqual([p['shard'] for p in plans], ['1/3', '2/3', '3/3'])
            selected = [unit for plan in plans for unit in plan['selected']]
            self.assertEqual(sorted(selected), plans[0]['all_units'])
            self.assertEqual(len(selected), len(set(selected)))
            self.assertEqual(plans[0]['args'][:3], ['abi.exp', 'prettyprinters.exp', 'xmethods.exp'])
            self.assertTrue(plans[1]['args'][0].startswith('conformance.exp='))
            for plan in plans[1:]:
                self.assertFalse(any(arg.endswith('.exp') and '=' not in arg for arg in plan['args']))
            root = os.path.abspath(src)
            for plan in plans:
                patterns = plan['args'][-1].split('=', 1)[1].split(' ')
                self.assertEqual(patterns, [f'{root}/{unit}/*' for unit in plan['selected']])
            with self.assertRaises(ValueError):
                native.libstdcxx_plan(src, 7, 7)

    def test_merge_requires_each_shard_once_and_disjoint_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for shard, names in ((1, ['a', 'b']), (2, ['c'])):
                out = root / f'libcxx-{shard}' / 'build' / 'nightly' / 'libcxx'
                (out / 'results').mkdir(parents=True)
                (out / 'results' / 'results.json').write_text(
                    json.dumps({'tests': [{'name': n, 'code': 'PASS'} for n in names]}))
                (out / 'summary.json').write_text(json.dumps(
                    {'suite': 'libcxx', 'shard': f'{shard}/2', 'native_exit': 0, 'outcomes': {'PASS': len(names)}}))
            paths = sorted(root.rglob('summary.json'))
            merged = native.merge_suite('libcxx', paths)
            self.assertEqual(merged['outcomes'], {'PASS': 3})
            self.assertEqual((merged['shards'], merged['native_exit']), (2, 0))
            with self.assertRaises(ValueError):
                native.merge_suite('libcxx', paths[:1])
            with self.assertRaises(ValueError):
                native.merge_suite('libcxx', [paths[0], paths[0]])
            (root / 'libcxx-2' / 'build' / 'nightly' / 'libcxx' / 'results' / 'results.json').write_text(
                json.dumps({'tests': [{'name': 'a', 'code': 'PASS'}]}))
            with self.assertRaises(ValueError):
                native.merge_suite('libcxx', paths)

    def test_merge_checks_dejagnu_directory_partition(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plans = ({'shard': '1/2', 'all_units': ['a', 'b'], 'selected': ['a']},
                     {'shard': '2/2', 'all_units': ['a', 'b'], 'selected': ['a']})
            for index, plan in enumerate(plans, 1):
                out = root / f'libstdcxx-{index}' / 'build' / 'nightly' / 'libstdcxx'
                (out / 'results').mkdir(parents=True)
                (out / 'results' / 'shard.json').write_text(json.dumps(plan))
                (out / 'summary.json').write_text(json.dumps(
                    {'suite': 'libstdcxx', 'shard': f'{index}/2', 'native_exit': 0, 'outcomes': {'PASS': 1}}))
            paths = sorted(root.rglob('summary.json'))
            with self.assertRaises(ValueError):
                native.merge_suite('libstdcxx', paths)
            plans[1]['selected'] = ['b']
            (root / 'libstdcxx-2' / 'build' / 'nightly' / 'libstdcxx' / 'results' / 'shard.json').write_text(
                json.dumps(plans[1]))
            self.assertEqual(native.merge_suite('libstdcxx', paths)['outcomes'], {'PASS': 2})


unittest.main()
