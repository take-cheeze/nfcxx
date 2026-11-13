# frozen_string_literal: false
#
# Declaration scan through libclang-edg (lib/libclang-edg), called from Ruby with Fiddle. The converter uses it in
# place of the DEF_RE regex scan when the library loads (convert_mrbgem.rb --scanner); both produce the same records.
#
# What libclang gives: which function declarations the main file has, and the line and column of each name. The
# library's cursor extents are points, so everything else is read from the text, with the regex scan's conventions:
# the storage class and return type before the name, the parameter text, the "{" or ";" after the parameter list.
# Columns are checked against the source (an identifier followed by "("), so a name that comes from a macro expansion
# is refused rather than recorded under the macro's name.
#
# The C API is called by value-correct means only. CXCursor and CXSourceLocation are 32 and 24 bytes, so the System V
# x86-64 ABI passes them in memory: the call is made with six register arguments (unused) followed by the words of
# the struct on the stack, and a struct result is written through a hidden first pointer. CXString (returned in two
# registers, and only the first one is readable here) is not used. The library's C mode is not reachable through
# clang_parseTranslationUnit, so C sources go to the runner tools/cext2mrbgem/libclang-cursors-c (LIBCLANG_EDG_RUNNER),
# which runs scripts/libclang-cursors --c.
#
# Nothing is compiled or run from the input: the front end parses the text, and the converter reads only the records.

require 'fiddle'
require 'rbconfig'

module DeclScan
  class Error < StandardError; end

  REPO_ROOT = File.expand_path('../..', __dir__)
  DEFAULT_LIBRARY = File.join(REPO_ROOT, 'build', 'libclang-edg', 'libclang-edg.so')
  RUNNER = File.join(__dir__, 'libclang-cursors-c')

  FUNCTION_DECL = 8   # CXCursor_FunctionDecl
  VISIT_BREAK = 0
  VISIT_CONTINUE = 1

  P = Fiddle::TYPE_VOIDP
  L = Fiddle::TYPE_LONG
  I = Fiddle::TYPE_INT
  U = Fiddle::TYPE_UINT
  V = Fiddle::TYPE_VOID

  # symbol => [C name, argument types, return type]. A CXCursor argument is six register-class dummies followed by its
  # four words (kind and xdata, then data[0..2]): 32 bytes in memory. A CXSourceLocation is three words.
  FUNCTIONS = {
    create_index: ['clang_createIndex', [I, I], P],
    dispose_index: ['clang_disposeIndex', [P], V],
    parse: ['clang_parseTranslationUnit', [P, P, P, I, P, U, U], P],
    dispose_tu: ['clang_disposeTranslationUnit', [P], V],
    tu_cursor: ['clang_getTranslationUnitCursor', [P, P], V],               # CXCursor result: hidden pointer, tu
    visit: ['clang_visitChildren', [P, P, P, P, P, P, L, L, L, L], U],       # visitor, client, 4 dummies, parent
    cursor_kind: ['clang_getCursorKind', [P, P, P, P, P, P, L, L, L, L], I],
    cursor_location: ['clang_getCursorLocation', [P, P, P, P, P, P, L, L, L, L], V], # hidden pointer, 5 dummies, cursor
    spelling_location: ['clang_getSpellingLocation', [P, P, P, P, P, P, L, L, L], V] # 4 outputs, 2 dummies, location
  }.freeze

  WSP = '\p{Space}\x1c-\x1f'
  IDENT_START = /[A-Za-z_][\p{L}\p{N}_]*/
  STORAGE_RE = /\A((?:(?:static|inline|extern)[ \t\n]+)*)/
  NON_FUNC_WORDS = %w[if while for switch return sizeof else do case goto].freeze

  @lib = nil

  module_function

  # The library path: CEXT_LIBCLANG (relative paths from the repository root), else build/libclang-edg.
  def library_path
    env = ENV.fetch('CEXT_LIBCLANG', nil)
    env.nil? || env.empty? ? DEFAULT_LIBRARY : File.expand_path(env, REPO_ROOT)
  end

  # The bound functions. Raises Error with the reason when the library does not load or lacks a symbol.
  def lib
    return @lib if @lib
    path = library_path
    raise Error, "#{path} is not a file" unless File.file?(path)
    handle = Fiddle.dlopen(path)
    @lib = FUNCTIONS.to_h do |key, (sym, args, ret)|
      [key, Fiddle::Function.new(handle[sym], args, ret)]
    end
  rescue Fiddle::DLError => e
    raise Error, "cannot load #{path}: #{e.message}"
  end

  # [true, nil] when the library loads and binds, else [false, reason].
  def available?
    lib
    [true, nil]
  rescue Error => e
    [false, e.message]
  end

  # The Ruby headers a file that includes ruby.h needs: CEXT_RUBY_INCLUDE (colon-separated), else this Ruby's own.
  def ruby_include_dirs
    env = ENV.fetch('CEXT_RUBY_INCLUDE', nil)
    dirs = env.nil? || env.empty? ? [RbConfig::CONFIG['rubyhdrdir'], RbConfig::CONFIG['rubyarchhdrdir']] : env.split(':')
    dirs.select { |d| d && File.directory?(d) }
  end

  def c_string(str)
    ptr = Fiddle::Pointer.malloc(str.bytesize + 1, Fiddle::RUBY_FREE)
    ptr[0, str.bytesize] = str
    ptr[str.bytesize, 1] = "\0"
    ptr
  end

  # [line, column] of each function declaration of the main file, in source order. options are the front end's
  # -I and -D arguments as written. Raises Error.
  def function_positions(path, options)
    f = lib
    saved = ENV.fetch('LIBCLANG_EDG_RUNNER', nil)
    ENV['LIBCLANG_EDG_RUNNER'] = RUNNER
    index = tu = callback = nil
    positions = []
    error = nil
    begin
      index = f[:create_index].call(0, 0)
      args = options.map { |o| c_string(o) }
      argv = Fiddle::Pointer.malloc(8 * (args.size + 1), Fiddle::RUBY_FREE)
      args.each_with_index { |a, i| argv[8 * i, 8] = [a.to_i].pack('Q<') }
      argv[8 * args.size, 8] = [0].pack('Q<')
      tu = f[:parse].call(index, c_string(path), argv, args.size, nil, 0, 0)
      raise Error, "libclang-edg could not parse #{path} (set CEXT_LIBCLANG_LOG for the front end's diagnostics)" if tu.to_i == 0

      loc = Fiddle::Pointer.malloc(24, Fiddle::RUBY_FREE)
      line = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      col = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      callback = Fiddle::Closure::BlockCaller.new(I, [P] * 6 + [L] * 8) do |_client, *rest|
        cursor = rest[5, 4]   # rest[0..4] are the register arguments the callee does not use
        result = VISIT_CONTINUE
        begin
          if f[:cursor_kind].call(0, 0, 0, 0, 0, 0, *cursor) == FUNCTION_DECL
            f[:cursor_location].call(loc, 0, 0, 0, 0, 0, *cursor)
            f[:spelling_location].call(0, line, col, 0, 0, 0, *loc[0, 24].unpack('q<3'))
            positions << [line[0, 4].unpack1('L<'), col[0, 4].unpack1('L<')]
          end
        rescue StandardError => e
          error ||= e
          result = VISIT_BREAK
        end
        result
      end
      root = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
      f[:tu_cursor].call(root, tu)
      f[:visit].call(callback.to_i, 0, 0, 0, 0, 0, *root[0, 32].unpack('q<4'))
    ensure
      f[:dispose_tu].call(tu) if tu && tu.to_i != 0
      f[:dispose_index].call(index) if index && index.to_i != 0
      ENV['LIBCLANG_EDG_RUNNER'] = saved
    end
    raise Error, "visiting #{path}: #{error.message}" if error
    positions.sort
  end

  # The records of one file from its positions: the same keys the regex scan gives, in source order. Returns
  # [records, skipped], where skipped lists [line, reason] for a declaration that is not a function definition or
  # prototype in the regex scan's sense. Raises Error when a position is not a function name in the text.
  def records(rel, text, masked, hdr, positions)
    starts = line_starts(text)
    pp = blank_preprocessor(masked)
    out = []
    skipped = []
    positions.each do |line, col|
      name_pos = char_position(text, starts, line, col)
      m = IDENT_START.match(masked, name_pos)
      raise Error, "#{rel}:#{line}:#{col} is not the start of a name" unless m && m.begin(0) == name_pos
      name = m[0]
      po = skip_space(masked, name_pos + name.length)
      raise Error, "#{rel}:#{line}:#{col} is not a function name (no \"(\" after #{name})" unless masked[po] == '('

      head_start = name_pos
      head_start -= 1 while head_start > 0 && pp[head_start - 1].match?(/[\p{L}\p{N}_\s*]/)
      hstart = head_start
      hstart += 1 while hstart < name_pos && pp[hstart].match?(/\s/)
      head = pp[hstart...name_pos]
      storage = STORAGE_RE.match(head)[1]
      ret = head[storage.length..].sub(/[#{WSP}\*]+\z/, '')
      if ret.empty? || NON_FUNC_WORDS.include?(ret.split.last)
        skipped << [line, 'no return type before the name, or not a function']
        next
      end
      pc = match_close(masked, po)
      if pc < 0
        skipped << [line, 'unbalanced parentheses in the parameter list']
        next
      end
      term_pos = skip_space(masked, pc + 1)
      term = masked[term_pos]
      unless term == '{' || term == ';'
        skipped << [line, 'no "{" or ";" after the parameter list']
        next
      end
      d = { 'file' => rel, 'name' => name, 'storage' => storage, 'ret' => ret, 'hstart' => hstart,
            'po' => po, 'pc' => pc, 'params' => text[(po + 1)...pc], 'proto' => term == ';', 'hdr' => hdr }
      if term == '{'
        d['brace'] = term_pos
        d['body_end'] = match_close(masked, term_pos)
        d['hend'] = term_pos
      else
        d['hend'] = pc + 1
      end
      out << d
    end
    [out, skipped]
  end

  def line_starts(text)
    starts = [0]
    i = -1
    starts << i + 1 while (i = text.index("\n", i + 1))
    starts
  end

  # The character index of (line, column). The front end's column is 1-based and counts characters of the line (a
  # multi-byte character is one column; a tab is one).
  def char_position(text, starts, line, col)
    raise Error, "line #{line} is outside the file" if line < 1 || line > starts.size
    starts[line - 1] + col - 1
  end

  # The masked text with preprocessor directives (and their continuation lines) blanked, so a declaration's
  # return type is not taken from a directive above it. Same length as the input.
  def blank_preprocessor(masked)
    cont = false
    masked.each_line.map do |ln|
      if cont || ln.match?(/\A[ \t]*#/)
        cont = ln.chomp.end_with?('\\')
        ln.gsub(/[^\n]/, ' ')
      else
        ln
      end
    end.join
  end

  def skip_space(s, pos)
    pos += 1 while pos < s.length && s[pos].match?(/[#{WSP}]/)
    pos
  end

  # Index of the bracket that closes the one at open_pos, over all three bracket kinds (as the converter's match_close).
  def match_close(masked, open_pos)
    depth = 0
    k = open_pos
    while k < masked.length
      ch = masked[k]
      if '([{'.include?(ch)
        depth += 1
      elsif ')]}'.include?(ch)
        depth -= 1
        return k if depth == 0
      end
      k += 1
    end
    -1
  end

  # The function declarations of one source file as [records, skipped] (see records). include_dirs and defines are
  # the front end's -I and -D options. Raises Error when libclang-edg cannot parse the file.
  def scan_file(path, rel, text, masked, hdr, include_dirs, defines = [])
    options = include_dirs.map { |d| "-I#{d}" } + defines.map { |d| "-D#{d}" }
    records(rel, text, masked, hdr, function_positions(path, options))
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ['--check']
    ok, why = DeclScan.available?
    puts ok ? "libclang-edg: #{DeclScan.library_path}" : "libclang-edg unavailable: #{why}"
    exit(ok ? 0 : 1)
  end
  warn 'usage: decl_scan.rb --check'
  exit 1
end
