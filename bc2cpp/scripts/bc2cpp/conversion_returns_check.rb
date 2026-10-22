#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks tools/bc2cpp/conversion_returns.rb on fixture sources: a conversion method takes only optional positional
# parameters (anything else is a build error), its return is declared as a runtime-checked hint in the generated RBS,
# and the generated RBS parses. Host only, a few milliseconds.
#
#   ruby scripts/bc2cpp/conversion_returns_check.rb

require 'tmpdir'
require 'rbs'
require_relative '../../tools/bc2cpp/conversion_returns'

failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def problems(source)
  ConversionReturns.found_in('fixture.rb', source).flat_map { |f| ConversionReturns.parameter_problems(f.node) }
end

def rbs_of(sources)
  Dir.mktmpdir('conversion-check') do |dir|
    paths = sources.each_with_index.map do |src, i|
      File.join(dir, "fixture#{i}.rb").tap { |p| File.write(p, src) }
    end
    ConversionReturns.rbs_text(paths)
  end
end

puts '== parameters'
check.call('no parameter is accepted', problems("class A\n def to_s; 'x'; end\nend\n").empty?)
check.call('an optional positional parameter is accepted', problems("class A\n def to_s(base = 10); 'x'; end\nend\n").empty?)
check.call('a required parameter is refused', problems("class A\n def to_int(base); 1; end\nend\n") == ['a required parameter'])
check.call('a rest parameter is refused', problems("class A\n def to_s(*args); 'x'; end\nend\n") == ['a rest parameter'])
check.call('a keyword parameter is refused', problems("class A\n def to_s(k: 1); 'x'; end\nend\n") == ['a keyword parameter'])
check.call('a singleton method is not a conversion',
           ConversionReturns.found_in('f.rb', "class A\n def self.to_s(a); 'x'; end\nend\n").empty?)

puts '== generated hints'
text = rbs_of(["class A\n def to_s(base = 10); 'x'; end\n def to_hash; {}; end\nend\n"])
check.call('a class method gets a runtime-checked hint with its optional arity, typed by its literal default',
           text.include?("class A\n  %a{bc2cpp:hint}\n  def to_s: (?Integer) -> String\n"))
check.call('to_hash returns Hash', text.include?('def to_hash: () -> Hash'))
check.call('inspect returns String, to_i Integer and to_f Float',
           rbs_of(["class A\n def inspect; 'x'; end\n def to_i; 1; end\n def to_f; 1.0; end\nend\n"])
             .then { |t| t.include?('def inspect: () -> String') && t.include?('def to_i: () -> Integer') && t.include?('def to_f: () -> Float') })
check.call('a required parameter on inspect is refused', problems("class A\n def inspect(x); 'x'; end\nend\n") == ['a required parameter'])
defaults = rbs_of(["class A\n def to_s(a = 'x', b = nil, c = [], d = {}, e = :s, f = true, g = 1.5); 'x'; end\nend\n"])
check.call('each literal default types its optional parameter, and a non-literal one stays untyped',
           defaults.include?('def to_s: (?String, ?untyped, ?Array, ?Hash, ?Symbol, ?bool, ?Float) -> String'))
check.call('a default that is not a literal stays untyped',
           rbs_of(["class A\n def to_s(a = Foo.new); 'x'; end\nend\n"]).include?('def to_s: (?untyped) -> String'))
mod = rbs_of(["module M\n def to_str; 'x'; end\nend\n"])
check.call('a module method is declared in a module', mod.start_with?("module M\n"))
check.call('the generated RBS parses', begin
  RBS::Parser.parse_signature(text) && RBS::Parser.parse_signature(mod)
  true
rescue RBS::ParsingError
  false
end)
check.call('a file with no conversion method generates nothing', rbs_of(["class A\n def x; 1; end\nend\n"]).nil?)

puts
puts "conversion returns check: #{checks - failures.size} checks passed" if failures.empty?
abort "conversion returns check: #{failures.size} of #{checks} failed" unless failures.empty?
