# Shim that lets ASTroGen (lib/astrogen.rb of https://github.com/ko1/astro, and the samples' *_gen.rb) run on the
# repo's mruby (scripts/mrb) instead of CRuby. scripts/astrogen-mruby concatenates this file, the generator sources
# (their `require` lines dropped: mruby has no require) and the caller's code into one script.
# What mruby lacks that the generator uses is defined here; see docs/notes/astro.md.

# optparse: astrogen's parse_opt only uses OptionParser#on('--name=[ARG]') { |v| } and #parse!(argv).
class OptionParser
  def initialize; @opts = {}; end
  def on(spec, &blk)
    name = spec.sub(/\A--/, '').sub(/=.*\z/, '')
    @opts[name] = [spec.include?('='), blk]
  end
  def parse!(argv)
    rest = []
    argv.each do |a|
      if a =~ /\A--([^=]+)(?:=(.*))?\z/ && @opts[$1]
        arg, blk = @opts[$1]
        blk.call(arg ? $2 : true)
      else
        rest << a
      end
    end
    argv.replace(rest)
  end
end

class Object; def send(*a, &b) = __send__(*a, &b); end unless Object.method_defined?(:send)

ENV = {} unless Object.const_defined?(:ENV)

# Struct (mruby-struct is not in the tool build): Struct.new(:a, :b) with positional arguments and accessors.
# (Neither instance_variable_set nor eval exists here, so the initializer goes through the setters.)
unless Object.const_defined?(:Struct)
  class Struct
    def self.new(*members)
      Class.new do
        attr_accessor(*members)
        define_method(:initialize) { |*vals| members.each_with_index { |m, i| send("#{m}=", vals[i]) } }
      end
    end
  end
end

class File
  # lines keep their "\n", as in CRuby
  def self.readlines(path)
    s = File.open(path, 'r') { |f| f.read }
    lines = []
    s.each_line { |l| lines << l }
    lines
  end
  def self.write(path, str)
    File.open(path, 'w') { |f| f.write(str) }
    str.bytesize
  end
end

module Enumerable; def to_set; Set.new(self); end; end unless [].respond_to?(:to_set)
class Array; def to_set; Set.new(self); end; end unless [].respond_to?(:to_set)

# No instance_variable_get (mruby-metaprog is not in the tool build). astrogen.rb reads exactly one, a node's
# @prefix_args (build_eval, build_head); any other name is an error so a new use is noticed.
unless Object.method_defined?(:instance_variable_get)
  class Object
    def instance_variable_get(name)
      raise NotImplementedError, "instance_variable_get(#{name.inspect}) is not shimmed" unless name == :@prefix_args
      @prefix_args
    end
  end
end
