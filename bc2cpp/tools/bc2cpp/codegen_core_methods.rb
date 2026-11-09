# frozen_string_literal: true

# CodeGen: the ancestry walk that proves a class's lookup path for the numeric helpers (see
# numeric_slow_spaceship_core?). No core method is inlined from a verified model here any more.
class CodeGen
  # `classes`, what they mix in, then Object, Kernel and BasicObject; nil when one
  # has an unknown mixin or a prepend that could sit ahead of the modelled method.
  def core_ancestry(*classes)
    seen = []
    work = classes + %w[Object Kernel BasicObject]
    until work.empty?
      klass = work.shift
      next if seen.include?(klass)
      return nil if @unknown_mixins.include?(klass) || !Array(@prepended_modules[klass]).empty?

      seen << klass
      work.concat(Array(@included_modules[klass]))
    end
    seen
  end
end
