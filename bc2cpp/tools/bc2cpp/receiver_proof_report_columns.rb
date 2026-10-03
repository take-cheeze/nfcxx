# frozen_string_literal: true

# The row layout of BC2CPP_RECEIVER_PROOF_REPORT (receiver_proof_report.rb), shared with
# scripts/bc2cpp_receiver_proof_report.rb.
module ReceiverProofReport
  COLUMNS = %w[irep idx gem owner name argc source detail existing mask hyp hyp_complete why before after after_nil
               nomethod_delta reloc cells answerers floor_after floor_nil floor_reloc kinds percls pc_set pc_after pc_after_nil
               where].freeze
end
