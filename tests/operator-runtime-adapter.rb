#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/runtime_adapter').to_s

class RecordingHelmRunner
  attr_reader :calls, :renders, :values_modes
  attr_accessor :existing_releases, :application_set, :execution_set

  def initialize
    @real = ForemanRelease::CommandRunner.new
    @calls = []
    @renders = {}
    @values_modes = []
    @existing_releases = []
    @application_set = 'nightly-candidate-2026-09-24'
    @execution_set = 'nightly-candidate-2026-09-24'
  end

  def run(*command, stdin_data: '')
    @calls << [command, stdin_data]
    if command.first == 'helm'
      command.each_index do |index|
        next unless command[index] == '--values'

        candidate = command[index + 1]
        @values_modes << (File.stat(candidate).mode & 0o777) if candidate.include?('foreman-release-values-')
      end
    end
    case command.first(2)
    when %w[helm upgrade]
      'submitted'
    when %w[helm status]
      JSON.generate('version' => command.include?('execution') ? 4 : 2)
    when %w[helm list]
      JSON.generate(@existing_releases.map { |name| {'name' => name} })
    when %w[helm get]
      release_name = command.fetch(3)
      if release_name == 'execution'
        JSON.generate('compatibilitySet' => @execution_set)
      else
        JSON.generate('platform' => {'compatibilitySet' => @application_set})
      end
    when %w[helm template]
      output = @real.run(*command, stdin_data: stdin_data)
      @renders[command.fetch(2)] = YAML.load_stream(output).compact
      output
    else
      @real.run(*command, stdin_data: stdin_data)
    end
  end
end

class RuntimeKubernetesClient
  attr_reader :created, :created_resources, :deleted
  attr_accessor :application_values, :execution_values, :releases_list

  def initialize(application_values:, execution_values:)
    @application_values = application_values
    @execution_values = execution_values
    @resources = Hash.new { |hash, key| hash[key] = [] }
    @created = []
    @created_resources = []
    @deleted = []
    @releases_list = []
  end

  def releases(_namespace)
    @releases_list
  end

  def secret_value(_namespace, name, _key)
    return @application_values if name == 'application-values'
    return @execution_values if name == 'execution-values'

    raise KeyError, "unknown Secret #{name}"
  end

  def resources(_namespace, type, labels: {})
    @resources[type].select do |resource|
      actual = resource.dig('metadata', 'labels') || {}
      labels.all? { |key, value| actual[key] == value }
    end
  end

  def create(_namespace, resource)
    copy = Marshal.load(Marshal.dump(resource))
    type = resource_type(copy.fetch('kind'))
    if @resources[type].any? { |item| item.dig('metadata', 'name') == copy.dig('metadata', 'name') }
      raise ForemanRelease::CommandError.new(['kubectl', 'create'], 'AlreadyExists', 1)
    end

    copy['metadata']['resourceVersion'] ||= (@created_resources.length + 1).to_s
    @resources[type] << copy
    @created_resources << copy
    @created << copy if type == 'jobs'
    copy
  end

  def replace(type_or_namespace, resources_or_resource)
    if resources_or_resource.is_a?(Array)
      @resources[type_or_namespace] = Marshal.load(Marshal.dump(resources_or_resource))
      return resources_or_resource
    end

    resource = Marshal.load(Marshal.dump(resources_or_resource))
    type = resource_type(resource.fetch('kind'))
    index = @resources[type].index { |item| item.dig('metadata', 'name') == resource.dig('metadata', 'name') }
    raise 'replaced resource does not exist' unless index

    resource['metadata']['resourceVersion'] = (Integer(resource.dig('metadata', 'resourceVersion')) + 1).to_s
    @resources[type][index] = resource
    resource
  end

  def resource(_namespace, type, name)
    plural = type.end_with?('s') ? type : "#{type}s"
    @resources[plural].find { |item| item.dig('metadata', 'name') == name } || raise('resource not found')
  end

  def delete(_namespace, type, name)
    plural = type.end_with?('s') ? type : "#{type}s"
    @resources[plural].reject! { |item| item.dig('metadata', 'name') == name }
    @deleted << [plural, name]
    true
  end

  private

  def resource_type(kind)
    {
      'ConfigMap' => 'configmaps',
      'Job' => 'jobs',
      'PersistentVolumeClaim' => 'persistentvolumeclaims',
      'ServiceAccount' => 'serviceaccounts'
    }.fetch(kind)
  end
end

class RuntimeLeaseManager
  attr_reader :calls

  def initialize
    @calls = []
  end

  def acquire(_resource, operation)
    @calls << [:acquire, operation.fetch('id')]
    ForemanRelease::Observation.new(state: :succeeded)
  end

  def release(_resource, operation)
    @calls << [:release, operation.fetch('id')]
    true
  end
end

class RuntimePreflight
  attr_reader :calls, :secret_calls
  attr_accessor :application_fingerprint, :execution_fingerprint, :certificate_expiry, :secret_error

  def initialize
    @calls = []
    @secret_calls = []
    @application_fingerprint = 'a' * 64
    @execution_fingerprint = 'b' * 64
    @certificate_expiry = Time.utc(2026, 10, 25, 12, 0, 0)
  end

  def validate!(documents, namespace)
    @calls << [documents, namespace]
    RuntimeSecretSnapshot.new(self, certificate_expiry)
  end

  def validate_secrets!(documents, namespace)
    @secret_calls << [documents, namespace]
    raise ForemanRelease::InvalidRelease, secret_error if secret_error

    RuntimeSecretSnapshot.new(self, certificate_expiry)
  end

  def fingerprint(documents)
    execution = documents.any? do |document|
      document.dig('metadata', 'labels', 'app.kubernetes.io/instance') == 'execution'
    end
    execution ? execution_fingerprint : application_fingerprint
  end
end

class RuntimeSecretSnapshot
  attr_reader :expiration

  def initialize(preflight, expiration)
    @preflight = preflight
    @expiration = expiration
  end

  def fingerprint(documents)
    @preflight.fingerprint(documents)
  end
end

def complete_job(job)
  copy = Marshal.load(Marshal.dump(job))
  copy['status'] = {'conditions' => [{'type' => 'Complete', 'status' => 'True'}]}
  copy
end

def available_deployment(deployment)
  copy = Marshal.load(Marshal.dump(deployment))
  copy['metadata']['generation'] = 1
  replicas = copy.dig('spec', 'replicas') || 1
  copy['status'] = {
    'observedGeneration' => 1,
    'replicas' => replicas,
    'updatedReplicas' => replicas,
    'readyReplicas' => replicas,
    'availableReplicas' => replicas,
    'unavailableReplicas' => 0,
    'conditions' => [
      {'type' => 'Progressing', 'status' => 'True'},
      {'type' => 'Available', 'status' => 'True'}
    ]
  }
  copy
end

def deployment_with_old_replicas(deployment)
  copy = available_deployment(deployment)
  desired = copy.dig('spec', 'replicas') || 1
  copy['status']['replicas'] = desired + 1
  copy['status']['updatedReplicas'] = [desired - 1, 0].max
  copy
end

runner = RecordingHelmRunner.new
preflight = RuntimePreflight.new
application_values = YAML.safe_load(root.join('examples/cluster-values.yaml').read)
application_values['monitoring'] = {'prometheusRule' => {'enabled' => true, 'labels' => {}}}
kubernetes = RuntimeKubernetesClient.new(
  application_values: YAML.dump(application_values),
  execution_values: root.join('examples/execution-proxy-values.yaml').read
)
runtime_lease = RuntimeLeaseManager.new
adapter = ForemanRelease::RuntimeAdapter.new(
  root: root,
  lease_identity: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  runner: runner,
  kubernetes_client: kubernetes,
  lease_manager: runtime_lease,
  preflight: preflight
)
resource = {
  'apiVersion' => 'platform.theforeman.org/v1alpha1',
  'kind' => 'ForemanRelease',
  'metadata' => {
    'name' => 'foreman',
    'namespace' => 'platform',
    'uid' => '12345678-1234-1234-1234-123456789abc'
  },
  'spec' => {
    'compatibilitySet' => 'nightly-candidate-2026-09-24',
    'allowCandidate' => true,
    'application' => {
      'releaseName' => 'foreman',
      'valuesSecretRef' => {'name' => 'application-values', 'key' => 'values.yaml'}
    },
    'executionProxy' => {
      'releaseName' => 'execution',
      'valuesSecretRef' => {'name' => 'execution-values', 'key' => 'values.yaml'}
    }
  }
}
operation = {'id' => '12345678-1234-1234-1234-123456789abc-g7'}
kubernetes.releases_list = [resource]

lease_holder = "#{operation.fetch('id')}:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
raise 'controller did not acquire its uniquely fenced operation Lease' unless adapter.acquire_lease(resource, operation).state == :succeeded
raise 'controller did not renew through a race-safe acquire' unless adapter.renew_lease(resource, operation).state == :succeeded
raise 'controller did not release its fenced operation Lease' unless adapter.release_lease(resource, operation)
raise 'durable operation ID was used as a shared holder identity' unless runtime_lease.calls == [
  [:acquire, lease_holder], [:acquire, lease_holder], [:release, lease_holder]
]

validation = adapter.validate(resource, operation)
raise 'release validation failed' unless validation.state == :succeeded
expected_validation_details = ForemanRelease::RuntimeAdapter::INPUT_DIGESTS.keys + [
  ForemanRelease::RuntimeAdapter::APPLICATION_SECRETS_DIGEST,
  ForemanRelease::RuntimeAdapter::EXECUTION_SECRETS_DIGEST,
  'sourceSets'
]
unless validation.details.keys.sort == expected_validation_details.sort
  raise 'validation did not pin all release inputs and source sets'
end
raise 'fresh installation unexpectedly recorded an installed source set' unless validation.details.fetch('sourceSets').empty?
raise 'rendered cluster preflight was not executed' unless preflight.calls.length == 1 && preflight.calls.first.last == 'platform'
raise 'Secret values were not written with mode 0600' unless runner.values_modes.all? { |mode| mode == 0o600 }

valid_application_values = kubernetes.application_values
application_config = YAML.safe_load(valid_application_values)
application_config['smartProxy']['executionRegistration']['url'] = 'https://wrong-execution-service:8443'
kubernetes.application_values = YAML.dump(application_config)
begin
  adapter.validate(resource, operation)
  raise 'mismatched execution proxy registration URL was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('registration URL must be')
ensure
  kubernetes.application_values = valid_application_values
end

valid_execution_values = kubernetes.execution_values
execution_config = YAML.safe_load(valid_execution_values)
execution_config['smokeTest']['foremanCertificateSecret'] = 'another-foreman-certificate'
kubernetes.execution_values = YAML.dump(execution_config)
begin
  adapter.validate(resource, operation)
  raise 'mismatched Foreman client certificate Secret was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('application Foreman certificate Secret')
ensure
  kubernetes.execution_values = valid_execution_values
end

execution_config = YAML.safe_load(valid_execution_values)
execution_config['networkPolicy']['ingress'] = {'peers' => [{
  'podSelector' => {
    'matchLabels' => {
      'app.kubernetes.io/instance' => 'another-application',
      'app.kubernetes.io/component' => 'foreman'
    }
  }
}]}
kubernetes.execution_values = YAML.dump(execution_config)
begin
  adapter.validate(resource, operation)
  raise 'execution proxy ingress excluding the registration Job was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('rejects its Foreman registration Job')
ensure
  kubernetes.execution_values = valid_execution_values
end

operation.merge!(validation.details)

runner.existing_releases = ['foreman']
begin
  adapter.validate(resource, operation)
  raise 'unmanaged existing Helm release was adopted implicitly'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('application.adoptExisting=true')
end
resource['spec']['application']['adoptExisting'] = true
adoption = adapter.validate(resource, operation)
raise 'explicit Helm release adoption was rejected' unless adoption.state == :succeeded
unless adoption.details.fetch('sourceSets') == ['nightly-candidate-2026-09-24']
  raise 'adopted Helm release source set was not validated and recorded'
end
runner.application_set = 'undeclared-set'
begin
  adapter.validate(resource, operation)
  raise 'adoption from an undeclared compatibility set was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('is not declared')
ensure
  runner.application_set = 'nightly-candidate-2026-09-24'
end
resource['spec']['application']['adoptExisting'] = false
runner.existing_releases = []

conflict = Marshal.load(Marshal.dump(resource))
conflict['metadata']['name'] = 'conflicting-release'
conflict['metadata']['uid'] = '87654321-4321-4321-4321-cba987654321'
kubernetes.releases_list = [resource, conflict]
begin
  adapter.validate(resource, operation)
  raise 'two ForemanRelease objects were allowed to own the same Helm releases'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('conflicting-release already owns')
ensure
  kubernetes.releases_list = [resource]
end

original_values = kubernetes.application_values
kubernetes.application_values = "#{original_values}\n# changed during release\n"
begin
  adapter.ensure_migrations(resource, operation)
  raise 'changed values Secret was accepted during an operation'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('changed during operation')
ensure
  kubernetes.application_values = original_values
end

preflight.application_fingerprint = 'c' * 64
begin
  adapter.ensure_migrations(resource, operation)
  raise 'changed application Secret input was accepted during an operation'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('applicationSecretsSha256 changed during operation')
ensure
  preflight.application_fingerprint = operation.fetch(
    ForemanRelease::RuntimeAdapter::APPLICATION_SECRETS_DIGEST
  )
end

application_render = runner.renders.fetch('foreman')
first_dependency_preflight = adapter.ensure_dependencies(resource, operation)
unless first_dependency_preflight.state == :pending &&
       first_dependency_preflight.details.fetch(:dependencyPreflightJobs).length == 1
  raise 'initial dependency preflight reconciliation did not checkpoint one Job'
end
dependency_jobs = kubernetes.created.select do |item|
  item.dig('metadata', 'labels', 'app.kubernetes.io/component') ==
    ForemanRelease::RuntimeAdapter::DEPENDENCY_PREFLIGHT_COMPONENT
end
raise 'controller did not submit exactly one dependency preflight Job' unless dependency_jobs.length == 1
dependency_job = dependency_jobs.first
unless dependency_job.dig('metadata', 'ownerReferences', 0, 'uid') == resource.dig('metadata', 'uid')
  raise 'dependency preflight Job is not owned by the ForemanRelease'
end
if dependency_job.fetch('metadata').fetch('annotations', {}).keys.any? { |key| key.start_with?('helm.sh/hook') }
  raise 'controller-owned dependency preflight Job retained Helm hook annotations'
end
kubernetes.replace('jobs', dependency_jobs.map { |job| complete_job(job) })
dependency_preflight = adapter.ensure_dependencies(resource, operation)
raise 'completed dependency preflight was not adopted' unless dependency_preflight.state == :succeeded

desired_foreman_config = application_render.find do |item|
  item['kind'] == 'ConfigMap' && item.dig('metadata', 'name').end_with?('-foreman-config')
end
existing_foreman_config = Marshal.load(Marshal.dump(desired_foreman_config))
existing_foreman_config['metadata']['resourceVersion'] = '40'
existing_foreman_config['metadata']['labels']['app.kubernetes.io/managed-by'] = 'Helm'
existing_foreman_config['metadata']['annotations'] = {
  'meta.helm.sh/release-name' => 'foreman',
  'meta.helm.sh/release-namespace' => 'platform'
}
existing_foreman_config['data'] = {'stale' => 'configuration'}
kubernetes.replace('configmaps', [existing_foreman_config])

first_migration = adapter.ensure_migrations(resource, operation)
raise 'initial migration reconciliation did not remain pending' unless first_migration.state == :pending
raise 'submitted migration Job names were not checkpointed' unless first_migration.details.fetch(:migrationJobs).length == 3
if runner.calls.map(&:first).any? { |command| command.first(2) == %w[helm upgrade] && command.include?('foreman') }
  raise 'application workloads were submitted before migrations completed'
end
migration_jobs = kubernetes.created.select do |item|
  ForemanRelease::RuntimeAdapter::MIGRATION_COMPONENTS.include?(item.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
raise 'controller did not submit all migration Jobs directly' unless migration_jobs.length == 3
unless migration_jobs.all? { |job| job.dig('metadata', 'ownerReferences', 0, 'uid') == resource.dig('metadata', 'uid') }
  raise 'migration Jobs are not owned by the ForemanRelease'
end
prepared_kinds = kubernetes.created_resources.each_with_object(Hash.new(0)) do |item, counts|
  counts[item['kind']] += 1
end
unless prepared_kinds.slice('PersistentVolumeClaim', 'ServiceAccount') == {
  'PersistentVolumeClaim' => 1, 'ServiceAccount' => 2
}
  raise "migration prerequisites were not prepared: #{prepared_kinds.inspect}"
end
updated_foreman_config = kubernetes.resource('platform', 'configmap', desired_foreman_config.dig('metadata', 'name'))
unless updated_foreman_config['data'] == desired_foreman_config['data']
  raise 'existing migration ConfigMap was not updated before starting Jobs'
end

kubernetes.replace('jobs', migration_jobs.map { |job| complete_job(job) })
migrations = adapter.ensure_migrations(resource, operation)
raise 'completed migrations were not adopted' unless migrations.state == :succeeded
raise 'migration Job names were not recorded' unless migrations.details.fetch(:migrationJobs).length == 3

runner.existing_releases = ['foreman']
raise 'controller-owned Helm release required re-adoption' unless adapter.validate(resource, operation).state == :succeeded
runner.existing_releases = []

application_submission = adapter.ensure_application(resource, operation)
raise 'application submission did not remain pending' unless application_submission.state == :pending
unless application_submission.details == {applicationSubmittedRevision: 2}
  raise 'application submission did not expose its Helm revision'
end
upgrade = runner.calls.map(&:first).find { |command| command.first(2) == %w[helm upgrade] && command.include?('foreman') }
raise 'application Helm release was not submitted after migrations' unless upgrade
raise 'runtime adapter used blocking Helm wait' if upgrade.any? { |argument| argument.start_with?('--wait') }
raise 'application operation ID was not passed to Helm' unless upgrade.include?("releaseOperation.id=#{operation.fetch('id')}")
unless upgrade.include?("secretRolloutToken=#{operation.fetch(ForemanRelease::RuntimeAdapter::APPLICATION_SECRETS_DIGEST)}")
  raise 'application Secret fingerprint was not passed as the rollout token'
end
unless upgrade.include?('releaseOperation.skipMigrationJobs=true')
  raise 'application rollout attempted to recreate controller-owned migration Jobs'
end

application_render = runner.renders.fetch('foreman')
deployments = application_render.select { |item| item['kind'] == 'Deployment' }.map { |item| available_deployment(item) }
application_upgrades = runner.calls.count do |command, _stdin|
  command.first(2) == %w[helm upgrade] && command.include?('foreman')
end
kubernetes.replace('deployments', deployments.drop(1))
partial_application = adapter.ensure_application(resource, operation)
raise 'partial application workload set was not repaired' unless partial_application.state == :pending
unless runner.calls.count { |command, _stdin| command.first(2) == %w[helm upgrade] && command.include?('foreman') } == application_upgrades + 1
  raise 'partial application workload set did not resubmit Helm ownership'
end
kubernetes.replace('deployments', deployments)
registration_jobs = application_render.select do |item|
  item['kind'] == 'Job' && item.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'pulp-registration'
end
kubernetes.replace('jobs', migration_jobs.map { |job| complete_job(job) })
rolling_deployments = deployments.each_with_index.map do |deployment, index|
  index.zero? ? deployment_with_old_replicas(deployment) : deployment
end
kubernetes.replace('deployments', rolling_deployments)
rolling_application = adapter.ensure_application(resource, operation)
unless rolling_application.state == :pending && rolling_application.message.include?('updated')
  raise 'application rollout advanced while old ReplicaSet pods were still available'
end
kubernetes.replace('deployments', deployments)
missing_registration = adapter.ensure_application(resource, operation)
raise 'missing Pulp registration Job was not repaired' unless missing_registration.state == :pending
kubernetes.replace('jobs', migration_jobs.map { |job| complete_job(job) } + registration_jobs.map { |job| complete_job(job) })
application = adapter.ensure_application(resource, operation)
raise "available application was not accepted: #{application.message}" unless application.state == :succeeded
raise 'application Helm revision was not recorded' unless application.details == {applicationRevision: 2}

application_smoke = adapter.ensure_application_smoke(resource, operation)
raise 'application smoke Job was not submitted asynchronously' unless application_smoke.state == :pending
smoke = kubernetes.created.last
raise 'smoke Job retained a Helm hook annotation' if smoke.dig('metadata', 'annotations').keys.any? { |key| key.start_with?('helm.sh/hook') }
raise 'smoke Job is not owned by the ForemanRelease' unless smoke.dig('metadata', 'ownerReferences', 0, 'uid') == resource.dig('metadata', 'uid')
kubernetes.replace('jobs', kubernetes.resources('platform', 'jobs').map { |job| complete_job(job) })
raise 'completed application smoke Job was not adopted' unless adapter.ensure_application_smoke(resource, operation).state == :succeeded

proxy_submission = adapter.ensure_proxy(resource, operation)
raise 'initial execution proxy reconciliation did not remain pending' unless proxy_submission.state == :pending
unless proxy_submission.details == {executionProxySubmittedRevision: 4}
  raise 'execution proxy submission did not expose its Helm revision'
end
proxy_upgrade = runner.calls.map(&:first).find { |command| command.first(2) == %w[helm upgrade] && command.include?('execution') }
raise 'execution proxy Helm release was not submitted' unless proxy_upgrade
raise 'execution operation ID was not passed to Helm' unless proxy_upgrade.include?("releaseOperation.id=#{operation.fetch('id')}")
unless proxy_upgrade.include?("secretRolloutToken=#{operation.fetch(ForemanRelease::RuntimeAdapter::EXECUTION_SECRETS_DIGEST)}")
  raise 'execution Secret fingerprint was not passed as the rollout token'
end

execution_render = runner.renders.fetch('execution')
kubernetes.replace(
  'deployments',
  deployments + execution_render.select { |item| item['kind'] == 'Deployment' }.map { |item| available_deployment(item) }
)
proxy = adapter.ensure_proxy(resource, operation)
raise "available execution proxy was not accepted: #{proxy.message}" unless proxy.state == :succeeded
raise 'execution proxy Helm revision was not recorded' unless proxy.details == {executionProxyRevision: 4}

registration = adapter.ensure_final_smoke(resource, operation)
raise 'execution proxy registration Job was not submitted asynchronously' unless registration.state == :pending
registration_job = kubernetes.created.last
raise 'registration Job has the wrong component' unless registration_job.dig('metadata', 'labels', 'app.kubernetes.io/component') ==
                                                    'execution-proxy-registration'
registration_script = registration_job.dig('spec', 'template', 'spec', 'containers', 0, 'command').join("\n")
raise 'registration Job does not verify exact Foreman features' unless registration_script.include?('proxy.features.reload.pluck(:name).sort')
verification_jobs = kubernetes.created.reject do |job|
  (ForemanRelease::RuntimeAdapter::MIGRATION_COMPONENTS +
    [ForemanRelease::RuntimeAdapter::DEPENDENCY_PREFLIGHT_COMPONENT]).include?(
      job.dig('metadata', 'labels', 'app.kubernetes.io/component')
    )
end
raise 'application verification Jobs reused a name' unless verification_jobs.map { |job| job.dig('metadata', 'name') }.uniq.length == 2
kubernetes.replace('jobs', kubernetes.resources('platform', 'jobs').map { |job| complete_job(job) })

final_application_smoke = adapter.ensure_final_smoke(resource, operation)
raise 'final application smoke Job was not submitted asynchronously' unless final_application_smoke.state == :pending
verification_jobs = kubernetes.created.reject do |job|
  (ForemanRelease::RuntimeAdapter::MIGRATION_COMPONENTS +
    [ForemanRelease::RuntimeAdapter::DEPENDENCY_PREFLIGHT_COMPONENT]).include?(
      job.dig('metadata', 'labels', 'app.kubernetes.io/component')
    )
end
raise 'verification Jobs did not receive distinct names' unless verification_jobs.map { |job| job.dig('metadata', 'name') }.uniq.length == 3
kubernetes.replace('jobs', kubernetes.resources('platform', 'jobs').map { |job| complete_job(job) })

execution_smoke = adapter.ensure_final_smoke(resource, operation)
raise 'execution mTLS smoke Job was not submitted asynchronously' unless execution_smoke.state == :pending
execution_job = kubernetes.created.last
raise 'execution smoke Job has the wrong Helm instance' unless execution_job.dig('metadata', 'labels', 'app.kubernetes.io/instance') == 'execution'
raise 'execution smoke Job does not verify the proxy Service' unless execution_job.dig('spec', 'template', 'spec', 'containers', 0, 'env').any? do |entry|
  entry['name'] == 'PROXY_FEATURES_URL' && entry['value'] == 'https://execution-foreman-execution-proxy:8443/features'
end
verification_jobs = kubernetes.created.reject do |job|
  (ForemanRelease::RuntimeAdapter::MIGRATION_COMPONENTS +
    [ForemanRelease::RuntimeAdapter::DEPENDENCY_PREFLIGHT_COMPONENT]).include?(
      job.dig('metadata', 'labels', 'app.kubernetes.io/component')
    )
end
raise 'four release verification Jobs did not receive distinct names' unless verification_jobs.map { |job| job.dig('metadata', 'name') }.uniq.length == 4
kubernetes.replace('jobs', kubernetes.resources('platform', 'jobs').map { |job| complete_job(job) })
raise 'completed paired final smoke gate was not adopted' unless adapter.ensure_final_smoke(resource, operation).state == :succeeded

runner.existing_releases = %w[foreman execution]
all_rendered = runner.renders.fetch('foreman') + runner.renders.fetch('execution')
ForemanRelease::RuntimeAdapter::DRIFT_RESOURCE_TYPES.each do |kind, type|
  kubernetes.replace(type, all_rendered.select { |item| item['kind'] == kind })
end
preflight.secret_calls.clear
audit = adapter.audit_ready(resource, operation)
raise "complete Ready release was reported as drifted: #{audit.message}" unless audit.state == :succeeded
unless audit.details == {'certificateExpiryTimestamp' => '2026-10-25T12:00:00Z'}
  raise 'Ready audit did not report the earliest certificate expiry'
end
unless preflight.secret_calls.length == 2 &&
       preflight.secret_calls.sum { |documents, _namespace| documents.length } == all_rendered.length &&
       preflight.secret_calls.all? { |_documents, namespace| namespace == 'platform' }
  raise 'Ready audit did not revalidate both external Secret inventories'
end

preflight.application_fingerprint = 'c' * 64
secret_drift = adapter.audit_ready(resource, operation)
unless secret_drift.state == :drifted &&
       secret_drift.details.fetch('driftedResources').include?('SecretInputs/application:modified')
  raise 'valid application Secret rotation did not request a repair rollout'
end
preflight.application_fingerprint = operation.fetch(
  ForemanRelease::RuntimeAdapter::APPLICATION_SECRETS_DIGEST
)

preflight.execution_fingerprint = 'd' * 64
execution_secret_drift = adapter.audit_ready(resource, operation)
unless execution_secret_drift.state == :drifted &&
       execution_secret_drift.details.fetch('driftedResources').include?('SecretInputs/execution-proxy:modified')
  raise 'valid execution proxy Secret rotation did not request a repair rollout'
end
preflight.execution_fingerprint = operation.fetch(
  ForemanRelease::RuntimeAdapter::EXECUTION_SECRETS_DIGEST
)

live_deployments = kubernetes.resources('platform', 'deployments')
injected_deployment = Marshal.load(Marshal.dump(live_deployments.first))
injected_deployment['metadata']['annotations'] ||= {}
injected_deployment['metadata']['annotations']['admission.example.test/injected'] = 'true'
injected_deployment.dig('spec', 'template', 'spec', 'containers') << {
  'name' => 'admission-sidecar',
  'image' => 'example.invalid/sidecar@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
}
kubernetes.replace('deployments', [injected_deployment] + live_deployments.drop(1))
unless adapter.audit_ready(resource, operation).state == :succeeded
  raise 'additional admission-injected fields were reported as chart drift'
end
kubernetes.replace('deployments', live_deployments)

preflight.secret_error = 'certificate expires before the safety window'
begin
  adapter.audit_ready(resource, operation)
  raise 'Ready audit accepted an unusable certificate Secret'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('certificate expires before the safety window')
ensure
  preflight.secret_error = nil
end

configmaps = kubernetes.resources('platform', 'configmaps')
modified_configmap = Marshal.load(Marshal.dump(configmaps.first))
modified_key = modified_configmap.fetch('data').keys.first
modified_configmap['data'][modified_key] = "#{modified_configmap['data'][modified_key]}\n# out-of-band change"
kubernetes.replace('configmaps', [modified_configmap] + configmaps.drop(1))
configuration_drift = adapter.audit_ready(resource, operation)
unless configuration_drift.state == :drifted &&
       configuration_drift.details.fetch('driftedResources').include?(
         "ConfigMap/#{modified_configmap.dig('metadata', 'name')}:modified"
       )
  raise 'out-of-band ConfigMap mutation was not detected'
end
kubernetes.replace('configmaps', configmaps)

prometheus_rules = kubernetes.resources('platform', 'prometheusrules')
raise 'monitoring-enabled release did not render a PrometheusRule' if prometheus_rules.empty?

modified_prometheus_rule = Marshal.load(Marshal.dump(prometheus_rules.first))
modified_prometheus_rule.dig('spec', 'groups', 0, 'rules', 0)['for'] = '11m'
kubernetes.replace('prometheusrules', [modified_prometheus_rule] + prometheus_rules.drop(1))
monitoring_drift = adapter.audit_ready(resource, operation)
unless monitoring_drift.state == :drifted &&
       monitoring_drift.details.fetch('driftedResources').include?(
         "PrometheusRule/#{modified_prometheus_rule.dig('metadata', 'name')}:modified"
       )
  raise 'out-of-band PrometheusRule mutation was not detected'
end
kubernetes.replace('prometheusrules', prometheus_rules)

revision_drift = adapter.audit_ready(
  resource,
  operation.merge('applicationRevision' => 1, 'executionProxyRevision' => 4)
)
unless revision_drift.state == :drifted &&
       revision_drift.details.fetch('driftedResources').any? { |item| item.start_with?('HelmRevision/foreman:') }
  raise 'out-of-band Helm revision was not detected'
end

claims = kubernetes.resources('platform', 'persistentvolumeclaims')
modified_claim = Marshal.load(Marshal.dump(claims.first))
modified_claim['spec']['accessModes'] = ['ReadOnlyMany']
kubernetes.replace('persistentvolumeclaims', [modified_claim] + claims.drop(1))
stateful_mutation = adapter.audit_ready(resource, operation)
unless stateful_mutation.state == :unsafe_drift &&
       stateful_mutation.details.fetch('driftedResources').include?(
         "PersistentVolumeClaim/#{modified_claim.dig('metadata', 'name')}:modified"
       )
  raise 'out-of-band PVC mutation was selected for automatic repair'
end
kubernetes.replace('persistentvolumeclaims', claims)

missing_claim = claims.first
kubernetes.replace('persistentvolumeclaims', claims.drop(1))
stateful_drift = adapter.audit_ready(resource, operation)
raise 'missing stateful claim was selected for automatic repair' unless stateful_drift.state == :unsafe_drift
unless stateful_drift.details.fetch('driftedResources').include?("PersistentVolumeClaim/#{missing_claim.dig('metadata', 'name')}")
  raise 'stateful drift evidence did not identify the missing claim'
end
kubernetes.replace('persistentvolumeclaims', claims)

services = kubernetes.resources('platform', 'services')
missing_service = services.first
kubernetes.replace('services', services.drop(1))
drift = adapter.audit_ready(resource, operation)
raise 'missing declared Service was not detected' unless drift.state == :drifted
unless drift.details.fetch('driftedResources').include?("Service/#{missing_service.dig('metadata', 'name')}")
  raise 'drift evidence did not identify the missing Service'
end

created_before_repair = kubernetes.created.length
repair = adapter.ensure_migrations(resource, operation.merge('type' => 'Repair'))
raise 'repair operation did not preserve migrated database state' unless repair.state == :succeeded
raise 'repair operation submitted database migration Jobs' unless kubernetes.created.length == created_before_repair
raise 'repair did not record skipped migrations' unless repair.details.fetch(:migrationsSkippedForRepair)

owner = resource.dig('metadata', 'uid')
historical_jobs = (3..6).map do |generation|
  job = {
    'apiVersion' => 'batch/v1',
    'kind' => 'Job',
    'metadata' => {
      'name' => "foreman-history-g#{generation}",
      'creationTimestamp' => "2026-09-2#{generation}T12:00:00Z",
      'labels' => {
        ForemanRelease::RuntimeAdapter::OWNER_LABEL => owner,
        ForemanRelease::RuntimeAdapter::OPERATION_LABEL => "#{owner}-g#{generation}",
        ForemanRelease::RuntimeAdapter::INSTANCE_LABEL => 'foreman',
        ForemanRelease::RuntimeAdapter::COMPONENT_LABEL => 'smoke-test'
      }
    }
  }
  generation == 3 ? job : complete_job(job)
end
kubernetes.replace('jobs', kubernetes.resources('platform', 'jobs') + historical_jobs)
cleanup = adapter.prune_operation_history(resource, operation)
raise 'operation history cleanup did not succeed' unless cleanup.state == :succeeded
unless kubernetes.deleted == [['jobs', 'foreman-history-g4']]
  raise "history cleanup removed an unsafe set: #{kubernetes.deleted.inspect}"
end

puts 'Runtime adapter pins inputs, adopts paired resources, and safely bounds completed Job history.'
