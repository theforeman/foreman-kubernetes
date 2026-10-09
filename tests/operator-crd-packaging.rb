#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
source = root.join('operator/crd/platform.theforeman.org_foremanreleases.yaml')
packaged = root.join('charts/foreman-release-operator/crds/platform.theforeman.org_foremanreleases.yaml')

raise 'operator chart does not package the ForemanRelease CRD' unless packaged.file?
raise 'packaged CRD drifted from the controller API source' unless packaged.binread == source.binread

crd = YAML.safe_load(packaged.read, aliases: true)
raise 'packaged API is not a CRD' unless crd['kind'] == 'CustomResourceDefinition'
raise 'packaged API has the wrong resource name' unless crd.dig('metadata', 'name') == 'foremanreleases.platform.theforeman.org'
versions = Array(crd.dig('spec', 'versions'))
storage = versions.select { |version| version['storage'] }
raise 'packaged API must have exactly one storage version' unless storage.length == 1
raise 'packaged API does not store v1beta1' unless storage.first['name'] == 'v1beta1'
raise 'packaged API no longer serves v1alpha1' unless versions.any? do |version|
  version['name'] == 'v1alpha1' && version['served'] == true
end
raise 'packaged API does not expose the status subresource' unless storage.first.dig('subresources', 'status') == {}

puts 'Operator chart packages the exact ForemanRelease CRD with one status-enabled storage version.'
