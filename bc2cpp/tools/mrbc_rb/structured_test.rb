# frozen_string_literal: true

# The structured seam: the irep tree the emitter hands over (MrbcRb::Result#tree, no RITE parse) must build the very Irep
# structs bc2cpp builds by parsing the serialized image, for every input of the corpus: every field of every Irep (labels from
# assign_irep_labels, instructions with their line numbers, pool, symbols, locals, file, catch handlers), plus the raw
# RiteBinary records themselves (pool and debug-info encodings included). Needs no mrbc; MRBC (the fork's mrbc) only locates the
# gem mrblib sets (<mruby>/mrbgems, <world>/3rd/*, <world>/mruby-*), as golden_test.rb does.
#   MRBC=<mrbc> bundle exec ruby bc2cpp/tools/mrbc_rb/structured_test.rb
require_relative '../bc2cpp/irep'

def same_strings?(a, b)
  a.equal?(b) || (a.is_a?(String) ? a == b && a.encoding == b.encoding : a == b)
end

# Compares the RiteIrep records field by field (Struct#== ignores String encodings).
def rite_diff(tree, parsed)
  return "irep count #{tree.size} != #{parsed.size}" unless tree.size == parsed.size

  tree.zip(parsed).each_with_index do |(a, b), i|
    RiteBinary::RiteIrep.members.each do |m|
      x = a[m]
      y = b[m]
      next if x == y && x.inspect == y.inspect # inspect shows the encoding-sensitive escapes

      return "rite irep #{i} #{m}: #{x.inspect[0, 120]} != #{y.inspect[0, 120]}"
    end
    return "rite irep #{i} iseq encoding" unless a.iseq.encoding == b.iseq.encoding
  end
  nil
end

def check(paths)
  result, = mrbc_rb_image(paths)
  return :unsupported unless result

  image = result.image
  parsed = RiteBinary.parse(image)
  diff = rite_diff(rites_from_tree(result.tree), parsed)
  return diff if diff

  structured, sroot = decode_ireps(RiteImage.new(image, rites_from_tree(result.tree)))
  from_bytes, broot = decode_ireps(RiteImage.new(image))
  return 'root label' unless sroot == broot
  return 'label order' unless structured.keys == from_bytes.keys

  structured.each do |label, irep|
    other = from_bytes.fetch(label)
    Irep::MEMBERS.each { |m| return "#{label} #{m}" unless irep[m] == other[m] }
    return "#{label} ==" unless irep == other
    return "#{label} tree" unless irep.tree.equal?(structured)
  end
  nil
end

corpus = Dir.glob('bc2cpp/**/*.rb').sort.map { |p| [p] }
oracle = ENV.fetch('MRBC', nil)
if oracle
  mruby_dir = File.expand_path('../..', oracle)
  world_root = File.expand_path('../..', mruby_dir)
  sets = { 'core mrblib' => Dir["#{mruby_dir}/mrblib/*.rb"].sort.reject { |p| p.end_with?('/10error.rb') } }
  (Dir["#{mruby_dir}/mrbgems/*"] + Dir["#{world_root}/3rd/*"] + Dir["#{world_root}/mruby-*"]).sort.each do |gem_dir|
    sets[File.basename(gem_dir)] = Dir["#{gem_dir}/mrblib/**/*.rb"].sort
  end
  sets.each_value { |files| corpus << files if files.size >= 2 }
  corpus.concat(Dir.glob("#{world_root}/**/*.rb").reject { |p| p.include?('/3rd/') || p.include?('/.git/') }.sort.map { |p| [p] })
else
  puts 'note: MRBC unset, the gem mrblib sets and the rpg-maker-clone files are not checked'
end

failures = covered = 0
corpus.each do |paths|
  verdict = check(paths)
  next if verdict == :unsupported

  covered += 1
  next unless verdict

  failures += 1
  puts "FAIL #{paths.first}#{paths.size > 1 ? " (+#{paths.size - 1})" : ''}: #{verdict}"
end
puts "structured: #{covered} of #{corpus.size} inputs covered by the emitter, #{failures} differ"
exit(failures.zero? && covered.positive? ? 0 : 1)
