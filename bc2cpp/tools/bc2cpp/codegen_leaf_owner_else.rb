# frozen_string_literal: true

# LEAF_OWNER_ELSE: the else of a class test `bc2cpp_class_is(M, recv, K)` that is only an owner call whose owner set
# is {K} becomes the proven nomethod when the closed world proves K a leaf (ClosedWorld#exact_class? and
# #known_subclasses == [K]).
#
# Sound because the owner set names every class that answers the name (NAME_OWNER_SET), so a receiver that answers it
# is an instance of K or of a subclass of K; with no subclass, of K itself, singleton classes included, and
# bc2cpp_class_is accepts those (it compares the singleton's real class). Every receiver the else sees therefore
# raises NoMethodError, which bc2cpp_nomethod raises through mruby's own dispatch (and reports the proof violated if
# a method answered). A block call keeps its owner call; BC2CPP_LEAF_OWNER_ELSE=0 keeps them all.
module LeafOwnerElse
  ELSE_CALL = %r{(?<head>^[ \t]*if\ \((?<likely>mrb_likely\()?bc2cpp_class_is\(M,\ (?<recv>r\d+|self),
    \ (?<cls>[\w:]+\((?:M)?\))\)(?(<likely>)\))\)\ \{\n
    (?:(?!^[ \t]*\}).*\n){1,6}
    ^[ \t]*\}\ else\ \{\n)
    (?<indent>[ \t]*)(?<dest>r\d+)\ =\ bc2cpp_owner_call_named\(M,\ \k<recv>,\ "(?<name>[^"]+)",\ (?<level>\d),
    \ BC2CPP_OWNERS\("(?<owner>[^"]+)"\),\ mrb_nil_value\(\),\ (?<argc>\d+)(?<args>(?:,\ [^,);]+)*)\);
    \ /\*\ CLOSED_WORLD\ owner-call:\ \S+\ \*/$}x

  # `code` with each matching else rewritten; the block answers whether the guard's class expression names exactly
  # the one owner and that owner is a leaf.
  def self.rewrite(code)
    code.gsub(ELSE_CALL) do
      m = Regexp.last_match
      args = m[:args].split(', ').drop(1).first(m[:argc].to_i)
      next m[0] unless args.size == m[:argc].to_i && yield(m[:cls], m[:owner])

      marker = NomethodReviewed.marker(m[:name], self_receiver: m[:recv] == 'self', site: '?:0')
      "#{m[:head]}#{m[:indent]}// LEAF_OWNER_ELSE :#{m[:name]} -- #{m[:owner]} is a leaf and its only definer\n" \
        "#{m[:indent]}#{m[:dest]} = bc2cpp_nomethod_named(M, #{m[:recv]}, \"#{m[:name]}\"" \
        "#{args.empty? ? '' : ", #{args.size}, #{args.join(', ')}"}); #{marker}"
    end
  end

  def compile_method(label)
    @leaf_owner_else_stack ||= []
    outer = !@leaf_owner_else_stack.include?(label)
    @leaf_owner_else_stack.push(label)
    begin
      result = super
      outer ? leaf_owner_else_rewrite(result) : result
    ensure
      @leaf_owner_else_stack.pop
    end
  end

  private

  def leaf_owner_else_rewrite(result)
    return result unless result.is_a?(Hash) && result[:code].is_a?(String) && !result[:unsupported]
    return result if ENV['BC2CPP_LEAF_OWNER_ELSE'] == '0' || @clean_probe || !@closed_world
    return result unless result[:code].include?('CLOSED_WORLD owner-call')

    code = LeafOwnerElse.rewrite(result[:code]) { |cls, owner| leaf_owner_class_expr?(cls, owner) }
    code == result[:code] ? result : result.merge(code: code)
  end

  # `cls` names exactly `owner` (its owner-class getter or its RGSS native class accessor), and `owner` is a class
  # with no subclass in the closed world.
  def leaf_owner_class_expr?(cls, owner)
    return false if owner.end_with?('.singleton')

    named = owner_class_slots[cls] ||
            CodeGen::NATIVE_WRAPPER_CLASS_ACCESSORS.key(cls.delete_prefix('rgss::').delete_suffix('()'))
    named == owner && @closed_world.exact_class?(owner) && @closed_world.known_subclasses(owner) == [owner]
  end
end

CodeGen.prepend(LeafOwnerElse)
