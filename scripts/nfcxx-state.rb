#!/usr/bin/env ruby
# The driver's state object (restructure step 1 of docs/notes/driver-body-restructure.md): the named groups the driver passes to its
# planners, held in one place. A group is a name and its values (an array of strings, possibly empty). records writes them as the
# driver's state records (the same bytes scripts/nfcxx-state-records.rb and the bash state_put write), in the order they were set.

class NfcxxState
  def initialize
    @groups = []
  end

  # add NAME, VALUE...: appends a group (a name with no values is a group with none). A repeated name is a second group, as the
  # driver's state_put calls write it.
  def add(name, *values)
    @groups << [name, values]
    self
  end

  def names = @groups.map(&:first)

  # the first group of NAME's values (the driver reads its state by name)
  def get(name)
    group = @groups.find { |n, _| n == name }
    group ? group[1] : []
  end

  # the records: "k NAME" then "v VALUE" for each value, each NUL-terminated, in the order the groups were added
  def records
    @groups.map do |name, values|
      out = "k#{name}\0"
      values.each { |v| out << "v#{v}\0" }
      out
    end.join
  end
end
