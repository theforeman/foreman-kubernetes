# frozen_string_literal: true

require 'json'

module ForemanRelease
  class InvalidTransition < StandardError; end

  Decision = Struct.new(:action, :status, keyword_init: true)

  class StateMachine
    CONDITION_TYPES = %w[Available Progressing Degraded Paused].freeze

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def initialize(definition)
      @initial_phase = definition.fetch('initialPhase')
      @quiescent_phases = definition.fetch('quiescentPhases')
      @transitions = definition.fetch('transitions').to_h do |transition|
        [[transition.fetch('from'), transition.fetch('event')], transition]
      end
    end

    def transition(status:, event:, generation:, desired_set:, retry_token:, now:, reconcile_token: '', operation_id: nil,
                   message: nil, details: {})
      current_status = deep_copy(status || {})
      phase = current_status.fetch('phase', @initial_phase)
      transition = @transitions[[phase, event]]
      raise InvalidTransition, "event #{event} is invalid in phase #{phase}" unless transition

      destination = transition.fetch('to')
      next_status = current_status.merge(
        'observedGeneration' => generation,
        'phase' => destination,
        'targetSet' => desired_set
      )
      next_status['phaseStartedAt'] = if destination == phase
                                        current_status['phaseStartedAt'] || now
                                      else
                                        now
                                      end

      if destination == 'Preflight'
        raise ArgumentError, 'operation_id is required when starting an operation' if operation_id.to_s.empty?

        next_status['observedRetryToken'] = retry_token.to_s
        next_status['observedReconcileToken'] = reconcile_token.to_s
        next_status['operation'] = {
          'id' => operation_id,
          'startedAt' => now,
          'dependencyPreflightJobs' => [],
          'migrationJobs' => []
        }
      end

      operation = next_status['operation']
      operation.merge!(stringify_keys(details)) if operation && !details.empty?

      if destination == 'Ready'
        next_status['currentSet'] = desired_set
        next_status['lastSuccessfulSet'] = desired_set
      end

      reason = event
      condition_message = message || "release phase is #{destination}"
      next_status['conditions'] = reconcile_conditions(
        current_status['conditions'], destination, generation, now, reason, condition_message
      )

      Decision.new(action: transition.fetch('action'), status: next_status)
    end

    def pause(status:, generation:, now:, message: 'release reconciliation is paused at a safe boundary')
      next_status = deep_copy(status || {})
      next_status['phase'] ||= @initial_phase
      next_status['observedGeneration'] = generation
      next_status['conditions'] = upsert_condition(
        next_status['conditions'],
        condition('Paused', true, 'ReconciliationPaused', message, generation, now)
      )
      next_status
    end

    def resume(status:, generation:, now:, message: 'release reconciliation is not paused')
      next_status = deep_copy(status || {})
      next_status['phase'] ||= @initial_phase
      next_status['observedGeneration'] = generation
      next_status['phaseStartedAt'] = now
      next_status['conditions'] = upsert_condition(
        next_status['conditions'],
        condition('Paused', false, 'ReconciliationResumed', message, generation, now)
      )
      next_status
    end

    def retry_allowed?(status, retry_token)
      current_status = status || {}
      current_status.fetch('phase', @initial_phase) == 'Blocked' &&
        current_status.fetch('observedRetryToken', '') != retry_token.to_s
    end

    def observe(status:, generation:)
      next_status = deep_copy(status || {})
      next_status['phase'] ||= @initial_phase
      next_status['observedGeneration'] = generation
      Array(next_status['conditions']).each { |condition| condition['observedGeneration'] = generation }
      next_status
    end

    def checkpoint(status:, generation:, now:, message:, details:)
      next_status = deep_copy(status || {})
      phase = next_status.fetch('phase', @initial_phase)
      operation = next_status['operation']
      raise ArgumentError, 'an active operation is required for a progress checkpoint' unless operation

      next_status['observedGeneration'] = generation
      operation.merge!(stringify_keys(details))
      next_status['conditions'] = reconcile_conditions(
        next_status['conditions'], phase, generation, now, 'ProgressObserved', message
      )
      next_status
    end

    def quiescent?(status)
      @quiescent_phases.include?((status || {}).fetch('phase', @initial_phase))
    end

    private

    def reconcile_conditions(existing, phase, generation, now, reason, message)
      states = {
        'Available' => phase == 'Ready',
        'Progressing' => !@quiescent_phases.include?(phase),
        'Degraded' => phase == 'Blocked',
        'Paused' => false
      }

      CONDITION_TYPES.reduce(Array(existing)) do |conditions, type|
        upsert_condition(
          conditions,
          condition(type, states.fetch(type), reason, message, generation, now)
        )
      end
    end

    def condition(type, state, reason, message, generation, now)
      {
        'type' => type,
        'status' => state ? 'True' : 'False',
        'reason' => reason,
        'message' => message,
        'observedGeneration' => generation,
        'lastTransitionTime' => now
      }
    end

    def upsert_condition(existing, replacement)
      conditions = deep_copy(Array(existing))
      previous = conditions.find { |candidate| candidate['type'] == replacement.fetch('type') }
      if previous && previous.slice('status', 'reason', 'message') == replacement.slice('status', 'reason', 'message')
        replacement['lastTransitionTime'] = previous.fetch('lastTransitionTime')
      end
      conditions.reject! { |candidate| candidate['type'] == replacement.fetch('type') }
      conditions << replacement
      conditions.sort_by { |candidate| CONDITION_TYPES.index(candidate.fetch('type')) || CONDITION_TYPES.length }
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
