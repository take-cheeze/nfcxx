# frozen_string_literal: true

# Parity between the two copies of the native-binding API lists: tools/bc2cpp/native_core_candidates.rb
# (FRAME_READERS, MRB_API_ALLOW) and scripts/native/binding_facts.py (FRAME_READERS, MRB_API_ALLOW). The Python list is
# the one reviewed for mrb_state-taking APIs, so the Ruby generator must never drift from it. Python is loaded for real
# (`-I -B`: no user site, no __pycache__ written into scripts/native).
#
#   ruby scripts/bc2cpp/native_api_lists_parity_check.rb
require 'open3'
require_relative '../../tools/bc2cpp/native_core_candidates'

ROOT = File.expand_path('../..', __dir__)
PY_DIR = File.join(ROOT, 'scripts', 'native')
PY_DUMP = <<~PY
  import json, sys
  sys.path.insert(0, sys.argv[1])
  import binding_facts
  print(json.dumps({
      'FRAME_READERS': sorted(binding_facts.FRAME_READERS),
      'MRB_API_ALLOW': sorted(binding_facts.MRB_API_ALLOW),
  }))
PY

FAILED = []
def check(what, ok)
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  FAILED << what unless ok
end

out, status = Open3.capture2('python3', '-I', '-B', '-c', PY_DUMP, PY_DIR)
unless status.success?
  puts "native_api_lists_parity_check: python3 could not load #{PY_DIR}/binding_facts.py"
  exit 1
end
py = JSON.parse(out)

rb_readers = NativeCoreCandidates::FRAME_READERS
rb_allow = NativeCoreCandidates::MRB_API_ALLOW.to_a

puts '== FRAME_READERS'
check('no duplicates on the Ruby side', rb_readers.uniq.size == rb_readers.size)
check("Ruby list equals binding_facts.py (#{py['FRAME_READERS'].size} names)", rb_readers.sort == py['FRAME_READERS'])

puts '== MRB_API_ALLOW'
check('no duplicates on the Ruby side', rb_allow.uniq.size == rb_allow.size)
check("Ruby list equals binding_facts.py (#{py['MRB_API_ALLOW'].size} names)", rb_allow.sort == py['MRB_API_ALLOW'])

puts
if FAILED.empty?
  puts 'native_api_lists_parity_check: all checks passed'
else
  puts "native_api_lists_parity_check: #{FAILED.size} failure(s)"
  exit 1
end
