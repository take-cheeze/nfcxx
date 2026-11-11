# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'set'
require 'stringio'
require_relative 'shard_output'

# RUNTIME_HEADER: the fixed runtime prelude bc2cpp.rb prints between BEGIN and END (helpers whose text depends on the
# build, never on which owners a unit emits) goes to one header in BC2CPP_RUNTIME_HEADER_DIR that every compiled gem
# includes, instead of a copy in each gem's translation unit.
#
# The header is named by its content digest, and its items live in `bc2cpp_rt_<digest>`: gems that print the same
# runtime share one definition of each item (an `inline` function folds across translation units), and a different
# runtime text gets a different namespace, so two definitions of one name never meet. All units of a link must
# preprocess the header alike; the digest covers its text, not the -D flags.
#
# PER_UNIT_STATE: an item with a `static` mutable variable (at file scope or function-local) is one state per gem
# today, and so is every item that names one, transitively (macro bodies included). Those stay in the gem's own
# text, in place: the region is cut into runs, each run of shared items becomes one part of the header, included
# where the run stood, so the order of definitions and macros the gem compiles is unchanged.
module RuntimeHeader
  BEGIN_MARK = "/* BC2CPP_RUNTIME_BEGIN */\n"
  END_MARK = "/* BC2CPP_RUNTIME_END */\n"
  DIR_KEY = 'BC2CPP_RUNTIME_HEADER_DIR'
  PART_MACRO = 'BC2CPP_RUNTIME_PART'
  NS_PLACEHOLDER = '@BC2CPP_RT_NS@'
  # Bumped when the header's layout changes, so an old file of the same region text is not reused.
  FORMAT = 1

  class Error < StandardError; end

  module_function

  # Registered after ShardOutput and before CompactOutput: at_exit runs last-in first-out, so this reads the
  # compacted (and instrumented) text and ShardOutput splits what it leaves.
  def capture_stdout(dir)
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      original.write(rewrite(buffer.string, dir)) unless $!
    end
  end

  # The text with the marked region moved to the header in `dir`; with no `dir`, the text without the marks.
  def rewrite(text, dir)
    first = text.index(BEGIN_MARK)
    last = text.index(END_MARK)
    return text unless first && last

    head = text[0...first]
    region = text[(first + BEGIN_MARK.size)...last]
    tail = text[(last + END_MARK.size)..]
    return head + region + tail if dir.nil? || dir.empty?

    header, local = split(region, head + tail)
    return head + region + tail unless header

    digest = Digest::SHA256.hexdigest("#{FORMAT}\n#{header}")[0, 16]
    ns = "bc2cpp_rt_#{digest}"
    path = File.join(File.expand_path(dir), "bc2cpp_runtime_#{digest}.hxx")
    write_once(path, header.gsub(NS_PLACEHOLDER, ns))
    head + local.gsub(NS_PLACEHOLDER, ns).gsub('@BC2CPP_RT_PATH@', path) + tail
  end

  # [header text, the unit's own text with the part includes], or [nil, nil] when nothing can be shared. `rest` is
  # the unit's text outside the region.
  def split(region, rest = '')
    lines = region.lines
    segs = ShardOutput.segments(lines)
    local_segs = per_unit_segments(segs)
    return [nil, nil] if local_segs.size == segs.count { |s| s[:kind] == :code }

    header = String.new("// bc2cpp runtime header (RUNTIME_HEADER, runtime_header.rb): generated, shared by every compiled gem.\n")
    header << "namespace #{NS_PLACEHOLDER} {}\n"
    local = String.new
    part = 0
    run = nil
    flush = lambda do
      next unless run

      part += 1
      header << "#if #{PART_MACRO} == #{part}\n" << shared_part(run) << "#endif\n"
      local << "#define #{PART_MACRO} #{part}\n#include \"@BC2CPP_RT_PATH@\"\n#undef #{PART_MACRO}\n"
      local << "using namespace #{NS_PLACEHOLDER};\n" if part == 1
      run = nil
    end
    segs.each_with_index do |seg, i|
      if local_segs.include?(i)
        flush.call
        local << seg[:lines].join
      else
        (run ||= []) << seg
      end
    end
    flush.call
    local << overload_declarations(segs, local_segs, local + rest)
    [header, local]
  end

  # OVERLOAD_MERGE: a unit function sharing a name with a header function hides it inside the gem's namespace
  # (lookup stops at the first scope that has the name), where both were overloads of one name before. A
  # using-declaration after the last part puts the header's overloads back in that scope. A header function under
  # an #if has no unconditional declaration to name, so a clash with one stops the run.
  def overload_declarations(segs, local_segs, unit_text)
    unit_functions = ShardOutput.top_level_items(unit_text.lines).select { |item| item[:function] }.filter_map { |item| function_name(item) }.to_set
    names = []
    segs.each_with_index do |seg, i|
      next if local_segs.include?(i) || seg[:kind] != :code

      ShardOutput.top_level_items(seg[:lines]).each do |item|
        # Only a definition of the header's own namespace: an extern "C" function is one entity wherever declared.
        name = function_name(item)
        next unless item[:function] && item[:body] && name && unit_functions.include?(name) && !item[:head].match?(/extern\s*"C"/)
        raise Error, "RUNTIME_HEADER: #{name} is overloaded by the unit but declared under an #if in the header" if seg[:lines].first.match?(/\A\s*#\s*if/)

        names << name
      end
    end
    names.uniq.map { |name| "using #{NS_PLACEHOLDER}::#{name};\n" }.join
  end

  # The identifier before a function head's first `(`: top_level_items takes the last one, which a function-pointer
  # parameter (`mrb_value (*body)(...)`) fools.
  def function_name(item)
    item[:head][/\A[^(]*/][/([A-Za-z_]\w*)\s*\z/, 1]
  end

  # The indices of the code segments that keep a per-unit state or name one (PER_UNIT_STATE).
  def per_unit_segments(segs)
    macros = macro_names(segs)
    entries = segs.each_with_index.filter_map do |seg, i|
      next unless seg[:kind] == :code

      items = ShardOutput.top_level_items(seg[:lines])
      code = ShardOutput.code_text(seg[:lines]).lines
      { index: i, items: items.map { |item| item_facts(seg[:lines], code, item, macros) } }
    end
    local = entries.select { |e| e[:items].any? { |item| item[:state] } }.map { |e| e[:index] }.to_set
    loop do
      names = entries.select { |e| local.include?(e[:index]) }.flat_map { |e| e[:items].filter_map { |item| item[:name] } }.to_set
      grown = entries.select do |e|
        local.include?(e[:index]) ||
          e[:items].any? { |item| item[:ids].any? { |id| names.include?(id) } }
      end.map { |e| e[:index] }.to_set
      break if grown == local

      local = grown
    end
    local
  end

  def item_facts(lines, code, item, macros)
    text = code[item[:first]..item[:last]].join
    head = lines[item[:first]][/\A[^({=]*/]
    internal = head.match?(/\bstatic\b/) && !head.match?(/extern\s*"C"/)
    mutable_var = item[:var] && item[:body] && !head.match?(/\b(?:const|constexpr)\b/) &&
                  !head.match?(/\A\s*(?:template|struct|class|union|enum|typedef|using)\b/)
    body = text.sub(/\A[^{]*\{/, '')
    mutable_local = item[:function] && item[:body] && body.scan(/\bstatic\b[^=;{(]*/).any? { |d| !ShardOutput.constant_static?(d) }
    { name: item[:name], state: internal && (mutable_var || mutable_local), ids: expand(text.scan(/\b[A-Za-z_]\w*\b/).to_set, macros) }
  end

  # Macro name -> the identifiers of its body, so a use of the macro names what it expands to.
  def macro_names(segs)
    macros = Hash.new { |h, k| h[k] = Set.new }
    segs.each do |seg|
      seg[:lines].each do |line|
        next unless (m = line.match(/\A\s*#\s*define\s+([A-Za-z_]\w*)(.*)/))

        macros[m[1]].merge(m[2].scan(/\b[A-Za-z_]\w*\b/))
      end
    end
    macros
  end

  def expand(ids, macros)
    seen = ids.dup
    queue = ids.select { |id| macros.key?(id) }
    while (id = queue.pop)
      macros[id].each { |x| queue << x if seen.add?(x) && macros.key?(x) }
    end
    seen
  end

  # One run in the shared namespace: includes at file scope, every `static` item `inline` (one definition per link).
  def shared_part(segs)
    out = String.new
    inside = false
    toggle = lambda do |want|
      next if inside == want

      out << (want ? "namespace #{NS_PLACEHOLDER} {\n" : "} // namespace #{NS_PLACEHOLDER}\n")
      inside = want
    end
    segs.each do |seg|
      lines = seg[:lines].dup
      case seg[:kind]
      when :other
        out << lines.join
      when :include
        toggle.call(false)
        out << lines.join
      else
        if seg[:include]
          toggle.call(false)
          out << lines.grep(/\A\s*#/).join
          lines = lines.grep_v(/\A\s*#\s*include\b/)
        end
        toggle.call(true)
        ShardOutput.top_level_items(lines).each do |item|
          line = lines[item[:first]]
          lines[item[:first]] = ShardOutput.to_inline(line) if line[/\A[^({=]*/].match?(/\bstatic\b/)
        end
        out << lines.join
      end
    end
    toggle.call(false)
    out
  end

  # Gems generate in parallel (SHARED_GENERATION forks); each writes the same text, so the last rename wins harmlessly.
  def write_once(path, text)
    return if File.file?(path) && File.read(path) == text

    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.#{Process.pid}.tmp"
    File.write(temp, text)
    File.rename(temp, path)
  end
end
