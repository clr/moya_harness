{{/*
Expand the chart base name.
*/}}
{{- define "distributed-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a fullname for a workload.
*/}}
{{- define "distributed-app.workloadFullname" -}}
{{- $root := index . "root" -}}
{{- $workload := index . "workload" -}}
{{- printf "%s-%s" (include "distributed-app.name" $root) $workload.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "distributed-app.labels" -}}
app.kubernetes.io/name: {{ include "distributed-app.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/component: {{ .workload.name }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" }}
{{- end -}}
