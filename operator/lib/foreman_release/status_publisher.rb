# frozen_string_literal: true

module ForemanRelease
  class StatusPublisher
    def initialize(kubernetes_client:, event_recorder:)
      @kubernetes_client = kubernetes_client
      @event_recorder = event_recorder
    end

    def call(resource, status)
      previous_status = resource.fetch('status', {})
      persisted = @kubernetes_client.write_status(resource, status)
      @event_recorder.record(persisted, previous_status, status)
      persisted
    end
  end
end
