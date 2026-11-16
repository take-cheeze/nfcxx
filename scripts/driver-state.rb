#!/usr/bin/env ruby
# The record protocol between nfcxx's bash and its Ruby helpers (docs/notes/driver-state-design.md, section 4): one module
# for both directions, so every helper reads and writes the same records.
#
# Records are NUL-terminated. "k NAME" starts a group; each "v VALUE" adds one value (an empty group has no "v"; a scalar is
# a group with one value). A reply from Ruby names every group it changes, in full, then "z" (the end marker: bash stops
# when it does not see one). A refusal is "x MESSAGE" with no "z" after it. Values may contain anything except NUL.
#
# The bash half is state_put (input) and the explicit readers in nfcxx, one per call (see the design, section 4).
# tests/nfcxx-link/run.sh and tests/nfcxx-eccp-plan/run.sh check the helpers that use this module.

module DriverState
  module_function

  # the records of DATA as the groups they name (a Hash: name => values, in the order the groups were sent)
  def read_groups(data)
    groups = {}
    current = nil
    records = data.split("\0", -1)
    records.pop if records.last == ""
    records.each do |rec|
      case rec[0]
      when "k"
        current = rec[1..]
        groups[current] ||= []
      when "v"
        raise ArgumentError, "a value before any group" if current.nil?
        groups[current] << rec[1..]
      else
        raise ArgumentError, "unknown record #{rec[0].inspect}"
      end
    end
    groups
  end

  # the one value of a scalar group (an error when the group is missing or has another number of values)
  def scalar(groups, name)
    values = groups.fetch(name) { raise ArgumentError, "group #{name} is missing" }
    raise ArgumentError, "group #{name} needs one value" unless values.length == 1
    values[0]
  end

  # the groups of GROUPS (an array of [name, values] pairs), each written in full
  def write_groups(io, groups)
    groups.each do |name, values|
      io.write("k#{name}\0")
      values.each { |v| io.write("v#{v}\0") }
    end
  end

  # the end marker, written last by a reply that finished
  def write_end(io)
    io.write("z\0")
  end

  # a refusal: the bash prints MESSAGE and stops (no end marker follows it)
  def write_refusal(io, message)
    io.write("x#{message}\0")
  end
end

module DriverState
  module_function

  # realpath as the bash runs it (GNU realpath without -m): every component but the last must exist; a missing last
  # component is resolved in its existing directory. The error names the path as given (ENOENT).
  def gnu_realpath(path)
    File.realpath(path)
  rescue Errno::ENOENT
    parent = File.dirname(path)
    raise Errno::ENOENT, path if parent == path
    File.join(File.realpath(parent), File.basename(path))
  end
end
