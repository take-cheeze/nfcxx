#!/usr/bin/env ruby
# The driver's state records (restructure step 2 of docs/notes/driver-body-port.md), written by one process instead of by the bash
# state_put function (nfcxx). The driver passes each group as its arguments: the group's name, then its values, and a record
# separator (ASCII 30) after each group. The output is the same bytes state_put writes: "k NAME" then "v VALUE" for each value,
# each NUL-terminated, groups in order. The groups are held by the state object (scripts/nfcxx-state.rb), which writes them.
# Checked against state_put by tests/driver-state-records/run.sh.
#
#   ruby scripts/nfcxx-state-records.rb NAME VALUE... SEP NAME VALUE... SEP ...

require_relative "nfcxx-state"

SEP = "\x1e"

state = NfcxxState.new
current = nil
ARGV.each do |arg|
  if arg == SEP
    state.add(*current) if current
    current = nil
  elsif current.nil?
    current = [arg]
  else
    current << arg
  end
end
state.add(*current) if current
$stdout.write(state.records)
