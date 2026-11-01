# frozen_string_literal: true

require_relative 'index_closed_planner'

# CodeGen: INDEX_CLOSED. The by-name tail of the shared index helpers (bc2cpp_getidx, bc2cpp_getidx0,
# bc2cpp_setidx) becomes a class-tag switch over the native `[]` / `[]=` bodies plus a proven NoMethodError,
# when CallFacts::Answers says every class that can answer the name is one the helper has an arm for.
#
# The native bodies are static in mruby and read the CALLING frame (mrb_get_args), which a shared helper does not have;
# the pinned fork commit (mruby-expose-index-bodies, docs/patch-fork-tracking.md) exports each as a function that takes its arguments. The generator trusts an
# arm only after reading the sources the build compiles: the registration, the wrapper that calls the exported body,
# and, where the arm calls a public function directly (Hash, String), the method body it stands for.
class CodeGen
  INDEX_HELPER_NAMES = { 'getidx' => '[]', 'getidx0' => '[]', 'setidx' => '[]=' }.freeze

  INDEX_ARMS = IndexClosedPlanner::ARMS

  INDEX_CLASS_ARMS = IndexClosedPlanner::CLASS_ARMS

  INDEX_OWNER_GEMS = IndexClosedPlanner::OWNER_GEMS


  INDEX_CLASS_PRELUDE = <<~CPP
    // INDEX_CLOSED (ADR 0365): `k` is `base` or below it, which is where a singleton method of `base` is found.
    static inline bool bc2cpp_class_inherits(struct RClass* k, struct RClass* base) {
      for (struct RClass* c = k; c; c = c->super) if (c == base) return true;
      return false;
    }
    // Struct.new defines `.[]` on the class it makes, so it and the classes below it answer it; `class X < Struct` does not.
    static bool bc2cpp_struct_class_p(mrb_state* M, struct RClass* k) {
      if (!mrb_class_defined(M, "Struct")) return false;
      struct RClass* st = mrb_class_get(M, "Struct");
      mrb_sym members = mrb_intern_lit(M, "__members__");
      bool found = false;
      for (struct RClass* c = k; c; c = c->super) {
        if (c == st) return found;
        if (c->tt == MRB_TT_CLASS && !mrb_nil_p(mrb_iv_get(M, mrb_obj_value(c), members))) found = true;
      }
      return false;
    }

  CPP

  # The `site` the helper's chain passes to guarded_fallback_line: no real site, and nothing else is this object.
  INDEX_CLOSED_SITE = { index_closed: true }.freeze

  IndexPlan = IndexClosedPlanner::IndexPlan

  # For the stderr summary: each helper called, closed or the reason it is not.
  def index_closed_summary(codes)
    index_helpers_used(codes).map do |kind|
      closed = @index_helper_code.fetch(kind).include?('INDEX_CLOSED')
      "#{kind} #{closed ? 'closed' : "by-name (#{index_closed_reasons.fetch(INDEX_HELPER_NAMES.fetch(kind), :not_planned)})"}"
    end.join(', ').then { |s| s.empty? ? 'none' : s }
  end

  # The extern "C" declarations of the exported bodies `helpers` call (they are in no mruby header), and the class
  # helpers its class-object arm uses.
  def index_closed_prelude(helpers)
    specs = INDEX_ARMS.values.flat_map(&:values) + INDEX_CLASS_ARMS.values
    decls = specs.flat_map { |spec| (spec[:decl] || []).map { |decl| [decl, spec[:gem] ? '__attribute__((weak)) ' : ''] } }.uniq.select do |decl, _|
      helpers.match?(/\b#{decl[/(\w+)\(/, 1]}\(/)
    end
    return '' if decls.empty? && !helpers.include?('INDEX_CLOSED')

    out = +"// INDEX_CLOSED (ADR 0365): exported by the pinned fork commit (mruby-expose-index-bodies, docs/patch-fork-tracking.md), or by mruby-rgss/src/lib.cxx.\n"
    decls.each { |decl, weak| out << "extern \"C\" #{weak}#{decl};\n" }
    out << "\n"
    out << INDEX_CLASS_PRELUDE if helpers.include?('bc2cpp_class_inherits(') || helpers.include?('bc2cpp_struct_class_p(')
    out
  end

  # BC2CPP_INDEX_HELPER_CLOSED=0 keeps the by-name helpers.
  def index_closed_world?
    ENV['BC2CPP_INDEX_HELPER_CLOSED'] != '0' && @closed_world && @native_name_sources && @closed_world.global_refusal.nil? &&
      @closed_world.exact_instances_singleton_free? && @closed_world.method_missing_classes.empty?
  end

  # name => the refusal Symbol, for the summary.
  def index_closed_reasons
    @index_closed_reasons ||= {}
  end

  # The plan for `name` (`[]` or `[]=`), or nil with the reason in index_closed_reasons.
  def index_closed_plan(name)
    @index_closed_plan ||= {}
    return @index_closed_plan[name] if @index_closed_plan.key?(name)

    plan = planner.plan(name)
    index_closed_reasons[name] = plan if plan.is_a?(Symbol)
    @index_closed_plan[name] = plan.is_a?(Symbol) ? nil : plan
  end

  def planner
    @planner ||= IndexClosedPlanner.new(
      answers: call_facts_answers,
      registry: @registry,
      superclass_of: @superclass_of,
      struct_members: CodeGen.struct_members,
      source: method(:index_source),
      gems: CodeGen.build_gem_names,
      world: @closed_world,
      enabled: index_closed_world?,
      blocked_name: method(:devirt_blocked_name?)
    )
  end

  # Shared with integer_tag_else's Array-body proof: whether `owner`'s arm is
  # linked, and whether its registration and sources verify.
  def index_owner_linked?(owner, spec)
    planner.owner_linked?(owner, spec)
  end

  def index_arm_verified?(answers, name, owner, spec)
    planner.arm_verified?(name, owner, spec)
  end

  # The mruby tree root the build scans, from its src/array.c.
  def index_mruby_root
    @index_mruby_root ||= begin
      array = @native_name_sources.each_value.flat_map(&:to_a).find { |p| p.end_with?('/src/array.c') }
      array&.delete_suffix('/src/array.c') || false
    end
  end

  # The whitespace-stripped text of `relative` (below the mruby tree, or a repo path `mruby-...`), or nil.
  def index_source(relative)
    path = if relative.start_with?('mruby-')
             @native_name_sources.each_value.flat_map(&:to_a).find { |p| p.end_with?("/#{relative}") }
           elsif index_mruby_root
             File.join(index_mruby_root, relative)
           end
    return nil unless path && File.file?(path)

    @index_sources ||= {}
    @index_sources[path] ||= File.read(path, encoding: 'UTF-8').gsub(%r{/\*.*?\*/}m, '').gsub(/\s+/, '')
  end


  # INHERITED_GUARD for the helper chain: the strict subclasses of candidate `owner` whose lookup of the name ends at its
  # definition, from the plan's own resolution (the general rule declines a name with a native outside mruby's core).
  def index_closed_subclasses(owner)
    subs = @index_closed_build[:plan].resolution.select { |klass, (kind, o)| kind == :ruby && o == owner && klass != owner }.keys.sort
    @index_closed_build[:overflow] = true if subs.size > POLY_SMALL_N_INHERITED_MAX
    subs.first(POLY_SMALL_N_INHERITED_MAX)
  end

  # The else arm of the helper's chain: native arms and a proven NoMethodError, or nil to keep the by-name line.
  # `listed` is every class the chain above it covers.
  def index_closed_fallback(d, recv, name, argv, listed)
    build = @index_closed_build
    plan = build[:plan]
    ruby_classes = plan.resolution.select { |_, (kind, _)| kind == :ruby }.keys
    return nil unless ruby_classes.all? { |klass| listed.include?(klass) } && !build[:overflow]

    build[:used] = true
    index_closed_tail(plan, d, recv, name, argv)
  end

  def index_arm_test(spec, test)
    spec[:guard] ? "#{spec[:guard]} != nullptr && #{test}" : test
  end

  def index_closed_tail(plan, d, recv, name, argv)
    arms = INDEX_ARMS.fetch(name)
    getter = name == '[]'
    args = { key: 'bc2cpp_key', idx: argv[0], val: argv[1] }
    branches = plan.natives.map do |owner|
      spec = arms.fetch(owner)
      body = if spec[:call]
               "r#{d} = #{format(spec[:call], args)};"
             else
               "#{format(spec[:stmt], args)};\n      r#{d} = #{format(spec[:result], args)};"
             end
      "if (#{index_arm_test(spec, spec[:test].gsub('recv', recv))}) {\n      #{body}\n    }"
    end
    nomethod = "r#{d} = bc2cpp_nomethod_named(M, #{recv}, \"#{name}\", #{argv.size}, #{getter ? 'bc2cpp_key' : argv.join(', ')});"
    unless plan.classes.empty?
      classes = plan.classes.values.map do |spec|
        "if (#{index_arm_test(spec, spec[:test])}) {\n        r#{d} = #{spec[:call].gsub('recv', recv)};\n      }"
      end
      branches << "if (mrb_class_p(#{recv})) {\n      struct RClass* k = mrb_class_ptr(#{recv});\n      " \
                  "#{classes.join(' else ')} else {\n        #{nomethod}\n      }\n    }"
    end
    text = +"  // INDEX_CLOSED :#{name} -- every class that can answer is a chain arm above or one of: " \
            "#{(plan.natives + plan.classes.keys.map { |k| k ? "#{k}.#{name}" : "<Struct class>.#{name}" }).join(', ')}; " \
            "any other receiver is a proven NoMethodError\n"
    text << "  {\n"
    text << "    mrb_value bc2cpp_key = #{argv.first};\n" if getter
    text << "    #{branches.join(' else ')}#{branches.empty? ? '' : ' else '}{\n      #{nomethod}\n    }\n  }\n"
    text
  end

  # The closed body of helper `kind` (without the leading fast paths), or nil to keep the by-name form. `fast` is the
  # helper's own inline fast-path text, `chain_args` the arguments the chain passes on.
  def index_helper_closed_source(fast, name, argv)
    plan = index_closed_plan(name)
    return nil unless plan

    @index_closed_build = { plan: plan, used: false, overflow: false }
    chain = without_strict_hints do
      compile_poly_dispatch(name, 0, 'recv', argv, argv.size, closed_world_site: INDEX_CLOSED_SITE)
    end
    build = @index_closed_build
    chain ||= index_closed_fallback(0, 'recv', name, argv, []) if plan.resolution.none? { |_, (kind2, _)| kind2 == :ruby }
    unless chain && build[:used] && !build[:overflow] && !chain.match?(/\bmrb_funcall\w*\(|\bbc2cpp_send\(|\bbc2cpp_owner_call(?:_named)?\(/)
      index_closed_reasons[name] = :chain_uncovered
      @index_closed_plan[name] = nil
      return nil
    end

    "#{fast}mrb_value r0 = mrb_nil_value();\n#{chain}  return r0;\n"
  ensure
    @index_closed_build = nil
  end
end
