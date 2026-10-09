# frozen_string_literal: true

module ReleaseJobStage
  DEPENDENCY_KINDS = %w[ConfigMap PersistentVolumeClaim ServiceAccount].freeze

  module_function

  def render(documents:, components:, expected_count:, stage_name:, release_name:, release_namespace:)
    jobs = documents.select do |item|
      item['kind'] == 'Job' && components.include?(item.dig('metadata', 'labels', 'app.kubernetes.io/component'))
    end
    abort "rendered application must contain exactly #{expected_count} #{stage_name} Job#{'s' unless expected_count == 1}" unless jobs.length == expected_count

    references = DEPENDENCY_KINDS.to_h { |kind| [kind, []] }
    jobs.each do |job|
      pod_spec = job.dig('spec', 'template', 'spec') || {}
      references['ServiceAccount'] << pod_spec['serviceAccountName'] if pod_spec['serviceAccountName']
      Array(pod_spec['volumes']).each do |volume|
        references['ConfigMap'] << volume.dig('configMap', 'name') if volume.dig('configMap', 'name')
        claim = volume.dig('persistentVolumeClaim', 'claimName')
        references['PersistentVolumeClaim'] << claim if claim
      end
    end
    references.each_value(&:uniq!)

    dependencies = documents.select do |item|
      references.fetch(item['kind'], []).include?(item.dig('metadata', 'name'))
    end
    references.each do |kind, names|
      present = dependencies.select { |item| item['kind'] == kind }.map { |item| item.dig('metadata', 'name') }
      missing = names - present
      # PVCs and ServiceAccounts may be supplied by the platform and are verified
      # by the release preflight. Chart-owned dependencies are staged for Helm
      # adoption so the later release can take them over without a conflict.
      next if %w[PersistentVolumeClaim ServiceAccount].include?(kind)

      abort "#{stage_name} render is missing #{kind}: #{missing.join(', ')}" unless missing.empty?
    end

    dependencies.each do |dependency|
      metadata = dependency.fetch('metadata')
      metadata['labels'] ||= {}
      metadata['labels']['app.kubernetes.io/managed-by'] = 'Helm'
      metadata['annotations'] ||= {}
      metadata['annotations']['meta.helm.sh/release-name'] = release_name
      metadata['annotations']['meta.helm.sh/release-namespace'] = release_namespace
    end

    jobs.each do |job|
      metadata = job.fetch('metadata')
      metadata['labels'] ||= {}
      metadata['labels']['app.kubernetes.io/managed-by'] = 'foreman-release-script'
      metadata.fetch('annotations', {}).delete_if { |key, _value| key.start_with?('helm.sh/hook') }
      job.fetch('spec')['ttlSecondsAfterFinished'] = 3600
    end

    dependencies + jobs
  end
end
