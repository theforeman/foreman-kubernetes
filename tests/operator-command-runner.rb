#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'
require 'rbconfig'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/command_runner').to_s

runner = ForemanRelease::CommandRunner.new(timeout_seconds: 2, termination_grace_seconds: 1)
output = runner.run(RbConfig.ruby, '-e', 'STDOUT.write(STDIN.read.upcase)', stdin_data: 'bounded')
raise 'command runner did not preserve stdin and stdout' unless output == 'BOUNDED'

begin
  runner.run(RbConfig.ruby, '-e', 'warn "expected failure"; exit 7')
  raise 'non-zero command was accepted'
rescue ForemanRelease::CommandError => error
  raise 'wrong exit status was reported' unless error.exit_status == 7
  raise 'stderr was lost' unless error.stderr.include?('expected failure')
end

timeout_runner = ForemanRelease::CommandRunner.new(timeout_seconds: 0.1, termination_grace_seconds: 0.1)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
  timeout_runner.run(RbConfig.ruby, '-e', "trap('TERM', 'IGNORE'); sleep 30")
  raise 'hung command was accepted'
rescue ForemanRelease::CommandTimeout => error
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  raise 'timeout did not report its budget' unless error.timeout_seconds == 0.1
  raise 'timed-out process group was not terminated promptly' unless elapsed < 2
end

puts 'Command runner preserves output, reports failures, and kills timed-out process groups.'
