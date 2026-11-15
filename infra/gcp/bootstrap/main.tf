terraform {
  required_version = ">= 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.location
}

variable "project_id" {
  description = "Proyecto de GCP donde vive el bucket de estado y el pool OIDC."
  type        = string
}

variable "location" {
  description = "Region de GCP."
  type        = string
  default     = "us-east1"
}

variable "github_repository" {
  description = "Repositorio como usuario/repositorio."
  type        = string
}

variable "github_repository_ids" {
  description = "Repositorio con IDs numericos usuario@id_owner/repo@id_repo."
  type        = string
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "google_storage_bucket" "state" {
  #checkov:skip=CKV_GCP_62:Es el bucket de estado de laboratorio; el acceso ya esta restringido por IAM
  name                        = "tfstate-ledger-${random_string.suffix.result}"
  location                    = var.location
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }
}

resource "google_service_account" "github" {
  account_id   = "id-ledger-github"
  display_name = "Identidad OIDC de GitHub Actions para Ledger Lab"
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "ledger-pool-${random_string.suffix.result}"
  display_name              = "Ledger GitHub Pool"
}

locals {
  owner_id = split("@", split("/", var.github_repository_ids)[0])[1]
  repo_id  = split("@", split("/", var.github_repository_ids)[1])[1]
  github_subjects = {
    for env in ["dev", "prod"] :
    env => "repo:${var.github_repository}:environment:${env}"
  }
}

resource "google_iam_workload_identity_pool_provider" "github" {
  #checkov:skip=CKV_GCP_125:Pool OIDC restringido por repo
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Actions OIDC"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_id"    = "assertion.repository_id"
    "attribute.repository_owner" = "assertion.repository_owner_id"
  }

  attribute_condition = "assertion.repository_id=='${local.repo_id}' && assertion.repository_owner_id=='${local.owner_id}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "wif" {
  for_each           = local.github_subjects
  service_account_id = google_service_account.github.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/${each.value}"
}

resource "google_storage_bucket_iam_member" "state_admin" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.github.email}"
}

resource "google_project_iam_member" "github_roles" {
  #checkov:skip=CKV_GCP_49:La identidad del pipeline crea Cloud Run y Secret Manager en el proyecto del laboratorio
  #checkov:skip=CKV_GCP_41:Service account user para Cloud Run
  for_each = toset([
    "roles/run.admin",
    "roles/secretmanager.admin",
    "roles/logging.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.github.email}"
}

output "azure_client_id" {
  description = "Email de la cuenta de servicio (equivalente a AZURE_CLIENT_ID)."
  value       = google_service_account.github.email
}

output "azure_tenant_id" {
  description = "Nombre completo del proveedor WIF (equivalente a AZURE_TENANT_ID)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "azure_subscription_id" {
  description = "Project ID de GCP (equivalente a AZURE_SUBSCRIPTION_ID)."
  value       = var.project_id
}

output "resource_group_name" {
  value = "rg-ledger-tfstate"
}

output "storage_account_name" {
  value = google_storage_bucket.state.name
}

output "container_name" {
  value = "tfstate"
}
