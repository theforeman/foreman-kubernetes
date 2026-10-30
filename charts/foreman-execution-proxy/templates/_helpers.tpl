{{- define "foreman-execution-proxy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "foreman-execution-proxy.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "foreman-execution-proxy.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "foreman-execution-proxy.labels" -}}
{{ include "foreman-execution-proxy.componentLabels" (dict "root" . "component" "execution-proxy") }}
{{- end }}

{{- define "foreman-execution-proxy.componentLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "foreman-execution-proxy.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: foreman
platform.theforeman.org/compatibility-set: {{ .root.Values.compatibilitySet | quote }}
{{- with .root.Values.releaseOperation.id }}
platform.theforeman.org/release-operation: {{ . | quote }}
platform.theforeman.org/release-owner: {{ $.root.Values.releaseOperation.ownerUid | quote }}
{{- end }}
{{- end }}

{{- define "foreman-execution-proxy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "foreman-execution-proxy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: execution-proxy
{{- end }}

{{- define "foreman-execution-proxy.podLabels" -}}
{{ include "foreman-execution-proxy.componentPodLabels" (dict "root" . "component" "execution-proxy") }}
{{- end }}

{{- define "foreman-execution-proxy.componentPodLabels" -}}
app.kubernetes.io/name: {{ include "foreman-execution-proxy.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
platform.theforeman.org/compatibility-set: {{ .root.Values.compatibilitySet | quote }}
{{- with .root.Values.releaseOperation.id }}
platform.theforeman.org/release-operation: {{ . | quote }}
platform.theforeman.org/release-owner: {{ $.root.Values.releaseOperation.ownerUid | quote }}
{{- end }}
{{- end }}

{{- define "foreman-execution-proxy.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "foreman-execution-proxy.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- required "serviceAccount.name is required when serviceAccount.create is false" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "foreman-execution-proxy.stateClaimName" -}}
{{- default (printf "%s-state" (include "foreman-execution-proxy.fullname" .)) .Values.state.existingClaim }}
{{- end }}

{{- define "foreman-execution-proxy.ansibleClaimName" -}}
{{- default (printf "%s-ansible" (include "foreman-execution-proxy.fullname" .)) .Values.ansible.existingClaim }}
{{- end }}

{{- define "foreman-execution-proxy.containerSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
readOnlyRootFilesystem: true
runAsGroup: 991
runAsNonRoot: true
runAsUser: 991
{{- end }}

{{- define "foreman-execution-proxy.scheduling" -}}
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
