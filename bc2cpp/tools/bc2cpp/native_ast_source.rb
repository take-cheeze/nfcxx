# frozen_string_literal: true

# Where the bc2cpp native analyses (native_ast_returns.rb, native_core_candidates.rb, ...) get a translation unit's AST:
#   clang  `clang -fsyntax-only -Xclang -ast-dump=json` (the original producer; the fallback when nfcxx is not built);
#   nfcxx  scripts/nfcxx-ast-dump: the nfcxx (EDG) front end's own dump of function bodies, records and file-scope
#          variables, in the subset of clang's JSON that these consumers read (be/nfcxx_ast.c, docs/notes/nfcxx-ast.md).
# nfcxx is the default when its front end is built (scripts/setup-libclang-edg.sh), else clang; BC2CPP_AST_PRODUCER=clang opts
# out, =nfcxx insists. Both give the same hash shape, so the analyses are unchanged.
#
# NativeAstSource.dump(path, flags, lang: :c | :cxx, std: nil) -> [json_text, stderr, status]
require 'open3'

module NativeAstSource
  REPO_ROOT = File.expand_path('../../..', __dir__)
  PRODUCERS = %w[clang nfcxx].freeze

  module_function

  # +auto+: with no BC2CPP_AST_PRODUCER, nfcxx when it is built here, else clang (auto: false: clang unless told otherwise).
  def producer(auto: true)
    name = ENV.fetch('BC2CPP_AST_PRODUCER', '')
    name = (auto && available?('nfcxx') ? 'nfcxx' : 'clang') if name.empty?
    raise ArgumentError, "BC2CPP_AST_PRODUCER must be one of #{PRODUCERS.join(', ')}: #{name.inspect}" unless PRODUCERS.include?(name)

    name
  end

  def nfcxx_tool
    ENV.fetch('NFCXX_AST_DUMP') { File.join(REPO_ROOT, 'scripts/nfcxx-ast-dump') }
  end

  # Whether the producer can run here: clang on PATH, or the nfcxx front end built (scripts/setup-libclang-edg.sh).
  def available?(name = producer)
    case name
    when 'clang' then system('clang --version', out: File::NULL, err: File::NULL) ? true : false
    when 'nfcxx' then File.executable?(ENV.fetch('LIBCLANG_EDG_CPFE') { File.join(REPO_ROOT, 'build/libclang-edg/cmake/bin/cpfe') })
    end
  end

  # argv for a producer. lang :c is `-x c -std=gnu11`, :cxx `-std=gnu++17` (what base_rbs_native.rb always passed).
  def command(name, path, flags, lang: :cxx, std: nil)
    language = lang == :c ? ['-x', 'c', "-std=#{std || 'gnu11'}"] : ["-std=#{std || 'gnu++17'}"]
    case name
    when 'clang' then ['clang', *language, '-fsyntax-only', '-Xclang', '-ast-dump=json', *flags, path]
    when 'nfcxx' then [nfcxx_tool, *language, *flags, path]
    end
  end

  def dump(path, flags, lang: :cxx, std: nil, name: producer)
    out, err, status = Open3.capture3(*command(name, path, flags, lang: lang, std: std))
    [out.force_encoding(Encoding::UTF_8), err, status]
  end
end
