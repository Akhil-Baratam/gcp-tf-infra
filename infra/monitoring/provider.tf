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

# Configure kubectl provider using GKE cluster details
provider "kubectl" {
  host                   = "https://${data.terraform_remote_state.gke.outputs.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.terraform_remote_state.gke.outputs.cluster_ca_certificate)
  load_config_file       = false
}
