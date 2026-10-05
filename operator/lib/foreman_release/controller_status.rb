# frozen_string_literal: true

require 'thread'
require 'time'

module ForemanRelease
  class ControllerStatus
    def initialize(clock: -> { Time.now.utc })
      @clock = clock
      @mutex = Mutex.new
      @running = false
      @role = :unknown
      @successful_cycles = 0
      @failed_cycles = 0
      @last_success_at = nil
      @releases = []
    end

    def started
      update { @running = true }
    end

    def stopped
      update do
        @running = false
        @role = :unknown
        @releases = []
      end
    end

    def role_changed(role)
      update do
        @role = role.to_sym
        @releases = [] unless @role == :leader
      end
    end

    def releases_observed(resources)
      observed = resources.map do |resource|
        {
          namespace: resource.dig('metadata', 'namespace').to_s,
          name: resource.dig('metadata', 'name').to_s,
          phase: resource.dig('status', 'phase') || 'Pending',
          generation: Integer(resource.dig('metadata', 'generation') || 0),
          observed_generation: Integer(resource.dig('status', 'observedGeneration') || 0),
          drift_check_healthy: resource.dig('status', 'lastDriftCheckError').to_s.empty?,
          certificate_expiry_timestamp_seconds: timestamp_seconds(
            resource.dig('status', 'certificateExpiryTimestamp')
          ),
          deleting: !resource.dig('metadata', 'deletionTimestamp').nil?
        }
      end
      update { @releases = observed.sort_by { |release| [release.fetch(:namespace), release.fetch(:name)] } }
    end

    def cycle_succeeded
      update do
        @successful_cycles += 1
        @last_success_at = @clock.call.utc
      end
    end

    def cycle_failed
      update do
        @failed_cycles += 1
        @role = :unknown
        @releases = []
      end
    end

    def snapshot
      @mutex.synchronize do
        {
          running: @running,
          role: @role,
          successful_cycles: @successful_cycles,
          failed_cycles: @failed_cycles,
          last_success_at: @last_success_at,
          releases: Marshal.load(Marshal.dump(@releases)),
          observed_at: @clock.call.utc
        }
      end
    end

    private

    def timestamp_seconds(value)
      return nil if value.to_s.empty?

      Time.iso8601(value).to_f
    rescue ArgumentError, TypeError
      nil
    end

    def update(&block)
      @mutex.synchronize(&block)
    end
  end
end
