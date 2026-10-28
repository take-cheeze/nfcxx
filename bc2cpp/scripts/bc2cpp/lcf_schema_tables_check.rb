#!/usr/bin/env ruby
# frozen_string_literal: true

# SCHEMA_TABLES (mruby-lcf/gen_schema_tables.rb, mruby-lcf/src/schema_tables.hxx): the `elements:` lambdas of
# mrblib/schema.rb folded to byte tables must decode to exactly what the lambdas build.
#
#   fold       every lambda is replaced by its table number and nothing else changes: same line count, the file
#              parses, no lambda is left in the build's copy
#   reference  a Ruby decoder of the wire format gives back, for each table, the Hash the lambda returns, with the
#              same keys in the same order, and a reference to one of LCF::Schema's own constants stays that object
#   native     the C++ decoder the gem links, run by a real mruby over the folded schema.rb, builds the same tables:
#              the whole of LCF::Schema, walked with each placeholder resolved (a lambda called under CRuby,
#              LCF.schema_table under mruby), prints the same text from both, shared constants included
#   size       the tables and the strings are a fraction of the lambdas' bytecode
#
# Needs a full-core libmruby for the native half (BC2CPP_MRUBY_FULL or BC2CPP_FULL_BUILD_DIR) and a host mrbc for the
# bytecode size.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require 'open3'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../mruby-lcf/gen_schema_tables'

suite = FixtureCheck.new('lcf_schema_tables_check')
ROOT_DIR = File.expand_path('../..', __dir__)
SCHEMA = "#{ROOT_DIR}/mruby-lcf/mrblib/schema.rb"
LCF_RB = "#{ROOT_DIR}/mruby-lcf/mrblib/lcf.rb"

# Run under CRuby and under mruby: the text of a value, a constant that is one of the schema's shared tables as <NAME>.
DUMP = <<~'RUBY'
  def lcf_dump(o, names, out, resolve)
    case o
    when Hash
      if (n = names[o.object_id])
        out << "<#{n}>"
        return out
      end
      out << '{'
      o.each do |k, v|
        lcf_dump(k, names, out, resolve)
        out << '=>'
        v = resolve.call(v) if k == :elements && !v.is_a?(Hash) && !v.nil?
        lcf_dump(v, names, out, resolve)
        out << ','
      end
      out << '}'
    when Array
      out << '['
      o.each { |v| lcf_dump(v, names, out, resolve); out << ',' }
      out << ']'
    when Symbol then out << ":#{o}"
    when String then out << "S(#{o.bytes.join(' ')})"
    when Float then out << "F#{o}"
    when Integer then out << "I#{o}"
    when nil then out << 'nil'
    when true then out << 'true'
    when false then out << 'false'
    else raise "dump: #{o.class}"
    end
    out
  end
  def lcf_dump_schema(resolve, tables)
    names = {}
    # Two names for one table (SAVE_EVENT_EXEC_STATE is SAVE_FOREGROUND_EVENT): the first by name.
    LCF::Schema.constants.sort.each do |c|
      v = LCF::Schema.const_get(c)
      names[v.object_id] ||= c.to_s if v.is_a?(Hash) && !v.key?(:type) && !v.empty?
    end
    lines = []
    tables.each_with_index { |t, i| lines << "table #{i} #{lcf_dump(t, names, +'', resolve)}" }
    LCF::Schema.constants.sort.each do |c|
      v = LCF::Schema.const_get(c)
      own = names.reject { |id, _| id == v.object_id }
      lines << "const #{c} #{lcf_dump(v, own, +'', resolve)}"
    end
    lines.join("\n")
  end
RUBY

Dir.mktmpdir('lcf-schema-tables') do |dir|
  encoder = SchemaTables.generate(SCHEMA, LCF_RB, dir)
  folded = File.binread(File.join(dir, 'schema_folded.rb'))
  original = File.binread(SCHEMA)

  # --- fold ----------------------------------------------------------------------------------------------
  nodes = SchemaTables.lambda_nodes(original)
  suite.check("schema.rb has the 18 `elements:` lambdas the docs count (#{nodes.size})", nodes.size == 18)
  suite.check('the folded schema.rb keeps every line (the note is two lines at the end)',
              folded.lines.size == original.lines.size + 2)
  suite.check('the folded schema.rb parses and holds no `elements:` lambda',
              Prism.parse(folded).errors.empty? && SchemaTables.lambda_nodes(folded).empty?)
  orig_lines = original.lines
  changed = folded.lines.first(orig_lines.size).each_with_index.reject { |l, i| l == orig_lines[i] }.map(&:last)
  suite.check('only the lines of the lambdas differ', changed.all? { |i| orig_lines[i].include?('->') || nodes.any? { |n| (n.location.start_line - 1..n.location.end_line - 1).cover?(i) } })

  # --- reference decoder -----------------------------------------------------------------------------------
  # The wire format as gen_schema_tables.rb documents it, read back in Ruby, against the lambdas under CRuby.
  ref = Class.new do
    def initialize(encoder, schema)
      @pool = encoder.pool
      @schema = schema
    end

    def table(bytes)
      @bytes = bytes
      @pos = 0
      value
    end

    def varint
      v = 0
      shift = 0
      loop do
        b = @bytes[@pos]
        @pos += 1
        v |= (b & 0x7f) << shift
        return v if b < 0x80

        shift += 7
      end
    end

    def sym(i) = @pool[i].to_sym
    def zig(z) = z.odd? ? -((z + 1) >> 1) : z >> 1

    def value
      tag = @bytes[@pos]
      @pos += 1
      case tag
      when 0 then nil
      when 1 then true
      when 2 then false
      when 3 then zig(varint)
      when 4
        v = @bytes[@pos, 8].pack('C*').unpack1('E')
        @pos += 8
        v
      when 5 then sym(varint)
      when 6 then @pool[varint].dup.force_encoding('UTF-8')
      when 7 then Array.new(varint) { value }
      when 8
        h = {}
        varint.times { k = value; h[k] = value }
        h
      when 9 then @schema.const_get(@pool[varint])
      when 11 then field
      when 12
        h = {}
        varint.times { k = varint; h[k] = value }
        h
      else raise "tag #{tag}"
      end
    end

    def field
      h = { name: sym(varint), type: sym(varint) }
      flags = @bytes[@pos]
      @pos += 1
      h[:default] = value if flags & 1 != 0
      h[:elements] = value if flags & 2 != 0
      if flags & 4 != 0
        varint.times { k = sym(varint); h[k] = value }
      end
      h
    end
  end

  # SchemaTables.generate loaded lcf.rb and schema.rb above.
  procs = {}
  LCF::Schema.constants.each { |c| SchemaTables.collect_procs(LCF::Schema.const_get(c), procs, Set.new) }
  lambdas = nodes.map { |n| procs.fetch(n.location.start_line) }
  decoder = ref.new(encoder, LCF::Schema)
  same = encoder.tables.each_with_index.all? do |bytes, i|
    want = lambdas[i].call
    got = decoder.table(bytes)
    # Hash#== ignores the order of keys; the order is checked on the text.
    got == want && got.inspect == want.inspect
  end
  suite.check('the reference decoder gives every lambda\'s Hash, keys in order', same)
  player = lambdas.index(LCF::Schema::DATABASE[:elements][11][:elements])
  decoded = decoder.table(encoder.tables.fetch(player))
  suite.check('a table that names a shared constant keeps that object (the player table\'s elements: LEARNING)',
              decoded[63][:elements].equal?(LCF::Schema::LEARNING) && lambdas[player].call[63][:elements].equal?(LCF::Schema::LEARNING))

  # --- size ------------------------------------------------------------------------------------------------
  data_bytes = encoder.tables.sum(&:size)
  pool_bytes = encoder.pool.sum { |s| s.bytesize + 1 } + 4 * (encoder.pool.size + 1)
  puts "    tables: #{encoder.tables.size} tables, #{data_bytes} bytes; strings: #{encoder.pool.size}, #{pool_bytes} bytes"
  suite.check('the tables are small (under 8 KB with the string pool under 20 KB)', data_bytes < 8_192 && pool_bytes < 20_000)

  # --- native ----------------------------------------------------------------------------------------------
  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP native decoder: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    File.write(File.join(dir, 'dump.rb'), DUMP)
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include <mruby/compile.h>
      #include <mruby/string.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <string>
      #include "schema_tables.hxx"
      static std::string slurp(const char* path) {
        std::ifstream in(path, std::ios::binary);
        return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
      }
      static mrb_value run(mrb_state* M, const std::string& code) {
        mrb_value v = mrb_load_nstring(M, code.data(), code.size());
        if (M->exc) { mrb_print_error(M); std::exit(2); }
        return v;
      }
      // The registration lcf.cxx makes under LCF_SCHEMA_TABLES.
      static mrb_value schema_table(mrb_state* M, mrb_value) {
        mrb_int i;
        mrb_get_args(M, "i", &i);
        return lcf_schema::table(M, i);
      }
      int main(int, char** argv) {
        mrb_state* M = mrb_open();
        run(M, slurp(argv[1]));  // schema_folded.rb
        run(M, slurp(argv[2]));  // dump.rb
        RClass* lcf = mrb_module_get(M, "LCF");
        mrb_define_module_function(M, lcf, "schema_table", schema_table, MRB_ARGS_REQ(1));
        // lcf_schema.hxx collects before every value (LCF_SCHEMA_STRESS): a Hash or String that is not rooted while
        // its table is built is swept, and the comparison below fails.
        mrb_value s = run(M, "tables = (0...#{encoder.tables.size}).map { |i| LCF.schema_table(i) }\\n"
                             "lcf_dump_schema(->(e) { LCF.schema_table(e) }, tables)");
        std::printf("%.*s\\n", (int)RSTRING_LEN(s), RSTRING_PTR(s));
        mrb_close(M);
        return 0;
      }
    CPP
    flags = %w[-std=c++17 -fexceptions -DMRB_USE_CXX_EXCEPTION -DLCF_SCHEMA_STRESS -w] + Bc2cppFixtureRuntime.library_defines(build)
    binary = File.join(dir, 'tables')
    built = Bc2cppCxx.system(*flags, "-I#{dir}", "-I#{ROOT_DIR}/mruby-lcf/src", "-I#{build}/include",
                             "-I#{ROOT_DIR}/3rd/mruby/include", File.join(dir, 'main.cpp'), File.join(dir, 'schema_tables.cc'),
                             "#{build}/lib/libmruby.a", '-lm', '-o', binary)
    suite.check('the native decoder builds with the generated tables', built)
    if built
      out, status = Open3.capture2e(binary, File.join(dir, 'schema_folded.rb'), File.join(dir, 'dump.rb'))
      suite.check('the native decoder runs with a full collection before every value', status.success?)
      puts out.lines.last(12).join unless status.success?
      # The same text under CRuby: a lambda is called where mruby asks the native decoder.
      eval(DUMP, TOPLEVEL_BINDING) # rubocop:disable Security/Eval
      want = lcf_dump_schema(->(e) { e.respond_to?(:call) ? e.call : e }, lambdas.map(&:call))
      got = out.chomp
      if got != want
        a = got.lines
        b = want.lines
        i = a.zip(b).index { |x, y| x != y }
        puts "    first difference at line #{i}:", "      native: #{a[i].to_s[0, 300]}", "      cruby:  #{b[i].to_s[0, 300]}" if i
      end
      suite.check('mruby builds the same tables, every constant and the shared objects included', status.success? && got == want)
      suite.check('the text is not empty (18 tables and the constants)', want.lines.size > 18 + 20)
    end
  end
end

suite.finish!
