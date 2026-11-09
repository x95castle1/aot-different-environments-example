#!/usr/bin/env bash
# Gives each environment of an app its own credentials, the way a platform team would:
#   - MongoDB: database <db>_<env> with user <db>_<env> and a fresh random password
#              (<db> = app name without "-app", dashes -> underscores; demo-app -> demo)
#   - Vault:   secret/<app>/<env> holding that password + an API key, a policy that can read only
#              the app's shared, tier and own paths, and a token for that policy
#   - .secrets/<app>/<env>.env: the Vault token, the only secret handed to the container
#
# Usage: infra/bootstrap.sh <app> <env> [<env> ...]     e.g. infra/bootstrap.sh demo-app dev1 qa1
# Safe to re-run: passwords, API keys and tokens are rotated each time.
# Expects the infrastructure to be up (make -C infra up).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[[ $# -ge 2 ]] || { echo "usage: $0 <app> <env> [<env> ...]"; exit 2; }
APP=$1; shift
DB_PREFIX=$(sed -e 's/-app$//' -e 's/-/_/g' <<<"$APP")

compose() { docker compose -f "$ROOT/infra/compose.yml" "$@"; }
vault() { compose exec -T -e VAULT_TOKEN=root -e VAULT_ADDR=http://127.0.0.1:8200 vault vault "$@"; }
mongo_root() { compose exec -T mongo mongosh --quiet -u root -p example --authenticationDatabase admin "$@"; }
random() { openssl rand -hex 16; }

SECRETS_DIR="$ROOT/.secrets/$APP"
mkdir -p "$SECRETS_DIR"
chmod 700 "$ROOT/.secrets" "$SECRETS_DIR"

for env in "$@"; do
  tier="${env%%[0-9]*}"
  db="${DB_PREFIX}_${env}"
  mongo_password="$(random)"
  api_key="$(random)"

  # 1. MongoDB user scoped to this environment's database
  mongo_root --eval "
    const d = db.getSiblingDB('${db}');
    if (d.getUser('${db}')) { d.updateUser('${db}', { pwd: '${mongo_password}' }); }
    else { d.createUser({ user: '${db}', pwd: '${mongo_password}', roles: [{ role: 'readWrite', db: '${db}' }] }); }
  " >/dev/null

  # 2. Vault secret for this environment (property names map 1:1 to Spring properties)
  vault kv put "secret/${APP}/${env}" \
    "spring.mongodb.password=${mongo_password}" \
    "app.api-key=${api_key}" >/dev/null

  # 3. Policy: read this app's shared, tier and own paths, nothing else (e.g. not prod from dev)
  vault policy write "${APP}-${env}" - >/dev/null <<EOF
path "secret/data/${APP}"         { capabilities = ["read"] }
path "secret/data/${APP}/${tier}" { capabilities = ["read"] }
path "secret/data/${APP}/${env}"  { capabilities = ["read"] }
EOF

  # 4. Token for this environment only
  token="$(vault token create -policy="${APP}-${env}" -period=24h -field=token)"
  (umask 077; printf 'VAULT_TOKEN=%s\n' "${token}" > "${SECRETS_DIR}/${env}.env")

  echo "bootstrapped ${APP}/${env}: mongo db/user ${db}, vault secret/${APP}/${env}, policy ${APP}-${env}"
done
