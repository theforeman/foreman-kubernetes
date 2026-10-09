#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/leader_elector').to_s

class RecordingLeaderLease
  attr_reader :acquired, :released

  def acquire(resource, operation)
    @acquired = [resource, operation]
    ForemanRelease::Observation.new(state: :succeeded, message: 'leader')
  end

  def release(resource, operation)
    @released = [resource, operation]
    true
  end
end

lease = RecordingLeaderLease.new
elector = ForemanRelease::LeaderElector.new(
  namespace: 'platform',
  identity: '12345678-1234-1234-1234-123456789abc',
  lease_manager: lease
)
raise 'leader Lease was not acquired' unless elector.acquire.state == :succeeded
resource, operation = lease.acquired
raise 'leader Lease escaped its namespace' unless resource.dig('metadata', 'namespace') == 'platform'
raise 'leader identity is not unique to the Pod' unless operation['id'] == '12345678-1234-1234-1234-123456789abc'
raise 'leader resource did not use the Pod identity' unless resource.dig('metadata', 'uid') == operation['id']
raise 'leader Lease was not released' unless elector.release
raise 'release used another identity' unless lease.released.last == operation

begin
  ForemanRelease::LeaderElector.new(namespace: 'platform', identity: '', lease_manager: lease)
  raise 'empty leader identity was accepted'
rescue ArgumentError => error
  raise unless error.message.include?('identity')
end

puts 'Leader election uses one namespaced Lease and a unique Pod identity.'
