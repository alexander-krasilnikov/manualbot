#!/bin/bash
# Sets up Couchbase Server for ManualBot: the cluster, the `manualbot` bucket with its scope and the three replicated
# collections, and the account Sync Gateway signs in with. Run again, it creates only what is missing.
set -euo pipefail

HOST="${CB_HOST:-couchbase-server}"
BASE="http://${HOST}:8091"
BUCKET=manualbot
SCOPE=manualbot
COLLECTIONS=(documents chunks images)
log() { echo "[cb-init] $*"; }

# Runs a command and counts "already exists" as success, so that a second run does not fail.
ensure() {
  local out
  if out=$("$@" 2>&1); then return 0; fi
  if grep -qiE "already exists|already been created" <<<"$out"; then return 0; fi
  echo "$out" >&2
  return 1
}

# 1. The cluster. A server that has not been set up refuses our credentials; one that has been set up accepts them.
if curl -sf -u "${CB_ADMIN_USER}:${CB_ADMIN_PASSWORD}" "${BASE}/pools/default" >/dev/null; then
  log "the cluster is already set up"
else
  log "setting up the cluster"
  couchbase-cli cluster-init -c "${HOST}:8091" \
    --cluster-username "${CB_ADMIN_USER}" --cluster-password "${CB_ADMIN_PASSWORD}" \
    --cluster-name manualbot --services data,index,query \
    --cluster-ramsize 768 --cluster-index-ramsize 256 --index-storage-setting default
fi
until curl -sf -u "${CB_ADMIN_USER}:${CB_ADMIN_PASSWORD}" "${BASE}/pools/default/buckets" >/dev/null; do sleep 2; done

CLI=(-c "${HOST}:8091" -u "${CB_ADMIN_USER}" -p "${CB_ADMIN_PASSWORD}")

# 2. The bucket.
if curl -sf -u "${CB_ADMIN_USER}:${CB_ADMIN_PASSWORD}" "${BASE}/pools/default/buckets/${BUCKET}" >/dev/null; then
  log "bucket ${BUCKET} exists"
else
  log "creating bucket ${BUCKET}"
  couchbase-cli bucket-create "${CLI[@]}" --bucket "${BUCKET}" --bucket-type couchbase --bucket-ramsize 512 \
    --storage-backend couchstore --durability-min-level none --wait
fi

# 3. The scope and collections: the same names the app uses on the iPad.
ensure couchbase-cli collection-manage "${CLI[@]}" --bucket "${BUCKET}" --create-scope "${SCOPE}"
for collection in "${COLLECTIONS[@]}"; do
  ensure couchbase-cli collection-manage "${CLI[@]}" --bucket "${BUCKET}" --create-collection "${SCOPE}.${collection}"
done
log "scope ${SCOPE} has ${COLLECTIONS[*]}"

# 4. Wait until the query service can see the collections. Sync Gateway needs it to create its indexes, and on a new cluster it
# is ready a little after the bucket is.
until [ "$(curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASSWORD}" "http://${HOST}:8093/query/service" \
    --data-urlencode "statement=SELECT RAW COUNT(*) FROM system:keyspaces WHERE \`bucket\` = '${BUCKET}' AND \`scope\` = '${SCOPE}'" \
    | tr -d '[:space:]' | grep -o '"results":\[[0-9]*\]' || true)" = "\"results\":[${#COLLECTIONS[@]}]" ]; do
  log "waiting for the query service to see the collections"; sleep 3
done

# 5. The account Sync Gateway uses. `--set` creates it or updates it.
couchbase-cli user-manage "${CLI[@]}" --set --rbac-username "${SG_BUCKET_USER}" --rbac-password "${SG_BUCKET_PASSWORD}" \
  --roles "mobile_sync_gateway[${BUCKET}]" --auth-domain local >/dev/null
log "account ${SG_BUCKET_USER} is ready"

# Done. Staying up, idle, is how this container tells `docker compose up --wait` that it has finished: its health check
# looks for this file. (A container that exits would count as ready before it had done anything, and as a failure later.)
touch /tmp/ready
exec sleep infinity
