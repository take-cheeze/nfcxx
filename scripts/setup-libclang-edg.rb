#!/usr/bin/env ruby
# libclang-edg: build a cpfe whose back end is be/nfcxx_decl.c (it lists the declarations of the primary file)
# instead of EDG's C++-generating back end. Same view-of-the-submodule approach as scripts/setup-pathb.sh: 3rd/edg
# is not modified; build/libclang-edg/tree links to it and replaces only the files below.
#   src/CMakeLists.txt                 nfcxx_decl.c added to CORE_FRONT_END_SOURCE_FILES; cp_gen_be.c's back_end renamed
#   cmake/macro-conf/nfcxx-libclang/   EDG's C++ back-end configuration (BACK_END_IS_CP_GEN_BE=1, no IL lowering).
#                                      That configuration keeps the source sequence lists (declarations in source
#                                      order, with their scopes) and the per-class member lists, which the back end
#                                      reads. EDG rejects those lists together with IL lowering.
#   src/nfcxx-so/                      the same front end and back end again, as position-independent code with
#                                      EDG_MAIN=nfcxx_edg_main (EDG's callable front end, basics.h) and the entry point
#                                      be/nfcxx_edg_entry.c: the archive libedgfe-pic.a that scripts/build-libclang-edg.sh
#                                      links into libclang-edg.so, which then runs the front end in-process.
# Result: build/libclang-edg/cmake/bin/cpfe (scripts/libclang-cursors runs it; lib/libclang-edg runs that when it is
# built without the archive) and build/libclang-edg/cmake/src/nfcxx-so/libedgfe-pic.a.
#   LIBCLANG_EDG_IN_PROCESS=0   build cpfe only
# Ruby port of setup-libclang-edg.sh: the external commands, their order and arguments are the same. The shell's
# `set -e` is kept: an external command that fails ends the script with its status.
require 'open3'

def which(cmd)
  return (File.file?(cmd) && File.executable?(cmd) ? cmd : nil) if cmd.include?('/')
  ENV.fetch('PATH', '').split(':', -1).each do |d|
    f = File.join(d.empty? ? '.' : d, cmd)
    return f if File.file?(f) && File.executable?(f)
  end
  nil
end

# Runs an external command and returns its exit status (127 when it cannot start, as the shell does).
def run(argv, env: {}, chdir: nil, out: nil, err: nil)
  opts = {}
  opts[:chdir] = chdir if chdir
  opts[:out] = out if out
  opts[:err] = err if err
  pid = Process.spawn(env, *argv, **opts)
  Process.wait(pid)
  $?.exitstatus || 1
rescue SystemCallError
  127
end

# set -e: a command that fails ends the script with its status
def must(argv, **opts)
  st = run(argv, **opts)
  exit st unless st == 0
end

root = File.expand_path(File.join(File.dirname($PROGRAM_NAME), '..'))
src = ENV['LIBCLANG_EDG_SRC'].to_s.empty? ? "#{root}/3rd/edg" : ENV['LIBCLANG_EDG_SRC']   # an EDG checkout elsewhere (worktrees with an empty 3rd/)
out = ENV['LIBCLANG_EDG_OUT'].to_s.empty? ? "#{root}/build/libclang-edg" : ENV['LIBCLANG_EDG_OUT']
tree = "#{out}/tree"

unless File.file?("#{src}/CMakeLists.txt")
  must(['git', '-C', root, 'submodule', 'update', '--init', '--depth', '1', '3rd/edg'])
end

must(['rm', '-rf', tree])
must(['mkdir', '-p', "#{tree}/src", "#{tree}/cmake/macro-conf/nfcxx-libclang"])   # keep $out/cmake: incremental rebuilds

# link_all FROM TO EXCLUDE...: a symlink in TO to each entry of FROM (its names of the shell's glob "*" and ".[!.]*"), but EXCLUDE
def link_all(from, to, *exclude)
  names = Dir.glob("#{from}/*").sort + Dir.glob("#{from}/.[!.]*").sort
  names.each do |e|
    next unless File.exist?(e)
    n = File.basename(e)
    next if exclude.include?(n)
    must(['ln', '-s', e, "#{to}/#{n}"])
  end
end
link_all(src, tree, 'src', 'cmake')
link_all("#{src}/src", "#{tree}/src", 'CMakeLists.txt')
link_all("#{src}/cmake", "#{tree}/cmake", 'macro-conf')
link_all("#{src}/cmake/macro-conf", "#{tree}/cmake/macro-conf", 'nfcxx-libclang')

# 1. Back end: nfcxx_decl.c joins the CORE list. cp_gen_be.c stays (the front end uses its helpers, such as
#    expr_has_comma_operation), but its back_end() is renamed in the tree copy, so the C++ generator never runs.
must(['sed', 's/ cp_gen_be\.c / cp_gen_be.c nfcxx_decl.c nfcxx_ast.c /', "#{src}/src/CMakeLists.txt"], out: "#{tree}/src/CMakeLists.txt")
unless File.read("#{tree}/src/CMakeLists.txt").match?(/ cp_gen_be.c nfcxx_decl.c nfcxx_ast.c /)
  $stderr.puts 'setup-libclang-edg: CORE list patch failed'
  exit 1
end
must(['cp', "#{root}/be/nfcxx_decl.c", "#{root}/be/nfcxx_ast.c", "#{root}/be/nfcxx_edg_entry.c", "#{tree}/src/"])
must(['rm', '-f', "#{tree}/src/cp_gen_be.c"])   # a symlink into the submodule: write a copy, never through the link
must(['sed', 's/^void back_end(void)/void nfcxx_cp_gen_back_end_unused(void)/', "#{src}/src/cp_gen_be.c"], out: "#{tree}/src/cp_gen_be.c")
unless File.read("#{tree}/src/cp_gen_be.c").include?('nfcxx_cp_gen_back_end_unused(void)')
  $stderr.puts 'setup-libclang-edg: cp_gen_be.c rename failed'
  exit 1
end
# folding.c calls mangled_typeinfo_string, which lower_name.h declares only with IL lowering on. The C++ configuration
# has lowering off, so the tree's folding.c gets the prototype (the function itself is still built from lower_name.c).
must(['rm', '-f', "#{tree}/src/folding.c"])   # a symlink into the submodule: write a copy, never through the link
PYTHON_FOLDING = <<'PY'
import sys
lines = open(sys.argv[1]).read().split('\n')
anchor = next(i for i, l in enumerate(lines) if 'Conditionally open the "edg" namespace' in l)
lines.insert(anchor, 'namespace edg { extern char *mangled_typeinfo_string(a_type *type); }  /* nfcxx: see setup-libclang-edg.sh */')
open(sys.argv[2], 'w').write('\n'.join(lines))
PY
stdout, stderr, st = Open3.capture3('python3', '-', "#{src}/src/folding.c", "#{tree}/src/folding.c", stdin_data: PYTHON_FOLDING)
$stdout.write(stdout)
$stderr.write(stderr)
exit st.exitstatus || 1 unless st.success?

# The in-process library: the CORE list (with nfcxx_decl.c) and the entry point, under cpfe's macro configuration.
# Hidden visibility keeps EDG's symbols inside libclang-edg.so; nfcxx_edg_run is the one it exports.
must(['mkdir', '-p', "#{tree}/src/nfcxx-so"])
File.write("#{tree}/src/nfcxx-so/CMakeLists.txt", <<'CM')
# libclang-edg (scripts/setup-libclang-edg.sh): the front end as an archive of position-independent objects.
set(NFCXX_SO_FILES ${CORE_FRONT_END_SOURCE_FILES} ${PROJECT_SOURCE_DIR}/nfcxx_edg_entry.c)
macro_configuration_to_compile_definitions("cpfe")
add_compile_definitions(EDG_MAIN=nfcxx_edg_main)
set_source_files_properties(${NFCXX_SO_FILES} PROPERTIES LANGUAGE CXX)
add_library(edgfe-pic STATIC ${NFCXX_SO_FILES})
add_dependencies(edgfe-pic error-info)
set_target_properties(edgfe-pic PROPERTIES POSITION_INDEPENDENT_CODE ON CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})
add_softfloat_to_target(edgfe-pic)
CM
File.write("#{tree}/src/CMakeLists.txt", "\nadd_subdirectory(nfcxx-so)  # nfcxx: scripts/setup-libclang-edg.sh\n", mode: 'a')

# 2. Macro config: EDG's C++ back-end configuration (default/cpfe-cp), with the Linux and release options.
File.write("#{tree}/cmake/macro-conf/nfcxx-libclang/base.cmakedef", <<'CFG')
import <linux-gcc-release/base>
CFG
File.write("#{tree}/cmake/macro-conf/nfcxx-libclang/cpfe.cmakedef", <<'CFG')
# libclang-edg: the C++-generating back end's configuration; nfcxx_decl.c defines back_end() in its place.
import <linux-gcc-release/cpfe-cp>
# The per-class list of member declarations in source order (class_type_supp(t)->member_declarations). Off by
# default in host_envir.h; nfcxx_decl.c reads it.
MAINTAIN_CLASS_MEMBER_LIST=1
# No IL lowering: the source sequence lists conflict with it (host_envir.h). The Itanium C++ ABI is what Linux
# sets in support/platform/linux/base; folding.c needs its mangled_typeinfo_string, declared only with IA64_ABI.
DO_IL_LOWERING=0
IA64_ABI=1
CFG
File.write("#{tree}/cmake/macro-conf/nfcxx-libclang/cpfe-cp.cmakedef", <<'CFG')
import <linux-gcc-release/cpfe-cp>
CFG
File.write("#{tree}/cmake/macro-conf/nfcxx-libclang/cdisp.cmakedef", <<'CFG')
import <linux-gcc-release/cdisp>
CFG

# 3. Base dir (predefined macros, EDG's own headers), as setup-pathb.sh does.
base = "#{out}/edg-base"
must(['rm', '-rf', base])
must(['cp', '-r', "#{src}/bases/docker/dev-env/gcc", base])
must(['rm', '-rf', "#{base}/include"])
must(['ln', '-s', "#{src}/include_c++", "#{base}/include"])

cd_or_exit = lambda do |dir|   # cd: a directory that does not exist ends the script, as set -e does
  Dir.chdir(dir)
rescue SystemCallError
  $stderr.puts "#{$PROGRAM_NAME}: cd: #{dir}: No such file or directory"
  exit 1
end
cd_or_exit.call(tree)
configured = run(['cmake', '-G', 'Ninja', '-S', tree, '-B', "#{out}/cmake", '-DCMAKE_BUILD_TYPE=Release',
                  '-DEDG_MACRO_CONF=nfcxx-libclang', '-DCMAKE_C_COMPILER=gcc', '-DCMAKE_CXX_COMPILER=g++'],
                 env: { 'EDG_BASE' => base }, out: ["#{out}/configure.log", 'w'], err: [:child, :out])
unless configured == 0
  run(['tail', '-30', "#{out}/configure.log"], out: $stderr)
  exit 1
end
cd_or_exit.call("#{out}/cmake")
targets = ['bin/cpfe']
targets << 'edgfe-pic' unless ENV['LIBCLANG_EDG_IN_PROCESS'] == '0'
jobs = ENV['LIBCLANG_EDG_JOBS'].to_s.empty? ? [] : ["-j#{ENV['LIBCLANG_EDG_JOBS']}"]
built = run(['ninja', *jobs, *targets], out: ["#{out}/build.log", 'w'], err: [:child, :out])
unless built == 0
  run(['grep', '-m20', '-B2', '-A8', 'error', "#{out}/build.log"], out: $stderr)
  exit 1
end
puts "libclang-edg cpfe built: #{out}/cmake/bin/cpfe (base dir: #{base})"
puts "libclang-edg front-end archive built: #{out}/cmake/src/nfcxx-so/libedgfe-pic.a" unless ENV['LIBCLANG_EDG_IN_PROCESS'] == '0'
