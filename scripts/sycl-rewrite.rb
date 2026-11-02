# SYCL device-side rewrite (the first slice of the SYCL front end): each `parallel_for(range<1>(...), LAMBDA)` in a
# SYCL source becomes an extern "C" device function, which the Path B front end lowers to IR and pathb-spirv-emit.rb
# to SPIR-V. The lambda's id parameter is the global index (the same thread-index intrinsics as tests/gpu/device),
# and the accessors it captures are the device function's pointer parameters.
#
# Usage: scripts/mrb scripts/sycl-rewrite.rb FILE.cpp > device.cpp
#
# The output is C++ for the device only: the kernels, named __nfcxx_sycl_k0, __nfcxx_sycl_k1, ... in source order, each
# with the parameters (one pointer per captured accessor, in declaration order, then `int n`). The guard `if (i >= n)`
# is added because the launch rounds the range up to whole work groups. The host side (queue, buffer, handler) is not
# rewritten yet: the runtime is the next slice.
#
# Scope. A scanner, not a parser, like cuda-rewrite.rb. Handled: one lambda with one id parameter (`sycl::id<1> i`), a
# range<1> of an expression, accessors declared as `sycl::accessor NAME(BUFFER, handler, MODE)` on a
# `sycl::buffer<T> BUFFER`, and captures that are accessors. Anything else exits 3 with `refused: ...` on stderr: a
# lambda capturing a scalar or any other variable, a range of 2 or 3 dimensions, a parallel_for without a lambda, and a
# lambda body that uses an accessor whose buffer is not declared with a type.
# No regexp: scripts run on mruby, which has none in core.

def ident_char?(c)
  return false if c.nil?
  o = c.ord
  (o >= 48 && o <= 57) || (o >= 65 && o <= 90) || (o >= 97 && o <= 122) || o == 95
end

def refuse(msg)
  $stderr.puts "refused: #{msg}"
  exit(3)
end

# The positions of the whole word w in s (not inside a longer identifier).
def word_positions(s, w, from = 0, to = nil)
  out = []
  to ||= s.length
  i = s.index(w, from)
  while i && i < to
    before = i > 0 ? s[i - 1] : nil
    after = s[i + w.length]
    out << i unless ident_char?(before) || ident_char?(after)
    i = s.index(w, i + 1)
  end
  out
end

def skip_ws(s, i)
  i += 1 while i < s.length && " \t\r\n".include?(s[i])
  i
end

# The index of the bracket that closes the one at s[open] (( [ or {), skipping string and character literals.
def match_close(s, open)
  pairs = { "(" => ")", "[" => "]", "{" => "}" }
  stack = [pairs[s[open]]]
  i = open + 1
  while i < s.length
    c = s[i]
    if c == "\"" || c == "'"
      i += 1
      i += 1 while i < s.length && s[i] != c
      i += 1
    else
      if pairs.key?(c)
        stack << pairs[c]
      elsif c == ")" || c == "]" || c == "}"
        refuse("unbalanced #{c}") if stack.last != c
        stack.pop
        return i if stack.empty?
      end
      i += 1
    end
  end
  refuse("unbalanced #{s[open]} in the source")
end

# The top-level comma-separated parts of text (commas inside brackets do not split).
def split_top(text)
  parts = []
  depth = 0
  cur = ""
  text.each_char do |c|
    if "([{".include?(c)
      depth += 1
    elsif ")]}".include?(c)
      depth -= 1
    end
    if c == "," && depth == 0
      parts << cur.strip
      cur = ""
    else
      cur << c
    end
  end
  parts << cur.strip unless cur.strip.empty?
  parts
end

# The accessor declarations: [name, buffer name, mode] in source order, and the buffer types: name => element type.
def declarations(src)
  accessors = []
  word_positions(src, "accessor").each do |p|
    j = skip_ws(src, p + 8)
    k = j
    k += 1 while k < src.length && ident_char?(src[k])
    name = src[j...k]
    next if name.empty? || src[skip_ws(src, k)] != "("
    args = split_top(src[(skip_ws(src, k) + 1)...match_close(src, skip_ws(src, k))])
    refuse("accessor #{name} with #{args.length} arguments (the form is accessor(buffer, handler, mode))") unless args.length == 3
    mode = args[2].split("::").last
    accessors << [name, args[0], mode]
  end
  buffers = {}
  word_positions(src, "buffer").each do |p|
    next unless src[p + 6] == "<"
    close = src.index(">", p + 7)
    type = src[(p + 7)...close].strip
    # every declarator of the statement: sycl::buffer<float> A(a), B(b);
    semi = src.index(";", close) || src.length
    split_top(src[(close + 1)...semi]).each do |d|
      name = ""
      name << d[name.length] while name.length < d.length && ident_char?(d[name.length])
      buffers[name] = type unless name.empty?
    end
  end
  [accessors, buffers]
end

# The index of the first `sycl::range<1>` or `range<1>` argument check, and the parallel_for calls in source order.
def lambda_parts(src, open)
  close = match_close(src, open)
  args = split_top(src[(open + 1)...close])
  refuse("parallel_for with #{args.length} arguments (the form is parallel_for(range, lambda))") unless args.length == 2
  range = args[0]
  head = range.sub("sycl::", "")
  refuse("parallel_for over #{range} (only range<1>)") unless head.start_with?("range<1>(") && range.end_with?(")")
  n_expr = head[9...-1]
  lam = args[1]
  lb = lam.index("(")
  refuse("parallel_for argument is not a lambda") unless lam.start_with?("[") && lb && lam.index("]") < lb
  lp = match_close(lam, lb)
  params = split_top(lam[(lb + 1)...lp])
  refuse("lambda with #{params.length} parameters (only the id)") unless params.length == 1
  id_name = params[0].split(" ").last
  bo = lam.index("{", lp)
  refuse("lambda without a body") unless bo
  body = lam[(bo + 1)...match_close(lam, bo)]
  [n_expr, id_name, body]
end

def rewrite(src)
  accessors, buffers = declarations(src)
  out = "// Generated by scripts/sycl-rewrite.rb from the SYCL source; do not edit.\n" \
        "extern \"C\" unsigned __nfcxx_tid_x(void);\n" \
        "extern \"C\" unsigned __nfcxx_ctaid_x(void);\n" \
        "extern \"C\" unsigned __nfcxx_ntid_x(void);\n"
  calls = []
  word_positions(src, "parallel_for").each do |p|
    open = skip_ws(src, p + 12)
    next unless src[open] == "(" # a mention without an argument list (a comment, a name): not a call
    calls << [p, open]
  end
  refuse("no parallel_for in the source") if calls.empty?
  calls.each_with_index do |(p, open), k|
    n_expr, id_name, body = lambda_parts(src, open)
    captured = accessors.select { |a| word_positions(body, a[0]).length > 0 }
    captured.each do |a|
      type = buffers[a[1]]
      refuse("accessor #{a[0]} on buffer #{a[1]} with no sycl::buffer<T> declaration") if type.nil?
    end
    params = captured.map do |a|
      type = buffers[a[1]]
      if a[2] == "read_only" then "const #{type} *#{a[0]}" else "#{type} *#{a[0]}" end
    end
    params << "int n"
    out << "\n// parallel_for #{k}: #{n_expr} work items\n"
    out << "extern \"C\" void __nfcxx_sycl_k#{k}(#{params.join(", ")}) {\n"
    out << "  int #{id_name} = (int)__nfcxx_tid_x() + (int)__nfcxx_ctaid_x() * (int)__nfcxx_ntid_x();\n"
    out << "  if (#{id_name} >= n) return;\n"
    out << body.strip.split("\n").map { |l| "  #{l.strip}" }.join("\n") << "\n"
    out << "}\n"
  end
  out
end

def main(argv)
  if argv.length != 1
    $stderr.puts "usage: sycl-rewrite.rb FILE.cpp > device.cpp"
    return 1
  end
  src = File.open(argv[0], "rb") { |f| f.read }
  $stdout.write(rewrite(src))
  0
end

rc = main(ARGV)
exit(rc) if rc != 0
