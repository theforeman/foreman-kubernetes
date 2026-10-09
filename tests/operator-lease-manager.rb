#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/lease_manager').to_s
require root.join('operator/lib/foreman_release/leader_elector').to_s

class LeaseRunner
  attr_reader :calls

  def initialize
    @lease = nil
    @calls = []
    @fail_next_replace = false
  end

  attr_writer :lease

  def fail_next_replace!
    @fail_next_replace = true
  end

  def run(*command, stdin_data: '')
    @calls << [command, stdin_data]
    action = command.fetch(3)
    case action
    when 'create'
      raise ForemanRelease::CommandError.new(command, 'AlreadyExists', 1) if @lease

      @lease = JSON.parse(stdin_data)
      @lease['metadata']['resourceVersion'] = '1'
      JSON.generate(@lease)
    when 'get'
      raise ForemanRelease::CommandError.new(command, 'NotFound', 1) unless @lease

      JSON.generate(@lease)
    when 'replace'
      if @fail_next_replace
        @fail_next_replace = false
        raise ForemanRelease::CommandError.new(command, 'Conflict', 1)
      end
      replacement = JSON.parse(stdin_data)
      expected = @lease.dig('metadata', 'resourceVersion')
      unless replacement.dig('metadata', 'resourceVersion') == expected
        raise ForemanRelease::CommandError.new(command, 'Conflict', 1)
      end

      replacement['metadata']['resourceVersion'] = (Integer(expected) + 1).to_s
      @lease = replacement
      JSON.generate(@lease)
    else
      raise "unexpected kubectl action: #{action}"
    end
  end

  def lease
    Marshal.load(Marshal.dump(@lease))
  end
end

def release
  {
    'metadata' => {
      'name' => 'foreman',
      'namespace' => 'platform',
      'uid' => '12345678-1234-1234-1234-123456789abc'
    },
    'spec' => {'compatibilitySet' => 'candidate-1'}
  }
end

now = Time.iso8601('2026-09-24T12:00:00Z')
runner = LeaseRunner.new
manager = ForemanRelease::LeaseManager.new(runner: runner, clock: -> { now })
operation = {'id' => '12345678-1234-1234-1234-123456789abc-g1'}

raise 'fresh Lease was not acquired' unless manager.acquire(release, operation).state == :succeeded
raise 'Lease did not record the operation holder' unless runner.lease.dig('spec', 'holderIdentity') == operation['id']
raise 'Lease did not record the release owner' unless runner.lease.dig('metadata', 'labels', 'platform.theforeman.org/release-owner') == release.dig('metadata', 'uid')

now += 20
raise 'owned Lease was not adopted and renewed' unless manager.acquire(release, operation).state == :succeeded
raise 'renewTime did not advance' unless runner.lease.dig('spec', 'renewTime') == now.utc.iso8601

other = runner.lease
other['spec']['holderIdentity'] = 'another-operation'
other['spec']['renewTime'] = now.utc.iso8601
runner.lease = other
raise 'active foreign Lease was not reported busy' unless manager.acquire(release, operation).state == :busy

expired = runner.lease
expired['spec']['renewTime'] = (now - 300).utc.iso8601
runner.lease = expired
raise 'expired Lease was not claimed' unless manager.acquire(release, operation).state == :succeeded
raise 'expired Lease retained its old holder' unless runner.lease.dig('spec', 'holderIdentity') == operation['id']

raise 'owned Lease was not released' unless manager.release(release, operation)
raise 'release deleted instead of retaining the Lease object' unless runner.lease
raise 'released Lease still has a holder' unless runner.lease.dig('spec', 'holderIdentity') == ''
raise 'released Lease was not immediately claimable' unless manager.acquire(release, {'id' => 'next-operation'}).state == :succeeded

foreign = runner.lease
foreign['spec']['holderIdentity'] = 'foreign-operation'
runner.lease = foreign
raise 'release touched a foreign Lease' if manager.release(release, operation)
raise 'foreign Lease holder changed' unless runner.lease.dig('spec', 'holderIdentity') == 'foreign-operation'

invalid = runner.lease
invalid['spec'].delete('renewTime')
invalid['spec'].delete('acquireTime')
runner.lease = invalid
begin
  manager.acquire(release, operation)
  raise 'invalid Lease expiry was accepted'
rescue ForemanRelease::LeaseLost => error
  raise unless error.message.include?('expiration contract')
end

raise 'controller does not share the guarded workflow Lease' unless manager.name(release) == 'foreman-kubernetes-release'
begin
  ForemanRelease::LeaseManager.new(lease_name: 'Invalid_Name')
  raise 'invalid shared Lease name was accepted'
rescue ArgumentError => error
  raise unless error.message.include?('valid DNS label')
end

leader_now = Time.iso8601('2026-09-24T13:00:00Z')
leader_runner = LeaseRunner.new
first_manager = ForemanRelease::LeaseManager.new(
  runner: leader_runner,
  duration_seconds: 30,
  lease_name: 'controller-leader',
  clock: -> { leader_now }
)
second_manager = ForemanRelease::LeaseManager.new(
  runner: leader_runner,
  duration_seconds: 30,
  lease_name: 'controller-leader',
  clock: -> { leader_now }
)
first_leader = ForemanRelease::LeaderElector.new(
  namespace: 'platform',
  identity: '11111111-1111-1111-1111-111111111111',
  lease_manager: first_manager
)
second_leader = ForemanRelease::LeaderElector.new(
  namespace: 'platform',
  identity: '22222222-2222-2222-2222-222222222222',
  lease_manager: second_manager
)
raise 'first controller did not become leader' unless first_leader.acquire.state == :succeeded
raise 'second live controller was not fenced' unless second_leader.acquire.state == :busy
leader_now += 31
raise 'standby did not take over an expired leader Lease' unless second_leader.acquire.state == :succeeded
raise 'stale controller released its successor Lease' if first_leader.release
raise 'takeover did not retain the new Pod identity' unless leader_runner.lease.dig('spec', 'holderIdentity') == '22222222-2222-2222-2222-222222222222'

puts 'ForemanRelease Lease acquisition, leader fencing, takeover, and safe release passed.'
