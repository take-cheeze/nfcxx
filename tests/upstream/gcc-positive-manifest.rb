# Use only the exact positive-action/standard forms recognized by gcc-index.rb.
root = ARGV[0]
puts "suite\tid\tpage\tstandard\tsource"
File.open(root + '/gcc-inventory.tsv', 'rb') do |f|
  f.read.split("\n")[1..-1].each do |line|
    page, action, standard, classification = line.split("\t", -1)
    next unless classification == 'simple-positive'
    id = page.split('/').join('--')
    puts ['gcc', id, page, standard, root + '/gcc/' + page].join("\t")
  end
end
