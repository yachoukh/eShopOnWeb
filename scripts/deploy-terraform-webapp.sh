#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_TF_DIR="$(cd "$APP_ROOT/../eshop-iac" && pwd)"

TF_DIR="$DEFAULT_TF_DIR"
CONFIGURATION="Release"
ARTIFACT_ROOT="$APP_ROOT/.artifacts"
WEB_OUTPUT_DIR="$ARTIFACT_ROOT/webapp"
WEB_PACKAGE_PATH="$WEB_OUTPUT_DIR/Web.zip"
WEB_HEALTH_PATH="/health"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
WEBAPP_NAME="${AZURE_WEBAPP_NAME:-}"
WEBAPP_URL="${AZURE_WEBAPP_URL:-}"
PUBLICAPI_NAME="${AZURE_PUBLICAPI_NAME:-}"
PUBLICAPI_URL="${AZURE_PUBLICAPI_URL:-}"
PUBLICAPI_RESOURCE_GROUP="${AZURE_PUBLICAPI_RESOURCE_GROUP:-}"
PUBLICAPI_OUTPUT_DIR="$ARTIFACT_ROOT/publicapi"
PUBLICAPI_PACKAGE_PATH="$PUBLICAPI_OUTPUT_DIR/PublicApi.zip"
PUBLICAPI_HEALTH_PATH="/swagger/v1/swagger.json"
DEPLOY_PUBLIC_API=false

usage() {
  cat <<'EOF'
Usage: deploy-terraform-webapp.sh [options]

Deploys eShopOnWeb/src/Web into the App Service provisioned by ../eshop-iac.
The app performs EF Core migrations and seeding during startup, so this script
deploys the package, sets the host-specific app setting, restarts the app, and
waits for the health endpoint to respond.

Optionally, the same script can deploy PublicApi into a separate, already-existing
App Service. PublicApi deployment is disabled by default because the current
Terraform stack does not provision that second app.

Options:
  --tf-dir PATH            Terraform directory. Default: ../eshop-iac
  --subscription ID        Azure subscription id or name. Optional.
  --resource-group NAME    Override inferred resource group name.
  --webapp-name NAME       Override inferred web app name.
  --webapp-url URL         Override inferred web app URL.
  --configuration NAME     Dotnet build configuration. Default: Release
  --web-health-path PATH   Web health endpoint path. Default: /health
  --deploy-public-api      Also deploy src/PublicApi to an existing App Service.
  --publicapi-name NAME    Existing PublicApi App Service name.
  --publicapi-url URL      PublicApi URL, usually https://<app>.azurewebsites.net.
  --publicapi-resource-group NAME
                           Resource group for PublicApi. Defaults to --resource-group.
  --publicapi-health-path PATH
                           PublicApi readiness path. Default: /swagger/v1/swagger.json
  --artifact-root PATH     Artifact root directory. Default: .artifacts
  --skip-build             Reuse an existing package in the output directory.
  -h, --help               Show this help.

Environment overrides:
  AZURE_SUBSCRIPTION_ID
  AZURE_RESOURCE_GROUP
  AZURE_WEBAPP_NAME
  AZURE_WEBAPP_URL
  AZURE_PUBLICAPI_NAME
  AZURE_PUBLICAPI_URL
  AZURE_PUBLICAPI_RESOURCE_GROUP
EOF
}

log() {
  printf '[deploy] %s\n' "$*"
}

fail() {
  printf '[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

terraform_output() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

infer_resource_group() {
  local env_name
  env_name="$(sed -nE 's/^environment_name[[:space:]]*=[[:space:]]*"([^"]+)"/\1/p' "$TF_DIR/terraform.tfvars" | head -n 1)"
  [[ -n "$env_name" ]] || fail "Unable to infer environment_name from $TF_DIR/terraform.tfvars"
  printf 'rg-%s' "$env_name"
}

normalize_base_url() {
  printf '%s/' "${1%/}"
}

host_from_url() {
  printf '%s' "$1" | sed -E 's#https?://([^./]+).*#\1#'
}

publish_project_zip() {
  local project_path="$1"
  local output_dir="$2"
  local package_path="$3"

  rm -rf "$output_dir"
  mkdir -p "$output_dir"
  dotnet publish "$project_path" --configuration "$CONFIGURATION" --output "$output_dir/publish"
  rm -f "$package_path"
  (
    cd "$output_dir/publish"
    zip -qr "$package_path" .
  )
}

deploy_zip_to_webapp() {
  local resource_group="$1"
  local app_name="$2"
  local package_path="$3"

  az webapp show --resource-group "$resource_group" --name "$app_name" --output none \
    || fail "Azure Web App '$app_name' was not found in resource group '$resource_group'"

  az webapp deploy \
    --resource-group "$resource_group" \
    --name "$app_name" \
    --src-path "$package_path" \
    --type zip \
    --clean true \
    --restart true \
    --output none

  az webapp restart --resource-group "$resource_group" --name "$app_name" --output none
}

wait_for_health() {
  local label="$1"
  local health_url="$2"

  log "Waiting for $label startup and database migrations"
  for attempt in $(seq 1 30); do
    local status_code
    status_code="$(curl -ksS -o /tmp/eshop-health.json -w '%{http_code}' "$health_url" || true)"
    if [[ "$status_code" == "200" ]]; then
      log "$label health endpoint responded successfully: $health_url"
      cat /tmp/eshop-health.json
      printf '\n'
      return 0
    fi

    log "$label health check attempt $attempt/30 returned HTTP $status_code"
    sleep 10
  done

  fail "Timed out waiting for $health_url. Check App Service logs with: bash $APP_ROOT/scripts/tail-appservice-logs.sh --resource-group $RESOURCE_GROUP --webapp-name $WEBAPP_NAME"
}

key_vault_secret() {
  local vault_name="$1"
  local secret_name="$2"
  az keyvault secret show --vault-name "$vault_name" --name "$secret_name" --query value -o tsv
}

SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tf-dir)
      TF_DIR="$2"
      shift 2
      ;;
    --subscription)
      SUBSCRIPTION_ID="$2"
      shift 2
      ;;
    --resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    --webapp-name)
      WEBAPP_NAME="$2"
      shift 2
      ;;
    --webapp-url)
      WEBAPP_URL="$2"
      shift 2
      ;;
    --artifact-root)
      ARTIFACT_ROOT="$2"
      WEB_OUTPUT_DIR="$ARTIFACT_ROOT/webapp"
      WEB_PACKAGE_PATH="$WEB_OUTPUT_DIR/Web.zip"
      PUBLICAPI_OUTPUT_DIR="$ARTIFACT_ROOT/publicapi"
      PUBLICAPI_PACKAGE_PATH="$PUBLICAPI_OUTPUT_DIR/PublicApi.zip"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    --web-health-path)
      WEB_HEALTH_PATH="$2"
      shift 2
      ;;
    --deploy-public-api)
      DEPLOY_PUBLIC_API=true
      shift
      ;;
    --publicapi-name)
      PUBLICAPI_NAME="$2"
      shift 2
      ;;
    --publicapi-url)
      PUBLICAPI_URL="$2"
      shift 2
      ;;
    --publicapi-resource-group)
      PUBLICAPI_RESOURCE_GROUP="$2"
      shift 2
      ;;
    --publicapi-health-path)
      PUBLICAPI_HEALTH_PATH="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

require_command az
require_command dotnet
require_command terraform
require_command zip
require_command curl

[[ -d "$TF_DIR" ]] || fail "Terraform directory not found: $TF_DIR"
[[ -f "$TF_DIR/terraform.tfvars" ]] || fail "terraform.tfvars not found in: $TF_DIR"

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  log "Setting Azure subscription to $SUBSCRIPTION_ID"
  az account set --subscription "$SUBSCRIPTION_ID"
fi

az account show >/dev/null 2>&1 || fail "Azure CLI is not logged in. Run 'az login' first."

if [[ -z "$WEBAPP_URL" ]]; then
  WEBAPP_URL="$(terraform_output web_app_url)"
fi

if [[ -z "$WEBAPP_NAME" ]]; then
  WEBAPP_NAME="$(host_from_url "$WEBAPP_URL")"
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  RESOURCE_GROUP="$(infer_resource_group)"
fi

if [[ -z "$PUBLICAPI_RESOURCE_GROUP" ]]; then
  PUBLICAPI_RESOURCE_GROUP="$RESOURCE_GROUP"
fi

[[ -n "$WEBAPP_URL" ]] || fail "Unable to resolve web app URL"
[[ -n "$WEBAPP_NAME" ]] || fail "Unable to resolve web app name"
[[ -n "$RESOURCE_GROUP" ]] || fail "Unable to resolve resource group"

log "Using Terraform directory: $TF_DIR"
log "Using resource group: $RESOURCE_GROUP"
log "Using web app: $WEBAPP_NAME"
log "Using web app URL: $WEBAPP_URL"

WEB_BASE_URL="$(normalize_base_url "$WEBAPP_URL")"
PUBLICAPI_BASE_URL=""
if [[ -n "$PUBLICAPI_URL" ]]; then
  PUBLICAPI_BASE_URL="$(normalize_base_url "$PUBLICAPI_URL")"
fi

if [[ "$SKIP_BUILD" == false ]]; then
  log "Publishing src/Web"
  publish_project_zip "$APP_ROOT/src/Web/Web.csproj" "$WEB_OUTPUT_DIR" "$WEB_PACKAGE_PATH"

  if [[ "$DEPLOY_PUBLIC_API" == true ]]; then
    log "Publishing src/PublicApi"
    publish_project_zip "$APP_ROOT/src/PublicApi/PublicApi.csproj" "$PUBLICAPI_OUTPUT_DIR" "$PUBLICAPI_PACKAGE_PATH"
  fi
else
  [[ -f "$WEB_PACKAGE_PATH" ]] || fail "Package not found: $WEB_PACKAGE_PATH"
  if [[ "$DEPLOY_PUBLIC_API" == true ]]; then
    [[ -f "$PUBLICAPI_PACKAGE_PATH" ]] || fail "Package not found: $PUBLICAPI_PACKAGE_PATH"
  fi
fi

log "Setting Web app settings"
web_settings=(
  "CatalogBaseUrl=$WEB_BASE_URL"
  "baseUrls__webBase=$WEB_BASE_URL"
  "UseOnlyInMemoryDatabase=false"
)

if [[ -n "$PUBLICAPI_BASE_URL" ]]; then
  web_settings+=("baseUrls__apiBase=$PUBLICAPI_BASE_URL")
fi

az webapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --settings "${web_settings[@]}" \
  --output none

log "Deploying Web package"
deploy_zip_to_webapp "$RESOURCE_GROUP" "$WEBAPP_NAME" "$WEB_PACKAGE_PATH"

wait_for_health "Web" "${WEBAPP_URL%/}${WEB_HEALTH_PATH}"

if [[ "$DEPLOY_PUBLIC_API" == true ]]; then
  [[ -n "$PUBLICAPI_URL" ]] || fail "--deploy-public-api requires --publicapi-url or AZURE_PUBLICAPI_URL"

  PUBLICAPI_BASE_URL="$(normalize_base_url "$PUBLICAPI_URL")"
  if [[ -z "$PUBLICAPI_NAME" ]]; then
    PUBLICAPI_NAME="$(host_from_url "$PUBLICAPI_URL")"
  fi
  [[ -n "$PUBLICAPI_NAME" ]] || fail "Unable to resolve PublicApi app name"

  log "Using PublicApi resource group: $PUBLICAPI_RESOURCE_GROUP"
  log "Using PublicApi app: $PUBLICAPI_NAME"
  log "Using PublicApi URL: $PUBLICAPI_URL"

  key_vault_name="$(terraform_output azure_key_vault_name)"
  catalog_secret_name="$(terraform_output azure_sql_catalog_connection_string_key)"
  identity_secret_name="$(terraform_output azure_sql_identity_connection_string_key)"
  catalog_connection="$(key_vault_secret "$key_vault_name" "$catalog_secret_name")"
  identity_connection="$(key_vault_secret "$key_vault_name" "$identity_secret_name")"

  log "Setting PublicApi app settings"
  az webapp config appsettings set \
    --resource-group "$PUBLICAPI_RESOURCE_GROUP" \
    --name "$PUBLICAPI_NAME" \
    --settings \
      "UseOnlyInMemoryDatabase=false" \
      "ConnectionStrings__CatalogConnection=$catalog_connection" \
      "ConnectionStrings__IdentityConnection=$identity_connection" \
      "CatalogBaseUrl=$WEB_BASE_URL" \
      "baseUrls__webBase=$WEB_BASE_URL" \
      "baseUrls__apiBase=${PUBLICAPI_BASE_URL}api/" \
    --output none

  log "Deploying PublicApi package"
  deploy_zip_to_webapp "$PUBLICAPI_RESOURCE_GROUP" "$PUBLICAPI_NAME" "$PUBLICAPI_PACKAGE_PATH"

  wait_for_health "PublicApi" "${PUBLICAPI_URL%/}${PUBLICAPI_HEALTH_PATH}"
fi

log "Deployment completed successfully"