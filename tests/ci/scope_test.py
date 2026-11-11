#!/usr/bin/env python3
"""Coverage selection and required-check policy, including real git diffs."""

import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/ci-scope.py"
spec = importlib.util.spec_from_file_location("ci_scope", SCRIPT)
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class SelectionTests(unittest.TestCase):
    def test_isolated_prs(self):
        for paths in (["bc2cpp/tools/bc2cpp/bc2cpp.rb"],
                      ["tests/bc2cpp/fetch.sh"], ["docs/notes/test.md"],
                      ["bc2cpp/new.rb", "docs/new.md", "tests/bc2cpp/new.sh"]):
            with self.subTest(paths=paths):
                self.assertEqual(scope.select("pull_request", paths),
                                 {"full_ci": "false", "changed": "false"})

    def test_unlisted_and_mixed_paths_keep_general_coverage(self):
        for path in ("be/new.cpp", ".github/workflows/ci.yml", "scripts/ci-scope.py",
                     "tests/ci/scope_test.py", "Gemfile", "unknown", "bc2cpp-other/a",
                     "docs/tool.py", "docs/notes/source.patch"):
            with self.subTest(path=path):
                self.assertEqual(scope.select("pull_request", ["bc2cpp/a.rb", path])["full_ci"], "true")

    def test_pathb_dependencies_keep_both_matrices(self):
        for path in ("scripts/pathb-qbe-emit.rb", "scripts/new-helper", "be/a.cpp",
                     "3rd/edg", "3rd/qbe", "3rd/cproc", "nfcxx", "nfcc/driver.c",
                     "lib/new.c", "tests/run.sh", "tests/pathb-ir/a.ir",
                     "tests/cases/a.cpp", "tests/mruby/a.sh", ".github/actions/toolchain/action.yml",
                     "tools/qbe-prep/main.cpp", ".github/workflows/ci.yml"):
            with self.subTest(path=path):
                self.assertEqual(scope.select("pull_request", [path]),
                                 {"full_ci": "true", "changed": "true"})

    def test_push_manual_unknown_events_and_empty_diffs_keep_general_coverage(self):
        for event in ("push", "workflow_dispatch", "merge_group", ""):
            with self.subTest(event=event):
                self.assertEqual(scope.select(event, ["docs/a.md"])["full_ci"], "true")
        self.assertEqual(scope.select("pull_request", []),
                         {"full_ci": "true", "changed": "true"})


def outcomes(full, pathb):
    needs = {"pathb-changes": {"result": "success", "outputs": {
        "full_ci": str(full).lower(), "changed": str(pathb).lower()}}}
    for names, enabled in ((scope.FULL_JOBS, full), (scope.PATHB_JOBS, pathb)):
        needs.update({name: {"result": "success" if enabled else "skipped"} for name in names})
    return needs


class GateTests(unittest.TestCase):
    def test_workflow_gate_command(self):
        import json
        env = dict(os.environ, NEEDS_JSON=json.dumps(outcomes(False, False)))
        result = subprocess.run([sys.executable, str(SCRIPT), "--gate"], env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        needs = outcomes(True, True)
        needs["test"]["result"] = "cancelled"
        env["NEEDS_JSON"] = json.dumps(needs)
        result = subprocess.run([sys.executable, str(SCRIPT), "--gate"], env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("test: expected success, got cancelled", result.stderr)

    def test_valid_full_selective_and_isolated_runs(self):
        for full, pathb in ((True, True), (True, False), (False, False)):
            with self.subTest(full=full, pathb=pathb):
                scope.validate(outcomes(full, pathb))

    def test_failed_cancelled_skipped_or_missing_selected_jobs_block(self):
        for full, pathb in ((True, True), (True, False), (False, False)):
            original = outcomes(full, pathb)
            for name in original:
                for status in ("failure", "cancelled", "skipped", "success", None):
                    if status == original[name]["result"]:
                        continue
                    with self.subTest(full=full, pathb=pathb, job=name, status=status):
                        needs = copy.deepcopy(original)
                        needs[name]["result"] = status
                        with self.assertRaises(ValueError):
                            scope.validate(needs)
                needs = copy.deepcopy(original)
                del needs[name]
                with self.assertRaises(ValueError):
                    scope.validate(needs)

    def test_invalid_or_inconsistent_selection_blocks(self):
        for key in ("full_ci", "changed"):
            for value in ("", "unknown", None, True):
                needs = outcomes(True, True)
                needs["pathb-changes"]["outputs"][key] = value
                with self.assertRaises(ValueError):
                    scope.validate(needs)
        with self.assertRaises(ValueError):
            scope.validate(outcomes(False, True))


class GitDiffTests(unittest.TestCase):
    def test_rename_includes_original_path_and_preserves_unusual_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(
                    ["git", "-c", "user.name=CI", "-c", "user.email=ci@example.invalid",
                     "-c", "commit.gpgsign=false", *args], cwd=root, stderr=subprocess.DEVNULL,
                ).decode().strip()

            git("init")
            (root / "be").mkdir()
            (root / "be/original.cpp").write_text("compiler code\n")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            (root / "docs").mkdir()
            (root / "be/original.cpp").rename(root / "docs/new\nname.md")
            git("add", "-A")
            git("commit", "-qm", "rename")
            previous = Path.cwd()
            try:
                os.chdir(root)
                paths = scope.changed_paths(base)
                self.assertCountEqual(paths, ["be/original.cpp", "docs/new\nname.md"])
                self.assertEqual(scope.select("pull_request", paths)["full_ci"], "true")
                env = dict(os.environ, BASE=base, GITHUB_EVENT_NAME="pull_request",
                           GITHUB_OUTPUT=str(root / "outputs"))
                result = subprocess.run([sys.executable, str(SCRIPT)], env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((root / "outputs").read_text(), "full_ci=true\nchanged=true\n")
                with self.assertRaises(subprocess.CalledProcessError):
                    scope.changed_paths("missing-base")
            finally:
                os.chdir(previous)


if __name__ == "__main__":
    unittest.main()
