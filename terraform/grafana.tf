# Alerting in Grafana Cloud (ADR-0011): it evaluates off-box, so it still
# fires when core-01 itself is down. Metrics come from Alloy
# (platform/alloy/config.alloy); thresholds follow the RAM budget in PLAN.md.
#
# Rules route straight to the email contact point (notification_settings),
# so the stack's notification policy tree is left untouched.

locals {
  # Every rule: PromQL instant query (A) -> threshold (C) fires when A > threshold.
  # Absence rules return 1 when the series is gone, hence threshold 0.
  alert_rules = {
    memory_high = {
      severity  = "warning"
      name      = "Host memory above 85%"
      expr      = "100 * (1 - node_memory_MemAvailable_bytes{instance=\"${var.server_name}\"} / node_memory_MemTotal_bytes{instance=\"${var.server_name}\"})"
      threshold = 85
      for       = "10m"
      summary   = "Memory on {{ $labels.instance }} is at {{ humanize $values.A.Value }}%."
    }
    swap_high = {
      severity  = "warning"
      name      = "Host swap above 1 GiB"
      expr      = "node_memory_SwapTotal_bytes{instance=\"${var.server_name}\"} - node_memory_SwapFree_bytes{instance=\"${var.server_name}\"}"
      threshold = 1073741824
      for       = "10m"
      summary   = "{{ humanize1024 $values.A.Value }}B of swap in use on {{ $labels.instance }}."
    }
    disk_high = {
      severity  = "warning"
      name      = "Disk above 80%"
      expr      = "100 * (1 - node_filesystem_avail_bytes{instance=\"${var.server_name}\"} / node_filesystem_size_bytes{instance=\"${var.server_name}\"})"
      threshold = 80
      for       = "15m"
      summary   = "{{ $labels.mountpoint }} on {{ $labels.instance }} is {{ humanize $values.A.Value }}% full."
    }
    container_restarts = {
      severity  = "warning"
      name      = "Container restarting"
      expr      = "changes(container_start_time_seconds{instance=\"${var.server_name}\", name!=\"\"}[15m])"
      threshold = 3
      for       = "0s"
      summary   = "Container {{ $labels.name }} restarted {{ $values.A.Value }} times in 15 minutes."
    }
    caddy_down = {
      severity  = "critical"
      name      = "Caddy not running"
      expr      = "absent(container_last_seen{instance=\"${var.server_name}\", name=\"caddy\"})"
      threshold = 0
      for       = "5m"
      summary   = "No caddy container seen on ${var.server_name} for 5 minutes: every site is down."
    }
    metrics_missing = {
      severity  = "critical"
      name      = "Host metrics missing"
      expr      = "absent(up{job=\"integrations/node_exporter\", instance=\"${var.server_name}\"} == 1)"
      threshold = 0
      for       = "10m"
      summary   = "No node metrics from ${var.server_name} for 10 minutes: the host or Alloy is down."
    }
  }
}

data "grafana_data_source" "prometheus" {
  name = var.grafana_prometheus_name
}

resource "grafana_folder" "platform" {
  title = "project-infra"
}

resource "grafana_contact_point" "email" {
  name = "project-infra email"

  email {
    addresses = [var.alert_email]
    subject   = "[project-infra] {{ .CommonLabels.alertname }} ({{ .Status }})"
  }
}

resource "grafana_rule_group" "host" {
  name             = "core-01"
  folder_uid       = grafana_folder.platform.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.alert_rules

    content {
      name      = rule.value.name
      condition = "C"
      for       = rule.value.for
      # Missing data has its own rule (metrics_missing); don't page twice.
      no_data_state  = "OK"
      exec_err_state = "Error"

      labels = {
        severity = rule.value.severity
        host     = var.server_name
      }

      annotations = {
        summary = rule.value.summary
        runbook = "https://github.com/${var.github_user}/project-infra/blob/main/docs/runbook.md"
      }

      notification_settings {
        contact_point = grafana_contact_point.email.name
      }

      data {
        ref_id         = "A"
        datasource_uid = data.grafana_data_source.prometheus.uid

        relative_time_range {
          from = 600
          to   = 0
        }

        model = jsonencode({
          refId   = "A"
          expr    = rule.value.expr
          instant = true
          range   = false
        })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"

        relative_time_range {
          from = 0
          to   = 0
        }

        model = jsonencode({
          refId      = "C"
          type       = "threshold"
          expression = "A"
          datasource = { type = "__expr__", uid = "__expr__" }
          conditions = [{ evaluator = { type = "gt", params = [rule.value.threshold] } }]
        })
      }
    }
  }
}
