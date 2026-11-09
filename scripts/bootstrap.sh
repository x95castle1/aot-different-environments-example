#!/usr/bin/env bash
# Gives each environment its own credentials, the way a platform team would:
#   - MongoDB: database demo_<env> with user demo_<env> and a fresh random password
#   - Vault:   secret/demo-app/<env> holding that password + an API key,
#              a policy that can read only demo-app's shared, tier and own paths, and a token
#   - .secrets/<env>.env: the Vault token, the only secret handed to the container
#
# Safe to re-run: passwords, API keys and tokens are rotated each time.
# Expects the infrastructure to be up (make infra).
set -euo pipefail
cd "$(dirname "$0")/.."

ENVS=(dev1 dev2 qa1 prod1)

vault() { docker compose exec -T -e VAULT_TOKEN=root -e VAULT_ADDR=http://127.0.0.1:8200 vault vault "$@"; }
mongo_root() { docker compose exec -T mongo mongosh --quiet -u root -p example --authenticationDatabase admin "$@"; }
random() { openssl rand -hex 16; }

mkdir -p .secrets
chmod 700 .secrets

for env in "${ENVS[@]}"; do
  tier="${env%%[0-9]*}"
  db="demo_${env}"
  mongo_password="$(random)"
  api_key="$(random)"

  # 1. MongoDB user scoped to this environment's database
  mongo_root --eval "
    const d = db.getSiblingDB('${db}');
    if (d.getUser('${db}')) { d.updateUser('${db}', { pwd: '${mongo_password}' }); }
    else { d.createUser({ user: '${db}', pwd: '${mongo_password}', roles: [{ role: 'readWrite', db: '${db}' }] }); }
  " >/dev/null

  # 2. Vault secret for this environment (property names map 1:1 to Spring properties)
  vault kv put "secret/demo-app/${env}" \
    "spring.mongodb.password=${mongo_password}" \
    "app.api-key=${api_key}" >/dev/null

  # 3. Policy: read demo-app's shared, tier and own paths, nothing else (e.g. not prod from dev)
  vault policy write "demo-app-${env}" - >/dev/null <<EOF
path "secret/data/demo-app"         { capabilities = ["read"] }
path "secret/data/demo-app/${tier}" { capabilities = ["read"] }
path "secret/data/demo-app/${env}"  { capabilities = ["read"] }
EOF

  # 4. Token for this environment only
  token="$(vault token create -policy="demo-app-${env}" -period=24h -field=token)"
  umask 077
  printf 'VAULT_TOKEN=%s\n' "${token}" > ".secrets/${env}.env"

  echo "bootstrapped ${env}: mongo db/user ${db}, vault secret/demo-app/${env}, policy demo-app-${env}"
done
