# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'nomethod_reviewed_probe'
require_relative 'constant_reviewed'
require_relative 'type_check_run'

# Every review site of the engine (docs/adr/0226, 0275, 0419, 0491, 0522): the NOMETHOD, PROVEN_MISS and STRICT_HINT
# sites of its full and hot-only closed-world runs, and the CONSTANT sites of its type check. Each is
# {gate:, spec:, file:, line:}, with the annotation key (SourceReview.key) its source line must carry.
module ReviewSites
  module_function

  def all(root, mrbc)
    NomethodReviewedProbe.review_sites(root, mrbc) + constants(root, mrbc)
  end

  # The untyped engine constants of the engine's type check (no sends pass: the constant analysis needs none).
  def constants(root, mrbc)
    facts = Dir.mktmpdir('review_sites') do |dir|
      result = TypeCheckRun.run(root: root, mrbc: mrbc, workdir: dir, sends: false)
      JSON.parse(File.read(result.facts_path))
    end
    abort 'review sites: the type check produced no constants' if facts['constants'].empty?

    ConstantReviewed.sites(facts['constants'], root: root)
  end
end
