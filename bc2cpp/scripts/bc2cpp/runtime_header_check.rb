#!/usr/bin/env ruby
# frozen_string_literal: true

# RUNTIME_HEADER (tools/bc2cpp/runtime_header.rb): the fixed runtime prelude goes to one header every compiled gem
# includes.
#
#   text (no tools)
#     - with no directory the marks are dropped and the text is otherwise unchanged;
#     - a stateless helper moves to the header, `inline`, in the digest-named namespace; an #include stays at file
#       scope;
#     - a `static` mutable variable or function-local (a `decltype(e) name` one too), every item that names one
#       (through a macro too) and the declaration paired with such a definition stay in the unit's text, at their
#       place between header parts;
#     - the same region gives the same header path; a different one a different path and namespace;
#   linkage (needs g++)
#     - two gems that include the header link warning-free, share one copy of each shared helper, and keep one
#       instance of a per-unit state each.
#   cross-gem share (CROSS_GEM_SHARE, tools/bc2cpp/cross_gem_share.rb; nm too)
#     - a stateless tail helper, its declaration, a constant table and a type move to a digest-named header; a
#       state, a function naming one (through a default argument or a continued macro too), an address-taken
#       function, a C++ `extern` declaration and a method declaration stay; an `extern "C"` prototype, its caller
#       and a program-wide site (BC2CPP_OWNERS_PW) move; an #if region's names come back under their own branch
#       (a header naming them reaches them through a using-directive);
#     - a helper calling the unit's own compiled method (METHOD_PROTOTYPE) or comparing a weak `extern "C"`
#       function's address moves; one in a gem that only declares the method stays;
#     - two sharded gems printing the same tail link, run, and nm finds each moved helper defined once, in no gem
#       namespace, while each gem keeps its own state and both advance the one program-wide site;
#       BC2CPP_CROSS_GEM_SHARE=0 leaves the tail as printed.
#
#   program-wide class slots (PROGRAM_CLASS_SLOTS, tools/bc2cpp/program_class_slots.rb; nm too)
#     - two gems asking for owners in different orders number each alike, by its rank in the sorted universe; an
#       owner outside it takes a slot of the gem's own after it; both include one header with the one table, a
#       different lookup gets a different one; the two compile and define the same mergeable table symbol;
#       BC2CPP_PROGRAM_CLASS_SLOTS=0, or no runtime header directory, keeps the gem's table 0...n.
#
#   isolation (--isolation BUILD_DIR; a real build, needs a C++ compiler)
#     - each compiled gem's main file, with every gem-namespace item after the runtime region dropped, still
#       compiles: no cross-gem header names a gem's own item (which ShardOutput's using-directive would hide).
#       BC2CPP_ISOLATION_FLAGS holds the build's other -I/-D flags. Every gem includes the same program class table.
#
# Usage: ruby scripts/bc2cpp/runtime_header_check.rb [--isolation BUILD_DIR]

require 'open3'
require 'tmpdir'
require_relative 'check_support'
require_relative 'cxx'
require_relative '../../tools/bc2cpp/runtime_header'
require_relative '../../tools/bc2cpp/cross_gem_share'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('runtime_header_check')

# The main file up to SHARD_DECLS with the gem-namespace items after the runtime region dropped; directives,
# includes and using-declarations stay.
def isolation_skeleton(text)
  lines = "#define BC2CPP_SHARD_PRELUDE_ONLY 1\n#{text[0...text.index('// SHARD_DECLS')]}".lines
  last_rt = lines.rindex { |l| l.start_with?('#undef BC2CPP_RUNTIME_PART') } || 0
  out = String.new
  inside = false
  depth = 0
  cont = false
  lines.each_with_index do |l, i|
    directive = cont || l.match?(/\A\s*#/)
    cont = directive && l.rstrip.end_with?('\\')
    if i <= last_rt || directive
      out << l
    elsif !inside && l.match?(/\Anamespace bc2cpp_shard_\w+ \{\s*\z/)
      inside = true
      out << l
    elsif inside && depth.zero? && l.match?(%r{\A\} // namespace bc2cpp_shard_})
      inside = false
      out << l
    elsif inside
      out << l if depth.zero? && l.match?(/\Ausing (?:namespace bc2cpp_rt_\h+|bc2cpp_(?:cs|rt)_\h+::\w+);\s*\z/)
      code = l.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\/\/.*/, '')
      depth += code.count('{') - code.count('}')
    else
      out << l
    end
  end
  out
end

if (at = ARGV.index('--isolation'))
  build = File.expand_path(ARGV.fetch(at + 1))
  mains = Dir["#{build}/**/mrbgems/*/*_compiled_gen.cpp"].sort
  suite.check("#{mains.size} compiled gem main files under #{build}", !mains.empty?)
  flags = ['-std=c++17', '-fsyntax-only', *ENV.fetch('BC2CPP_ISOLATION_FLAGS', '').split]
  Dir.mktmpdir('bc2cpp-isolation') do |dir|
    mains.each do |main|
      text = File.read(main)
      next unless text.include?('// SHARD_DECLS') && text.include?('bc2cpp_cs_')

      skeleton = File.join(dir, File.basename(main))
      File.write(skeleton, isolation_skeleton(text))
      # The gem's own build's include directory: its presym table.
      target = main[%r{\A(.*)/mrbgems/}, 1]
      _out, err, status = Bc2cppCxx.capture3("-I#{target}/include", *flags, "-I#{File.dirname(main)}", skeleton)
      suite.check("#{File.basename(main)}: the cross-gem headers compile without the gem's own items", status.success?)
      puts err.lines.grep(/error/).first(10).join unless status.success?
    end
  end
  # PROGRAM_CLASS_SLOTS: the gems of a build agree on the universe, so they include one program class table.
  tables = mains.map { |main| File.read(main).scan(/bc2cpp_pw_classes_\h{16}\.hxx/).uniq }
  suite.check("the compiled gems include one program class table (#{tables.flatten.uniq.join(', ')})",
              tables.flatten.uniq.size <= 1 && (tables.flatten.empty? || tables.all? { |t| t.size == 1 }))
  suite.finish!
  exit
end

REGION = <<~'CPP'
  #include <stdio.h>
  static inline int twice(int x) { return 2 * x; }
  static int counter = 0;
  static int bump() { return ++counter; }
  #define BUMP_TWICE() (bump() + bump())
  [[maybe_unused]] static int via_macro() { return BUMP_TWICE(); }
  [[maybe_unused]] static int cached_name();
  [[maybe_unused]] static int cached_name() {
    static int calls = 0;
    return ++calls;
  }
  static const int TABLE[] = { 1, 2, 3 };
  struct Pair { int a; int b; };
  #ifdef RUNTIME_CHECK_NEVER
  #include <never_included.h>
  #endif
  static int third(const Pair& p) { return twice(p.a) + TABLE[2] + p.b; }
  extern "C" inline int shared_slot() {
    static int slot = 0;
    return ++slot;
  }
  inline const void* twice_address() { return reinterpret_cast<const void*>(&twice); }
  static decltype(&twice) twice_hook = nullptr;
  [[maybe_unused]] static int via_hook(int x) { return twice_hook ? twice_hook(x) : x; }
CPP

def marked(region)
  "// head\n#{RuntimeHeader::BEGIN_MARK}#{region}#{RuntimeHeader::END_MARK}// tail\n"
end

puts '-- text'
suite.check('without a directory only the marks go', RuntimeHeader.rewrite(marked(REGION), nil) == "// head\n#{REGION}// tail\n")

Dir.mktmpdir('bc2cpp-runtime-header') do |dir|
  local = RuntimeHeader.rewrite(marked(REGION), dir)
  headers = Dir[File.join(dir, '*.hxx')]
  header = headers.size == 1 ? File.read(headers.first) : ''
  ns = header[/namespace (bc2cpp_rt_\h{16}) \{\}/, 1].to_s
  suite.check('one header, in a digest-named namespace', headers.size == 1 && !ns.empty?)
  suite.check('a stateless helper moves to the header, inline',
              header.include?('inline int twice(int x)') && !local.include?('twice(int x)'))
  suite.check('a constant table and a type move too', header.include?('inline const int TABLE[]') && header.include?('struct Pair'))
  suite.check('a helper calling only shared helpers moves', header.include?('inline int third(const Pair& p)'))
  suite.check('an extern "C" inline function (already one per link) moves unchanged',
              header.include?('extern "C" inline int shared_slot()'))
  suite.check('#include stays at file scope in the header',
              header.match?(/^\} \/\/ namespace #{ns}\n#include <stdio.h>|^#include <stdio.h>/) &&
              header.include?("#ifdef RUNTIME_CHECK_NEVER\n#include <never_included.h>\n#endif\n"))
  suite.check('a static mutable variable and its callers stay in the unit',
              local.include?('static int counter = 0;') && local.include?('static int bump()') && !header.include?('counter'))
  suite.check('a function naming state through a macro stays', local.include?('static int via_macro()'))
  suite.check('a `decltype(e) name` variable is state, and so is its reader',
              local.include?('static decltype(&twice) twice_hook') && local.include?('static int via_hook(int x)') && !header.include?('twice_hook'))
  suite.check('a function with a mutable static local stays, with its declaration',
              local.include?("[[maybe_unused]] static int cached_name();\n[[maybe_unused]] static int cached_name() {") && !header.include?('cached_name'))
  suite.check('the unit includes each part where its run stood, and uses the namespace once',
              local.scan(/#define BC2CPP_RUNTIME_PART \d+\n#include "#{Regexp.escape(headers.first.to_s)}"\n#undef BC2CPP_RUNTIME_PART\n/).size >= 2 &&
              local.scan("using namespace #{ns};").size == 1 && local.start_with?('// head') && local.end_with?("// tail\n"))
  again = RuntimeHeader.rewrite(marked(REGION), dir)
  suite.check('the same region gives the same header and text', again == local && Dir[File.join(dir, '*.hxx')].size == 1)
  RuntimeHeader.rewrite(marked(REGION.sub('2 * x', '3 * x')), dir)
  other = Dir[File.join(dir, '*.hxx')] - headers
  suite.check('a different region gives another header and namespace',
              other.size == 1 && File.read(other.first)[/namespace (bc2cpp_rt_\h{16}) \{\}/, 1] != ns)

  puts '-- linkage'
  if Bc2cppCxx.executable?(Bc2cppCxx.compiler.first)
    %w[a b].each do |gem|
      File.write(File.join(dir, "#{gem}.cpp"), <<~CPP)
        #{local}
        const void* #{gem}_twice() { return twice_address(); }
        int #{gem}_bump() { return bump(); }
        int #{gem}_third() { Pair p{1, 2}; return third(p); }
        int #{gem}_slot() { return shared_slot(); }
      CPP
    end
    File.write(File.join(dir, 'main.cpp'), <<~'CPP')
      #include <cstdio>
      const void* a_twice(); const void* b_twice();
      int a_bump(); int b_bump(); int a_third(); int b_third(); int a_slot(); int b_slot();
      int main() {
        a_bump(); a_bump();
        int b = b_bump();
        a_slot();
        std::printf("%d %d %d %d\n", a_twice() == b_twice(), b, a_third() + b_third(), b_slot());
        return 0;
      }
    CPP
    binary = File.join(dir, 'rt')
    sources = %w[a.cpp b.cpp main.cpp].map { |f| File.join(dir, f) }
    _out, err, status = Bc2cppCxx.capture3('-std=c++17', '-O2', '-Wall', '-Werror', *sources, '-o', binary)
    suite.check('two gems including the header compile warning-free and link', status.success?)
    puts err.lines.first(20).join unless status.success?
    if status.success?
      out, = Open3.capture2(binary)
      # One twice() for both gems; gem b's counter is its own (1); third = 2 + 3 + 2 per gem; one shared slot.
      suite.check("a shared helper is one definition, per-unit state stays per unit (#{out.strip})", out == "1 1 14 2\n")
    end
  else
    puts '  SKIP: no C++ compiler'
  end
end

# OVERLOAD_MERGE: in a sharded gem the unit's prelude moves into the gem namespace, where a unit function of the
# header function's name would hide it.
puts '-- overloads in a sharded gem'
OVERLOAD_REGION = <<~'CPP'
  static inline int put(int a, int b) { return a + b; }
CPP
OVERLOAD_REST = <<~'CPP'
  [[maybe_unused]] static int put(const char* s, int b) { return s[0] + b; }
  static int use_put() { return put(1, 2) * 1000 + put("x", 3); }
CPP
if Bc2cppCxx.executable?(Bc2cppCxx.compiler.first)
  Dir.mktmpdir('bc2cpp-runtime-overload') do |dir|
    text = RuntimeHeader.rewrite(RuntimeHeader::BEGIN_MARK + OVERLOAD_REGION + RuntimeHeader::END_MARK + OVERLOAD_REST +
                                 ShardOutput.unit_mark('A') + "int A_impl() { return use_put(); }\n" +
                                 ShardOutput.unit_mark('B') + "int B_impl() { return use_put() + 1; }\n" +
                                 ShardOutput::HOOKS_MARK + "int run_all() { return A_impl() + B_impl(); }\n", dir)
    suite.check('a unit overload of a header function gets its using-declaration', text.match?(/^using bc2cpp_rt_\h+::put;$/))
    ENV['BC2CPP_SHARD_MIN_BYTES'] = '1'
    main, shards = ShardOutput.split(text, 'ovl', 2)
    ENV.delete('BC2CPP_SHARD_MIN_BYTES')
    File.write(File.join(dir, 'ovl_gen.cpp'), main)
    shards.each_with_index { |t, i| File.write(ShardOutput.shard_path(dir, 'ovl', i + 1), t) }
    File.write(File.join(dir, 'main.cpp'), "#include <cstdio>\nint run_all();\nint main() { std::printf(\"%d\\n\", run_all()); }\n")
    sources = [File.join(dir, 'ovl_gen.cpp'), *shards.each_index.map { |i| ShardOutput.shard_path(dir, 'ovl', i + 1) },
               File.join(dir, 'main.cpp')]
    _out, err, status = Bc2cppCxx.capture3('-std=c++17', '-O2', '-Wall', '-Werror', *sources, '-o', File.join(dir, 'ovl'))
    suite.check('the sharded gem compiles with both overloads in reach', status.success? && main.include?('namespace bc2cpp_shard_ovl {'))
    puts err.lines.first(20).join unless status.success?
    if status.success?
      out, = Open3.capture2(File.join(dir, 'ovl'))
      # use_put = 3 * 1000 + ('x' + 3) = 3123; A + B = 3123 + 3124.
      suite.check("each call reaches its overload (#{out.strip})", out == "6247\n")
    end
  end
else
  puts '  SKIP: no C++ compiler'
end

puts '-- cross-gem share'
CGS_TAIL = <<~'CPP'
  static int counter = 0;
  static int bump() { return ++counter; }
  static int helper(int a);
  static int helper(int a) { return twice(a) + 1; }
  static const int CGS_TABLE[] = { 1, 2, 3 };
  struct CgsPair { int a; int b; };
  static int third(const CgsPair& p) { return helper(p.a) + CGS_TABLE[2] + p.b; }
  static int via_bump() { return bump(); }
  static int target(int x) { return x + 7; }
  static int (*const target_ptr)(int) = &target;
  static int dflt() { return 1; }
  static int with_default(int a, int b = dflt()) { return bump() + a + b; }
  static int calls_default() { return with_default(1); }
  #define CGS_SITE(x) \
    ([]() -> int { static int n = 0; return ++n + (x); }())
  static int site_user() { return CGS_SITE(1); }
  static int bump_$3f() { return bump(); }
  static int uses_q() { return bump_$3f(); }
  extern "C" int cgs_c_abs(int);
  static int via_c(int x) { return cgs_c_abs(x); }
  extern int cgs_cxx_ext(int);
  #define BC2CPP_OWNERS_PW(x) \
    ([]() -> int { static int n = 0; return ++n + (x); }())
  static int program_site() { return BC2CPP_OWNERS_PW(1); }
  #ifdef CGS_NEVER
  static int never_helper() { return 1; }
  #else
  static int other_helper() { return 2; }
  #endif
  static int uses_branch() {
  #ifdef CGS_NEVER
    return never_helper();
  #else
    return other_helper();
  #endif
  }
  int GEM_method(int x);
CPP
def cgs_gem(gem, dir)
  tail = CGS_TAIL.gsub('GEM', gem)
  text = "#{RuntimeHeader::BEGIN_MARK}static inline int twice(int x) { return 2 * x; }\n#{RuntimeHeader::END_MARK}#{tail}" \
         "#{ShardOutput.unit_mark('A')}int #{gem}_method(int x) { CgsPair p{x, 2}; return third(p) + via_bump() + target_ptr(1) + calls_default() + site_user() + via_c(-3) + program_site() + uses_branch(); }\n" \
         "#{ShardOutput.unit_mark('B')}int #{gem}_b(int x) { return helper(x) + #{gem}_method(x); }\n#{ShardOutput::HOOKS_MARK}"
  CrossGemShare.rewrite(RuntimeHeader.rewrite(text, dir, tail_mark: true), dir)
end
Dir.mktmpdir('bc2cpp-cross-gem') do |dir|
  a = cgs_gem('ga', dir)
  b = cgs_gem('gb', dir)
  headers = Dir[File.join(dir, 'bc2cpp_cs_*.hxx')]
  moved = headers.map { |h| File.read(h) }.join
  suite.check('both gems print the same tail: one set of headers, both include it',
              !headers.empty? && headers.all? { |h| a.include?(h) && b.include?(h) })
  suite.check('a stateless helper, its declaration, a constant table and a type move',
              moved.include?('int helper(int a);') && moved.include?('int helper(int a) {') &&
              moved.include?('inline const int CGS_TABLE[]') && moved.include?('struct CgsPair') && !a.include?('int helper(int a)'))
  suite.check('state, its callers, an address-taken function and a method declaration stay',
              a.include?('static int counter = 0;') && a.include?('static int via_bump()') &&
              a.include?('static int target(int x)') && a.include?('int ga_method(int x);') && !moved.include?('counter'))
  suite.check('a caller of a function whose default argument is a call stays with it',
              a.include?('static int with_default(int a, int b = dflt())') && a.include?('static int calls_default()'))
  suite.check('a function using a macro whose continued body holds a static stays', a.include?('static int site_user()'))
  suite.check('a caller of a `$`-spelled local stays', a.include?('static int uses_q()'))
  suite.check('the unit names a moved item through a using-declaration', a.match?(/^using bc2cpp_cs_\h{16}::helper;$/))
  suite.check('an extern "C" prototype and its caller move; a C++ extern declaration stays',
              moved.include?('extern "C" int cgs_c_abs(int);') && moved.include?('int via_c(int x)') &&
              a.include?('extern int cgs_cxx_ext(int);') && !moved.include?('cgs_cxx_ext'))
  suite.check('a program-wide site (BC2CPP_OWNERS_PW) moves with its helper', moved.include?('int program_site()'))
  suite.check('an #if region brings each name back under its own branch',
              a.match?(/^#ifdef CGS_NEVER\nusing bc2cpp_cs_\h{16}::never_helper;\n#else\nusing bc2cpp_cs_\h{16}::other_helper;\n#endif\n/) &&
              moved.match?(/^using namespace bc2cpp_cs_\h{16};\n[^\n]*int uses_branch\(\)/))
  ENV['BC2CPP_CROSS_GEM_SHARE'] = '0'
  off = RuntimeHeader.rewrite("#{RuntimeHeader::BEGIN_MARK}#{RuntimeHeader::END_MARK}#{CGS_TAIL}", nil, tail_mark: CrossGemShare.enabled?)
  ENV.delete('BC2CPP_CROSS_GEM_SHARE')
  suite.check('BC2CPP_CROSS_GEM_SHARE=0 leaves the tail as printed', off == CGS_TAIL)
  nm = ENV.fetch('NM', 'nm')
  if Bc2cppCxx.executable?(Bc2cppCxx.compiler.first) && system("#{nm} --version > /dev/null 2>&1")
    ENV['BC2CPP_SHARD_MIN_BYTES'] = '1'
    sources = []
    { 'ga' => a, 'gb' => b }.each do |gem, text|
      main, shards = ShardOutput.split(text, gem, 2)
      File.write(File.join(dir, "#{gem}_gen.cpp"), main)
      sources << File.join(dir, "#{gem}_gen.cpp")
      shards.each_with_index do |t, i|
        File.write(ShardOutput.shard_path(dir, gem, i + 1), t)
        sources << ShardOutput.shard_path(dir, gem, i + 1)
      end
    end
    ENV.delete('BC2CPP_SHARD_MIN_BYTES')
    File.write(File.join(dir, 'main.cpp'), "#include <cstdio>\nint ga_b(int); int gb_b(int);\n" \
                                           "extern \"C\" int cgs_c_abs(int x) { return x < 0 ? -x : x; }\n" \
                                           "int main() { int x = ga_b(1); int y = gb_b(1); std::printf(\"%d %d\\n\", x, y); }\n")
    binary = File.join(dir, 'cgs')
    # GCC's local clones would hide the entries nm counts; clang makes none and does not know the flags.
    version, = Open3.capture2e(Bc2cppCxx.compiler.first, '--version')
    no_clones = version.include?('clang') ? [] : %w[-fno-ipa-sra -fno-ipa-cp]
    _out, err, status = Bc2cppCxx.capture3('-std=c++17', '-Os', '-fno-inline', *no_clones, '-Wall', '-Werror', *sources, File.join(dir, 'main.cpp'), '-o', binary)
    suite.check('two sharded gems sharing headers compile warning-free and link (-Os)', status.success?)
    puts err.lines.first(20).join unless status.success?
    if status.success?
      out, = Open3.capture2(binary)
      # b(1) = helper 3 + method: third (3 + 3 + 2) + bump 1 + target 8 + calls_default (bump 2 + 1 + 1) + site 2
      # + via_c 3 + uses_branch 2 + the program-wide site, whose one counter both gems advance (2, then 3) = 33, 34.
      suite.check("each gem's own state stays its own, a program-wide site is one (#{out.strip})", out == "33 34\n")
      # A local clone the optimizer makes ([clone .isra.0]) is a copy per object of its own; the entries count.
      syms, = Open3.capture2(nm, '-C', '--defined-only', binary)
      syms = syms.lines.grep_v(/\[clone /).join
      # A function-local lambda's operator() names its function too; only the function counts.
      defs = ->(name) { syms.lines.select { |l| l.match?(/\s(?:\S+::)?#{name}\(/) && !l.include?('{lambda') } }
      suite.check('nm: each moved helper is defined once, in no gem namespace',
                  %w[helper third via_c program_site].all? { |n| defs.call(n).size == 1 && defs.call(n).none? { |l| l.include?('bc2cpp_shard_') } })
      suite.check('nm: a function naming per-gem state is defined in each gem', defs.call('via_bump').size == 2)
      shared = syms.lines.select { |l| l.include?('bc2cpp_cs_') && l.match?(/ [tTwW] /) }.map { |l| l.split(' ', 3).last }
      suite.check('nm: no shared helper is defined in two gems', !shared.empty? && shared.uniq.size == shared.size)
    end
  else
    puts '  SKIP: no C++ compiler or nm'
  end
end

# FIBER_SHARE: the Fiber runtime's items (named as in tools/bc2cpp/runtime) move with their state and addresses, one per
# program; one naming a gem's own state stays; a self-guarded #if region's names come back after its include.
puts '-- cross-gem share: the Fiber runtime'
FS_TAIL = <<~'CPP'
  static int counter = 0;
  #ifndef BC2CPP_LIT_SYM
  struct Bc2cppLitSymCache { int sym; };
  static int bc2cpp_lit_sym(Bc2cppLitSymCache& c, int v) { return c.sym ? c.sym : (c.sym = v); }
  #define BC2CPP_LIT_SYM(v) ([]() -> int { static Bc2cppLitSymCache bc2cpp_lit_cache = {0}; return bc2cpp_lit_sym(bc2cpp_lit_cache, (v)); }())
  #endif
  static int bc2cpp_running_fibers() { static int n = 0; return ++n; }
  static int bc2cpp_fiber_m_alive_p(int x) { return bc2cpp_running_fibers() + x + BC2CPP_LIT_SYM(1); }
  static int (*bc2cpp_fiber_orig_alive_p)(int) = nullptr;
  static const void* bc2cpp_fiber_definer_p() { return reinterpret_cast<const void*>(&bc2cpp_fiber_m_alive_p); }
  static int bc2cpp_fiber_own_p(int x) { return ++counter + x; }
CPP
def fs_gem(gem, dir)
  text = "#{RuntimeHeader::BEGIN_MARK}#{RuntimeHeader::END_MARK}#{FS_TAIL}" \
         "#{ShardOutput.unit_mark('A')}int #{gem}_run() { bc2cpp_fiber_orig_alive_p = &bc2cpp_fiber_m_alive_p; " \
         "return bc2cpp_fiber_orig_alive_p(0) * 100 + bc2cpp_fiber_own_p(0) * 10 + BC2CPP_LIT_SYM(2); }\n" \
         "const void* #{gem}_addr() { return bc2cpp_fiber_definer_p(); }\n#{ShardOutput::HOOKS_MARK}"
  CrossGemShare.rewrite(RuntimeHeader.rewrite(text, dir, tail_mark: true), dir)
end
Dir.mktmpdir('bc2cpp-cgs-fiber') do |dir|
  a = fs_gem('ga', dir)
  b = fs_gem('gb', dir)
  moved = Dir[File.join(dir, 'bc2cpp_cs_*.hxx')].map { |h| File.read(h) }.join
  suite.check('the runtime moves with its state, an address-taken function and a mutable variable, inline',
              moved.include?('inline int bc2cpp_running_fibers()') && moved.include?('inline int bc2cpp_fiber_m_alive_p(int x)') &&
              moved.include?('inline int (*bc2cpp_fiber_orig_alive_p)(int) = nullptr;') && !a.include?('int bc2cpp_running_fibers()'))
  suite.check("a runtime item naming the gem's own state stays", a.include?('static int bc2cpp_fiber_own_p(int x)') && !moved.include?('bc2cpp_fiber_own_p'))
  suite.check("a self-guarded region's names come back under a marker set before its include",
              a.match?(/^#ifndef BC2CPP_LIT_SYM\n#define (BC2CPP_CGS_TAKEN_\w+) 1\n#endif\n#define BC2CPP_CROSS_GEM_PART \d+\n#include "[^"]+"\n#undef BC2CPP_CROSS_GEM_PART\n#ifdef \1\nusing bc2cpp_cs_\h{16}::Bc2cppLitSymCache;\n#endif\n#ifdef \1\nusing bc2cpp_cs_\h{16}::bc2cpp_lit_sym;\n#endif\n#undef \1\n/))
  ENV['BC2CPP_FIBER_SHARE'] = '0'
  Dir.mktmpdir('bc2cpp-cgs-fiber-off') do |off_dir|
    suite.check('BC2CPP_FIBER_SHARE=0 keeps the runtime in the gem', fs_gem('ga', off_dir).include?('static int bc2cpp_running_fibers()'))
  end
  ENV.delete('BC2CPP_FIBER_SHARE')
  nm = ENV.fetch('NM', 'nm')
  if Bc2cppCxx.executable?(Bc2cppCxx.compiler.first) && system("#{nm} --version > /dev/null 2>&1")
    ENV['BC2CPP_SHARD_MIN_BYTES'] = '1'
    sources = []
    { 'ga' => a, 'gb' => b }.each do |gem, text|
      main, shards = ShardOutput.split(text, gem, 2)
      File.write(File.join(dir, "#{gem}_gen.cpp"), main)
      sources << File.join(dir, "#{gem}_gen.cpp")
      shards.each_with_index do |t, i|
        File.write(ShardOutput.shard_path(dir, gem, i + 1), t)
        sources << ShardOutput.shard_path(dir, gem, i + 1)
      end
    end
    ENV.delete('BC2CPP_SHARD_MIN_BYTES')
    File.write(File.join(dir, 'main.cpp'), "#include <cstdio>\nint ga_run(); int gb_run(); const void* ga_addr(); const void* gb_addr();\n" \
                                           "int main() { int x = ga_run(); int y = gb_run(); std::printf(\"%d %d %d\\n\", x, y, ga_addr() == gb_addr()); }\n")
    binary = File.join(dir, 'fs')
    [%w[-O2], %w[-Os]].each do |opt|
      _out, err, status = Bc2cppCxx.capture3('-std=c++17', *opt, '-Wall', '-Werror', *sources, File.join(dir, 'main.cpp'), '-o', binary)
      suite.check("two gems sharing the runtime compile warning-free and link (#{opt.first})", status.success?)
      puts err.lines.first(20).join unless status.success?
      next unless status.success?

      out, = Open3.capture2(binary)
      # run = alive_p (running_fibers + 0 + lit 1) * 100 + own_p * 10 + lit 2: the runtime's counter is one for the
      # program (2, then 3) and its literal cache one per site; own_p's counter is each gem's (1, 1).
      suite.check("the runtime's state is one per program, the gem's per gem, one address (#{opt.first}: #{out.strip})",
                  out == "212 312 1\n")
      syms, = Open3.capture2(nm, '-C', '--defined-only', binary)
      defs = ->(name) { syms.lines.grep_v(/\[clone /).select { |l| l.match?(/\s(?:\S+::)?#{name}\(/) && !l.include?('{lambda') } }
      suite.check("nm: the runtime state function is defined once, in no gem namespace (#{opt.first})",
                  defs.call('bc2cpp_running_fibers').size <= 1 && defs.call('bc2cpp_running_fibers').none? { |l| l.include?('bc2cpp_shard_') })
    end
  else
    puts '  SKIP: no C++ compiler or nm'
  end
end

# METHOD_PROTOTYPE: a helper calling the unit's own compiled method, and one testing a weak `extern "C"` function's
# address, move; a gem that only declares the method keeps its copy.
puts '-- cross-gem share: method prototypes'
MP_TAIL = <<~'CPP'
  extern "C" __attribute__((weak)) int mp_weak(int);
  int Mp__Box_get_impl(int x);
  static int mp_helper(int x) { return (mp_weak != nullptr ? mp_weak(x) : 0) + Mp__Box_get_impl(x); }
CPP
def mp_unit(dir, own)
  methods = own ? "int Mp__Box_get_impl(int x) { return x + 1; }\n" : ''
  text = "#{RuntimeHeader::BEGIN_MARK}#{RuntimeHeader::END_MARK}#{MP_TAIL}#{ShardOutput.unit_mark('A')}#{methods}" \
         "int mp_run(int x) { return mp_helper(x); }\n#{ShardOutput::HOOKS_MARK}"
  CrossGemShare.rewrite(RuntimeHeader.rewrite(text, dir, tail_mark: true), dir)
end
Dir.mktmpdir('bc2cpp-cgs-method') do |dir|
  own = mp_unit(dir, true)
  other = mp_unit(dir, false)
  suite.check('a helper calling the unit\'s own method and a weak C function\'s address moves; the declaration stays',
              !own.include?('static int mp_helper') && own.include?('int Mp__Box_get_impl(int x);') &&
              Dir[File.join(dir, 'bc2cpp_cs_*.hxx')].any? { |h| File.read(h).include?('int mp_helper(int x)') })
  suite.check('a gem that only declares the method keeps the helper', other.include?('static int mp_helper'))
  ENV['BC2CPP_CROSS_GEM_METHOD_PROTOTYPE'] = '0'
  Dir.mktmpdir('bc2cpp-cgs-method-off') do |off_dir|
    suite.check('BC2CPP_CROSS_GEM_METHOD_PROTOTYPE=0 keeps the helper', mp_unit(off_dir, true).include?('static int mp_helper'))
  end
  ENV.delete('BC2CPP_CROSS_GEM_METHOD_PROTOTYPE')
end

# PROGRAM_CLASS_SLOTS (tools/bc2cpp/program_class_slots.rb): two gems number an owner alike and share one table.
puts '-- program-wide class slots'
def pcs_gen(registry, superclass_of)
  CodeGen.new({}, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new)
end
PCS_REGISTRY = {
  'run' => [MethodDef.new(name: 'run', owner: 'Alpha'), MethodDef.new(name: 'run', owner: 'Beta::Gamma'),
            MethodDef.new(name: 'run', owner: 'Alpha.singleton'), MethodDef.new(name: 'run', owner: '<dynamic>')]
}.freeze
PCS_SUPER = { 'Beta::Gamma' => 'Alpha', 'Delta' => 'Alpha' }.freeze
Dir.mktmpdir('bc2cpp-pcs') do |dir|
  ENV[RuntimeHeader::DIR_KEY] = dir
  a = pcs_gen(PCS_REGISTRY, PCS_SUPER)
  b = pcs_gen(PCS_REGISTRY, PCS_SUPER)
  a_names = %w[Beta::Gamma Alpha Delta].to_h { |o| [o, a.owner_class_fn_name(o)] }
  b_names = %w[Alpha Zed Delta Beta::Gamma].to_h { |o| [o, b.owner_class_fn_name(o)] }
  universe = (%w[Alpha Alpha.singleton Beta::Gamma Delta] + CallFacts::CORE_SUPER.keys).uniq.sort
  n = universe.size
  suite.check('the universe is every registry, superclass and core owner spelled as a constant path, sorted',
              a.instance_variable_get(:@program_class_universe) == universe)
  suite.check('two gems asking in different orders number each owner alike, by its rank',
              %w[Alpha Beta::Gamma Delta].all? { |o| a_names[o] == b_names[o] && a_names[o] == "bc2cpp_owner_class_#{universe.index(o)}" })
  suite.check('an owner outside the universe takes the gem slot after it', b_names['Zed'] == "bc2cpp_owner_class_#{n}")
  a_text = a.emit_owner_class_cache
  b_text = b.emit_owner_class_cache
  headers = Dir[File.join(dir, 'bc2cpp_pw_classes_*.hxx')]
  header = headers.first.to_s
  suite.check('both gems include one header holding the one table',
              headers.size == 1 && a_text.include?("#include \"#{header}\"") && b_text.include?("#include \"#{header}\"") &&
              File.read(header).match?(/^inline struct RClass\* bc2cpp_pw_class_slots_\h{16}\[#{n}\] = \{\};$/))
  suite.check('only the gem with an extra owner keeps slots of its own, after the universe',
              !a_text.include?('bc2cpp_owner_class_xslots') && b_text.include?('bc2cpp_owner_class_xslots[1]') &&
              b_text.include?("i < #{n} ?") && !a_text.include?('static struct RClass* bc2cpp_owner_class_slots['))
  suite.check("the gems' fuse getters and table readers print the same text",
              a_text[/^\[\[maybe_unused\]\] \[\[gnu::noinline\]\] static struct RClass\* bc2cpp_owner_class_at.*?^}\n/m] ==
                b_text[/^\[\[maybe_unused\]\] \[\[gnu::noinline\]\] static struct RClass\* bc2cpp_owner_class_at.*?^}\n/m] &&
              a_text.include?('bc2cpp_owner_class_slot(i)'))
  suite.check('the reset clears the program table and the VM it is bound to',
              a_text.match?(/bc2cpp_reset_owner_classes\(\) \{\n  bc2cpp_pw_class_state_\h{16} = nullptr;\n  for \(struct RClass\*& c : bc2cpp_pw_class_slots_\h{16}\) c = nullptr;\n/))
  closed = pcs_gen(PCS_REGISTRY, PCS_SUPER)
  closed.owner_class_fn_name('Alpha')
  closed.instance_variable_set(:@closed_world, Object.new)
  closed.emit_owner_class_cache
  suite.check('a different lookup gets a different table', Dir[File.join(dir, 'bc2cpp_pw_classes_*.hxx')].size == 2)
  mruby_inc = "#{BC2CPP_WORLD_ROOT}/3rd/mruby/include"
  build_inc = ENV.fetch('BC2CPP_BUILD_INCLUDE', "#{BC2CPP_WORLD_ROOT}/build-closed-bc2cpp/closed/include")
  if Bc2cppCxx.executable?(Bc2cppCxx.compiler.first) && File.directory?(mruby_inc) && File.directory?(build_inc) &&
     system("#{ENV.fetch('NM', 'nm')} --version > /dev/null 2>&1")
    objs = { 'ga' => a_text, 'gb' => b_text }.map do |gem, text|
      src = File.join(dir, "#{gem}.cpp")
      File.write(src, "#include <mruby.h>\n#include <mruby/class.h>\n#include <mruby/variable.h>\nnamespace pcs_#{gem} {\n" \
                      "#{text.sub(/^#include "[^"]+"\n/, '')}" \
                      "struct RClass* probe(mrb_state* M) { bc2cpp_reset_owner_classes(); return bc2cpp_owner_class_at(M, 0); }\n}\n"
                      .sub("namespace pcs_#{gem} {\n", "#include \"#{header}\"\nnamespace pcs_#{gem} {\n"))
      obj = File.join(dir, "#{gem}.o")
      _o, err, st = Bc2cppCxx.capture3('-std=c++17', '-O1', '-c', "-I#{mruby_inc}", "-I#{build_inc}", src, '-o', obj)
      puts err.lines.first(10).join unless st.success?
      st.success? ? obj : nil
    end
    suite.check('both gems compile with the mruby headers', objs.all?)
    if objs.all?
      syms = objs.map { |o| Open3.capture2(ENV.fetch('NM', 'nm'), '--defined-only', o).first }
      tables = syms.map { |s| s.lines.grep(/bc2cpp_pw_class_slots_\h{16}/).map { |l| l.split.last } }
      suite.check('nm: each gem defines the same program table symbol, mergeable (inline, not per gem)',
                  tables.all? { |t| t.size == 1 } && tables.uniq.size == 1 && !tables.first.first.include?('pcs_'))
    end
  else
    puts '  SKIP: no C++ compiler, nm, mruby headers or build include directory'
  end
  ENV['BC2CPP_PROGRAM_CLASS_SLOTS'] = '0'
  off = pcs_gen(PCS_REGISTRY, PCS_SUPER)
  off_names = %w[Delta Alpha].map { |o| off.owner_class_fn_name(o) }
  off_text = off.emit_owner_class_cache
  ENV.delete('BC2CPP_PROGRAM_CLASS_SLOTS')
  suite.check('BC2CPP_PROGRAM_CLASS_SLOTS=0 numbers the gem table 0...n and includes no program table',
              off_names == %w[bc2cpp_owner_class_0 bc2cpp_owner_class_1] && !off_text.include?('bc2cpp_pw_class_') &&
              off_text.include?('static struct RClass* bc2cpp_owner_class_slots[2] = {};'))
  ENV.delete(RuntimeHeader::DIR_KEY)
  suite.check('no runtime header directory (a fixture world) keeps the gem table',
              pcs_gen(PCS_REGISTRY, PCS_SUPER).instance_variable_get(:@program_class_universe).nil?)
end

suite.finish!
