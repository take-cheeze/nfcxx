# frozen_string_literal: true

# ENUM_STEP flag. The Ruby driver forms that used to live here are gone: a guarded core method keeps its saved body,
# which the Fiber path runs through a VM frame (the removed core block guard). The flag still gates the resumable variants of
# CodeGen::RESUMABLE_DUAL (codegen_method.rb), so BC2CPP_ENUM_STEP=0 turns those off too.
module EnumStep
  FLAG = 'BC2CPP_ENUM_STEP'

  module_function

  # Read once, when bc2cpp generates code. On by default; BC2CPP_ENUM_STEP=0 turns it off.
  def enabled?
    ENV[FLAG] != '0'
  end
end
