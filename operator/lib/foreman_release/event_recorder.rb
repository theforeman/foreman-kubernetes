# frozen_string_literal: true

require 'json'
require 'time'

module ForemanRelease
  class EventRecorder
    REPORTING_CONTROLLER = 'platform.theforeman.org/release-controller'
    CONDITION_PRIORITY = %w[Paused Degraded Available Progressing].freeze

    def initialize(kubernetes_client:, reporting_instance:, clock: -> { Time.now.utc }, output: $stdout)
      raise ArgumentError, 'reporting instance is required' if reporting_instance.to_s.empty?

      @kubernetes_client = kubernetes_client
      @reporting_instance = reporting_instance
      @clock = clock
      @output = output
    end

    def record(resource, previous_status, current_status)
      description = event_description(previous_status || {}, current_status || {})
      return unless description

      metadata = resource.fetch('metadata')
      @kubernetes_client.create(
        metadata.fetch('namespace'),
        {
          'apiVersion' => 'events.k8s.io/v1',
          'kind' => 'Event',
          'metadata' => {
            'generateName' => "#{metadata.fetch('name')}-release-",
            'namespace' => metadata.fetch('namespace')
          },
          'eventTime' => @clock.call.utc.iso8601(6),
          'action' => 'Reconcile',
          'reason' => description.fetch(:reason),
          'note' => truncate_note(description.fetch(:note)),
          'type' => description.fetch(:type),
          'regarding' => {
            'apiVersion' => resource.fetch('apiVersion'),
            'kind' => resource.fetch('kind'),
            'namespace' => metadata.fetch('namespace'),
            'name' => metadata.fetch('name'),
            'uid' => metadata.fetch('uid'),
            'resourceVersion' => metadata.fetch('resourceVersion')
          },
          'reportingController' => REPORTING_CONTROLLER,
          'reportingInstance' => @reporting_instance
        }
      )
    rescue StandardError => error
      log_failure(resource, error)
      nil
    end

    private

    def event_description(previous_status, current_status)
      previous_phase = previous_status['phase'] || 'Pending'
      current_phase = current_status['phase'] || 'Pending'
      if previous_phase != current_phase
        condition = relevant_condition(current_status)
        return {
          reason: "Release#{current_phase}",
          note: condition&.fetch('message', nil) || "ForemanRelease entered #{current_phase}",
          type: current_phase == 'Blocked' ? 'Warning' : 'Normal'
        }
      end

      audit = drift_audit_description(previous_status, current_status)
      return audit if audit

      condition = changed_condition(previous_status, current_status)
      return unless condition

      {
        reason: condition.fetch('reason', 'ReleaseConditionChanged'),
        note: "#{condition.fetch('type')}=#{condition.fetch('status')}: #{condition.fetch('message', '')}",
        type: condition.fetch('type') == 'Degraded' && condition.fetch('status') == 'True' ? 'Warning' : 'Normal'
      }
    end

    def drift_audit_description(previous_status, current_status)
      previous_error = previous_status['lastDriftCheckError'].to_s
      current_error = current_status['lastDriftCheckError'].to_s
      return if previous_error == current_error

      if current_error.empty?
        {
          reason: 'ReadyAuditRecovered',
          note: current_status['lastDriftCheckMessage'] || 'Ready release audit recovered',
          type: 'Normal'
        }
      else
        {
          reason: 'ReadyAuditFailed',
          note: current_error,
          type: 'Warning'
        }
      end
    end

    def relevant_condition(status)
      conditions = Array(status['conditions'])
      conditions.find { |condition| condition['type'] == 'Degraded' && condition['status'] == 'True' } ||
        conditions.find { |condition| condition['type'] == 'Progressing' && condition['status'] == 'True' } ||
        conditions.find { |condition| condition['type'] == 'Available' && condition['status'] == 'True' }
    end

    def changed_condition(previous_status, current_status)
      previous = Array(previous_status['conditions']).to_h { |condition| [condition.fetch('type'), signature(condition)] }
      changed = Array(current_status['conditions']).select do |condition|
        previous[condition.fetch('type')] != signature(condition)
      end
      changed.min_by { |condition| CONDITION_PRIORITY.index(condition.fetch('type')) || CONDITION_PRIORITY.length }
    end

    def signature(condition)
      condition.slice('status', 'reason', 'message')
    end

    def truncate_note(note)
      note.to_s.byteslice(0, 1024).to_s.scrub
    end

    def log_failure(resource, error)
      @output.puts(JSON.generate(
        level: 'warning',
        event: 'kubernetes_event_publish_failed',
        release: resource.dig('metadata', 'name'),
        error: error.class.name,
        message: error.message,
        time: @clock.call.utc.iso8601
      ))
      @output.flush
    rescue StandardError
      nil
    end
  end
end
