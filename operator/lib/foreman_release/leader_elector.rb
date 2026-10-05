# frozen_string_literal: true

require_relative 'lease_manager'

module ForemanRelease
  class LeaderElector
    def initialize(namespace:, identity:, lease_manager:)
      raise ArgumentError, 'leader namespace is required' if namespace.to_s.empty?
      raise ArgumentError, 'leader identity is required' if identity.to_s.empty?

      @lease_manager = lease_manager
      @resource = {
        'metadata' => {
          'name' => 'foreman-release-controller',
          'namespace' => namespace,
          'uid' => identity
        },
        'spec' => {'compatibilitySet' => 'controller-leader'}
      }
      @operation = {'id' => identity}
    end

    def acquire
      @lease_manager.acquire(@resource, @operation)
    end

    def release
      @lease_manager.release(@resource, @operation)
    end
  end
end
