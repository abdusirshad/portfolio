# observability-stack

[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=flat-square&logo=prometheus)](https://prometheus.io)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?style=flat-square&logo=grafana)](https://grafana.com)
[![ELK](https://img.shields.io/badge/ELK_Stack-005571?style=flat-square&logo=elasticstack)](https://elastic.co)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat-square&logo=kubernetes)](https://kubernetes.io)
[![Helm](https://img.shields.io/badge/Helm-0F1689?style=flat-square&logo=helm)](https://helm.sh)

> Production-grade observability stack on Kubernetes — **Prometheus + Grafana + ELK Stack** with SLO/SLI dashboards, PagerDuty alerting, and FinOps cost dashboards. Sustained **99.99% availability** across 750+ servers at fintech scale.

---

## Stack Overview

```
                    ┌────────────────────────────────────────┐
                    │            Grafana Dashboards          │
                    │  ┌──────────┐  ┌────────┐  ┌───────┐  │
                    │  │ SLO/SLI  │  │ K8s    │  │FinOps │  │
                    │  │Dashboard │  │Cluster │  │ Cost  │  │
                    │  └──────────┘  └────────┘  └───────┘  │
                    └──────────┬──────────┬──────────────────┘
                               │          │
              ┌────────────────▼──┐    ┌──▼──────────────┐
              │    Prometheus     │    │  Elasticsearch   │
              │  + Alertmanager   │    │  + Kibana        │
              └────────┬──────────┘    └──────────────────┘
                       │                        ▲
              ┌────────▼──────────┐    ┌────────┴────────┐
              │  Metrics Sources  │    │   Log Sources   │
              │  - node-exporter  │    │  - Fluent Bit   │
              │  - kube-state     │    │  - Logstash     │
              │  - app /metrics   │    │  - App logs     │
              └───────────────────┘    └─────────────────┘
                       │
              ┌────────▼──────────┐
              │    PagerDuty      │
              │  (on-call alerts) │
              └───────────────────┘
```

---

## Repository Structure

```
observability-stack/
├── prometheus/
│   ├── values.yaml              # kube-prometheus-stack Helm values
│   ├── alerts/
│   │   ├── kubernetes.yaml      # K8s cluster alerts
│   │   ├── slo.yaml             # SLO burn-rate alerts
│   │   ├── infrastructure.yaml  # Node, disk, network alerts
│   │   └── application.yaml     # App-level alerts
│   └── recording-rules.yaml     # Pre-computed SLI metrics
├── grafana/
│   ├── dashboards/
│   │   ├── slo-sli.json         # SLO/SLI dashboard
│   │   ├── kubernetes-cluster.json
│   │   ├── finops-cost.json     # Cloud cost dashboard
│   │   └── incident-response.json
│   └── datasources/
│       ├── prometheus.yaml
│       └── elasticsearch.yaml
├── elk/
│   ├── elasticsearch/values.yaml
│   ├── kibana/values.yaml
│   ├── fluent-bit/values.yaml
│   └── index-templates/
│       └── application-logs.json
├── alertmanager/
│   └── config.yaml              # PagerDuty + Slack routing
└── README.md
```

---

## SLO/SLI Alert Rules (Prometheus)

```yaml
# prometheus/alerts/slo.yaml
groups:
  - name: slo-burn-rate
    rules:
      # Multi-window, multi-burn-rate SLO alerts (Google SRE model)

      - alert: ErrorBudgetBurnHigh
        expr: |
          (
            rate(http_requests_total{status=~"5.."}[1h])
            / rate(http_requests_total[1h])
          ) > (14.4 * (1 - 0.999))
          and
          (
            rate(http_requests_total{status=~"5.."}[5m])
            / rate(http_requests_total[5m])
          ) > (14.4 * (1 - 0.999))
        for: 2m
        labels:
          severity: critical
          team: platform
        annotations:
          summary: "High error budget burn rate (14.4x) — 2h to exhaust"
          description: |
            Service {{ $labels.service }} is burning error budget at 14.4x
            the sustainable rate. At this rate, the monthly budget will be
            exhausted in ~2 hours.
            Current error rate: {{ $value | humanizePercentage }}
          runbook_url: "https://wiki.company.com/runbooks/error-budget-burn"

      - alert: ErrorBudgetBurnMedium
        expr: |
          (
            rate(http_requests_total{status=~"5.."}[6h])
            / rate(http_requests_total[6h])
          ) > (6 * (1 - 0.999))
          and
          (
            rate(http_requests_total{status=~"5.."}[30m])
            / rate(http_requests_total[30m])
          ) > (6 * (1 - 0.999))
        for: 15m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Medium error budget burn rate (6x) — 1d to exhaust"

      # Latency SLO — 99th percentile < 500ms
      - alert: LatencySLOBreach
        expr: |
          histogram_quantile(0.99,
            rate(http_request_duration_seconds_bucket[5m])
          ) > 0.5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "P99 latency SLO breach — {{ $value | humanizeDuration }}"

      # Availability SLO — 99.9% uptime
      - alert: AvailabilitySLOBreach
        expr: |
          avg_over_time(up[30m]) < 0.999
        labels:
          severity: critical
        annotations:
          summary: "Availability below 99.9% SLO"
```

---

## Alertmanager — PagerDuty + Slack Routing

```yaml
# alertmanager/config.yaml
global:
  resolve_timeout: 5m
  pagerduty_url: https://events.pagerduty.com/v2/enqueue

route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: slack-default

  routes:
    # Critical alerts → PagerDuty (wakes on-call)
    - match:
        severity: critical
      receiver: pagerduty-oncall
      continue: true

    # All alerts → team Slack
    - match_re:
        team: .+
      receiver: slack-team-channel

    # SLO alerts → dedicated channel
    - match:
        alertname: ErrorBudgetBurn.*
      receiver: slack-slo-channel

receivers:
  - name: pagerduty-oncall
    pagerduty_configs:
      - routing_key: $PAGERDUTY_INTEGRATION_KEY
        description: '{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}'
        details:
          firing: '{{ template "pagerduty.default.firing" . }}'
          resolved: '{{ template "pagerduty.default.resolved" . }}'
        links:
          - href: '{{ (index .Alerts 0).Annotations.runbook_url }}'
            text: Runbook

  - name: slack-slo-channel
    slack_configs:
      - api_url: $SLACK_WEBHOOK_URL
        channel: '#slo-alerts'
        title: '🔥 SLO Alert — {{ .CommonAnnotations.summary }}'
        text: |
          *Severity:* {{ .CommonLabels.severity }}
          *Service:* {{ .CommonLabels.service }}
          *Details:* {{ .CommonAnnotations.description }}
          *Runbook:* {{ .CommonAnnotations.runbook_url }}
        send_resolved: true
```

---

## Recording Rules — SLI Pre-computation

```yaml
# prometheus/recording-rules.yaml
groups:
  - name: sli-recording-rules
    interval: 30s
    rules:
      # Request success rate (5m window)
      - record: job:request_success_rate:5m
        expr: |
          1 - (
            rate(http_requests_total{status=~"5.."}[5m])
            / rate(http_requests_total[5m])
          )

      # Error budget remaining (monthly)
      - record: job:error_budget_remaining:30d
        expr: |
          1 - (
            (1 - job:request_success_rate:5m) / (1 - 0.999)
          )

      # P99 latency (per service)
      - record: job:latency_p99:5m
        expr: |
          histogram_quantile(0.99,
            sum by (service, le)(rate(http_request_duration_seconds_bucket[5m]))
          )
```

---

## Fluent Bit — Log Collection Config

```yaml
# elk/fluent-bit/values.yaml
config:
  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            cri
        Tag               kube.*
        Refresh_Interval  5
        Mem_Buf_Limit     50MB
        Skip_Long_Lines   On

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Merge_Log           On
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

    [FILTER]
        Name    grep
        Match   kube.*
        Exclude log /health|/metrics|/readyz  # Drop noisy health probes

  outputs: |
    [OUTPUT]
        Name            es
        Match           kube.*
        Host            elasticsearch-master
        Port            9200
        Logstash_Format On
        Logstash_Prefix k8s-logs
        Retry_Limit     5
        tls             On
        tls.verify      Off
```

---

## Helm Installation

```bash
# Add repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add elastic https://helm.elastic.co
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

# Deploy kube-prometheus-stack
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f prometheus/values.yaml \
  --wait

# Deploy ELK
helm upgrade --install elasticsearch elastic/elasticsearch \
  --namespace logging --create-namespace \
  -f elk/elasticsearch/values.yaml

helm upgrade --install kibana elastic/kibana \
  --namespace logging \
  -f elk/kibana/values.yaml

# Deploy Fluent Bit log collector
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace logging \
  -f elk/fluent-bit/values.yaml
```
