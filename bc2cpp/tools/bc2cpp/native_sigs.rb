# frozen_string_literal: true

# NativeSigs: which signature files declare built-in and RGSS methods rather than the program's. They live in sig/bc2cpp
# with the program's declarations; a file is native when its first line is the marker below. A native declaration is
# not a program hint: its C function or mruby body is checked by its own generator, not by a method the program defines.
module NativeSigs
  MARKER = '# bc2cpp-native:'

  module_function

  def file?(path)
    return false unless path && File.file?(path)

    File.foreach(path).first.to_s.start_with?(MARKER)
  end
end
