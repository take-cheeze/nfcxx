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
#   --sroa       scalar replacement with unrolling and constant propagation (below); --jobs=N shares its functions out among
#                N forked workers (default NFCXX_IR_OPT_JOBS, or the processor count up to 8).
#   --prune-unused   drop the functions and objects that no definition of external linkage reaches (prune_pass, below)
#   --prune-unreachable=SUBSTR   drop the functions and the global or data objects that no function whose name contains SUBSTR
#                reaches, by name (prune_pass). With --inline or --sroa this is the default for a SYCL device module
#                (__nfcxx_sycl_entry_ kernels); --no-prune keeps every function.
#
# Exit status: 0 written; 1 malformed IR (on stderr).

class BadIR < StandardError; end

# A map keyed by object identity (what Hash#compare_by_identity gave): the key is its object_id, and the entry keeps the
# key object, so its id cannot be reused while the map holds it. The pinned mruby has no compare_by_identity.
class IdentityMap
  def initialize
    @h = {}
  end

  def [](k)
    e = @h[k.object_id]
    e && e[1]
  end

  def []=(k, v)
    @h[k.object_id] = [k, v]
    v
  end

  def fetch(k)
    e = @h[k.object_id]
    return e[1] if e
    block_given? ? yield(k) : raise(KeyError, "key not found")
  end
end


HEADER_HEADS = ["ret", "params", "slot", "static", "weak", "constructor", "destructor", "noinline"]

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

# show(x) appended to buf: one buffer for the whole form (show copies each nested form's text into every enclosing level).
def show_to(buf, x)
  if x.is_a?(Array)
    buf << "("
    first = true
    x.each do |y|
      buf << " " unless first
      first = false
      show_to(buf, y)
    end
    buf << ")"
  else
    buf << x.to_s
  end
  buf
end

# show(a) == show(b) without building the texts (the atoms are compared as text: a size may be an Integer or its digits).
def same_text?(a, b)
  if a.is_a?(Array)
    return false unless b.is_a?(Array) && a.length == b.length
    i = 0
    while i < a.length
      return false unless same_text?(a[i], b[i])
      i += 1
    end
    true
  else
    !b.is_a?(Array) && (a.equal?(b) || a.to_s == b.to_s)
  end
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

def max_id(x, m = 0)
  x.each do |y|
    if y.is_a?(Array)
      m = max_id(y, m)
    elsif y.is_a?(String) && y.getbyte(0) == 37 && y.length > 1   # %N: the digits read in place (id_number)
      k = 0
      j = 1
      n = y.length
      while j < n
        d = y.getbyte(j)
        break if d < 48 || d > 57
        k = k * 10 + d - 48
        j += 1
      end
      m = k if j == n && k > m
    end
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
# Caps on inlining (docs/notes/pathb-ir-passes.md). A callee of more than $inline_max_callee nodes is not inlined, and the
# module is not inlined past $inline_max_growth times its size on entry (each inlined copy is a full copy of the callee, and
# the callees grow with each round). 0 turns a cap off.
$inline_max_callee = 400
$inline_max_growth = 2.0

def node_count(x)
  return 0 unless x.is_a?(Array)
  n = 1
  x.each { |y| n += node_count(y) }
  n
end

def refusal(fn, name)
  return "callee over --max-callee" if $inline_max_callee > 0 && node_count(fn) > $inline_max_callee
  return "ctor/dtor" if fn.any? { |f| head(f) == "constructor" || head(f) == "destructor" }
  return "noinline" if fn.any? { |f| head(f) == "noinline" }
  params = fn.find { |f| head(f) == "params" }
  if params
    params.drop(1).each do |p|
      return "ellipsis" if head(p) == "ellipsis"
      return "struct/bool parameter" if head(p) == "param" && (head(p[3]) == "struct" || p[3] == "bool")
    end
  end
  ret = fn.find { |f| head(f) == "ret" }
  return "struct/array result" if ret && (head(ret[1]) == "struct" || head(ret[1]) == "array")
  body = fn.drop(2)
  # one walk for the atoms and heads that the checks below read
  self_ref = "&\"#{name}\""
  facts = { printf: false, self: false, jumps: 0, rets: 0 }
  scan = lambda do |x|
    h = x[0]
    if h.is_a?(String)
      facts[:frame] = true if h == "retaddr" || h == "frameaddr"   # the caller's frame is read: the body must stay in its own
      facts[:jumps] += 1 if h == "goto" || h == "label"
      facts[:rets] += 1 if h == "return"
    end
    x.each do |y|
      if y.is_a?(Array)
        scan.call(y)
      elsif y == "&\"printf\""
        facts[:printf] = true
      elsif y == self_ref
        facts[:self] = true
      end
    end
  end
  scan.call(body)
  return "frame address" if facts[:frame]
  return "printf" if facts[:printf]
  return "recursion" if facts[:self]
  return "goto/label" if facts[:jumps] > 0
  return "work-group static" if fn.any? { |f| head(f) == "slot" && contains_wgs?(f) }
  rets = facts[:rets]
  return nil if rets == 0 || (rets == 1 && head(splice_tail_blocks(body).last) == "return")
  # Early returns: the inlined body is a loop that runs once, and each return breaks out of it (expand_call). A return inside
  # a loop or switch of the callee also sets a done flag, and a test of the flag after each enclosing loop or switch breaks on
  # outwards (early_returns).
  return "early return of a non-scalar" unless ret.nil? || ret[1] == "void" || scalar_size_of(ret[1])
  nil
end

def return_in_loop?(x, inside)
  return false unless x.is_a?(Array)
  return inside if head(x) == "return"
  inside ||= head(x) == "loop" || head(x) == "switch"
  x.any? { |y| return_in_loop?(y, inside) }
end

# The statements with each return replaced by a store of its operand to the result slot (when the call has a destination)
# and a break out of the loop that expand_call puts around an early-returning callee. A return inside a loop or switch of
# the callee (inside) also stores true to the done slot dslot; its break leaves only the innermost loop or switch, so after
# each loop or switch that holds such a return comes (let %T bool (load bool DONE)) (if %T (then (break))), which leaves
# the next one out, up to the one-trip loop. A break or continue of the callee keeps its meaning: the tests are placed after
# the loop or switch, in the statement list that holds it. Returns [form, whether it holds a return inside a loop or switch].
def early_returns(x, rtype, rslot, dslot = nil, st = nil, inside = false)
  return [x, false] unless x.is_a?(Array)
  if head(x) == "return"
    stmts = []
    stmts << ["store", rtype, rslot, x[1]] unless rslot.nil? || x.length < 2
    stmts << ["store", "bool", dslot, ["const", "bool", "1"]] if inside
    stmts << ["break"]
    return [stmts.length == 1 ? stmts[0] : ["block"] + stmts, inside]
  end
  deep = false
  out = []
  x.each do |y|
    nested = head(y) == "loop" || head(y) == "switch"
    y2, d = early_returns(y, rtype, rslot, dslot, st, inside || nested)
    out << y2
    next unless d
    deep = true
    next unless nested
    t = "%#{st[:next]}"
    st[:next] += 1
    out << ["let", t, "bool", ["load", "bool", dslot]]
    out << ["if", t, ["then", ["break"]]]
  end
  [out, deep]
end

def unqualified(t)
  t = t[1] while head(t) == "const" && t.length == 2
  t
end

# The statements with a trailing (block ...) replaced by its statements, repeatedly: a block only groups statements (the ids
# are the function's), so a return at the end of the last block is in tail position.
def splice_tail_blocks(stmts)
  while stmts.length > 0 && head(stmts.last) == "block"
    stmts = stmts[0...-1] + stmts.last.drop(1)
  end
  stmts
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
  stmts = splice_tail_blocks(body.reject { |f| HEADER_HEADS.include?(head(f)) })
  ret_op = nil
  early = count_heads(stmts, "return") > (stmts.length > 0 && head(stmts.last) == "return" ? 1 : 0)
  if !early && stmts.length > 0 && head(stmts.last) == "return"
    ret_op = stmts.last[1]
    stmts = stmts[0...-1]
  end
  { ret: ret, rtext: show(ret[1]), params: params, slots: slots, stmts: stmts, ret_op: ret_op, early: early,
    deep: early && return_in_loop?(stmts, false) }
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
    if head(p) == "sret"
      # the result object of a struct-returning callee: the call passes (sret TYPE ADDR), and the callee's stores go to ADDR
      # (the caller copies the result from there after the call, as before the inline)
      return nil unless head(args[i]) == "sret"
      map[p[1]] = args[i][2]
    elsif head(p[3]) == "byval"
      bt = p[3][1]
      bsize = p[3][2]
      balign = p[3][3]
      # the parameter's position makes the name unique: parameters are named by the front end and two of them can share a name
      # (unnamed temporaries are "tmp"), and two slots of one name would share their storage
      name = "\"#{unq(p[2])}.byval#{i}.i#{k}\""
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
  if info[:early]
    # (loop (body STMTS... (break)) (step)): each return stores its operand to the result slot and breaks (early_returns)
    rslot = nil
    if dest
      rt = unqualified(rtype)
      size = scalar_size_of(rt).to_s
      rslot = "$\"ret.i#{k}\""
      hoisted_ret = [["slot", "\"ret.i#{k}\"", rt, size, size]]
    end
    pre = byval_pre
    dslot = nil
    if info[:deep]
      # the done flag of the returns inside loops or switches (early_returns); false on each entry
      dslot = "$\"done.i#{k}\""
      hoisted += [["slot", "\"done.i#{k}\"", "bool", "1", "1"]]
      pre += [["store", "bool", dslot, ["const", "bool", "0"]]]
    end
    body = early_returns(stmts.map { |x| subst(x, map, st) }, rt, rslot, dslot, st)[0]
    out = pre + [["loop", ["body"] + body + [["break"]], ["step"]]]
    out << ["let", dest, dtype, ["load", rt, rslot]] if dest
    hoisted += hoisted_ret if dest
    st[:inlined] += 1
    st[:attr_from] << cname if st[:attrs].key?(cname)
    return [hoisted, out]
  end
  return nil if dest && ret_op.nil?
  out = byval_pre + stmts.map { |x| subst(x, map, st) }
  out << ["let", dest, dtype, subst(ret_op, map, st)] if dest
  st[:inlined] += 1
  st[:attr_from] << cname if st[:attrs].key?(cname)
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

# Whether x holds a call statement (call_statement) whose callee is a function of the module: the statements rewrite may expand.
def calls_module_function?(x, fns)
  return false unless x.is_a?(Array)
  parts = call_statement(x)
  if parts
    c = parts[2]
    return true if c.length >= 3 && c[2].is_a?(String) && c[2][0, 2] == "&\"" && fns.key?(unq(c[2]))
  end
  x.any? { |y| calls_module_function?(y, fns) }
end

def inline_pass(forms, max_depth, report)
  fns = {}
  forms.each { |f| fns[unq(f[1])] = f if head(f) == "function" }
  refused = {}
  inlined = 0
  counter = { k: 0 }
  reasons = {}   # callee name -> refusal reason (nil: inlinable); see expand_call
  infos = {}     # callee name -> callee_info; dropped with the reason when the callee changes
  # A function's [[sycl::reqd_sub_group_size(N)]] is a top-level sycl-kernel-attr form that the emitter reads for the functions a
  # kernel reaches. A callee that carries one is inlined into its caller, so the caller gets the same attr (else the kernel
  # that reaches the caller alone takes the default sub-group size).
  attrs = {}     # function name -> its sycl-kernel-attr form (with a reqd-sub-group-size)
  forms.each { |f| attrs[unq(f[1])] = f if head(f) == "sycl-kernel-attr" && f.drop(2).any? { |a| head(a) == "reqd-sub-group-size" } }
  extra = []     # attr forms for callers, appended after the functions
  # Per function form (by identity, so a rewritten function starts afresh): its largest id, and whether it has a call statement
  # of a function of the module at all (a function without one is never changed and counts no refusal, so its walk is skipped).
  ids = IdentityMap.new
  calls = IdentityMap.new
  total = node_count(forms)
  budget = $inline_max_growth > 0 ? total * $inline_max_growth : nil
  max_depth.times do
    round = 0
    forms.each_with_index do |f, i|
      next unless head(f) == "function"
      next unless calls.fetch(f) { calls[f] = calls_module_function?(f, fns) }
      if budget && total > budget
        refused["module over --max-growth"] = (refused["module over --max-growth"] || 0) + 1
        next
      end
      name = unq(f[1])
      st = { next: ids.fetch(f) { ids[f] = max_id(f) } + 1, k: counter[:k], hoist: [], inlined: 0, refused: refused, rc: reasons,
             ic: infos, attrs: attrs, attr_from: [] }
      children = rewrite(f.drop(2), fns, st)
      counter[:k] = st[:k]
      next if st[:inlined] == 0
      round += st[:inlined]
      before = node_count(f)
      forms[i] = ["function", f[1]] + insert_slots(children, st[:hoist])
      total += node_count(forms[i]) - before
      fns[name] = forms[i]
      reasons.delete(name)
      infos.delete(name)
      unless st[:attr_from].empty? || attrs.key?(name)
        src = attrs[st[:attr_from].first]
        attrs[name] = ["sycl-kernel-attr", f[1]] + src.drop(2)
        extra << attrs[name]
      end
    end
    inlined += round
    break if round == 0
  end
  forms.concat(extra)
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
    struct_slots[unq(f[1])] = true if %w[struct array].include?(head(unqualified(f[2])))
  end
  return children if ptr_slots.empty?
  counts = Hash.new(0)
  slot_atom_counts(children, counts)
  promoted_count = [0]
  ptr_atom = {}
  ptr_slots.each_key { |n| ptr_atom["$\"#{n}\""] = true }
  has_store = IdentityMap.new   # filled below, before the walk
  promote_in_list = lambda do |list|
    i = 0
    orig = 0    # i in the list as it was when idx was built (each promotion deletes the statement at i)
    idx = nil   # built on the first store to a pointer slot (suffix_index)
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
        if target
          # the uses of the slot's atom in the statements after the store, from one index of the list (the walk of the
          # statements after each store made the pass quadratic in a long list). The index stays exact: a promotion changes
          # only the uses of its own slot, which has no store left in the list after it.
          idx ||= suffix_index(list, i, ptr_atom)
          atom = "$\"#{n}\""
          rest_count = 0
          (idx[:count][atom] || []).each { |j, c| rest_count += c if j > orig }
        end
        if target && counts[atom] == 1 + rest_count
          later = lambda { |key| (idx[key][atom] || []).select { |j, _| j > orig }.map { |_, sf| sf } }
          loads = later.call(:load).select { |sf| head(sf) == "load" && sf.length == 3 && sf[2] == atom }
          lets = later.call(:let).select { |sf| head(sf) == "let" && sf.length == 4 && head(sf[3]) == "load" && sf[3][2] == atom }
          # another store to the slot after this one: a load after it may read another address (promote_same_address_slots)
          restores = later.call(:store).count { |sf| head(sf) == "store" && sf[2] == atom }
          if lets.length == loads.length && lets.length > 0 && restores == 0
            lets.each { |sf| sf[3] = ["offset", "$\"#{target[0]}\"", target[1].to_s] }
            list.delete_at(i)
            orig += 1
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
      orig += 1
    end
    list.each { |x| promote_in_list.call(x) if x.is_a?(Array) && has_store[x] }
  end
  # the forms with a store to a pointer slot inside: the walk skips the others, where it finds nothing to do (a form keeps its
  # entry when its store goes, which only costs the walk)
  mark = lambda do |x|
    found = head(x) == "store" && x.length == 4 && x[2].is_a?(String) && ptr_atom[x[2]]
    x.each { |y| found = true if y.is_a?(Array) && mark.call(y) }
    has_store[x] = true if found
    found
  end
  mark.call(children)
  # a store of a value that is itself a promoted load becomes visible to the next round
  4.times do
    before = promoted_count[0]
    promote_in_list.call(children)
    break if promoted_count[0] == before
  end
  children
end

# counts[a] += 1 for each slot atom $"..." in x (atoms_flat without the array).
def slot_atom_counts(x, counts)
  x.each do |y|
    if y.is_a?(Array)
      slot_atom_counts(y, counts)
    elsif y.is_a?(String) && y.start_with?("$\"")
      counts[y] += 1
    end
  end
  counts
end

# The same for a pointer slot with several stores (an unrolled loop that calls a member function stores `this` in each
# iteration): when every store writes one address (the same struct slot and byte offset) and every other use is a let of a
# load, each load is that address and the stores go. A load before every store reads an uninitialized pointer, so it may be
# given the address too.
def promote_same_address_slots(children)
  ptr_slots = {}
  struct_slots = {}
  children.each do |f|
    next unless head(f) == "slot"
    t = f[2]
    t = t[1] while head(t) == "const"
    ptr_slots[unq(f[1])] = true if head(t) == "ptr"
    struct_slots[unq(f[1])] = true if %w[struct array].include?(head(unqualified(f[2])))
  end
  return children if ptr_slots.empty?
  counts = Hash.new(0)
  slot_atom_counts(children, counts)
  targets = {}   # pointer slot => [target, ...] (nil for a store it cannot resolve)
  lets = Hash.new { |h, k| h[k] = [] }
  walk = lambda do |list, outer|
    addr = outer.dup   # value name => [struct slot name, byte offset]; the registers of enclosing lists are visible
    list.each do |f|
      next unless f.is_a?(Array)
      if head(f) == "store" && f.length == 4 && f[2].is_a?(String) && f[2].start_with?("$\"") && ptr_slots[unq(f[2])]
        v = f[3]
        t = if v.is_a?(String) && v.start_with?("$\"") && struct_slots[unq(v)] then [unq(v), 0]
            elsif v.is_a?(String) then addr[v]
            end
        (targets[unq(f[2])] ||= []) << t
      elsif head(f) == "let" && f.length == 4
        rv = f[3]
        if head(rv) == "load" && rv.length == 3 && rv[2].is_a?(String) && rv[2].start_with?("$\"") && ptr_slots[unq(rv[2])]
          lets[unq(rv[2])] << f
        elsif head(rv) == "offset" && rv.length == 3 && rv[1].is_a?(String) && rv[1].start_with?("$\"") && struct_slots[unq(rv[1])]
          addr[f[1]] = [unq(rv[1]), rv[2].to_i]
        elsif head(rv) == "bitcast" && rv.length == 3 && rv[2].is_a?(String) && rv[2].start_with?("$\"") && struct_slots[unq(rv[2])]
          addr[f[1]] = [unq(rv[2]), 0]
        elsif head(rv) == "offset" && rv.length == 3 && addr[rv[1]]
          addr[f[1]] = [addr[rv[1]][0], addr[rv[1]][1] + rv[2].to_i]
        elsif head(rv) == "bitcast" && rv.length == 3 && addr[rv[2]]
          addr[f[1]] = addr[rv[2]].dup
        end
      elsif head(f) == "set" && f[1].is_a?(String)
        addr.delete(f[1])
      end
      walk.call(f, addr) unless head(f) == "let" || head(f) == "store"
    end
  end
  walk.call(children, {})
  done = {}
  targets.each do |n, ts|
    next if ts.include?(nil) || ts.uniq.length != 1 || lets[n].empty?
    next unless counts["$\"#{n}\""] == ts.length + lets[n].length
    t = ts[0]
    lets[n].each { |f| f[3] = ["offset", "$\"#{t[0]}\"", t[1].to_s] }
    done["$\"#{n}\""] = true
  end
  return children if done.empty?
  drop = lambda do |list|
    list.reject { |f| head(f) == "store" && f.length == 4 && done[f[2]] }.map { |f| f.is_a?(Array) ? drop.call(f) : f }
  end
  drop.call(children)
end

# A call of memcpy with a constant size is a copy of that many bytes (alignment 1), which the scalar replacement models (the
# call would make both objects escape); its result is the destination.
def memcpy_to_copy(list)
  out = []
  list.each do |s|
    call = head(s) == "let" ? s[3] : (head(s) == "eval" ? s[1] : nil)
    if head(call) == "call" && call[2] == "&\"memcpy\"" && call.length == 6 && head(call[5]) == "const" && int_text?(call[5][2]) &&
       call[3].is_a?(String) && call[4].is_a?(String)
      out << ["copy", call[5][2], call[3], call[4], "1"]
      out << ["let", s[1], s[2], call[3]] if head(s) == "let"
      next
    end
    out << (s.is_a?(Array) ? memcpy_to_copy(s) : s)
  end
  out
end

def count_in_forms(list, atom)
  atoms_flat(list).count { |a| a == atom }
end

# The uses of the pointer slots' atoms in the statements list[from..], keyed by the statement's position: :count (atom =>
# [[position, count]]), and the forms that may be a load, a let of a load, or a store of each atom (:load, :let, :store =>
# atom => [[position, form]]), in the order of a walk of the statements (all_forms).
def suffix_index(list, from, ptr_atom)
  idx = { count: {}, load: {}, let: {}, store: {} }
  j = from
  walk = lambda do |x, cnt|
    if x.is_a?(Array)
      h = x[0]
      if h == "load" && x.length == 3 && ptr_atom[x[2]]
        (idx[:load][x[2]] ||= []) << [j, x]
      elsif h == "let" && x.length == 4 && head(x[3]) == "load" && ptr_atom[x[3][2]]
        (idx[:let][x[3][2]] ||= []) << [j, x]
      elsif h == "store" && x.length >= 3 && ptr_atom[x[2]]
        (idx[:store][x[2]] ||= []) << [j, x]
      end
      x.each { |y| walk.call(y, cnt) }
    elsif ptr_atom[x]
      cnt[x] += 1
    end
  end
  while j < list.length
    cnt = Hash.new(0)
    walk.call(list[j], cnt)
    cnt.each { |a, c| (idx[:count][a] ||= []) << [j, c] }
    j += 1
  end
  idx
end

# [all_forms(list[from..]), count_in_forms(list[from..], atom)] in one walk (the same forms, in the same order).
def suffix_forms_and_count(list, from, atom)
  forms = []
  count = 0
  walk = lambda do |x|
    if x.is_a?(Array)
      forms << x
      x.each { |y| walk.call(y) }
    elsif x == atom
      count += 1
    end
  end
  rest = list[from..]
  forms << rest   # all_forms of the array includes the array itself
  rest.each { |y| walk.call(y) }
  [forms, count]
end

def sroa_function(children, counter)
  children = memcpy_to_copy(children)
  children = promote_address_slots(children)
  children = promote_same_address_slots(children)
  slots = {}   # name => [type, size, align]
  children.each do |f|
    # an array or a const struct too: the fields are the offsets and types the object is accessed at
    next unless head(f) == "slot" && %w[struct array].include?(head(unqualified(f[2]))) && !contains_wgs?(f[2])
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
  used = []
  walk = lambda do |x|
    if x.is_a?(Array)
      h = x[0]
      defined[x[1]] = true if (h == "let" || h == "phi" || h == "param" || h == "sret") && x[1].is_a?(String)
      x.each { |y| walk.call(y) }
    elsif numbered_id?(x)
      used << x
    end
  end
  walk.call(children)
  used.all? { |a| defined[a] }
end

# An index that a bounds check has proved to be 0 (`(bounds I 1)` traps unless 0 <= I < 1): (index B I S) is the address B. The
# check dominates the index in its statement list, or an enclosing one.
def fold_unit_index(list, unit, sets = IdentityMap.new)
  unit = unit.dup
  list.each_with_index do |s, i|
    next unless s.is_a?(Array)
    if head(s) == "bounds" && s.length == 3 && s[1].is_a?(String) && (s[2] == "1" || s[2] == "0x1")
      unit[s[1]] = true
    elsif head(s) == "let" && s.length == 4 && head(s[3]) == "index" && s[3].length == 4 && unit[s[3][2]]
      list[i] = ["let", s[1], s[2], ["offset", s[3][1], "0"]]
      next
    end
    # set is a store to a variable, not a new value: a register that s sets no longer holds the checked 0 after s, and inside s
    # the fact is dropped too, since a loop in s runs its body again with the set value
    set_registers(s, sets).each { |r| unit.delete(r) }
    s.each { |x| fold_unit_index(x, unit, sets) if x.is_a?(Array) }
  end
  list
end

# The registers that the sets in x (x itself included) assign, memoized per form in memo: the fold only replaces lets of an
# index, which hold no set, so a form's sets stay the same while it runs.
NO_SETS = [].freeze

def set_registers(x, memo)
  memo[x] ||= begin
    res = []
    res << x[1] if head(x) == "set" && x.length == 3 && x[1].is_a?(String)
    x.each { |y| res.concat(set_registers(y, memo)) if y.is_a?(Array) }
    res.empty? ? NO_SETS : res.uniq
  end
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
  # one walk: the uses of each slot atom, its plain loads and stores of the slot's type, and the registers assigned with set
  uses = Hash.new(0)
  modelled = Hash.new(0)
  setted = {}
  scan = lambda do |x|
    h = x[0]
    if (h == "load" || h == "store") && x.length >= 3 && x[2].is_a?(String) && x[2].start_with?("$\"")
      modelled[x[2]] += 1 if scalar[unq(x[2])] == x[1]
    elsif h == "set" && x.length == 3
      # a register that is assigned with set is a variable, not a value: its let is never a constant (decided before the
      # walk, so no value is folded from it)
      setted[x[1]] = true
    end
    x.each do |y|
      if y.is_a?(Array)
        scan.call(y)
      elsif y.is_a?(String) && y.start_with?("$\"")
        uses[y] += 1
      end
    end
  end
  scan.call(children)
  eligible = {}
  scalar.each { |n, t| eligible[n] = true if uses["$\"#{n}\""] == modelled["$\"#{n}\""] && uses["$\"#{n}\""] > 0 }
  return children if eligible.empty?

  consts = {}   # value name => the constant form
  set_const = lambda { |name, val| consts[name] = val unless setted[name] }
  # the slots a statement may store (anywhere inside it)
  # Memoized per form: the walk only replaces the right side of a let (a load by a constant), which holds no store, so a
  # form's stores do not change while the walk runs. Nested containers are then read once, not once per enclosing container.
  stored_memo = IdentityMap.new
  stored_in = lambda do |x|
    next [] unless x.is_a?(Array)
    stored_memo[x] ||= begin
      res = []
      res << unq(x[2]) if head(x) == "store" && x.length >= 3 && x[2].is_a?(String) && x[2].start_with?("$\"")
      x.each { |y| res.concat(stored_in.call(y)) if y.is_a?(Array) }
      res.empty? ? NO_SETS : res.uniq
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
        # wadd/wsub/wmul wrap in the type's width (int is 32 bits, two's complement)
        v = ((v + 0x80000000) & 0xFFFFFFFF) - 0x80000000
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
# The front end's `for` loop: (loop (body PREFIX... (if C (then) (else (break))) REST...) (step LOAD OP STORE)). A loop whose
# condition C compares the counter (a load of a scalar slot in PREFIX) with a constant (lt, le, gt, ge, signed or unsigned, ne,
# eq, the counter on either side), whose counter starts at a constant K (the last store before the loop, with no other store to
# it in between), is stepped by a constant (wadd, wsub, wmul, cshl, cshr), is not stored anywhere else in the loop and has its
# address used only by loads and stores, and whose body has no other break or continue, is unrolled: the counter's values are
# computed from K until C is false, and one copy of PREFIX, REST and the step per value, each with its own names, replaces the
# loop (at most UNROLL_MAX copies). The counter's stores keep its value in each copy. A loop that runs no trip is PREFIX alone
# (the test runs once), and so is the last test after the trips (dropped when PREFIX is only lets without a call).
UNROLL_MAX = 4
UNROLL_CMP = { "lt.s" => :<, "lt.u" => :<, "le.s" => :<=, "le.u" => :<=, "gt.s" => :>, "gt.u" => :>, "ge.s" => :>=,
               "ge.u" => :>=, "eq" => :==, "ne" => :!= }.freeze
UNROLL_SWAP = { :< => :>, :<= => :>=, :> => :<, :>= => :<=, :== => :==, :!= => :!= }.freeze
UNROLL_INT = { "int" => [32, true], "unsigned_int" => [32, false], "long" => [64, true], "unsigned_long" => [64, false],
               "long_long" => [64, true], "unsigned_long_long" => [64, false] }.freeze

def stores_slot?(x, name)
  all_forms(x).any? { |sf| head(sf) == "store" && sf.length >= 3 && sf[2].is_a?(String) && sf[2].start_with?("$\"") && unq(sf[2]) == name }
end

# A break or continue that leaves the loop around x: one inside a nested loop belongs to that loop, and a break inside a
# switch leaves the switch (an inlined early-returning callee is a nested loop, expand_call).
def has_jump?(x, in_switch = false)
  return false unless x.is_a?(Array)
  return true if head(x) == "continue" || (head(x) == "break" && !in_switch)
  return false if head(x) == "loop"
  in_switch ||= head(x) == "switch"
  x.any? { |y| has_jump?(y, in_switch) }
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

# The slots whose address is used other than as the address of a load or store (a call argument, an offset, a stored value):
# a store through that use may change a loop counter, so such a slot is never one.
def unroll_escaped_slots(children)
  total = Hash.new(0)
  direct = Hash.new(0)
  walk = lambda do |x|
    if x.is_a?(Array)
      h = x[0]
      if (h == "load" || h == "store") && x.length >= 3 && x[2].is_a?(String) && x[2].start_with?("$\"")
        direct[x[2]] += 1
      end
      x.each { |y| walk.call(y) }
    elsif x.is_a?(String) && x.start_with?("$\"")
      total[x] += 1
    end
  end
  walk.call(children)
  esc = {}
  total.each { |a, n| esc[unq(a)] = true if n != direct[a] }
  esc
end

# The integer constant of (const T N) with T the counter's type, or nil.
def unroll_const(x, t)
  const_form?(x) && x[1] == t && int_text?(x[2]) ? x[2].to_i : nil
end

# v in the range of the counter type, or nil.
def unroll_fit(v, t)
  bits, signed = UNROLL_INT[t]
  lo = signed ? -(1 << (bits - 1)) : 0
  hi = signed ? (1 << (bits - 1)) - 1 : (1 << bits) - 1
  v >= lo && v <= hi ? v : nil
end

# The counter's next value: OP of the step on v and the constant c, nil when it leaves the type's range or a shift count is not
# in [0, width) (a wrap or a trap is left to the loop).
def unroll_step(op, v, c, t)
  bits = UNROLL_INT[t][0]
  r = case op
      when "wadd" then v + c
      when "wsub" then v - c
      when "wmul" then v * c
      when "cshl" then c >= 0 && c < bits ? v << c : nil
      when "cshr" then c >= 0 && c < bits ? v >> c : nil
      end
  r && unroll_fit(r, t)
end

def try_unroll(list, i, counter, escaped = {})
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
  return unroll_no(3) unless cdef && cdef.length == 4 && UNROLL_CMP.key?(head(cdef[3])) && cdef[3].length == 4 &&
                             UNROLL_INT.key?(cdef[3][1])
  ty = cdef[3][1]
  cmp = UNROLL_CMP[head(cdef[3])]
  if (bound = unroll_const(cdef[3][3], ty)) && cdef[3][2].is_a?(String)
    xname = cdef[3][2]
  elsif (bound = unroll_const(cdef[3][2], ty)) && cdef[3][3].is_a?(String)
    xname = cdef[3][3]
    cmp = UNROLL_SWAP[cmp]   # K OP x is x OP' K
  else
    return unroll_no(3)
  end
  xdef = prefix.find { |x| head(x) == "let" && x[1] == xname }
  return unroll_no(4) unless xdef && xdef.length == 4 && xdef[2] == ty && head(xdef[3]) == "load" && xdef[3].length == 3 &&
                             xdef[3][1] == ty && xdef[3][2].is_a?(String) && xdef[3][2].start_with?("$\"")
  slot = unq(xdef[3][2])
  # the step: (let V T (load T SLOT)) (let W T (OP T V (const T C))) (store T SLOT W), or (store T SLOT (OP T V (const T C)))
  sop = nil
  if step.length == 3 && head(step[0]) == "let" && step[0].length == 4 && head(step[0][3]) == "load" && step[0][3][2] == xdef[3][2] &&
     head(step[1]) == "let" && step[1].length == 4 && head(step[2]) == "store" && step[2].length == 4 && step[2][2] == xdef[3][2] &&
     step[2][3] == step[1][1]
    sop = step[1][3]
  elsif step.length == 2 && head(step[0]) == "let" && step[0].length == 4 && head(step[0][3]) == "load" && step[0][3][2] == xdef[3][2] &&
        head(step[1]) == "store" && step[1].length == 4 && step[1][2] == xdef[3][2]
    sop = step[1][3]
  end
  return unroll_no(5) unless sop && %w[wadd wsub wmul cshl cshr].include?(head(sop)) && sop.length == 4 && sop[1] == ty &&
                             sop[2] == step[0][1] && (sc = unroll_const(sop[3], ty)) && step[0][2] == ty && step[0][3][1] == ty &&
                             (step.length == 2 || step[2][1] == ty) && (step.length == 3 || step[1][1] == ty)
  return unroll_no(6) if stores_slot?(prefix, slot) || stores_slot?(suffix, slot) || escaped[slot]
  # the counter's value before the loop: the last store to it, with no other store in between
  k0 = nil
  (i - 1).downto(0) do |p|
    st = list[p]
    if head(st) == "store" && st.length == 4 && st[2].is_a?(String) && st[2].start_with?("$\"") && unq(st[2]) == slot
      return unroll_no(7) unless st[1] == ty && (k0 = unroll_const(st[3], ty)) && unroll_fit(k0, ty)
      break
    end
    return unroll_no(8) if stores_slot?(st, slot)
  end
  return unroll_no(9) if k0.nil?
  # the trips: the counter's values while the test holds
  trip = 0
  v = k0
  while v.send(cmp, bound)
    trip += 1
    return unroll_no(10) if trip > UNROLL_MAX
    v = unroll_step(head(sop), v, sc, ty)
    return unroll_no(12) if v.nil?
  end
  if $unroll_limit && (!$unroll_cap_in || $sroa_fn.include?($unroll_cap_in))
    return unroll_no(11) if $unroll_done >= $unroll_limit
    $unroll_done += 1
  end
  copies = []
  trip.times do
    copies.concat(rename_copy(prefix + suffix + step, counter))
  end
  # the last test: its statements run once more (only lets of values, without a call, can go)
  pure = prefix.all? { |x| head(x) == "let" && x.length == 4 && count_heads(x[3], "call") == 0 }
  copies.concat(rename_copy(prefix, counter)) unless pure
  copies
end

def unroll_list!(list, counter, escaped = {})
  i = 0
  while i < list.length
    s = list[i]
    if head(s) == "loop" && s.length == 3
      rep = try_unroll(list, i, counter, escaped)
      if rep
        list[i, 1] = rep
        i += rep.length
        next
      end
    end
    unroll_list!(s, counter, escaped) if s.is_a?(Array)
    i += 1
  end
  list
end

# 8: an unrolled loop's copies are walked in the next round, so a nest of loops unrolls one level per round (with 4 rounds the
# deep nests of the mmvq kernels stopped half unrolled); the rounds end as soon as one changes nothing
SROA_ROUNDS = 8

def sroa_function_form(f)
  begin
    counter = { n: max_id(f) }
    $sroa_fn = unq(f[1])
    children = f.drop(2)
    # Rounds until nothing changes (at most SROA_ROUNDS): a promoted pointer slot or a replaced aggregate makes loop counters
    # and stored addresses constant, which the next round's unrolling and promotion use.
    new_children = nil
    cand = nil
    SROA_ROUNDS.times do
      # the round's input (the passes below change the lists in place). A round whose result is its input ends the rounds, the
      # first one too: the next round would read the same text and give it again.
      before = copy_form(new_children || children)
      children = new_children if new_children
      unroll_list!(children, counter, unroll_escaped_slots(children)) if $pass_unroll && ($unroll_in.nil? || unq(f[1]).include?($unroll_in))
      children = cprop_function(children) if $pass_cprop
      children = fold_unit_index(children, {}) if $pass_fold_unit
      cand = sroa_function(children, counter)
      break unless defined_values_ok?(cand)
      new_children = cand
      break if same_text?(cand, before)
    end
    if new_children
      f.take(2) + new_children
    else
      if $sroa_debug
        dv = {}
        all_forms(cand).each { |sf| dv[sf[1]] = true if (head(sf) == "let" || head(sf) == "param" || head(sf) == "sret") && sf[1].is_a?(String) }
        miss = atoms_flat(cand).find { |a| numbered_id?(a) && !dv[a] }
        $stderr.write("pathb-ir-opt: scalar replacement of #{$sroa_fn} refused: #{miss} would lose its definition\n")
      end
      f
    end
  end
end

# The functions are independent, and the serial pass gives the reference texts. The forked workers this pass used to run
# (--jobs=N) need Process, which the closed (script-world) build does not have, so the pass is serial; --jobs=N is still
# accepted and changes nothing.
def sroa_pass(forms, _jobs = 1)
  forms.map { |f| head(f) == "function" ? sroa_function_form(f) : f }
end

# The number of atoms and forms in x: the size a worker's share is balanced by.
def form_weight(x)
  n = 1
  x.each { |y| n += y.is_a?(Array) ? form_weight(y) : 1 }
  n
end

# Store-to-load forwarding on the structured IR (the last pass before the emitters): a load of a scalar that the same statement
# list has just stored, or has just loaded, becomes the value itself. A store kills every remembered value (it may write
# through a pointer to any object), and so does anything that is not a plain let, set, store or load: a call, a branch, a
# nested then/else/body/step list (which runs once, or again, from a different state). A set of a register kills the values
# that register holds and the addresses it forms.
FWD_NESTED = %w[then else body step case].freeze

def fwd_scalar?(t)
  (t.is_a?(String) && !%w[struct array union].include?(t)) || head(t) == "ptr"
end

def fwd_value?(v)
  (v.is_a?(String) && v.start_with?("%")) || head(v) == "const"
end

def fwd_kill_reg(tab, r)
  tab.delete_if { |k, e| k == r || e[1] == r }
end

def fwd_list(stmts, tab, st)
  stmts.map { |s| fwd_stmt(s, tab, st) }
end

def fwd_stmt(s, tab, st)
  return s unless s.is_a?(Array) && s[0].is_a?(String)
  h = s[0]
  return s if HEADER_HEADS.include?(h)
  case h
  when "let"
    if s.length == 4 && head(s[3]) == "load" && s[3].length == 3 && fwd_scalar?(s[2]) && show(s[3][1]) == show(s[2])
      key = show(s[3][2])
      e = tab[key]
      fwd_kill_reg(tab, s[1])
      if e && e[0] == show(s[2])
        st[:fwd] += 1
        tab[key] = [e[0], s[1]]
        return ["let", s[1], s[2], e[1]]
      end
      tab[key] = [show(s[2]), s[1]]
      return s
    end
    fwd_kill_reg(tab, s[1])
    s
  when "store"
    tab.clear
    if s.length == 4 && fwd_scalar?(s[1]) && fwd_value?(s[3])
      tab[show(s[2])] = [show(s[1]), s[3]]
    end
    s
  when "set"
    fwd_kill_reg(tab, s[1])
    s
  when "block"
    # a block runs once, in order: the values it sees are the ones before it
    [h, *fwd_list(s.drop(1), tab, st)]
  else
    tab.clear
    s.map { |c| c.is_a?(Array) && FWD_NESTED.include?(head(c)) ? [head(c), *fwd_list(c.drop(1), {}, st)] : (c.is_a?(Array) && head(c) == "block" ? fwd_stmt(c, {}, st) : c) }
  end
end

# The forwarding pass over the functions of a structured module (scripts/pathb-ir-opt.rb --forward).
def forward_pass(forms, report)
  st = { fwd: 0 }
  out = forms.map do |f|
    next f unless head(f) == "function"
    f.take(2) + fwd_list(f.drop(2), {}, st)
  end
  $stderr.write("pathb-ir-opt: forwarded #{st[:fwd]} load(s)\n") if report
  out
end

# ---- exception-handling state (--strip-eh) --------------------------------------------------------------------------------
# The front end keeps the exception-handling state in two globals: the stack of EH entries (__curr_eh_stack_entry, pushed by
# functions with cleanups or a noexcept guard) and the current cleanup region (__eh_curr_region). Only a throw reads them, and
# device code does not throw, so on the device their stores are dropped and their loads are null or 0. The pushed entries
# become slots that are written and never read, which the later passes remove.

EH_GLOBALS = ["@\"__curr_eh_stack_entry\"", "@\"__eh_curr_region\""].freeze

def strip_eh_list(stmts, st)
  out = []
  stmts.each do |s|
    if head(s) == "store" && EH_GLOBALS.include?(s[2])
      st[:n] += 1
      next
    end
    if head(s) == "let" && head(s[3]) == "load" && EH_GLOBALS.include?(s[3][2])
      st[:n] += 1
      out << ["let", s[1], s[2], head(s[2]) == "ptr" ? ["null", s[2]] : ["const", s[2], "0"]]
      next
    end
    out << (s.is_a?(Array) ? strip_eh_list(s, st) : s)
  end
  out
end

def strip_eh_pass(forms, report)
  st = { n: 0 }
  forms = forms.map { |f| head(f) == "function" ? strip_eh_list(f, st) : f }
  $stderr.write("pathb-ir-opt: dropped #{st[:n]} EH state access(es)\n") if report
  forms
end

# ---- EH frames of functions that cannot throw (--strip-leaf-eh) ----------------------------------------------------------
# Only a throw walks the EH stack, so the entry a function pushes (a noexcept guard, kind 6, or a cleanup frame) is never read
# when nothing the function calls can throw. libstdc++'s accessors and shared_ptr members are such functions, and each pushes and
# pops a 240-byte entry on thread-local state (and each body inlined into a caller does the same). The pass drops the entry's
# slot, its initialisation, the push and the pop, and the writes of __eh_curr_region, of every function whose calls all go to
# functions that cannot let an exception out (throwing_functions below). It leaves a function unchanged when anything else
# reads the entry (every register and slot it removes must be gone from what remains). Run before --inline the inliner copies
# the lean callee, and after it the functions whose calls were all inlined lose the frames of the bodies copied into them.

# Which functions can let an exception out (the nothrow analysis of --strip-leaf-eh). A function cannot when it is guarded (a
# noexcept function or a destructor: its entry of kind 6 makes a throw through it terminate) or when every call it makes goes
# to a function that cannot, to an atomic builtin (__atomic_fetch_add_4 ...: a locked instruction or a libatomic call) or to one
# of the few libc routines that never throw. An indirect call, a call of a function the module does not define (operator new,
# __cxa_throw ...) can. Computed as the least set of the functions that can, from those with such a call, through their
# unguarded callers.
NOTHROW_EXTERN = %w[memcpy memmove memset memcmp strlen strcmp _mm_pause].freeze

def guarded_function?(f)
  frame = f.find { |c| head(c) == "slot" && head(c[2]) == "struct" && c[2][1].to_s.start_with?("\"__C") && c[3].to_i >= 200 }
  return false unless frame
  # the entry's kind byte is stored at offset 8: (let %r (ptr unsigned_char) (offset $"frame" 8)) (store unsigned_char %r (const unsigned_char 6))
  regs = {}
  f.each do |c|
    next unless head(c) == "let" && head(c[3]) == "offset" && c[3][1] == "$" + frame[1] && c[3][2].to_s == "8"
    regs[c[1]] = true
  end
  f.any? { |c| head(c) == "store" && regs[c[2]] && head(c[3]) == "const" && c[3][2].to_s == "6" }
end

def direct_callees(x, out, unknown)
  return unless x.is_a?(Array)
  if head(x) == "call"
    callee = x[2]
    if callee.is_a?(String) && callee.start_with?("&\"")
      out << unq(callee)
    else
      unknown[0] = true
    end
  end
  x.each { |y| direct_callees(y, out, unknown) }
end

def throwing_functions(forms)
  defs = {}
  forms.each { |f| defs[unq(f[1])] = f if head(f) == "function" }
  bad = {}
  callers = Hash.new { |h, k| h[k] = [] }
  work = []
  defs.each do |name, f|
    next if guarded_function?(f)
    callees = []
    unknown = [false]
    direct_callees(f, callees, unknown)
    risky = unknown[0]
    callees.uniq.each do |c|
      if defs.key?(c)
        callers[c] << name
      elsif !(c.start_with?("__atomic_") || NOTHROW_EXTERN.include?(c))
        risky = true
      end
    end
    if risky
      bad[name] = true
      work << name
    end
  end
  until work.empty?
    c = work.pop
    callers[c].each do |name|
      next if bad[name]
      bad[name] = true
      work << name
    end
  end
  bad
end

# The calls of x that can throw: those of functions in bad (throwing_functions), and any other not listed as safe.
def throwing_calls(x, bad)
  return 0 unless x.is_a?(Array)
  n = 0
  if head(x) == "call"
    callee = x[2]
    if !(callee.is_a?(String) && callee.start_with?("&\""))
      n = 1
    else
      name = unq(callee)
      safe = name.start_with?("__atomic_") || NOTHROW_EXTERN.include?(name) || ($leaf_defs.key?(name) && !bad.key?(name))
      n = 1 unless safe
    end
  end
  x.each { |y| n += throwing_calls(y, bad) }
  n
end

# Whether e (the value of a let) is computed from the address of one of the frames or from a register already removed: an
# offset, bitcast or index of it, or a load through it.
def derived_of_removed?(e, fnames, removed_regs)
  base = case head(e)
         when "offset", "index" then e[1]
         when "bitcast", "load" then e[2]
         end
  base.is_a?(String) && (fnames.include?(base) || removed_regs.key?(base))
end

def leaf_eh_function(f, bad)
  return [f, 0] if throwing_calls(f, bad) > 0
  frames = f.select { |c| head(c) == "slot" && head(c[2]) == "struct" && c[2][1].to_s.start_with?("\"__C") && c[3].to_i >= 200 }
  return [f, 0] if frames.empty?
  fnames = frames.map { |c| "$" + c[1] }
  removed_regs = {}
  n = 0
  walk = lambda do |list|
    out = []
    list.each do |c|
      unless c.is_a?(Array)
        out << c
        next
      end
      h = head(c)
      drop = false
      if h == "slot" && fnames.include?("$" + c[1].to_s)
        drop = true
      elsif h == "store" && c[2].is_a?(String) && EH_GLOBALS.include?(c[2])
        drop = true
      elsif h == "store" && (fnames.include?(c[2]) || removed_regs.key?(c[2]))
        drop = true
      elsif h == "let" && head(c[3]) == "load" && (EH_GLOBALS.include?(c[3][2]) || fnames.include?(c[3][2]))
        removed_regs[c[1]] = true
        drop = true
      elsif h == "let" && head(c[3]) == "offset" && fnames.include?(c[3][1])
        removed_regs[c[1]] = true
        drop = true
      elsif h == "let" && derived_of_removed?(c[3], fnames, removed_regs)
        # an address or a value read through the frame's address: the cleanup frame's fields (the region table, the objects'
        # addresses, the saved region number) are set up and read back through chains of offsets
        removed_regs[c[1]] = true
        drop = true
      end
      if drop
        n += 1
      else
        out << walk.call(c)
      end
    end
    out
  end
  g = walk.call(f)
  gone = fnames.to_a + removed_regs.keys
  return [f, 0] if atoms_of(g).any? { |a| gone.include?(a) }
  [g, n]
end

def strip_leaf_eh_pass(forms, report)
  total = 0
  $leaf_defs = {}
  forms.each { |f| $leaf_defs[unq(f[1])] = true if head(f) == "function" }
  bad = throwing_functions(forms)
  forms = forms.map do |f|
    next f unless head(f) == "function"
    g, n = leaf_eh_function(f, bad)
    total += n
    g
  end
  $stderr.write("pathb-ir-opt: dropped #{total} EH frame statement(s) of functions that cannot throw\n") if report
  forms
end

# ---- unreachable functions (--prune-unreachable=SUBSTR) -------------------------------------------------------------------
# Drops the functions and the global or data objects that no root reaches. The roots are the functions whose name contains
# SUBSTR (the SYCL device build's entry kernels, __nfcxx_sycl_entry_). A reached function or object reaches each function or
# object whose name it holds (a &"f", $"x" or @"g" atom), called or not. The IR names every global and function, so a form that
# no reached code names cannot be used by the device; the emitters take only what their kernels reach.
SYCL_ENTRY = "__nfcxx_sycl_entry_"

# --prune-unused: the roots are the definitions that another object can see (neither (static) nor (weak): a weak function or
# object, a template or inline one, is emitted only where it is used), the (constructor) and (destructor) functions and the
# thread-locals; the rest of the module is kept only when a root reaches it by name. A host TU of libstdc++ and vulkan.hpp
# carries tens of thousands of unused instances (ggml-vulkan.cpp: 42720 functions and 129 MB of IR, 8248 and 48 MB after this),
# which --inline would spend its time on.
UNUSED_ROOTS = "\0unused"

def external_root?(f)
  return false if head(f) == "data"
  attrs = f.drop(2).select { |c| c.is_a?(Array) && c[0].is_a?(String) }.map { |c| c[0] }
  return true if attrs.include?("constructor") || attrs.include?("destructor") || attrs.include?("thread") || attrs.include?("used")
  return false if attrs.include?("weak") || attrs.include?("static")
  true   # a definition (or declaration) of external linkage
end

# The quoted names in x: the "...", $"...", &"..." and @"..." atoms (a local slot, a function, a global), in order.
def quoted_names(x, out)
  if x.is_a?(Array)
    x.each { |y| quoted_names(y, out) }
  elsif x.is_a?(String) && (x[0] == "\"" || (x.length > 1 && (x[0] == "$" || x[0] == "&" || x[0] == "@") && x[1] == "\""))
    out << unq(x[0] == "@" ? x[1..-1] : x)
  end
  out
end

# The functions and objects (global, data) that the functions whose names contain substr reach. An object is reached only
# when a reached function or object names it: the other top-level forms of a module (static tables of host code, for one)
# are not roots, so the functions that only they name are dropped too. A name shared by two forms keeps both (a conservative
# match on the name, never a miss).
def prune_pass(forms, substr, report)
  nodes = {}
  forms.each { |f| nodes[unq(f[1])] = f if %w[function global data].include?(head(f)) }
  queue = if substr == UNUSED_ROOTS
            nodes.keys.select { |n| external_root?(nodes[n]) }
          else
            nodes.keys.select { |n| head(nodes[n]) == "function" && n.include?(substr) }
          end
  seen = {}
  until queue.empty?
    n = queue.pop
    next if seen[n]
    seen[n] = true
    quoted_names(nodes[n].drop(2), []).each { |c| queue << c if nodes.key?(c) && !seen[c] }
  end
  out = forms.select { |f| !%w[function global data].include?(head(f)) || seen[unq(f[1])] }
  $stderr.write("pathb-ir-opt: kept #{seen.size} of #{nodes.size} functions and objects (reachable from #{substr})\n") if report
  out
end

# The workers of --sroa: the serial pass (see sroa_pass), so one.
def default_jobs
  1
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
  forward = false
  strip_eh = false
  strip_leaf = false
  prune = nil
  jobs = default_jobs
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
    elsif a.start_with?("--max-callee=")
      $inline_max_callee = a[13..-1].to_i
    elsif a.start_with?("--max-growth=")
      $inline_max_growth = a[13..-1].to_f
    elsif a == "--report"
      report = true
    elsif a == "--forward"
      forward = true
    elsif a == "--strip-eh"
      strip_eh = true
    elsif a == "--strip-leaf-eh"
      strip_leaf = true
    elsif a.start_with?("--jobs=")
      jobs = a[7..-1].to_i
    elsif a.start_with?("--prune-unreachable=")
      prune = a[20..-1]
    elsif a == "--prune-unused"
      prune = UNUSED_ROOTS
    elsif a == "--no-prune"
      prune = false
    elsif a == "-" || !a.start_with?("--")
      file = a
    else
      $stderr.write("usage: pathb-ir-opt.rb [--inline] [--max-depth=N] [--report] [FILE.ir | -] > out.ir\n")
      return 1
    end
  end
  $sroa_debug = report
  unless inline || sroa || forward || strip_eh || strip_leaf || prune
    $stderr.write("pathb-ir-opt: no pass selected (--prune-unreachable=S, --strip-eh, --inline, --sroa, --forward)\n")
    return 1
  end
  begin
    forms = parse(tokenize(read_text(file)))
    # A SYCL device module (entry kernels named __nfcxx_sycl_entry_, the emitters' roots) drops its unreachable functions
    # before --inline or --sroa unless --no-prune is given: they are most of the module (host code of the same TU), and the
    # passes and every later stage would spend their time on them.
    if prune.nil? && (inline || sroa) && forms.any? { |f| head(f) == "function" && f[1].include?(SYCL_ENTRY) }
      prune = SYCL_ENTRY
    end
    forms = prune_pass(forms, prune, report) if prune
    forms = strip_eh_pass(forms, report) if strip_eh
    forms = strip_leaf_eh_pass(forms, report) if strip_leaf
    forms = inline_pass(forms, max_depth, report) if inline
    # a function whose calls were all inlined (or are atomics) is a leaf now: its frames, and those of the bodies copied into it
    forms = strip_leaf_eh_pass(forms, report) if strip_leaf && inline
    # the callees that the inliner copied into every caller are not reached any more
    forms = prune_pass(forms, prune, report) if prune && inline
    forms = sroa_pass(forms, jobs) if sroa
    # a worker's function comes back as its text; a later pass reads forms
    forms = forms.map { |f| f.is_a?(String) ? parse(tokenize(f))[0] : f } if forward
    forms = forward_pass(forms, report) if forward
  rescue BadIR => e
    $stderr.write("error: #{e.message}\n")
    return 1
  end
  forms.each { |f| $stdout.write(show_to(+"", f) << "\n") }
  0
end

unless $pathb_ir_opt_lib
  rc = main(ARGV)
  exit(rc) if rc != 0
end
