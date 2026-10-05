#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'

repo_root = File.expand_path('..', __dir__)
manifest = <<~YAML
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: internal
  ---
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: generated-default
  spec:
    accessModes: [ReadWriteOnce]
  ---
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: generated-fast
  spec:
    storageClassName: fast-rwx
    accessModes: [ReadWriteMany]
  ---
  apiVersion: apps/v1
  kind: Deployment
  spec:
    template:
      spec:
        nodeSelector:
          kubernetes.io/arch: amd64
          workload: foreman
        tolerations:
          - key: dedicated
            operator: Equal
            value: foreman
            effect: NoSchedule
          - key: maintenance
            operator: Exists
        priorityClassName: foreman-platform-critical
        serviceAccountName: external-runtime
        containers:
          - name: app
        volumes:
          - name: generated
            persistentVolumeClaim:
              claimName: generated-fast
          - name: external
            persistentVolumeClaim:
              claimName: imported-content
  ---
  apiVersion: batch/v1
  kind: Job
  spec:
    template:
      spec:
        serviceAccountName: internal
        containers:
          - name: task
  ---
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    annotations:
      foreman-kubernetes.io/required-ingress-controller: k8s.io/ingress-nginx
  spec:
    ingressClassName: nginx
  ---
  apiVersion: autoscaling/v2
  kind: HorizontalPodAutoscaler
  metadata:
    name: web
  spec:
    scaleTargetRef:
      apiVersion: apps/v1
      kind: Deployment
      name: web
    minReplicas: 2
    maxReplicas: 4
    metrics:
      - type: Resource
        resource:
          name: cpu
          target:
            type: Utilization
            averageUtilization: 75
  ---
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: foreman
YAML

output, error, status = Open3.capture3(
  'ruby', File.join(repo_root, 'scripts/required-cluster-resources.rb'),
  stdin_data: manifest
)
abort error unless status.success?

expected = <<~OUTPUT
  APIService\tv1beta1.metrics.k8s.io\tAvailable
  CustomResourceDefinition\tprometheusrules.monitoring.coreos.com
  DefaultStorageClass\t
  IngressClass\tnginx\tk8s.io/ingress-nginx
  NodeScheduling\t{"nodeSelector":{"kubernetes.io/arch":"amd64","workload":"foreman"},"tolerations":[{"effect":"NoSchedule","key":"dedicated","operator":"Equal","value":"foreman"},{"key":"maintenance","operator":"Exists"}]}
  PersistentVolumeClaim\timported-content
  PriorityClass\tforeman-platform-critical
  ServiceAccount\texternal-runtime
  StorageClass\tfast-rwx
OUTPUT
abort "unexpected cluster resource inventory:\n#{output}" unless output == expected

puts 'Required cluster resource discovery checks passed.'
