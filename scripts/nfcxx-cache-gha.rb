#!/usr/bin/env ruby
# Ruby port of scripts/nfcxx-cache-gha.py: stores and fetches one nfcxx compile-cache entry in the GitHub Actions cache
# service (cache v2). Same command line, messages and exit codes. Ruby standard library only. Run it with no arguments
# for the usage text, which describes the wire format too.
require "digest"
require "fileutils"
require "net/http"
require "uri"

module NfcxxCacheGha
  NAMESPACE = "nfcxx-cache-v1"
  SERVICE = "twirp/github.actions.results.api.v1.CacheService/"
  ACCEPT = "application/json;api-version=6.0-preview.1"
  # Python's "$" also matches before one final newline, so a key may end with one; this accepts the same keys.
  KEY_RE = /\A[A-Za-z0-9._-]{1,200}\n?\z/

  USAGE = <<-'USAGE'
Stores and fetches one nfcxx compile-cache entry in the GitHub Actions cache service (cache v2, the protocol sccache's
GHA backend uses through OpenDAL). Standard library only; run it with `ruby`.

  nfcxx-cache-gha.rb get KEY DIR           extracts the entry KEY into DIR (created). Exit 0: hit. Exit 1: miss.
  nfcxx-cache-gha.rb put KEY DIR FILE...   stores FILE... (paths relative to DIR) as the entry KEY. Exit 0: stored, or the
                                           key already exists (GHA entries are immutable). Exit 2: an error.

The entry is a tar of the named files. Its cache key is "nfcxx-<KEY>" and its version is the SHA-256 of NAMESPACE, so a
change to NAMESPACE drops every entry. The service comes from ACTIONS_RESULTS_URL and ACTIONS_RUNTIME_TOKEN (set in a
workflow step that runs with the cache enabled; ACTIONS_CACHE_SERVICE_V2 must be set too, or the runner uses v1).

Wire format (from the actions/toolkit generated types and OpenDAL's ghac service): Twirp POSTs with protobuf bodies to
  twirp/github.actions.results.api.v1.CacheService/{CreateCacheEntry,FinalizeCacheEntryUpload,GetCacheEntryDownloadURL}
CreateCacheEntry returns a signed upload URL, which takes the blob with PATCH and a Content-Range header. Finalize
commits the size. GetCacheEntryDownloadURL returns a signed URL that is read with GET.
  USAGE

  class CacheError < StandardError; end
  class NetError < CacheError; end

  # --- protobuf (only what these messages use: varints and length-delimited strings/bytes) ---

  module_function

  def varint(n)
    out = []
    loop do
      b = n & 0x7F
      n >>= 7
      if n != 0
        out << (b | 0x80)
      else
        out << b
        break
      end
    end
    out.pack("C*")
  end

  def pb_str(field, s)
    data = s.b
    varint((field << 3) | 2) + varint(data.bytesize) + data
  end

  def pb_int(field, n)
    varint(field << 3) + varint(n)
  end

  # Raises IndexError with Python's message when the buffer ends inside a field.
  def byte_at(buf, i)
    b = buf.getbyte(i)
    raise IndexError, "index out of range" if b.nil?
    b
  end

  # Returns {field => [value, ...]}; a varint is an Integer, a length-delimited field is a binary String.
  def pb_decode(buf)
    buf = buf.b
    out = {}
    i = 0
    while i < buf.bytesize
      tag = 0
      shift = 0
      loop do
        b = byte_at(buf, i)
        i += 1
        tag |= (b & 0x7F) << shift
        shift += 7
        break if (b & 0x80) == 0
      end
      field = tag >> 3
      wire = tag & 7
      case wire
      when 0
        val = 0
        shift = 0
        loop do
          b = byte_at(buf, i)
          i += 1
          val |= (b & 0x7F) << shift
          shift += 7
          break if (b & 0x80) == 0
        end
      when 2
        n = 0
        shift = 0
        loop do
          b = byte_at(buf, i)
          i += 1
          n |= (b & 0x7F) << shift
          shift += 7
          break if (b & 0x80) == 0
        end
        val = buf.byteslice(i, n) || "".b
        i += n
      else
        raise CacheError, "unsupported protobuf wire type #{wire}"
      end
      (out[field] ||= []) << val
    end
    out
  end

  # Python truthiness of a decoded field: a varint is true when nonzero, bytes when nonempty.
  def truthy?(v)
    v.is_a?(Integer) ? v != 0 : !v.empty?
  end

  # bytes.decode() (UTF-8, strict).
  def utf8(bytes)
    s = bytes.dup.force_encoding(Encoding::UTF_8)
    return s if s.valid_encoding?
    pos = 0
    s.each_char do |c|
      unless c.valid_encoding?
        byte = c.getbyte(0)
        reason = (byte >= 0x80 && byte <= 0xBF) || byte == 0xC0 || byte == 0xC1 || byte >= 0xF5 ? "invalid start byte" : "invalid continuation byte"
        raise CacheError, "'utf-8' codec can't decode byte 0x#{format('%02x', byte)} in position #{pos}: #{reason}"
      end
      pos += c.bytesize
    end
    s
  end

  # --- Python's repr() of a str or bytes, for the messages that quote a key or a response body ---

  def py_str_repr(s)
    s = s.dup.force_encoding(Encoding::UTF_8)
    quote = s.include?("'") && !s.include?('"') ? '"' : "'"
    out = String.new(quote)
    s.each_char do |ch|
      if !ch.valid_encoding?
        out << format("\\x%02x", ch.getbyte(0))
      elsif ch == "\\"
        out << "\\\\"
      elsif ch == quote
        out << "\\" << quote
      elsif ch == "\t"
        out << "\\t"
      elsif ch == "\n"
        out << "\\n"
      elsif ch == "\r"
        out << "\\r"
      elsif ch.ord < 0x20 || (0x7f..0x9f).cover?(ch.ord)
        out << format("\\x%02x", ch.ord)
      else
        out << ch
      end
    end
    out << quote
  end

  def py_bytes_repr(bytes)
    quote = bytes.include?("'") && !bytes.include?('"') ? '"' : "'"
    out = "b#{quote}".b
    bytes.each_byte do |c|
      out << case c
             when 0x5c then "\\\\"
             when 0x09 then "\\t"
             when 0x0a then "\\n"
             when 0x0d then "\\r"
             else
               if c == quote.ord
                 "\\" + quote
               elsif c < 0x20 || c >= 0x7f
                 format("\\x%02x", c)
               else
                 c.chr
               end
             end
    end
    out << quote
  end

  # str(OSError) for a failed file operation: "[Errno 13] Permission denied: 'path'".
  def os_message(e, path)
    "[Errno #{e.errno}] #{SystemCallError.new(nil, e.errno).message}: #{py_str_repr(path)}"
  end

  # --- HTTP ---

  # One request; returns the Net::HTTP response. Transport failures are NetError with urllib's wording.
  def send_request(method, url, body, headers, timeout)
    uri = URI(url)
    raise CacheError, "unknown url type: #{uri.scheme}" unless uri.is_a?(URI::HTTP)
    klass = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post, "PATCH" => Net::HTTP::Patch }.fetch(method)
    req = klass.new(uri.request_uri, headers)
    req.body = body if body
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                    open_timeout: timeout, read_timeout: timeout, write_timeout: timeout) { |h| h.request(req) }
  rescue Timeout::Error
    raise NetError, "timed out"
  rescue SystemCallError => e
    raise NetError, "<urlopen error [Errno #{e.errno}] #{SystemCallError.new(nil, e.errno).message}>"
  rescue SocketError, Net::ProtocolError, IOError => e
    raise NetError, "<urlopen error #{e.message}>"
  end

  # urllib.request.urlopen(...).read(): the body of a 2xx answer; any other status is "HTTP Error CODE: REASON".
  def http(method, url, body = nil, headers = {}, timeout = 300)
    res = send_request(method, url, body, headers, timeout)
    raise NetError, "HTTP Error #{res.code}: #{res.message}" unless res.is_a?(Net::HTTPSuccess)
    res.body.to_s.b
  end

  # --- the service ---

  class Service
    def initialize
      base = ENV.fetch("ACTIONS_RESULTS_URL", "")
      token = ENV.fetch("ACTIONS_RUNTIME_TOKEN", "")
      if base.empty? || token.empty?
        raise CacheError, "ACTIONS_RESULTS_URL and ACTIONS_RUNTIME_TOKEN are not set (not in a workflow step with the cache)"
      end
      @base = base.sub(%r{/+\z}, "") + "/"
      @token = token
      @version = Digest::SHA256.hexdigest(NAMESPACE)
    end

    def call(method, body)
      res = NfcxxCacheGha.send_request("POST", @base + SERVICE + method, body,
                                       { "Authorization" => "Bearer #{@token}", "Content-Type" => "application/protobuf",
                                         "Accept" => ACCEPT }, 120)
      unless res.is_a?(Net::HTTPSuccess)
        raise CacheError, "#{method}: HTTP #{res.code} #{NfcxxCacheGha.py_bytes_repr(res.body.to_s.b[0, 300])}"
      end
      NfcxxCacheGha.pb_decode(res.body.to_s)
    end

    # The signed download URL of KEY, or nil when the entry is absent.
    def download_url(key)
      resp = call("GetCacheEntryDownloadURL", NfcxxCacheGha.pb_str(2, "nfcxx-" + key) + NfcxxCacheGha.pb_str(4, @version))
      return nil unless NfcxxCacheGha.truthy?(resp.fetch(1, [0])[0])
      NfcxxCacheGha.utf8(resp.fetch(2)[0])
    end

    # A signed upload URL for a new entry, or nil when the key already exists.
    def reserve(key)
      resp = call("CreateCacheEntry", NfcxxCacheGha.pb_str(2, "nfcxx-" + key) + NfcxxCacheGha.pb_str(3, @version))
      return nil unless NfcxxCacheGha.truthy?(resp.fetch(1, [0])[0])
      NfcxxCacheGha.utf8(resp.fetch(2)[0])
    end

    def finalize(key, size)
      resp = call("FinalizeCacheEntryUpload",
                  NfcxxCacheGha.pb_str(2, "nfcxx-" + key) + NfcxxCacheGha.pb_int(3, size) + NfcxxCacheGha.pb_str(4, @version))
      raise CacheError, "FinalizeCacheEntryUpload returned not ok" unless NfcxxCacheGha.truthy?(resp.fetch(1, [0])[0])
    end
  end

  # --- tar: a minimal ustar writer and reader for regular files at the top level ---

  # os.path.join(dir, name) for two parts.
  def join(dir, name)
    return name if name.start_with?("/")
    return dir + name if dir.empty? || dir.end_with?("/")
    "#{dir}/#{name}"
  end

  # A name the entry may carry: one top-level component, not "." or "..", within the 100-byte ustar name field.
  def check_name!(name)
    if name.empty? || name.include?("/") || name == "." || name == ".."
      raise CacheError, "unsupported entry name #{py_str_repr(name)}"
    end
    raise CacheError, "entry name too long for ustar: #{py_str_repr(name)}" if name.bytesize > 100
  end

  # A field of `width` bytes: octal digits, then NUL.
  def oct(n, width)
    format("%0#{width - 1}o", n) + "\0"
  end

  def ustar_header(name, size, mode, mtime, uid, gid)
    raise CacheError, "file too large for ustar: #{py_str_repr(name)}" if size >= 8**11
    uid = 0 if uid >= 8**7
    gid = 0 if gid >= 8**7
    h = "\0".b * 512
    h[0, name.bytesize] = name.b
    h[100, 8] = oct(mode, 8)
    h[108, 8] = oct(uid, 8)
    h[116, 8] = oct(gid, 8)
    h[124, 12] = oct(size, 12)
    h[136, 12] = oct([mtime, 0].max, 12)
    h[148, 8] = "        "
    h[156, 1] = "0"
    h[257, 6] = "ustar\0"
    h[263, 2] = "00"
    h[329, 8] = oct(0, 8)
    h[337, 8] = oct(0, 8)
    h[148, 8] = format("%06o", h.bytes.sum) + "\0 "
    h
  end

  # The archive of the named files, as tarfile writes it: records of 10240 bytes, with two zero blocks at the end.
  def pack(src_dir, names)
    out = "".b
    names.each do |name|
      path = join(src_dir, name)
      raise CacheError, "#{path} is not a file" unless File.file?(path)
      check_name!(name)
      begin
        data = File.binread(path)
        st = File.stat(path)
      rescue SystemCallError => e
        raise CacheError, os_message(e, path)
      end
      out << ustar_header(name, data.bytesize, st.mode & 0o7777, st.mtime.to_i, st.uid, st.gid)
      out << data
      out << "\0" * ((512 - data.bytesize % 512) % 512)
    end
    out << "\0" * 1024
    out << "\0" * ((10240 - out.bytesize % 10240) % 10240)
    out
  end

  # The NUL-terminated or space-padded octal number of a header field (tarfile's nti).
  def field_octal(field)
    s = (field.b.split("\0", 2)[0] || "").strip
    return 0 if s.empty?
    raise CacheError, "invalid header" unless s.match?(/\A[0-7]+\z/)
    s.to_i(8)
  end

  def parse_header(block)
    chk = field_octal(block.byteslice(148, 8))
    unsigned = 0
    signed = 0
    block.each_byte.with_index do |b, i|
      v = (148...156).cover?(i) ? 32 : b
      unsigned += v
      signed += v > 127 ? v - 256 : v
    end
    raise CacheError, "bad checksum" unless chk == unsigned || chk == signed
    name = (block.byteslice(0, 100).split("\0", 2)[0] || "")
    prefix = block.byteslice(345, 155).split("\0", 2)[0] || ""
    name = "#{prefix}/#{name}" unless prefix.empty?
    type = block.byteslice(156, 1)
    type = "0" if type == "\0"
    {
      name: name, type: type, size: field_octal(block.byteslice(124, 12)),
      mode: field_octal(block.byteslice(100, 8)), mtime: field_octal(block.byteslice(136, 12))
    }
  end

  # The records of a PAX extended header: "LEN KEY=VALUE\n", LEN counting the whole record.
  def pax_records(data)
    recs = {}
    pos = 0
    while pos < data.bytesize
      sp = data.index(" ", pos)
      raise CacheError, "invalid header" if sp.nil?
      len_text = data.byteslice(pos, sp - pos)
      raise CacheError, "invalid header" unless len_text.match?(/\A[0-9]+\z/)
      len = len_text.to_i
      raise CacheError, "invalid header" if len < 1 || pos + len > data.bytesize
      rec = data.byteslice(sp + 1, pos + len - sp - 1)
      raise CacheError, "invalid header" unless rec.end_with?("\n")
      key, val = rec.chomp("\n").split("=", 2)
      recs[key] = val.to_s if key
      pos += len
    end
    recs
  end

  def check_entry_name!(name)
    if name.empty? || name.include?("/") || name == "." || name == ".."
      raise CacheError, "unexpected entry #{py_str_repr(name)}"
    end
  end

  def unpack(data, dest)
    begin
      FileUtils.mkdir_p(dest)
    rescue SystemCallError => e
      raise CacheError, os_message(e, dest)
    end
    data = data.b
    pos = 0
    pax = {}
    loop do
      break if pos >= data.bytesize
      raise CacheError, "truncated header" if data.bytesize - pos < 512
      block = data.byteslice(pos, 512)
      break if block == "\0".b * 512
      hdr = parse_header(block)
      pos += 512
      name = pax.fetch("path", hdr[:name])
      size = pax.key?("size") ? Integer(pax["size"], 10) : hdr[:size]
      raise CacheError, "unexpected end of data" if size > data.bytesize - pos
      content = data.byteslice(pos, size)
      pos += (size + 511) / 512 * 512
      case hdr[:type]
      when "x"
        pax = pax_records(content)
        next
      when "g"
        pax = {}
        next
      when "0", "7"
        nil
      else
        raise CacheError, "unexpected entry #{py_str_repr(name)}"
      end
      pax = {}
      check_entry_name!(name)
      mode = hdr[:mode] & 0o755
      mode &= ~0o111 if (mode & 0o100) == 0
      mode |= 0o600
      target = join(dest, name)
      mtime = hdr[:mtime]
      begin
        File.binwrite(target, content)
        File.chmod(mode, target)
        File.utime(mtime, mtime, target)
      rescue SystemCallError => e
        raise CacheError, os_message(e, target)
      end
    end
  end

  # --- the commands ---

  def get(key, dest)
    svc = Service.new
    url = svc.download_url(key)
    return 1 if url.nil?
    data = http("GET", url)
    unpack(data, dest)
    0
  end

  def put(key, src_dir, names)
    svc = Service.new
    data = pack(src_dir, names)
    url = svc.reserve(key)
    return 0 if url.nil?   # already stored (entries are immutable): nothing to do
    n = data.bytesize
    http("PATCH", url, data, { "Content-Type" => "application/octet-stream", "Content-Length" => n.to_s,
                               "Content-Range" => "bytes 0-#{n - 1}/#{n}" }, 300)
    svc.finalize(key, n)
    0
  end

  def main(argv)
    if argv.length < 3 || !%w[get put].include?(argv[0])
      $stderr.write(USAGE + "\n")
      return 2
    end
    cmd, key, path = argv[0], argv[1], argv[2]
    unless KEY_RE.match?(key.b)
      $stderr.write("nfcxx-cache-gha: bad key #{py_str_repr(key)}\n")
      return 2
    end
    begin
      return get(key, path) if cmd == "get"
      if argv.length < 4
        $stderr.write("nfcxx-cache-gha: put needs at least one FILE\n")
        return 2
      end
      return put(key, path, argv[3..])
    rescue KeyError
      raise   # not an error the Python script catches: it ends with a traceback and exit 1
    rescue CacheError, SystemCallError, IOError, IndexError => e
      $stderr.write("nfcxx-cache-gha: #{cmd} #{key}: #{e.message}\n")
      return 2
    end
  end
end

exit(NfcxxCacheGha.main(ARGV)) if __FILE__ == $PROGRAM_NAME
