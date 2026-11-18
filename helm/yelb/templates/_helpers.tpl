{{/*
Nom du chart (« yelb » sauf nameOverride).
*/}}
{{- define "yelb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Préfixe de toutes les ressources : <release>-yelb, ou <release> si le nom de
la release contient déjà « yelb ». Grâce à ce préfixe, deux releases (dev et
prod) peuvent cohabiter, même dans un seul namespace.
*/}}
{{- define "yelb.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Nom d'un composant : <fullname>-<composant>, ex. dev-yelb-db.
Usage : include "yelb.componentName" (dict "root" . "component" "db")
*/}}
{{- define "yelb.componentName" -}}
{{- printf "%s-%s" (include "yelb.fullname" .root) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Label helm.sh/chart.
*/}}
{{- define "yelb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels de sélection d'un composant : ce sont eux qui relient un Service ou
un Deployment à ses pods. Ils ne doivent jamais changer après l'installation.
Usage : include "yelb.selectorLabels" (dict "root" . "component" "db")
*/}}
{{- define "yelb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "yelb.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Labels complets d'un composant.
Usage : include "yelb.labels" (dict "root" . "component" "db" "version" "0.6")
*/}}
{{- define "yelb.labels" -}}
helm.sh/chart: {{ include "yelb.chart" .root }}
{{ include "yelb.selectorLabels" . }}
app.kubernetes.io/part-of: yelb
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- with .version }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
{{- end }}

{{/*
Image complète d'un composant : <repository>:<tag>.
Usage : include "yelb.image" .Values.ui.image
*/}}
{{- define "yelb.image" -}}
{{- printf "%s:%s" .repository (toString .tag) }}
{{- end }}
