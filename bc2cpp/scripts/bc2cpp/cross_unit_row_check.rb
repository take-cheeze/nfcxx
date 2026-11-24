#!/usr/bin/env ruby
# frozen_string_literal: true

# CROSS_UNIT_ROW (tools/bc2cpp/codegen_emit.rb, CodeGen#other_unit_direct_entry): an owner call may carry a direct
# row for a method another compiled gem emits, through that gem's exported thunk. The row is only sound when it
# is what the defining gem registers, so in a closed build's generated sources every row naming a thunk:
#   - names a thunk exactly one gem defines, forwarding to that gem's entry wrapper;
#   - carries the aspec and visibility of what the defining gem itself says about that entry: every registration
#     (mrb_define_method or a ROM mrb_mt_entry) and every local row it carries for the wrapper. A left-out entry with
#     neither is counted as unchecked;
#   - is not a row of the defining gem itself (that gem names the wrapper, not the thunk).
# The parser is checked first against a source pair with a mismatched aspec, which it must reject.
#
#   ruby scripts/bc2cpp/cross_unit_row_check.rb <closed-build-dir>

ROW = /BC2CPP_OWNER_DIRECT\("([^"]+)", bc2cpp_xrow_([A-Za-z0-9_$]+), (.*?), (MRB_METHOD_(?:PUBLIC|PRIVATE)_FL)\)/
THUNK = /^mrb_value bc2cpp_xrow_([A-Za-z0-9_$]+)\(mrb_state\* M, mrb_value self\) \{ return ([A-Za-z0-9_$]+)\(M, self\); \}$/

# Every registration aspec of `entry` in `text`.
def registration_aspecs(text, entry)
  e = Regexp.escape(entry)
  text.scan(/mrb_define_(?:private_)?method(?:_id)?\(M, [^;]*?, #{e}, (MRB_ARGS_[^;]*?)\);/).flatten +
    text.scan(/MRB_MT_ENTRY\w*\(#{e}, [^,]+, (MRB_ARGS_.*?)\)\s*$/).flatten
end

# The [aspec, visibility] pairs `text`'s own rows give the wrapper `entry`.
def local_rows(text, entry)
  e = Regexp.escape(entry)
  text.scan(/BC2CPP_OWNER_DIRECT\("[^"]+", #{e}, (.*?), (MRB_METHOD_(?:PUBLIC|PRIVATE)_FL)\)/).map { |a, v| [a.strip, v] }
end

# [failures, unchecked rows] for the generated sources `texts` ({ gem => text }).
def failures(texts)
  out = []
  unchecked = []
  thunks = Hash.new { |h, k| h[k] = [] }
  texts.each { |gem, text| text.scan(THUNK) { |name, target| thunks[name] << [gem, target] } }
  texts.each do |gem, text|
    text.scan(ROW).uniq.each do |owner, entry, aspec, vis|
      defs = thunks[entry]
      unless defs.size == 1 && defs[0][1] == entry
        out << "#{gem}: row #{owner} bc2cpp_xrow_#{entry}: #{defs.size} thunk definition(s) #{defs.inspect}"
        next
      end
      home = defs[0][0]
      out << "#{gem}: row #{owner} #{entry} names its own gem's thunk" if home == gem
      regs = registration_aspecs(texts[home], entry).map(&:strip).uniq
      locals = local_rows(texts[home], entry).uniq
      if regs.empty? && locals.empty?
        unchecked << "#{owner} #{entry}"
        next
      end
      bad = regs.reject { |r| r == aspec.strip }
      out << "#{gem}: row #{owner} #{entry} aspec #{aspec} vs #{home} registration #{bad.join(', ')}" unless bad.empty?
      wrong = locals.reject { |pair| pair == [aspec.strip, vis] }
      out << "#{gem}: row #{owner} #{entry} #{aspec}/#{vis} vs #{home}'s own row #{wrong.inspect}" unless wrong.empty?
    end
  end
  [out, unchecked.uniq]
end

bad_pair = {
  'a' => "  r1 = bc2cpp_owner_call(M, r1, BC2CPP_OWNERS_D(3, 0, BC2CPP_OWNER_DIRECT(\"G::X\", bc2cpp_xrow_G__X_f, " \
         'MRB_ARGS_REQ(1), MRB_METHOD_PUBLIC_FL), "G::X"), nullptr, 1, r2);',
  'b' => "mrb_value bc2cpp_xrow_G__X_f(mrb_state* M, mrb_value self) { return G__X_f(M, self); }\n" \
         "  mrb_define_method(M, c, \"f\", G__X_f, MRB_ARGS_REQ(2));\n"
}
abort 'cross_unit_row: FAIL the check accepts a row whose aspec differs from the registration' if failures(bad_pair)[0].empty?

dir = ARGV.fetch(0) { abort 'usage: cross_unit_row_check.rb <closed-build-dir>' }
# A sharded gem's output is its *_gen.cpp and *_gen_shard<N>.cpp (ShardOutput): one gem, several files.
sources = Dir[File.join(dir, 'mrbgems/*-compiled/*_gen{,_shard*}.cpp')].sort
abort "cross_unit_row: no generated sources under #{dir}/mrbgems" if sources.empty?

texts = sources.group_by { |path| File.basename(File.dirname(path)) }.transform_values { |paths| paths.map { |p| File.read(p) }.join("\n") }
rows = texts.values.sum { |t| t.scan(ROW).uniq.size }
found, unchecked = failures(texts)
found.each { |f| puts "  FAIL #{f}" }
abort "cross_unit_row: #{found.size} failure(s) over #{rows} row(s)" unless found.empty?
abort 'cross_unit_row: FAIL no cross-unit row in the build (the prediction never fired)' if rows.zero?
unchecked.each { |u| puts "  unchecked (left out, no local row): #{u}" }
puts "cross_unit_row: PASS (#{rows} cross-unit row(s); #{unchecked.size} entry(ies) with nothing to compare)"
