# Standalone native smoke configuration. Original RUN lines and -verify
# annotations are interpreted by the pinned LLVM lit, not translated to nfcxx.
import os
import shlex
import lit.formats

config.name = "pinned-clang-native-smoke"
config.test_format = lit.formats.ShTest(execute_external=False)
config.suffixes = [".cpp"]
config.test_source_root = os.path.dirname(__file__)
config.test_exec_root = os.path.join(config.test_source_root, "work")
config.substitutions.append(("%clang_cc1", shlex.quote(os.environ["SMOKE_CLANG"]) + " -cc1"))
