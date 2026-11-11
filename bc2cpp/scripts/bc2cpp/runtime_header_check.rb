#!/usr/bin/env ruby
# frozen_string_literal: true

# RUNTIME_HEADER (tools/bc2cpp/runtime_header.rb): the fixed runtime prelude goes to one header every compiled gem
# includes.
#
#   text (no tools)
#     - with no directory the marks are dropped and the text is otherwise unchanged;
#     - a stateless helper moves to the header, `inline`, in the digest-named namespace; an #include stays at file
#       scope;
#     - a `static` mutable variable or function-local, every item that names one (through a macro too) and the
#       declaration paired with such a definition stay in the unit's text, at their place between header parts;
#     - the same region gives the same header path; a different one a different path and namespace;
#   linkage (needs g++)
#     - two gems that include the header link warning-free, share one copy of each shared helper, and keep one
#       instance of a per-unit state each.
#
# Usage: ruby scripts/bc2cpp/runtime_header_check.rb

require 'open3'
require 'tmpdir'
require_relative 'check_support'
require_relative 'cxx'
require_relative '../../tools/bc2cpp/runtime_header'

suite = FixtureCheck.new('runtime_header_check')

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

suite.finish!
