# Native Clang site configuration for the installed LLVM 21 toolchain.
# Source tests are pinned independently; failures may include distro/version
# differences. Feature booleans below describe this Linux package setup.
import os
import platform
import sys

src = os.environ["CLANG_SUITE_SOURCE"]
out = os.environ["CLANG_SUITE_OUTPUT"]
tools = os.environ.get("LLVM_TOOLS_DIR", "/usr/lib/llvm-21/bin")
config.llvm_src_root = os.path.join(src, "llvm")
config.llvm_obj_root = os.path.dirname(tools)
config.llvm_tools_dir = tools
config.llvm_libs_dir = os.path.join(os.path.dirname(tools), "lib")
config.llvm_shlib_dir = config.llvm_libs_dir
config.llvm_plugin_ext = ".so"
config.lit_tools_dir = ""
config.errc_messages = ""
config.clang_lit_site_cfg = __file__
config.clang_obj_root = out
config.clang_src_dir = os.path.join(src, "clang")
config.clang_tools_dir = tools
config.clang_lib_dir = config.llvm_libs_dir
config.host_triple = os.environ["CLANG_SUITE_TRIPLE"]
config.target_triple = config.host_triple
config.llvm_use_sanitizer = ""
config.have_zlib = True
config.have_zstd = True
config.clang_objc_rewriter = True
config.clang_default_pie_on_linux = True
config.clang_default_cxx_stdlib = "libstdc++"
config.clang_staticanalyzer = True
config.clang_staticanalyzer_z3 = False
config.clang_staticanalyzer_z3_mock = False
config.clang_enable_cir = False
config.clang_examples = False
config.enable_shared = True
config.enable_backtrace = True
config.enable_threads = True
config.build_shared_libs = False
config.link_llvm_dylib = True
config.link_clang_dylib = True
config.reverse_iteration = False
config.host_arch = platform.machine()
config.perl_executable = "/usr/bin/perl"
config.python_executable = sys.executable
config.has_plugins = True
config.clang_vendor_uti = ""
config.llvm_external_lit = ""
config.standalone_build = True
config.ppc_linux_default_ieeelongdouble = False
config.have_llvm_driver = False
config.spirv_tools_tests = False
config.has_key_instructions = False
config.substitutions.append(("%llvm-version-major", "21"))

import lit.llvm
lit.llvm.initialize(lit_config, config)
lit_config.load_config(config, os.path.join(src, "clang/test/lit.cfg.py"))
# Unit is a separate GoogleTest suite requiring uninstalled build-tree test
# executables. Keep that exclusion explicit; the compiler regression tree runs.
config.excludes.add("Unit")
