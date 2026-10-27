# frozen_string_literal: true

# EMBED_INIT_GUARD: an owner whose ivars are embedded (CodeGen#select_embeddings) keeps them in the struct its compiled
# #initialize allocates (mrb_data_init); every other compiled method of the owner reads them through DATA_PTR. The
# choice rests on a cleanliness probe of that #initialize made before the final compile, so the final output is
# checked: if this run emits the owner but not a compiled #initialize that builds the storage (missing, or dropped by
# SKIP_UNSUPPORTED for an `#error`), the program would read DATA_PTR of a plain object. The build fails instead.
module EmbedInitGuard
  CODE = 'EMBED_INIT_GUARD'

  module_function

  # +initializers+: [owner, #initialize irep label (nil when the owner has none), the storage line its body must
  # contain] per embedding owner (CodeGen#embedding_initializers). +compiled+: the methods this run emits.
  def failures(initializers, compiled, only_owners)
    by_label = compiled.each_with_object({}) { |m, h| h[m[:label]] ||= m if m[:label] }
    initializers.filter_map do |owner, label, storage_line|
      next if only_owners && !only_owners.include?(owner)

      m = label && by_label[label]
      next "#{owner} embeds its ivars but this run emits no compiled #{owner}#initialize [#{CODE}]" unless m
      if m[:unsupported] || m[:code].include?('#error')
        next "#{owner} embeds its ivars but its #initialize does not compile [#{CODE}]"
      end
      next "#{owner}#initialize does not allocate the embedded storage [#{CODE}]" unless m[:code].include?(storage_line)
    end
  end
end
