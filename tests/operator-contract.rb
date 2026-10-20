#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'set'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
crd = YAML.safe_load(
  (root / 'operator/crd/platform.theforeman.org_foremanreleases.yaml').read,
  aliases: true
)
state_machine = JSON.parse((root / 'operator/release-state-machine.json').read)

raise 'operator CRD must be namespaced' unless crd.dig('spec', 'scope') == 'Namespaced'
raise 'unexpected operator API group' unless crd.dig('spec', 'group') == 'platform.theforeman.org'

versions = crd.fetch('spec').fetch('versions')
alpha = versions.find { |candidate| candidate.fetch('name') == 'v1alpha1' }
version = versions.find { |candidate| candidate.fetch('name') == 'v1beta1' }
raise 'v1alpha1 must remain served for compatible reads and writes' unless alpha&.fetch('served') && !alpha.fetch('storage')
raise 'v1beta1 must be served and stored' unless version&.fetch('served') && version.fetch('storage')
raise 'operator API versions require schema-equivalent None conversion' unless
  crd.dig('spec', 'conversion', 'strategy') == 'None' && alpha.fetch('schema') == version.fetch('schema')
raise 'operator CRD must expose the status subresource' unless version.fetch('subresources').key?('status')

root_schema = version.dig('schema', 'openAPIV3Schema')
spec_schema = root_schema.dig('properties', 'spec')
status_schema = root_schema.dig('properties', 'status')
required_spec = spec_schema.fetch('required')
%w[compatibilitySet application executionProxy].each do |property|
  raise "operator spec does not require #{property}" unless required_spec.include?(property)
end

%w[application executionProxy].each do |release|
  release_schema = spec_schema.dig('properties', release)
  raise "#{release} must reference a values Secret" unless release_schema.fetch('required') == ['valuesSecretRef']
  secret_reference = release_schema.dig('properties', 'valuesSecretRef')
  raise "#{release} Secret reference must require name and key" unless secret_reference.fetch('required').sort == %w[key name]
  raise "#{release} Secret reference must remain in the CR namespace" if secret_reference.fetch('properties').key?('namespace')
  raise "#{release} does not require explicit existing-release adoption" unless release_schema.dig('properties', 'adoptExisting', 'default') == false
end

after_migration = spec_schema.dig('properties', 'failurePolicy', 'properties', 'afterMigration')
raise 'post-migration failure policy must only permit Halt' unless after_migration.fetch('enum') == ['Halt']
raise 'operator spec must expose an explicit retry token' unless spec_schema.dig('properties', 'retryToken', 'type') == 'string'
raise 'operator spec must expose an explicit reconcile token' unless spec_schema.dig('properties', 'reconcileToken', 'type') == 'string'
drift_interval = spec_schema.dig('properties', 'driftCheckSeconds')
unless drift_interval.fetch('default') == 60 && drift_interval.fetch('minimum') == 30
  raise 'operator spec must bound Ready drift checks'
end
history_limit = spec_schema.dig('properties', 'operationHistoryLimit')
unless history_limit.fetch('default') == 3 && history_limit.fetch('minimum') == 1 && history_limit.fetch('maximum') == 20
  raise 'operator spec must bound retained operation history'
end
unless status_schema.dig('properties', 'observedReconcileToken', 'type') == 'string'
  raise 'operator status does not retain the applied reconcile token'
end
unless status_schema.dig('properties', 'historyPrunedThroughOperation', 'type') == 'string' &&
       status_schema.dig('properties', 'historyPrunedLimit', 'minimum') == 1
  raise 'operator status does not checkpoint Job history cleanup'
end
timeouts = spec_schema.dig('properties', 'timeouts')
expected_timeouts = %w[preflightSeconds leaseSeconds migrationSeconds applicationRolloutSeconds verificationSeconds proxyRolloutSeconds]
raise 'operator spec does not define every phase timeout' unless timeouts.fetch('default').keys.sort == expected_timeouts.sort
expected_timeouts.each do |timeout|
  schema = timeouts.dig('properties', timeout)
  raise "#{timeout} has no positive default" unless schema.fetch('default').positive?
end
raise 'status does not retain a phase start time' unless status_schema.dig('properties', 'phaseStartedAt', 'format') == 'date-time'

conditions = status_schema.dig('properties', 'conditions')
raise 'conditions must use list-map semantics' unless conditions.fetch('x-kubernetes-list-type') == 'map'
raise 'conditions must be keyed by type' unless conditions.fetch('x-kubernetes-list-map-keys') == ['type']
condition_required = conditions.dig('items', 'required')
raise 'conditions must identify their observed generation' unless condition_required.include?('observedGeneration')

operation = status_schema.dig('properties', 'operation', 'properties')
unless operation.dig('dependencyPreflightJobs', 'type') == 'array' &&
       operation.dig('dependencyPreflightJobs', 'items', 'type') == 'string'
  raise 'operation status does not retain dependency preflight Jobs'
end
unless operation.dig('sourceSets', 'type') == 'array' && operation.dig('sourceSets', 'uniqueItems') == true
  raise 'operation status does not retain validated source compatibility sets'
end
%w[
  applicationValuesSha256 executionProxyValuesSha256
  applicationProfileSha256 executionProxyProfileSha256
  applicationSecretsSha256 executionProxySecretsSha256
].each do |digest|
  raise "operation status does not retain #{digest}" unless operation.dig(digest, 'pattern') == '^[0-9a-f]{64}$'
end
raise 'operation status does not retain timeout evidence' unless operation.dig('timeoutSeconds', 'minimum') == 1 &&
                                                           operation.dig('timedOutPhase', 'type') == 'string'
%w[applicationSubmittedRevision executionProxySubmittedRevision].each do |revision|
  raise "operation status does not retain #{revision}" unless operation.dig(revision, 'minimum') == 1
end
unless operation.dig('type', 'enum') == %w[Release Repair] && operation.dig('sequence', 'minimum') == 1
  raise 'operation status does not distinguish uniquely sequenced repairs'
end
unless status_schema.dig('properties', 'lastDriftCheckAt', 'format') == 'date-time' &&
       status_schema.dig('properties', 'lastDriftCheckError', 'type') == 'string' &&
       status_schema.dig('properties', 'operationSequence', 'minimum') == 0
  raise 'operator status does not checkpoint drift checks and operation sequencing'
end

phases = status_schema.dig('properties', 'phase', 'enum')
raise 'unsupported release state-machine schema' unless state_machine.fetch('schemaVersion') == 1
raise 'state-machine initial phase is not in the CRD' unless phases.include?(state_machine.fetch('initialPhase'))
raise 'state-machine quiescent phase is not in the CRD' unless (state_machine.fetch('quiescentPhases') - phases).empty?

transitions = state_machine.fetch('transitions')
keys = transitions.map { |transition| [transition.fetch('from'), transition.fetch('event')] }
raise 'state-machine transitions must be unique by phase and event' unless keys.uniq == keys
transitions.each do |transition|
  raise "unknown source phase #{transition.fetch('from')}" unless phases.include?(transition.fetch('from'))
  raise "unknown destination phase #{transition.fetch('to')}" unless phases.include?(transition.fetch('to'))
  if transition.fetch('action').match?(/rollback|restore/i)
    raise "unsafe automatic recovery action: #{transition.fetch('action')}"
  end
end

transition_by_key = transitions.to_h do |transition|
  [[transition.fetch('from'), transition.fetch('event')], transition]
end
happy_path = [
  ['Pending', 'Reconcile', 'Preflight'],
  ['Preflight', 'ValidationSucceeded', 'AcquiringLock'],
  ['AcquiringLock', 'LeaseAcquired', 'CheckingDependencies'],
  ['CheckingDependencies', 'DependencyPreflightSucceeded', 'Migrating'],
  ['Migrating', 'MigrationsSucceeded', 'RollingApplication'],
  ['RollingApplication', 'ApplicationAvailable', 'VerifyingApplication'],
  ['VerifyingApplication', 'ApplicationSmokeSucceeded', 'RollingProxy'],
  ['RollingProxy', 'ExecutionProxyAvailable', 'Verifying'],
  ['Verifying', 'FinalSmokeSucceeded', 'Ready']
]
happy_path.each do |from, event, expected_destination|
  transition = transition_by_key.fetch([from, event])
  raise "#{from}/#{event} bypasses #{expected_destination}" unless transition.fetch('to') == expected_destination
end
reconcile_transition = transition_by_key.fetch(['Ready', 'ReconcileTokenChanged'])
unless reconcile_transition.fetch('to') == 'Preflight' && reconcile_transition.fetch('action') == 'ValidateReleaseSet'
  raise 'a reconcile token change must start a fully validated release'
end
repair_transition = transition_by_key.fetch(['Ready', 'DriftDetected'])
unless repair_transition.fetch('to') == 'Preflight' && repair_transition.fetch('action') == 'ValidateRepair'
  raise 'detected drift must start a fully validated repair operation'
end
unsafe_drift_transition = transition_by_key.fetch(['Ready', 'UnsafeDriftDetected'])
unless unsafe_drift_transition.fetch('to') == 'Blocked' && unsafe_drift_transition.fetch('action') == 'RecordBlocked'
  raise 'missing stateful storage must block automatic drift repair'
end

lease_wait = transition_by_key.fetch(['AcquiringLock', 'LeaseBusy'])
unless lease_wait.fetch('to') == 'AcquiringLock' && lease_wait.fetch('action') == 'Requeue'
  raise 'a busy release Lease must wait without starting migrations or blocking the release'
end

failure_phases = %w[Preflight AcquiringLock CheckingDependencies Migrating RollingApplication VerifyingApplication RollingProxy Verifying]
failure_phases.each do |phase|
  blocked_transitions = transitions.select do |transition|
    transition.fetch('from') == phase && transition.fetch('to') == 'Blocked'
  end
  unless blocked_transitions.length == 1 && blocked_transitions.first.fetch('action') == 'RecordBlocked'
    raise "#{phase} must have exactly one explicit transition to Blocked"
  end
end

blocked_exits = transitions.select { |transition| transition.fetch('from') == 'Blocked' }
expected_retry = {
  'from' => 'Blocked',
  'event' => 'RetryTokenChanged',
  'action' => 'ValidateReleaseSet',
  'to' => 'Preflight'
}
raise 'Blocked releases must require an explicit retry token change' unless blocked_exits == [expected_retry]

reachable = Set[state_machine.fetch('initialPhase')]
loop do
  previous_size = reachable.size
  transitions.each do |transition|
    reachable << transition.fetch('to') if reachable.include?(transition.fetch('from'))
  end
  break if reachable.size == previous_size
end
raise "unreachable operator phases: #{(phases - reachable.to_a).join(', ')}" unless reachable.size == phases.size

puts 'ForemanRelease CRD and release state-machine contract passed.'
