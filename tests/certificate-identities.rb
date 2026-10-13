#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'

repo_root = File.expand_path('..', __dir__)
manifest = <<~YAML
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: foreman
  spec:
    rules:
      - host: fallback.example.test
    tls:
      - secretName: shared-ingress
        hosts:
          - foreman.example.test
  ---
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: content
  spec:
    rules:
      - host: content.example.test
    tls:
      - secretName: shared-ingress
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: candlepin
    annotations:
      foreman-kubernetes.io/certificate-secret: candlepin-certificates
      foreman-kubernetes.io/certificate-key: tomcat.crt
      foreman-kubernetes.io/certificate-dns-name: candlepin
YAML

output, error, status = Open3.capture3(
  'ruby', File.join(repo_root, 'scripts/certificate-identities.rb'),
  stdin_data: manifest
)
abort error unless status.success?

expected = {
  'candlepin-certificates' => {'tomcat.crt' => ['candlepin']},
  'shared-ingress' => {'tls.crt' => %w[content.example.test foreman.example.test]}
}
actual = JSON.parse(output)
abort "unexpected certificate identity inventory:\n#{output}" unless actual == expected

puts 'Certificate identity discovery checks passed.'
