# Extract explicitly tagged runnable examples, not API declarations/fragments.
# Usage: scripts/mrb tests/upstream/cpprefjp-extract.rb ROOT OUT PAGE...
def die(message)
  $stderr.puts message
  exit 1
end
die('usage: cpprefjp-extract.rb ROOT OUT PAGE...') if ARGV.size < 3
root, out = ARGV.shift, ARGV.shift
puts "id\tpage\texample\tsource\toutput"
seen = {}
ARGV.each do |page|
  die('unsafe page path') if page.start_with?('/') || page.split('/').include?('..')
  text = File.open(root + '/' + page, 'rb') { |f| f.read }
  fence = nil; selected = false; lines = []; number = 0; start_line = 0
  text.split("\n").each_with_index do |line, index|
    stripped = line.strip
    if fence
      if stripped == fence
        if selected
          number += 1
          id = page.byteslice(0, page.bytesize - 3).split('/').join('--') + '-' + number.to_s
          die('duplicate example ID: ' + id) if seen[id]
          seen[id] = true
          source = out + '/' + id + '.cpp'
          attribution = '// cpprefjp/site 213f89d, ' + page + ':' + start_line.to_s + "\n"
          attribution += "// CC BY 4.0; extraction adds this header and a final newline.\n"
          File.open(source, 'wb') { |f| f.write(attribution + lines.join("\n") + "\n") }
          puts [id, page, number.to_s, source, '-'].join("\t")
        end
        fence = nil; selected = false; lines = []
      else
        lines << line if selected
      end
    elsif stripped.start_with?('```', '~~~')
      marker = stripped.byteslice(0, 3)
      n = 3
      n += 1 while stripped.byteslice(n, 1) == marker.byteslice(0, 1)
      fence = stripped.byteslice(0, n)
      info = stripped.byteslice(n, stripped.bytesize - n).strip.split
      selected = ['cpp', 'c++'].include?(info[0]) && info.include?('example')
      start_line = index + 2
    end
  end
  die('unterminated example fence: ' + page) if fence && selected
end
