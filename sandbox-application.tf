terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -------------------------------
# VPC + Subnet
# -------------------------------
resource "google_compute_network" "vpc" {
  name                    = "vpc-sandbox"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "snet-sandbox-application"
  ip_cidr_range = "10.250.0.0/25" 
  region        = var.region
  network       = google_compute_network.vpc.id
}

# -------------------------------
# GKE Cluster
# -------------------------------
resource "google_container_cluster" "gke" {
  name     = "gke-aip-sandbox-app-se1"
  location = var.region

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  node_config {
    machine_type = "e2-medium"
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# -------------------------------
# Secondary IP Ranges for GKE
# -------------------------------
resource "google_compute_subnetwork_secondary_range" "pods" {
  subnetwork = google_compute_subnetwork.subnet.name
  range_name = "pods"
  ip_cidr_range = "172.16.0.0/16"
}

resource "google_compute_subnetwork_secondary_range" "services" {
  subnetwork = google_compute_subnetwork.subnet.name
  range_name = "services"
  ip_cidr_range = "192.168.16.0/20"
}

# -------------------------------
# Node Pools (5 namespaces → 5 node pools)
# -------------------------------
locals {
  namespaces = ["infra-namespace", "web-namespace", "hi-admin-namespace", "project-admin-namespace", "core-service-namespace"]
}

resource "google_container_node_pool" "nodepool" {
  for_each = toset(local.namespaces)

  name       = "${each.key}-pool"
  cluster    = google_container_cluster.gke.name
  location   = var.region

  node_count = 3

  node_config {
    machine_type = "e2-medium"
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    labels = {
      namespace = each.key
    }
    tags = ["gke-node", each.key]
  }
}

# -------------------------------
# Kubernetes Namespaces
# -------------------------------
provider "kubernetes" {
  host                   = google_container_cluster.gke.endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.gke.master_auth[0].cluster_ca_certificate)
}

data "google_client_config" "default" {}

resource "kubernetes_namespace" "ns" {
  for_each = toset(local.namespaces)
  metadata {
    name = each.key
  }
}
