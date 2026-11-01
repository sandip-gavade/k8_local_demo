{{/* Resource name prefix: the release name (e.g. "orders") unless overridden. */}}
{{- define "django-app.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "django-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels on every object. */}}
{{- define "django-app.labels" -}}
helm.sh/chart: {{ include "django-app.chart" . }}
app.kubernetes.io/name: {{ default .Chart.Name .Values.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Selector labels: immutable once a Deployment exists, so keep them minimal. Call with (dict "ctx" . "component" "web"). */}}
{{- define "django-app.selectorLabels" -}}
app.kubernetes.io/name: {{ default .ctx.Chart.Name .ctx.Values.nameOverride }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "django-app.backendImage" -}}
{{ .Values.image.backend.repository }}:{{ .Values.image.backend.tag }}
{{- end -}}
{{- define "django-app.frontendImage" -}}
{{ .Values.image.frontend.repository }}:{{ .Values.image.frontend.tag }}
{{- end -}}

{{- define "django-app.secretName" -}}
{{ .Values.secret.name }}
{{- end -}}

{{/* Secret env vars, referenced (never inlined) from the Secret. */}}
{{- define "django-app.secretEnv" -}}
- name: POSTGRES_PASSWORD
  valueFrom: {secretKeyRef: {name: {{ include "django-app.secretName" . }}, key: POSTGRES_PASSWORD}}
- name: DJANGO_SECRET_KEY
  valueFrom: {secretKeyRef: {name: {{ include "django-app.secretName" . }}, key: DJANGO_SECRET_KEY}}
{{- end -}}

{{/* Writable scratch dirs for read-only root filesystems. */}}
{{- define "django-app.tmpVolume" -}}
- {name: tmp, emptyDir: {}}
{{- end -}}
