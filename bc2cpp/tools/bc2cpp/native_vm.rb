# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'zlib'
require 'open3'
require 'tmpdir'
require_relative 'insn_decoder'

# AOT continuations for bodies whose Ruby frame semantics must survive suspension.
# The emitted branches enter VM primitives directly; no instruction bytes are retained or decoded at run time.
module NativeVM
  module_function

  def verify_schema!
    header = File.expand_path('../../3rd/mruby/include/mruby/ops.h', __dir__)
    formats = File.read(header).scan(/OPCODE\((\w+),\s*(\w+)\)/).map { |name, format| [name.to_sym, format] }
    raise 'native VM instruction schema does not match the pinned mruby' unless formats == InsnDecoder::FORMATS
  end

  def instructions(bytes, length)
    result = []
    pc = 0
    while pc < length
      start = pc
      op, format = InsnDecoder::FORMATS.fetch(bytes.fetch(pc))
      pc += 1
      ext = InsnDecoder::EXT_WIDTH[op] || 0
      if ext.positive?
        op, format = InsnDecoder::FORMATS.fetch(bytes.fetch(pc))
        pc += 1
        raise 'nested native instruction prefix' if InsnDecoder::EXT_WIDTH.key?(op)
      end
      args = InsnDecoder.operand_sizes(format, ext).map do |size|
        value = bytes.slice(pc, size).reduce(0) { |v, byte| (v << 8) | byte }
        raise 'truncated native operand' unless pc + size <= length

        pc += size
        value
      end
      result << [start, pc, op, args]
    end
    raise 'native instruction overruns program' unless pc == length

    result
  end

  def transform(source, dir)
    verify_schema!
    FileUtils.mkdir_p(dir)
    programs = []
    source = source.gsub(/static const mrb_code (\w+)_iseq_(\d+)\[\d+\] = \{([^}]+)\};/m) do
      name, number, data = Regexp.last_match.captures
      symbol = "#{name}_irep_#{number}"
      metadata = source.match(/static const mrb_irep #{Regexp.escape(symbol)} = \{\s*(\d+),(\d+),(\d+),.*?\n  (\d+),(\d+),(\d+),(\d+),0\s*\n\};/m)
      raise "missing native metadata for #{symbol}" unless metadata

      catches = metadata[3].to_i
      length = metadata[4].to_i
      bytes = data.scan(/0x([0-9a-fA-F]{2})/).flatten.map { |v| v.to_i(16) }
      raise "bad native program length for #{symbol}" unless bytes.size == length + catches * 13

      decoded = instructions(bytes, length)
      id = Zlib.crc32(symbol)
      aspec = decoded.first&.[](2) == :ENTER ? decoded.first[3].first : 0
      handlers = catches.zero? ? 'NULL' : "(const struct mrb_irep_catch_handler*)#{name}_handlers_#{number}"
      programs << { 'id' => id, 'symbol' => symbol, 'instructions' => decoded }
      output = catches.zero? ? '' : "static const uint8_t #{name}_handlers_#{number}[] = {#{bytes.drop(length).join(',')}};\n"
      output + "static const struct mrb_native_irep #{name}_native_#{number} = {#{id}u, #{aspec}u, #{handlers}};"
    end
    raise 'native compilation received no C-struct programs' if programs.empty?

    programs.each do |program|
      symbol = program.fetch('symbol')
      native = symbol.sub('_irep_', '_native_')
      source = source.sub(/(static const mrb_irep #{Regexp.escape(symbol)} = \{.*?\n  \d+,\d+,\d+,\d+,0)(\s*\n\};)/m) { "#{Regexp.last_match(1)},&#{native}#{Regexp.last_match(2)}" }
    end
    source = source.gsub(/MRB_IREP_STATIC,\w+_iseq_\d+,/, 'MRB_IREP_STATIC,(const mrb_code*)(uintptr_t)1,')
    key = programs.find { |program| program['symbol'].end_with?('_irep_0') }.fetch('symbol')
    path = File.join(dir, "#{key}.json")
    temp = "#{path}.#{Process.pid}.tmp"
    File.write(temp, JSON.generate(programs))
    File.rename(temp, path)
    source
  end

  def builtins(dir)
    file = File.expand_path('../../3rd/mruby/mrbgems/mruby-catch/src/catch.c', __dir__)
    body = File.read(file)[/static const mrb_code catch_iseq\[\] = \{(.*?)\};/m, 1]
    raise 'missing builtin catch program' unless body

    body = body.gsub(%r{//[^\n]*}, '')
    bytes = body.scan(/OP_(\w+)|0x([0-9a-fA-F]+)/).map do |op, hex|
      op ? InsnDecoder::FORMATS.index { |name, _| name.to_s == op } || raise("unknown builtin #{op}") : hex.to_i(16)
    end
    programs = [
      { 'id' => 166_470_989, 'symbol' => 'mrb_builtin_catch_irep', 'instructions' => instructions(bytes, bytes.size) },
      { 'id' => 4_206_464_619, 'symbol' => 'mrb_builtin_binding_irep', 'instructions' => [[0, 2, 'RETURN', [0]]] }
    ]
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'builtins.json'), JSON.generate(programs))
  end

  def dispatch(dir, output)
    programs = Dir[File.join(dir, '*.json')].sort.flat_map { |path| JSON.parse(File.read(path)) }
    raise 'native VM has no programs' if programs.empty?

    ids = {}
    text = +"switch (irep->native->id) {\n"
    programs.each do |program|
      id, symbol = program.values_at('id', 'symbol')
      raise "native id collision: #{symbol} and #{ids[id]}" if ids.key?(id)

      ids[id] = symbol
      text << "case #{id}u:\n  switch (mrb_irep_pc_offset(irep, ci->pc)) {\n"
      program.fetch('instructions').each do |start, after, op, args|
        text << "  case #{start}: ci->pc = mrb_irep_pc(irep, #{after}); insn = OP_#{op}; "
        args.zip(%w[a b c]).each { |value, arg| text << "#{arg} = #{value}u; " }
        text << "goto L_OP_#{op}_BODY;\n"
      end
      text << "  }\n  break;\n"
    end
    text << "}\n"
    File.write(output, text) unless File.exist?(output) && File.read(output) == text
  end

  def compile(source, name, mrbc:, dir:)
    Dir.mktmpdir('native-vm') do |work|
      input = File.join(work, 'program.rb')
      File.write(input, source)
      output, err, status = Open3.capture3(mrbc, '-S', '-s', "-B#{name}", '-o-', input)
      raise "native compiler failed: #{err}" unless status.success?

      transform(output, dir)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  NativeVM.dispatch(ARGV.fetch(0), ARGV.fetch(1))
end
