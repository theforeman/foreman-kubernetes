#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'
require 'time'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/controller_status').to_s
require root.join('operator/lib/foreman_release/health_server').to_s

now = Time.iso8601('2026-09-25T00:00:00Z')
status = ForemanRelease::ControllerStatus.new(clock: -> { now })
server = ForemanRelease::HealthServer.new(
  status: status,
  port: 9393,
  readiness_max_staleness_seconds: 30
)

status.started
raise 'live controller failed liveness' unless server.response('GET', '/livez').first == 200
raise 'controller was ready before one successful cycle' unless server.response('GET', '/readyz').first == 503

status.role_changed(:leader)
status.releases_observed([
  {
    'metadata' => {'namespace' => 'platform', 'name' => 'foreman', 'generation' => 4},
    'status' => {
      'phase' => 'Blocked',
      'observedGeneration' => 3,
      'lastDriftCheckError' => 'cannot list Services',
      'certificateExpiryTimestamp' => '2026-10-25T00:00:00Z'
    }
  }
])
status.cycle_succeeded
raise 'successful cycle did not make controller ready' unless server.response('GET', '/readyz').first == 200
metrics = server.response('GET', '/metrics').last
raise 'metrics omitted leadership' unless metrics.include?("foreman_release_controller_leader 1\n")
raise 'metrics omitted successful cycles' unless metrics.include?("result=\"success\"} 1\n")
unless metrics.include?('foreman_release_status{namespace="platform",name="foreman",phase="Blocked"} 1')
  raise 'metrics omitted release phase'
end
unless metrics.include?('foreman_release_metadata_generation{namespace="platform",name="foreman"} 4') &&
       metrics.include?('foreman_release_observed_generation{namespace="platform",name="foreman"} 3')
  raise 'metrics omitted release generation convergence'
end
unless metrics.include?('foreman_release_drift_check_healthy{namespace="platform",name="foreman"} 0')
  raise 'metrics omitted failed Ready drift audit'
end
unless metrics.include?('foreman_release_certificate_expiry_timestamp_seconds{namespace="platform",name="foreman"} 1792886400.0')
  raise 'metrics omitted the earliest certificate expiry'
end

status.cycle_failed
metrics = server.response('GET', '/metrics').last
raise 'metrics retained leadership after a failed API cycle' unless metrics.include?("foreman_release_controller_leader 0\n")
raise 'metrics omitted failed cycles' unless metrics.include?("result=\"failure\"} 1\n")
raise 'failed API cycle retained stale release metrics' if metrics.include?('foreman_release_status{')

status.role_changed(:leader)
status.releases_observed([
  {
    'metadata' => {'namespace' => 'platform', 'name' => "quoted\"release\\name\n", 'generation' => 1},
    'status' => {'phase' => 'Ready', 'observedGeneration' => 1}
  }
])
escaped_metrics = server.response('GET', '/metrics').last
unless escaped_metrics.include?('name="quoted\\"release\\\\name\\n"')
  raise 'release metric label was not escaped'
end
unless escaped_metrics.include?('foreman_release_drift_check_healthy{namespace="platform",name="quoted\\"release\\\\name\\n"} 1')
  raise 'release without a drift error was not reported healthy'
end
status.role_changed(:standby)
raise 'standby retained leader release metrics' if server.response('GET', '/metrics').last.include?('foreman_release_status{')

now += 31
raise 'stale controller remained ready' unless server.response('GET', '/readyz').first == 503
status.stopped
raise 'stopped controller remained live' unless server.response('GET', '/livez').first == 503
raise 'stopped controller retained release metrics' if server.response('GET', '/metrics').last.include?('foreman_release_status{')
raise 'unsupported method was accepted' unless server.response('POST', '/metrics').first == 405

puts 'Controller health endpoint reports liveness, stale readiness, leadership, and cycle metrics.'
