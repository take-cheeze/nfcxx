# frozen_string_literal: true

# NativeSigs: which signature files declare built-in and RGSS methods rather than the program's. They live in sig/bc2cpp
# with the program's declarations; a file is native when its first line is the marker below. A native declaration is
# not a program hint: its C function or mruby body is checked by its own generator, not by a method the program defines.
module NativeSigs
  MARKER = '# bc2cpp-native:'

  module_function

  # The source text of a signature file, as RBS parsed it, is native when it opens with the marker.
  def text?(text)
    !text.nil? && text.start_with?(MARKER)
  end

  def file?(path)
    return false unless path && File.file?(path)

    text?(File.read(path))
  end
end
