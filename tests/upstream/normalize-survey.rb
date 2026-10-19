# Separate unsupported dialect flags from reference/example rejection.
# Usage: scripts/mrb normalize-survey.rb RESULT_ROOT INPUT.tsv
root, input = ARGV
File.open(input, 'rb') do |f|
  f.read.split("\n").each_with_index do |line, index|
    if index == 0
      puts line
      next
    end
    row = line.split("\t", -1)
    if row[5] == 'rejected'
      log = File.open(root + '/' + row[1] + '/' + row[4] + '.log', 'rb') { |logfile| logfile.read }
      if log.include?('unknown option: --' + row[3]) || log.include?('invalid option: --' + row[3]) ||
          (log.include?('unrecognized command-line option') && log.include?('-std=' + row[3]))
        row[5] = 'mode-unavailable'
      end
    end
    puts row.join("\t")
  end
end
