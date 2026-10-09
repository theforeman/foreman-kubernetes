#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'stringio'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/event_recorder').to_s
require root.join('operator/lib/foreman_release/status_publisher').to_s

class EventClient
  attr_reader :calls
  attr_accessor :fail_events

  def initialize
    @calls = []
    @fail_events = false
  end

  def write_status(resource, status)
    @calls << [:status, status]
    Marshal.load(Marshal.dump(resource)).tap do |persisted|
      persisted['metadata']['resourceVersion'] = '43'
      persisted['status'] = status
    end
  end

  def create(namespace, event)
    @calls << [:event, namespace, event]
    raise 'Event API unavailable' if fail_events

    event
  end
end

def release(status = {})
  {
    'apiVersion' => 'platform.theforeman.org/v1alpha1',
    'kind' => 'ForemanRelease',
    'metadata' => {
      'name' => 'foreman',
      'namespace' => 'platform',
      'uid' => '12345678-1234-1234-1234-123456789abc',
      'resourceVersion' => '42'
    },
    'status' => status
  }
end

client = EventClient.new
output = StringIO.new
recorder = ForemanRelease::EventRecorder.new(
  kubernetes_client: client,
  reporting_instance: 'controller-pod-uid',
  clock: -> { Time.utc(2026, 9, 25, 12, 0, 0) },
  output: output
)
publisher = ForemanRelease::StatusPublisher.new(kubernetes_client: client, event_recorder: recorder)

preflight = {
  'phase' => 'Preflight',
  'conditions' => [
    {'type' => 'Progressing', 'status' => 'True', 'reason' => 'Reconcile', 'message' => 'validating release'}
  ]
}
persisted = publisher.call(release, preflight)
raise 'status was not persisted before Event publication' unless client.calls.map(&:first) == %i[status event]
raise 'publisher did not return the persisted resource' unless persisted.dig('metadata', 'resourceVersion') == '43'
event = client.calls.last.fetch(2)
raise 'Event does not target the persisted resource version' unless event.dig('regarding', 'resourceVersion') == '43'
raise 'phase Event has the wrong reason' unless event['reason'] == 'ReleasePreflight'
raise 'phase Event did not preserve the status message' unless event['note'] == 'validating release'
raise 'normal progress was emitted as a warning' unless event['type'] == 'Normal'
raise 'Event reporter is not bound to the controller Pod' unless event['reportingInstance'] == 'controller-pod-uid'

unchanged_calls = client.calls.length
publisher.call(release(preflight), Marshal.load(Marshal.dump(preflight)))
raise 'unchanged status emitted a duplicate Event' unless client.calls.length == unchanged_calls + 1

paused = Marshal.load(Marshal.dump(preflight))
paused['conditions'] << {
  'type' => 'Paused',
  'status' => 'True',
  'reason' => 'ReconciliationPaused',
  'message' => 'release is paused'
}
publisher.call(release(preflight), paused)
pause_event = client.calls.last.fetch(2)
raise 'pause condition did not emit its reason' unless pause_event['reason'] == 'ReconciliationPaused'
raise 'pause Event does not describe the changed condition' unless pause_event['note'] == 'Paused=True: release is paused'

blocked = {
  'phase' => 'Blocked',
  'conditions' => [
    {'type' => 'Degraded', 'status' => 'True', 'reason' => 'ValidationFailed', 'message' => 'profile is invalid'}
  ]
}
publisher.call(release(preflight), blocked)
blocked_event = client.calls.last.fetch(2)
raise 'blocked release did not emit a warning' unless blocked_event['type'] == 'Warning'
raise 'blocked release did not expose the failure' unless blocked_event['note'] == 'profile is invalid'

ready = {
  'phase' => 'Ready',
  'lastDriftCheckMessage' => 'declared release resources are present'
}
failed_audit = ready.merge(
  'lastDriftCheckMessage' => 'Ready drift audit could not be completed',
  'lastDriftCheckError' => 'certificate in Secret foreman-tls has expired'
)
publisher.call(release(ready), failed_audit)
audit_event = client.calls.last.fetch(2)
raise 'failed Ready audit did not emit a warning' unless audit_event['type'] == 'Warning'
raise 'failed Ready audit used the wrong reason' unless audit_event['reason'] == 'ReadyAuditFailed'
unless audit_event['note'] == 'certificate in Secret foreman-tls has expired'
  raise 'failed Ready audit did not expose its status error'
end

audit_calls = client.calls.length
publisher.call(release(failed_audit), Marshal.load(Marshal.dump(failed_audit)))
raise 'unchanged Ready audit failure emitted a duplicate Event' unless client.calls.length == audit_calls + 1

publisher.call(release(failed_audit), ready)
recovered_event = client.calls.last.fetch(2)
raise 'recovered Ready audit did not emit a normal Event' unless recovered_event['type'] == 'Normal'
raise 'recovered Ready audit used the wrong reason' unless recovered_event['reason'] == 'ReadyAuditRecovered'
unless recovered_event['note'] == 'declared release resources are present'
  raise 'recovered Ready audit did not preserve its status message'
end

client.fail_events = true
result = publisher.call(release(preflight), blocked)
raise 'Event failure discarded a successful status write' unless result.dig('status', 'phase') == 'Blocked'
failure_log = JSON.parse(output.string.lines.last)
raise 'Event failure was not logged' unless failure_log['event'] == 'kubernetes_event_publish_failed'
raise 'Event failure log leaked release status' if output.string.include?('profile is invalid')

begin
  ForemanRelease::EventRecorder.new(kubernetes_client: client, reporting_instance: '')
  raise 'empty reporting instance was accepted'
rescue ArgumentError
  nil
end

puts 'Release status publishes deduplicated best-effort Kubernetes Events after durable status writes.'
