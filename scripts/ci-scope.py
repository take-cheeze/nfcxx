#!/usr/bin/env python3
"""Select CI coverage and validate the required aggregate check."""

import json
import os
import re
import subprocess
import sys


# These trees have their own bc2cpp workflow or contain documentation only.
# Every unlisted path keeps the general compiler suites enabled.
ISOLATED_PREFIXES = ("bc2cpp/", "tests/bc2cpp/")

# The existing Path B workflow selection, including all scripts and runtime code.
PATHB = re.compile(
    r"^(be/|3rd/(edg|qbe|cproc)$|scripts/|nfcc/|lib/|tests/run\.sh$|"
    r"tests/realworld/|\.github/actions/|"
    r"tests/(pathb/|pathb-|wasm/|sycl/|mruby/|cases/|cpp-features/|ehshim/|safeptr/)|"
    r"tools/(pathb-spirv-emit|qbe-prep)/|nfcxx$|\.github/workflows/ci\.yml$)"
)
FULL_JOBS = ("build", "test", "arm-build", "arm-test", "macos-suites", "mrustc")
PATHB_JOBS = ("pathb-build", "pathb-test")


def select(event, paths):
    full = event != "pull_request" or not paths or any(
        not (path.startswith(ISOLATED_PREFIXES) or
             (path.startswith("docs/") and path.endswith(".md"))) for path in paths
    )
    return {"full_ci": str(full).lower(),
            "changed": str(not paths or any(PATHB.search(path) for path in paths)).lower()}


def changed_paths(base):
    # Report both sides of renames: moving compiler code into docs is still a
    # compiler change. NUL separation preserves spaces and newlines in names.
    result = subprocess.run(
        ["git", "diff", "--no-renames", "--name-only", "-z", base, "HEAD"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return result.stdout.decode("utf-8", errors="surrogateescape").split("\0")[:-1]


def validate(needs):
    selection = needs.get("pathb-changes", {})
    if selection.get("result") != "success":
        raise ValueError("CI selection did not succeed")
    outputs = selection.get("outputs", {})
    full, pathb = outputs.get("full_ci"), outputs.get("changed")
    if full not in ("true", "false") or pathb not in ("true", "false"):
        raise ValueError("CI selection outputs are missing or invalid")
    if full == "false" and pathb == "true":
        raise ValueError("Path B coverage cannot run without general compiler coverage")
    for names, enabled in ((FULL_JOBS, full), (PATHB_JOBS, pathb)):
        expected = "success" if enabled == "true" else "skipped"
        for name in names:
            actual = needs.get(name, {}).get("result")
            if actual != expected:
                raise ValueError(f"{name}: expected {expected}, got {actual}")


def main():
    if sys.argv[1:] == ["--gate"]:
        validate(json.loads(os.environ["NEEDS_JSON"]))
        print("Every selected CI job passed; unselected jobs were skipped")
    elif not sys.argv[1:]:
        base = os.environ.get("BASE", "")
        paths = changed_paths(base) if base and set(base) != {"0"} else []
        outputs = select(os.environ.get("GITHUB_EVENT_NAME", ""), paths)
        text = "".join(f"{key}={value}\n" for key, value in outputs.items())
        print(text, end="")
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(text)
    else:
        raise ValueError("usage: ci-scope.py [--gate]")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.stderr.decode(errors="replace").strip() if error.stderr else str(error))
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
