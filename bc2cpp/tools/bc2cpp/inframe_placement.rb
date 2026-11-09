# frozen_string_literal: true

# The experimental in-frame placement switch (docs/bc2cpp-placement-harness.md). Off by default; the shipped
# codegen never reads it on. The gates in scripts/bc2cpp/placement_harness_check.rb must pass before any code
# path emits a placed object, so the request is refused loudly until that codegen exists, rather than
# falling back to the heap silently (a fallback would make the harness's differential vacuous).
module InFramePlacement
  ENV_KEY = 'BC2CPP_EXPERIMENTAL_INFRAME_PLACEMENT'

  # TODO(placement): flip to true only together with the codegen that emits a placed object, once every gate
  # in docs/bc2cpp-placement-harness.md passes for it.
  IMPLEMENTED = false

  module_function

  def requested?
    ENV[ENV_KEY] == '1'
  end

  # Aborts when the experimental flag asks for placement codegen this build does not have.
  def refuse_if_requested!
    return unless requested?
    return if IMPLEMENTED

    abort "bc2cpp: #{ENV_KEY}=1 requests in-frame placement, which is not implemented " \
          '(stub: tools/bc2cpp/inframe_placement.rb). Unset it; see docs/bc2cpp-placement-harness.md.'
  end
end
