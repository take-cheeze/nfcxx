#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# CLASS_READ_INLINE (tools/bc2cpp/bc2cpp.rb's prelude, codegen_send.rb's obj_class_expr / exact_class_guard): every
# compiled class guard tests the receiver through bc2cpp_class_is, and every hoisted class read goes through
# bc2cpp_obj_class, instead of calling the out-of-line mrb_obj_class.
#
#   generated code (needs a host mrbc)
#     - the prelude defines both helpers with their class-pointer tests and the mrb_obj_class fallback, and
#       BC2CPP_CLASS_READ_INLINE=0 makes them plain mrb_obj_class calls;
#     - MONO_EMBED_GUARD, TYPED, NATIVE_OWNER_MAP, IVAR_ACCESSOR, POLY_SMALL_N, INHERITED_GUARD, POLY_INTEGER_TAG
#       and USER_RECEIVER_CASES sites all read the class through it, and no compiled method calls mrb_obj_class.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for plain instances, subclass instances, objects with a
#       singleton class, objects extended by a module, instances of a class with a prepended module, immediates
#       (Integer, Symbol, nil, true) and other classes, at every one of those guard families.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/class_read_inline_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

# CrCell embeds @v (MONO_EMBED_GUARD / IVAR_ACCESSOR); CrCell/CrB answer #kind (POLY_SMALL_N); CrA/CrB answer
# #area and CrSub inherits CrA#area (INHERITED_GUARD); #grow is answered by Integer and CrCell (POLY_INTEGER_TAG).
# CrMark and CrFront only add names nobody guards on, so extending or prepending them changes the receiver's class
# pointer, not its methods.
SRC = <<~'RUBY'
  module CrMark
    def marked; :marked; end
  end
  module CrFront
    def front; :front; end
  end
  class CrCell
    attr_reader :v
    def initialize(v); @v = v; end
    def bump(k); @v += k; self; end
    def grow(k); CrCell.new(@v + k); end
    def kind; [:cell, @v]; end
  end
  class CrA
    def initialize(w); @w = w; end
    def area; @w * 2; end
  end
  class CrB
    def initialize(w); @w = w; end
    def area; @w * 3; end
    def kind; [:b, @w]; end
  end
  class CrSub < CrA
  end
  class Integer
    def grow(k); self + k; end
  end
  class CrUse
    def initialize(cell); @cell = cell; @a = CrA.new(5); end
    def mono(k); @cell.bump(k).v; end
    def typed; @a.area; end
    def union(k); x = CrB.new(k); x = CrA.new(k) if k > 2; x.area; end
    def read(k); x = Object.new; x = CrCell.new(k) if k > 2; x.v; end
    def poly(s); s.area; end
    def kind(x); x.kind; end
    def grow(x); x.grow(1); end
    def run(items); t = 0; items.each { |s| t += s.area }; t; end
  end
RUBY

OWNERS = %w[CrCell CrA CrB CrSub CrUse Integer].freeze

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

dir = Dir.mktmpdir('bc2cpp-class-read-inline')
at_exit { FileUtils.remove_entry(dir) }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
File.write(ENV['CR_DUMP'], code) if ENV['CR_DUMP']
check.call('the prelude defines bc2cpp_obj_class with the plain-class test and the mrb_obj_class fallback',
           code.match?(/static inline struct RClass\* bc2cpp_obj_class\(mrb_state\* M, mrb_value v\) \{\n\s+if \(!mrb_immediate_p\(v\)\) \{\n\s+struct RClass\* c = mrb_obj_ptr\(v\)->c;\n\s+if \(c->tt == MRB_TT_CLASS\) return c;\n\s+\}\n\s+return mrb_obj_class\(M, v\);/))
check.call('the prelude defines bc2cpp_class_is as the class-pointer test, then bc2cpp_obj_class',
           code.match?(/static inline bool bc2cpp_class_is\(mrb_state\* M, mrb_value v, struct RClass\* cls\) \{\n\s+if \(!mrb_immediate_p\(v\) && mrb_obj_ptr\(v\)->c == cls\) return true;\n\s+return cls == bc2cpp_obj_class\(M, v\);/))
guarded = lambda do |fn, tag|
  body = code_of(code, fn)
  body.include?(tag) && body.match?(/bc2cpp_class_is\(M, r\d+, bc2cpp_owner_class_\d+\(M\)\)/)
end
check.call('MONO_EMBED_GUARD reads the class inline', guarded.call('CrUse_mono', 'MONO_EMBED_GUARD'))
check.call('TYPED reads the class inline', guarded.call('CrUse_typed', 'TYPED :area'))
check.call('IVAR_ACCESSOR reads the class inline', guarded.call('CrUse_read', 'IVAR_ACCESSOR'))
check.call('POLY_SMALL_N reads the class inline', guarded.call('CrUse_kind', 'POLY_SMALL_N'))
check.call('NATIVE_OWNER_MAP reads the class inline', guarded.call('CrUse_typed', 'NATIVE_OWNER_MAP'))
check.call('USER_RECEIVER_CASES reads the class inline',
           code_of(code, 'CrUse_union').match?(/USER_RECEIVER_CASES[^\n]*\n(?:[^\n]*\n)?\s*struct RClass\* bc2cpp_union_class = bc2cpp_obj_class\(M, r\d+\);/))
check.call('INHERITED_GUARD hoists one inline read',
           code_of(code, 'CrUse_poly').match?(/INHERITED_GUARD[^\n]*\n\s*\{\n\s*struct RClass\* bc2cpp_recv_class = bc2cpp_obj_class\(M, r\d+\);/))
check.call('POLY_INTEGER_TAG reads a non-Integer class inline',
           code_of(code, 'CrUse_grow').match?(/bc2cpp_recv_class = mrb_integer_p\(r\d+\) \? M->integer_class : bc2cpp_obj_class\(M, r\d+\);/))
methods = code.scan(/^(?:static )?mrb_value Cr\w+\(mrb_state\* M.*?(?=^\S)/m).join
check.call('no compiled method calls mrb_obj_class itself', !methods.empty? && !methods.include?('mrb_obj_class(M'))
check.call('no #error in the generated code', !code.include?('#error'))
off = Dir.mktmpdir do |off_dir|
  ENV['BC2CPP_CLASS_READ_INLINE'] = '0'
  Bc2cppFixtureRuntime.generate(SRC, off_dir, core: true, only_owners: OWNERS).first
ensure
  ENV.delete('BC2CPP_CLASS_READ_INLINE')
end
check.call('BC2CPP_CLASS_READ_INLINE=0 makes both helpers plain mrb_obj_class calls',
           off.include?('static inline struct RClass* bc2cpp_obj_class(mrb_state* M, mrb_value v) { return mrb_obj_class(M, v); }') &&
           off.include?('{ return cls == mrb_obj_class(M, v); }') && !off.include?('MRB_TT_CLASS) return c;'))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  single = CrCell.new(10)
  single.singleton_class
  extended = CrCell.new(20).extend(CrMark)
  sa = CrA.new(4)
  sa.singleton_class
  ea = CrB.new(5).extend(CrMark)
  receivers = {
    'plain' => [CrCell.new(1), CrA.new(1)],
    'subclass' => [CrCell.new(2), CrSub.new(2)],
    'singleton' => [single, sa],
    'extended' => [extended, ea],
    'integer' => [7, 7],
    'symbol' => [:s, :s],
    'nil' => [nil, nil],
    'true' => [true, true],
    'other' => [Object.new, Object.new]
  }
  probe = lambda do |label, cell, shape|
    u = CrUse.new(cell)
    show.call("#{label} mono") { u.mono(1) }
    show.call("#{label} poly") { u.poly(shape) }
    show.call("#{label} kind") { [u.kind(cell), u.kind(shape)] }
    show.call("#{label} grow") { r = u.grow(cell); r.is_a?(CrCell) ? [:cell, r.v] : r }
    show.call("#{label} run") { u.run([shape, CrB.new(1), shape]) }
    # TYPED and NATIVE_OWNER_MAP: @a is traced to CrA. Only reflection puts another object there, and one of
    # another class is a STRICT_HINTS violation by design, so this varies only the CrA instance's class pointer.
    if shape.class == CrA
      show.call("#{label} typed") { u.instance_variable_set(:@a, shape); u.typed }
    end
  end
  receivers.each { |label, (cell, shape)| probe.call(label, cell, shape) }
  show.call('union') { [CrUse.new(nil).union(1), CrUse.new(nil).union(3)] }
  show.call('read') { [CrUse.new(nil).read(1), CrUse.new(nil).read(3)] }
  # The origin case: a prepended class keeps its own class pointer on its instances.
  CrCell.prepend(CrFront)
  CrSub.prepend(CrFront)
  probe.call('prepended', CrCell.new(3), CrSub.new(3))
  probe.call('prepended singleton', CrCell.new(4).extend(CrMark), CrSub.new(4).extend(CrMark))
  show.call('union prepended') { CrUse.new(nil).union(3) }
  show.call('read prepended') { CrUse.new(nil).read(3) }
  show.call('marked') { [extended.marked, ea.marked, CrCell.new(1).front, CrSub.new(1).front] }
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"CRI(#{DRIVER})CRI";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp class read inline check: PASS'
else
  warn "bc2cpp class read inline check: #{failures.size} failure(s)"
  exit 1
end
