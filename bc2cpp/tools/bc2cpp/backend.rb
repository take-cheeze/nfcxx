# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative 'world_root'

# The C++ compiler and mrbbc consume the same RITE input, but own different runtimes and output formats.
module Bc2cppBackend
  class Error < StandardError; end
  CPP_INPUTS = %w[BC2CPP_BUILD_GEMS NATIVE_SRCS FOREIGN_RUBY_SRCS BC2CPP_LINKED_NATIVE_SRCS BC2CPP_LINKED_RUBY_SRCS
                  ONLY_OWNERS OTHER_OWNERS BC2CPP_TYPE_FACTS].freeze
  LOWER = File.expand_path('../build/mrbbc/mrbbc_lower', BC2CPP_TREE_ROOT).freeze

  module_function

  def dispatch!(argv)
    exit run_mrbbc(argv) if take_argv!(argv) == 'mrbbc'
  rescue Error => e
    warn "bc2cpp: #{e.message}"
    exit 2
  end

  def take_argv!(argv)
    flags = argv.each_index.select { |i| argv[i] == '--backend' || argv[i].start_with?('--backend=') }
    raise Error, 'only one --backend is allowed' if flags.size > 1

    backend = 'cpp'
    unless flags.empty?
      index = flags.first
      flag = argv.delete_at(index)
      backend = flag == '--backend' ? argv.delete_at(index) : flag.delete_prefix('--backend=')
    end
    raise Error, '--backend must be cpp or mrbbc' unless %w[cpp mrbbc].include?(backend)

    if backend == 'cpp' && argv.any? { |arg| arg.start_with?('--mrbbc-value', '--mrbbc-export-i64') }
      raise Error, '--mrbbc options require --backend=mrbbc'
    end
    backend
  end

  # IR is published only after successful lowering; mrbbc's refusal status (3) and diagnostic are preserved.
  def run_mrbbc(argv)
    value = '8'
    sources = []
    exports = []
    seen_value = false
    args = argv.dup
    until args.empty?
      arg = args.shift
      if arg == '--mrbbc-value' || arg.start_with?('--mrbbc-value=')
        raise Error, 'only one --mrbbc-value is allowed' if seen_value

        seen_value = true
        value = arg == '--mrbbc-value' ? args.shift : arg.delete_prefix('--mrbbc-value=')
        raise Error, '--mrbbc-value must be 8, 4 or 16' unless %w[8 4 16].include?(value)
      elsif arg == '--mrbbc-export-i64' || arg.start_with?('--mrbbc-export-i64=')
        name = arg == '--mrbbc-export-i64' ? args.shift : arg.delete_prefix('--mrbbc-export-i64=')
        raise Error, '--mrbbc-export-i64 requires a plain method name' unless name&.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        raise Error, "duplicate i64 export: #{name}" if exports.include?(name)

        exports << name
      elsif arg.start_with?('-')
        raise Error, "the mrbbc backend does not accept #{arg}"
      else
        sources << arg
      end
    end
    raise Error, 'usage: bc2cpp.rb --backend=mrbbc [--mrbbc-value=8|4|16] [--mrbbc-export-i64=NAME ...] file.rb [file2.rb ...]' if sources.empty?

    unsupported = CPP_INPUTS.reject { |key| ENV[key].to_s.empty? }
    unsupported << 'BC2CPP_TYPE_CHECK_ONLY' if ENV['BC2CPP_TYPE_CHECK_ONLY'] == '1'
    unsupported << 'BC2CPP_SELF_REGISTERING' if ENV['BC2CPP_SELF_REGISTERING'] == '1'
    unless unsupported.empty?
      raise Error, "the mrbbc backend cannot honor C++ build inputs: #{unsupported.join(', ')}; pass the complete Ruby program as source files"
    end

    lower = ENV['BC2CPP_MRBBC_LOWER'] || LOWER
    unless File.file?(lower) && File.executable?(lower)
      warn "bc2cpp: mrbbc lowerer not executable: #{lower}; run scripts/setup-mrbbc.sh or set BC2CPP_MRBBC_LOWER"
      return 1
    end

    require_relative 'irep'
    symbol = ENV['OUT_SYMBOL'] || File.basename(sources.first, '.rb').gsub(/[^a-zA-Z0-9_]/, '_')
    out_dir = ENV['OUT_DIR'] || File.dirname(sources.first)
    FileUtils.mkdir_p(out_dir)
    image = run_mrbc(sources, symbol, out_dir)
    # The fork appends FSTRING to stock mruby's opcodes. Refuse it explicitly instead of treating a valid fork image
    # as a malformed stock image, or silently losing frozen-string semantics in mrbbc's standalone runtime.
    rites = image.rites || RiteBinary.parse(image.bytes)
    if rites.any? { |rite| InsnDecoder.decode(rite).first.any?(&:frozen_literal) }
      warn 'refused: mrbbc backend does not lower FSTRING (frozen string literals) yet'
      return 3
    end

    output, errors, status = Open3.capture3(lower, "--value=#{value}", *exports.map { |name| "--export-i64=#{name}" },
                                          File.join(out_dir, "#{symbol}.mrb"))
    $stderr.write(errors)
    return status.exitstatus || 128 + status.termsig unless status.success?

    if output.empty?
      warn 'bc2cpp: mrbbc returned no IR'
      return 1
    end
    $stdout.write(output)
    0
  rescue SystemCallError => e
    warn "bc2cpp: mrbbc backend: #{e.message}"
    1
  end
end
