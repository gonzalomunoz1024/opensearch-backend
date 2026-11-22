{{/* Name of the Service and StatefulSet. */}}
{{- define "osl.fullname" -}}
{{- default "opensearch-lite" .Values.fullnameOverride | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{- define "osl.selectorLabels" -}}
app.kubernetes.io/name: opensearch-lite
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "osl.labels" -}}
{{ include "osl.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
OpenSearch settings as environment variables; the image turns variables that look
like settings into settings. The chart's own come first, then .Values.settings, which
win. A setting may be given only once, hence one merged list.
*/}}
{{- define "osl.settingsEnv" -}}
{{- $name := include "osl.fullname" . -}}
{{- $replicas := int .Values.replicas -}}
{{- $settings := dict "cluster.name" (toString .Values.clusterName) -}}
{{- if gt $replicas 1 -}}
  {{- $nodes := list -}}
  {{- range $i := until $replicas -}}
    {{- $nodes = append $nodes (printf "%s-%d" $name $i) -}}
  {{- end -}}
  {{- $_ := set $settings "discovery.type" "zen" -}}
  {{- $_ := set $settings "discovery.seed_hosts" (printf "%s-nodes" $name) -}}
  {{- $_ := set $settings "cluster.initial_cluster_manager_nodes" (join "," $nodes) -}}
  {{- /* The image's own configuration is for one node, which keeps no replicas. */ -}}
  {{- $_ := set $settings "cluster.default_number_of_replicas" "1" -}}
{{- end -}}
{{- $mmap := .Values.allowMmap -}}
{{- if kindIs "invalid" $mmap -}}
  {{- $mmap = le $replicas 1 -}}
{{- end -}}
{{- if not $mmap -}}
  {{- $_ := set $settings "node.store.allow_mmap" "false" -}}
{{- end -}}
{{- range $key, $value := .Values.settings -}}
  {{- $_ := set $settings $key (toString $value) -}}
{{- end -}}
{{- range $key, $value := $settings }}
- name: {{ $key | quote }}
  value: {{ $value | quote }}
{{- end -}}
{{- end -}}
