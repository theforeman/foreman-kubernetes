#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/state_machine').to_s

machine = ForemanRelease::StateMachine.load(root.join('operator/release-state-machine.json'))
now = '2026-09-24T12:00:00Z'
status = {}

decision = machine.transition(
  status: status,
  event: 'Reconcile',
  generation: 1,
  desired_set: 'candidate-1',
  retry_token: '',
  reconcile_token: 'configuration-1',
  operation_id: 'uid-1-1',
  now: now
)
raise 'pending release did not enter preflight' unless decision.status['phase'] == 'Preflight'
raise 'preflight did not start a durable operation' unless decision.status.dig('operation', 'id') == 'uid-1-1'
raise 'preflight did not record the retry token' unless decision.status['observedRetryToken'] == ''
unless decision.status['observedReconcileToken'] == 'configuration-1'
  raise 'preflight did not record the reconcile token'
end
raise 'preflight did not record its phase start' unless decision.status['phaseStartedAt'] == now
raise 'unexpected first action' unless decision.action == 'ValidateReleaseSet'
status = decision.status

busy_started_at = '2026-09-24T11:59:00Z'
busy = machine.transition(
  status: {'phase' => 'AcquiringLock', 'phaseStartedAt' => busy_started_at},
  event: 'LeaseBusy',
  generation: 4,
  desired_set: 'candidate-2',
  retry_token: 'attempt-2',
  now: now
)
raise 'busy Lease did not preserve its timeout budget' unless busy.status['phaseStartedAt'] == busy_started_at

status = machine.checkpoint(
  status: status,
  generation: 1,
  now: now,
  message: 'application release submitted',
  details: {applicationSubmittedRevision: 2}
)
raise 'progress checkpoint changed the phase' unless status['phase'] == 'Preflight'
unless status.dig('operation', 'applicationSubmittedRevision') == 2
  raise 'progress checkpoint did not persist operation evidence'
end
progress = status['conditions'].find { |condition| condition['type'] == 'Progressing' }
raise 'progress checkpoint did not refresh the condition' unless progress['reason'] == 'ProgressObserved'

happy_path = [
  ['ValidationSucceeded', 'AcquiringLock', 'AcquireLease', {}],
  ['LeaseAcquired', 'CheckingDependencies', 'StartDependencyPreflight', {}],
  ['DependencyPreflightSucceeded', 'Migrating', 'StartMigrationJobs', {dependencyPreflightJobs: ['dependencies']}],
  ['MigrationsSucceeded', 'RollingApplication', 'RollApplication', {}],
  ['ApplicationAvailable', 'VerifyingApplication', 'RunApplicationSmokeTest', {applicationRevision: 2}],
  ['ApplicationSmokeSucceeded', 'RollingProxy', 'RollExecutionProxy', {}],
  ['ExecutionProxyAvailable', 'Verifying', 'RunFinalSmokeTest', {executionProxyRevision: 4}],
  ['FinalSmokeSucceeded', 'Ready', 'RecordReady', {}]
]

happy_path.each do |event, phase, action, details|
  decision = machine.transition(
    status: status,
    event: event,
    generation: 1,
    desired_set: 'candidate-1',
    retry_token: '',
    now: now,
    details: details
  )
  raise "#{event} entered #{decision.status['phase']} instead of #{phase}" unless decision.status['phase'] == phase
  raise "#{event} selected #{decision.action} instead of #{action}" unless decision.action == action
  status = decision.status
end

raise 'ready release did not record its current set' unless status['currentSet'] == 'candidate-1'
raise 'ready release did not record its last successful set' unless status['lastSuccessfulSet'] == 'candidate-1'
raise 'ready release is not quiescent' unless machine.quiescent?(status)
raise 'ready release is not Available' unless status['conditions'].find { |c| c['type'] == 'Available' }['status'] == 'True'
raise 'ready release is still Progressing' unless status['conditions'].find { |c| c['type'] == 'Progressing' }['status'] == 'False'

paused = machine.pause(status: status, generation: 2, now: now)
raise 'pause changed the completed phase' unless paused['phase'] == 'Ready'
raise 'pause did not set its condition' unless paused['conditions'].find { |c| c['type'] == 'Paused' }['status'] == 'True'
resumed = machine.resume(status: paused, generation: 3, now: now)
raise 'resume changed the completed phase' unless resumed['phase'] == 'Ready'
raise 'resume did not clear its condition' unless resumed['conditions'].find { |c| c['type'] == 'Paused' }['status'] == 'False'
raise 'resume did not restart the current phase timeout' unless resumed['phaseStartedAt'] == now
observed = machine.observe(status: resumed, generation: 4)
raise 'idle generation was not acknowledged' unless observed['observedGeneration'] == 4
unless observed['conditions'].all? { |condition| condition['observedGeneration'] == 4 }
  raise 'idle condition generations were not acknowledged'
end

reconciled = machine.transition(
  status: status,
  event: 'ReconcileTokenChanged',
  generation: 5,
  desired_set: 'candidate-1',
  retry_token: '',
  reconcile_token: 'configuration-2',
  operation_id: 'uid-1-5',
  now: now
).status
raise 'reconcile token did not start preflight' unless reconciled['phase'] == 'Preflight'
unless reconciled['observedReconcileToken'] == 'configuration-2'
  raise 'new release did not retain its reconcile token'
end
raise 'reconcile token reused the completed operation' unless reconciled.dig('operation', 'id') == 'uid-1-5'

blocked = machine.transition(
  status: {
    'phase' => 'Preflight',
    'observedRetryToken' => 'attempt-1',
    'operation' => {
      'id' => 'uid-2-1', 'startedAt' => now, 'dependencyPreflightJobs' => [], 'migrationJobs' => []
    }
  },
  event: 'ValidationFailed',
  generation: 2,
  desired_set: 'candidate-2',
  retry_token: 'attempt-1',
  now: now,
  message: 'values Secret is missing'
).status
raise 'failed release was not blocked' unless blocked['phase'] == 'Blocked'
raise 'blocked release is not degraded' unless blocked['conditions'].find { |c| c['type'] == 'Degraded' }['status'] == 'True'
raise 'same retry token unexpectedly permits retry' if machine.retry_allowed?(blocked, 'attempt-1')
raise 'changed retry token does not permit retry' unless machine.retry_allowed?(blocked, 'attempt-2')

retried = machine.transition(
  status: blocked,
  event: 'RetryTokenChanged',
  generation: 3,
  desired_set: 'candidate-2',
  retry_token: 'attempt-2',
  operation_id: 'uid-2-3',
  now: now
).status
raise 'retry did not replace the previous operation' unless retried.dig('operation', 'id') == 'uid-2-3'
raise 'retry did not record its token' unless retried['observedRetryToken'] == 'attempt-2'

raise 'busy Lease did not remain pending' unless busy.status['phase'] == 'AcquiringLock'
raise 'busy Lease did not request requeue' unless busy.action == 'Requeue'

begin
  machine.transition(
    status: {'phase' => 'Ready'},
    event: 'MigrationsSucceeded',
    generation: 5,
    desired_set: 'candidate-3',
    retry_token: '',
    now: now
  )
  raise 'invalid transition was accepted'
rescue ForemanRelease::InvalidTransition
  nil
end

begin
  machine.transition(
    status: {},
    event: 'Reconcile',
    generation: 1,
    desired_set: 'candidate-1',
    retry_token: '',
    now: now
  )
  raise 'operation without an ID was accepted'
rescue ArgumentError
  nil
end

begin
  machine.checkpoint(status: {'phase' => 'Preflight'}, generation: 1, now: now, message: 'invalid', details: {})
  raise 'progress checkpoint without an operation was accepted'
rescue ArgumentError
  nil
end

puts 'ForemanRelease executable state-machine behavior passed.'
