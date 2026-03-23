#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_TF_DIR="$(cd "$APP_ROOT/../eshop-iac" && pwd)"

TF_DIR="$DEFAULT_TF_DIR"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
WEBAPP_NAME="${AZURE_WEBAPP_NAME:-}"
PUBLICAPI_NAME="${AZURE_PUBLICAPI_NAME:-}"
TARGET_APP="web"

usage() {
  cat <<'EOF'
Usage: tail-appservice-logs.sh [options]

Tail Azure App Service logs for the Web app inferred from the Terraform environment,
or for an explicitly named PublicApi App Service.

Options:
  --tf-dir PATH             Terraform directory. Default: ../eshop-iac
  --subscription ID         Azure subscription id or name. Optional.
  --resource-group NAME     Override inferred resource group name.
  --webapp-name NAME        Override inferred Web app name.
  --publicapi-name NAME     Existing PublicApi App Service name.
  --app NAME                Which app to tail: web or publicapi. Default: web
  -h, --help                Show this help.

Environment overrides:
  AZURE_SUBSCRIPTION_ID
  AZURE_RESOURCE_GROUP
  AZURE_WEBAPP_NAME
  AZURE_PUBLICAPI_NAME
EOF
}

fail() {
  printf '[logs] ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[logs] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

infer_resource_group() {
  local env_name
  env_name="$(sed -nE 's/^environment_name[[:space:]]*=[[:space:]]*"([^"]+)"/\1/p' "$TF_DIR/terraform.tfvars" | head -n 1)"
  [[ -n "$env_name" ]] || fail "Unable to infer environment_name from $TF_DIR/terraform.tfvars"
  printf 'rg-%s' "$env_name"
}

terraform_output() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

host_from_url() {
  printf '%s' "$1" | sed -E 's#https?://([^./]+).*#\1#'
}

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
    --publicapi-name)
      PUBLICAPI_NAME="$2"
      shift 2
      ;;
    --app)
      TARGET_APP="$2"
      shift 2
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
require_command terraform

[[ -d "$TF_DIR" ]] || fail "Terraform directory not found: $TF_DIR"
[[ -f "$TF_DIR/terraform.tfvars" ]] || fail "terraform.tfvars not found in: $TF_DIR"

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

az account show >/dev/null 2>&1 || fail "Azure CLI is not logged in. Run 'az login' first."

if [[ -z "$RESOURCE_GROUP" ]]; then
  RESOURCE_GROUP="$(infer_resource_group)"
fi

if [[ -z "$WEBAPP_NAME" ]]; then
  WEBAPP_NAME="$(host_from_url "$(terraform_output web_app_url)")"
fi

case "$TARGET_APP" in
  web)
    APP_NAME="$WEBAPP_NAME"
    ;;
  publicapi)
    APP_NAME="$PUBLICAPI_NAME"
    [[ -n "$APP_NAME" ]] || fail "--app publicapi requires --publicapi-name or AZURE_PUBLICAPI_NAME"
    ;;
  *)
    fail "--app must be 'web' or 'publicapi'"
    ;;
esac

log "Tailing logs for $TARGET_APP app '$APP_NAME' in resource group '$RESOURCE_GROUP'"
az webapp log tail --resource-group "$RESOURCE_GROUP" --name "$APP_NAME"