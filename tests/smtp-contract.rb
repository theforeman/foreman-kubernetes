#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
backup_documents = YAML.load_stream(File.read(ARGV.fetch(1))).compact
config = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name').to_s.end_with?('-foreman-config')
end
settings = config&.dig('data', 'settings.yaml').to_s

{
  ':delivery_method: smtp' => 'SMTP delivery method',
  ':smtp_enable_starttls_auto: true' => 'STARTTLS',
  ':smtp_openssl_verify_mode: peer' => 'TLS peer verification',
  ':smtp_address: "smtp.example.test"' => 'SMTP address',
  ':smtp_port: 587' => 'SMTP port',
  "ENV.fetch('FOREMAN_SMTP_USERNAME')" => 'SMTP username Secret lookup',
  "ENV.fetch('FOREMAN_SMTP_PASSWORD')" => 'SMTP password Secret lookup'
}.each do |needle, description|
  abort "Foreman settings omit #{description}" unless settings.include?(needle)
end

def pod_spec(document)
  case document['kind']
  when 'Deployment', 'Job'
    document.dig('spec', 'template', 'spec')
  when 'CronJob'
    document.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

checked = 0
documents.each do |document|
  spec = pod_spec(document)
  next unless spec

  (Array(spec['initContainers']) + Array(spec['containers'])).each do |container|
    env = Array(container['env']).to_h { |entry| [entry['name'], entry] }
    next unless env.key?('RAILS_ENV')

    {
      'FOREMAN_SMTP_USERNAME' => 'smtp-user',
      'FOREMAN_SMTP_PASSWORD' => 'smtp-password'
    }.each do |name, key|
      reference = env.dig(name, 'valueFrom', 'secretKeyRef')
      unless reference == {'name' => 'foreman-smtp', 'key' => key}
        abort "#{container['name']} has an invalid #{name} reference"
      end
    end
    checked += 1
  end
end
abort 'SMTP contract did not cover any Rails process' if checked.zero?

policy = documents.find do |resource|
  resource['kind'] == 'NetworkPolicy' && resource.dig('metadata', 'name').to_s.end_with?('-foreman-egress')
end
smtp_rule = Array(policy&.dig('spec', 'egress')).find do |rule|
  Array(rule['to']).any? { |peer| peer.dig('ipBlock', 'cidr') == '192.0.2.25/32' }
end
ports = Array(smtp_rule&.fetch('ports', nil)).map { |port| port['port'] }
abort 'Foreman egress does not permit the declared SMTP relay' unless ports == [587]

role = backup_documents.find do |resource|
  resource['kind'] == 'Role' && resource.dig('metadata', 'name').to_s.end_with?('-recovery')
end
secret_rule = Array(role&.fetch('rules', nil)).find { |rule| Array(rule['resources']).include?('secrets') }
unless Array(secret_rule&.fetch('resourceNames', nil)).include?('foreman-smtp')
  abort 'recovery escrow cannot read the SMTP Secret'
end

backup = backup_documents.find { |resource| resource['kind'] == 'Job' }
container = backup&.dig('spec', 'template', 'spec', 'containers', 0)
secret_names = Array(container&.fetch('env', nil)).find { |entry| entry['name'] == 'BACKUP_SECRET_NAMES' }
abort 'recovery escrow does not list the SMTP Secret' unless secret_names&.fetch('value', '').split.include?('foreman-smtp')

puts "Authenticated SMTP reaches #{checked} Rails containers through one declared relay."
