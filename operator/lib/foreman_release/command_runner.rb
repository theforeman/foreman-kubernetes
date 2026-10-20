# frozen_string_literal: true

require 'open3'
require 'timeout'

module ForemanRelease
  class CommandError < StandardError
    attr_reader :command, :stderr, :exit_status

    def initialize(command, stderr, exit_status)
      @command = command
      @stderr = stderr
      @exit_status = exit_status
      super("command failed with exit status #{exit_status}: #{command.join(' ')}: #{stderr.strip}")
    end
  end

  class CommandTimeout < StandardError
    attr_reader :command, :timeout_seconds, :stderr

    def initialize(command, timeout_seconds, stderr)
      @command = command
      @timeout_seconds = timeout_seconds
      @stderr = stderr
      super("command exceeded #{timeout_seconds} seconds: #{command.join(' ')}: #{stderr.strip}")
    end
  end

  class CommandRunner
    def initialize(timeout_seconds: 60, termination_grace_seconds: 5)
      raise ArgumentError, 'command timeout must be positive' unless timeout_seconds.positive?
      raise ArgumentError, 'termination grace period must be positive' unless termination_grace_seconds.positive?

      @timeout_seconds = timeout_seconds
      @termination_grace_seconds = termination_grace_seconds
    end

    def run(*command, stdin_data: '')
      stdout_data = nil
      stderr_data = nil
      status = nil
      Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, wait_thread|
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }
        begin
          stdin.write(stdin_data)
          stdin.close
          status = Timeout.timeout(@timeout_seconds) { wait_thread.value }
        rescue Timeout::Error
          terminate_process_group(wait_thread.pid, wait_thread)
          stdout_data = stdout_reader.value
          stderr_data = stderr_reader.value
          raise CommandTimeout.new(command, @timeout_seconds, stderr_data)
        ensure
          stdin.close unless stdin.closed?
        end
        stdout_data ||= stdout_reader.value
        stderr_data ||= stderr_reader.value
      end
      raise CommandError.new(command, stderr_data, status.exitstatus) unless status.success?

      stdout_data
    end

    private

    def terminate_process_group(pid, wait_thread)
      signal_group('TERM', pid)
      Timeout.timeout(@termination_grace_seconds) { wait_thread.value }
    rescue Timeout::Error
      signal_group('KILL', pid)
      wait_thread.value
    end

    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
