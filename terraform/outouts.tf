# Outputs
output "management_vm_private_ip" {
  value = google_compute_instance.management_vm.network_interface[0].network_ip
}

output "gke_cluster_name" {
  value = google_container_cluster.primary.name
}

output "artifact_registry_repo" {
  value = google_artifact_registry_repository.repo.repository_id
}