# frozen_string_literal: true

# FIXPOINT_BOUNDS (ADR 0465): the whole-program fixed points run under a hard round limit. One round is the block;
# it returns true when something changed. The loop ends when a round changes nothing. A round limit reached while
# rounds still change is a build error that names the analysis and the loop; the partial result is never used.
#
# The limits are constants here, not environment switches. Each is far above what a convergent run of the engine
# needs; reaching one means an analysis is not monotone (a bug) or the program outgrew the limit, and either way the
# build must stop rather than ship facts that were still moving.
module Fixpoint
  class NotConverged < RuntimeError; end

  # The layout sweeps (ClassLayout, IvarLayout, ArrayElementLayout, HashElementLayout). They used to stop after 10
  # sweeps whether or not the table had settled, silently keeping a table that was still changing.
  SWEEP_LIMIT = 32
  # The pooled growth loops (return classes and class pools, the numeric pools). Every key's mask only grows by
  # union or is dropped for good, so they terminate; the limit keeps a slow one from stalling a build.
  GROWTH_LIMIT = 200

  module_function

  def iterate(analysis, limit)
    where = caller_locations(1, 1).first
    limit.times do
      return unless yield
    end
    raise NotConverged, "bc2cpp: #{analysis} did not reach a fixed point in #{limit} rounds " \
                        "(#{where.path}:#{where.lineno}); its facts were still changing, so none of them are used"
  end
end
