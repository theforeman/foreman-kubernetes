# frozen_string_literal: true

require 'socket'

module ForemanRelease
  class HealthServer
    STATUS_TEXT = {200 => 'OK', 404 => 'Not Found', 405 => 'Method Not Allowed', 503 => 'Service Unavailable'}.freeze

    def initialize(status:, port:, readiness_max_staleness_seconds:, bind_address: '0.0.0.0')
      raise ArgumentError, 'health port must be non-negative' if port.negative?
      raise ArgumentError, 'readiness staleness must be positive' unless readiness_max_staleness_seconds.positive?

      @status = status
      @port = port
      @readiness_max_staleness_seconds = readiness_max_staleness_seconds
      @bind_address = bind_address
      @stopping = false
    end

    def start
      @server = TCPServer.new(@bind_address, @port)
      @thread = Thread.new { serve }
      @thread.report_on_exception = true
      self
    end

    def stop
      @stopping = true
      @server&.close
      @thread&.join(2)
    end

    def port
      @server&.local_address&.ip_port || @port
    end

    def response(method, path)
      return [405, 'text/plain; charset=utf-8', "method not allowed\n"] unless method == 'GET'

      snapshot = @status.snapshot
      case path
      when '/livez'
        probe(snapshot[:running], 'live')
      when '/readyz'
        probe(ready?(snapshot), 'ready')
      when '/metrics'
        [200, 'text/plain; version=0.0.4; charset=utf-8', metrics(snapshot)]
      else
        [404, 'text/plain; charset=utf-8', "not found\n"]
      end
    end

    private

    def serve
      loop do
        break if @stopping

        client = @server.accept
        handle(client)
      rescue IOError, Errno::EBADF
        break if @stopping

        raise
      end
    end

    def handle(client)
      return unless IO.select([client], nil, nil, 1)

      method, path, = client.gets.to_s.split(' ', 3)
      code, content_type, body = response(method, path)
      client.write(
        "HTTP/1.1 #{code} #{STATUS_TEXT.fetch(code)}\r\n" \
        "Content-Type: #{content_type}\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n\r\n#{body}"
      )
    rescue Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      client.close
    end

    def probe(success, word)
      success ? [200, 'text/plain; charset=utf-8', "#{word}\n"] : [503, 'text/plain; charset=utf-8', "not #{word}\n"]
    end

    def ready?(snapshot)
      return false unless snapshot[:running] && snapshot[:last_success_at]

      snapshot[:observed_at] - snapshot[:last_success_at] <= @readiness_max_staleness_seconds
    end

    def metrics(snapshot)
      last_success = snapshot[:last_success_at]&.to_f || 0
      controller_metrics = <<~METRICS
        # HELP foreman_release_controller_running Whether the controller loop is running.
        # TYPE foreman_release_controller_running gauge
        foreman_release_controller_running #{snapshot[:running] ? 1 : 0}
        # HELP foreman_release_controller_ready Whether a reconciliation cycle succeeded recently.
        # TYPE foreman_release_controller_ready gauge
        foreman_release_controller_ready #{ready?(snapshot) ? 1 : 0}
        # HELP foreman_release_controller_leader Whether this candidate most recently held leadership.
        # TYPE foreman_release_controller_leader gauge
        foreman_release_controller_leader #{snapshot[:role] == :leader ? 1 : 0}
        # HELP foreman_release_controller_cycles_total Reconciliation cycles by result.
        # TYPE foreman_release_controller_cycles_total counter
        foreman_release_controller_cycles_total{result="success"} #{snapshot[:successful_cycles]}
        foreman_release_controller_cycles_total{result="failure"} #{snapshot[:failed_cycles]}
        # HELP foreman_release_controller_last_success_timestamp_seconds Last successful cycle as Unix time.
        # TYPE foreman_release_controller_last_success_timestamp_seconds gauge
        foreman_release_controller_last_success_timestamp_seconds #{last_success}
      METRICS
      release_metrics = Array(snapshot[:releases]).map do |release|
        labels = %i[namespace name phase].map do |key|
          %(#{key}="#{escape_label(release.fetch(key))}")
        end.join(',')
        identity = %i[namespace name].map do |key|
          %(#{key}="#{escape_label(release.fetch(key))}")
        end.join(',')
        certificate_expiry = if release.fetch(:certificate_expiry_timestamp_seconds)
                               "foreman_release_certificate_expiry_timestamp_seconds{#{identity}} " \
                                 "#{release.fetch(:certificate_expiry_timestamp_seconds)}\n"
                             else
                               ''
                             end
        <<~RELEASE + certificate_expiry
          foreman_release_status{#{labels}} 1
          foreman_release_metadata_generation{#{identity}} #{release.fetch(:generation)}
          foreman_release_observed_generation{#{identity}} #{release.fetch(:observed_generation)}
          foreman_release_drift_check_healthy{#{identity}} #{release.fetch(:drift_check_healthy) ? 1 : 0}
          foreman_release_deleting{#{identity}} #{release.fetch(:deleting) ? 1 : 0}
        RELEASE
      end.join
      return controller_metrics if release_metrics.empty?

      controller_metrics + <<~METRICS + release_metrics
        # HELP foreman_release_status Current ForemanRelease phase; exactly one series exists per observed release.
        # TYPE foreman_release_status gauge
        # HELP foreman_release_metadata_generation Desired ForemanRelease generation.
        # TYPE foreman_release_metadata_generation gauge
        # HELP foreman_release_observed_generation ForemanRelease generation acknowledged by the controller.
        # TYPE foreman_release_observed_generation gauge
        # HELP foreman_release_drift_check_healthy Whether the most recent Ready drift audit completed successfully.
        # TYPE foreman_release_drift_check_healthy gauge
        # HELP foreman_release_certificate_expiry_timestamp_seconds Earliest usable release certificate expiry as Unix time.
        # TYPE foreman_release_certificate_expiry_timestamp_seconds gauge
        # HELP foreman_release_deleting Whether ForemanRelease deletion is waiting for safe finalization.
        # TYPE foreman_release_deleting gauge
      METRICS
    end

    def escape_label(value)
      value.to_s.gsub('\\') { '\\\\' }.gsub("\n") { '\\n' }.gsub('"') { '\\"' }
    end
  end
end
