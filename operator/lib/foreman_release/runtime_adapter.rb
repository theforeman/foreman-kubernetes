# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require 'tmpdir'
require 'yaml'
require_relative 'cluster_preflight'
require_relative 'command_runner'
require_relative 'kubernetes_client'
require_relative 'lease_manager'
require_relative 'reconciler'
require_relative 'release_inputs'

module ForemanRelease
  class RuntimeAdapter
    DEPENDENCY_PREFLIGHT_COMPONENT = 'dependency-preflight'
    MIGRATION_COMPONENTS = %w[candlepin-migrate pulp-migrate foreman-migrate].freeze
    REGISTRATION_COMPONENT = 'pulp-registration'
    EXECUTION_REGISTRATION_COMPONENT = 'execution-proxy-registration'
    HISTORY_COMPONENTS = (MIGRATION_COMPONENTS + [
      DEPENDENCY_PREFLIGHT_COMPONENT,
      REGISTRATION_COMPONENT, EXECUTION_REGISTRATION_COMPONENT, 'smoke-test'
    ]).freeze
    OPERATION_LABEL = 'platform.theforeman.org/release-operation'
    OWNER_LABEL = 'platform.theforeman.org/release-owner'
    COMPONENT_LABEL = 'app.kubernetes.io/component'
    INSTANCE_LABEL = 'app.kubernetes.io/instance'
    INPUT_DIGESTS = {
      'applicationValuesSha256' => :application_values,
      'executionProxyValuesSha256' => :execution_values,
      'applicationProfileSha256' => :application_profile,
      'executionProxyProfileSha256' => :execution_proxy_profile
    }.freeze
    APPLICATION_SECRETS_DIGEST = 'applicationSecretsSha256'
    EXECUTION_SECRETS_DIGEST = 'executionProxySecretsSha256'
    MIGRATION_DEPENDENCY_TYPES = {
      'ConfigMap' => 'configmap',
      'PersistentVolumeClaim' => 'persistentvolumeclaim',
      'ServiceAccount' => 'serviceaccount'
    }.freeze
    DRIFT_RESOURCE_TYPES = {
      'ConfigMap' => 'configmaps',
      'CronJob' => 'cronjobs',
      'Deployment' => 'deployments',
      'HorizontalPodAutoscaler' => 'horizontalpodautoscalers',
      'Ingress' => 'ingresses',
      'NetworkPolicy' => 'networkpolicies',
      'PersistentVolumeClaim' => 'persistentvolumeclaims',
      'PodDisruptionBudget' => 'poddisruptionbudgets',
      'PrometheusRule' => 'prometheusrules',
      'Service' => 'services',
      'ServiceAccount' => 'serviceaccounts'
    }.freeze

    ReleaseContext = Struct.new(
      :profiles,
      :application_values,
      :execution_values,
      :digests,
      keyword_init: true
    )

    def initialize(root:, lease_identity:, runner: CommandRunner.new, kubernetes_client: nil, lease_manager: nil, preflight: nil)
      raise ArgumentError, 'release Lease identity is required' if lease_identity.to_s.empty?

      @root = Pathname.new(root).realpath
      @lease_identity = lease_identity
      @runner = runner
      @kubernetes_client = kubernetes_client || KubernetesClient.new(runner: runner)
      @lease_manager = lease_manager || LeaseManager.new(runner: runner)
      @preflight = preflight || ClusterPreflight.new(@kubernetes_client, runner: runner)
      @catalog = ReleaseCatalog.load(@root)
      @values_reader = ValuesReader.new(@kubernetes_client)
      @application_chart = @root.join('charts/foreman-stack').to_s
      @execution_chart = @root.join('charts/foreman-execution-proxy').to_s
    end

    def validate(resource, operation)
      validate_release_ownership!(resource)
      validate_helm_ownership!(resource)
      source_sets = installed_compatibility_sets(resource)
      context = resolve_context(resource, source_sets: source_sets)
      with_value_files(context) do |application_values, execution_values|
        lint_chart(
          @application_chart, application_values, context.profiles.application_path,
          resource, operation, APPLICATION_SECRETS_DIGEST
        )
        lint_chart(
          @execution_chart, execution_values, context.profiles.execution_proxy_path,
          resource, operation, EXECUTION_SECRETS_DIGEST
        )
        application = render_chart(
          application_release(resource), @application_chart, application_values,
          context.profiles.application_path, resource, operation, APPLICATION_SECRETS_DIGEST
        )
        execution = render_chart(
          execution_release(resource), @execution_chart, execution_values,
          context.profiles.execution_proxy_path, resource, operation, EXECUTION_SECRETS_DIGEST
        )
        validate_rendered_contract!(application, execution)
        snapshot = @preflight.validate!(application + execution, resource.dig('metadata', 'namespace'))
        context.digests[APPLICATION_SECRETS_DIGEST] = snapshot.fingerprint(application)
        context.digests[EXECUTION_SECRETS_DIGEST] = snapshot.fingerprint(execution)
      end

      Observation.new(
        state: :succeeded,
        message: "validated compatibility set #{context.profiles.name}",
        details: context.digests.merge('sourceSets' => source_sets)
      )
    end

    def acquire_lease(resource, operation)
      @lease_manager.acquire(resource, lease_operation(operation))
    end

    def renew_lease(resource, operation)
      @lease_manager.acquire(resource, lease_operation(operation))
    end

    def release_lease(resource, operation)
      @lease_manager.release(resource, lease_operation(operation))
    end

    def prune_operation_history(resource, operation)
      limit = Integer(resource.dig('spec', 'operationHistoryLimit') || 3)
      jobs = @kubernetes_client.resources(
        resource.dig('metadata', 'namespace'), 'jobs',
        labels: {OWNER_LABEL => resource.dig('metadata', 'uid')}
      ).select do |job|
        HISTORY_COMPONENTS.include?(job.dig('metadata', 'labels', COMPONENT_LABEL)) &&
          [application_release(resource), execution_release(resource)].include?(job.dig('metadata', 'labels', INSTANCE_LABEL))
      end
      completed = jobs.group_by { |job| job.dig('metadata', 'labels', OPERATION_LABEL) }.reject do |id, grouped|
        id.to_s.empty? || grouped.any? { |job| !terminal_job?(job) }
      end
      retained = completed.keys.sort_by do |id|
        grouped = completed.fetch(id)
        timestamps = grouped.map { |job| job.dig('metadata', 'creationTimestamp') }.compact
        [*operation_order(id), timestamps.max.to_s, id]
      end.last(limit)
      retained << operation['id'] if operation['id']
      stale = completed.keys - retained
      stale.flat_map { |id| completed.fetch(id) }.each do |job|
        @kubernetes_client.delete(
          resource.dig('metadata', 'namespace'), 'job', job.dig('metadata', 'name')
        )
      end
      retained_count = (completed.keys - stale).length

      Observation.new(
        state: :succeeded,
        message: "retained #{retained_count} completed operation histories and removed #{stale.length}",
        details: {'prunedOperations' => stale.sort}
      )
    end

    def ensure_migrations(resource, operation)
      if operation['type'] == 'Repair'
        return Observation.new(
          state: :succeeded,
          message: 'repair operation preserves the already-migrated database state',
          details: {migrationJobs: [], migrationsSkippedForRepair: true}
        )
      end

      with_rendered_application(resource, operation) do |context, values_path, resources|
        expected = jobs(resources, MIGRATION_COMPONENTS)
        raise InvalidRelease, 'application chart did not render all three migration Jobs' unless expected.length == 3

        live = operation_resources(resource, operation, 'jobs')
        matching = live.select { |job| expected_names(expected).include?(job.dig('metadata', 'name')) }
        unless matching.length == expected.length
          submit_job_bundle(resource, operation, resources, expected, matching)
          return Observation.new(
            state: :pending,
            message: 'migration resources submitted; waiting for Jobs',
            details: {migrationJobs: expected_names(expected).sort}
          )
        end

        observe_jobs(matching, details: {migrationJobs: expected_names(expected).sort})
      end
    end

    def ensure_dependencies(resource, operation)
      with_rendered_application(resource, operation) do |_context, _values_path, resources|
        expected = jobs(resources, [DEPENDENCY_PREFLIGHT_COMPONENT])
        unless expected.length == 1
          raise InvalidRelease, 'application chart must render exactly one dependency preflight Job'
        end

        live = operation_resources(resource, operation, 'jobs')
        matching = live.select { |job| expected_names(expected).include?(job.dig('metadata', 'name')) }
        unless matching.length == expected.length
          submit_job_bundle(resource, operation, resources, expected, matching)
          return Observation.new(
            state: :pending,
            message: 'dependency preflight submitted; waiting for its Job',
            details: {dependencyPreflightJobs: expected_names(expected).sort}
          )
        end

        observe_jobs(matching, details: {dependencyPreflightJobs: expected_names(expected).sort})
      end
    end

    def audit_ready(resource, operation)
      drift = []
      application_rendered = []
      execution_rendered = []
      [
        [application_release(resource), operation['applicationRevision']],
        [execution_release(resource), operation['executionProxyRevision']]
      ].each do |release_name, expected_revision|
        unless helm_release_exists?(resource, release_name)
          drift << "HelmRelease/#{release_name}"
          next
        end
        next unless expected_revision

        actual_revision = helm_revision(resource, release_name)
        if actual_revision != Integer(expected_revision)
          drift << "HelmRevision/#{release_name}:expected-#{expected_revision}-actual-#{actual_revision}"
        end
      end

      with_rendered_application(resource, operation, verify_secret_inputs: false) do |_context, _values_path, resources|
        application_rendered.concat(resources)
        drift.concat(declared_resource_drift(resource, resources))
      end
      with_rendered_execution(resource, operation, verify_secret_inputs: false) do |_context, _values_path, resources|
        execution_rendered.concat(resources)
        drift.concat(declared_resource_drift(resource, resources))
      end

      namespace = resource.dig('metadata', 'namespace')
      secret_snapshots = [
        [APPLICATION_SECRETS_DIGEST, 'application', application_rendered],
        [EXECUTION_SECRETS_DIGEST, 'execution-proxy', execution_rendered]
      ].map do |digest_key, label, resources|
        snapshot = @preflight.validate_secrets!(resources, namespace)
        actual = snapshot.fingerprint(resources)
        expected = operation[digest_key].to_s
        drift << "SecretInputs/#{label}:modified" if expected.empty? || expected != actual
        snapshot
      end

      drift = drift.uniq.sort
      stateful = drift.grep(/\APersistentVolumeClaim\//)
      unless stateful.empty?
        return Observation.new(
          state: :unsafe_drift,
          message: "stateful release resources are missing or modified and require recovery: #{stateful.join(', ')}",
          details: {'driftedResources' => drift}
        )
      end
      unless drift.empty?
        return Observation.new(
          state: :drifted,
          message: "declared release resources are missing or modified: #{drift.join(', ')}",
          details: {'driftedResources' => drift}
        )
      end

      certificate_expiry = secret_snapshots.map(&:expiration).compact.min
      details = if certificate_expiry
                  {'certificateExpiryTimestamp' => certificate_expiry.utc.iso8601}
                else
                  {}
                end
      Observation.new(
        state: :succeeded,
        message: 'all declared release resources and external Secret inputs are usable',
        details: details
      )
    end

    def ensure_application(resource, operation)
      with_rendered_application(resource, operation) do |context, values_path, resources|
        expected_deployments = resources.select { |item| item['kind'] == 'Deployment' }
        raise InvalidRelease, 'application chart did not render any Deployments' if expected_deployments.empty?

        live_deployments = operation_resources(resource, operation, 'deployments')
        missing_deployments = expected_names(expected_deployments) - expected_names(live_deployments)
        unless missing_deployments.empty?
          return submit_application_release(
            resource, operation, context, values_path,
            "submitted application release; waiting for Deployments: #{missing_deployments.join(', ')}"
          )
        end
        deployment_result = observe_deployments(expected_deployments, live_deployments)
        return deployment_result unless deployment_result.state == :succeeded

        expected_registration = jobs(resources, [REGISTRATION_COMPONENT])
        unless expected_registration.empty?
          live_jobs = operation_resources(resource, operation, 'jobs')
          registration = live_jobs.select do |job|
            expected_names(expected_registration).include?(job.dig('metadata', 'name'))
          end
          unless registration.length == expected_registration.length
            missing = expected_names(expected_registration) - expected_names(registration)
            return submit_application_release(
              resource, operation, context, values_path,
              "resubmitted application release; waiting for Pulp registration Jobs: #{missing.join(', ')}"
            )
          end

          registration_result = observe_jobs(registration)
          return registration_result unless registration_result.state == :succeeded
        end

        Observation.new(
          state: :succeeded,
          message: 'application workloads and Pulp registration are available',
          details: {applicationRevision: helm_revision(resource, application_release(resource))}
        )
      end
    end

    def ensure_application_smoke(resource, operation)
      ensure_smoke(resource, operation, 'application-smoke', source: :application)
    end

    def ensure_proxy(resource, operation)
      with_rendered_execution(resource, operation) do |context, values_path, resources|
        expected = resources.select { |item| item['kind'] == 'Deployment' }
        raise InvalidRelease, 'execution proxy chart must render exactly one Deployment' unless expected.length == 1

        live = operation_resources(resource, operation, 'deployments', instance: execution_release(resource))
        missing = expected_names(expected) - expected_names(live)
        unless missing.empty?
          return submit_execution_release(
            resource, operation, context, values_path,
            "submitted execution proxy release; waiting for Deployments: #{missing.join(', ')}"
          )
        end

        result = observe_deployments(expected, live)
        return result unless result.state == :succeeded

        Observation.new(
          state: :succeeded,
          message: 'execution proxy is available',
          details: {executionProxyRevision: helm_revision(resource, execution_release(resource))}
        )
      end
    end

    def ensure_final_smoke(resource, operation)
      proxy = ensure_proxy(resource, operation)
      return proxy unless proxy.state == :succeeded

      registration = ensure_execution_registration(resource, operation)
      return registration unless registration.state == :succeeded

      application = ensure_smoke(resource, operation, 'final-application-smoke', source: :application)
      return application unless application.state == :succeeded

      ensure_smoke(resource, operation, 'final-execution-smoke', source: :execution)
    end

    private

    def lease_operation(operation)
      {'id' => "#{operation.fetch('id')}:#{@lease_identity}"}
    end

    def validate_release_ownership!(resource)
      application = application_release(resource)
      execution = execution_release(resource)
      conflicting = @kubernetes_client.releases(resource.dig('metadata', 'namespace')).find do |candidate|
        next if candidate.dig('metadata', 'uid') == resource.dig('metadata', 'uid')

        application_release(candidate) == application || execution_release(candidate) == execution
      end
      return unless conflicting

      raise InvalidRelease,
            "ForemanRelease #{conflicting.dig('metadata', 'name')} already owns application #{application} or execution proxy #{execution}"
    end

    def validate_helm_ownership!(resource)
      [
        ['application', application_release(resource)],
        ['executionProxy', execution_release(resource)]
      ].each do |spec_key, release_name|
        next unless helm_release_exists?(resource, release_name)
        next if resource.dig('spec', spec_key, 'adoptExisting') == true
        next if release_owned_by_resource?(resource, release_name)

        raise InvalidRelease,
              "Helm release #{release_name} already exists; set spec.#{spec_key}.adoptExisting=true to take ownership explicitly"
      end
    end

    def helm_release_exists?(resource, release_name)
      output = @runner.run(
        'helm', 'list', '--namespace', resource.dig('metadata', 'namespace'),
        '--filter', "^#{Regexp.escape(release_name)}$", '--output=json'
      )
      JSON.parse(output).any? { |release| release['name'] == release_name }
    rescue JSON::ParserError => error
      raise InvalidRelease, "cannot inspect Helm releases: #{error.message}"
    end

    def release_owned_by_resource?(resource, release_name)
      labels = {
        OWNER_LABEL => resource.dig('metadata', 'uid'),
        INSTANCE_LABEL => release_name
      }
      %w[deployments jobs].any? do |type|
        !@kubernetes_client.resources(resource.dig('metadata', 'namespace'), type, labels: labels).empty?
      end
    end

    def resolve_context(resource, operation = nil, source_sets: [])
      profiles = @catalog.resolve(
        resource.dig('spec', 'compatibilitySet'),
        allow_candidate: resource.dig('spec', 'allowCandidate') == true,
        source_names: source_sets
      )
      values = @values_reader.read(resource)
      content = {
        application_values: values.application,
        execution_values: values.execution_proxy,
        application_profile: File.binread(profiles.application_path),
        execution_proxy_profile: File.binread(profiles.execution_proxy_path)
      }
      digests = INPUT_DIGESTS.to_h do |status_key, content_key|
        [status_key, Digest::SHA256.hexdigest(content.fetch(content_key))]
      end
      if operation
        digests.each do |key, actual|
          expected = operation[key]
          raise InvalidRelease, "release input #{key} was not pinned during validation" if expected.to_s.empty?
          raise InvalidRelease, "release input #{key} changed during operation" unless expected == actual
        end
      end

      ReleaseContext.new(
        profiles: profiles,
        application_values: values.application,
        execution_values: values.execution_proxy,
        digests: digests
      )
    end

    def installed_compatibility_sets(resource)
      sources = [
        resource.dig('status', 'currentSet'),
        resource.dig('status', 'lastSuccessfulSet')
      ].compact
      namespace = resource.dig('metadata', 'namespace')
      [
        [application_release(resource), %w[platform compatibilitySet]],
        [execution_release(resource), %w[compatibilitySet]]
      ].each do |release_name, path|
        next unless helm_release_exists?(resource, release_name)

        output = @runner.run(
          'helm', 'get', 'values', release_name,
          '--namespace', namespace, '--all', '--output=json'
        )
        values = JSON.parse(output)
        source = path.reduce(values) { |value, key| value.is_a?(Hash) ? value[key] : nil }
        if source.to_s.empty?
          raise InvalidRelease, "Helm release #{release_name} does not identify its compatibility set"
        end

        sources << source
      rescue JSON::ParserError => error
        raise InvalidRelease, "cannot inspect Helm release #{release_name} values: #{error.message}"
      end
      sources.uniq
    end

    def with_rendered_application(resource, operation, verify_secret_inputs: true)
      context = resolve_context(resource, operation)
      with_value_files(context) do |application_values, _execution_values|
        rendered = render_chart(
          application_release(resource), @application_chart, application_values,
          context.profiles.application_path, resource, operation, APPLICATION_SECRETS_DIGEST
        )
        validate_secret_inputs!(resource, operation, rendered, APPLICATION_SECRETS_DIGEST) if verify_secret_inputs
        yield context, application_values, rendered
      end
    end

    def with_rendered_execution(resource, operation, verify_secret_inputs: true)
      context = resolve_context(resource, operation)
      with_value_files(context) do |_application_values, execution_values|
        rendered = render_chart(
          execution_release(resource), @execution_chart, execution_values,
          context.profiles.execution_proxy_path, resource, operation, EXECUTION_SECRETS_DIGEST
        )
        validate_secret_inputs!(resource, operation, rendered, EXECUTION_SECRETS_DIGEST) if verify_secret_inputs
        yield context, execution_values, rendered
      end
    end

    def with_value_files(context)
      Dir.mktmpdir('foreman-release-values-') do |directory|
        application = secure_write(directory, 'application.yaml', context.application_values)
        execution = secure_write(directory, 'execution.yaml', context.execution_values)
        yield application, execution
      end
    end

    def secure_write(directory, name, content)
      path = File.join(directory, name)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(content) }
      path
    end

    def lint_chart(chart, values_path, profile_path, resource, operation, secret_digest_key)
      @runner.run(
        'helm', 'lint', chart, '--values', values_path, '--values', profile_path,
        *operation_arguments(resource, operation, secret_digest_key)
      )
    end

    def render_chart(release_name, chart, values_path, profile_path, resource, operation = nil, secret_digest_key = nil)
      output = @runner.run(
        'helm', 'template', release_name, chart,
        '--namespace', resource.dig('metadata', 'namespace'),
        '--values', values_path, '--values', profile_path,
        *operation_arguments(resource, operation, secret_digest_key)
      )
      YAML.load_stream(output).compact
    rescue Psych::Exception => error
      raise InvalidRelease, "Helm rendered invalid YAML: #{error.message}"
    end

    def operation_arguments(resource, operation = nil, secret_digest_key = nil)
      id = operation&.fetch('id', nil).to_s
      return [] if id.empty?

      arguments = [
        '--set-string', "releaseOperation.id=#{id}",
        '--set-string', "releaseOperation.ownerUid=#{resource.dig('metadata', 'uid')}"
      ]
      secret_digest = operation[secret_digest_key].to_s if secret_digest_key
      arguments.concat(['--set-string', "secretRolloutToken=#{secret_digest}"]) unless secret_digest.to_s.empty?
      arguments
    end

    def validate_secret_inputs!(resource, operation, rendered, digest_key)
      expected = operation[digest_key].to_s
      raise InvalidRelease, "release input #{digest_key} was not pinned during validation" if expected.empty?

      snapshot = @preflight.validate_secrets!(rendered, resource.dig('metadata', 'namespace'))
      actual = snapshot.fingerprint(rendered)
      return if actual == expected

      raise InvalidRelease, "release input #{digest_key} changed during operation"
    end

    def validate_rendered_contract!(application, execution)
      dependency_preflight = jobs(application, [DEPENDENCY_PREFLIGHT_COMPONENT])
      unless dependency_preflight.length == 1
        raise InvalidRelease, 'application values must enable exactly one dependency preflight Job'
      end
      migration_components = jobs(application, MIGRATION_COMPONENTS).map { |job| job.dig('metadata', 'labels', COMPONENT_LABEL) }
      unless migration_components.sort == MIGRATION_COMPONENTS.sort
        raise InvalidRelease, 'application values must enable every migration Job'
      end
      raise InvalidRelease, 'application values must not enable maintenance mode' unless application.any? { |item| item['kind'] == 'Deployment' }
      raise InvalidRelease, 'application values must enable its smoke test' if jobs(application, ['smoke-test']).empty?
      if jobs(application, [EXECUTION_REGISTRATION_COMPONENT]).empty?
        raise InvalidRelease, 'application values must enable execution Smart Proxy registration'
      end
      raise InvalidRelease, 'execution proxy chart must render exactly one Deployment' unless execution.count { |item| item['kind'] == 'Deployment' } == 1
      raise InvalidRelease, 'execution proxy values must enable its mTLS smoke test' if jobs(execution, ['smoke-test']).empty?
      validate_execution_pair!(application, execution)
    end

    def validate_execution_pair!(application, execution)
      service = execution.find do |item|
        item['kind'] == 'Service' && item.dig('metadata', 'labels', COMPONENT_LABEL) == 'execution-proxy'
      end
      raise InvalidRelease, 'execution proxy Service is missing' unless service

      service_port = Array(service.dig('spec', 'ports')).find { |port| port['name'] == 'https' }
      raise InvalidRelease, 'execution proxy Service has no https port' unless service_port

      registration = jobs(application, [EXECUTION_REGISTRATION_COMPONENT]).first
      registration_env = container_environment(registration)
      expected_url = "https://#{service.dig('metadata', 'name')}:#{service_port.fetch('port')}"
      unless registration_env['EXECUTION_PROXY_URL'] == expected_url
        raise InvalidRelease, "execution proxy registration URL must be #{expected_url}"
      end
      unless registration_env['EXECUTION_PROXY_FEATURES'] == 'Ansible,Dynflow,Script'
        raise InvalidRelease, 'execution proxy registration must require exactly Ansible, Dynflow, and Script'
      end

      application_secret = secret_volume_name(jobs(application, ['smoke-test']).first, 'certificates')
      execution_secret = projected_secret_name(
        jobs(execution, ['smoke-test']).first, 'certificates', %w[client_cert.pem client_key.pem]
      )
      unless application_secret == execution_secret
        raise InvalidRelease, 'execution proxy smoke test must use the application Foreman certificate Secret'
      end

      validate_registration_ingress!(registration, service, execution)
    end

    def container_environment(workload)
      Array(workload.dig('spec', 'template', 'spec', 'containers')).first.fetch('env', []).to_h do |entry|
        [entry['name'], entry['value']]
      end
    end

    def secret_volume_name(workload, volume_name)
      volume = Array(workload.dig('spec', 'template', 'spec', 'volumes')).find { |item| item['name'] == volume_name }
      volume&.dig('secret', 'secretName')
    end

    def projected_secret_name(workload, volume_name, keys)
      volume = Array(workload.dig('spec', 'template', 'spec', 'volumes')).find { |item| item['name'] == volume_name }
      source = Array(volume&.dig('projected', 'sources')).find do |candidate|
        item_keys = Array(candidate.dig('secret', 'items')).map { |item| item['key'] }
        (keys - item_keys).empty?
      end
      source&.dig('secret', 'name')
    end

    def validate_registration_ingress!(registration, service, execution)
      proxy_labels = service.dig('spec', 'selector') || {}
      registration_labels = registration.dig('spec', 'template', 'metadata', 'labels') || {}
      policies = execution.select do |item|
        item['kind'] == 'NetworkPolicy' && Array(item.dig('spec', 'policyTypes')).include?('Ingress') &&
          selector_matches?(item.dig('spec', 'podSelector') || {}, proxy_labels)
      end
      return if policies.empty?

      permitted = policies.any? do |policy|
        Array(policy.dig('spec', 'ingress')).any? do |rule|
          port_allowed = Array(rule['ports']).any? { |port| port['port'] == service.dig('spec', 'ports', 0, 'port') }
          port_allowed && Array(rule['from']).any? do |peer|
            selector_matches?(peer['podSelector'] || {}, registration_labels)
          end
        end
      end
      raise InvalidRelease, 'execution proxy NetworkPolicy rejects its Foreman registration Job' unless permitted
    end

    def selector_matches?(selector, labels)
      matches = (selector['matchLabels'] || {}).all? { |key, value| labels[key] == value }
      expressions = Array(selector['matchExpressions']).all? do |expression|
        value = labels[expression['key']]
        case expression['operator']
        when 'In' then Array(expression['values']).include?(value)
        when 'NotIn' then !Array(expression['values']).include?(value)
        when 'Exists' then labels.key?(expression['key'])
        when 'DoesNotExist' then !labels.key?(expression['key'])
        else false
        end
      end
      matches && expressions
    end

    def upgrade(release_name, chart, values_path, profile_path, resource, operation, secret_digest_key,
                skip_migration_jobs: false)
      phase_arguments = if skip_migration_jobs
                          ['--set', 'releaseOperation.skipMigrationJobs=true']
                        else
                          []
                        end
      @runner.run(
        'helm', 'upgrade', '--install', release_name, chart,
        '--namespace', resource.dig('metadata', 'namespace'),
        '--history-max', '10',
        '--values', values_path, '--values', profile_path,
        *phase_arguments,
        *operation_arguments(resource, operation, secret_digest_key)
      )
    end

    def submit_application_release(resource, operation, context, values_path, message)
      upgrade(
        application_release(resource), @application_chart, values_path,
        context.profiles.application_path, resource, operation,
        APPLICATION_SECRETS_DIGEST,
        skip_migration_jobs: true
      )
      Observation.new(
        state: :pending,
        message: message,
        details: {applicationSubmittedRevision: helm_revision(resource, application_release(resource))}
      )
    end

    def submit_execution_release(resource, operation, context, values_path, message)
      upgrade(
        execution_release(resource), @execution_chart, values_path,
        context.profiles.execution_proxy_path, resource, operation,
        EXECUTION_SECRETS_DIGEST
      )
      Observation.new(
        state: :pending,
        message: message,
        details: {executionProxySubmittedRevision: helm_revision(resource, execution_release(resource))}
      )
    end

    def submit_job_bundle(resource, operation, rendered, expected_jobs, live_jobs)
      dependencies = job_dependencies(rendered, expected_jobs)
      dependencies.each { |dependency| ensure_helm_dependency(resource, dependency) }

      live_names = expected_names(live_jobs)
      expected_jobs.reject { |job| live_names.include?(job.dig('metadata', 'name')) }.each do |job|
        ensure_owned_resource(resource, operation, owned_operation_resource(job, resource), application_release(resource))
      end
    end

    def job_dependencies(rendered, operation_jobs)
      names = MIGRATION_DEPENDENCY_TYPES.keys.to_h { |kind| [kind, []] }
      operation_jobs.each do |job|
        pod_spec = job.dig('spec', 'template', 'spec') || {}
        names['ServiceAccount'] << pod_spec['serviceAccountName'] if pod_spec['serviceAccountName']
        Array(pod_spec['volumes']).each do |volume|
          names['ConfigMap'] << volume.dig('configMap', 'name') if volume.dig('configMap', 'name')
          claim = volume.dig('persistentVolumeClaim', 'claimName')
          names['PersistentVolumeClaim'] << claim if claim
        end
      end

      rendered.select do |item|
        names.fetch(item['kind'], []).include?(item.dig('metadata', 'name'))
      end
    end

    def ensure_helm_dependency(resource, desired)
      namespace = resource.dig('metadata', 'namespace')
      release_name = application_release(resource)
      dependency = Marshal.load(Marshal.dump(desired))
      metadata = dependency.fetch('metadata')
      metadata.delete('namespace')
      metadata['labels'] ||= {}
      metadata['labels']['app.kubernetes.io/managed-by'] = 'Helm'
      metadata['annotations'] ||= {}
      metadata['annotations']['meta.helm.sh/release-name'] = release_name
      metadata['annotations']['meta.helm.sh/release-namespace'] = namespace
      @kubernetes_client.create(namespace, dependency)
    rescue CommandError => error
      raise unless error.stderr.include?('AlreadyExists')

      type = MIGRATION_DEPENDENCY_TYPES.fetch(dependency.fetch('kind'))
      existing = @kubernetes_client.resource(namespace, type, dependency.dig('metadata', 'name'))
      validate_helm_dependency_ownership!(existing, release_name, namespace)
      return unless dependency['kind'] == 'ConfigMap'

      dependency['metadata']['resourceVersion'] = existing.dig('metadata', 'resourceVersion')
      @kubernetes_client.replace(namespace, dependency)
    end

    def validate_helm_dependency_ownership!(resource, release_name, namespace)
      metadata = resource.fetch('metadata')
      owned = metadata.dig('labels', 'app.kubernetes.io/managed-by') == 'Helm' &&
        metadata.dig('annotations', 'meta.helm.sh/release-name') == release_name &&
        metadata.dig('annotations', 'meta.helm.sh/release-namespace') == namespace
      return if owned

      raise InvalidRelease, "release dependency #{metadata.fetch('name')} is not owned by Helm release #{release_name}"
    end

    def ensure_owned_resource(resource, operation, expected, release_name)
      @kubernetes_client.create(resource.dig('metadata', 'namespace'), expected)
    rescue CommandError => error
      raise unless error.stderr.include?('AlreadyExists')

      existing = @kubernetes_client.resource(
        resource.dig('metadata', 'namespace'), expected.fetch('kind').downcase, expected.dig('metadata', 'name')
      )
      labels = existing.dig('metadata', 'labels') || {}
      unless labels[OPERATION_LABEL] == operation.fetch('id') &&
             labels[OWNER_LABEL] == resource.dig('metadata', 'uid') &&
             labels[INSTANCE_LABEL] == release_name
        raise InvalidRelease, "#{expected.fetch('kind')} #{expected.dig('metadata', 'name')} belongs to another release operation"
      end
    end

    def owned_operation_resource(template, resource)
      result = Marshal.load(Marshal.dump(template))
      result['metadata'].delete('namespace')
      result['metadata']['labels']['app.kubernetes.io/managed-by'] = 'foreman-release-controller'
      result['metadata'].fetch('annotations', {}).delete_if { |key, _value| key.start_with?('helm.sh/hook') }
      result['metadata']['ownerReferences'] = [release_owner_reference(resource)]
      result
    end

    def operation_resources(resource, operation, type, instance: application_release(resource))
      @kubernetes_client.resources(
        resource.dig('metadata', 'namespace'), type,
        labels: {
          OPERATION_LABEL => operation.fetch('id'),
          OWNER_LABEL => resource.dig('metadata', 'uid'),
          INSTANCE_LABEL => instance
        }
      )
    end

    def jobs(resources, components)
      resources.select do |item|
        item['kind'] == 'Job' && components.include?(item.dig('metadata', 'labels', COMPONENT_LABEL))
      end
    end

    def expected_names(resources)
      resources.map { |resource| resource.dig('metadata', 'name') }
    end

    def observe_jobs(resources, details: {})
      failed = resources.find { |job| condition_true?(job, 'Failed') }
      if failed
        condition = condition(failed, 'Failed')
        return Observation.new(
          state: :failed,
          message: "Job #{failed.dig('metadata', 'name')} failed: #{condition['reason'] || condition['message'] || 'unknown reason'}"
        )
      end
      incomplete = resources.reject { |job| condition_true?(job, 'Complete') }
      unless incomplete.empty?
        return Observation.new(
          state: :pending,
          message: "waiting for Jobs: #{expected_names(incomplete).join(', ')}"
        )
      end

      Observation.new(state: :succeeded, message: 'Jobs completed successfully', details: details)
    end

    def observe_deployments(expected, live)
      live_by_name = live.to_h { |deployment| [deployment.dig('metadata', 'name'), deployment] }
      missing = expected_names(expected).reject { |name| live_by_name.key?(name) }
      return Observation.new(state: :pending, message: "waiting for Deployments: #{missing.join(', ')}") unless missing.empty?

      expected_names(expected).each do |name|
        deployment = live_by_name.fetch(name)
        progressing = condition(deployment, 'Progressing')
        if progressing && progressing['status'] == 'False'
          return Observation.new(
            state: :failed,
            message: "Deployment #{name} failed: #{progressing['reason'] || progressing['message'] || 'not progressing'}"
          )
        end
        generation = Integer(deployment.dig('metadata', 'generation') || 0)
        observed = Integer(deployment.dig('status', 'observedGeneration') || 0)
        unless observed >= generation && condition_true?(deployment, 'Available')
          return Observation.new(state: :pending, message: "waiting for Deployment #{name} to become available")
        end
        desired = Integer(deployment.dig('spec', 'replicas') || 1)
        replicas = Integer(deployment.dig('status', 'replicas') || 0)
        updated = Integer(deployment.dig('status', 'updatedReplicas') || 0)
        ready = Integer(deployment.dig('status', 'readyReplicas') || 0)
        available = Integer(deployment.dig('status', 'availableReplicas') || 0)
        unavailable = Integer(deployment.dig('status', 'unavailableReplicas') || 0)
        rollout_complete = replicas == desired && updated == desired && ready >= desired &&
          available >= desired && unavailable.zero?
        unless rollout_complete
          return Observation.new(
            state: :pending,
            message: "waiting for Deployment #{name} rollout " \
                     "(#{updated}/#{desired} updated, #{ready}/#{desired} ready, " \
                     "#{available}/#{desired} available, #{unavailable} unavailable)"
          )
        end
      end

      Observation.new(state: :succeeded, message: 'Deployments are available')
    end

    def condition(resource, type)
      Array(resource.dig('status', 'conditions')).find { |candidate| candidate['type'] == type }
    end

    def condition_true?(resource, type)
      condition(resource, type)&.fetch('status', nil) == 'True'
    end

    def terminal_job?(job)
      condition_true?(job, 'Complete') || condition_true?(job, 'Failed')
    end

    def operation_order(operation_id)
      match = operation_id.match(/-g(\d+)(?:-o(\d+))?\z/)
      match ? [Integer(match[1]), Integer(match[2] || 0)] : [-1, -1]
    end

    def declared_resource_drift(resource, rendered)
      namespace = resource.dig('metadata', 'namespace')
      rendered.group_by { |item| item['kind'] }.flat_map do |kind, expected|
        type = DRIFT_RESOURCE_TYPES[kind]
        next [] unless type

        live_by_name = @kubernetes_client.resources(namespace, type).to_h do |item|
          [item.dig('metadata', 'name'), item]
        end
        expected.flat_map do |item|
          name = item.dig('metadata', 'name')
          live = live_by_name[name]
          next ["#{kind}/#{name}"] unless live
          next [] if managed_subset?(managed_projection(item), live)

          ["#{kind}/#{name}:modified"]
        end
      end
    end

    def managed_projection(resource)
      metadata = %w[labels annotations].each_with_object({}) do |field, projected|
        projected[field] = resource.dig('metadata', field) if resource.dig('metadata', field)
      end
      projection = {'metadata' => metadata}
      case resource.fetch('kind')
      when 'ConfigMap'
        %w[data binaryData immutable].each do |field|
          projection[field] = resource[field] if resource.key?(field)
        end
      when 'ServiceAccount'
        %w[automountServiceAccountToken imagePullSecrets].each do |field|
          projection[field] = resource[field] if resource.key?(field)
        end
      else
        projection['spec'] = resource.fetch('spec', {})
      end
      projection
    end

    def managed_subset?(expected, actual)
      case expected
      when Hash
        actual.is_a?(Hash) && expected.all? do |key, value|
          actual.key?(key) && managed_subset?(value, actual[key])
        end
      when Array
        return false unless actual.is_a?(Array)

        if expected.all? { |item| item.is_a?(Hash) }
          expected.all? do |item|
            actual.any? { |candidate| candidate.is_a?(Hash) && managed_subset?(item, candidate) }
          end
        else
          expected == actual
        end
      else
        expected == actual
      end
    end

    def ensure_smoke(resource, operation, stage, source:)
      renderer, release_name = smoke_source(resource, source)
      renderer.call(resource, operation) do |_context, _values_path, resources|
        template = jobs(resources, ['smoke-test']).first
        raise InvalidRelease, "#{source} smoke-test Job is disabled" unless template

        ensure_operation_job(template, resource, operation, stage, release_name)
      end
    end

    def ensure_execution_registration(resource, operation)
      with_rendered_application(resource, operation) do |_context, _values_path, resources|
        template = jobs(resources, [EXECUTION_REGISTRATION_COMPONENT]).first
        raise InvalidRelease, 'execution Smart Proxy registration Job is disabled' unless template

        ensure_operation_job(
          template, resource, operation, 'execution-proxy-registration', application_release(resource)
        )
      end
    end

    def ensure_operation_job(template, resource, operation, stage, release_name)
      expected = operation_job(template, resource, operation, stage, release_name)
      live = operation_resources(resource, operation, 'jobs', instance: release_name).select do |job|
        job.dig('metadata', 'name') == expected.dig('metadata', 'name')
      end
      if live.empty?
        create_operation_job(resource, operation, expected, release_name)
        return Observation.new(state: :pending, message: "#{stage} Job submitted")
      end

      result = observe_jobs(live)
      return result unless result.state == :succeeded

      Observation.new(state: :succeeded, message: "#{stage} passed")
    end

    def create_operation_job(resource, operation, expected, release_name)
      @kubernetes_client.create(resource.dig('metadata', 'namespace'), expected)
    rescue CommandError => error
      raise unless error.stderr.include?('AlreadyExists')

      existing = @kubernetes_client.resource(
        resource.dig('metadata', 'namespace'), 'job', expected.dig('metadata', 'name')
      )
      labels = existing.dig('metadata', 'labels') || {}
      unless labels[OPERATION_LABEL] == operation.fetch('id') &&
             labels[OWNER_LABEL] == resource.dig('metadata', 'uid') &&
             labels[INSTANCE_LABEL] == release_name
        raise InvalidRelease, "Job #{expected.dig('metadata', 'name')} belongs to another release operation"
      end
    end

    def smoke_source(resource, source)
      case source
      when :application
        [method(:with_rendered_application), application_release(resource)]
      when :execution
        [method(:with_rendered_execution), execution_release(resource)]
      else
        raise ArgumentError, "unknown smoke source #{source.inspect}"
      end
    end

    def operation_job(template, resource, operation, stage, release_name)
      job = Marshal.load(Marshal.dump(template))
      job['metadata']['name'] = bounded_name("#{release_name}-#{stage}-#{operation.fetch('id')}")
      job['metadata'].delete('namespace')
      annotations = job.dig('metadata', 'annotations') || {}
      annotations.delete_if { |key, _value| key.start_with?('helm.sh/hook') }
      annotations['foreman-kubernetes.io/verification-stage'] = stage
      job['metadata']['annotations'] = annotations
      job['metadata']['ownerReferences'] = [release_owner_reference(resource)]
      job
    end

    def release_owner_reference(resource)
      {
        'apiVersion' => resource.fetch('apiVersion'),
        'kind' => resource.fetch('kind'),
        'name' => resource.dig('metadata', 'name'),
        'uid' => resource.dig('metadata', 'uid'),
        'controller' => true,
        'blockOwnerDeletion' => true
      }
    end

    def bounded_name(raw)
      return raw if raw.length <= 63

      "#{raw[0, 54].sub(/-+\z/, '')}-#{Digest::SHA256.hexdigest(raw)[0, 8]}"
    end

    def helm_revision(resource, release_name)
      status = JSON.parse(
        @runner.run(
          'helm', 'status', release_name,
          '--namespace', resource.dig('metadata', 'namespace'), '--output=json'
        )
      )
      Integer(status.fetch('version'))
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError => error
      raise InvalidRelease, "cannot determine Helm revision for #{release_name}: #{error.message}"
    end

    def application_release(resource)
      resource.dig('spec', 'application', 'releaseName') || 'foreman'
    end

    def execution_release(resource)
      resource.dig('spec', 'executionProxy', 'releaseName') || 'execution'
    end
  end
end
