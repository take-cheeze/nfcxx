#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'rbconfig'

require_relative '../../tools/bc2cpp/compact_output'

source = <<~'CPP'
  // diagnostic containing "quotes", /* markers and Ruby source
  const char* text = "https://example.com//path"; // inline diagnostic
  const char* raw = R"tag(// literal
  /* literal */)tag";
  char slash = '/';
  /* opaque block
  // inside block */
  #define VALUE 1 // continued comment \
  // still a comment
  int value = VALUE;
CPP
expected = <<~'CPP'

  const char* text = "https://example.com//path";<space>
  const char* raw = R"tag(// literal
  /* literal */)tag";
  char slash = '/';
  /* opaque block
  // inside block */
  #define VALUE 1<space>

  int value = VALUE;
CPP
expected = expected.gsub('<space>', ' ')
abort 'compact output changed literal/block contents or retained diagnostics' unless CompactOutput.rewrite(source) == expected
abort 'compact output changed source line numbers' unless CompactOutput.rewrite(source).count("\n") == source.count("\n")
helper = File.expand_path('../../tools/bc2cpp/compact_output.rb', __dir__)
pipeline = <<~'RUBY'
  CompactOutput.capture_stdout
  original = $stdout
  buffer = StringIO.new
  $stdout = buffer
  at_exit do
    $stdout = original
    original.write(buffer.string.sub('// marker', "// instrumented\nint counter;"))
  end
  puts "// marker\nint value;"
RUBY
output, error, status = Open3.capture3(RbConfig.ruby, '-r', helper, '-e', pipeline)
abort "compact output pipeline failed: #{error}" unless status.success?
abort 'compaction ran before instrumentation consumed its marker' unless output == "\nint counter;\nint value;\n"
output, error, status = Open3.capture3(RbConfig.ruby, '-r', helper, '-e',
                                     'CompactOutput.capture_stdout; puts "partial code"; raise "decode failed"')
abort 'failed generation emitted partial compact output or hid its error' unless !status.success? && output.empty? && error.include?('decode failed')
puts 'compact output check: PASS'
