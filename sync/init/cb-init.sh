#!/bin/bash
# Sets up Couchbase Server for ManualBot: the cluster, the `manualbot` bucket with its scope and the replicated collections,
# and the account Sync Gateway signs in with. Run again, it creates only what is missing.
set -euo pipefail

HOST="${CB_HOST:-couchbase-server}"
BASE="http://${HOST}:8091"
BUCKET=manualbot
SCOPE=manualbot
# The collections the app replicates: CouchbaseSchema.replicated in the app. Defined once, in docker-compose.yml.
read -r -a COLLECTIONS <<<"${REPLICATED_COLLECTIONS:?set in docker-compose.yml}"
log() { echo "[cb-init] $*"; }

# This container reports healthy by the presence of this file, so it must not be left over from an earlier run.
rm -f /tmp/ready

# Waits for the command `$3...` to succeed, for at most `$1` seconds, then gives up with a message instead of waiting for ever.
wait_for() {
  local seconds="$1" description="$2"; shift 2
  local waited=0
  until "$@"; do
    if (( waited >= seconds )); then echo "gave up waiting for ${description} after ${seconds}s" >&2; exit 1; fi
    sleep 2; waited=$(( waited + 2 ))
  done
}

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
  if ! couchbase-cli cluster-init -c "${HOST}:8091" \
    --cluster-username "${CB_ADMIN_USER}" --cluster-password "${CB_ADMIN_PASSWORD}" \
    --cluster-name manualbot --services data,index,query \
    --cluster-ramsize 768 --cluster-index-ramsize 256 --index-storage-setting default; then
    echo "The cluster could not be set up, or it already was, with another administrator password." >&2
    echo "If CB_ADMIN_PASSWORD was changed in .env after the first start, run 'docker compose down -v' and start again." >&2
    exit 1
  fi
fi
buckets_ready() { curl -sf -u "${CB_ADMIN_USER}:${CB_ADMIN_PASSWORD}" "${BASE}/pools/default/buckets" >/dev/null; }
wait_for 120 "the cluster to accept requests" buckets_ready

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
query_sees_collections() {
  [ "$(curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASSWORD}" "http://${HOST}:8093/query/service" \
    --data-urlencode "statement=SELECT RAW COUNT(*) FROM system:keyspaces WHERE \`bucket\` = '${BUCKET}' AND \`scope\` = '${SCOPE}'" \
    | tr -d '[:space:]' | grep -o '"results":\[[0-9]*\]' || true)" = "\"results\":[${#COLLECTIONS[@]}]" ]
}
wait_for 180 "the query service to see the collections" query_sees_collections

# 5. The account Sync Gateway uses. `--set` creates it or updates it.
couchbase-cli user-manage "${CLI[@]}" --set --rbac-username "${SG_BUCKET_USER}" --rbac-password "${SG_BUCKET_PASSWORD}" \
  --roles "mobile_sync_gateway[${BUCKET}]" --auth-domain local >/dev/null
log "account ${SG_BUCKET_USER} is ready"

# Done. Staying up, idle, is how this container tells `docker compose up --wait` that it has finished: its health check
# looks for this file. (A container that exits would count as ready before it had done anything, and as a failure later.)
touch /tmp/ready
exec sleep infinity
