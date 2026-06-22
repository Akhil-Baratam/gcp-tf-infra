terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    grafana = {
      source  = "grafana/grafana"
      version = ">= 2.9.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Get GKE cluster details from remote state
data "terraform_remote_state" "gke" {
  backend   = "gcs"
  workspace = terraform.workspace
  config = {
    bucket = "cinemates-tf-state"
    prefix = "gke"
  }
}

# Configure Kubernetes provider using GKE cluster details
provider "kubernetes" {
  host                   = "https://${data.terraform_remote_state.gke.outputs.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.terraform_remote_state.gke.outputs.cluster_ca_certificate)
}

# Configure Helm provider using GKE cluster details
provider "helm" {
  kubernetes {
    host                   = "https://${data.terraform_remote_state.gke.outputs.cluster_endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(data.terraform_remote_state.gke.outputs.cluster_ca_certificate)
  }
}

data "google_client_config" "default" {}

# Read Grafana admin password from the secret created by the Helm chart.
# This is always valid and survives pod restarts (unlike service account tokens,
# which are stored in Grafana's DB and lost when persistence is disabled).
data "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "kube-prometheus-stack-grafana"
    namespace = "monitoring"
  }
}

# Configure kubectl provider using GKE cluster details
provider "kubectl" {
  host                   = "https://${data.terraform_remote_state.gke.outputs.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.terraform_remote_state.gke.outputs.cluster_ca_certificate)
  load_config_file       = false
}

provider "grafana" {
  url  = "http://grafana.34.49.38.142.nip.io"
  auth = "admin:${data.kubernetes_secret.grafana_admin.data["admin-password"]}"
}
