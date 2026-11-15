# Se ejecuta una sola vez desde tu equipo, con `az login`. Crea lo que GitHub Actions necesita antes de
}

resource "azurerm_resource_group" "state" {
  name     = "rg-ledger-tfstate"
  location = var.location
  tags     = { project = "eci-ledger-lab", managed_by = "terraform" }
}

resource "azurerm_storage_account" "state" {
  #checkov:skip=CKV_AZURE_33:No se usa el servicio de colas en esta cuenta
  #checkov:skip=CKV_AZURE_59:Terraform corre desde tu equipo; el acceso exige Entra ID y claves desactivadas
  #checkov:skip=CKV_AZURE_206:LRS basta: el estado se versiona y puede reconstruirse en un laboratorio
  #checkov:skip=CKV2_AZURE_33:Un private endpoint cuesta cerca de 7 USD al mes y exige una VNet
  #checkov:skip=CKV2_AZURE_1:La llave administrada por Microsoft basta; CMK exige mas infraestructura
  name                            = "stledger${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.state.name
  location                        = azurerm_resource_group.state.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_0"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # Solo Entra ID: el estado contiene secretos.
  default_to_oauth_authentication = true
  tags                            = azurerm_resource_group.state.tags

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_role_assignment" "state_owner" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.state_owner]
  create_duration = "90s"
}

resource "azurerm_storage_container" "state" {
  #checkov:skip=CKV2_AZURE_21:Los logs de diagnostico del blob se cobran; el acceso ya exige Entra ID
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
  depends_on            = [time_sleep.rbac_propagation]
}

# Identidad de GitHub Actions. No es un service principal con secreto: no hay contrasena que guardar.
resource "azurerm_user_assigned_identity" "github" {
  name                = "id-ledger-github"
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location
  tags                = azurerm_resource_group.state.tags
}

# Azure solo acepta tokens de este repositorio y de estos dos GitHub Environments. Se registran los
# dos formatos de subject: con nombres (repositorios anteriores) y con ID numericos (los nuevos).
locals {
  github_subjects = merge(
    { for environment in ["dev", "prod"] : "github-${environment}" => "repo:${var.github_repository}:environment:${environment}" },
    var.github_repository_ids == null ? {} : {
      for environment in ["dev", "prod"] : "github-${environment}-ids" => "repo:${var.github_repository_ids}:environment:${environment}"
    },
  )
}

resource "azurerm_federated_identity_credential" "github" {
  for_each = local.github_subjects

  name                      = each.key
  user_assigned_identity_id = azurerm_user_assigned_identity.github.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = each.value
}

locals {
  subscription_scope = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"

  # Key Vault Secrets Officer y Key Vault Secrets User: los unicos roles que el pipeline puede asignar.
