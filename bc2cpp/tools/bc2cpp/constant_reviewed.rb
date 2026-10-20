# frozen_string_literal: true

require 'set'
require_relative 'source_review'

# CONSTANT (docs/adr/0491, 0522): a ratchet over the type check's untyped engine constants. A constant the analysis
# gives no type (no class pool, literal, integer, array-sum or constructed class) is TC1017 unless its source line
# carries a review annotation, `# bc2cpp-reviewed: constant <Name> -- reason`, on that line or the line above. An
# annotated constant that is now typed, or no longer exists, is TC1017 too, so the annotations can only shrink.
#
# Only engine constants are judged: a fixture or project run (`--files`) has no gate. The annotations are read from
# the engine's own sources, so the gate needs no list file.
module ConstantReviewed
  CODE = 'TC1017'
  ROOT = File.expand_path('../..', __dir__)
  # The engine's mrblib sources: where an engine constant's annotation can be written.
  ENGINE_SOURCE_GLOB = '{mruby-rpg2k,mruby-lcf,mruby-rgss}/**/*.rb'

  module_function

  # Gate: [{file:, line:, col:, message:}] for each unannotated untyped constant and each stale annotation.
  def violations(constants, root: ROOT)
    rows = engine(constants, root)
    untyped = rows.reject { |c| c['type'] }
    out = untyped.reject { |c| annotated?(c, root) }.sort_by { |c| c['name'] }.map do |c|
      { file: c['file'], line: c['line'], col: c['col'],
        message: "constant #{c['name']} has no type and no review annotation: give it a type, or read it and annotate " \
                 "its line (# bc2cpp-reviewed: constant #{c['name']} -- reason)" }
    end
    out + stale(rows, untyped, root: root)
  end

  # Annotations no untyped engine constant uses: the constant is typed now, or is not an engine constant of this program.
  def stale(rows, untyped, root: ROOT)
    engine_files(root).flat_map do |file|
      SourceReview.annotations(file).filter_map do |line, key|
        next unless key.start_with?('constant ')
        next if untyped.any? do |c|
          source_path(c, root) == file && SourceReview.key('constant', c['name']) == key &&
            SourceReview.annotation_lines(file, c['line']).include?(line)
        end

        typed = rows.find { |c| SourceReview.key('constant', c['name']) == key && c['type'] }
        message = if typed
                    "listed constant #{typed['name']} is typed (#{typed['type']}, #{typed['source']}): remove its annotation"
                  else
                    "annotated constant #{key.delete_prefix('constant ')} is not an engine constant of this program: " \
                      'remove its annotation'
                  end
        { file: file, line: line, col: 1, message: message }
      end
    end
  end

  # The gate's sites for the review-site dump: each untyped engine constant, with the source line it is read at.
  def sites(constants, root: ROOT)
    engine(constants, root).reject { |c| c['type'] }.map do |c|
      { gate: 'constant', spec: c['name'], file: source_path(c, root), line: c['line'] }
    end
  end

  def annotated?(row, root)
    return false unless row['file'] && row['line']

    SourceReview.annotated?(source_path(row, root), row['line'], SourceReview.key('constant', row['name']))
  end

  # The absolute path of a row's file: the analysis reports engine paths relative to the repository root.
  def source_path(row, root)
    File.expand_path(row['file'].to_s, root)
  end

  def engine_files(root)
    Dir.glob(File.join(root, ENGINE_SOURCE_GLOB)).sort
  end

  # The engine's rows: scope 'engine' and a file that holds the row's line. A row whose file does not hold that line
  # was attributed to the wrong file (mrbc names the previous file of a multi-file compile): mruby-io's STDIN, STDOUT and
  # STDERR (3rd/mruby/mrbgems/mruby-io/mrblib/io.rb, lines 292-296) come out this way, and are not engine source.
  def engine(constants, root = ROOT)
    constants.select { |c| c['scope'] == 'engine' && holds_line?(c, root) }
  end

  def holds_line?(row, root)
    return false unless row['file'] && row['line']

    path = source_path(row, root)
    File.file?(path) && row['line'] <= SourceReview.source(path).size
  end
end
