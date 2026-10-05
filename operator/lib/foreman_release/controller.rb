# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'controller_status'

module ForemanRelease
  class Controller
    FINALIZER = 'platform.theforeman.org/release-protection'

    def initialize(namespace:, kubernetes_client:, reconciler:, leader_elector:, poll_seconds: 5,
                   sleeper: ->(seconds) { sleep(seconds) }, output: $stdout, status: ControllerStatus.new)
      raise ArgumentError, 'controller namespace is required' if namespace.to_s.empty?
      raise ArgumentError, 'poll interval must be at least one second' if poll_seconds < 1

      @namespace = namespace
      @kubernetes_client = kubernetes_client
      @reconciler = reconciler
      @leader_elector = leader_elector
      @poll_seconds = poll_seconds
      @sleeper = sleeper
      @output = output
      @status = status
      @stopping = false
      @leadership_state = nil
    end

    def run
      @status.started
      log('info', 'controller_started', namespace: @namespace, pollSeconds: @poll_seconds)
      begin
        until @stopping
          run_once
          @sleeper.call(@poll_seconds) unless @stopping
        end
      ensure
        @leader_elector.release
        @status.stopped
      end
      log('info', 'controller_stopped', namespace: @namespace)
    end

    def run_once
      leadership = @leader_elector.acquire
      unless leadership.state == :succeeded
        log_leadership('standby', leadership.message)
        @status.cycle_succeeded
        return :standby
      end
      log_leadership('leader', leadership.message)
      releases = @kubernetes_client.releases(@namespace)
      @status.releases_observed(releases)
      releases.each do |resource|
        reconcile(resource)
      end
      @status.cycle_succeeded
      :leader
    rescue StandardError => error
      @status.cycle_failed
      log('error', 'controller_cycle_failed', error: error.class.name, message: error.message)
      :failed
    end

    def stop
      @stopping = true
    end

    private

    def log_leadership(state, message)
      return if @leadership_state == state

      @leadership_state = state
      @status.role_changed(state)
      log('info', 'leadership_changed', state: state, message: message)
    end

    def reconcile(resource)
      name = resource.dig('metadata', 'name').to_s
      if resource.dig('metadata', 'deletionTimestamp')
        result = @reconciler.quiesce(resource)
        if result == :safe
          @kubernetes_client.remove_finalizer(resource, FINALIZER)
          log('info', 'release_finalized', release: name)
        else
          log('info', 'release_deletion_waiting', release: name, result: result)
        end
        return
      end

      unless Array(resource.dig('metadata', 'finalizers')).include?(FINALIZER)
        @kubernetes_client.ensure_finalizer(resource, FINALIZER)
        log('info', 'release_finalizer_added', release: name)
        return
      end

      result = @reconciler.reconcile(resource)
      log(
        'info', 'release_reconciled',
        release: name,
        generation: resource.dig('metadata', 'generation'),
        phase: resource.dig('status', 'phase') || 'Pending',
        result: result
      )
    rescue StandardError => error
      log(
        'error', 'release_reconcile_failed',
        release: name,
        error: error.class.name,
        message: error.message
      )
    end

    def log(level, event, fields)
      @output.puts(JSON.generate({level: level, event: event, time: Time.now.utc.iso8601}.merge(fields)))
      @output.flush
    end
  end
end
