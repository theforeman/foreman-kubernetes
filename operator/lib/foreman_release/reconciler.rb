# frozen_string_literal: true

require_relative 'state_machine'
require 'digest'
require 'time'

module ForemanRelease
  Observation = Struct.new(:state, :message, :details, keyword_init: true)

  class Reconciler
    ACTIVE_PHASES = %w[CheckingDependencies Migrating RollingApplication RollingProxy].freeze
    LEASED_PHASES = %w[CheckingDependencies Migrating RollingApplication VerifyingApplication RollingProxy Verifying].freeze
    PHASE_TIMEOUT_KEYS = {
      'Preflight' => 'preflightSeconds',
      'AcquiringLock' => 'leaseSeconds',
      'CheckingDependencies' => 'preflightSeconds',
      'Migrating' => 'migrationSeconds',
      'RollingApplication' => 'applicationRolloutSeconds',
      'VerifyingApplication' => 'verificationSeconds',
      'RollingProxy' => 'proxyRolloutSeconds',
      'Verifying' => 'verificationSeconds'
    }.freeze
    DEFAULT_TIMEOUTS = {
      'preflightSeconds' => 300,
      'leaseSeconds' => 900,
      'migrationSeconds' => 3600,
      'applicationRolloutSeconds' => 1800,
      'verificationSeconds' => 600,
      'proxyRolloutSeconds' => 900
    }.freeze
    DEFAULT_DRIFT_CHECK_SECONDS = 60
    PHASE_HANDLERS = {
      'Preflight' => [:validate, 'ValidationSucceeded', 'ValidationFailed'],
      'AcquiringLock' => [:acquire_lease, 'LeaseAcquired', 'LeaseFailed'],
      'CheckingDependencies' => [:ensure_dependencies, 'DependencyPreflightSucceeded', 'DependencyPreflightFailed'],
      'Migrating' => [:ensure_migrations, 'MigrationsSucceeded', 'MigrationsFailed'],
      'RollingApplication' => [:ensure_application, 'ApplicationAvailable', 'ApplicationFailed'],
      'VerifyingApplication' => [:ensure_application_smoke, 'ApplicationSmokeSucceeded', 'ApplicationSmokeFailed'],
      'RollingProxy' => [:ensure_proxy, 'ExecutionProxyAvailable', 'ExecutionProxyFailed'],
      'Verifying' => [:ensure_final_smoke, 'FinalSmokeSucceeded', 'FinalSmokeFailed']
    }.freeze

    def initialize(state_machine:, adapter:, status_writer:, clock: -> { Time.now.utc.iso8601 })
      @state_machine = state_machine
      @adapter = adapter
      @status_writer = status_writer
      @clock = clock
    end

    def reconcile(resource)
      spec = resource.fetch('spec')
      status = resource.fetch('status', {})
      phase = status.fetch('phase', 'Pending')

      if start_required?(resource, phase)
        return persist_start(resource) unless spec.fetch('paused', false)

        return persist_pause(resource, status)
      end

      if phase == 'Ready' || phase == 'Blocked'
        return persist_pause(resource, status) if spec.fetch('paused', false)
        return persist_resume(resource, status) if paused?(status)
        return persist_observation(resource, status) if status['observedGeneration'] != resource.dig('metadata', 'generation')
        return prune_operation_history(resource, status) if phase == 'Ready' && history_cleanup_required?(resource, status)
        return reconcile_ready_drift(resource, status) if phase == 'Ready' && drift_check_due?(resource, status)

        return :idle
      end

      handler, success_event, failure_event = PHASE_HANDLERS.fetch(phase)
      if LEASED_PHASES.include?(phase)
        renewal = observe(:renew_lease, resource, status.fetch('operation', {}))
        if renewal.state == :failed
          transition(resource, status, failure_event, renewal)
          @adapter.release_lease(resource, status.fetch('operation', {}))
          return :blocked
        end
        return :requeue unless renewal.state == :succeeded
      end
      if spec.fetch('paused', false) && !ACTIVE_PHASES.include?(phase)
        return persist_pause(resource, status)
      end
      timeout = timeout_observation(spec, status, phase)
      if timeout
        transition(resource, status, failure_event, timeout)
        @adapter.release_lease(resource, status.fetch('operation', {})) if LEASED_PHASES.include?(phase)
        return :blocked
      end
      observation = observe(handler, resource, status.fetch('operation', {}))

      if observation.state == :pending || observation.state == :busy
        if phase == 'AcquiringLock' && observation.state == :busy
          transition(resource, status, 'LeaseBusy', observation)
          return :requeue
        end

        persist_checkpoint(resource, status, observation) if checkpoint_required?(status, observation)

        return :requeue
      end

      if observation.state == :failed
        transition(resource, status, failure_event, observation)
        @adapter.release_lease(resource, status.fetch('operation', {}))
        return :blocked
      end

      unless observation.state == :succeeded
        raise ArgumentError, "#{handler} returned unsupported state #{observation.state.inspect}"
      end

      return persist_pause(resource, status) if spec.fetch('paused', false)

      result = transition(resource, status, success_event, observation)
      if result.status == 'Ready'
        @adapter.release_lease(resource, result.operation)
        :ready
      else
        :requeue
      end
    end

    def quiesce(resource)
      status = resource.fetch('status', {})
      phase = status.fetch('phase', 'Pending')
      return :safe if phase == 'Pending'

      operation = status.fetch('operation', {})
      if %w[Ready Blocked].include?(phase)
        return operation['id'] ? release_for_deletion(resource, operation) : :safe
      end

      if paused?(status)
        return release_for_deletion(resource, operation) if LEASED_PHASES.include?(phase) && operation['id']

        return :safe
      end

      paused_resource = resource.merge('spec' => resource.fetch('spec').merge('paused' => true))
      reconcile(paused_resource)
      :requeue
    end

    private

    TransitionResult = Struct.new(:status, :operation, keyword_init: true)

    def release_for_deletion(resource, operation)
      ownership = observe(:renew_lease, resource, operation)
      return :requeue unless ownership.state == :succeeded

      @adapter.release_lease(resource, operation) ? :safe : :requeue
    end

    def start_required?(resource, phase)
      spec = resource.fetch('spec')
      status = resource.fetch('status', {})
      case phase
      when 'Pending'
        true
      when 'Ready'
        status['currentSet'] != spec.fetch('compatibilitySet') ||
          status.fetch('observedReconcileToken', '') != spec.fetch('reconcileToken', '').to_s
      when 'Blocked'
        @state_machine.retry_allowed?(status, spec.fetch('retryToken', ''))
      else
        false
      end
    end

    def persist_start(resource, event: nil, operation_type: 'Release', details: {})
      status = resource.fetch('status', {})
      phase = status.fetch('phase', 'Pending')
      event ||= case phase
                when 'Pending' then 'Reconcile'
                when 'Ready'
                  if status['currentSet'] != resource.dig('spec', 'compatibilitySet')
                    'DesiredSetChanged'
                  else
                    'ReconcileTokenChanged'
                  end
                when 'Blocked' then 'RetryTokenChanged'
                end
      sequence = Integer(status['operationSequence'] || status.dig('operation', 'sequence') || 0) + 1
      operation_id = operation_id(resource, sequence)
      decision = @state_machine.transition(
        status: status,
        event: event,
        generation: resource.dig('metadata', 'generation'),
        desired_set: resource.dig('spec', 'compatibilitySet'),
        retry_token: resource.dig('spec', 'retryToken').to_s,
        reconcile_token: resource.dig('spec', 'reconcileToken').to_s,
        operation_id: operation_id,
        now: @clock.call,
        details: details.merge('type' => operation_type, 'sequence' => sequence)
      )
      decision.status['operationSequence'] = sequence
      @status_writer.call(resource, decision.status)
      :requeue
    end

    def operation_id(resource, sequence)
      owner = Digest::SHA256.hexdigest(resource.dig('metadata', 'uid').to_s)[0, 16]
      "#{owner}-g#{Integer(resource.dig('metadata', 'generation'))}-o#{sequence}"
    end

    def persist_pause(resource, status)
      paused_status = @state_machine.pause(
        status: status,
        generation: resource.dig('metadata', 'generation'),
        now: @clock.call
      )
      @status_writer.call(resource, paused_status)
      :paused
    end

    def persist_resume(resource, status)
      resumed_status = @state_machine.resume(
        status: status,
        generation: resource.dig('metadata', 'generation'),
        now: @clock.call
      )
      @status_writer.call(resource, resumed_status)
      :idle
    end

    def persist_observation(resource, status)
      observed_status = @state_machine.observe(
        status: status,
        generation: resource.dig('metadata', 'generation')
      )
      @status_writer.call(resource, observed_status)
      :idle
    end

    def persist_checkpoint(resource, status, observation)
      checkpoint = @state_machine.checkpoint(
        status: status,
        generation: resource.dig('metadata', 'generation'),
        now: @clock.call,
        message: observation.message || 'release progress observed',
        details: observation.details
      )
      @status_writer.call(resource, checkpoint)
    end

    def checkpoint_required?(status, observation)
      details = observation.details || {}
      operation = status.fetch('operation', {})
      details.any? { |key, value| operation[key.to_s] != value }
    end

    def paused?(status)
      Array(status['conditions']).any? do |condition|
        condition['type'] == 'Paused' && condition['status'] == 'True'
      end
    end

    def history_cleanup_required?(resource, status)
      operation_id = status.dig('operation', 'id')
      return false unless operation_id

      limit = Integer(resource.dig('spec', 'operationHistoryLimit') || 3)
      status['historyPrunedThroughOperation'] != operation_id ||
        status['historyPrunedLimit'] != limit
    end

    def prune_operation_history(resource, status)
      operation = status.fetch('operation', {})
      observation = observe(:prune_operation_history, resource, operation)
      return :cleanup_pending unless observation.state == :succeeded

      cleaned_status = Marshal.load(Marshal.dump(status))
      cleaned_status['historyPrunedThroughOperation'] = operation.fetch('id')
      cleaned_status['historyPrunedLimit'] = Integer(resource.dig('spec', 'operationHistoryLimit') || 3)
      @status_writer.call(resource, cleaned_status)
      :idle
    end

    def drift_check_due?(resource, status)
      seconds = Integer(resource.dig('spec', 'driftCheckSeconds') || DEFAULT_DRIFT_CHECK_SECONDS)
      checked_at = status['lastDriftCheckAt']
      return true unless checked_at

      Time.iso8601(@clock.call) - Time.iso8601(checked_at) >= seconds
    rescue ArgumentError, TypeError
      true
    end

    def reconcile_ready_drift(resource, status)
      observation = observe(:audit_ready, resource, status.fetch('operation', {}))
      case observation.state
      when :succeeded
        audited = Marshal.load(Marshal.dump(status))
        audited['lastDriftCheckAt'] = @clock.call
        audited['lastDriftCheckMessage'] = observation.message || 'declared release resources are present'
        audited.delete('lastDriftCheckError')
        certificate_expiry = (observation.details || {})['certificateExpiryTimestamp'] ||
          (observation.details || {})[:certificateExpiryTimestamp]
        if certificate_expiry
          audited['certificateExpiryTimestamp'] = certificate_expiry
        else
          audited.delete('certificateExpiryTimestamp')
        end
        @status_writer.call(resource, audited)
        :idle
      when :drifted
        persist_start(
          resource,
          event: 'DriftDetected',
          operation_type: 'Repair',
          details: observation.details || {}
        )
      when :unsafe_drift
        transition(resource, status, 'UnsafeDriftDetected', observation)
        :blocked
      when :failed
        audited = Marshal.load(Marshal.dump(status))
        audited['lastDriftCheckAt'] = @clock.call
        audited['lastDriftCheckMessage'] = 'Ready drift audit could not be completed'
        audited['lastDriftCheckError'] = observation.message || 'unknown drift audit failure'
        @status_writer.call(resource, audited)
        :audit_failed
      else
        raise ArgumentError, "audit_ready returned unsupported state #{observation.state.inspect}"
      end
    end

    def observe(handler, resource, operation)
      value = @adapter.public_send(handler, resource, operation)
      return value if value.is_a?(Observation)

      Observation.new(state: value, details: {})
    rescue StandardError => error
      Observation.new(state: :failed, message: error.message, details: {})
    end

    def timeout_observation(spec, status, phase)
      key = PHASE_TIMEOUT_KEYS.fetch(phase)
      seconds = Integer(spec.fetch('timeouts', {}).fetch(key, DEFAULT_TIMEOUTS.fetch(key)))
      started_at = status['phaseStartedAt'] || status.dig('operation', 'startedAt')
      return unless started_at

      elapsed = Time.iso8601(@clock.call) - Time.iso8601(started_at)
      return if elapsed < seconds

      Observation.new(
        state: :failed,
        message: "release phase #{phase} exceeded its #{seconds}-second timeout",
        details: {'timedOutPhase' => phase, 'timeoutSeconds' => seconds}
      )
    rescue ArgumentError, TypeError => error
      Observation.new(state: :failed, message: "invalid timeout state for #{phase}: #{error.message}", details: {})
    end

    def transition(resource, status, event, observation)
      decision = @state_machine.transition(
        status: status,
        event: event,
        generation: resource.dig('metadata', 'generation'),
        desired_set: resource.dig('spec', 'compatibilitySet'),
        retry_token: resource.dig('spec', 'retryToken').to_s,
        reconcile_token: resource.dig('spec', 'reconcileToken').to_s,
        now: @clock.call,
        message: observation.message,
        details: observation.details || {}
      )
      @status_writer.call(resource, decision.status)
      TransitionResult.new(status: decision.status.fetch('phase'), operation: decision.status.fetch('operation', {}))
    end

  end
end
