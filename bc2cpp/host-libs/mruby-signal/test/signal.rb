##
# Signal.trap Test

assert('Signal.trap returns the previous handler') do
  # USR2 is restored to DEFAULT at the end of the test
  first = Signal.trap("USR2", "IGNORE")
  assert_equal "DEFAULT", first
  assert_equal "IGNORE", Signal.trap("USR2", "DEFAULT")
  assert_equal "DEFAULT", Signal.trap("USR2", "SIG_DFL")
  assert_equal "DEFAULT", Signal.trap("USR2", "DEFAULT")
end

assert('Signal.trap accepts names with or without SIG, and symbols') do
  Signal.trap("SIGUSR2", "IGNORE")
  assert_equal "IGNORE", Signal.trap(:USR2, "DEFAULT")
  assert_equal "DEFAULT", Signal.trap("USR2", "DEFAULT")
end

assert('Signal.trap IGNORE forms') do
  assert_equal "DEFAULT", Signal.trap("USR2", "")
  assert_equal "IGNORE", Signal.trap("USR2", nil)
  assert_equal "IGNORE", Signal.trap("USR2", "SIG_IGN")
  assert_equal "IGNORE", Signal.trap("USR2", "DEFAULT")
end

assert('Signal.trap SYSTEM_DEFAULT') do
  Signal.trap("USR2", "SYSTEM_DEFAULT")
  assert_equal "SYSTEM_DEFAULT", Signal.trap("USR2", "DEFAULT")
  assert_equal "DEFAULT", Signal.trap("USR2", "DEFAULT")
end

assert('Signal.trap errors') do
  assert_raise(ArgumentError) { Signal.trap("NOSUCHSIG", "IGNORE") }
  assert_raise(ArgumentError) { Signal.trap("USR2", "NOT A COMMAND") }
  assert_raise(ArgumentError) { Signal.trap("USR2") }
  assert_raise(ArgumentError) { Signal.trap(-1, "IGNORE") }
  assert_raise(ArgumentError) { Signal.trap("SEGV", "IGNORE") }
  assert_raise(ArgumentError) { Signal.trap("KILL", "IGNORE") }
end

assert('Signal.trap with a proc or block raises NotImplementedError') do
  assert_raise(NotImplementedError) { Signal.trap("USR2", Proc.new {}) }
  assert_raise(NotImplementedError) { Signal.trap("USR2") { } }
  assert_raise(NotImplementedError) { Signal.trap("USR2", "EXIT") }
end
