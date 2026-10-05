# frozen_string_literal: true

require_relative 'command_runner'
require_relative 'certificate_validator'
require_relative 'manifest_requirements'
require_relative 'release_inputs'
require 'digest'
require 'json'
require 'yaml'

module ForemanRelease
  class SecretSnapshot
    attr_reader :expiration

    def initialize(versions:, expiration: nil)
      @versions = versions
      @expiration = expiration
    end

    def fingerprint(documents)
      requirements = ManifestRequirements.new(documents).secrets
      inputs = requirements.map do |name, keys|
        [name, keys, @versions.fetch(name)]
      end
      Digest::SHA256.hexdigest(JSON.generate(inputs))
    rescue KeyError => error
      raise InvalidRelease, "Secret snapshot is missing #{error.key}"
    end
  end

  class ClusterPreflight
    DEFAULT_STORAGE_ANNOTATIONS = %w[
      storageclass.kubernetes.io/is-default-class
      storageclass.beta.kubernetes.io/is-default-class
    ].freeze

    def initialize(kubernetes_client, runner: CommandRunner.new, certificate_validator: CertificateValidator.new)
      @kubernetes_client = kubernetes_client
      @runner = runner
      @certificate_validator = certificate_validator
    end

    def validate!(documents, namespace)
      requirements = ManifestRequirements.new(documents)
      requirements.cluster_resources.each do |kind, name, contract|
        validate_resource!(namespace, kind, name, contract)
      end
      snapshot = validate_secret_requirements!(requirements, namespace)
      validate_server_dry_run!(documents, namespace)
      snapshot
    end

    def validate_secrets!(documents, namespace)
      validate_secret_requirements!(ManifestRequirements.new(documents), namespace)
    end

    private

    def validate_secret_requirements!(requirements, namespace)
      versions = {}
      expirations = requirements.secrets.each_with_object([]) do |(name, keys), found|
        secret = required_resource(namespace, 'secret', name)
        resource_version = secret.dig('metadata', 'resourceVersion').to_s
        if resource_version.empty?
          raise InvalidRelease, "Secret #{namespace}/#{name} has no resourceVersion"
        end
        versions[name] = resource_version
        missing = keys.reject { |key| secret.fetch('data', {}).key?(key) }
        raise InvalidRelease, "Secret #{namespace}/#{name} is missing keys: #{missing.join(', ')}" unless missing.empty?

        expiration = @certificate_validator.validate_secret!(
          namespace, name, secret, keys,
          required_identities: requirements.certificate_identities.fetch(name, {})
        )
        found << expiration if expiration
      end
      SecretSnapshot.new(versions: versions, expiration: expirations.min)
    end

    def validate_server_dry_run!(documents, namespace)
      manifest = Array(documents).map { |document| YAML.dump(document) }.join
      @runner.run(
        'kubectl', '--namespace', namespace, 'apply', '--dry-run=server', '--filename', '-',
        stdin_data: manifest
      )
    rescue CommandError, CommandTimeout => error
      raise InvalidRelease, "server-side admission dry-run failed: #{error.message}"
    end

    def validate_resource!(namespace, kind, name, contract)
      case kind
      when 'DefaultStorageClass'
        classes = @kubernetes_client.resources(nil, 'storageclasses')
        found = classes.any? do |storage_class|
          annotations = storage_class.dig('metadata', 'annotations') || {}
          DEFAULT_STORAGE_ANNOTATIONS.any? { |annotation| annotations[annotation] == 'true' }
        end
        raise InvalidRelease, 'a rendered PVC requires a default StorageClass, but none is configured' unless found
      when 'StorageClass'
        required_resource(nil, 'storageclass', name)
      when 'IngressClass'
        ingress_class = required_resource(nil, 'ingressclass', name)
        if !contract.to_s.empty? && ingress_class.dig('spec', 'controller') != contract
          raise InvalidRelease, "IngressClass #{name} is not managed by #{contract}"
        end
      when 'APIService'
        api_service = required_resource(nil, 'apiservice', name)
        if contract == 'Available' && !condition_true?(api_service, 'Available')
          raise InvalidRelease, "APIService #{name} is not Available"
        end
      when 'CustomResourceDefinition'
        required_resource(nil, 'customresourcedefinition', name)
      when 'PriorityClass'
        required_resource(nil, 'priorityclass', name)
      when 'NodeScheduling'
        scheduling = JSON.parse(name)
        selector = scheduling.fetch('nodeSelector')
        tolerations = scheduling.fetch('tolerations')
        nodes = @kubernetes_client.resources(nil, 'nodes')
        found = nodes.any? do |node|
          labels = node.dig('metadata', 'labels') || {}
          hard_taints = Array(node.dig('spec', 'taints')).select do |taint|
            %w[NoSchedule NoExecute].include?(taint['effect'])
          end
          node.dig('spec', 'unschedulable') != true && condition_true?(node, 'Ready') &&
            selector.all? { |key, value| labels[key] == value } &&
            hard_taints.all? { |taint| taint_tolerated?(taint, tolerations) }
        end
        unless found
          description = selector.sort.map { |key, value| "#{key}=#{value}" }.join(', ')
          raise InvalidRelease,
                "rendered workloads require a Ready, uncordoned node matching #{description} with tolerated hard taints, but none is available"
        end
      when 'PersistentVolumeClaim'
        claim = required_resource(namespace, 'persistentvolumeclaim', name)
        phase = claim.dig('status', 'phase')
        storage_class_name = claim.dig('spec', 'storageClassName').to_s
        delayed_binding = if phase == 'Pending' && !storage_class_name.empty?
                            storage_class = required_resource(nil, 'storageclass', storage_class_name)
                            storage_class['volumeBindingMode'] == 'WaitForFirstConsumer'
                          else
                            false
                          end
        unless phase == 'Bound' || delayed_binding
          raise InvalidRelease, "required persistentvolumeclaim #{namespace}/#{name} is not Bound"
        end
      when 'ServiceAccount'
        required_resource(namespace, 'serviceaccount', name)
      else
        raise InvalidRelease, "unsupported preflight resource kind: #{kind}"
      end
    end

    def required_resource(namespace, type, name)
      @kubernetes_client.resource(namespace, type, name)
    rescue CommandError
      scope = namespace ? "#{namespace}/" : ''
      raise InvalidRelease, "required #{type} #{scope}#{name} does not exist"
    end

    def condition_true?(resource, type)
      Array(resource.dig('status', 'conditions')).any? do |condition|
        condition['type'] == type && condition['status'] == 'True'
      end
    end

    def taint_tolerated?(taint, tolerations)
      tolerations.any? do |toleration|
        effect = toleration['effect'].to_s
        next false unless effect.empty? || effect == taint['effect']

        operator = toleration.fetch('operator', 'Equal')
        if operator == 'Exists'
          toleration['key'].to_s.empty? || toleration['key'] == taint['key']
        else
          toleration['key'] == taint['key'] && toleration['value'].to_s == taint['value'].to_s
        end
      end
    end
  end
end
