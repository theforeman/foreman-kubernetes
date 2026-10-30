{{- define "foreman-release-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "foreman-release-operator.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "foreman-release-operator.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "foreman-release-operator.labels" -}}
app.kubernetes.io/name: {{ include "foreman-release-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: release-controller
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: foreman
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
platform.theforeman.org/compatibility-set: controller-runtime
{{- end }}

{{- define "foreman-release-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "foreman-release-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: release-controller
platform.theforeman.org/compatibility-set: controller-runtime
{{- end }}

{{- define "foreman-release-operator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "foreman-release-operator.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- required "serviceAccount.name is required when serviceAccount.create is false" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "foreman-release-operator.clusterRoleName" -}}
{{- $raw := printf "%s-%s" (include "foreman-release-operator.fullname" .) (.Release.Namespace | sha256sum | trunc 8) -}}
{{- if gt (len $raw) 63 -}}
{{- printf "%s-%s" ($raw | trunc 54 | trimSuffix "-") ($raw | sha256sum | trunc 8) -}}
{{- else -}}
{{- $raw -}}
{{- end -}}
{{- end }}

{{- define "foreman-release-operator.scheduling" -}}
{{- with .Values.scheduling.priorityClassName }}
priorityClassName: {{ . | quote }}
{{- end }}
{{- with .Values.scheduling.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.scheduling.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
