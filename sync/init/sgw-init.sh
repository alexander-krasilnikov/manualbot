#!/bin/bash
# Creates the Sync Gateway database for the `manualbot` bucket and the accounts of the iPads. Run again, it changes nothing
# that exists, except that it sets the accounts' password again.
set -euo pipefail

ADMIN="${SGW_ADMIN:-http://sync-gateway:4985}"
DB=manualbot
USERS=(ipad1 ipad2 ipad3)
COLLECTIONS=(documents chunks images)
log() { echo "[sgw-init] $*"; }

# 1. The database. 412 means it exists: Sync Gateway keeps its configuration in the bucket.
# A few tries: on a new cluster Sync Gateway can still fail for a moment to reach the query service.
for attempt in 1 2 3 4 5 6 7 8; do
  code=$(curl -s -o /tmp/create.out -w '%{http_code}' -X PUT "${ADMIN}/${DB}/" -H 'Content-Type: application/json' --data @/init/database.json)
  [ "${code}" != "500" ] && break
  log "Sync Gateway is not ready yet (attempt ${attempt}); trying again"; sleep 5
done
case "${code}" in
  200|201) log "created database ${DB}" ;;
  412) log "database ${DB} exists" ;;
  *) echo "creating the database failed (HTTP ${code}):" >&2; cat /tmp/create.out >&2; exit 1 ;;
esac
until [ "$(curl -s "${ADMIN}/${DB}/" | grep -o '"state":"[A-Za-z]*"' || true)" = '"state":"Online"' ]; do
  log "waiting for ${DB} to come online"; sleep 2
done

# 2. One account per iPad. All of them may read and write the shared library, which is the `library` channel.
access=""
for collection in "${COLLECTIONS[@]}"; do
  access+="\"${collection}\":{\"admin_channels\":[\"library\"]},"
done
for user in "${USERS[@]}"; do
  body="{\"password\":\"${IPAD_PASSWORD}\",\"collection_access\":{\"manualbot\":{${access%,}}}}"
  code=$(curl -s -o /tmp/user.out -w '%{http_code}' -X PUT "${ADMIN}/${DB}/_user/${user}" -H 'Content-Type: application/json' --data "${body}")
  case "${code}" in
    200|201) log "account ${user} is ready" ;;
    *) echo "account ${user} failed (HTTP ${code}):" >&2; cat /tmp/user.out >&2; exit 1 ;;
  esac
done
log "done"

# Done. Staying up, idle, is how this container tells `docker compose up --wait` that it has finished: its health check
# looks for this file.
touch /tmp/ready
exec sleep infinity
