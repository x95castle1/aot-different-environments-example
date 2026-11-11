#!/usr/bin/env bash
# Gives each environment of demo-app its own credentials, the way a platform team would. Per environment:
#
#   1. MongoDB: database demo_<env> with user demo_<env> and a fresh random password
#   2. Vault:   secret/demo-app/<env> holding that password + an API key
#   3. Vault:   a policy that can read only the app's shared, tier and own paths
#   4. Vault:   a token for that policy, written to .secrets/<env>.env: the only secret handed to the container
#
# Usage: ./bootstrap.sh <env> [<env> ...]     e.g. ./bootstrap.sh dev1
# Safe to re-run: passwords, API keys and tokens are rotated each time.
# Expects this example's vault and mongo to be up (make infra).
# COMPOSE_FILE=<compose file> targets another stack with the same services.
#
# Each step is a function below; main, at the bottom, runs them for each environment.
set -euo pipefail
cd "$(dirname "$0")"

[[ $# -ge 1 ]] || { echo "usage: $0 <env> [<env> ...]"; exit 2; }
APP=demo-app
DB_PREFIX=demo
SECRETS_DIR=.secrets

# ---------------------------------------------------------------------------------------------------- helpers

compose() { docker compose -f "${COMPOSE_FILE:-compose.yml}" "$@"; }
vault() { compose exec -T -e VAULT_TOKEN=root -e VAULT_ADDR=http://127.0.0.1:8200 vault vault "$@"; }
mongo_root() { compose exec -T mongo mongosh --quiet -u root -p example --authenticationDatabase admin "$@"; }
random() { openssl rand -hex 16; }

# ---------------------------------------------------------------------------------------------------- steps

prepare_secrets_dir() {
  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
}

# bootstrap_env <env>: steps 1-4 for one environment
bootstrap_env() {
  local env=$1
  local tier="${env%%[0-9]*}" db="${DB_PREFIX}_${env}" mongo_password api_key
  mongo_password="$(random)"
  api_key="$(random)"
  create_mongo_user "$db" "$mongo_password"
  put_vault_secret "$env" "$mongo_password" "$api_key"
  write_vault_policy "$env" "$tier"
  write_vault_token "$env"
  echo "bootstrapped ${APP}/${env}: mongo db/user ${db}, vault secret/${APP}/${env}, policy ${APP}-${env}"
}

# create_mongo_user <db> <password>: a user scoped to this environment's database (password updated if it exists)
create_mongo_user() {
  local db=$1 password=$2
  mongo_root --eval "
    const d = db.getSiblingDB('${db}');
    if (d.getUser('${db}')) { d.updateUser('${db}', { pwd: '${password}' }); }
    else { d.createUser({ user: '${db}', pwd: '${password}', roles: [{ role: 'readWrite', db: '${db}' }] }); }
  " >/dev/null
}

# put_vault_secret <env> <mongo password> <api key>: property names map 1:1 to Spring properties
put_vault_secret() {
  vault kv put "secret/${APP}/$1" \
    "spring.mongodb.password=$2" \
    "app.api-key=$3" >/dev/null
}

# write_vault_policy <env> <tier>: read this app's shared, tier and own paths, nothing else (e.g. not prod from dev)
write_vault_policy() {
  local env=$1 tier=$2
  vault policy write "${APP}-${env}" - >/dev/null <<EOF
path "secret/data/${APP}"         { capabilities = ["read"] }
path "secret/data/${APP}/${tier}" { capabilities = ["read"] }
path "secret/data/${APP}/${env}"  { capabilities = ["read"] }
EOF
}

# write_vault_token <env>: a token for this environment only -> .secrets/<env>.env
write_vault_token() {
  local env=$1 token
  token="$(vault token create -policy="${APP}-${env}" -period=24h -field=token)"
  (umask 077; printf 'VAULT_TOKEN=%s\n' "${token}" > "${SECRETS_DIR}/${env}.env")
}

# ---------------------------------------------------------------------------------------------------- main

prepare_secrets_dir
for env in "$@"; do bootstrap_env "$env"; done
