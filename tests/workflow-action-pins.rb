# frozen_string_literal: true

workflow_directory = ARGV.fetch(0)
errors = []
action_pattern = /^\s*-\s+uses:\s+([^\s#]+)(?:\s+#.*)?$/
immutable_pattern = %r{\A[^/\s]+/[^@\s]+@[0-9a-f]{40}\z}

Dir.glob(File.join(workflow_directory, '*.{yaml,yml}')).sort.each do |workflow|
  File.foreach(workflow).with_index(1) do |line, line_number|
    match = line.match(action_pattern)
    next unless match

    action = match[1]
    next if action.start_with?('./')
    next if action.match?(immutable_pattern)

    errors << "#{workflow}:#{line_number}: action is not pinned to a commit: #{action}"
  end
end

abort errors.join("\n") unless errors.empty?

puts 'Every third-party workflow action is pinned to an immutable commit.'
