data "google_secret_manager_secret_version" "google_oauth_client_id" {
  secret  = "GOOGLE_OAUTH_CLIENT_ID"
  project = var.project_id
}

data "google_secret_manager_secret_version" "google_oauth_client_secret" {
  secret  = "GOOGLE_OAUTH_CLIENT_SECRET"
  project = var.project_id
}

resource "helm_release" "prometheus" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "65.0.0"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600
  wait             = true

  values = [
    templatefile("${path.module}/charts/prometheus/values-override.yaml", {
      google_oauth_client_id     = data.google_secret_manager_secret_version.google_oauth_client_id.secret_data
      google_oauth_client_secret = data.google_secret_manager_secret_version.google_oauth_client_secret.secret_data
    })
  ]

  depends_on = [
    data.terraform_remote_state.gke
  ]
}

resource "kubectl_manifest" "grafana_httproute" {
  yaml_body = file("${path.module}/charts/grafana/httproute.yaml")

  depends_on = [
    helm_release.prometheus
  ]
}

resource "kubectl_manifest" "grafana_healthcheckpolicy" {
  yaml_body = file("${path.module}/charts/grafana/healthcheckpolicy.yaml")

  depends_on = [
    helm_release.prometheus
  ]
}

output "prometheus_server_service" {
  description = "Prometheus server service name"
  value       = "kube-prometheus-stack-prometheus"
}

output "prometheus_namespace" {
  description = "Namespace where the monitoring stack is deployed"
  value       = helm_release.prometheus.namespace
}

output "prometheus_port_forward_command" {
  description = "Command to access Prometheus UI via port-forward"
  value       = "kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090"
}

output "alertmanager_port_forward_command" {
  description = "Command to access Alertmanager UI via port-forward"
  value       = "kubectl port-forward svc/kube-prometheus-stack-alertmanager -n monitoring 9093:9093"
}

output "grafana_port_forward_command" {
  description = "Command to access Grafana UI via port-forward"
  value       = "kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
}

output "grafana_admin_password_command" {
  description = "Grafana admin password (set via Helm values)"
  value       = "Password is 'prom-operator' as set in charts/prometheus/values-override.yaml"
}
