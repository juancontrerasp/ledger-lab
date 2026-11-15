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
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.location
}

variable "project_id" {
  type = string
}

variable "environment" {
  type = string
}

variable "location" {
  type    = string
  default = "us-east1"
}

variable "database_location" {
  type    = string
  default = "us-east1"
}

variable "image" {
  type = string
  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.image))
    error_message = "La imagen debe fijarse por digest: registro/imagen@sha256:..."
  }
}

variable "max_replicas" {
  type    = number
  default = 1
}

variable "jwt_minutes" {
  type    = number
  default = 60
}

locals {
  name    = "ledger-${var.environment}"
  is_prod = var.environment == "prod"
  labels = {
    project     = "eci-ledger-lab"
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "random_password" "db_admin" {
  length  = 32
  special = false
}

# Equivalente a Key Vault + 2 secretos (database-url y jwt-secret)
resource "google_secret_manager_secret" "secrets" {
  for_each = toset(["database-url", "jwt-secret"])

  secret_id = "kv-${var.environment}-${each.key}-${random_string.suffix.result}"
  labels    = local.labels

  replication {
    auto {}
  }
}

locals {
  secret_values = {
    "database-url" = "sqlite:////data/ledger-${var.environment}.db"
    "jwt-secret"   = random_password.jwt.result
  }
}

resource "google_secret_manager_secret_version" "versions" {
  for_each = google_secret_manager_secret.secrets

  secret      = each.value.id
  secret_data = local.secret_values[each.key]
}

# Identidad asignada por el usuario para la aplicacion (solo lectura de secretos)
resource "google_service_account" "app" {
  account_id   = "id-${local.name}-${random_string.suffix.result}"
  display_name = "Identidad de solo lectura de secretos para ${local.name}"
}

resource "google_secret_manager_secret_iam_member" "secrets_reader" {
  for_each = google_secret_manager_secret.secrets

  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app.email}"
}

# Equivalente a Log Analytics Workspace (solo en prod, con retencion de 30 dias)
resource "google_logging_project_bucket_config" "prod_logs" {
  count = local.is_prod ? 1 : 0

  project        = var.project_id
  location       = "global"
  retention_days = 30
  bucket_id      = "log-${local.name}-${random_string.suffix.result}"
}

# Equivalente a Container App (escala de 0 a max_replicas, 0.25 vCPU / 0.5 GiB, secretos desde Secret Manager)
resource "google_cloud_run_v2_service" "this" {
  name                = "ca-${local.name}"
  location            = var.location
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false
  labels              = local.labels

  depends_on = [
    google_secret_manager_secret_version.versions,
    google_secret_manager_secret_iam_member.secrets_reader,
  ]

  template {
    service_account                  = google_service_account.app.email
    max_instance_request_concurrency = 1

    scaling {
      min_instance_count = 0
      max_instance_count = var.max_replicas
    }

    containers {
      name  = "ledger"
      image = var.image

      ports {
        container_port = 8000
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      env {
        name  = "APP_ENV"
        value = var.environment
      }

      env {
        name  = "JWT_MINUTES"
        value = tostring(var.jwt_minutes)
      }

      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["database-url"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "JWT_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["jwt-secret"].secret_id
            version = "latest"
          }
        }
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = 8000
        }
        initial_delay_seconds = 2
        period_seconds        = 5
        failure_threshold     = 12
      }

      liveness_probe {
        http_get {
          path = "/healthz"
          port = 8000
        }
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  #checkov:skip=CKV_GCP_102:La aplicacion web y API publica de Ledger se protege con JWT propio
  project  = var.project_id
  location = google_cloud_run_v2_service.this.location
  name     = google_cloud_run_v2_service.this.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "app_url" {
  value = google_cloud_run_v2_service.this.uri
}

output "resource_group_name" {
  value = "rg-${local.name}"
}
