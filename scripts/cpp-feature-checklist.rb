# Parse a locally fetched, pinned cpprefjp checklist. No network access here.
# Usage: scripts/mrb scripts/cpp-feature-checklist.rb implementation-status.md
# TSV stays in build/: upstream descriptions/version notes are not vendored.
# A malformed checklist: main reports the message and returns status 1. Raised, not exited, so the compiled build
# (script-world) returns the same status as the interpreter.
class ChecklistError < StandardError; end
def fail_checklist(message)
  raise ChecklistError, message
end
def main(argv)
  begin
    check_run(argv)
  rescue ChecklistError => e
    $stderr.puts e.message
    1
  rescue SystemCallError => e
    $stderr.puts "cpp-feature-checklist.rb: #{e.message}"
    1
  end
end

def check_run(argv)
  fail_checklist 'usage: cpp-feature-checklist.rb implementation-status.md' unless argv.size == 1
  rows = []
  seen = {}
  standard = nil
  File.open(argv[0], 'rb') do |file|
    lines = file.read.split("\n")
    references = {}
    lines.each do |line|
      if line.start_with?('[') && line.include?(']: ')
        name, url = line.split(']: ', 2)
        references[name.byteslice(1, name.bytesize - 1)] = url.strip
      end
    end
    lines.each do |line|
      if line.start_with?('## <a id="cpp')
        start = line.index('id="cpp') + 7
        finish = line.index('"', start)
        standard = line.byteslice(start, finish - start)
      end
      next unless line.start_with?('| N', '| P')
      cells = line.strip.split('|', -1)
      fail_checklist 'malformed checklist row: ' + line unless cells.size == 8 && standard
      cells = cells[1, 6].map { |cell| cell.strip }
      paper = cells[0].split(':', 2)[0]
      fail_checklist 'missing paper number: ' + line unless cells[0].include?(':')
      # Some rows link only from the explanation (e.g. N1653).
      text = cells[0] + ' ' + cells[1]
      start = text.index('](')
      if start
        start += 2
        finish = text.index(')', start)
        fail_checklist 'unterminated language page: ' + line unless finish
        page = text.byteslice(start, finish - start)
        slug = page.split('/')[-1].split('.')[0]
        slug += '-' + page.split('#', 2)[1] if page.include?('#')
      else
        page = references[paper]
        fail_checklist 'missing language page or paper reference: ' + line unless page
        slug = 'paper'
      end
      key = 'cpp' + standard + '-' + paper + '-' + slug
      fail_checklist 'duplicate checklist key: ' + key if seen[key]
      seen[key] = true
      row = [key, 'c++' + standard, paper, page, cells[0], cells[1]] + cells[2, 4]
      fail_checklist 'tab in checklist row' if row.any? { |cell| cell.include?("\t") }
      rows << row
    end
  end
  fail_checklist 'no checklist rows found' if rows.empty?
  puts "key\tstandard\tpaper\tpage\tfeature\tdescription\tgcc\tclang\tintel\tmsvc"
  rows.each { |row| puts row.join("\t") }
  0
end

rc = main(ARGV)
exit(rc) if rc != 0
