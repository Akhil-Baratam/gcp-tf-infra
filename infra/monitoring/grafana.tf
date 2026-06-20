# Grafana Deployment using Helm
# This deploys Grafana to the GKE cluster for metrics visualization and dashboards

resource "helm_release" "grafana" {
  name             = "grafana"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "grafana"
  version          = "10.5.15"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600
  wait             = true

  values = [
    file("${path.module}/charts/grafana/value.yaml")
  ]

  depends_on = [
    data.terraform_remote_state.gke
  ]
}

# Deploy HTTPRoute to expose Grafana UI on the Gateway Load Balancer

resource "kubectl_manifest" "grafana_httproute" {

  yaml_body = file("${path.module}/charts/grafana/httproute.yaml")

  depends_on = [
    helm_release.grafana
  ]
  
}

output "grafana_server_service" {
  description = "Grafana server service name"
  value       = "grafana"
}

output "grafana_namespace" {
  description = "Namespace where Grafana is deployed"
  value       = helm_release.grafana.namespace
}

output "grafana_port_forward_command" {
  description = "Command to access Grafana UI via port-forward"
  value       = "kubectl port-forward svc/grafana -n monitoring 3000:80"
}

output "grafana_admin_password_command" {
  description = "Command to retrieve Grafana admin password"
  value       = "kubectl get secret -n monitoring grafana -o jsonpath='{.data.admin-password}' | base64 -d"
}
