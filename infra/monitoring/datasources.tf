resource "grafana_data_source" "loki" {
  name = "Loki"
  type = "loki"
  uid  = "loki"
  url  = "http://loki.monitoring.svc.cluster.local:3100"

  json_data_encoded = jsonencode({
    maxLines = 1000
  })
}