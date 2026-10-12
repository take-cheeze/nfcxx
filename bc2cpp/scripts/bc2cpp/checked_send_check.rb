#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check CHECKED_SEND (docs/adr/0299): the by-name call of a real SEND / SSEND instruction does what
# OP_SEND / OP_SSEND do before calling, which mrb_funcall does not -- an explicit-receiver send of a
# private or protected method raises NoMethodError, and an attr_reader called with arguments raises
# ArgumentError.
#
# 1. Slot table: SymbolCache gives a checked call its own slot and emits the check only when used.
# 2. Generated code (needs MRBC): which sites are marked, and which keep the plain call.
# 3. Behaviour on real mruby (needs MRBC, a mruby build and g++): interpreted and compiled answer
#    alike -- values, exception classes and messages -- on a 64-bit full-core build, a core-only
#    build, and (BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32) a 32-bit `mrb_int` build.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/checked_send_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/symbol_cache'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

# -- 1. the slot table ---------------------------------------------------------------------

puts '== the slot table'
table = SymbolCache::Table.new
rewritten = SymbolCache.rewrite(<<~CPP, table)
  r1 = mrb_funcall(M, r2, "x", 0);
  r1 = bc2cpp_funcall_explicit(M, r2, "x", 1, r3);
  r1 = bc2cpp_funcall_noarg(M, self, "x", 1, r3);
  r1 = mrb_funcall(M, r2, "x", 0);
CPP
check.call('a checked call gets a slot of its own, apart from the plain call of the same name',
           rewritten.lines.map { |l| l[/bc2cpp_send\(M, \S+ (\d+),/, 1] } == %w[0 1 2 0] &&
             table.literals == ['"x"', '"x"', '"x"'] && table.checks.map(&:to_i) == [0, 2, 1])
check.call('the check helper and the slot flags are emitted only when a site uses them',
           SymbolCache.emit(table).include?('static const unsigned char bc2cpp_sym_check[3] = { 0, 2, 1 };') &&
             SymbolCache.emit(table).include?('bc2cpp_check_send(M, recv') &&
             !SymbolCache.emit(SymbolCache::Table.new).include?('bc2cpp_check_send'))

# -- fixture ---------------------------------------------------------------------------------

FIXTURE = <<~'RUBY'
  class CsBox
    attr_reader :val
    attr_accessor :acc

    def initialize
      @val = :v
      @acc = :a
    end

    def pub
      :pub
    end

    def pub1(x)
      x
    end

    private

    def secret
      :secret
    end

    protected

    def guarded
      :guarded
    end
  end

  class CsUser
    def explicit_private(o)
      o.secret
    end

    def explicit_protected(o)
      o.guarded
    end

    def explicit_public(o)
      o.pub
    end

    def reader_args(o, x)
      o.val(x)
    end

    def reader_plain(o)
      o.val
    end

    def writer_args(o)
      o.acc = 1
    end

    def call_pub1(o, x)
      o.pub1(x)
    end
  end

  class CsBase
    attr_reader :val

    def initialize
      @val = :sv
    end

    private

    def secret
      :ssecret
    end
  end

  class CsSelf < CsBase
    def implicit_secret
      secret
    end

    def self_secret
      self.secret
    end

    def implicit_reader_args
      val(1)
    end

    def implicit_reader
      val
    end

    def other_secret(o)
      o.secret
    end
  end

  class CsGhost
    def method_missing(name, *args)
      name == :secret ? :ghost_secret : super
    end

    def respond_to_missing?(name, include_private = false)
      name == :secret || super
    end
  end
RUBY
OWNERS = %w[CsUser CsSelf].freeze

# The level of slot `index` in the generated `bc2cpp_sym_check` table.
level_of = lambda do |code, index|
  code[/static const unsigned char bc2cpp_sym_check\[\d+\] = \{ ([^}]*) \}/, 1].to_s.split(', ')[index].to_i
end

# The text of one compiled method, from its header to the next one.
chunk = lambda do |code, owner_method|
  code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
end

# -- 2. generated code -----------------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  [true, false].each do |closed|
    world = closed ? 'closed world' : 'open world'
    Dir.mktmpdir do |dir|
      code, = runtime.generate(FIXTURE, dir, closed: closed, only_owners: OWNERS)
      marked = ->(text) { SymbolCache.send_indices(text).size }
      %w[CsUser#explicit_private CsUser#explicit_protected CsUser#reader_args CsSelf#other_secret].each do |m|
        text = chunk.call(code, m)
        check.call("#{world}: #{m} (an explicit-receiver SEND) calls through a level-2 slot",
                   marked.call(text).positive? && text.match?(/bc2cpp_send\(M, r\d+, (\d+),/) &&
                     text.scan(/bc2cpp_send\(M, r\d+, (\d+),/).flatten.any? { |i| level_of.call(code, i.to_i) == 2 })
      end
      text = chunk.call(code, 'CsSelf#implicit_reader_args')
      check.call("#{world}: an implicit-self send of an attr_reader name with an argument calls through a level-1 slot",
                 text.scan(/bc2cpp_send\(M, self, (\d+),/).flatten.any? { |i| level_of.call(code, i.to_i) == 1 })
      %w[CsUser#reader_plain CsSelf#implicit_reader].each do |m|
        text = chunk.call(code, m)
        check.call("NEG: #{world}: #{m} passes no argument and stays off the checked path where it is by name",
                   text.scan(/bc2cpp_send\(M, \S+, (\d+),/).flatten.none? { |i| level_of.call(code, i.to_i) == 1 })
      end
      check.call("#{world}: the helper is emitted once a checked site exists",
                 code.include?('static void bc2cpp_check_send(mrb_state* M') && code.include?('bc2cpp_visibility_error'))
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 3. behaviour ----------------------------------------------------------------------------

BODY = <<~'CPP'
  // The value, or the exception class and message.
  static void cs_call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                      const mrb_value* argv = nullptr) {
    mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
    if (M->exc) {
      mrb_value e = mrb_obj_value(M->exc);
      M->exc = nullptr;
      mrb_value msg = (mrb_funcall)(M, e, "message", 0);
      std::printf("%s => raised %s: %.*s\n", label, mrb_obj_classname(M, e), (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
    } else {
      show(M, label, r);
    }
  }
  static int scenario(mrb_state* M) {
    // mruby's mrblib (absent from a bare core) defines these.
    if (!mrb_class_defined(M, "NameError")) mrb_define_class(M, "NameError", M->eStandardError_class);
    if (!mrb_class_defined(M, "NoMethodError")) mrb_define_class(M, "NoMethodError", mrb_class_get(M, "NameError"));
    mrb_value user = mrb_obj_new(M, mrb_class_get(M, "CsUser"), 0, nullptr);
    mrb_value self_obj = mrb_obj_new(M, mrb_class_get(M, "CsSelf"), 0, nullptr);
    mrb_value box = mrb_obj_new(M, mrb_class_get(M, "CsBox"), 0, nullptr);
    mrb_value ghost = mrb_obj_new(M, mrb_class_get(M, "CsGhost"), 0, nullptr);
    mrb_value one = mrb_fixnum_value(1), five = mrb_fixnum_value(5);
    mrb_value a_box[] = { box }, a_self[] = { self_obj }, a_ghost[] = { ghost };
    mrb_value a_box_one[] = { box, one }, a_box_five[] = { box, five };
    cs_call(M, "explicit_private(box)", user, "explicit_private", 1, a_box);
    cs_call(M, "explicit_protected(box)", user, "explicit_protected", 1, a_box);
    cs_call(M, "explicit_public(box)", user, "explicit_public", 1, a_box);
    cs_call(M, "reader_args(box)", user, "reader_args", 2, a_box_one);
    cs_call(M, "reader_plain(box)", user, "reader_plain", 1, a_box);
    cs_call(M, "writer(box)", user, "writer_args", 1, a_box);
    cs_call(M, "call_pub1(box)", user, "call_pub1", 2, a_box_five);
    cs_call(M, "explicit_private(ghost)", user, "explicit_private", 1, a_ghost);
    cs_call(M, "implicit_secret", self_obj, "implicit_secret");
    cs_call(M, "self_secret", self_obj, "self_secret");
    cs_call(M, "implicit_reader", self_obj, "implicit_reader");
    cs_call(M, "implicit_reader_args", self_obj, "implicit_reader_args");
    cs_call(M, "other_secret(self_obj)", self_obj, "other_secret", 1, a_self);
    cs_call(M, "other_secret(box)", self_obj, "other_secret", 1, a_box);
    cs_call(M, "other_secret(ghost)", self_obj, "other_secret", 1, a_ghost);
    return 0;
  }
CPP

builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['mrb_int 64, full-core', full, true, ENV['MRBC'], ''] if full
builds << ['mrb_int 64, core only', runtime.core, false, ENV['MRBC'], ''] if runtime.core
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
  builds << ['mrb_int 32, full-core', ENV['BC2CPP_MRUBY_FULL32'], true, ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie']
end
builds.clear unless ENV['MRBC'] && runtime.compiler?
puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or BC2CPP_MRUBY_CORE) and have g++' if builds.empty?

values = ->(sections, name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }

builds.each do |label, build, full_flag, mrbc, flags|
  [true, false].each do |closed|
    next unless closed || label == builds.first.first

    puts "== fixture on real mruby (#{label}, #{closed ? 'closed' : 'open'} world), interpreted and compiled"
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
    ENV['MRBC'] = mrbc
    ENV['BC2CPP_CXXFLAGS'] = [saved.last, flags].compact.reject(&:empty?).join(' ')
    begin
      Dir.mktmpdir do |dir|
        _code, err = runtime.generate(FIXTURE, dir, closed: closed, only_owners: OWNERS)
        built, output = runtime.run(dir, err, OWNERS, BODY, build: build, full: full_flag)
        check.call('the fixture compiles and runs against real mruby', built)
        next unless built

        sections = runtime.sections(output)
        interpreted = values.call(sections, 'interpreted')
        compiled = values.call(sections, 'compiled')
        puts output if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
        check.call("compiled answers what the interpreter answers (#{interpreted.size} calls)",
                   interpreted.size == 15 && interpreted == compiled)
        text = interpreted.join("\n")
        # mrb_open_core has no usable exception messages: the texts are pinned on full-core builds.
        if full_flag
          check.call('an explicit-receiver send of a private method raises its NoMethodError',
                     text.include?("explicit_private(box) => raised NoMethodError: private method 'secret' called for") &&
                       text.include?("other_secret(self_obj) => raised NoMethodError: private method 'secret' called for"))
          check.call('an explicit-receiver send of a protected method raises its NoMethodError',
                     text.include?("explicit_protected(box) => raised NoMethodError: protected method 'guarded' called for"))
          check.call('an attr_reader called with an argument raises ArgumentError, with or without self',
                     text.include?('reader_args(box) => raised ArgumentError: wrong number of arguments (given 1, expected 0)') &&
                       text.include?('implicit_reader_args => raised ArgumentError: wrong number of arguments (given 1, expected 0)'))
        end
        check.call('the public sends, the implicit and self. private sends and the method_missing receiver answer',
                   text.include?('explicit_public(box) => :pub') && text.include?('reader_plain(box) => :v') &&
                     text.include?('call_pub1(box) => 5') && text.include?('implicit_secret => :ssecret') &&
                     text.include?('self_secret => :ssecret') && text.include?('implicit_reader => :sv') &&
                     text.include?('explicit_private(ghost) => :ghost_secret') && text.include?('writer(box) => 1'))
      end
    ensure
      ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
    end
  end
end

if failures.empty?
  puts 'bc2cpp checked send check: PASS'
else
  warn "bc2cpp checked send check: #{failures.size} failure(s)"
  exit 1
end
