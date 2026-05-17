# EKS Monitoring — Prometheus, Grafana, Node Exporter & Slack Alerting

Complete step-by-step guide to set up production-grade monitoring on AWS EKS.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Install kube-prometheus-stack](#3-install-kube-prometheus-stack)
4. [Access Grafana](#4-access-grafana)
5. [Configure Slack Alerting](#5-configure-slack-alerting)
6. [6 Alert Use Cases](#6-six-alert-use-cases)
   - [Use Case 1 — Pod Down](#use-case-1--pod-down)
   - [Use Case 2 — High CPU Usage](#use-case-2--high-cpu-usage)
   - [Use Case 3 — High Memory Usage](#use-case-3--high-memory-usage)
   - [Use Case 4 — Node Not Ready](#use-case-4--node-not-ready)
   - [Use Case 5 — Pod Crash Loop](#use-case-5--pod-crash-loop)
   - [Use Case 6 — Container OOM Killed](#use-case-6--container-oom-killed)
7. [Install Loki + Promtail (Log Monitoring)](#7-install-loki--promtail-log-monitoring)
8. [Grafana Dashboards](#8-grafana-dashboards)
9. [Test Your Alerts](#9-test-your-alerts)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        EKS Cluster                              │
│                                                                 │
│  ┌──────────────┐   scrapes   ┌───────────────────────────┐    │
│  │ Node Exporter│ ──────────► │                           │    │
│  │ (every node) │             │       Prometheus          │    │
│  └──────────────┘             │  (metrics storage &       │    │
│                               │   alerting engine)        │    │
│  ┌──────────────┐   scrapes   │                           │    │
│  │kube-state-   │ ──────────► │                           │    │
│  │metrics       │             └─────────┬─────────────────┘    │
│  └──────────────┘                       │ fires alerts          │
│                                         ▼                       │
│  ┌──────────────┐             ┌───────────────────────────┐    │
│  │  Promtail    │──► Loki ──► │       Grafana             │    │
│  │ (log agent)  │             │  (dashboards + UI)        │    │
│  └──────────────┘             └─────────────────────────┬─┘    │
│                                                         │       │
└─────────────────────────────────────────────────────────┼───────┘
                                                          │ alerts
                                                          ▼
                                               ┌──────────────────┐
                                               │  Alertmanager    │
                                               └────────┬─────────┘
                                                        │
                                                        ▼
                                               ┌──────────────────┐
                                               │   Slack Channel  │
                                               └──────────────────┘
```

### What Each Component Does

| Component | Role |
|-----------|------|
| **Prometheus** | Scrapes and stores time-series metrics from all pods and nodes |
| **Node Exporter** | Runs on every node as a DaemonSet — exposes CPU, memory, disk, network metrics |
| **kube-state-metrics** | Exposes Kubernetes object state (pod status, deployments, restarts) |
| **Alertmanager** | Receives alerts from Prometheus, groups them, routes to Slack/email/PagerDuty |
| **Grafana** | Visualises all metrics from Prometheus and logs from Loki |
| **Loki** | Log aggregation engine — stores logs from all pods |
| **Promtail** | Agent that runs on every node, ships pod logs to Loki |

---

## 2. Prerequisites

### Tools Required

```bash
# Verify kubectl is connected to your EKS cluster
kubectl get nodes
# Expected: nodes in Ready state

# Helm 3 (package manager for Kubernetes)
brew install helm          # macOS
# or
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm version               # should show v3.x
```

### Set Variables (run once per session)

```bash
export CLUSTER_NAME=quantam-cluster
export AWS_REGION=ap-northeast-1
export MONITORING_NS=monitoring

# Connect kubectl to your EKS cluster
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
```

### Create the Monitoring Namespace

```bash
kubectl create namespace monitoring
kubectl get namespace monitoring
```

---

## 3. Install kube-prometheus-stack

`kube-prometheus-stack` is a single Helm chart that installs **everything** in one command:
- Prometheus
- Grafana
- Node Exporter (as DaemonSet on every node)
- Alertmanager
- kube-state-metrics
- All necessary RBAC, ServiceMonitors, and default dashboards

### Add the Helm Repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Create the Values File

Create `monitoring/prometheus-values.yaml`:

```yaml
# monitoring/prometheus-values.yaml

# ─── Prometheus ───────────────────────────────────────────────────────────────
prometheus:
  prometheusSpec:
    retention: 15d                   # keep 15 days of metrics
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp2      # AWS EBS gp2 volume
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
    # scrape ALL ServiceMonitors across all namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

# ─── Grafana ──────────────────────────────────────────────────────────────────
grafana:
  adminPassword: "GrafanaAdmin@2026"   # change this
  persistence:
    enabled: true
    storageClassName: gp2
    size: 5Gi
  service:
    type: LoadBalancer                 # expose Grafana via AWS ALB
  # pre-load Loki as a datasource
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki:3100
      access: proxy

# ─── Alertmanager ─────────────────────────────────────────────────────────────
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: gp2
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi
  config:
    global:
      resolve_timeout: 5m
      slack_api_url: "<YOUR_SLACK_WEBHOOK_URL>"

    route:
      group_by: ["alertname", "namespace", "pod"]
      group_wait: 10s
      group_interval: 5m
      repeat_interval: 1h
      receiver: "slack-warning"
      routes:
        - match:
            severity: critical
          receiver: "slack-critical"
          continue: false
        - match:
            severity: warning
          receiver: "slack-warning"
          continue: false

    receivers:
      - name: "slack-critical"
        slack_configs:
          - channel: "#alerts-critical"
            send_resolved: true
            icon_emoji: ":red_circle:"
            title: '[CRITICAL] {{ .GroupLabels.alertname }}'
            text: >-
              {{ range .Alerts }}
              *Alert:* {{ .Annotations.summary }}
              *Namespace:* {{ .Labels.namespace }}
              *Pod:* {{ .Labels.pod }}
              *Description:* {{ .Annotations.description }}
              *Started:* {{ .StartsAt | since }}
              {{ end }}

      - name: "slack-warning"
        slack_configs:
          - channel: "#alerts-warning"
            send_resolved: true
            icon_emoji: ":warning:"
            title: '[WARNING] {{ .GroupLabels.alertname }}'
            text: >-
              {{ range .Alerts }}
              *Alert:* {{ .Annotations.summary }}
              *Namespace:* {{ .Labels.namespace }}
              *Pod:* {{ .Labels.pod }}
              *Description:* {{ .Annotations.description }}
              *Started:* {{ .StartsAt | since }}
              {{ end }}

# ─── Node Exporter ────────────────────────────────────────────────────────────
nodeExporter:
  enabled: true                        # DaemonSet on every node

# ─── kube-state-metrics ───────────────────────────────────────────────────────
kubeStateMetrics:
  enabled: true

# ─── Default Alert Rules ──────────────────────────────────────────────────────
defaultRules:
  create: true
  rules:
    alertmanager: true
    etcd: false              # not needed for managed EKS
    configReloaders: true
    general: true
    kubeApiserver: true
    kubeApiserverAvailability: true
    kubeApiserverSlos: true
    kubelet: true
    kubeProxy: false         # not exposed in EKS
    kubePrometheusGeneral: true
    kubePrometheusNodeRecording: true
    kubernetesApps: true
    kubernetesResources: true
    kubernetesStorage: true
    kubernetesSystem: true
    kubeScheduler: false     # not accessible in managed EKS
    kubeStateMetrics: true
    network: true
    node: true
    nodeExporterAlerting: true
    nodeExporterRecording: true
    prometheus: true
    prometheusOperator: true
```

### Install the Stack

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/prometheus-values.yaml \
  --wait

# Verify all pods are Running
kubectl get pods -n monitoring
```

Expected output:
```
NAME                                                     READY   STATUS    RESTARTS
alertmanager-kube-prometheus-stack-alertmanager-0        2/2     Running   0
kube-prometheus-stack-grafana-xxxx                       3/3     Running   0
kube-prometheus-stack-kube-state-metrics-xxxx            1/1     Running   0
kube-prometheus-stack-operator-xxxx                      1/1     Running   0
kube-prometheus-stack-prometheus-node-exporter-xxxx      1/1     Running   0   ← one per node
kube-prometheus-stack-prometheus-node-exporter-yyyy      1/1     Running   0   ← one per node
prometheus-kube-prometheus-stack-prometheus-0            2/2     Running   0
```

---

## 4. Access Grafana

### Option A — LoadBalancer (recommended for demos)

```bash
# Get the external URL (takes ~2 minutes for AWS to provision the LB)
kubectl get svc kube-prometheus-stack-grafana -n monitoring --watch

# Once EXTERNAL-IP is assigned:
export GRAFANA_URL=$(kubectl get svc kube-prometheus-stack-grafana \
  -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Grafana: http://$GRAFANA_URL"
```

Login:
- **Username:** `admin`
- **Password:** `GrafanaAdmin@2026`

### Option B — Port Forward (local access only)

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# Open: http://localhost:3000
```

### Access Prometheus UI

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
# Open: http://localhost:9090
```

### Access Alertmanager UI

```bash
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring
# Open: http://localhost:9093
```

---

## 5. Configure Slack Alerting

### Step 1 — Create a Slack App and Incoming Webhook

1. Go to **https://api.slack.com/apps** → click **Create New App** → **From scratch**
2. Name it `EKS Alerts`, choose your workspace
3. Left panel → **Incoming Webhooks** → toggle **Activate Incoming Webhooks** ON
4. Click **Add New Webhook to Workspace**
5. Select the channel (e.g. `#alerts-critical`) → click **Allow**
6. Copy the webhook URL (shown after you click Allow)
   - Store it safely — you will paste it into `prometheus-values.yaml`
   - **Never commit the real URL to git** — use a secret manager or environment variable
7. Repeat for `#alerts-warning` channel

### Step 2 — Update prometheus-values.yaml

Replace `<YOUR_SLACK_WEBHOOK_URL>` in the values file with your actual webhook URL:

```yaml
alertmanager:
  config:
    global:
      slack_api_url: "<YOUR_SLACK_WEBHOOK_URL>"
```

### Step 3 — Apply the Updated Config

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/prometheus-values.yaml \
  --wait

# Verify Alertmanager picked up the new config
kubectl logs -l app.kubernetes.io/name=alertmanager -n monitoring --tail=20
```

### Step 4 — Test the Slack Connection

Send a test alert via Alertmanager's API:

```bash
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring &

curl -X POST http://localhost:9093/api/v1/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "TestAlert",
      "severity": "warning",
      "namespace": "monitoring"
    },
    "annotations": {
      "summary": "Test alert from Alertmanager",
      "description": "If you see this in Slack, your alerting is working."
    }
  }]'
```

You should see the test message in your `#alerts-warning` Slack channel within 10–30 seconds.

---

## 6. Six Alert Use Cases

All six rules are defined in a single `PrometheusRule` custom resource. Prometheus Operator
watches for these CRDs and loads them into Prometheus automatically.

Create `monitoring/alert-rules.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: eks-custom-alert-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack    # must match the Helm release name
spec:
  groups:

  # ─────────────────────────────────────────────────────────────────────────────
  # USE CASE 1 — Pod Down
  # ─────────────────────────────────────────────────────────────────────────────
  - name: pod-down
    rules:
      - alert: PodNotReady
        expr: |
          kube_pod_status_ready{condition="true"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Pod {{ $labels.pod }} is NOT ready"
          description: >
            Pod {{ $labels.pod }} in namespace {{ $labels.namespace }}
            has been in a not-ready state for more than 1 minute.
            Check: kubectl describe pod {{ $labels.pod }} -n {{ $labels.namespace }}

      - alert: PodNotRunning
        expr: |
          kube_pod_status_phase{phase=~"Failed|Unknown"} == 1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Pod {{ $labels.pod }} is in {{ $labels.phase }} state"
          description: >
            Pod {{ $labels.pod }} in namespace {{ $labels.namespace }}
            is in phase {{ $labels.phase }}. Immediate investigation required.

  # ─────────────────────────────────────────────────────────────────────────────
  # USE CASE 2 — High CPU Usage
  # ─────────────────────────────────────────────────────────────────────────────
  - name: cpu-usage
    rules:
      - alert: ContainerHighCPU
        expr: |
          (
            rate(container_cpu_usage_seconds_total{
              container!="",
              container!="POD",
              namespace!="kube-system"
            }[5m])
            /
            on(namespace, pod, container)
            kube_pod_container_resource_limits{resource="cpu"}
          ) * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU: {{ $labels.container }} at {{ $value | printf \"%.1f\" }}%"
          description: >
            Container {{ $labels.container }} in pod {{ $labels.pod }}
            (namespace {{ $labels.namespace }}) is using {{ $value | printf "%.1f" }}%
            of its CPU limit for more than 5 minutes.

      - alert: ContainerCPUThrottling
        expr: |
          rate(container_cpu_throttled_seconds_total{container!=""}[5m])
          /
          rate(container_cpu_usage_seconds_total{container!=""}[5m]) > 0.25
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "CPU throttling on {{ $labels.container }}"
          description: >
            Container {{ $labels.container }} is being CPU throttled >25%.
            Consider increasing its CPU limit or optimizing the application.

  # ─────────────────────────────────────────────────────────────────────────────
  # USE CASE 3 — High Memory Usage
  # ─────────────────────────────────────────────────────────────────────────────
  - name: memory-usage
    rules:
      - alert: ContainerHighMemory
        expr: |
          (
            container_memory_working_set_bytes{
              container!="",
              container!="POD"
            }
            /
            on(namespace, pod, container)
            kube_pod_container_resource_limits{resource="memory"}
          ) * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory: {{ $labels.container }} at {{ $value | printf \"%.1f\" }}%"
          description: >
            Container {{ $labels.container }} in pod {{ $labels.pod }}
            is using {{ $value | printf "%.1f" }}% of its memory limit.
            Risk of OOM kill if this continues.

      - alert: ContainerMemoryCritical
        expr: |
          (
            container_memory_working_set_bytes{container!="",container!="POD"}
            /
            on(namespace, pod, container)
            kube_pod_container_resource_limits{resource="memory"}
          ) * 100 > 95
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "CRITICAL memory: {{ $labels.container }} at {{ $value | printf \"%.1f\" }}%"
          description: >
            Container {{ $labels.container }} is at {{ $value | printf "%.1f" }}% memory.
            OOM kill imminent. Pod will be restarted automatically but data may be lost.

  # ─────────────────────────────────────────────────────────────────────────────
  # USE CASE 4 — Node Health
  # ─────────────────────────────────────────────────────────────────────────────
  - name: node-health
    rules:
      - alert: NodeNotReady
        expr: |
          kube_node_status_condition{condition="Ready", status="true"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Node {{ $labels.node }} is NOT ready"
          description: >
            Kubernetes node {{ $labels.node }} has been in NotReady state for 1 minute.
            Pods on this node will be evicted after 5 minutes.
            Check: kubectl describe node {{ $labels.node }}

      - alert: NodeHighCPU
        expr: |
          (1 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Node {{ $labels.instance }} CPU at {{ $value | printf \"%.1f\" }}%"
          description: >
            Node {{ $labels.instance }} has CPU usage above 85% for 5 minutes.
            This may cause pod scheduling failures.

      - alert: NodeHighMemory
        expr: |
          (
            1 - (
              node_memory_MemAvailable_bytes
              /
              node_memory_MemTotal_bytes
            )
          ) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Node {{ $labels.instance }} memory at {{ $value | printf \"%.1f\" }}%"
          description: >
            Node {{ $labels.instance }} has memory usage above 85% for 5 minutes.

      - alert: NodeDiskPressure
        expr: |
          (
            1 - (
              node_filesystem_avail_bytes{mountpoint="/", fstype!="tmpfs"}
              /
              node_filesystem_size_bytes{mountpoint="/", fstype!="tmpfs"}
            )
          ) * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Node {{ $labels.instance }} disk at {{ $value | printf \"%.1f\" }}%"
          description: >
            Node {{ $labels.instance }} root disk is {{ $value | printf "%.1f" }}% full.
            Clean up or resize the EBS volume.

  # ─────────────────────────────────────────────────────────────────────────────
  # USE CASE 5 — Pod Crash Loop
  # ─────────────────────────────────────────────────────────────────────────────
  - name: pod-crash-loop
    rules:
      - alert: PodCrashLooping
        expr: |
          rate(kube_pod_container_status_restarts_total[15m]) * 60 * 15 > 3
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Pod {{ $labels.pod }} is crash looping"
          description: >
            Pod {{ $labels.pod }} in namespace {{ $labels.namespace }}
            has restarted more than 3 times in 15 minutes.
            Check logs: kubectl logs {{ $labels.pod }} -n {{ $labels.namespace }} --previous

      - alert: PodRestartingFrequently
        expr: |
          kube_pod_container_status_restarts_total > 5
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Pod {{ $labels.pod }} has restarted {{ $value }} times"
          description: >
            Pod {{ $labels.pod }} in namespace {{ $labels.namespace }}
            has a total restart count of {{ $value }}. Investigate the root cause.

  # ─────────────────────────────────────────────────────────────────────────────
  # USE CASE 6 — Container OOM Killed
  # ─────────────────────────────────────────────────────────────────────────────
  - name: oom-killed
    rules:
      - alert: ContainerOOMKilled
        expr: |
          kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Container {{ $labels.container }} was OOM killed"
          description: >
            Container {{ $labels.container }} in pod {{ $labels.pod }}
            (namespace {{ $labels.namespace }}) was killed because it exceeded
            its memory limit. Increase the memory limit or fix the memory leak.
            Current limit: check with kubectl describe pod {{ $labels.pod }} -n {{ $labels.namespace }}
```

### Apply the Rules

```bash
kubectl apply -f monitoring/alert-rules.yaml

# Verify Prometheus loaded the rules (takes ~30 seconds)
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &
# Open http://localhost:9090/rules — all 6 groups should be green
```

---

## 7. Install Loki + Promtail (Log Monitoring)

Loki aggregates logs from all pods. Promtail is the agent that ships logs to Loki.
Both are visualised in Grafana alongside your metrics.

### Add Grafana Helm Repo

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### Create Loki Values File

Create `monitoring/loki-values.yaml`:

```yaml
# monitoring/loki-values.yaml
loki:
  auth_enabled: false
  storage:
    type: filesystem       # for demo — use S3 in production
  commonConfig:
    replication_factor: 1
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

persistence:
  enabled: true
  storageClassName: gp2
  size: 10Gi

service:
  type: ClusterIP
  port: 3100
```

### Create Promtail Values File

Create `monitoring/promtail-values.yaml`:

```yaml
# monitoring/promtail-values.yaml
config:
  clients:
    - url: http://loki:3100/loki/api/v1/push

  # Scrape all pod logs and attach Kubernetes metadata
  snippets:
    pipelineStages:
      - cri: {}
      - labeldrop:
          - filename
    scrapeConfigs: |
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: __host__
          - action: labelmap
            regex: __meta_kubernetes_pod_label_(.+)
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_pod_container_name]
            target_label: container
          - replacement: /var/log/pods/*$1/*.log
            separator: /
            source_labels:
              - __meta_kubernetes_pod_uid
              - __meta_kubernetes_pod_container_name
            target_label: __path__
```

### Install Loki and Promtail

```bash
# Install Loki
helm install loki grafana/loki \
  --namespace monitoring \
  --values monitoring/loki-values.yaml \
  --wait

# Install Promtail (DaemonSet — runs on every node)
helm install promtail grafana/promtail \
  --namespace monitoring \
  --values monitoring/promtail-values.yaml \
  --wait

# Verify
kubectl get pods -n monitoring | grep -E "loki|promtail"
```

### Add Loki as Grafana Datasource

1. Open Grafana → left sidebar → **Connections** → **Data Sources** → **Add data source**
2. Choose **Loki**
3. URL: `http://loki:3100`
4. Click **Save & Test** — should show "Data source connected"

---

## 8. Grafana Dashboards

### Pre-Built Dashboards (Import by ID)

Grafana has a public library of community dashboards. Import these with one click.

**In Grafana: Dashboards → Import → Enter dashboard ID → Load**

| Dashboard | ID | What it shows |
|-----------|-----|---------------|
| Kubernetes Cluster Overview | `7249` | Node CPU, memory, pod count |
| Kubernetes Pod Resources | `6417` | Per-pod CPU and memory |
| Node Exporter Full | `1860` | Deep node metrics (disk, network, CPU per core) |
| Kubernetes Namespace Resources | `8588` | Resource usage per namespace |
| Loki Log Dashboard | `13639` | Logs from all pods with filtering |

### Manual Dashboard — Pod CPU & Memory

1. Grafana → **Dashboards** → **New** → **New Dashboard** → **Add visualization**
2. Data source: **Prometheus**

**Panel 1 — Pod CPU Usage:**
```promql
rate(container_cpu_usage_seconds_total{
  namespace="blog",
  container!="",
  container!="POD"
}[5m]) * 1000
```
- Visualization: **Time series**
- Title: `Pod CPU Usage (millicores)`
- Legend: `{{pod}} - {{container}}`

**Panel 2 — Pod Memory Usage:**
```promql
container_memory_working_set_bytes{
  namespace="blog",
  container!="",
  container!="POD"
} / 1024 / 1024
```
- Visualization: **Time series**
- Title: `Pod Memory Usage (MiB)`
- Legend: `{{pod}} - {{container}}`

**Panel 3 — Pod Restart Count:**
```promql
kube_pod_container_status_restarts_total{namespace="blog"}
```
- Visualization: **Stat**
- Title: `Pod Restart Count`

**Panel 4 — Pod Status (Up/Down):**
```promql
kube_pod_status_ready{namespace="blog", condition="true"}
```
- Visualization: **Stat** with thresholds: `0` = red, `1` = green
- Title: `Pod Ready Status`

**Panel 5 — Node CPU:**
```promql
(1 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100
```
- Visualization: **Gauge**
- Title: `Node CPU %`
- Thresholds: 0–70 green, 70–85 yellow, 85–100 red

**Panel 6 — Logs Explorer (requires Loki):**
```logql
{namespace="blog"} |= ""
```
- Visualization: **Logs**
- Title: `Application Logs`

Save the dashboard as **EKS Monitoring — Blog Platform**.

---

## 9. Test Your Alerts

### Test 1 — Simulate Pod Down

```bash
# Scale a deployment to 0 replicas (simulates all pods being down)
kubectl scale deployment auth-service --replicas=0 -n blog

# Watch the alert fire in Prometheus (takes ~1 minute)
# http://localhost:9090/alerts

# Watch Grafana Pod Status panel go red

# Restore
kubectl scale deployment auth-service --replicas=2 -n blog
```

Expected Slack message:
```
[CRITICAL] PodNotReady
Alert: Pod auth-service-xxxx is NOT ready
Namespace: blog
Description: Pod auth-service-xxxx has been in a not-ready state for more than 1 minute.
```

### Test 2 — Simulate CPU Spike

```bash
# Deploy a CPU stress pod
kubectl run cpu-stress \
  --image=containerstack/cpustress \
  --restart=Never \
  -n blog \
  -- --cpu 4 --timeout 120s

# Watch CPU alert fire after ~5 minutes
kubectl top pods -n blog
```

### Test 3 — Simulate Pod Crash Loop

```bash
# Deploy a pod that always exits with error
kubectl run crash-test \
  --image=busybox \
  --restart=Always \
  -n blog \
  -- sh -c "sleep 5 && exit 1"

# Watch restart count climb
kubectl get pod crash-test -n blog --watch

# Slack should fire PodCrashLooping after 3 restarts in 15 min

# Cleanup
kubectl delete pod crash-test -n blog
kubectl delete pod cpu-stress -n blog
```

### Test 4 — Simulate OOM Kill

```bash
# Deploy a pod that allocates memory until killed
kubectl run oom-test \
  --image=polinux/stress \
  --restart=Never \
  -n blog \
  --limits memory=64Mi \
  -- stress --vm 1 --vm-bytes 128M --timeout 30s

# Pod will be OOM killed — check
kubectl get pod oom-test -n blog
# STATUS: OOMKilled

# Slack fires ContainerOOMKilled immediately (for: 0m)

kubectl delete pod oom-test -n blog
```

### Test 5 — Node Health Check

```bash
# View node conditions in Prometheus
# http://localhost:9090
# Query: kube_node_status_condition{condition="Ready",status="true"}
# Expected: value 1 for each node (healthy)

# View full node metrics in Grafana dashboard ID 1860 (Node Exporter Full)
```

### Test 6 — Check Log Monitoring

```bash
# Generate some application logs
kubectl exec -it $(kubectl get pod -l app=auth-service -n blog -o jsonpath='{.items[0].metadata.name}') \
  -n blog -- sh -c "for i in \$(seq 1 20); do echo 'test log line \$i'; done"

# In Grafana → Explore → Loki datasource
# Query: {namespace="blog", app="auth-service"}
# You should see the log lines appear in real time
```

---

## Quick Reference

### Useful kubectl Commands

```bash
# Check all monitoring pods
kubectl get pods -n monitoring

# View Prometheus targets (what is being scraped)
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090 -n monitoring
# → http://localhost:9090/targets

# View firing alerts
# → http://localhost:9090/alerts

# View Alertmanager routing
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093 -n monitoring
# → http://localhost:9093

# Reload Alertmanager config after changes
kubectl rollout restart deployment/kube-prometheus-stack-alertmanager -n monitoring

# Check Prometheus rule syntax
kubectl get prometheusrules -n monitoring

# View resource usage across all pods
kubectl top pods -n blog
kubectl top nodes
```

### Key PromQL Queries for the Terminal

```promql
# All pods not ready
kube_pod_status_ready{condition="true"} == 0

# CPU usage per pod (millicores)
rate(container_cpu_usage_seconds_total{namespace="blog",container!=""}[5m]) * 1000

# Memory usage per pod (bytes)
container_memory_working_set_bytes{namespace="blog",container!=""}

# Node memory usage %
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Total restart count per pod
kube_pod_container_status_restarts_total{namespace="blog"}

# OOM killed containers
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}
```

### Helm Upgrade After Config Changes

```bash
# Any time you change prometheus-values.yaml
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/prometheus-values.yaml

# Check upgrade status
helm history kube-prometheus-stack -n monitoring
```

### Uninstall (if needed)

```bash
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall loki -n monitoring
helm uninstall promtail -n monitoring
kubectl delete namespace monitoring
```
