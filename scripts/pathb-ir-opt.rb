# Path B: IR-to-IR passes shared by the back ends (docs/notes/pathb-ir-passes.md). Reads the IR text of
# scripts/pathb-dump --ir and writes the same IR with the passes applied; every back end that reads that text can run
# them, and the device pass of scripts/sycl-build.sh does so when NFCXX_IR_OPT=inline is set.
#
# Usage: ruby scripts/pathb-ir-opt.rb [--inline] [--max-depth=N] [--report] [FILE.ir | -] > out.ir
#
#   --inline     call inlining. A statement (let %D T (call T &"f" ARGS...)) or (eval (call T &"f" ARGS...)) of a function
#                of the module is replaced by f's body. f's ids become fresh ids of the caller, its slots become caller
#                slots with new names (hoisted to the caller's header), its parameters are bound to the arguments, and
#                its final return becomes (let %D T OPERAND). A callee is inlined only when its returns are all in tail
#                position (none, or the last statement); refused callees are: constructors and destructors, sret, byval
#                and ellipsis parameters, struct or array results, struct or bool parameters, printf, recursion, goto and
#                label, and work-group statics (the emitters key those by their function). Rounds repeat for nested calls,
#                up to --max-depth (default 4, the device inliner's depth in pathb-ptx-emit).
#   --report     the number of calls inlined and the refusal reasons, on stderr.
#
# Exit status: 0 written; 1 malformed IR (on stderr).

class BadIR < StandardError; end

HEADER_HEADS = ["ret", "params", "slot", "static", "weak", "constructor", "destructor"]

# Tokens: "(", ")", and atoms as their raw text. A string keeps its quotes; $"x" and &"x" keep their prefix.
def tokenize(text)
  toks = []
  i = 0
  n = text.length
  while i < n
    c = text.getbyte(i)
    if c == 32 || c == 10 || c == 9 || c == 13
      i += 1
    elsif c == 40 || c == 41                      # ( )
      toks << text[i, 1]
      i += 1
    elsif c == 34 || ((c == 36 || c == 38) && text.getbyte(i + 1) == 34)   # " or $" or &"
      j = c == 34 ? i + 1 : i + 2
      while true
        raise BadIR, "unterminated string in IR" if j >= n
        break if text.getbyte(j) == 34
        j += text.getbyte(j) == 92 ? 2 : 1
      end
      toks << text[i..j]
      i = j + 1
    else
      j = i
      while j < n
        d = text.getbyte(j)
        break if d == 32 || d == 10 || d == 9 || d == 13 || d == 40 || d == 41
        j += 1
      end
      toks << text[i...j]
      i = j
    end
  end
  toks
end

def parse(toks)
  stack = [[]]
  toks.each do |t|
    if t == "("
      stack.push([])
    elsif t == ")"
      raise BadIR, "unbalanced ')' in IR" if stack.length == 1
      f = stack.pop
      stack.last << f
    else
      stack.last << t
    end
  end
  raise BadIR, "unbalanced '(' in IR" if stack.length != 1
  stack[0]
end

def show(x)
  return x unless x.is_a?(Array)
  "(" + x.map { |y| show(y) }.join(" ") + ")"
end

def head(x)
  (x.is_a?(Array) && x[0].is_a?(String)) ? x[0] : nil
end

# The name in a "..." string, $"..." or &"..." atom.
def unq(s)
  s = s[1..-1] if s[0] == "$" || s[0] == "&"
  (s.length >= 2 && s[0] == "\"") ? s[1..-2] : s
end

def count_heads(x, name)
  return 0 unless x.is_a?(Array)
  n = head(x) == name ? 1 : 0
  x.each { |y| n += count_heads(y, name) }
  n
end

def atoms_of(x, out = [])
  if x.is_a?(Array)
    x.each { |y| atoms_of(y, out) }
  else
    out << x
  end
  out
end

def id_number(s)
  return nil unless s.is_a?(String) && s.length > 1 && s[0] == "%"
  k = 1
  while k < s.length
    d = s.getbyte(k)
    return nil if d < 48 || d > 57
    k += 1
  end
  s[1..-1].to_i
end

def max_id(x)
  m = 0
  atoms_of(x).each do |a|
    k = id_number(a)
    m = k if k && k > m
  end
  m
end

def contains_wgs?(x)
  atoms_of(x).any? { |a| a.is_a?(String) && a.include?("work_group_static") }
end

def copy_form(x)
  x.is_a?(Array) ? x.map { |y| copy_form(y) } : x
end

# Why a function cannot be inlined, or nil when it can.
def refusal(fn, name)
  return "ctor/dtor" if fn.any? { |f| head(f) == "constructor" || head(f) == "destructor" }
  params = fn.find { |f| head(f) == "params" }
  if params
    params.drop(1).each do |p|
      return "sret/byval/ellipsis" if head(p) == "sret" || head(p) == "ellipsis"
      return "struct/bool parameter" if head(p) == "param" && (head(p[3]) == "struct" || p[3] == "bool")
    end
  end
  ret = fn.find { |f| head(f) == "ret" }
  return "struct/array result" if ret && (head(ret[1]) == "struct" || head(ret[1]) == "array")
  atoms = atoms_of(fn)
  return "printf" if atoms.any? { |a| a == "&\"printf\"" }
  return "recursion" if atoms.any? { |a| a == "&\"#{name}\"" }
  body = fn.drop(2)
  return "goto/label" if count_heads(body, "goto") + count_heads(body, "label") > 0
  return "work-group static" if fn.any? { |f| head(f) == "slot" && contains_wgs?(f) }
  rets = count_heads(body, "return")
  return "return not in tail position" unless rets == 0 || (rets == 1 && head(body.last) == "return")
  nil
end

# The statement a call form is: [dest, dest type, call] or [nil, nil, call], or nil.
def call_statement(s)
  return nil unless s.is_a?(Array)
  if head(s) == "let" && head(s[3]) == "call"
    [s[1], s[2], s[3]]
  elsif head(s) == "eval" && head(s[1]) == "call"
    [nil, nil, s[1]]
  end
end

# The facts of a callee that every call site of it needs: its return, parameters, slots, statements and returned operand.
# Computed once per callee (inline_pass keeps them while the callee is unchanged): a call site used to scan the whole callee.
def callee_info(fn)
  ret = fn.find { |f| head(f) == "ret" }
  params = fn.find { |f| head(f) == "params" }.drop(1)
  body = fn.drop(2)
  slots = body.select { |f| head(f) == "slot" }
  stmts = body.reject { |f| HEADER_HEADS.include?(head(f)) }
  ret_op = nil
  if stmts.length > 0 && head(stmts.last) == "return"
    ret_op = stmts.last[1]
    stmts = stmts[0...-1]
  end
  { ret: ret, rtext: show(ret[1]), params: params, slots: slots, stmts: stmts, ret_op: ret_op }
end

# Replaces one call statement by the callee's statements. Returns [hoisted slots, statements] or nil.
def expand_call(s, fns, st)
  parts = call_statement(s)
  return nil unless parts
  dest, dtype, call = parts
  return nil unless call.length >= 3 && call[2].is_a?(String) && call[2][0, 2] == "&\""
  cname = unq(call[2])
  fn = fns[cname]
  return nil unless fn
  # The reason depends only on the callee's form, so it is computed once per callee (inline_pass clears it when the callee changes).
  reason = st[:rc].fetch(cname) { st[:rc][cname] = refusal(fn, cname) }
  if reason
    st[:refused][reason] = (st[:refused][reason] || 0) + 1
    return nil
  end
  info = st[:ic].fetch(cname) { st[:ic][cname] = callee_info(fn) }
  rtype = info[:ret][1]
  return nil unless show(call[1]) == info[:rtext]
  return nil if dest && rtype == "void"
  params = info[:params]
  args = call.drop(3)
  return nil unless params.length == args.length

  st[:k] += 1
  k = st[:k]
  map = {}
  # A byval parameter is the address of the callee's own copy of the argument object: a slot of the caller that holds the copy
  # (the size and alignment come from the parameter's form, be/nfcxx_ir.c), made by a copy from the argument's address.
  byval_pre = []
  byval_slots = []
  params.each_with_index do |p, i|
    if head(p[3]) == "byval"
      bt = p[3][1]
      bsize = p[3][2]
      balign = p[3][3]
      name = "\"#{unq(p[2])}.i#{k}\""
      arg = args[i]
      arg = arg[2] if head(arg) == "byval"   # the call passes (byval TYPE TMP): TMP is the argument's address
      map[p[1]] = "%#{st[:next]}"
      st[:next] += 1
      byval_slots << ["slot", name, bt, bsize, balign]
      byval_pre << ["let", map[p[1]], ["ptr", bt], ["offset", "$#{name}", "0"]]
      byval_pre << ["copy", bsize, "$#{name}", arg, balign]
    else
      map[p[1]] = args[i]
    end
  end
  slots = info[:slots]
  slots.each { |sl| map["$#{sl[1]}"] = "$\"#{unq(sl[1])}.i#{k}\"" }
  hoisted = slots.map { |sl| ["slot", "\"#{unq(sl[1])}.i#{k}\""] + sl.drop(2) } + byval_slots
  stmts = info[:stmts]
  ret_op = info[:ret_op]
  return nil if dest && ret_op.nil?
  out = byval_pre + stmts.map { |x| subst(x, map, st) }
  out << ["let", dest, dtype, subst(ret_op, map, st)] if dest
  st[:inlined] += 1
  [hoisted, out]
end

# The callee's form with its parameters, slots and fresh ids substituted.
def subst(x, map, st)
  if x.is_a?(Array)
    return x.map { |y| subst(y, map, st) }
  end
  return copy_form(map[x]) if map.key?(x)
  if id_number(x)
    map[x] = "%#{st[:next]}"
    st[:next] += 1
    return map[x]
  end
  x
end

def rewrite(list, fns, st)
  out = []
  list.each do |s|
    exp = s.is_a?(Array) ? expand_call(s, fns, st) : nil
    if exp
      st[:hoist].concat(exp[0])
      out.concat(exp[1])
    elsif s.is_a?(Array)
      out << rewrite(s, fns, st)
    else
      out << s
    end
  end
  out
end

# Hoisted slots go after the header (ret, params and the caller's own slots).
def insert_slots(children, slots)
  return children if slots.empty?
  idx = -1
  children.each_with_index { |f, i| idx = i if HEADER_HEADS.include?(head(f)) || head(f) == "ret" || head(f) == "params" }
  children[0, idx + 1] + slots + children[(idx + 1)..-1]
end

def inline_pass(forms, max_depth, report)
  fns = {}
  forms.each { |f| fns[unq(f[1])] = f if head(f) == "function" }
  refused = {}
  inlined = 0
  counter = { k: 0 }
  reasons = {}   # callee name -> refusal reason (nil: inlinable); see expand_call
  infos = {}     # callee name -> callee_info; dropped with the reason when the callee changes
  max_depth.times do
    round = 0
    forms.each_with_index do |f, i|
      next unless head(f) == "function"
      name = unq(f[1])
      st = { next: max_id(f) + 1, k: counter[:k], hoist: [], inlined: 0, refused: refused, rc: reasons, ic: infos }
      children = rewrite(f.drop(2), fns, st)
      counter[:k] = st[:k]
      next if st[:inlined] == 0
      round += st[:inlined]
      forms[i] = ["function", f[1]] + insert_slots(children, st[:hoist])
      fns[name] = forms[i]
      reasons.delete(name)
      infos.delete(name)
    end
    inlined += round
    break if round == 0
  end
  if report
    $stderr.write("pathb-ir-opt: inlined #{inlined} calls\n")
    refused.keys.each { |r| $stderr.write("pathb-ir-opt: refused #{refused[r]} call(s): #{r}\n") }
  end
  forms
end

def read_text(path)
  if path.nil? || path == "-"
    $stdin.read
  else
    File.open(path, "rb") { |f| f.read }
  end
end

# ---- scalar replacement of aggregates (--sroa) ----------------------------------------------------------------------------
# A struct slot whose object is only read and written at constant offsets is replaced by one scalar slot per field the object
# is accessed at. The accesses may go through the slot's address or through addresses derived from it (offset, bitcast).
# Slots that a copy connects form one group, which shares its fields. A group is refused when one of its addresses is used in a
# way the pass does not model (a call argument, a stored address, index, nonnull, a volatile access), when two fields overlap
# with other types, when a copy out of the group needs bytes that no field covers, or when a copy's size is not the object's.
# A copy into the group is a per-field copy; the bytes that no field reads are never written.

SROA_SIZES = { "bool" => 1, "char" => 1, "signed_char" => 1, "unsigned_char" => 1, "short" => 2, "unsigned_short" => 2,
               "int" => 4, "unsigned_int" => 4, "float" => 4, "long" => 8, "unsigned_long" => 8, "long_long" => 8,
               "unsigned_long_long" => 8, "double" => 8 }.freeze
SROA_CONTAINERS = %w[then else body step block].freeze

def scalar_size_of(t)
  if t.is_a?(String)
    SROA_SIZES[t]
  elsif head(t) == "ptr"
    8
  elsif head(t) == "const" && t.length == 2
    scalar_size_of(t[1])
  end
end

def all_forms(x, out = [])
  if x.is_a?(Array)
    out << x
    x.each { |y| all_forms(y, out) }
  end
  out
end

def atoms_flat(x, out = [])
  if x.is_a?(Array)
    x.each { |y| atoms_flat(y, out) }
  else
    out << x
  end
  out
end

class SroaGroups
  def initialize
    @parent = {}
  end

  def find(x)
    @parent[x] = x unless @parent.key?(x)
    root = x
    root = @parent[root] while @parent[root] != root
    @parent[x] = root
    root
  end

  def union(a, b)
    ra = find(a)
    rb = find(b)
    @parent[ra] = rb unless ra == rb
  end
end

# Returns the children of a function with the candidate slots replaced (or the same children when nothing changes).
# A pointer slot that holds the address of a struct slot (the inlined callee's copy of its `this`) is read as that address. Its one
# store is removed when every other use is a let of a load of the slot, after the store in the same statement list (straight-line
# code, so the store dominates the loads), and when the stored value is the struct slot's address, or an offset or bitcast of it
# that is defined earlier in that list. Each such load becomes the address (offset of the struct slot). Anything else stays.
def promote_address_slots(children)
  ptr_slots = {}
  struct_slots = {}
  children.each do |f|
    next unless head(f) == "slot"
    t = f[2]
    t = t[1] while head(t) == "const"
    ptr_slots[unq(f[1])] = true if head(t) == "ptr"
    struct_slots[unq(f[1])] = true if head(f[2]) == "struct"
  end
  return children if ptr_slots.empty?
  counts = Hash.new(0)
  atoms_flat(children).each { |a| counts[a] += 1 if a.is_a?(String) && a.start_with?("$\"") }
  promoted_count = [0]
  promote_in_list = lambda do |list|
    i = 0
    addr = {}   # value name => [struct slot name, byte offset], defined in this list so far
    while i < list.length
      f = list[i]
      if head(f) == "store" && f.length == 4 && f[2].is_a?(String) && f[2].start_with?("$\"") && ptr_slots[unq(f[2])]
        n = unq(f[2])
        v = f[3]
        target = nil
        if v.is_a?(String) && v.start_with?("$\"") && struct_slots[unq(v)]
          target = [unq(v), 0]
        elsif v.is_a?(String) && addr[v]
          target = addr[v]
        end
        if target && counts["$\"#{n}\""] == 1 + count_in_forms(list.drop(i + 1), "$\"#{n}\"")
          loads = all_forms(list.drop(i + 1)).select { |sf| head(sf) == "load" && sf.length == 3 && sf[2] == "$\"#{n}\"" }
          lets = all_forms(list.drop(i + 1)).select { |sf| head(sf) == "let" && sf.length == 4 && head(sf[3]) == "load" && sf[3][2] == "$\"#{n}\"" }
          if lets.length == loads.length && lets.length > 0
            lets.each { |sf| sf[3] = ["offset", "$\"#{target[0]}\"", target[1].to_s] }
            list.delete_at(i)
            promoted_count[0] += 1
            next
          end
        end
      elsif head(f) == "let" && f.length == 4 && f[1].is_a?(String) && f[1].start_with?("%")
        rv = f[3]
        if head(rv) == "offset" && rv.length == 3 && rv[1].is_a?(String) && rv[1].start_with?("$\"") && struct_slots[unq(rv[1])]
          addr[f[1]] = [unq(rv[1]), rv[2].to_i]
        elsif head(rv) == "bitcast" && rv.length == 3 && rv[2].is_a?(String) && rv[2].start_with?("$\"") && struct_slots[unq(rv[2])]
          addr[f[1]] = [unq(rv[2]), 0]
        elsif head(rv) == "offset" && rv.length == 3 && rv[1].is_a?(String) && addr[rv[1]]
          addr[f[1]] = [addr[rv[1]][0], addr[rv[1]][1] + rv[2].to_i]
        elsif head(rv) == "bitcast" && rv.length == 3 && rv[2].is_a?(String) && addr[rv[2]]
          addr[f[1]] = addr[rv[2]].dup
        end
      end
      i += 1
    end
    list.each { |x| promote_in_list.call(x) if x.is_a?(Array) }
  end
  # a store of a value that is itself a promoted load becomes visible to the next round
  4.times do
    before = promoted_count[0]
    promote_in_list.call(children)
    break if promoted_count[0] == before
  end
  children
end

def count_in_forms(list, atom)
  atoms_flat(list).count { |a| a == atom }
end

def sroa_function(children, counter)
  children = promote_address_slots(children)
  slots = {}   # name => [type, size, align]
  children.each do |f|
    next unless head(f) == "slot" && head(f[2]) == "struct" && !contains_wgs?(f[2])
    slots[unq(f[1])] = [f[2], f[3].to_i, f[4].to_i]
  end
  return children if slots.empty?

  # the names an address can have: "$\"name\"" for a slot, "%N" for a value derived from one
  alias_of = {}   # value name => [slot name, byte offset]
  base_of = lambda do |a|
    next nil unless a.is_a?(String)
    if a.start_with?("$\"") && slots.key?(unq(a))
      [unq(a), 0]
    else
      alias_of[a]
    end
  end
  all = all_forms(children)
  all.each do |s|
    next unless head(s) == "let" && s.length == 4 && s[1].is_a?(String) && s[1].start_with?("%")
    rv = s[3]
    if head(rv) == "offset" && rv.length == 3 && base_of.call(rv[1])
      b = base_of.call(rv[1])
      alias_of[s[1]] = [b[0], b[1] + rv[2].to_i]
    elsif head(rv) == "bitcast" && rv.length == 3 && base_of.call(rv[2])
      alias_of[s[1]] = base_of.call(rv[2]).dup
    elsif rv.is_a?(String) && base_of.call(rv)
      alias_of[s[1]] = base_of.call(rv).dup   # a copy of an address
    end
  end

  # the uses each name may have: the positions the pass models
  allowed = Hash.new(0)
  all.each do |s|
    case head(s)
    when "load", "store"
      allowed[s[2]] += 1 if s[2].is_a?(String)
    when "copy"
      allowed[s[2]] += 1 if s[2].is_a?(String)
      allowed[s[3]] += 1 if s[3].is_a?(String)
    when "nonnull"
      # the address of an object is never null: the check goes with the object
      allowed[s[1]] += 1 if s.length == 2 && s[1].is_a?(String)
    when "let"
      next unless s.length == 4 && alias_of.key?(s[1])
      allowed[s[1]] += 1
      rv = s[3]
      if head(rv) == "offset" then allowed[rv[1]] += 1
      elsif head(rv) == "bitcast" then allowed[rv[2]] += 1
      elsif rv.is_a?(String) then allowed[rv] += 1
      end
    end
  end
  total = Hash.new(0)
  atoms_flat(children).each { |a| total[a] += 1 if a.is_a?(String) && (a.start_with?("$\"") || alias_of.key?(a)) }

  groups = SroaGroups.new
  slots.each_key { |n| groups.find(n) }
  refused = {}
  refuse_names = []   # slots refused before the groups are merged: the refusal goes to their group after the merges
  fields = Hash.new { |h, k| h[k] = {} }   # slot name => { offset => type }
  copies = []
  total.each do |a, cnt|
    b = base_of.call(a)
    next unless b
    next if cnt == allowed[a]
    $stderr.write("sroa: #{$sroa_fn} #{b[0]}: #{a} used #{cnt} times, #{allowed[a]} in modelled positions\n") if $sroa_debug
    all.each { |sf| $stderr.write("sroa:   use in #{head(sf)} #{sf.map { |x| x.is_a?(Array) ? head(x).to_s : x.to_s }.join(' ')[0, 120]}\n") if $sroa_debug && sf.include?(a) } if $sroa_debug
    refuse_names << b[0]
  end
  all.each do |s|
    case head(s)
    when "load", "store"
      next unless s.length >= 3
      b = base_of.call(s[2])
      next unless b
      ty = s[1]
      if fields[b[0]].key?(b[1]) && fields[b[0]][b[1]] != ty
        $stderr.write("sroa: #{$sroa_fn} #{b[0]}: field #{b[1]} with two types\n") if $sroa_debug
        refuse_names << b[0]
      else
        fields[b[0]][b[1]] = ty
      end
      vb = base_of.call(s[3]) if head(s) == "store"
      refuse_names << vb[0] if vb
    when "copy"
      db = base_of.call(s[2])
      sb = base_of.call(s[3])
      next unless db || sb
      # the copy's ALIGN (its last item) is the object's alignment: a filler field may not be wider than it
      copies << [db, sb, s[1].to_i, s.length >= 5 ? s[4].to_i : 1]
    end
  end
  copies.each do |db, sb, bytes|
    groups.union(db[0], sb[0]) if db && sb
    [db, sb].each do |b|
      next unless b
      refused[groups.find(b[0])] = true if b[1] != 0 || bytes != slots[b[0]][1]
    end
  end
  refuse_names.each { |n| refused[groups.find(n)] = true }
  group_fields = Hash.new { |h, k| h[k] = {} }
  slots.each_key do |n|
    fields[n].each { |k, t| group_fields[groups.find(n)][k] = t }
  end
  group_fields.each do |g, fs|
    fs.each { |k, t| refused[g] = true if scalar_size_of(t).nil? }
    keys = fs.keys.sort
    keys.each_cons(2) do |a, b|
      if a + scalar_size_of(fs[a]).to_i > b
        $stderr.write("sroa: fields overlap at #{a} and #{b}\n") if $sroa_debug
        refused[g] = true
      end
    end
  end
  # a copy out of the group must write every byte of the object: the bytes no access reads get filler fields. The group's
  # copy in (from memory) gives them their values, so they are defined; a group that is only written is refused above when
  # its fields overlap.
  copies.each do |db, sb, bytes, align|
    next if db || !sb
    g = groups.find(sb[0])
    fs = group_fields[g]
    pos = 0
    fs.keys.sort.each do |k|
      refused[g] = true if k < pos
      pos = k + scalar_size_of(fs[k]).to_i
    end
    if pos > bytes
      refused[g] = true
    else
      gap_start = 0
      occupied = fs.keys.sort
      cursor = 0
      limit = bytes
      while cursor < limit
        if fs.key?(cursor)
          cursor += scalar_size_of(fs[cursor]).to_i
          next
        end
        nxt = occupied.find { |k| k > cursor } || limit
        nxt = limit if nxt > limit
        while cursor < nxt
          chunk = [8, 4, 2, 1].find { |c| c <= align && cursor % c == 0 && cursor + c <= nxt }
          fs[cursor] = { 8 => "unsigned_long", 4 => "unsigned_int", 2 => "unsigned_short", 1 => "unsigned_char" }[chunk]
          cursor += chunk
        end
      end
    end
  end
  replaced = {}
  slots.each_key { |n| replaced[n] = true unless refused[groups.find(n)] }
  return children if replaced.empty?

  field_name = lambda { |n, k| "\"#{n}.f#{k}\"" }
  fresh = lambda do
    counter[:n] += 1
    "%#{counter[:n]}"
  end
  fs_of = lambda { |n| group_fields[groups.find(n)] }
  rewritable = lambda { |addr| (b = base_of.call(addr)) && replaced[b[0]] ? b : nil }

  # the rewrite: an expression rewrites the accesses of the replaced slots; a statement list expands the copies
  rw_expr = nil
  rw_expr = lambda do |x|
    return x unless x.is_a?(Array)
    if head(x) == "load" && x.length == 3 && (b = rewritable.call(x[2]))
      ["load", x[1], "$" + field_name.call(b[0], b[1])]
    else
      x.map { |y| rw_expr.call(y) }
    end
  end
  rw_list = nil
  rw_stmt = nil
  expand_copy = nil
  rw_list = lambda do |list|
    res = []
    list.each do |s|
      unless s.is_a?(Array)
        res << s
        next
      end
      h = head(s)
      if h == "let" && s.length == 4 && alias_of.key?(s[1]) && replaced[alias_of[s[1]][0]]
        next
      elsif h == "nonnull" && s.length == 2 && rewritable.call(s[1])
        next
      elsif h == "copy" && s.length >= 4 && (rewritable.call(s[2]) || rewritable.call(s[3]))
        res.concat(expand_copy.call(s))
      elsif SROA_CONTAINERS.include?(h) || h == "case" || h == "default"
        res << rw_stmt.call(s)
      else
        res << rw_stmt.call(s)
      end
    end
    res
  end
  rw_stmt = lambda do |s|
    h = head(s)
    if SROA_CONTAINERS.include?(h)
      [h] + rw_list.call(s.drop(1))
    elsif h == "store" && s.length == 4 && (b = rewritable.call(s[2]))
      ["store", s[1], "$" + field_name.call(b[0], b[1]), rw_expr.call(s[3])]
    elsif h == "if" || h == "loop" || h == "switch"
      s.map { |c| SROA_CONTAINERS.include?(head(c)) || head(c) == "case" || head(c) == "default" ? rw_list.call([c]).first : rw_expr.call(c) }
    else
      rw_expr.call(s)
    end
  end
  expand_copy = lambda do |s|
    bytes = s[1]
    db = rewritable.call(s[2])
    sb = rewritable.call(s[3])
    out = []
    if db && sb
      fs_of.call(db[0]).each do |k, t|
        v = fresh.call
        out << ["let", v, t, ["load", t, "$" + field_name.call(sb[0], sb[1] + k)]]
        out << ["store", t, "$" + field_name.call(db[0], db[1] + k), v]
      end
    elsif db
      fs_of.call(db[0]).each do |k, t|
        q = fresh.call
        v = fresh.call
        out << ["let", q, ["ptr", t], ["offset", s[3], k.to_s]]
        out << ["let", v, t, ["load", t, q]]
        out << ["store", t, "$" + field_name.call(db[0], db[1] + k), v]
      end
    else
      fs_of.call(sb[0]).each do |k, t|
        v = fresh.call
        q = fresh.call
        out << ["let", v, t, ["load", t, "$" + field_name.call(sb[0], sb[1] + k)]]
        out << ["let", q, ["ptr", t], ["offset", s[2], k.to_s]]
        out << ["store", t, q, v]
      end
    end
    out
  end

  out = []
  children.each do |f|
    if head(f) == "slot" && replaced[unq(f[1])]
      fs_of.call(unq(f[1])).each { |k, t| out << ["slot", field_name.call(unq(f[1]), k), t, scalar_size_of(t), scalar_size_of(t)] }
    else
      out << f
    end
  end
  rw_list.call(out)
end

# A value name %N (a digit after the %). A byte test: the regex it replaces was run on every atom.
def numbered_id?(a)
  return false unless a.is_a?(String) && a.length > 1 && a.getbyte(0) == 37
  d = a.getbyte(1)
  d >= 48 && d <= 57
end

# Every value a function uses is defined in it (a parameter, or a let or phi). A rewrite that loses a definition is refused.
def defined_values_ok?(children)
  defined = {}
  all_forms(children).each do |f|
    defined[f[1]] = true if (head(f) == "let" || head(f) == "phi") && f[1].is_a?(String)
    defined[f[1]] = true if (head(f) == "param" || head(f) == "sret") && f[1].is_a?(String)
  end
  atoms_flat(children).all? { |a| !numbered_id?(a) || defined[a] }
end

# An index that a bounds check has proved to be 0 (`(bounds I 1)` traps unless 0 <= I < 1): (index B I S) is the address B. The
# check dominates the index in its statement list, or an enclosing one.
def fold_unit_index(list, unit)
  unit = unit.dup
  list.each_with_index do |s, i|
    next unless s.is_a?(Array)
    if head(s) == "bounds" && s.length == 3 && s[1].is_a?(String) && (s[2] == "1" || s[2] == "0x1")
      unit[s[1]] = true
    elsif head(s) == "let" && s.length == 4 && head(s[3]) == "index" && s[3].length == 4 && unit[s[3][2]]
      list[i] = ["let", s[1], s[2], ["offset", s[3][1], "0"]]
      next
    end
    s.each { |x| fold_unit_index(x, unit) if x.is_a?(Array) }
  end
  list
end

# ---- constant propagation through scalar slots (part of --sroa) -----------------------------------------------------------
# A scalar slot whose every use is a plain load or store of its type, and whose stores are constants, gives its loads the stored
# constant while the store is the latest one in the same statement list. Nested statements forget what they may store. A let that
# is a constant is replaced by the constant in its uses, and an index by a constant is an offset.
CPROP_SCALARS = ["bool", "char", "signed_char", "unsigned_char", "short", "unsigned_short", "int", "unsigned_int", "long",
                 "unsigned_long", "long_long", "unsigned_long_long", "float", "double"].freeze

def int_text?(t)
  return false unless t.is_a?(String) && t.length > 0
  k = t[0] == "-" ? 1 : 0
  return false if k >= t.length
  while k < t.length
    d = t.getbyte(k)
    return false if d < 48 || d > 57
    k += 1
  end
  true
end

def const_form?(x)
  head(x) == "const" && x.length == 3 && x[1].is_a?(String)
end

def cprop_function(children)
  scalar = {}
  children.each do |f|
    next unless head(f) == "slot" && f[2].is_a?(String) && CPROP_SCALARS.include?(f[2])
    scalar[unq(f[1])] = f[2]
  end
  return children if scalar.empty?
  all = all_forms(children)
  uses = Hash.new(0)
  atoms_flat(children).each { |a| uses[a] += 1 if a.is_a?(String) && a.start_with?("$\"") }
  modelled = Hash.new(0)
  all.each do |sf|
    next unless (head(sf) == "load" || head(sf) == "store") && sf.length >= 3 && sf[2].is_a?(String) && sf[2].start_with?("$\"")
    n = unq(sf[2])
    modelled["$\"#{n}\""] += 1 if scalar[n] == sf[1]
  end
  eligible = {}
  scalar.each { |n, t| eligible[n] = true if uses["$\"#{n}\""] == modelled["$\"#{n}\""] && uses["$\"#{n}\""] > 0 }
  return children if eligible.empty?

  consts = {}   # value name => the constant form
  # a register that is assigned with set is a variable, not a value: its let is never a constant (decided before the walk, so
  # no value is folded from it)
  setted = {}
  all.each { |sf| setted[sf[1]] = true if head(sf) == "set" && sf.length == 3 }
  set_const = lambda { |name, val| consts[name] = val unless setted[name] }
  # the slots a statement may store (anywhere inside it)
  # Memoized per form: the walk only replaces the right side of a let (a load by a constant), which holds no store, so a
  # form's stores do not change while the walk runs. Nested containers are then read once, not once per enclosing container.
  stored_memo = {}.compare_by_identity
  stored_in = lambda do |x|
    next [] unless x.is_a?(Array)
    stored_memo[x] ||= begin
      res = []
      res << unq(x[2]) if head(x) == "store" && x.length >= 3 && x[2].is_a?(String) && x[2].start_with?("$\"")
      x.each { |y| res.concat(stored_in.call(y)) if y.is_a?(Array) }
      res.uniq
    end
  end
  resolve = lambda { |x| x.is_a?(String) && consts[x] ? consts[x] : x }
  walk = nil
  walk = lambda do |list, known0|
    known = known0.dup
    list.each do |s|
      next unless s.is_a?(Array)
      h = head(s)
      if h == "store" && s.length == 4 && s[2].is_a?(String) && s[2].start_with?("$\"") && eligible[unq(s[2])]
        v = resolve.call(s[3])
        if const_form?(v)
          known[unq(s[2])] = v
        else
          known.delete(unq(s[2]))
        end
      elsif h == "let" && s.length == 4 && head(s[3]) == "load" && s[3].length == 3 && s[3][2].is_a?(String) && s[3][2].start_with?("$\"") && eligible[unq(s[3][2])] && known[unq(s[3][2])]
        c = known[unq(s[3][2])]
        s[3] = c
        set_const.call(s[1], c)
      elsif h == "let" && s.length == 4 && const_form?(s[3])
        set_const.call(s[1], s[3])
      elsif h == "let" && s.length == 4 && %w[wadd wsub wmul].include?(head(s[3])) && s[3].length == 4 &&
            s[3][1] == "int" && const_form?(resolve.call(s[3][2])) && const_form?(resolve.call(s[3][3])) &&
            int_text?(resolve.call(s[3][2])[2]) && int_text?(resolve.call(s[3][3])[2])
        a = resolve.call(s[3][2])[2].to_i
        b = resolve.call(s[3][3])[2].to_i
        v = head(s[3]) == "wadd" ? a + b : (head(s[3]) == "wsub" ? a - b : a * b)
        set_const.call(s[1], ["const", "int", v.to_s])
      elsif h == "if" || h == "loop" || h == "switch" || h == "block" || SROA_CONTAINERS.include?(h)
        # an if arm or a block runs once from here, so it keeps what is known; a loop or a switch can enter its body from
        # several points (each iteration, each case), so it keeps only what it does not store. What it stores is forgotten after it.
        inner_once = known.dup
        stored_in.call(s).each { |n| known.delete(n) }
        if SROA_CONTAINERS.include?(h)
          walk.call(s.drop(1), inner_once)
        elsif h == "if"
          s.drop(1).each { |c| walk.call(c.drop(1), inner_once) if c.is_a?(Array) && SROA_CONTAINERS.include?(head(c)) }
        else
          s.drop(1).each { |c| walk.call(c.drop(1), known.dup) if c.is_a?(Array) && SROA_CONTAINERS.include?(head(c)) }
        end
      else
        # a statement with a store inside (none here, but keep the knowledge honest)
        stored_in.call(s).each { |n| known.delete(n) }
      end
    end
  end
  # the function's statements form the top list (its header forms are not statements)
  walk.call(children.reject { |f| head(f) == "slot" || head(f) == "params" || head(f) == "ret" }, {})
  return children if consts.empty?
  subst = lambda do |x|
    if x.is_a?(Array)
      if head(x) == "let" && x.length == 4
        ["let", x[1], x[2], subst.call(x[3])]
      else
        x.map { |y| subst.call(y) }
      end
    elsif x.is_a?(String) && consts[x]
      consts[x]
    else
      x
    end
  end
  folded = subst.call(children)
  # an index by a constant is an offset of the base
  fold_index = lambda do |x|
    return x unless x.is_a?(Array)
    if head(x) == "index" && x.length == 4 && const_form?(x[2]) && int_text?(x[2][2])
      ["offset", fold_index.call(x[1]), (x[2][2].to_i * x[3].to_i).to_s]
    else
      x.map { |y| fold_index.call(y) }
    end
  end
  fold_index.call(folded)
end

# ---- counted loops with a small constant trip count (--sroa) ----------------------------------------------------------------
# The front end's `for` loop: (loop (body (let C ...) (if C (then) (else (break))) REST...) (step LOAD ADD STORE)). A loop whose
# condition is `counter < N` (N a constant), whose counter starts at a constant K (the last store before the loop, with no other
# store to it in between) and is stepped by +1, and whose body has no other break or continue, is unrolled: the trip count
# T = N - K copies of the body and step, each with its own names, replace it. The counter's stores keep its value in each copy.
UNROLL_MAX = 4

def stores_slot?(x, name)
  all_forms(x).any? { |sf| head(sf) == "store" && sf.length >= 3 && sf[2].is_a?(String) && sf[2].start_with?("$\"") && unq(sf[2]) == name }
end

def has_jump?(x)
  all_forms(x).any? { |sf| head(sf) == "break" || head(sf) == "continue" }
end

def rename_copy(stmts, counter)
  defined = {}
  all_forms(stmts).each { |sf| defined[sf[1]] = true if head(sf) == "let" && sf[1].is_a?(String) }
  map = {}
  defined.each_key { |n| counter[:n] += 1; map[n] = "%#{counter[:n]}" }
  ren = lambda do |x|
    if x.is_a?(Array)
      x.map { |y| ren.call(y) }
    elsif x.is_a?(String) && map[x]
      map[x]
    else
      x
    end
  end
  ren.call(stmts)
end

def unroll_no(k)
  $stderr.write("unroll: refused at #{k}\n") if $sroa_debug
  nil
end

def try_unroll(list, i, counter)
  loop_s = list[i]
  body = loop_s[1].drop(1)
  step = loop_s[2].drop(1)
  j = body.index { |x| head(x) == "if" && x.length == 4 && x[2] == ["then"] && x[3] == ["else", ["break"]] }
  return unroll_no(1) if j.nil?
  prefix = body[0...j]
  suffix = body[(j + 1)..-1]
  return unroll_no(2) if has_jump?(prefix) || has_jump?(suffix) || has_jump?(step)
  cond = body[j][1]
  cdef = prefix.find { |x| head(x) == "let" && x[1] == cond }
  return unroll_no(3) unless cdef && head(cdef[3]) == "lt.s" && cdef[3].length == 4 && cdef[3][1] == "int" && int_text?(cdef[3][3][2]) && const_form?(cdef[3][3])
  bound = cdef[3][3][2].to_i
  xname = cdef[3][2]
  xdef = prefix.find { |x| head(x) == "let" && x[1] == xname }
  return unroll_no(4) unless xdef && head(xdef[3]) == "load" && xdef[3][2].is_a?(String) && xdef[3][2].start_with?("$\"")
  slot = unq(xdef[3][2])
  return unroll_no(5) unless step.length == 3 && head(step[0]) == "let" && head(step[0][3]) == "load" && unq(step[0][3][2]) == slot &&
                    head(step[1]) == "let" && head(step[1][3]) == "wadd" && step[1][3][3] == ["const", "int", "1"] &&
                    head(step[2]) == "store" && unq(step[2][2]) == slot && step[2][3] == step[1][1]
  return unroll_no(6) if stores_slot?(prefix, slot) || stores_slot?(suffix, slot)
  # the counter's value before the loop: the last store to it, with no other store in between
  k0 = nil
  (i - 1).downto(0) do |p|
    st = list[p]
    if head(st) == "store" && st.length == 4 && st[2].is_a?(String) && st[2].start_with?("$\"") && unq(st[2]) == slot
      return unroll_no(7) unless const_form?(st[3]) && int_text?(st[3][2])
      k0 = st[3][2].to_i
      break
    end
    return unroll_no(8) if stores_slot?(st, slot)
  end
  return unroll_no(9) if k0.nil?
  trip = bound - k0
  return unroll_no(10) if trip < 1 || trip > UNROLL_MAX
  if $unroll_limit && (!$unroll_cap_in || $sroa_fn.include?($unroll_cap_in))
    return unroll_no(11) if $unroll_done >= $unroll_limit
    $unroll_done += 1
  end
  copies = []
  trip.times do
    copies.concat(rename_copy(prefix + suffix + step, counter))
  end
  copies
end

def unroll_list!(list, counter)
  i = 0
  while i < list.length
    s = list[i]
    if head(s) == "loop" && s.length == 3
      rep = try_unroll(list, i, counter)
      if rep
        list[i, 1] = rep
        i += rep.length
        next
      end
    end
    unroll_list!(s, counter) if s.is_a?(Array)
    i += 1
  end
  list
end

def sroa_pass(forms)
  forms.map do |f|
    next f unless head(f) == "function"
    counter = { n: max_id(f) }
    $sroa_fn = unq(f[1])
    children = f.drop(2)
    unroll_list!(children, counter) if $pass_unroll && ($unroll_in.nil? || unq(f[1]).include?($unroll_in))
    children = cprop_function(children) if $pass_cprop
    children = fold_unit_index(children, {}) if $pass_fold_unit
    new_children = sroa_function(children, counter)
    if defined_values_ok?(new_children)
      f.take(2) + new_children
    else
      if $sroa_debug
        dv = {}
        all_forms(new_children).each { |sf| dv[sf[1]] = true if (head(sf) == "let" || head(sf) == "param" || head(sf) == "sret") && sf[1].is_a?(String) }
        miss = atoms_flat(new_children).find { |a| numbered_id?(a) && !dv[a] }
        $stderr.write("pathb-ir-opt: scalar replacement of #{$sroa_fn} refused: #{miss} would lose its definition\n")
      end
      f
    end
  end
end

def main(argv)
  $sroa_debug = false
  $pass_unroll = true
  $pass_cprop = true
  $pass_fold_unit = true
  inline = false
  sroa = false
  max_depth = 4
  report = false
  file = nil
  argv.each do |a|
    if a == "--inline"
      inline = true
    elsif a == "--sroa"
      sroa = true
    elsif a == "--no-unroll"
      $pass_unroll = false
    elsif a.start_with?("--unroll-in=")
      $unroll_in = a[12..-1]
    elsif a.start_with?("--unroll-cap-in=")
      $unroll_cap_in = a[16..-1]
    elsif a.start_with?("--unroll-limit=")
      $unroll_limit = a[15..-1].to_i
      $unroll_done = 0
    elsif a == "--no-cprop"
      $pass_cprop = false
    elsif a == "--no-fold-unit"
      $pass_fold_unit = false
    elsif a.start_with?("--max-depth=")
      max_depth = a[12..-1].to_i
    elsif a == "--report"
      report = true
    elsif a == "-" || !a.start_with?("--")
      file = a
    else
      $stderr.write("usage: pathb-ir-opt.rb [--inline] [--max-depth=N] [--report] [FILE.ir | -] > out.ir\n")
      return 1
    end
  end
  $sroa_debug = report
  unless inline || sroa
    $stderr.write("pathb-ir-opt: no pass selected (--inline, --sroa)\n")
    return 1
  end
  begin
    forms = parse(tokenize(read_text(file)))
    forms = inline_pass(forms, max_depth, report) if inline
    forms = sroa_pass(forms) if sroa
  rescue BadIR => e
    $stderr.write("error: #{e.message}\n")
    return 1
  end
  forms.each { |f| $stdout.write(show(f) + "\n") }
  0
end

unless $pathb_ir_opt_lib
  rc = main(ARGV)
  exit(rc) if rc != 0
end
