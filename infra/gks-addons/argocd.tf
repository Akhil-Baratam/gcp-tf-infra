# ArgoCD Deployment using Helm
# This deploys ArgoCD to the GKE cluster for GitOps-based application delivery

# Fetch GitHub PAT from Google Secret Manager
data "google_secret_manager_secret_version" "github_pat" {
  secret  = "GITHUB_PAT_ARGOCD_TOKEN"
  project = var.project_id
}

# Fetch Google OAuth Client ID from Google Secret Manager
data "google_secret_manager_secret_version" "google_oauth_client_id" {
  secret  = "GOOGLE_OAUTH_CLIENT_ID"
  project = var.project_id
}

# Fetch Google OAuth Client Secret from Google Secret Manager
data "google_secret_manager_secret_version" "google_oauth_client_secret" {
  secret  = "GOOGLE_OAUTH_CLIENT_SECRET"
  project = var.project_id
}

# Create Kubernetes secret for GitHub repository credentials
resource "kubernetes_secret" "argocd_repo_creds" {
  metadata {
    name      = "github-repo-creds"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = "https://github.com/tenex-ai/gcp-tf-infra.git"
    password = data.google_secret_manager_secret_version.github_pat.secret_data
    username = "not-used"
  }

  depends_on = [
    helm_release.argocd
  ]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.12"
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600
  wait             = true

  values = [
    templatefile("${path.module}/charts/argocd/value.yaml", {
      google_oauth_client_id     = data.google_secret_manager_secret_version.google_oauth_client_id.secret_data
      google_oauth_client_secret = data.google_secret_manager_secret_version.google_oauth_client_secret.secret_data
    })
  ]

  depends_on = [
    data.terraform_remote_state.gke
  ]
}

# Output the ArgoCD server service details
output "argocd_server_service" {
  description = "ArgoCD server service name"
  value       = "argocd-server"
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is deployed"
  value       = helm_release.argocd.namespace
}

output "argocd_admin_password_command" {
  description = "Command to retrieve ArgoCD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "argocd_port_forward_command" {
  description = "Command to access ArgoCD UI via port-forward"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

# Deploy Root Application (App of Apps pattern)
resource "kubectl_manifest" "argocd_root_app" {
  yaml_body = file("${path.module}/charts/argo-root-app/root-app.yaml")

  depends_on = [
    helm_release.argocd
  ]
}

output "argocd_root_app" {
  description = "Root application for app-of-apps pattern"
  value       = "root-app deployed in argocd namespace"
}

# Deploy HTTPRoute to expose ArgoCD UI on the Gateway Load Balancer
resource "kubectl_manifest" "argocd_httproute" {
  yaml_body = file("${path.module}/charts/argocd/httproute.yaml")

  depends_on = [
    helm_release.argocd
  ]
}
