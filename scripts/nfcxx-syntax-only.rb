# nfcxx's -fsyntax-only (the type check): the command the driver runs instead, planned from the arguments as given. A command
# without -fsyntax-only is not one of these (plan returns nil). The rewrite is the one the frozen body made (its pre-loop block,
# tests/driver-body/nfcxx-oracle.sh before this change):
#   -E                  the command without -fsyntax-only (the preprocessor runs; nothing is compiled)
#   an explicit -o      -c, with the -o value replaced by the temporary object (the type check discards it)
#   otherwise           -c, the arguments, and -o to the temporary object
# The temporary object is DIR/x.o; the driver makes DIR and removes it. tests/driver-fsyntax/run.sh checks the rewrite against
# the goldens recorded from the body.

module NfcxxSyntaxOnly
  Plan = Struct.new(:args, :temp)

  # plan(argv) -> nil, or a Plan: args (the arguments to run the driver with, the temporary object DIR/x.o named where it is
  # used), and temp (whether DIR is needed)
  def self.plan(argv)
    return nil unless argv.include?("-fsyntax-only")

    rest = argv.reject { |a| a == "-fsyntax-only" }
    return Plan.new(rest, false) if rest.include?("-E")

    if rest.include?("-o")
      replaced = []
      skip = false
      rest.each do |a|
        if skip
          skip = false
          replaced << :object
          next
        end
        skip = (a == "-o")
        replaced << a
      end
      Plan.new(["-c", *replaced], true)
    else
      Plan.new(["-c", *rest, "-o", :object], true)
    end
  end

  # the arguments with the temporary object's path (dir) in place of :object
  def self.args_in(plan, dir)
    plan.args.map { |a| a == :object ? File.join(dir, "x.o") : a }
  end
end
