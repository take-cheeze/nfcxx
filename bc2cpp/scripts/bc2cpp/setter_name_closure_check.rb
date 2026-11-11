#!/usr/bin/env ruby
# frozen_string_literal: true

# SETTER_NAME_CLOSURE: DynamicNames.setter_composition says whether a program can make a value naming a setter
# other than by spelling it, and DynamicNames.universe adds `stem=` for computed sends only when it can. Each
# fixture is compiled by the host mrbc.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/setter_name_closure_check.rb
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/dynamic_names'
require_relative 'check_support'

suite = FixtureCheck.new('setter_name_closure_check')
check = suite.method(:check)
suite.require_mrbc!

# A computed definition send (its names are a parameter), so the blanket rule would add every `stem=`; it defines
# methods and calls none.
COMPUTED = <<~RUBY
  class Caller
    def self.make(names)
      attr_accessor(*names)
      nil
    end
  end
RUBY

composition = lambda do |source|
  result = nil
  suite.compile(COMPUTED + source) { |ireps, _root, _dir| result = DynamicNames.setter_composition(ireps) }
  result
end
universe = lambda do |source|
  result = nil
  suite.compile(COMPUTED + source) { |ireps, _root, _dir| result = DynamicNames.universe(ireps) }
  result
end

CLEAN = <<~RUBY
  class Box
    attr_accessor :size
    def weight=(v)
      @weight = v
    end
    private def secret; end
    def field(type)
      :"\#{type}_name"
    end
    def each_part(*args)
      to_enum(:each_part, *args)
    end
    def last; end
  end
RUBY

check.call('accessors, setters, visibility, a suffixed Symbol and a final def compose nothing', composition.call(CLEAN).nil?)
check.call('without composition a computed send adds no stem=', !universe.call(CLEAN).include?('size='))
check.call('a spelled name stays in the universe', universe.call(CLEAN).include?('size'))

ENV['BC2CPP_SETTER_NAME_CLOSURE'] = '0'
check.call('BC2CPP_SETTER_NAME_CLOSURE=0 keeps the blanket rule', universe.call(CLEAN).include?('size='))
ENV.delete('BC2CPP_SETTER_NAME_CLOSURE')

refusals = {
  'an interpolated Symbol ending in =' => ['def name_for(k); :"#{k}="; end', 'interpolated Symbol may end in ='],
  'an interpolated Symbol whose last piece is computed' => ['def name_for(k); :"x#{k}"; end',
                                                             'interpolated Symbol may end in ='],
  'to_sym of a String' => ['def name_for(s); s.to_sym; end', 'to_sym of a String'],
  'intern of a String' => ['def name_for(s); s.intern; end', 'intern of a String'],
  'a method-name lister' => ['def names(o); o.methods; end', 'methods lists method names'],
  'a computed send, which may take a String' => ['def call(o, n); o.send(n); end', 'computed send may take a String name'],
  'to_enum of a non-literal name' => ['def en(o, n); o.to_enum(n); end', 'to_enum names its method by a non-literal'],
  'to_enum of a splat headed by a non-literal' => ['def en(o, n, *r); o.to_enum(n, *r); end',
                                                   'to_enum names its method by a non-literal'],
  'a def whose name value is used' => ['def keep; @m = def weight=(v); end; end', 'name value used'],
  'a define_method whose name value is used' => ['def keep; @m = Maker.define_method(:w=) { |v| v }; end',
                                                'define_method result used']
}
refusals.each do |label, (body, reason)|
  why = composition.call("class Maker\n#{body}\nend\n")
  check.call("#{label} may compose a setter name", why.to_s.include?(reason))
end
check.call('composition puts stem= back for a computed send',
           universe.call("class Maker\ndef n(s); s.to_sym; end\nend\nclass Box\nattr_accessor :size\nend\n").include?('size='))

suite.finish!
