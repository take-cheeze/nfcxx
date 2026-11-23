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
#       function and a method declaration stay;
#     - two sharded gems printing the same tail link, run, and nm finds each moved helper defined once, in no gem
#       namespace, while each gem keeps its own state; BC2CPP_CROSS_GEM_SHARE=0 leaves the tail as printed.
#
#   isolation (--isolation BUILD_DIR; a real build, needs a C++ compiler)
#     - each compiled gem's main file, with every gem-namespace item after the runtime region dropped, still
#       compiles: no cross-gem header names a gem's own item (which ShardOutput's using-directive would hide).
#       BC2CPP_ISOLATION_FLAGS holds the build's other -I/-D flags.
#
# Usage: ruby scripts/bc2cpp/runtime_header_check.rb [--isolation BUILD_DIR]

require 'open3'
require 'tmpdir'
require_relative 'check_support'
require_relative 'cxx'
require_relative '../../tools/bc2cpp/runtime_header'
require_relative '../../tools/bc2cpp/cross_gem_share'

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
  flags = ['-std=c++17', '-fsyntax-only', "-I#{Dir["#{build}/*/include"].first || "#{build}/include"}",
           *ENV.fetch('BC2CPP_ISOLATION_FLAGS', '').split]
  Dir.mktmpdir('bc2cpp-isolation') do |dir|
    mains.each do |main|
      text = File.read(main)
      next unless text.include?('// SHARD_DECLS') && text.include?('bc2cpp_cs_')

      skeleton = File.join(dir, File.basename(main))
      File.write(skeleton, isolation_skeleton(text))
      _out, err, status = Bc2cppCxx.capture3(*flags, "-I#{File.dirname(main)}", skeleton)
      suite.check("#{File.basename(main)}: the cross-gem headers compile without the gem's own items", status.success?)
      puts err.lines.grep(/error/).first(10).join unless status.success?
    end
  end
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
  int GEM_method(int x);
CPP
def cgs_gem(gem, dir)
  tail = CGS_TAIL.gsub('GEM', gem)
  text = "#{RuntimeHeader::BEGIN_MARK}static inline int twice(int x) { return 2 * x; }\n#{RuntimeHeader::END_MARK}#{tail}" \
         "#{ShardOutput.unit_mark('A')}int #{gem}_method(int x) { CgsPair p{x, 2}; return third(p) + via_bump() + target_ptr(1) + calls_default() + site_user(); }\n" \
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
  suite.check('the unit names a moved item through a using-declaration', a.match?(/^using bc2cpp_cs_\h{16}::helper;$/))
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
                                           "int main() { std::printf(\"%d %d\\n\", ga_b(1), gb_b(1)); }\n")
    binary = File.join(dir, 'cgs')
    # GCC's local clones would hide the entries nm counts; clang makes none and does not know the flags.
    version, = Open3.capture2e(Bc2cppCxx.compiler.first, '--version')
    no_clones = version.include?('clang') ? [] : %w[-fno-ipa-sra -fno-ipa-cp]
    _out, err, status = Bc2cppCxx.capture3('-std=c++17', '-Os', '-fno-inline', *no_clones, '-Wall', '-Werror', *sources, File.join(dir, 'main.cpp'), '-o', binary)
    suite.check('two sharded gems sharing headers compile warning-free and link (-Os)', status.success?)
    puts err.lines.first(20).join unless status.success?
    if status.success?
      out, = Open3.capture2(binary)
      # b(1) = helper 3 + method: third (3 + 3 + 2) + bump 1 + target 8 + calls_default (bump 2 + 1 + 1) + site 2 = 26.
      suite.check("each gem's own state stays its own (#{out.strip})", out == "26 26\n")
      # A local clone the optimizer makes ([clone .isra.0]) is a copy per object of its own; the entries count.
      syms, = Open3.capture2(nm, '-C', '--defined-only', binary)
      syms = syms.lines.grep_v(/\[clone /).join
      defs = ->(name) { syms.lines.select { |l| l.match?(/\s(?:\S+::)?#{name}\(/) } }
      suite.check('nm: each moved helper is defined once, in no gem namespace',
                  %w[helper third].all? { |n| defs.call(n).size == 1 && defs.call(n).none? { |l| l.include?('bc2cpp_shard_') } })
      suite.check('nm: a function naming per-gem state is defined in each gem', defs.call('via_bump').size == 2)
      shared = syms.lines.select { |l| l.include?('bc2cpp_cs_') && l.match?(/ [tTwW] /) }.map { |l| l.split(' ', 3).last }
      suite.check('nm: no shared helper is defined in two gems', !shared.empty? && shared.uniq.size == shared.size)
    end
  else
    puts '  SKIP: no C++ compiler or nm'
  end
end

suite.finish!
