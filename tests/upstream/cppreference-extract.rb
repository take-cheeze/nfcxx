# Extract complete example blocks from the pinned cppreference HTML book.
# Usage: scripts/mrb tests/upstream/cppreference-extract.rb HTML_ROOT OUT PAGE...
# PAGE is relative to HTML_ROOT; outputs are data under ignored build/.
def die(message)
  $stderr.puts message
  exit 1
end
die('usage: cppreference-extract.rb HTML_ROOT OUT PAGE...') if ARGV.size < 3
root, out = ARGV.shift, ARGV.shift
def utf8(n)
  if n < 128
    n.chr
  elsif n < 2048
    (192 + (n >> 6)).chr + (128 + (n & 63)).chr
  elsif n < 65536
    (224 + (n >> 12)).chr + (128 + ((n >> 6) & 63)).chr + (128 + (n & 63)).chr
  else
    (240 + (n >> 18)).chr + (128 + ((n >> 12) & 63)).chr + (128 + ((n >> 6) & 63)).chr + (128 + (n & 63)).chr
  end
end
def plain(html)
  text = ''; i = 0
  while i < html.bytesize
    if html.getbyte(i) == 60
      stop = html.index('>', i)
      die('unterminated HTML tag') unless stop
      i = stop + 1
    elsif html.getbyte(i) == 38
      stop = html.index(';', i)
      die('unterminated HTML entity') unless stop
      entity = html.byteslice(i + 1, stop - i - 1)
      value = {'amp'=>'&', 'lt'=>'<', 'gt'=>'>', 'quot'=>'"', 'apos'=>"'", 'nbsp'=>' '}[entity]
      if entity.start_with?('#')
        n = entity.start_with?('#x', '#X') ? entity.byteslice(2, entity.bytesize - 2).to_i(16) : entity.byteslice(1, entity.bytesize - 1).to_i
        value = n == 160 ? ' ' : utf8(n)
      end
      die('unknown HTML entity: ' + entity) unless value
      text += value
      i = stop + 1
    else
      text += html.byteslice(i, 1)
      i += 1
    end
  end
  # The HTML book uses literal NBSP for layout, even between C++ tokens.
  text.gsub("\xc2\xa0", ' ')
end
puts "id\tpage\texample\tsource\toutput"
seen = {}
def write_file(path, contents)
  File.open(path + '.tmp', 'wb') { |f| f.write(contents) }
  File.rename(path + '.tmp', path)
end
ARGV.each do |page|
  die('unsafe page path') if page.start_with?('/') || page.split('/').include?('..')
  html = File.open(root + '/' + page, 'rb') { |f| f.read }
  pos = 0; number = 0
  while (start = html.index('<div class="t-example">', pos))
    number += 1
    # Find this example's closing div, accounting for syntax-highlighter divs.
    cursor = start + '<div class="t-example">'.bytesize
    depth = 1
    while depth > 0
      opening = html.index('<div', cursor)
      closing = html.index('</div>', cursor)
      die('unterminated example in ' + page) unless closing
      if opening && opening < closing
        depth += 1; cursor = opening + 4
      else
        depth -= 1; cursor = closing + 6
      end
    end
    block = html.byteslice(start, cursor - start)
    pos = cursor
    pres = []; p = 0
    while (p = block.index('<pre', p))
      p = block.index('>', p)
      finish = block.index('</pre>', p)
      die('unterminated pre in ' + page) unless finish
      pres << plain(block.byteslice(p + 1, finish - p - 1))
      p = finish + 6
    end
    # Only cpp source blocks are eligible; explanatory fragments elsewhere are ignored.
    next if pres.empty? || !block.include?('source-cpp')
    # Language IDs remain compatible with the reviewed pilot. Library pages
    # need their entire path: thousands of different classes have "begin" etc.
    stem = page.start_with?('cpp/language/') ? page.split('/')[-1] : page.split('/').join('--')
    # Strip only the .html suffix: sizeof....html describes sizeof..., a
    # different feature from sizeof.html.
    id = stem.byteslice(0, stem.bytesize - 5) + '-' + number.to_s
    die('duplicate example ID: ' + id) if seen[id]
    seen[id] = true
    source = out + '/' + id + '.cpp'
    write_file(source, pres[0] + "\n")
    output = '-'
    if pres.size == 2 && block.include?('source-text')
      output = out + '/' + id + '.output'
      write_file(output, pres[1] + "\n")
    end
    puts [id, page, number.to_s, source, output].join("\t")
  end
end
