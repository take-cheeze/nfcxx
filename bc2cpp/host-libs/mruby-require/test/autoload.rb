assert('Module#autoload? returns the path until the constant is loaded') do
  m = Module.new
  m.autoload(:Missing, "no_such_file_zz")
  assert_equal "no_such_file_zz", m.autoload?(:Missing)
  assert_nil m.autoload?(:Other)
end

assert('a missing autoload raises LoadError and keeps the path') do
  m = Module.new
  m.autoload(:Missing, "no_such_file_zz")
  assert_raise(LoadError) { m::Missing }
  assert_equal "no_such_file_zz", m.autoload?(:Missing)
end

assert('an autoload whose require does not define the constant raises NameError') do
  # the feature is provided (see require.rb): its require succeeds but defines no Stringy
  $LOADED_FEATURES = ["stringio"]
  m = Module.new
  m.autoload(:Stringy, "stringio")
  assert_raise(NameError) { m::Stringy }
  assert_nil m.autoload?(:Stringy)
end

# A constant autoloaded on Object is found from a class body, as CRuby finds it through the ancestors. The file is
# loaded by require (see require.rb for the path rules).
assert('a constant autoloaded on Object is found from a class body') do
  Object.autoload(:Zq, './mrbgems/mruby-require/test/requirefile/zq')
  class RequireFileAutoload
    def go; Zq.val; end
  end
  assert_equal 7, RequireFileAutoload.new.go
  assert_nil Object.autoload?(:Zq)
end
