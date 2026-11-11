# mruby's core defines no LoadError (the exception require raises for a missing feature). CRuby's ScriptError family.
class ScriptError < StandardError; end unless defined?(ScriptError)
class LoadError < ScriptError; end unless defined?(LoadError)
# EncodingError (CRuby's Encoding family); no mruby gem defines it.
class EncodingError < StandardError; end unless defined?(EncodingError)

# Features provided by the build, as name => check. A check returns true when the code it names is present.
module MRubyRequire
  FEATURES = {}
  SOURCES = {}
  LOADED = {}

  def self.provide(name, &check)
    FEATURES[name] = check
  end

  # A baked source (tools/bc2cpp/bake_sources.rb): its code is evaluated under its own name, once, by require.
  def self.bake(name, source)
    SOURCES[name] = source
  end
end

# require is defined on Object, not in module Kernel: the baked source it evaluates runs with the lexical scope of this
# method, so a module the source defines at top level (module NativeOwnerMap) would be Kernel::NativeOwnerMap under Kernel.
class Object
  def require(name)
    feature = name.to_s
    return false if MRubyRequire::LOADED[feature]

    # A source compiled into the build (mruby-bc2cpp-sources) is run from its bytecode, with no eval.
    if MRubyRequire.respond_to?(:baked?) && MRubyRequire.baked?(feature)
      MRubyRequire::LOADED[feature] = true
      MRubyRequire.load_baked(feature)
      return true
    end

    if (source = MRubyRequire::SOURCES[feature])
      MRubyRequire::LOADED[feature] = true
      eval(source, nil, feature)
      return true
    end

    check = MRubyRequire::FEATURES[feature]
    raise LoadError, "cannot load such file -- #{feature}" unless check && check.call

    MRubyRequire::LOADED[feature] = true
    true
  end
end

MRubyRequire.provide('set') { defined?(Set) }
MRubyRequire.provide('stringio') { defined?(StringIO) }

# The standard libraries this build's gems stand in for (each named by its gem's constant or method).
MRubyRequire.provide('json') { defined?(JSON) }
MRubyRequire.provide('digest') { defined?(Digest) }
MRubyRequire.provide('fileutils') { defined?(FileUtils) }
MRubyRequire.provide('tmpdir') { defined?(Dir) && Dir.respond_to?(:mktmpdir) }
MRubyRequire.provide('shellwords') { defined?(Shellwords) }
MRubyRequire.provide('strscan') { defined?(StringScanner) }
MRubyRequire.provide('tempfile') { defined?(Tempfile) }
MRubyRequire.provide('zlib') { defined?(Zlib) }
MRubyRequire.provide('prism') { defined?(Prism) }
MRubyRequire.provide('rbs') { defined?(RBS) }
# The tools require 'pathname' before 'rbs' (CRuby's rbs needs Pathname); the mruby rbs port does not use it.
MRubyRequire.provide('pathname') { true }
MRubyRequire.provide('open3') { defined?(Open3) }

# RbConfig.ruby: the interpreter bc2cpp starts its tools with. Under mruby it is the wrapper tools/bc2cpp/mruby-ruby,
# which runs a tool through the mruby binary and its baked source; the build or the run sets BC2CPP_RUBY to it.
module Kernel
  # Call-site locations are not available in this VM: callers that only report a location get none.
  def caller_locations(*_args)
    []
  end unless method_defined?(:caller_locations)

  # Kernel#Array as CRuby has it: Array(nil) is [], not [nil]. mruby's core wraps nil in an Array.
  def Array(value)
    return [] if value.nil?
    return value if value.is_a?(Array)
    return value.to_ary if value.respond_to?(:to_ary)
    return value.to_a if value.respond_to?(:to_a)

    [value]
  end

  # String.new(str = "", encoding: nil, capacity: nil), as CRuby takes it: mruby's takes only the string.
  class ::String
    class << self
      alias __new_without_options new

      def new(*args, **options)
        str = __new_without_options(*args)
        encoding = options[:encoding]
        str.force_encoding(encoding) if encoding
        str
      end
    end
  end

  # String#string_scan: the String-pattern scan the onig gem falls back to (it aliases the core scan, which mruby lacks).
  # Matches are the pattern's own occurrences, left to right without overlap, as CRuby's scan with a String.
  class ::String
    def string_scan(pattern, &block)
      pattern = pattern.to_str
      found = []
      pos = 0
      while (at = index(pattern, pos))
        found << pattern.dup
        pos = at + [pattern.size, 1].max
        break if pos > size
      end
      return found unless block

      found.each { |match| block.call(match) }
      self
    end
  end

  # Array#concat with any number of arrays (CRuby 2.4), as mruby's takes one.
  class ::Array
    alias_method :__concat_one, :concat

    def concat(*others)
      others.each { |other| __concat_one(other) }
      self
    end
  end

  # Symbol#start_with? and #end_with? (CRuby 2.7), which mruby does not define.
  class ::Symbol
    def start_with?(*prefixes)
      to_s.start_with?(*prefixes)
    end

    def end_with?(*suffixes)
      to_s.end_with?(*suffixes)
    end
  end

  # NilClass#to_i and #to_f (CRuby: 0 and 0.0), which mruby does not define.
  class ::NilClass
    def to_i
      0
    end

    def to_f
      0.0
    end
  end unless nil.respond_to?(:to_i) && nil.respond_to?(:to_f)

  # Kernel#tap (CRuby 1.9+), which mruby does not define: yields self, returns self.
  unless method_defined?(:tap)
    def tap
      raise LocalJumpError, 'no block given (yield)' unless block_given?

      yield self
      self
    end
  end

  # Object#then (yield_self), which mruby does not define.
  unless method_defined?(:then)
    def then
      return to_enum(:then) unless block_given?

      yield self
    end
  end
end

module RbConfig
  def self.ruby
    interpreter = ENV['BC2CPP_RUBY']
    raise LoadError, 'RbConfig.ruby: BC2CPP_RUBY is not set' unless interpreter

    interpreter
  end
end
MRubyRequire.provide('rbconfig') { defined?(RbConfig) }

# Enumerable#to_set, as CRuby's set library defines it. mruby-set leaves it out (its README lists it as unimplemented).
# mruby has no Integer#[] (a bit read); bc2cpp's class masks use it. The same body as tools/optcarrot_probe/shim_integer_aref.rb.
class Integer
  def [](i)
    (self >> i) & 1
  end
end unless Integer.method_defined?(:[])

module Enumerable
  def to_set(klass = Set, *args, &block)
    klass.new(self, *args, &block)
  end
end

# RUBY_PLATFORM, which mruby does not define. bc2cpp keys its caches on it; "mruby" names the runtime that wrote them.
RUBY_PLATFORM = 'mruby' unless defined?(RUBY_PLATFORM)

# File.stat, reduced to what bc2cpp reads from it: the modification time and the size, taken from the open file (mruby-io
# has no stat). Any other field is absent, and a missing file raises as File.open does.
class File
  # A plain class, not Struct: this file loads before mruby-struct in a build that links both.
  class Stat
    attr_reader :mtime, :size

    def initialize(mtime, size)
      @mtime = mtime
      @size = size
    end
  end unless defined?(File::Stat)

  def self.stat(path)
    File.open(path, 'rb') { |io| File::Stat.new(io.mtime, io.size) }
  end
end

# File.readlines: the lines of a file. chomp: removes each line's newline, as CRuby does; encoding: is accepted and not
# needed (text is read as bytes).
class File
  def self.readlines(path, *options)
    lines = File.read(path).lines
    options.last.is_a?(Hash) && options.last[:chomp] ? lines.map(&:chomp) : lines
  end
end

# SystemCallError: mruby has no Errno, and its failed file operations raise RuntimeError, so the name stands for that class.
SystemCallError = RuntimeError unless defined?(SystemCallError)

# File.write, File.binwrite and File.binread, as CRuby defines them (mruby-io has the IO methods, not these).
class File
  def self.write(path, data)
    File.open(path, 'w') { |io| io.write(data) }
  end

  def self.binwrite(path, data)
    File.open(path, 'wb') { |io| io.write(data) }
  end

  def self.binread(path)
    File.open(path, 'rb') { |io| io.read }
  end
end

# Module#private_constant. mruby has no constant visibility, so the named constants stay public: a correct program
# behaves the same, and only code that would have raised NameError on a private constant can tell the difference.
class Module
  def private_constant(*_names)
    nil
  end
end

# File.read with the encoding: option. mruby-io's read takes no options; the bytes it reads are the file's, so the option
# only chooses the result's encoding, BINARY (the bytes as they are) or not (the text as read).
class File
  class << self
    alias __core_read read
  end

  def self.read(path, *args, **options)
    text = args.empty? ? __core_read(path) : __core_read(path, *args)
    options[:encoding].to_s.upcase == 'BINARY' ? text.b : text
  end
end

# Mutex, for the single thread mruby runs: no other thread can hold it, so a lock is only ever taken by the one caller.
# Locking it again while held raises ThreadError, as CRuby does for a recursive lock.
# String#scrub (CRuby 2.1+): each invalid UTF-8 byte sequence becomes the replacement (U+FFFD by default).
class String
  unless method_defined?(:scrub)
    # Works on the bytes in place (getbyte, byteslice), not on an Array of every byte: that Array is past mruby's array
    # size limit for a large file.
    def scrub(repl = "\uFFFD")
      out = "".b
      n = bytesize
      i = 0
      while i < n
        b = getbyte(i)
        len = if b < 0x80 then 1
              elsif b >= 0xC2 && b <= 0xDF then 2
              elsif b >= 0xE0 && b <= 0xEF then 3
              elsif b >= 0xF0 && b <= 0xF4 then 4
              else 0
              end
        # The byte after a lead byte has a narrower range for some leads (no overlongs, no surrogates, no code points
        # past U+10FFFF), as CRuby's UTF-8 decoder has it. Later bytes are 80..BF.
        j = 1
        ok = len > 0
        while ok && j < len
          break unless i + j < n

          c = getbyte(i + j)
          lo, hi = if j == 1
                     case b
                     when 0xE0 then [0xA0, 0xBF]
                     when 0xED then [0x80, 0x9F]
                     when 0xF0 then [0x90, 0xBF]
                     when 0xF4 then [0x80, 0x8F]
                     else [0x80, 0xBF]
                     end
                   else
                     [0x80, 0xBF]
                   end
          break unless c >= lo && c <= hi

          j += 1
        end
        if len > 0 && j == len
          out << byteslice(i, len)
          i += len
        else
          # One replacement for the maximal subpart of an invalid sequence: the lead byte and the continuation bytes
          # that are valid so far (at least the lead itself).
          out << repl.to_s.b
          i += j
        end
      end
      out
    end
  end
end

class ThreadError < StandardError; end unless defined?(ThreadError)

class Mutex
  def initialize
    @locked = false
  end

  def lock
    raise ThreadError, 'deadlock; recursive locking' if @locked

    @locked = true
    self
  end

  def unlock
    raise ThreadError, 'Attempt to unlock a mutex which is not locked' unless @locked

    @locked = false
    self
  end

  def try_lock
    return false if @locked

    @locked = true
  end

  def locked? = @locked

  def synchronize
    lock
    begin
      yield
    ensure
      unlock
    end
  end
end unless defined?(Mutex)

# ObjectSpace::WeakMap, identity-keyed. mruby has no weak references, so entries are held for the life of the map: a
# caller that rebuilds a missing entry gets the same results, and only the memory is not released early.
module ObjectSpace
  class WeakMap
    def initialize
      @entries = {}
    end

    def []=(key, value)
      entry = @entries[key.object_id]
      if entry
        entry[1] = value
      else
        @entries[key.object_id] = [key, value]
      end
      value
    end

    def [](key)
      entry = @entries[key.object_id]
      entry ? entry[1] : nil
    end

    def key?(key) = @entries.key?(key.object_id)
    alias include? key?
    alias member? key?

    def delete(key)
      entry = @entries.delete(key.object_id)
      entry ? entry[1] : nil
    end

    def size = @entries.size
    alias length size

    def each_pair
      @entries.values.each { |key, value| yield key, value }
      self
    end
  end
end unless defined?(ObjectSpace::WeakMap)

# Hash#to_h with a block: each [key, value] pair is yielded as one argument, and the block's result must be a
# two-element pair, which becomes the entry. mruby's Hash#to_h ignores the block and returns a copy of the hash.
class Hash
  alias __core_to_h to_h

  def to_h(&block)
    return __core_to_h unless block

    result = {}
    each_pair do |key, value|
      pair = block.call([key, value])
      raise TypeError, "wrong element type #{pair.class} (expected array)" unless pair.is_a?(Array)
      raise ArgumentError, "element has wrong array length (expected 2, was #{pair.size})" unless pair.size == 2

      result[pair[0]] = pair[1]
    end
    result
  end
end

# Kernel#at_exit. mruby has no exit hook to run these from, so the blocks wait in a list until the program's own runner
# calls ExitHandlers.run (tools/bc2cpp/mruby_tool.rb does, after the tool's main block); they then run in reverse order,
# as CRuby runs them.
module ExitHandlers
  BLOCKS = []

  def self.run
    until BLOCKS.empty?
      BLOCKS.pop.call
    end
  end
end

module Kernel
  def at_exit(&block)
    raise ArgumentError, 'called without a block' unless block

    ExitHandlers::BLOCKS << block
    block
  end
end

# Process.clock_gettime and Process::CLOCK_MONOTONIC, for the timers bc2cpp reads. The mruby process gem has neither. The
# fallback reads the wall clock (Time.now), so it is not monotonic; it only times runs.
module Process
  CLOCK_MONOTONIC = 1 unless defined?(Process::CLOCK_MONOTONIC)

  unless respond_to?(:clock_gettime)
    def self.clock_gettime(_clock = CLOCK_MONOTONIC, unit = :float_second)
      seconds = Time.now.to_f
      case unit
      when :float_second then seconds
      when :float_millisecond then seconds * 1_000.0
      when :float_microsecond then seconds * 1_000_000.0
      when :second then seconds.to_i
      when :millisecond then (seconds * 1_000).to_i
      when :microsecond then (seconds * 1_000_000).to_i
      when :nanosecond then (seconds * 1_000_000_000).to_i
      else raise ArgumentError, "unexpected unit: #{unit}"
      end
    end
  end
end

# Kernel#system with all of its arguments. The mruby process gem runs only the first one, so a list of arguments is quoted
# and joined into one shell command here. A single string is the shell command itself, as in CRuby, and goes unchanged.
# exception: true raises when the command fails, as CRuby does.
module Kernel
  if method_defined?(:system)
    alias __core_system system

    def system(*args, exception: false)
      command = args.size == 1 ? args[0] : args.map { |arg| "'" + arg.to_s.split("'", -1).join("'\\''") + "'" }.join(' ')
      ok = __core_system(command)
      raise RuntimeError, "Command failed with #{command}" if exception && !ok
      ok
    end
  end
end

# Kernel#abort: print the message to $stderr and exit with status 1, as CRuby does. mruby has no abort.
module Kernel
  def abort(message = nil)
    $stderr.puts message if message
    exit 1
  end
end unless Kernel.method_defined?(:abort)

# Kernel#warn: each message to $stderr, one per line, as CRuby writes plain messages. mruby has no warn.
module Kernel
  def warn(*messages, **_options)
    messages.each { |message| $stderr.puts message }
    nil
  end
end unless Kernel.method_defined?(:warn)

# Module#name: the constant path of a named module or class, as a String. mruby has no name, and to_s gives the same path
# for a named module.
class Module
  def name = to_s unless method_defined?(:name)
end
