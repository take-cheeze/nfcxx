# frozen_string_literal: true

require 'digest/sha1'
require 'fileutils'
require 'stringio'
require_relative 'site_census'

# SITE_PROFILE (ADR 0298): opt-in counters on the by-name dispatch left in the
# generated C++, so the leftovers can be ranked by executed count.
#
# Off unless BC2CPP_SITE_PROFILE=DIR is set; the unset output is byte-identical.
# Set, bc2cpp's stdout is rewritten after codegen (nothing in codegen reads it):
# every `bc2cpp_send(` / `mrb_funcall*(` call becomes `(hit(ID), fn)(` and a
# DIR/<OUT_SYMBOL>.sites.tsv row records the site. A built binary writes
# $BC2CPP_SITE_PROFILE_OUT/<symbol>.<pid>.hits at exit; no output dir, no dump.
module SiteProfile
  SITE_COLUMNS = %w[id kind line fn name argc category shape origin marker why].freeze
  # The by-name dispatcher bc2cpp_send itself ends in; counting it too would count every send twice.
  DISPATCHERS = %w[bc2cpp_funcall_argv].freeze
  CALL_RE = /(?<![\w.])(bc2cpp_send|mrb_funcall_with_block|mrb_funcall_argv|mrb_funcall_id|mrb_funcall)\((?=M, )/

  module_function

  def ident(symbol)
    symbol.to_s.gsub(/\W/, '_')
  end

  # Rewrites generated C++; returns [instrumented_text, rows]. Row `line` is the
  # line in the input, so classification matches the uninstrumented output.
  def instrument(cpp, symbol)
    scan = SiteCensus.scan(cpp)
    lines = scan.lines
    send_rows = scan.sites.to_h { |s| [s[:line], s] }
    rows = []
    cur = nil
    out = lines.each_with_index.map do |l, i|
      cur = SiteCensus.fn_name(l) || cur
      next l if l.lstrip.start_with?('//') || l !~ CALL_RE

      l.gsub(CALL_RE) do |call|
        next call if DISPATCHERS.include?(cur)

        kind = Regexp.last_match(1)
        row = site_row(scan, send_rows, i, kind, cur, rows.size)
        rows << row
        "(bc2cpp_site_hit_#{ident(symbol)}(#{row[:id]}), #{kind})("
      end
    end
    [header(symbol, rows.size, digest(rows)) + out.join, rows]
  end

  def site_row(scan, send_rows, i, kind, fn, id)
    if kind == 'bc2cpp_send'
      s = send_rows[i + 1]
      base = s || helper_send_row(scan, i, fn)
      return base.merge(id: id, kind: kind, line: i + 1, fn: fn)
    end
    SiteCensus.classify_funcall(scan.lines, scan.names, i, kind, fn).merge(id: id, argc: nil, shape: nil, origin: nil, why: nil)
  end

  # A send inside a shared helper has no guard chain of its own; it is reached from every caller of the helper.
  def helper_send_row(scan, i, fn)
    idx = scan.lines[i][SiteCensus::SEND_RE, 1].to_i
    { name: scan.names[idx], argc: scan.lines[i][SiteCensus::SEND_RE, 2].to_i, category: 'shared_helper', shape: nil, origin: nil,
      marker: SiteCensus.marker_before(scan.lines, i), why: nil, fn: fn }
  end

  # Names a site table, so a hit file from an older binary (a stale build directory)
  # cannot be ranked against a newer table whose ids happen to be in range.
  def digest(rows)
    Digest::SHA1.hexdigest(rows.map { |r| [r[:id], r[:kind], r[:line], r[:name]].join(':') }.join("\n"))[0, 12]
  end

  def header(symbol, count, digest)
    id = ident(symbol)
    <<~CPP
      // SITE_PROFILE -- see tools/bc2cpp/site_profile.rb.
      #include <stdio.h>
      #include <stdlib.h>
      #include <unistd.h>
      static unsigned long long bc2cpp_site_hits_#{id}[#{[count, 1].max}];
      static inline void bc2cpp_site_hit_#{id}(unsigned id) { ++bc2cpp_site_hits_#{id}[id]; }
      static void bc2cpp_site_dump_#{id}() {
        const char* dir = getenv("BC2CPP_SITE_PROFILE_OUT");
        if (!dir || !*dir) return;
        char path[4096];
        snprintf(path, sizeof path, "%s/#{symbol}.%d.hits", dir, (int)getpid());
        FILE* f = fopen(path, "w");
        if (!f) { perror(path); return; }
        fprintf(f, "# sites #{digest}\\n");
        for (unsigned i = 0; i < #{count}; i++)
          if (bc2cpp_site_hits_#{id}[i]) fprintf(f, "%u\\t%llu\\n", i, bc2cpp_site_hits_#{id}[i]);
        fclose(f);
      }
      static const int bc2cpp_site_registered_#{id} = atexit(bc2cpp_site_dump_#{id});
    CPP
  end

  def write_sites(path, rows)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'w') do |f|
      f.puts SITE_COLUMNS.join("\t")
      rows.each { |r| f.puts SITE_COLUMNS.map { |c| r[c.to_sym] }.join("\t") }
    end
  end

  # Called from bc2cpp.rb before the first output line: stdout is held, and on a
  # clean exit written out instrumented. A failed run emits nothing extra.
  def capture_stdout(dir, symbol)
    real = $stdout
    buf = StringIO.new
    $stdout = buf
    at_exit do
      $stdout = real
      next if $!

      text, rows = instrument(buf.string, symbol)
      write_sites(File.join(dir, "#{symbol}.sites.tsv"), rows)
      real.write(text)
    end
  end
end
