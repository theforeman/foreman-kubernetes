# frozen_string_literal: true

require 'base64'
require 'json'
require_relative 'command_runner'

module ForemanRelease
  class KubernetesClient
    RESOURCE = 'foremanreleases.platform.theforeman.org'

    def initialize(runner: CommandRunner.new)
      @runner = runner
    end

    def releases(namespace)
      response = @runner.run(
        'kubectl', '--namespace', namespace, 'get', RESOURCE, '--output=json'
      )
      JSON.parse(response).fetch('items')
    end

    def release(namespace, name)
      response = @runner.run(
        'kubectl', '--namespace', namespace, 'get', RESOURCE, name, '--output=json'
      )
      JSON.parse(response)
    end

    def secret_value(namespace, name, key)
      response = @runner.run(
        'kubectl', '--namespace', namespace, 'get', 'secret', name, '--output=json'
      )
      encoded = JSON.parse(response).dig('data', key)
      raise KeyError, "Secret #{namespace}/#{name} has no key #{key}" unless encoded

      Base64.strict_decode64(encoded)
    rescue ArgumentError
      raise ArgumentError, "Secret #{namespace}/#{name} key #{key} is not valid base64"
    end

    def resources(namespace, type, labels: {})
      command = kubectl(namespace, 'get', type, '--output=json')
      unless labels.empty?
        selector = labels.sort.map { |key, value| "#{key}=#{value}" }.join(',')
        command.insert(-1, '--selector', selector)
      end
      JSON.parse(@runner.run(*command)).fetch('items')
    end

    def resource(namespace, type, name)
      response = @runner.run(*kubectl(namespace, 'get', type, name, '--output=json'))
      JSON.parse(response)
    end

    def create(namespace, resource)
      response = @runner.run(
        'kubectl', '--namespace', namespace, 'create', '--filename=-', '--output=json',
        stdin_data: JSON.generate(resource)
      )
      JSON.parse(response)
    end

    def replace(namespace, resource)
      response = @runner.run(
        'kubectl', '--namespace', namespace, 'replace', '--filename=-', '--output=json',
        stdin_data: JSON.generate(resource)
      )
      JSON.parse(response)
    end

    def delete(namespace, type, name)
      @runner.run(
        *kubectl(namespace, 'delete', type, name, '--ignore-not-found=true', '--wait=false')
      )
      true
    end

    def write_status(resource, status)
      metadata = resource.fetch('metadata')
      resource_version = metadata.fetch('resourceVersion')
      patch = [
        {
          'op' => 'test',
          'path' => '/metadata/resourceVersion',
          'value' => resource_version
        },
        {
          'op' => 'add',
          'path' => '/status',
          'value' => status
        }
      ]
      response = @runner.run(
        'kubectl', '--namespace', metadata.fetch('namespace'),
        'patch', RESOURCE, metadata.fetch('name'),
        '--subresource=status', '--type=json', '--patch', JSON.generate(patch),
        '--output=json'
      )
      JSON.parse(response)
    end

    def ensure_finalizer(resource, finalizer)
      metadata = resource.fetch('metadata')
      finalizers = Array(metadata['finalizers'])
      return resource if finalizers.include?(finalizer)

      path = metadata.key?('finalizers') ? '/metadata/finalizers/-' : '/metadata/finalizers'
      value = metadata.key?('finalizers') ? finalizer : [finalizer]
      patch_metadata(resource, [{'op' => 'add', 'path' => path, 'value' => value}])
    end

    def remove_finalizer(resource, finalizer)
      finalizers = Array(resource.dig('metadata', 'finalizers'))
      index = finalizers.index(finalizer)
      return resource unless index

      patch_metadata(resource, [{'op' => 'remove', 'path' => "/metadata/finalizers/#{index}"}])
    end

    private

    def patch_metadata(resource, operations)
      metadata = resource.fetch('metadata')
      patch = [
        {
          'op' => 'test',
          'path' => '/metadata/resourceVersion',
          'value' => metadata.fetch('resourceVersion')
        }
      ] + operations
      response = @runner.run(
        'kubectl', '--namespace', metadata.fetch('namespace'),
        'patch', RESOURCE, metadata.fetch('name'),
        '--type=json', '--patch', JSON.generate(patch), '--output=json'
      )
      JSON.parse(response)
    end

    def kubectl(namespace, *arguments)
      command = ['kubectl']
      command.push('--namespace', namespace) unless namespace.to_s.empty?
      command.concat(arguments)
    end
  end
end
