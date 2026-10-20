#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'

repo_root = File.expand_path('..', __dir__)
manifest = <<~YAML
  apiVersion: v1
  kind: Secret
  metadata:
    name: chart-owned
  data:
    password: Y2hhcnQ=
  ---
  apiVersion: apps/v1
  kind: Deployment
  spec:
    template:
      spec:
        imagePullSecrets:
          - name: registry-auth
        initContainers:
          - name: init
            env:
              - name: PASSWORD
                valueFrom:
                  secretKeyRef:
                    name: database
                    key: password
              - name: OPTIONAL
                valueFrom:
                  secretKeyRef:
                    name: optional-env
                    key: value
                    optional: true
        containers:
          - name: app
            volumeMounts:
              - name: certificate
                mountPath: /certificates/server.crt
                subPath: certificate
              - name: unfiltered-certificate
                mountPath: /certificates/client.crt
                subPath: client.crt
            envFrom:
              - secretRef:
                  name: runtime
            env:
              - name: USERNAME
                valueFrom:
                  secretKeyRef:
                    name: database
                    key: username
              - name: CHART_OWNED
                valueFrom:
                  secretKeyRef:
                    name: chart-owned
                    key: password
        volumes:
          - name: certificate
            secret:
              secretName: certificate
              items:
                - key: tls.crt
                  path: certificate
                - key: tls.key
                  path: private-key
          - name: projected
            projected:
              sources:
                - secret:
                    name: projected
                    items:
                      - key: token
                        path: token
          - name: unfiltered-certificate
            secret:
              secretName: unfiltered-certificate
          - name: optional-volume
            secret:
              secretName: optional-volume
              optional: true
  ---
  apiVersion: batch/v1
  kind: CronJob
  spec:
    jobTemplate:
      spec:
        template:
          spec:
            containers:
              - name: recurring
                envFrom:
                  - secretRef:
                      name: runtime
  ---
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    annotations:
      nginx.ingress.kubernetes.io/auth-tls-secret: test/client-ca
  spec:
    tls:
      - secretName: ingress-tls
  ---
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  spec:
    tls:
      - secretName: cert-manager-owned
YAML

output, error, status = Open3.capture3(
  'ruby', File.join(repo_root, 'scripts/required-secrets.rb'),
  stdin_data: manifest
)
abort error unless status.success?

expected = <<~OUTPUT
  cert-manager-owned\ttls.crt,tls.key
  certificate\ttls.crt,tls.key
  client-ca\tca.crt
  database\tpassword,username
  ingress-tls\ttls.crt,tls.key
  projected\ttoken
  registry-auth\t
  runtime\t
  unfiltered-certificate\tclient.crt
OUTPUT

abort "unexpected required Secret inventory:\n#{output}" unless output == expected

puts 'Required Secret discovery checks passed.'
