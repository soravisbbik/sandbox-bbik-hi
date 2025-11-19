# Required providers
terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source = "hashicorp/google-beta"
      version = "~> 5.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

# --- Google Provider Configuration ---
# Replace 'YOUR_PROJECT_ID' and 'YOUR_REGION'
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# --- 1. Network and Subnet Setup ---

# Create the VPC Network
resource "google_compute_network" "gke_network" {
  name                    = "vpc-sandbox"
  auto_create_subnetworks = false
}

# Create the Subnet with the specified IP range for nodes
resource "google_compute_subnetwork" "gke_subnet" {
  name          = "snet-sandbox-gke-portal"
  ip_cidr_range = "10.250.0.0/25" # Nodes IP Range (10.250.0.0/25)
  region        = var.region
  network       = google_compute_network.gke_network.self_link

  # Secondary range for Pods (172.16.0.0/16)
  secondary_ip_range {
    range_name    = "gke-pods-range"
    ip_cidr_range = "172.16.0.0/16"
  }

  # Secondary range for Services (192.168.16.0/20)
  secondary_ip_range {
    range_name    = "gke-services-range"
    ip_cidr_range = "192.168.16.0/20"
  }
}

# --- 2. GKE Cluster Provisioning ---

resource "google_container_cluster" "primary" {
  name                     = "gke-aip-sandbox-app-se1"
  location                 = var.region
  network                  = google_compute_network.gke_network.self_link
  subnetwork               = google_compute_subnetwork.gke_subnet.self_link
  initial_node_count       = 1 # GKE best practice: use node_pool resource instead for explicit configuration

  # Enable IP alias for VPC-native cluster
  ip_allocation_policy {
    cluster_secondary_range_name = google_compute_subnetwork.gke_subnet.secondary_ip_range[0].range_name # Pods
    services_secondary_range_name = google_compute_subnetwork.gke_subnet.secondary_ip_range[1].range_name # Services
  }

  # We are defining the node pool explicitly below, so remove the default one
  remove_default_node_pool = true
  
  # Configuration for master auth and connectivity
  master_auth {
    client_certificate_config {
      issue_client_certificate = true
    }
  }
}

# Explicit Node Pool with 3 nodes
resource "google_container_node_pool" "primary_nodes" {
  name       = "default-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = 3 # 3 Nodes as requested
  
  node_config {
    machine_type = "e2-medium" # Example machine type
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  # version = "1.27"
}

# --- 3. Kubernetes Provider Configuration ---

# Setup the K8s provider to talk to the newly created GKE cluster
provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}

data "google_client_config" "default" {}

# --- 4. Create 5 Namespaces ---

# Generate 5 unique namespace names
resource "kubernetes_namespace" "app_namespaces" {
  for_each = toset([
    "infra-namespace",
    "web-namespace",
    "hi-admin-namespace",
    "project-admin-namespace",
    "core-service-namespace",
  ])
  metadata {
    name = each.key
  }
  # This dependency ensures the cluster is fully up before attempting to create namespaces
  depends_on = [google_container_cluster.primary] 
}

# --- Outputs ---

output "gke_cluster_endpoint" {
  value = google_container_cluster.primary.endpoint
}

output "node_pool_size" {
  value = google_container_node_pool.primary_nodes.node_count
}