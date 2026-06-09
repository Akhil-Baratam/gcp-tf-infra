# Get VPC network and subnet IDs from the vpc module's remote state
data "terraform_remote_state" "vpc" {
  backend   = "gcs"
  workspace = terraform.workspace
  config = {
    bucket = "cinemates-tf-state"
    prefix = "vpc"
  }
}

# GKE cluster (Standard mode with manual node pool management)
# url: https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster
resource "google_container_cluster" "gke_cluster" {
  name     = "${var.project_name}-${var.environment}"
  location = var.zone
  project  = var.project_id

  min_master_version       = var.gke_version
  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    disk_type    = "pd-standard"
    disk_size_gb = 50
  }

  network    = data.terraform_remote_state.vpc.outputs.vpc_network_id
  subnetwork = data.terraform_remote_state.vpc.outputs.gke_subnet_id
  
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  resource_labels = local.all_labels
  # Enable dataplane v2 (advanced CNI)
  # datapath_provider = "ADVANCED_DATAPATH"
  deletion_protection = false

  # Ignore changes to node_config because remove_default_node_pool deletes it, 
  # causing Terraform to constantly want to replace the cluster.
  lifecycle {
    ignore_changes = [node_config]
  }
}

# GKE Service Account
resource "google_service_account" "gke_sa" {
  account_id   = "${var.project_name}-${var.environment}-sa"
  display_name = "Service Account for GKE nodes"
  project      = var.project_id
}

# Grant necessary minimum roles to the GKE Service Account
resource "google_project_iam_member" "gke_sa_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader" # Optional, but highly recommended if using GCP Artifact Registry
  ])

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

# Node pool
# url: https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_node_pool
resource "google_container_node_pool" "gke_node_pool" {
  for_each = var.node_pools
  name       = "${var.project_name}-${each.key}"
  cluster    = google_container_cluster.gke_cluster.id
  node_count = each.value.node_count
  version    = var.gke_version

  node_config {
    preemptible     = each.value.preemptible
    machine_type    = each.value.machine_type
    disk_size_gb    = each.value.disk_size_gb
    disk_type       = each.value.disk_type
    labels          = local.all_labels
    service_account = google_service_account.gke_sa.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  # Ignore version changes so Terraform doesn't perpetually try to revert the 
  # exact patch version (1.33.11) back to the short version (1.33).
  # Ignore node_config.resource_labels because GKE auto-injects internal GCP
  # resource labels (e.g. goog-gke-node-pool-provisioning-model=spot for
  # preemptible nodes) that are not in our config, causing a perpetual
  # in-place update diff on every apply.
  lifecycle {
    ignore_changes = [
      version,
      node_config[0].resource_labels,
    ]
  }
}
