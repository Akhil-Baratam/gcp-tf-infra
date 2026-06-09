project_id   = "cinemates-497209"
project_name = "cinemates"
region       = "us-east1"
zone         = "us-east1-b"
gke_version  = "1.33"
environment  = "dev"


node_pools = {
  "nodepool-1" = {
    node_count   = 2
    machine_type = "e2-medium"
    preemptible  = true
    disk_size_gb = 50
    disk_type    = "pd-standard"
  }
  "nodepool-2" = {
    node_count = 1
    machine_type = "e2-standard-2"
    preemptible = false
    disk_size_gb = 50
    disk_type = "pd-standard"
  }
}


labels = {
  team        = "platform"
  cost-center = "engineering"
  managed-by  = "terraform"
}
