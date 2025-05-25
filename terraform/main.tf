terraform {
  required_version = ">= 1.3.0"
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

# Use existing VPC named "lab2-vpc"
data "google_compute_network" "lab2_vpc" {
  name = "lab2-vpc"
}
  
resource "google_compute_subnetwork" "management" {
  name          = "management-subnet-ak"
  ip_cidr_range = "10.55.1.0/24"  # your management subnet CIDR
  region        = var.region
  network       = data.google_compute_network.lab2_vpc.id
}


resource "google_compute_subnetwork" "restricted" {
  name          = "restricted-subnet-ak"
  ip_cidr_range = "10.66.3.0/24"
  region        = var.region
  network       = data.google_compute_network.lab2_vpc.id

  purpose = "PRIVATE"
  role    = "ACTIVE"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.67.0.0/16"    # non-overlapping, in 10.66.x.x range
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.68.0.0/20"  # non-overlapping
  }
}


# Enable required APIs
resource "google_project_service" "services" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com"
  ])
  service = each.key
}

# NAT Router for management subnet
resource "google_compute_router" "nat_router" {
  name    = "nat-router-un"
  network = data.google_compute_network.lab2_vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat_gateway" {
  name                               = "nat-gateway-ak"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.management.name
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# Artifact Registry
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "devops-demo"
  description   = "Docker repo"
  format        = "DOCKER"
}

# GKE Node Service Account
resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes-sa"
  display_name = "GKE Nodes Service Account"
}

resource "google_project_iam_member" "artifact_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# GKE Cluster
resource "google_container_cluster" "primary" {
  name       = "private-gke-cluster-ak"
  #location   = var.region
  location       = "${var.region}-a"
  network    = data.google_compute_network.lab2_vpc.name
  subnetwork = google_compute_subnetwork.restricted.name

  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.16.1.0/28"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "10.10.1.0/24"
      display_name = "management-subnet"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  depends_on = [google_project_service.services]
}

# GKE Node Pool
resource "google_container_node_pool" "primary_nodes" {
  name       = "primary-node-pool-ak"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = 1

  node_config {
    machine_type    = "e2-medium"
    disk_size_gb    = 10
    disk_type       = "pd-standard"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
  
 

  depends_on = [google_service_account.gke_nodes]
}

# Private VM (management VM, no public IP)
resource "google_compute_instance" "management_vm" {
  name         = "management-vm-ak"
  machine_type = "e2-medium"
  zone         = "${var.region}-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.management.name
    # No access_config block means no public IP
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gnupg
    curl -fsSLo /usr/share/keyrings/cloud.google.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
    apt-get update
    apt-get install -y kubectl
  EOT
}


