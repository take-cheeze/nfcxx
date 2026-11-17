#!/usr/bin/env ruby
# The driver's state object (restructure step 1 of docs/notes/driver-body-restructure.md): the named groups the driver passes to its
# planners, held in one place. A group is a name and its values (an array of strings, possibly empty). records writes them as the
# driver's state records (the same bytes scripts/nfcxx-state-records.rb and the bash state_put write), in the order they were set.

class NfcxxState
  def initialize
    @names = []
    @values = {}
  end

  # set NAME, VALUE...: replaces the group (a name with no values is a group with none)
  def set(name, *values)
    @names << name unless @values.key?(name)
    @values[name] = values
    self
  end

  def get(name)
    @values.fetch(name, [])
  end

  def names = @names

  # the records: "k NAME" then "v VALUE" for each value, each NUL-terminated
  def records
    @names.map do |n|
      out = "k#{n}\0"
      @values[n].each { |v| out << "v#{v}\0" }
      out
    end.join
  end
end
