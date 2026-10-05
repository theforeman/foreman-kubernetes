#!/usr/bin/env ruby
# frozen_string_literal: true

script = File.expand_path('../charts/foreman-stack/files/foreman-readiness.rb', __dir__)
require script

healthy = {
  'results' => {
    'foreman' => {
      'database' => {'active' => true},
      'cache' => {'servers' => [{'status' => 'ok'}]},
    },
    'katello' => {'status' => 'ok'},
  },
}

ForemanReadiness.validate!(healthy.fetch('results'))

{
  'inactive database' => ->(status) { status['results']['foreman']['database']['active'] = false },
  'missing cache' => ->(status) { status['results']['foreman'].delete('cache') },
  'failed cache' => ->(status) { status['results']['foreman']['cache']['servers'][0]['status'] = 'FAIL' },
  'failed Katello dependency' => ->(status) { status['results']['katello']['status'] = 'FAIL' },
}.each do |name, mutate|
  unhealthy = Marshal.load(Marshal.dump(healthy))
  mutate.call(unhealthy)
  begin
    ForemanReadiness.validate!(unhealthy.fetch('results'))
  rescue RuntimeError
    next
  end
  abort "#{name} was accepted"
end

puts 'Foreman readiness accepts healthy status and rejects dependency failures.'
