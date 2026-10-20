# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module ForemanReadiness
  module_function

  def validate!(results)
    database = results.dig('foreman', 'database', 'active')
    raise 'Foreman database is not active' unless database == true

    cache_servers = Array(results.dig('foreman', 'cache', 'servers'))
    if cache_servers.empty? || !cache_servers.all? { |server| server['status'] == 'ok' }
      raise 'Foreman cache is not healthy'
    end

    katello_status = results.dig('katello', 'status')
    raise "Katello dependencies report #{katello_status.inspect}" unless katello_status == 'ok'
  end

  def check!
    uri = URI(ENV.fetch('FOREMAN_READINESS_URL', 'http://127.0.0.1:3000/api/v2/ping'))
    client = Net::HTTP.new(uri.host, uri.port)
    client.open_timeout = 2
    client.read_timeout = 8
    request = Net::HTTP::Get.new(uri)
    request['Host'] = ENV.fetch('FOREMAN_READINESS_HOST')
    request['X-Forwarded-Proto'] = 'https'
    response = client.start { |http| http.request(request) }

    raise "Foreman ping returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    validate!(JSON.parse(response.body).fetch('results'))
  end
end

ForemanReadiness.check! if $PROGRAM_NAME == __FILE__
