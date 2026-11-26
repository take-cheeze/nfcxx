# require: a provided feature returns false, any other feature raises LoadError.
# A gem's test state loads only its dependencies, so the features the build provides (the generated table) are
# registered here by hand; the table itself is checked by running a full build (see tasks/mrbgems.rake).
assert('require of a provided feature returns false') do
  $LOADED_FEATURES = ["stringio"]
  assert_false require('stringio')
end

assert('require of an unknown feature raises LoadError') do
  assert_raise(LoadError) { require 'no_such_feature_xyz' }
  assert_kind_of ScriptError, LoadError.new
end

# A file is loaded from a path (or from $LOAD_PATH for a plain name), once. The fixtures are in test/requirefile/ and
# are named relative to the repository root, where the test run starts (a gem's test state has no File to write them).
assert('require loads a file once, from a path') do
  $requirefile_hello = nil
  assert_true require('./mrbgems/mruby-require/test/requirefile/hello')
  assert_false require('./mrbgems/mruby-require/test/requirefile/hello')
  assert_equal 1, $requirefile_hello
end

assert('require searches $LOAD_PATH for a plain name') do
  $requirefile_other = nil
  $LOAD_PATH = ['./mrbgems/mruby-require/test/requirefile']
  assert_true require('other')
  assert_equal 42, $requirefile_other
  assert_false require('other')
end

assert('a file that requires itself does not recurse') do
  assert_true require('./mrbgems/mruby-require/test/requirefile/self')
  assert_false $requirefile_self
end

assert('require of a file that is not there raises LoadError') do
  assert_raise(LoadError) { require('./mrbgems/mruby-require/test/requirefile/does_not_exist') }
end
