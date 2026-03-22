{{/*
Expand the name of the chart.
*/}}
{{- define "doris.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "doris.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "doris.fe.fullname" -}}
{{- printf "%s-fe" (include "doris.fullname" .) }}
{{- end }}

{{- define "doris.be.fullname" -}}
{{- printf "%s-be" (include "doris.fullname" .) }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "doris.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "doris.fe.selectorLabels" -}}
app.kubernetes.io/name: {{ include "doris.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: fe
{{- end }}

{{- define "doris.be.selectorLabels" -}}
app.kubernetes.io/name: {{ include "doris.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: be
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "doris.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "doris.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
