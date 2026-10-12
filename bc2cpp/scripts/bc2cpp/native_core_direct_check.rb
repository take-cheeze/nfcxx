#!/usr/bin/env ruby
# encoding: UTF-8
# Check NATIVE_CORE_DIRECT (docs/adr/0257): a send to a core native with a
# frame-independent body (Array#join/shift/compact/index, String#bytes,
# Integer#inspect) gets an exact-builtin-class arm in front of its dynamic send.
#
#   - the audit: every table row verifies against the real mruby sources, and a
#     changed registration, body or spelling drops the row;
#   - ForeignDefiners: outside Ruby definitions are attributed to their class;
#   - generated code: the arms and their argument guards, and every reason they
#     are withheld (open world, Ruby override, prepend, installer, arity, block);
#   - behaviour: each emitted arm, compiled against a real libmruby, agrees with
#     the interpreter on results, exceptions and receiver state.
require 'fileutils'
require 'open3'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/native_core_direct'
require_relative '../../tools/bc2cpp/foreign_definers'
require_relative 'cxx'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

mruby_dir = File.join(root, '3rd/mruby')
rgss_srcs = Dir[File.join(root, 'mruby-rgss/src/*.cxx')]
native_srcs = rgss_srcs + core_native_srcs(mruby_dir) + external_gem_native_srcs(root)

# -- the audit ------------------------------------------------------------------

audit = NativeCoreDirect.audit(native_srcs)
NativeCoreDirect::ENTRIES.each do |entry|
  check.call("#{entry.owner}##{entry.name}/#{entry.arity} verifies against the mruby sources (#{audit[entry] || 'ok'})",
             audit[entry].nil?)
end
NativeCoreDirect::ENTRIES.each do |entry|
  next unless entry.helper

  check.call("#{entry.helper} has helper text and the expression calls it",
             NativeCoreDirect::HELPERS.key?(entry.helper) && entry.expression.include?("#{entry.helper}("))
end

Dir.mktmpdir do |dir|
  fake = File.join(dir, '3rd/mruby')
  FileUtils.mkdir_p(File.join(fake, 'src'))
  FileUtils.ln_s(File.join(mruby_dir, 'include'), File.join(fake, 'include'))
  array_c = File.join(fake, 'src/array.c')
  original = File.read(File.join(mruby_dir, 'src/array.c'))
  join = NativeCoreDirect::ENTRIES.find { |e| e.name == 'join' && e.arity.zero? }
  shift = NativeCoreDirect::ENTRIES.find { |e| e.name == 'shift' }
  index = NativeCoreDirect::ENTRIES.find { |e| e.name == 'index' }

  File.write(array_c, original)
  check.call('a copy of array.c verifies join', NativeCoreDirect.audit([array_c])[join].nil?)

  File.write(array_c, original.sub('mrb_get_args(mrb, "|S!", &sep);', 'mrb_get_args(mrb, "|o", &sep);'))
  check.call('a changed argument spec in the registered body drops join',
             NativeCoreDirect.audit([array_c])[join].to_s.include?('no longer matches'))

  File.write(array_c, original.sub('if (mrb_get_argc(mrb) == 0) {', 'if (mrb_get_argc(mrb) == 0 && FALSE) {'))
  check.call('a changed prefix drops shift', NativeCoreDirect.audit([array_c])[shift].to_s.include?('no longer matches'))

  File.write(array_c, original.sub('MRB_MT_ENTRY(mrb_ary_join_m,       MRB_SYM(join),            MRB_ARGS_OPT(1))',
                                   'MRB_MT_ENTRY(mrb_ary_join_m,       MRB_SYM(join),            MRB_ARGS_ANY())'))
  check.call('a changed aspec drops join', NativeCoreDirect.audit([array_c])[join].to_s.include?('registered as'))

  File.write(array_c, original.sub('MRB_MT_ENTRY(mrb_ary_join_m,       MRB_SYM(join),            MRB_ARGS_OPT(1)),',
                                   'MRB_MT_ENTRY(mrb_ary_join_m,       MRB_SYM(collect),         MRB_ARGS_OPT(1)),'))
  check.call('a registration that no longer spells the name drops join',
             NativeCoreDirect.audit([array_c])[join].to_s.include?('found 0'))

  File.write(array_c, original)
  other = File.join(fake, 'src/other.c')
  File.write(other, 'void f(mrb_state* mrb) { mrb_define_method_id(mrb, mrb->array_class, MRB_SYM(index), g, MRB_ARGS_NONE()); }')
  check.call('a second registration of the name on the class drops the row',
             NativeCoreDirect.audit([array_c, other])[index].to_s.include?('unattributed'))
  File.write(other, 'void f(mrb_state* mrb, RClass* k) { mrb_define_method_id(mrb, k, MRB_SYM(index), g, MRB_ARGS_NONE()); }')
  check.call('an unattributable registration of the name drops the row',
             NativeCoreDirect.audit([array_c, other])[index].to_s.include?('unattributed'))

  string_c = File.join(fake, 'src/string.c')
  string_original = File.read(File.join(mruby_dir, 'src/string.c'))
  size = NativeCoreDirect::ENTRIES.find { |e| e.owner == 'String' && e.name == 'size' }
  File.write(string_c, string_original)
  check.call('a copy of string.c verifies String#size', NativeCoreDirect.audit([string_c])[size].nil?)
  File.write(string_c, string_original.sub("#else\n#define RSTRING_CHAR_LEN(s) RSTRING_LEN(s)",
                                           "#else\n#define RSTRING_CHAR_LEN(s) utf8_strlen(s)"))
  check.call('a changed non-UTF-8 RSTRING_CHAR_LEN drops String#size',
             NativeCoreDirect.audit([string_c])[size].to_s.include?('no longer contains'))
  File.write(string_c, string_original.sub('mrb_int len = RSTRING_CHAR_LEN(self);', 'mrb_int len = RSTRING_CHAR_LEN(self) + 1;'))
  check.call('a changed mrb_str_size body drops String#size', NativeCoreDirect.audit([string_c])[size].to_s.include?('no longer matches'))
  File.write(string_c, string_original.sub('MRB_MT_ENTRY(mrb_str_size,            MRB_SYM(size),            MRB_ARGS_NONE())',
                                           'MRB_MT_ENTRY(mrb_str_size,            MRB_SYM(size),            MRB_ARGS_OPT(1))'))
  check.call('a changed String#size aspec drops the row', NativeCoreDirect.audit([string_c])[size].to_s.include?('registered as'))

  FileUtils.rm_f(File.join(fake, 'include'))
  check.call('without the mruby headers no row is trusted',
             NativeCoreDirect.audit([array_c])[join].to_s.include?('include'))
end

# -- ForeignDefiners --------------------------------------------------------------

Dir.mktmpdir do |dir|
  write = lambda do |name, text|
    File.join(dir, name).tap { |path| File.write(path, text) }
  end
  defines = ->(paths, owner, name) { ForeignDefiners.defines?(paths, owner, name) }
  plain = write.call('plain.rb', <<~RUBY)
    class Array
      def sort; end
      alias_method :sorted, :sort
      attr_reader :first_seen
      private def hidden; end
      class << self
        def try_convert(x); end
      end
      def self.build; end
    end
    class Rational
      def inspect; end
    end
    module Enumerable
      def min; end
    end
  RUBY
  check.call('a def in the class body is attributed to it', defines.call([plain], 'Array', 'sort'))
  check.call('alias_method, attr_reader and `private def` are attributed',
             %w[sorted first_seen first_seen= hidden].all? { |n| defines.call([plain], 'Array', n) })
  check.call('a singleton def is not an instance definition', !defines.call([plain], 'Array', 'try_convert') &&
                                                              !defines.call([plain], 'Array', 'build'))
  check.call('another class\'s definition of the name is not attributed', !defines.call([plain], 'Integer', 'inspect') &&
                                                                          defines.call([plain], 'Rational', 'inspect'))
  check.call('a module the class inherits from is a different owner', !defines.call([plain], 'Array', 'min'))
  wild = write.call('wild.rb', <<~RUBY)
    class Array
      [:a, :b].each { |n| define_method(n) { n } }
    end
    class String
      prepend Shadow
    end
    class Integer
      class_eval "def to_s; end"
    end
    class Hash
      undef_method :fetch
      visibility = :private
      private visibility
    end
  RUBY
  check.call('a define_method with a computed name makes the class wild', defines.call([wild], 'Array', 'anything'))
  check.call('a prepend makes the class wild', defines.call([wild], 'String', 'anything'))
  check.call('a class_eval makes the class wild', defines.call([wild], 'Integer', 'anything'))
  check.call('undef_method names the method and a computed visibility target makes the class wild',
             defines.call([wild], 'Hash', 'fetch') && defines.call([wild], 'Hash', 'anything'))
  receiver = write.call('receiver.rb', "Array.send(:define_method, :x) { }\nNokogiri = 1\n")
  check.call('a definer called on a class constant makes that class wild', defines.call([receiver], 'Array', 'anything'))
  real = Dir[File.join(mruby_dir, 'mrblib/**/*.rb')] + Dir[File.join(mruby_dir, 'mrbgems/*/mrblib/**/*.rb')]
  check.call('the real mrblib defines no Integer#inspect, Array#join or Array#compact',
             !defines.call(real, 'Integer', 'inspect') && !defines.call(real, 'Array', 'join') &&
               !defines.call(real, 'Array', 'compact'))
  check.call('the real mrblib does define Array#sort', defines.call(real, 'Array', 'sort'))
end

# -- generated code ---------------------------------------------------------------

mrbc = ENV['MRBC'] || 'mrbc'
gems = NomethodReviewedProbe.wio_gems(root)
generate = lambda do |source, name, closed|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'NATIVE_SRCS' => Shellwords.join(native_srcs) }
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(root)),
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), path)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    out
  end
end
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

WORLD = <<~'RUBY'
  class CdCaller
    def join0(a); a.join; end
    def join1(a, sep); a.join(sep); end
    def join2(a); a.join(",", 1); end
    def shift0(a); a.shift; end
    def shift1(a); a.shift(2); end
    def compact0(a); a.compact; end
    def index1(a, x); a.index(x); end
    def index_block(a); a.index { |v| v }; end
    def bytes0(s); s.bytes; end
    def inspect0(n); n.inspect; end
    def inspect_arg(n); n.inspect(2); end
    def size0(v); v.size; end
    def length0(v); v.length; end
    def size_lit; 'abc'.size; end
    def size_ary_lit; [1, 2].size; end
    def size_arg(v); v.size(1); end
  end
RUBY
OVERRIDE = "#{WORLD}\nclass Array\n  def join(sep = nil); 'x'; end\n  def shift(n = nil); 1; end\nend\n"
PREPEND = "#{WORLD}\nmodule CdShadow\n  def compact; []; end\nend\nclass Array\n  prepend CdShadow\nend\n"
INSTALLER = "#{WORLD}\nclass CdCaller\n  def install(name); Array.send(:define_method, name) { 1 }; end\nend\n"
INTEGER_OVERRIDE = "#{WORLD}\nclass Integer\n  def inspect; 'i'; end\nend\n"
STRING_OVERRIDE = "#{WORLD}\nclass String\n  def size; 1; end\nend\n"
STRING_PREPEND = "#{WORLD}\nmodule CdStrShadow\n  def length; 1; end\nend\nclass String\n  prepend CdStrShadow\nend\n"

open_code = generate.call(WORLD, 'cd_open', false)
closed_code = generate.call(WORLD, 'cd_closed', true)
override_code = generate.call(OVERRIDE, 'cd_override', true)
prepend_code = generate.call(PREPEND, 'cd_prepend', true)
installer_code = generate.call(INSTALLER, 'cd_installer', true)
integer_code = generate.call(INTEGER_OVERRIDE, 'cd_integer', true)
string_override_code = generate.call(STRING_OVERRIDE, 'cd_string_override', true)
string_prepend_code = generate.call(STRING_PREPEND, 'cd_string_prepend', true)

check.call('without the closed world no arm is emitted', !open_code.include?('NATIVE_CORE_DIRECT'))

arm = lambda do |code, fn|
  body_of.call(code, "CdCaller_#{fn}")
end
join0 = arm.call(closed_code, 'join0')
check.call('join with no argument calls mrb_ary_join under an exact-Array guard, with the send as its else',
           join0.match?(/if \(mrb_array_p\(r\d+\) && mrb_obj_ptr\(r\d+\)->c == M->array_class\) \{\n\s+r\d+ = mrb_ary_join\(M, r\d+, mrb_nil_value\(\)\);\n\s+\} else \{\n\s+r\d+ = bc2cpp_send\(/))
join1 = arm.call(closed_code, 'join1')
check.call('join with a separator only takes the arm for nil or a String, so other separators reach the wrapper\'s coercion',
           join1.include?('(mrb_nil_p(r') && join1.include?('mrb_string_p(r') && join1.include?('mrb_ary_join(M, r') &&
             join1.include?('bc2cpp_send('))
check.call('join with two arguments has no arm', !arm.call(closed_code, 'join2').include?('NATIVE_CORE_DIRECT'))
shift0 = arm.call(closed_code, 'shift0')
check.call('shift with no argument calls mrb_ary_shift', shift0.include?('mrb_ary_shift(M, r'))
check.call('shift with a count has no arm', !arm.call(closed_code, 'shift1').include?('NATIVE_CORE_DIRECT'))
check.call('compact and index and bytes call their helpers',
           arm.call(closed_code, 'compact0').include?('bc2cpp_ary_compact(M, r') &&
             arm.call(closed_code, 'index1').include?('bc2cpp_ary_index(M, r') &&
             arm.call(closed_code, 'bytes0').include?('bc2cpp_str_bytes(M, r'))
check.call('the helpers are defined once each in the output',
           %w[bc2cpp_ary_compact bc2cpp_ary_index bc2cpp_str_bytes].all? do |helper|
             closed_code.scan(/^static inline mrb_value #{helper}\(/).size == 1
           end)
check.call('Integer#inspect with no argument calls mrb_integer_to_str in base 10',
           arm.call(closed_code, 'inspect0').match?(/if \(mrb_integer_p\(r\d+\)\) \{\n\s+r\d+ = mrb_integer_to_str\(M, r\d+, 10\);/))
check.call('inspect with an argument has no arm', !arm.call(closed_code, 'inspect_arg').include?('NATIVE_CORE_DIRECT'))
check.call('a block-carrying index is not an arm', !arm.call(closed_code, 'index_block').include?('bc2cpp_ary_index('))

check.call('a Ruby definition of join or shift on Array withdraws exactly those arms',
           !arm.call(override_code, 'join0').include?('NATIVE_CORE_DIRECT') &&
             !arm.call(override_code, 'shift0').include?('NATIVE_CORE_DIRECT') &&
             arm.call(override_code, 'compact0').include?('NATIVE_CORE_DIRECT'))
check.call('a prepend on Array withdraws every Array arm and leaves String and Integer alone',
           !arm.call(prepend_code, 'join0').include?('NATIVE_CORE_DIRECT') &&
             !arm.call(prepend_code, 'compact0').include?('NATIVE_CORE_DIRECT') &&
             arm.call(prepend_code, 'bytes0').include?('NATIVE_CORE_DIRECT') &&
             arm.call(prepend_code, 'inspect0').include?('NATIVE_CORE_DIRECT'))
check.call('a dynamic installer withdraws every arm',
           !arm.call(installer_code, 'join0').include?('NATIVE_CORE_DIRECT') &&
             !arm.call(installer_code, 'bytes0').include?('NATIVE_CORE_DIRECT'))
check.call('a Ruby Integer#inspect withdraws the Integer arm',
           !arm.call(integer_code, 'inspect0').include?('NATIVE_CORE_DIRECT') &&
             arm.call(integer_code, 'join0').include?('NATIVE_CORE_DIRECT'))

size0 = arm.call(closed_code, 'size0')
check.call('String#size and #length get an exact-String arm after the generated Array/Hash arms, the send as its else',
           size0.match?(/mrb_hash_size.*?NATIVE_CORE_DIRECT :size.*?if \(mrb_string_p\(r\d+\) && mrb_obj_ptr\(r\d+\)->c == M->string_class\) \{\n\s+r\d+ = bc2cpp_str_size\(M, r\d+\);\n\s+\} else \{\n\s+r\d+ = bc2cpp_send\(/m) &&
             arm.call(closed_code, 'length0').include?('bc2cpp_str_length(M, r'))
check.call('size with an argument has no String arm', !arm.call(closed_code, 'size_arg').include?('bc2cpp_str_size('))
check.call('the String size helpers are defined once each and branch on MRB_UTF8_STRING',
           %w[bc2cpp_str_size bc2cpp_str_length].all? do |helper|
             text = closed_code[/^static inline mrb_value #{helper}\(.*?^\}\n/m].to_s
             closed_code.scan(/^static inline mrb_value #{helper}\(/).size == 1 &&
               text.include?('#ifdef MRB_UTF8_STRING') && text.include?('RSTRING_LEN(str)')
           end)
check.call('a Ruby String#size withdraws the size arm only; length keeps its own',
           !arm.call(string_override_code, 'size0').include?('bc2cpp_str_size(') &&
             arm.call(string_override_code, 'length0').include?('bc2cpp_str_length('))
check.call('a prepend on String withdraws both String arms and leaves Array alone',
           !arm.call(string_prepend_code, 'size0').include?('bc2cpp_str_size(') &&
             !arm.call(string_prepend_code, 'length0').include?('bc2cpp_str_length(') &&
             arm.call(string_prepend_code, 'join0').include?('NATIVE_CORE_DIRECT'))
check.call('a dynamic installer and an open world withdraw the String arms',
           !arm.call(installer_code, 'size0').include?('bc2cpp_str_size(') && !open_code.include?('bc2cpp_str_size('))
check.call('a Ruby Integer#inspect leaves the String size arm alone', arm.call(integer_code, 'size0').include?('bc2cpp_str_size('))

# -- the bucket -------------------------------------------------------------------

NATIVE_BUCKET = <<~'RUBY'
  class CdBox
    def z=(v); @z = v; end
  end
  class CdSetter
    def set_z(w, v); w.z = v; end
  end
RUBY
bucket_code = generate.call(NATIVE_BUCKET, 'cd_bucket', true)
diag = bucket_code[/POLY_DIAG[^\n]*name="z="[^\n]*/].to_s
check.call('a chain whose native definition is fully covered by RGSS arms reports native_direct, not native_or_uncompiled',
           diag.include?('native_direct=') && !diag.include?('native_or_uncompiled'))

# -- behaviour --------------------------------------------------------------------
# Compiled against the core-only mruby library the other bc2cpp checks use, so
# every input is built through the C API and the reference is the ordinary
# dispatch. Array#compact lives in a gem and is pinned by the audited body text
# instead.

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |dir| File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural comparison: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  cases = {
    'join0' => { name: 'join',
                 recv: ['A(M, {})', 'A(M, {I(1), I(2), I(3)})', 'A(M, {S("a"), NIL, A(M, {I(3), A(M, {I(4), S("b")})})})',
                        'SA(M, {I(1), I(2)})', 'REC(M)', 'A(M, {Y("x"), F(1.5), S("s")})', 'FRZ(M, A(M, {I(1)}))'],
                 args: [nil] },
    'join1' => { name: 'join',
                 recv: ['A(M, {I(1), I(2), I(3)})', 'A(M, {S("a"), A(M, {S("b"), S("c")})})', 'A(M, {})'],
                 args: ['NIL', 'S(",")', 'S("::")', 'SS(M, "-")', 'Y("sym")', 'I(5)', 'OBJ(M)'] },
    'shift0' => { name: 'shift',
                  recv: ['A(M, {I(1), I(2), I(3)})', 'A(M, {})', 'A(M, {NIL})', 'BIG(M, 40)', 'FRZ(M, A(M, {I(1), I(2)}))'],
                  args: [nil] },
    'index1' => { name: 'index',
                  recv: ['A(M, {})', 'A(M, {I(1), I(2), I(3)})', 'A(M, {NIL, F(1.0)})', 'A(M, {S("a"), S("b")})',
                         'A(M, {A(M, {I(1)}), A(M, {I(2)})})'],
                  args: ['I(1)', 'I(2)', 'I(5)', 'NIL', 'F(1.0)', 'S("b")', 'A(M, {I(2)})', 'OBJ(M)'] },
    'bytes0' => { name: 'bytes',
                  recv: ['S("")', 'S("abc")', 'SN(M, "\xe3\x81\x82\xc3\xbf", 5)', 'SN(M, "\xff\x00a", 3)', 'SS(M, "xy")'],
                  args: [nil] },
    'size0' => { name: 'size',
                 recv: ['S("")', 'S("abc")', 'SN(M, "\xe3\x81\x82\xc3\xbf", 5)', 'SN(M, "\xff\x00a", 3)', 'SS(M, "xy")',
                        'FRZ(M, S("frozen"))', 'BIGS(M, 300)', 'SING(M, "abc")', 'NIL', 'A(M, {I(1), I(2)})', 'I(7)'],
                 args: [nil] },
    'length0' => { name: 'length',
                   recv: ['S("")', 'S("abc")', 'SN(M, "\xe3\x81\x82\xc3\xbf", 5)', 'SS(M, "xy")', 'FRZ(M, S("frozen"))',
                          'BIGS(M, 300)', 'SING(M, "abc")', 'NIL', 'A(M, {})'],
                   args: [nil] },
    'inspect0' => { name: 'inspect',
                    recv: ['I(0)', 'I(-5)', 'I(123456789)', 'I(MRB_INT_MAX)', 'I(MRB_INT_MIN)', 'F(1.5)', 'NIL', 'S("s")', 'Y("a")'],
                    args: [nil] }
  }
  Dir.mktmpdir do |dir|
    snippets = cases.to_h do |fn, spec|
      body = arm.call(closed_code, fn)
      snippet = body[%r{^\s*// NATIVE_CORE_DIRECT :.*?\n(?:.*\n)*?  \}\n}m]
      abort "no NATIVE_CORE_DIRECT snippet found in #{fn}" unless snippet
      [fn, snippet.gsub(/bc2cpp_send\(M, (r\d+), \d+, /) { "mrb_funcall(M, #{Regexp.last_match(1)}, \"#{spec[:name]}\", " }]
    end
    registers = snippets.transform_values do |snippet|
      guard = snippet[/if \((.*?)\) \{/m, 1]
      recv = guard[/(r\d+)/, 1]
      arg = snippet[/mrb_funcall\(M, r\d+, "\w+", 1, (r\d+)\)/, 1] || guard.scan(/r\d+/).last
      [recv, arg, snippet[/(r\d+) = (?:mrb_|bc2cpp_)/, 1]]
    end

    harness = +<<~CPP
      #include <mruby.h>
      #include <mruby/array.h>
      #include <mruby/string.h>
      #include <mruby/numeric.h>
      #include <mruby/range.h>
      #include <mruby/error.h>
      #include <mruby/class.h>
      #include <cstdio>
      #include <initializer_list>
      #include <string>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      #define I(n) mrb_int_value(M, (n))
      #define F(x) mrb_float_value(M, (x))
      #define NIL mrb_nil_value()
      #define S(lit) mrb_str_new_lit(M, lit)
      #define Y(lit) mrb_symbol_value(mrb_intern_lit(M, lit))
      #define SN(M, p, n) mrb_str_new(M, p, n)
      static mrb_value A(mrb_state* M, std::initializer_list<mrb_value> v) {
        mrb_value a = mrb_ary_new_capa(M, (mrb_int)v.size());
        for (mrb_value x : v) mrb_ary_push(M, a, x);
        return a;
      }
      static mrb_value SA(mrb_state* M, std::initializer_list<mrb_value> v) {
        mrb_value a = mrb_obj_new(M, mrb_class_get(M, "SubArray"), 0, NULL);
        for (mrb_value x : v) mrb_ary_push(M, a, x);
        return a;
      }
      static mrb_value SS(mrb_state* M, const char* s) {
        mrb_value str = mrb_obj_new(M, mrb_class_get(M, "SubString"), 0, NULL);
        mrb_str_cat_cstr(M, str, s);
        return str;
      }
      static mrb_value sing_size(mrb_state* M, mrb_value) { return mrb_int_value(M, 99); }
      static mrb_value SING(mrb_state* M, const char* s) {
        mrb_value str = mrb_str_new_cstr(M, s);
        mrb_define_singleton_method(M, mrb_obj_ptr(str), "size", sing_size, MRB_ARGS_NONE());
        mrb_define_singleton_method(M, mrb_obj_ptr(str), "length", sing_size, MRB_ARGS_NONE());
        return str;
      }
      static mrb_value BIGS(mrb_state* M, int n) { return mrb_str_new(M, std::string((size_t)n, 'a').data(), n); }
      static mrb_value REC(mrb_state* M) { mrb_value a = A(M, {I(1)}); mrb_ary_push(M, a, a); return a; }
      static mrb_value FRZ(mrb_state* M, mrb_value v) { mrb_obj_freeze(M, v); return v; }
      static mrb_value OBJ(mrb_state* M) { return mrb_obj_new(M, M->object_class, 0, NULL); }
      static mrb_value BIG(mrb_state* M, int n) { mrb_value a = A(M, {}); for (int i = 0; i < n; i++) mrb_ary_push(M, a, I(i)); return a; }
      static std::string show(mrb_state* M, mrb_value v) {
        mrb_value s = mrb_inspect(M, v);
        return std::string(RSTRING_PTR(s), (size_t)RSTRING_LEN(s));
      }
      struct RefCtx { mrb_value recv, arg; const char* name; int argc; mrb_value out; };
      static mrb_value run_ref(mrb_state* M, void* ud) {
        RefCtx* c = (RefCtx*)ud;
        c->out = c->argc ? mrb_funcall(M, c->recv, c->name, 1, c->arg) : mrb_funcall(M, c->recv, c->name, 0);
        return c->out;
      }
    CPP
    NativeCoreDirect::HELPERS.each_value { |text| harness << text << "\n" }
    cases.each_key do |fn|
      recv, arg, dest = registers.fetch(fn)
      harness << <<~CPP
        struct Ctx_#{fn} { mrb_value recv, arg, out; };
        static mrb_value run_#{fn}(mrb_state* M, void* ud) {
          Ctx_#{fn}* ctx = (Ctx_#{fn}*)ud;
          mrb_value #{recv} = ctx->recv;
          mrb_value #{arg == recv ? 'unused_arg' : arg} = ctx->arg;
          mrb_value #{dest == recv || dest == arg ? 'unused_dest' : dest} = mrb_nil_value();
          #{snippets.fetch(fn)}
          ctx->out = #{dest};
          return ctx->out;
        }
      CPP
    end
    harness << <<~CPP
      int main() {
        mrb_state* M = mrb_open_core();
        mrb_define_class(M, "SubArray", M->array_class);
        mrb_define_class(M, "SubString", M->string_class);
        int bad = 0, n = 0;
    CPP
    cases.each do |fn, spec|
      spec[:recv].each do |recv_src|
        spec[:args].each do |arg_src|
          harness << <<~CPP
            {
              ++n;
              mrb_value a_ref = #{recv_src}, b_ref = #{arg_src || 'NIL'};
              mrb_value a_dir = #{recv_src}, b_dir = #{arg_src || 'NIL'};
              RefCtx ref = { a_ref, b_ref, "#{spec[:name]}", #{arg_src ? 1 : 0}, NIL };
              mrb_bool ref_raised = FALSE;
              mrb_value ref_result = mrb_protect_error(M, run_ref, &ref, &ref_raised);
              Ctx_#{fn} ctx = { a_dir, b_dir, NIL };
              mrb_bool raised = FALSE;
              mrb_value result = mrb_protect_error(M, run_#{fn}, &ctx, &raised);
              std::string want = std::string(ref_raised ? "raise " : "") + show(M, ref_raised ? ref_result : ref.out) + " / " + show(M, a_ref);
              std::string got = std::string(raised ? "raise " : "") + show(M, raised ? result : ctx.out) + " / " + show(M, a_dir);
              if (got != want) {
                std::printf("DIFF #{fn} #{recv_src.dump[1..-2].gsub('%', '%%')} #{arg_src.to_s.dump[1..-2].gsub('%', '%%')}\\n  want %s\\n  got  %s\\n", want.c_str(), got.c_str());
                ++bad;
              }
            }
          CPP
        end
      end
    end
    harness << <<~CPP
        std::printf("compared %d cases, %d differ\\n", n, bad);
        mrb_close(M);
        return bad ? 1 : 0;
      }
    CPP
    source = File.join(dir, 'core_direct.cpp')
    File.write(source, harness)
    binary = File.join(dir, 'core_direct')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                   "-I#{core}/include", "-I#{root}/3rd/mruby/include", source, "#{core}/lib/libmruby_core.a", '-o', binary)
    check.call('the emitted arms compile against real mruby headers', built)
    utf8 = File.join(dir, 'utf8.cpp')
    File.write(utf8, "#include <mruby.h>\n#include <mruby/string.h>\n" +
                     NativeCoreDirect::HELPERS.values_at('bc2cpp_str_size', 'bc2cpp_str_length').join("\n"))
    check.call('the String size helpers also compile with MRB_UTF8_STRING defined (their send branch)',
               Bc2cppCxx.system('-std=c++17', '-fsyntax-only', '-Werror', '-DMRB_UTF8_STRING', "-I#{core}/include",
                      "-I#{root}/3rd/mruby/include", utf8))
    if built
      output = IO.popen(binary, err: %i[child out], &:read)
      puts output.lines.first(40).map { |l| "  #{l}" }.join
      check.call('every emitted arm agrees with ordinary dispatch on results, errors and receiver state',
                 $?.success? && output.include?(' 0 differ'))
    end
  end
end

puts "\n#{failures.size} check(s) failed" unless failures.empty?
exit(failures.empty? ? 0 : 1)
