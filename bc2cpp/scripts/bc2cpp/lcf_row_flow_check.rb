#!/usr/bin/env ruby
# frozen_string_literal: true

# LCF_ROW_FLOW (docs/adr/0294): a receiver the class flow proves to be an LCF::Database, a table or a
# row gets an exact-class direct call, and a field read gets its schema class.
#
# 1. Model (CRuby, the real mruby-lcf reader): what LcfRowFlow::Model says `[]` returns for every
#    schema position is a superset of what the reader returns, and the invariants the proof leans on
#    hold (Array2D#[]= re-reads a foreign entry through the table's schema).
# 2. Generated code: the real mruby-lcf mrblib plus fixtures, compiled under the wio closed world.
#    Each positive shape gets an exact-class call and each refusal (subclass, reflection, singleton
#    maker, dup, a mixed-class parameter, a block parameter, a Hash that looks like a row) keeps its
#    guard or fallback.
# 3. With BC2CPP_MRUBY_FULL and g++: the fixtures run on real mruby, interpreted and compiled, and
#    must answer alike, nil holes, absent chunks and foreign rows included. The run repeats on a
#    32-bit-`mrb_int` build (BC2CPP_MRUBY_FULL32, BC2CPP_MRBC32; scripts/bc2cpp/width_build.rb int32).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_FULL32=dir
#         BC2CPP_MRBC32=mrbc32] ruby scripts/bc2cpp/lcf_row_flow_check.rb

require 'set'
require 'stringio'
require 'tmpdir'
require_relative '../../tools/bc2cpp/lcf_row_flow'
require_relative 'fixture_runtime'

ROOT = File.expand_path('../..', __dir__)
MRBLIB = File.join(ROOT, 'mruby-lcf/mrblib')
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
NF = NumericFlow
finish = lambda do
  if failures.empty?
    puts 'bc2cpp lcf row flow check: PASS'
    exit 0
  end
  warn "bc2cpp lcf row flow check: #{failures.size} failure(s)"
  exit 1
end

# ---------------------------------------------------------------------------
puts '-- model (host)'
model = LcfRowFlow.model(MRBLIB)
db_bit = model.file_bit('LCF::Database')
check.call('the three Array1D-rooted file classes are modelled',
           %w[LCF::Database LCF::MapUnit LCF::SaveData].all? { |k| model.file_bit(k) })
check.call('a class that is not a file class has no bit', model.file_bit('LCF::Tree').nil? && model.file_bit('Array').nil?)
player_table = model.index(db_bit, :player)
player_row = model.index(player_table & ~NF::NIL, 1)
check.call('db[:player] is that table or nil (no default)',
           player_table & ~NF::NIL == model.kinds.find { |k| k.role == :table && k.path == 'DATABASE/player' }.bit &&
           player_table.anybits?(NF::NIL))
check.call('table[i] is its row or nil (a hole)',
           player_row & ~NF::NIL == model.kinds.find { |k| k.role == :row && k.path == 'DATABASE/player' }.bit && player_row.anybits?(NF::NIL))
row = player_row & ~NF::NIL
check.call('an :int field with a default reads Integer only', model.index(row, :initial_level) == NF::INT)
check.call('a :string field with a default reads String only', model.index(row, :name) == NF::STR)
check.call('an int16_array with `order` reads Hash or nil', model.index(row, :status) == (NF::HSH | NF::NIL))
check.call('a :bool field is not narrowed (false is falsy)', model.index(row, :semi_transparent) == NF::OTHER)
check.call('a lambda default is called for its class (max_level reads Integer)', model.index(row, :max_level) == NF::INT)
check.call('a name the schema does not declare is unknown', model.index(row, :no_such_field) == NF::OTHER)
check.call('a key that is not a literal is unknown', model.index(row, nil) == NF::OTHER)
check.call('an Integer chunk id reads like its name', model.index(row, 7) == NF::INT)
check.call('a receiver bit of another class contributes OTHER', model.index(row | NF::ARR, :name) == (NF::STR | NF::OTHER))
check.call('nil contributes nothing only where it raises',
           model.index(row | NF::NIL, :name) == (NF::STR | NF::OTHER) && model.index(row | NF::NIL, :name, nil_raises: true) == NF::STR)
check.call('a mask that is exactly one kind names its class',
           model.exact_owner(db_bit) == 'LCF::Database' && model.exact_owner(row) == 'LCF::Array1D' &&
           model.exact_owner(player_table & ~NF::NIL) == 'LCF::Array2D')
check.call('two kinds, or a kind with anything else, name no class',
           model.exact_owner(row | db_bit).nil? && model.exact_owner(row | NF::INT).nil?)

puts '-- model against the real reader (host)'
$VERBOSE = nil
load File.join(MRBLIB, 'lcf.rb')
load File.join(MRBLIB, 'schema.rb')
load File.join(MRBLIB, 'lcf_file.rb')
load File.join(MRBLIB, 'save_typed.rb')
load File.join(MRBLIB, 'save_typed_accessors.rb')
module LCF
  def self.cp932_to_utf8(s) = s.dup.force_encoding('Windows-31J').encode('UTF-8')
  def self.utf8_to_cp932(s) = s.encode('Windows-31J').b
end

# Every record position of the three file roots: path => its resolved elements Hash. Several paths share one
# elements constant (BGM, SE, LEARNING, ...), so a real object is matched to every path it could be.
PATH_ELEMENTS = {}
walk = lambda do |field, path|
  elements = LCF.elements_of(field)
  PATH_ELEMENTS[path] = elements
  elements.each_value do |f|
    walk.call(f, "#{path}/#{f[:name]}") if f.is_a?(Hash) && f[:elements]
  end
end
ROOTS = { LCF::Database => 'DATABASE', LCF::MapUnit => 'MAP_UNIT', LCF::SaveData => 'SAVE_DATA' }.freeze
ROOTS.each_value { |const| walk.call(LCF::Schema.const_get(const), const) }

# A row of +field+ with every nested record and table present (one row each).
def filled_row(field)
  row = LCF::Array1D.new('', field)
  LCF.elements_of(field).each do |id, f|
    case f[:type]
    when :Array1D
      row[id] = filled_row(f) if f[:elements]
    when :Array2D
      next unless f[:elements]

      table = LCF::Array2D.new('', f)
      table[1] = filled_row(f)
      row[id] = table
    end
  end
  row
end

def schema_of(value)
  value.instance_variable_get(:@schema)
end

# The bits a real value may stand for: every kind whose path has the value's elements.
def mask_of(value, model)
  case value
  when Integer then NF::INT
  when Float then NF::FLT
  when String then NF::STR
  when Array then NF::ARR
  when Hash then NF::HSH
  when nil then NF::NIL
  when LCF::File then model.file_bit(value.class.name)
  when LCF::Array1D, LCF::Array2D
    role = value.is_a?(LCF::Array1D) ? :row : :table
    elements = LCF.elements_of(schema_of(value))
    model.kinds.select { |k| k.role == role && PATH_ELEMENTS[k.path].equal?(elements) }.sum(&:bit)
  else NF::OTHER
  end
end

checked = 0
escapes = []
# A scalar is inside the prediction bit for bit; a record or table, when one of the kinds it may be is.
inside = lambda do |predicted, actual|
  kinds = actual & model.mask
  kinds.zero? ? (actual & ~predicted).zero? : (predicted & kinds).nonzero?
end
visit = lambda do |obj, root_fields|
  recv = mask_of(obj, model)
  if obj.is_a?(LCF::File) || obj.is_a?(LCF::Array1D)
    fields = obj.is_a?(LCF::File) ? root_fields : LCF.elements_of(schema_of(obj))
    fields.each_value do |f|
      value = obj[f[:name]]
      predicted = model.index(recv, f[:name])
      actual = mask_of(value, model)
      checked += 1
      escapes << "#{f[:name]}: #{value.class}" unless inside.call(predicted, actual)
      visit.call(value, root_fields) if value.is_a?(LCF::Array1D) || value.is_a?(LCF::Array2D)
    end
  elsif obj.is_a?(LCF::Array2D)
    [0, 1, 2].each do |i|
      value = obj[i]
      checked += 1
      escapes << "table[#{i}] #{value.class}" unless inside.call(model.index(recv, nil), mask_of(value, model))
      visit.call(value, root_fields) if value.is_a?(LCF::Array1D)
    end
  end
end
ROOTS.each do |klass, const|
  file = klass.new
  schema = LCF::Schema.const_get(const)
  root = filled_row(schema)
  LCF.elements_of(schema).each_key { |id| file[id] = root[id] if root.key?(id) }
  visit.call(file, LCF.elements_of(schema))
end
check.call("every field read of every DATABASE, MAP_UNIT and SAVE_DATA position is inside the model (#{checked} reads)",
           checked > 1000 && escapes.empty?)
puts "    #{escapes.first(5).join(', ')}" unless escapes.empty?

puts '-- the Array2D#[]= invariant (host, real reader)'
player_field = LCF::Schema::DATABASE[:elements][11]
skill_field = LCF::Schema::DATABASE[:elements][12]
table = LCF::Array2D.new('', player_field)
own = LCF::Array1D.new('', player_field)
own[:name] = 'Own'
table[1] = own
check.call('an entry over the same elements is kept as it is', table[1].equal?(own))
other_wrapper = LCF::Array1D.new('', { elements: LCF.elements_of(player_field) })
table[2] = other_wrapper
check.call('an entry over the same elements through another schema Hash is kept as it is', table[2].equal?(other_wrapper))
foreign = LCF::Array1D.new('', skill_field)
foreign[:name] = 'Foreign'
table[3] = foreign
stored = table[3]
check.call('an entry over another schema is re-read through the table schema',
           stored.is_a?(LCF::Array1D) && !stored.equal?(foreign) && LCF.elements_of(stored.schema).equal?(LCF.elements_of(player_field)))
check.call('the re-read entry answers with the table schema (initial_level: the default Integer)',
           stored[:name] == 'Foreign' && stored[:initial_level].is_a?(Integer))
table[4] = nil
check.call('nil stays a hole', table[4].nil?)
table[5] = foreign.to_lcf
check.call('bytes are decoded through the table schema', table[5].is_a?(LCF::Array1D) && table[5][:name] == 'Foreign')
begin
  table[6] = { name: 'x' }
  raised = false
rescue ArgumentError
  raised = true
end
check.call('an object that is not a row is refused, not stored', raised && table[6].nil?)
check.call('the table still serialises', LCF::Array2D.new(table.to_lcf, player_field)[1][:name] == 'Own')

unless ENV['MRBC']
  puts '-- generated code, fixtures on real mruby: SKIP (set MRBC to the host mrbc)'
  finish.call
end

# ---------------------------------------------------------------------------
puts '-- generated code'
PRELUDE = <<~'RUBY'
  # Stand-ins for what the native side provides (StringIO, the cp932 codecs).
  class StringIO
    def initialize(s = '')
      @s = s
      @i = 0
    end

    def eof?
      @i >= @s.bytesize
    end

    def getbyte
      b = @s.getbyte(@i)
      @i += 1 if b
      b
    end

    def read(n)
      r = @s.byteslice(@i, n) || ''
      @i += r.bytesize
      r
    end

    def ungetc(x)
      @i -= x.bytesize
    end
  end

  module LCF
    def self.cp932_to_utf8(s)
      s
    end

    def self.utf8_to_cp932(s)
      s
    end
  end
RUBY

HOST = <<~'RUBY'
  class LrHost
    attr_reader :db

    def initialize
      @db = LCF::Database.new
      schema = LCF::Schema::DATABASE[:elements][11]
      table = LCF::Array2D.new('', schema)
      one = LCF::Array1D.new('', schema)
      one[:name] = 'Hero'
      one[:initial_level] = 7
      table[1] = one
      three = LCF::Array1D.new('', schema)
      three[:name] = 'Third'
      table[3] = three
      @db[:player] = table
      nil
    end

    def name_of(i); @db[:player][i][:name]; end
    def level_plus(i); @db[:player][i][:initial_level] + 1; end
    def hole; @db[:player][99]; end
    def hole_name; @db[:player][99][:name]; end
    def absent; @db[:system]; end
    def absent_title; @db[:system][:title]; end
    def status_of(i); @db[:player][i][:status]; end
    def narrowed_name(i)
      row = @db[:player][i]
      return 'none' unless row

      row[:name]
    end
    def helper_name(i); row_name(@db[:player][i]); end
    def row_name(row); row[:name]; end
    def has_rows?; @db.rpg2003?; end
    def shared_a; shared_name(@db[:player][1]); end
    def shared_b; shared_name({ name: 'h' }); end
    def shared_name(row); row[:name]; end
    def via_send; send(:picked, @db[:player][1]); end
    def picked(row); row[:name]; end

    def dup_name; @db.dup[:player][1][:name]; end
    def each_names
      out = []
      @db[:player].each { |_id, row| out << row[:name] }
      out
    end
    def mixed_name(flag)
      row = flag ? @db[:player][1] : { name: 'plain' }
      row[:name]
    end
    def put_foreign
      skill = LCF::Schema::DATABASE[:elements][12]
      r = LCF::Array1D.new('', skill)
      r[:name] = 'Fire'
      @db[:player][2] = r
      [@db[:player][2][:name], @db[:player][2][:initial_level]]
    end
    def put_nil
      @db[:player][1] = nil
      @db[:player][1]
    end
    def put_other
      @db[:player][4] = LCF::Array1D.new('', LCF::Schema::DATABASE[:elements][12])
      @db[:player][4][:initial_level]
    end
  end
RUBY

extra = %w[lcf.rb lcf_file.rb schema.rb].map { |f| ["lcf/#{f}", File.read(File.join(MRBLIB, f))] }
LCF_OWNERS = %w[LCF::File LCF::Database LCF::Array1D LCF::Array2D LCF::Sections].freeze
runtime = Bc2cppFixtureRuntime

# Compiles +source+ with the real mruby-lcf mrblib; returns [cpp, stderr].
compile = lambda do |source, owners, dir|
  runtime.generate(PRELUDE + source, dir, closed: true, only_owners: owners + LCF_OWNERS, extra: extra)
end

# The text of one compiled method.
method_code = lambda do |cpp, owner, name|
  chunk = cpp.split(/^(?=\/\/ \S+#\S+ \(compiled from irep \d+, \d+ insns\)$)/).find { |c| c.start_with?("// #{owner}##{name} (") }
  chunk&.split(/^static mrb_value /, 2)&.first
end
flow_lines = ->(code) { code.lines.grep(%r{// LCF_ROW_FLOW :}) }
dispatches = ->(code) { code.gsub(%r{//[^\n]*}, '').scan(/mrb_funcall|bc2cpp_send|bc2cpp_getidx/).size }

Dir.mktmpdir do |dir|
  cpp, err = compile.call(HOST, %w[LrHost], dir)
  check.call('the proof is on for the real mruby-lcf', err.include?("== LCF row flow (LCF_ROW_FLOW) ==\n  on ("))
  code = ->(name) { method_code.call(cpp, 'LrHost', name) }

  name = code.call('name_of')
  check.call('db[:player][i][:name] is three exact-class direct calls with no untyped index and no dispatch',
             flow_lines.call(name).map { |l| l[/-> (\S+)/, 1] } == %w[LCF::File#[] LCF::Array2D#[] LCF::Array1D#[]] &&
             dispatches.call(name).zero?)
  check.call('the Database is proven non-nil (only `LCF::Database.new` is ever stored): no nil test on it',
             !name.include?('mrb_nil_p(r3)') || name.index('mrb_nil_p') > name.index('LCF__File'))
  check.call('a table hole is tested for nil, and raises what dispatch would',
             name.scan(/if \(mrb_nil_p\(r3\)\) \{\s*r3 = bc2cpp_nomethod\(/).size == 2)
  plus = code.call('level_plus')
  check.call('an :int field with a default proves the `+` operand Integer (no dynamic send)',
             plus.include?('NUMERIC_OPERAND_PROOF :+') && dispatches.call(plus).zero?)
  narrowed = code.call('narrowed_name')
  check.call('`return unless row` leaves one nil test (the table read) and the row read is exactly an Array1D',
             flow_lines.call(narrowed).size == 3 && narrowed.scan('mrb_nil_p(').size == 1 &&
             flow_lines.call(narrowed).last.include?('exactly LCF::Array1D)'))
  check.call('an absent-chunk read is an exact call too', flow_lines.call(code.call('absent')).size == 1)
  rows = code.call('has_rows?')
  check.call('a Database method is a direct call with no dispatch', rows.include?('LCF__Database_rpg2003') && dispatches.call(rows).zero?)
  helper = code.call('row_name')
  check.call('a parameter every caller fills from a table read is an exact Array1D (pooled over its one call site)',
             flow_lines.call(helper).one? && dispatches.call(helper).zero?)

  check.call('a parameter one caller fills with a Hash is not an Array1D (shared by two callers)',
             flow_lines.call(code.call('shared_name')).empty? && code.call('shared_name').include?('bc2cpp_getidx('))
  check.call('a parameter reached through send(:name) is not pooled (unknown caller)',
             flow_lines.call(code.call('picked')).empty? && code.call('picked').include?('bc2cpp_getidx('))
  dup = code.call('dup_name')
  check.call('a value made by dup is not a proven file (dispatch stays)', flow_lines.call(dup).empty? && dispatches.call(dup).positive?)
  each = code.call('each_names')
  check.call('a block parameter of Array2D#each is not proven a row', flow_lines.call(each).none? { |l| l.include?('LCF::Array1D#[]') })
  mixed = code.call('mixed_name')
  check.call('a row that may be a Hash keeps the class-gated index',
             flow_lines.call(mixed).none? { |l| l.include?('LCF::Array1D#[]') } && mixed.include?('bc2cpp_getidx('))
  put_foreign = code.call('put_foreign')
  check.call('a row replaced through `[]=` does not widen what a read is proven to be',
             flow_lines.call(put_foreign).any? { |l| l.include?('LCF::Array1D#[]') })
end

refusal = lambda do |extra_source, why, reason|
  Dir.mktmpdir do |dir|
    _cpp, err = compile.call("#{HOST}\n#{extra_source}", %w[LrHost], dir)
    said = err[/== LCF row flow \(LCF_ROW_FLOW\) ==\n  (.*)/, 1].to_s
    check.call("the proof is off (#{reason}) when #{why}", said.start_with?('off:') && said.include?(reason))
    puts "    #{said}" unless said.include?(reason)
  end
end
refusal.call("class LrRow < LCF::Array1D; end\n", 'a subclass of Array1D exists', 'LCF::Array1D has a subclass')
refusal.call("class LrTable < LCF::Array2D; end\n", 'a subclass of Array2D exists', 'LCF::Array2D has a subclass')
refusal.call("class LrDb < LCF::Database; end\n", 'a subclass of Database exists', 'LCF::Database has a subclass')
refusal.call("class LrPoke\n  def go(o); o.instance_variable_set(:@data, []); end\nend\n",
             'reflection names an ivar the model relies on', 'ivar data is written by name')
refusal.call("class LrSingle\n  def go(o); def o.[](k); 1; end; end\nend\n",
             'an instance can gain a singleton method', 'instances may gain singleton methods')
refusal.call("module LCF\n  class Array2D\n    def [](i); 1; end\n  end\nend\n",
             '`Array2D#[]` is defined a second time', 'LCF::Array2D#[] is not defined exactly once')
refusal.call("module LCF\n  class Array2D\n    def []=(i, v); @data[i] = v; end\n  end\nend\n",
             '`Array2D#[]=` (the invariant) is redefined', 'LCF::Array2D#[]= is not defined exactly once')

# ---------------------------------------------------------------------------
puts '-- fixtures on real mruby, interpreted and compiled'
# [label, build dir, mrbc, extra flags]
builds = []
builds << ['mrb_int 64', runtime.full, ENV['MRBC'], ''] if runtime.full
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
  builds << ['mrb_int 32 (MRB_INT32)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'],
             '-DMRB_32BIT -DMRB_INT32 -no-pie -DMRB_USE_BIGINT']
end
if builds.empty? || !runtime.compiler?
  puts '  SKIP run: set BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems, from the patched 3rd/mruby) and have g++'
else
  builds.each do |label, full, mrbc, flags|
    puts "  -- #{label}"
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
    ENV['MRBC'] = mrbc
    ENV['BC2CPP_CXXFLAGS'] = flags
    begin
      Dir.mktmpdir do |dir|
        owners = %w[LrHost] + LCF_OWNERS
        _code, err = compile.call(HOST, %w[LrHost], dir)
        calls = %w[name_of level_plus narrowed_name helper_name status_of].flat_map do |meth|
          [1, 2, 3, 99].map { |i| "        one(M, \"#{meth}(#{i})\", host, \"#{meth}\", #{i});" }
        end
        body = <<~CPP
          static void one(mrb_state* M, const char* label, mrb_value host, const char* meth, int n) {
            mrb_value arg = mrb_fixnum_value(n);
            call(M, label, host, meth, 1, &arg);
          }
          static int scenario(mrb_state* M) {
            mrb_value host = mrb_obj_new(M, mrb_class_get(M, "LrHost"), 0, nullptr);
          #{calls.join("\n")}
            call(M, "hole", host, "hole");
            call(M, "hole_name", host, "hole_name");
            call(M, "absent", host, "absent");
            call(M, "absent_title", host, "absent_title");
            call(M, "has_rows?", host, "has_rows?");
            call(M, "shared_a", host, "shared_a");
            call(M, "shared_b", host, "shared_b");
            call(M, "via_send", host, "via_send");
            call(M, "dup_name", host, "dup_name");
            call(M, "each_names", host, "each_names");
            mrb_value t = mrb_true_value(), f = mrb_false_value();
            call(M, "mixed_name(true)", host, "mixed_name", 1, &t);
            call(M, "mixed_name(false)", host, "mixed_name", 1, &f);
            call(M, "put_foreign", host, "put_foreign");
            mrb_value two = mrb_fixnum_value(2), one_ = mrb_fixnum_value(1);
            call(M, "name_of(2) after put_foreign", host, "name_of", 1, &two);
            call(M, "put_other", host, "put_other");
            call(M, "put_nil", host, "put_nil");
            call(M, "name_of(1) after put_nil", host, "name_of", 1, &one_);
            return 0;
          }
        CPP
        built, output = runtime.run(dir, err, owners, body, build: full, full: true)
        check.call('the fixture compiles and runs against real mruby', built)
        puts output unless built
        if built
          sections = runtime.sections(output)
          values = ->(section) { sections.fetch(section, []).reject { |l| l.start_with?('  ') } }
          check.call('every call answers what the interpreter answers, nil holes, absent chunks and foreign rows included',
                     !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
          puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
          check.call('the reads return the stored values',
                     values.call('compiled').include?('name_of(1) => "Hero"') && values.call('compiled').include?('level_plus(1) => 8'))
          check.call('a hole and an absent chunk raise NoMethodError on the next index',
                     values.call('compiled').any? { |l| l.start_with?('hole_name => raised NoMethodError') } &&
                     values.call('compiled').any? { |l| l.start_with?('absent_title => raised NoMethodError') })
        end
      end
    ensure
      saved[0] ? ENV['MRBC'] = saved[0] : ENV.delete('MRBC')
      saved[1] ? ENV['BC2CPP_CXXFLAGS'] = saved[1] : ENV.delete('BC2CPP_CXXFLAGS')
    end
  end
end

finish.call
