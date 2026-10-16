# frozen_string_literal: true

# BLOCK_RETURNS (docs/adr/0472): native block-return declarations (sig/native) whose C function the source scan
# (BlockReturns.native_function_why) cannot verify, accepted after a person read the function. The key is the
# declaration ("Owner#name", a singleton owner spelled "Owner.singleton"); the value maps the native source's
# repository-relative path to the SHA-256 of the file as reviewed (a String, or an Array of them). A file that changes
# no longer matches, so the declaration fails the build until it is reviewed again.
#
# Every native declaration the scan verifies (today: RGSS::Profiler.section and .frame, mruby-rgss/src/profiler.cxx)
# needs no entry here.
module BlockReturns
  REVIEWED = {}.freeze
end
