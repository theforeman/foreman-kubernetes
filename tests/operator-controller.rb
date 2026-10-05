#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'stringio'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/controller').to_s

class ControllerClient
  attr_accessor :error
  attr_reader :added_finalizers, :removed_finalizers

  def initialize(releases)
    @releases = releases
    @error = nil
    @added_finalizers = []
    @removed_finalizers = []
  end

  def releases(namespace)
    raise @error if @error
    raise 'controller escaped its namespace' unless namespace == 'platform'

    @releases
  end

  def ensure_finalizer(resource, finalizer)
    @added_finalizers << [resource.dig('metadata', 'name'), finalizer]
    resource
  end

  def remove_finalizer(resource, finalizer)
    @removed_finalizers << [resource.dig('metadata', 'name'), finalizer]
    resource
  end
end

class ControllerReconciler
  attr_reader :names, :quiesced

  def initialize
    @names = []
    @quiesced = []
  end

  def reconcile(resource)
    name = resource.dig('metadata', 'name')
    @names << name
    raise 'isolated failure' if name == 'broken'

    :requeue
  end

  def quiesce(resource)
    @quiesced << resource.dig('metadata', 'name')
    :safe
  end
end

Leadership = Struct.new(:state, :message, keyword_init: true)

class ControllerLeader
  attr_reader :acquisitions, :releases
  attr_accessor :state

  def initialize(state = :succeeded)
    @state = state
    @acquisitions = 0
    @releases = 0
  end

  def acquire
    @acquisitions += 1
    Leadership.new(state: @state, message: "leadership is #{@state}")
  end

  def release
    @releases += 1
    true
  end
end

releases = %w[foreman broken second].map do |name|
  {
    'metadata' => {
      'name' => name,
      'generation' => 1,
      'finalizers' => [ForemanRelease::Controller::FINALIZER]
    },
    'status' => {'phase' => 'Preflight'}
  }
end
client = ControllerClient.new(releases)
reconciler = ControllerReconciler.new
output = StringIO.new
leader = ControllerLeader.new
controller_status = ForemanRelease::ControllerStatus.new
controller = ForemanRelease::Controller.new(
  namespace: 'platform',
  kubernetes_client: client,
  reconciler: reconciler,
  leader_elector: leader,
  status: controller_status,
  output: output
)
controller.run_once
raise 'one failed resource stopped the reconciliation batch' unless reconciler.names == %w[foreman broken second]
raise 'leader cycle was not published to health state' unless controller_status.snapshot.values_at(:role, :successful_cycles) == [:leader, 1]
unless controller_status.snapshot.fetch(:releases).map { |release| release.fetch(:name) } == %w[broken foreman second]
  raise 'leader did not publish its observed release inventory'
end

events = output.string.lines.map { |line| JSON.parse(line) }
raise 'successful reconciliation was not logged' unless events.any? { |event| event['event'] == 'release_reconciled' && event['release'] == 'foreman' }
failure = events.find { |event| event['event'] == 'release_reconcile_failed' }
raise 'per-resource failure was not logged' unless failure && failure['release'] == 'broken'
raise 'controller log exposed a release spec' if events.any? { |event| event.key?('spec') }

standby_reconciler = ControllerReconciler.new
standby_leader = ControllerLeader.new(:busy)
standby_status = ForemanRelease::ControllerStatus.new
standby = ForemanRelease::Controller.new(
  namespace: 'platform',
  kubernetes_client: ControllerClient.new(releases),
  reconciler: standby_reconciler,
  leader_elector: standby_leader,
  status: standby_status,
  output: StringIO.new
)
raise 'standby controller did not skip reconciliation' unless standby.run_once == :standby
raise 'standby controller reconciled a release' unless standby_reconciler.names.empty?
raise 'standby cycle was not published to health state' unless standby_status.snapshot.values_at(:role, :successful_cycles) == [:standby, 1]
raise 'standby published stale release inventory' unless standby_status.snapshot.fetch(:releases).empty?

client.error = RuntimeError.new('API unavailable')
controller.run_once
events = output.string.lines.map { |line| JSON.parse(line) }
raise 'controller cycle failure was not isolated and logged' unless events.last['event'] == 'controller_cycle_failed'
raise 'failed cycle did not clear leadership health' unless controller_status.snapshot.values_at(:role, :failed_cycles) == [:unknown, 1]
raise 'failed API cycle retained stale release inventory' unless controller_status.snapshot.fetch(:releases).empty?

unprotected = {'metadata' => {'name' => 'new-release', 'generation' => 1}, 'status' => {'phase' => 'Pending'}}
protection_client = ControllerClient.new([unprotected])
protection_reconciler = ControllerReconciler.new
protection_controller = ForemanRelease::Controller.new(
  namespace: 'platform',
  kubernetes_client: protection_client,
  reconciler: protection_reconciler,
  leader_elector: ControllerLeader.new,
  output: StringIO.new
)
protection_controller.run_once
raise 'unprotected release started work before finalizer persistence' unless protection_reconciler.names.empty?
raise 'new release did not receive its protection finalizer' unless protection_client.added_finalizers == [
  ['new-release', ForemanRelease::Controller::FINALIZER]
]

deleting = {
  'metadata' => {
    'name' => 'retiring',
    'generation' => 1,
    'deletionTimestamp' => '2026-09-25T01:00:00Z',
    'finalizers' => [ForemanRelease::Controller::FINALIZER]
  },
  'status' => {'phase' => 'Migrating'}
}
deletion_client = ControllerClient.new([deleting])
deletion_reconciler = ControllerReconciler.new
deletion_controller = ForemanRelease::Controller.new(
  namespace: 'platform',
  kubernetes_client: deletion_client,
  reconciler: deletion_reconciler,
  leader_elector: ControllerLeader.new,
  output: StringIO.new
)
deletion_controller.run_once
raise 'deleting release was reconciled as a normal release' unless deletion_reconciler.names.empty?
raise 'deleting release was not quiesced' unless deletion_reconciler.quiesced == ['retiring']
raise 'safe deleting release retained its finalizer' unless deletion_client.removed_finalizers == [
  ['retiring', ForemanRelease::Controller::FINALIZER]
]

ticks = []
looping_client = ControllerClient.new([])
looping = nil
looping = ForemanRelease::Controller.new(
  namespace: 'platform',
  kubernetes_client: looping_client,
  reconciler: reconciler,
  leader_elector: leader,
  poll_seconds: 3,
  sleeper: lambda do |seconds|
    ticks << seconds
    looping.stop
  end,
  output: StringIO.new
)
looping.run
raise 'controller ignored its poll interval or graceful stop' unless ticks == [3]
raise 'controller did not relinquish leadership during shutdown' unless leader.releases == 1

puts 'Controller isolates release failures and stops gracefully.'
