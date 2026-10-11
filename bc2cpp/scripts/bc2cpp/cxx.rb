# frozen_string_literal: true

# The one place the bc2cpp checks start the C++ compiler, so every fixture and mruby build can go
# through sccache (docs/ci.md, "Compiler cache"). Without sccache nothing changes: the compiler is
# ${CXX:-g++} and the argument list is passed through untouched.
#
# sccache only caches a compile (-c): `g++ main.cpp lib.a -o bin` is a link as far as it can tell. With a
# launcher, `system`/`capture3` therefore run a one-source build as a cached `-c` plus a link. The
# compile runs in the source's directory with that directory spelled `.`, because the preprocessed text
# sccache hashes carries the source path and the fixtures live in a fresh mktmpdir every run.
#
# BC2CPP_SCCACHE: unset = look for a launcher; 0 = never use one; a path = use that sccache.
require 'open3'
require 'shellwords'

module Bc2cppCxx
  SOURCE = /\.(?:cpp|cc|cxx)\z/
  NOT_A_BUILD = %w[-c -E -S -M -MM -fsyntax-only].freeze
  LAUNCHERS = %w[sccache ccache].freeze

  module_function

  # The sccache to put in front of a compile, or nil.
  def launcher
    return @launcher if defined?(@launcher)

    setting = ENV.fetch('BC2CPP_SCCACHE', nil)
    @launcher = if setting == '0' then nil
                elsif setting && !setting.empty? then setting
                else
                  candidates = [ENV.fetch('CMAKE_CXX_COMPILER_LAUNCHER', nil), 'sccache'].compact
                  candidates.find { |c| File.basename(c) == 'sccache' && executable?(c) }
                end
  end

  def executable?(command)
    return File.executable?(command) if command.include?('/')

    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, command)) }
  end

  # ${CXX:-g++} as an argv prefix; a launcher already named in CXX is kept, not doubled.
  def compiler(variable = 'CXX', default = 'g++')
    words = Shellwords.split(ENV.fetch(variable, ''))
    words = [default] if words.empty?
    words
  end

  def launched(variable = 'CXX', default = 'g++')
    words = compiler(variable, default)
    return words if launcher.nil? || LAUNCHERS.include?(File.basename(words.first))

    [launcher, *words]
  end

  # CC/CXX for a `rake` that builds mruby, so its compiles are cached too (nil-safe: {} without a launcher).
  def rake_env
    return {} if launcher.nil?

    { 'CC' => launched('CC', 'gcc').shelljoin, 'CXX' => launched.shelljoin }
  end

  # [[argv, spawn options], ...] to run in order for `args` (what `system('g++', *args)` took).
  def plan(args)
    return [[[*compiler, *args], {}]] if launcher.nil?

    split(args) || [[[*compiler, *args], {}]]
  end

  # The cached compile and the link, or nil when `args` is not a single-source build.
  def split(args)
    return nil if args.any? { |arg| NOT_A_BUILD.include?(arg) }

    out_at = args.index('-o')
    sources = args.grep(SOURCE)
    return nil if out_at.nil? || sources.size != 1

    source = sources.first
    output = args[out_at + 1]
    rest = args.each_with_index.reject { |_arg, i| [out_at, out_at + 1].include?(i) }.map(&:first) - [source]
    libs, flags = rest.partition { |arg| arg.end_with?('.a') || arg.start_with?('-l', '-L') }
    object = "#{output}.o"
    dir = File.dirname(source)
    compile_flags, compile_source, options = anchored(flags, source, dir, object)
    [[[*launched, *compile_flags, '-c', compile_source, '-o', object], options],
     [[*compiler, *flags.grep_v(/\A-[ID]/), object, *libs, '-o', output], {}]]
  end

  # The compile arguments with the source's directory as `.`, run from there; unchanged when the
  # arguments name a relative path whose meaning would move with the working directory.
  def anchored(flags, source, dir, object)
    paths = flags.filter_map { |flag| flag.start_with?('-I') ? flag.delete_prefix('-I') : (flag unless flag.start_with?('-')) }
    paths << source << object
    return [flags, source, {}] unless paths.all? { |path| File.absolute_path?(path) }

    [flags.map { |flag| flag == "-I#{dir}" ? '-I.' : flag }, File.basename(source), { chdir: dir }]
  end

  # Drop-in for `system('g++', *args, **options)`.
  def system(*args, **options)
    plan(args).all? { |argv, extra| Kernel.system(*argv, **options, **extra) }
  end

  # Drop-in for `Open3.capture3('g++', *args)`: [stdout, stderr, status] of the failing step, else of the last.
  def capture3(*args)
    results = []
    plan(args).each do |argv, extra|
      results << Open3.capture3(*argv, **extra)
      break unless results.last.last.success?
    end
    [results.sum('') { |r| r[0] }, results.sum('') { |r| r[1] }, results.last.last]
  end
end
