# frozen_string_literal: true

require 'json'
require 'set'

module ForemanRelease
  class ManifestRequirements
    def initialize(documents)
      @documents = Array(documents).select { |document| document.is_a?(Hash) }
      @rendered = @documents.each_with_object(Set.new) do |document, identities|
        name = document.dig('metadata', 'name')
        identities << [document['kind'], name] if document['kind'] && name
      end
    end

    def cluster_resources
      requirements = Set.new
      @documents.each do |document|
        add_document_requirement(requirements, document)
        pod_spec = pod_spec_for(document)
        next unless pod_spec.is_a?(Hash)

        service_account = pod_spec['serviceAccountName'].to_s
        if !service_account.empty? && !@rendered.include?(['ServiceAccount', service_account])
          requirements << ['ServiceAccount', service_account]
        end
        priority_class = pod_spec['priorityClassName'].to_s
        requirements << ['PriorityClass', priority_class] unless priority_class.empty?
        scheduling = scheduling_requirement(pod_spec)
        unless scheduling.nil?
          requirements << ['NodeScheduling', JSON.generate(scheduling)]
        end
        Array(pod_spec['volumes']).each do |volume|
          claim_name = volume.dig('persistentVolumeClaim', 'claimName').to_s
          next if claim_name.empty? || @rendered.include?(['PersistentVolumeClaim', claim_name])

          requirements << ['PersistentVolumeClaim', claim_name]
        end
      end
      requirements.to_a.sort
    end

    def secrets
      references = Hash.new { |secrets, name| secrets[name] = Set.new }
      rendered_secrets = @documents.each_with_object(Set.new) do |document, names|
        name = document.dig('metadata', 'name')
        names << name if document['kind'] == 'Secret' && name
      end
      @documents.each do |document|
        add_ingress_secrets(references, document)
        pod_spec = pod_spec_for(document)
        next unless pod_spec.is_a?(Hash)

        add_pod_secrets(references, pod_spec)
      end
      certificate_identities.each do |name, identities|
        references[name].merge(identities.keys)
      end
      rendered_secrets.each { |name| references.delete(name) }
      references.transform_values { |keys| keys.to_a.sort }.sort.to_h
    end

    def certificate_identities
      references = Hash.new do |secrets, name|
        secrets[name] = Hash.new { |keys, key| keys[key] = Set.new }
      end
      @documents.each do |document|
        case document['kind']
        when 'Ingress'
          rule_hosts = Array(document.dig('spec', 'rules')).each_with_object([]) do |rule, hosts|
            host = rule['host'].to_s
            hosts << host unless host.empty?
          end
          Array(document.dig('spec', 'tls')).each do |tls|
            name = tls['secretName'].to_s
            next if name.empty?

            hosts = Array(tls['hosts']).map(&:to_s).reject(&:empty?)
            references[name]['tls.crt'].merge(hosts.empty? ? rule_hosts : hosts)
          end
        when 'Service'
          add_service_certificate_identity(references, document)
        end
      end
      references.transform_values do |identities|
        identities.transform_values { |names| names.to_a.sort }.sort.to_h
      end.sort.to_h
    end

    private

    def scheduling_requirement(pod_spec)
      node_selector = pod_spec['nodeSelector']
      return unless node_selector.is_a?(Hash) && !node_selector.empty?

      tolerations = Array(pod_spec['tolerations']).each_with_object([]) do |toleration, normalized|
        normalized << toleration.sort.to_h if toleration.is_a?(Hash)
      end
      {
        'nodeSelector' => node_selector.sort.to_h,
        'tolerations' => tolerations.sort_by { |toleration| JSON.generate(toleration) }
      }
    end

    def add_document_requirement(requirements, document)
      case document['kind']
      when 'PrometheusRule'
        requirements << ['CustomResourceDefinition', 'prometheusrules.monitoring.coreos.com']
      when 'ServiceMonitor'
        requirements << ['CustomResourceDefinition', 'servicemonitors.monitoring.coreos.com']
      when 'HorizontalPodAutoscaler'
        metrics = Array(document.dig('spec', 'metrics')).map { |metric| metric['type'] }
        requirements << ['APIService', 'v1beta1.metrics.k8s.io', 'Available'] unless (metrics & %w[Resource ContainerResource]).empty?
      when 'PersistentVolumeClaim'
        storage_class = document.dig('spec', 'storageClassName').to_s
        requirements << (storage_class.empty? ? ['DefaultStorageClass', ''] : ['StorageClass', storage_class])
      when 'Ingress'
        ingress_class = document.dig('spec', 'ingressClassName').to_s
        return if ingress_class.empty?

        requirement = ['IngressClass', ingress_class]
        controller = document.dig('metadata', 'annotations', 'foreman-kubernetes.io/required-ingress-controller').to_s
        requirement << controller unless controller.empty?
        requirements << requirement
      end
    end

    def add_ingress_secrets(references, document)
      return unless document['kind'] == 'Ingress'

      Array(document.dig('spec', 'tls')).each do |tls|
        name = tls['secretName'].to_s
        references[name].merge(%w[tls.crt tls.key]) unless name.empty?
      end
      client_ca_reference = document.dig('metadata', 'annotations', 'nginx.ingress.kubernetes.io/auth-tls-secret').to_s
      return if client_ca_reference.empty?

      references[client_ca_reference.split('/', 2).last] << 'ca.crt'
    end

    def add_service_certificate_identity(references, document)
      annotations = document.dig('metadata', 'annotations') || {}
      values = %w[certificate-secret certificate-key certificate-dns-name].map do |suffix|
        annotations["foreman-kubernetes.io/#{suffix}"].to_s
      end
      return if values.all?(&:empty?)

      if values.any?(&:empty?)
        raise ArgumentError,
              "Service #{document.dig('metadata', 'name')} has an incomplete certificate identity contract"
      end

      secret, key, dns_name = values
      references[secret][key] << dns_name
    end

    def add_pod_secrets(references, pod_spec)
      Array(pod_spec['imagePullSecrets']).each do |secret|
        add_reference(references, secret, name_key: 'name')
      end
      secret_volumes = direct_secret_volumes(pod_spec, references)
      %w[initContainers containers ephemeralContainers].each do |container_type|
        Array(pod_spec[container_type]).each do |container|
          Array(container['envFrom']).each do |source|
            add_reference(references, source['secretRef'], name_key: 'name')
          end
          Array(container['env']).each do |environment|
            add_reference(
              references, environment.dig('valueFrom', 'secretKeyRef'),
              name_key: 'name', key_key: 'key'
            )
          end
          Array(container['volumeMounts']).each do |mount|
            add_secret_subpath_reference(references, secret_volumes, mount)
          end
        end
      end
      Array(pod_spec['volumes']).each do |volume|
        Array(volume.dig('projected', 'sources')).each do |source|
          add_volume_secret(references, source['secret'], name_key: 'name')
        end
      end
    end

    def direct_secret_volumes(pod_spec, references)
      Array(pod_spec['volumes']).each_with_object({}) do |volume, result|
        secret = volume['secret']
        add_volume_secret(references, secret, name_key: 'secretName')
        next unless secret.is_a?(Hash) && secret['optional'] != true

        secret_name = secret['secretName'].to_s
        volume_name = volume['name'].to_s
        next if secret_name.empty? || volume_name.empty?

        paths = Array(secret['items']).each_with_object({}) do |item, mapped|
          key = item['key'].to_s
          path = item.fetch('path', key).to_s
          mapped[path] = key unless key.empty? || path.empty?
        end
        result[volume_name] = {'name' => secret_name, 'paths' => paths}
      end
    end

    def add_secret_subpath_reference(references, secret_volumes, mount)
      return if mount.key?('subPathExpr')

      sub_path = mount['subPath'].to_s
      volume = secret_volumes[mount['name'].to_s]
      return if sub_path.empty? || volume.nil?

      paths = volume.fetch('paths')
      key = paths.empty? ? sub_path : paths[sub_path]
      references[volume.fetch('name')] << key unless key.to_s.empty?
    end

    def add_volume_secret(references, secret, name_key:)
      add_reference(references, secret, name_key: name_key)
      return unless secret.is_a?(Hash) && secret['optional'] != true

      name = secret[name_key].to_s
      Array(secret['items']).each do |item|
        references[name] << item['key'] if !name.empty? && item['key']
      end
    end

    def add_reference(references, reference, name_key:, key_key: nil)
      return unless reference.is_a?(Hash) && reference['optional'] != true

      name = reference[name_key].to_s
      return if name.empty?

      references[name]
      key = key_key && reference[key_key].to_s
      references[name] << key unless key.nil? || key.empty?
    end

    def pod_spec_for(document)
      case document['kind']
      when 'Pod'
        document['spec']
      when 'Deployment', 'DaemonSet', 'ReplicaSet', 'StatefulSet', 'Job'
        document.dig('spec', 'template', 'spec')
      when 'CronJob'
        document.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
      end
    end
  end
end
