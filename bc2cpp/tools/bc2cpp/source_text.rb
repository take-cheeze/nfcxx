# frozen_string_literal: true

require 'set'

# Reader for the outside-world sources (mruby C, foreign Ruby) the closed-world
# proofs scan (ADR 0262). A file that exists but cannot be read would silently
# under-collect a poison source, so it raises; a path that does not exist (an
# uninitialized submodule) is not part of the build and contributes nothing.
module SourceText
  class Unreadable < RuntimeError; end

  @missing_warned = Set.new

  # nil, after one stderr line per path, when `path` does not exist.
  def self.read(path, what, binary: false)
    binary ? File.binread(path) : File.read(path, encoding: 'UTF-8')
  rescue Errno::ENOENT
    warn "[bc2cpp] #{what}: #{path} does not exist, skipped" if @missing_warned.add?(path)
    nil
  rescue SystemCallError => e
    raise Unreadable, "bc2cpp: #{what}: cannot read #{path}: #{e.message}"
  end

  def self.forget_warnings
    @missing_warned.clear
  end
end
