#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
job = documents.find do |resource|
  resource['kind'] == 'Job' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'execution-proxy-registration'
end
abort 'execution Smart Proxy registration Job is missing' unless job
abort 'registration must remain an explicit post-proxy test hook' unless job.dig('metadata', 'annotations', 'helm.sh/hook') == 'test'

container = job.dig('spec', 'template', 'spec', 'containers', 0)
script = Array(container['command']).join("\n")
environment = Array(container['env']).to_h { |entry| [entry['name'], entry['value']] }
abort 'registration does not target the paired proxy Service' unless environment['EXECUTION_PROXY_URL'] ==
                                                                  'https://execution-foreman-execution-proxy:8443'
abort 'registration accepts the wrong feature set' unless environment['EXECUTION_PROXY_FEATURES'] == 'Ansible,Dynflow,Script'
abort 'registration does not run as Foreman system administrator' unless script.include?('User.as_anonymous_admin do')
abort 'registration is not idempotent by both URL and name' unless script.include?('by_url || by_name || SmartProxy.new')
abort 'registration does not reject split name/URL ownership' unless script.include?('by_url.id != by_name.id')
abort 'registration does not require exact associated features' unless script.include?('proxy.features.reload.pluck(:name).sort')

policies = documents.select { |resource| resource['kind'] == 'NetworkPolicy' }
egress = policies.find { |resource| resource.dig('metadata', 'name') == 'foreman-foreman-stack-foreman-egress' }
registration_selected = Array(egress&.dig('spec', 'podSelector', 'matchExpressions')).any? do |expression|
  expression['key'] == 'app.kubernetes.io/component' && Array(expression['values']).include?('execution-proxy-registration')
end
abort 'registration Job is not selected by Foreman egress policy' unless registration_selected
proxy_rule = Array(egress.dig('spec', 'egress')).find do |rule|
  Array(rule['to']).any? do |peer|
    peer.dig('podSelector', 'matchLabels', 'app.kubernetes.io/instance') == 'execution' &&
      peer.dig('podSelector', 'matchLabels', 'app.kubernetes.io/component') == 'execution-proxy'
  end
end
abort 'registration Job cannot reach the paired execution proxy' unless Array(proxy_rule&.fetch('ports', nil)).any? do |port|
  port['port'] == 8443
end

puts 'Execution proxy registration is idempotent, feature-gated, and network-bounded.'
