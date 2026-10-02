# frozen_string_literal: true

# CodeGen: ACCESSOR_RETURN_CLASS (ADR 0309).
#
# An `attr_reader` has no irep, so RETURN_CLASS_TABLE (ADR 0289) joined it as an unmodelled value and
# dropped every name it shares a definition with: `state.party`, `scene.db`, `owner.font` never gave a
# class. Its return is the slot's class set, the same pool a GETIV in a method of that class reads
# (ADR 0295), minus the nil an assigning constructor rules out.
class CodeGen
  # BC2CPP_RETURN_ACCESSORS=0 turns the accessor fact off.
  def return_accessor_classes_enabled?
    ENV.fetch('BC2CPP_RETURN_ACCESSORS', '1') != '0'
  end

  # Class set a getter definition (`d.irep.nil?`, kind :ivar_accessor) returns, or OTHER.
  def return_class_accessor_mask(d)
    return NumericFlow::OTHER unless return_accessor_classes_enabled? && @class_pools_on && d.kind == :ivar_accessor
    return NumericFlow::OTHER if d.name.end_with?('=') || d.owner.end_with?('.singleton') || d.owner.start_with?('<')

    pool = @class_ivar_pools[[numeric_family(d.owner), d.name]]
    return NumericFlow::OTHER unless pool

    numeric_ivar_assured?(d.owner, d.name) ? pool : pool | NumericFlow::NIL
  end
end
