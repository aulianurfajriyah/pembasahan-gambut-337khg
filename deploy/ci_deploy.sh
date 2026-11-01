#!/usr/bin/env bash
# Deploy otomatis ke VM produksi, dipanggil .github/workflows/deploy.yml setelah CI hijau di main.
# Bertahap seperti README bagian F, BUKAN deploy.sh: tidak menyentuh lapisan/, simulasi/data/, .env, dan web/ di VM.
#  1. backup definisi skema + berkas lama  2. migrasi  3. sinkron api/ db/ deploy/  4. recreate container yang berubah
#  5. uji asap publik  -> gagal: berkas lama dikembalikan otomatis (migrasi bersifat tambahan, tidak di-undo)
# Env wajib: DEPLOY_HOST DEPLOY_KEY (path kunci privat) API_URL (https://...). Opsional: DEPLOY_USER (gambut).
# Uji manual dari laptop: DEPLOY_HOST=1.2.3.4 DEPLOY_KEY=~/.ssh/gambut_vps API_URL=https://1-2-3-4.sslip.io ./deploy/ci_deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEPLOY_HOST:?}" "${DEPLOY_KEY:?}" "${API_URL:?}"
DEPLOY_USER=${DEPLOY_USER:-gambut}
REV=$(git rev-parse --short=10 HEAD)
SSH_ARGS=(-i "$DEPLOY_KEY" -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=15)
SSH=(ssh "${SSH_ARGS[@]}" "$DEPLOY_USER@$DEPLOY_HOST")
RSYNC=(rsync -az --out-format=%n -e "ssh ${SSH_ARGS[*]}")
VM=/srv/gambut
DC="cd $VM/db && docker compose"
dikembalikan=0

rollback() {
  [ "$dikembalikan" = 0 ] || return 0
  dikembalikan=1
  echo "::error::Deploy gagal, mengembalikan berkas $REV sebelumnya"
  "${SSH[@]}" "cd $VM && tar xzf /srv/backup/rollback_$REV.tgz && cd db && docker compose up -d --remove-orphans db && docker compose up -d --force-recreate api martin proxy" \
    || echo "::error::Rollback otomatis gagal. Pulihkan manual: deploy/README.md bagian E/F"
}

echo "== 1. backup (skema + berkas lama)"
"${SSH[@]}" "set -e; mkdir -p /srv/backup
  tar czf /srv/backup/rollback_$REV.tgz -C $VM --exclude=db/.env api db
  docker exec gambut_db pg_dump -U postgres -d gambut --schema-only -Fc > /srv/backup/skema_$REV.dump
  ls -t /srv/backup/rollback_*.tgz | tail -n +6 | xargs -r rm -f
  ls -t /srv/backup/skema_*.dump | tail -n +6 | xargs -r rm -f"

echo "== 2. migrasi"
PSQL="${SSH[*]} docker exec -i gambut_db psql -X -q -U postgres -d gambut -v ON_ERROR_STOP=1" db/migrasi.sh

trap rollback ERR
echo "== 3. sinkron berkas"
ubah=$("${RSYNC[@]}" --delete api/ "$DEPLOY_USER@$DEPLOY_HOST:$VM/api/")
"${RSYNC[@]}" db/*.sql db/docker-compose.yml deploy/docker-compose.prod.yml deploy/docker-compose.web.yml \
  deploy/Caddyfile.web deploy/backup.sh "$DEPLOY_USER@$DEPLOY_HOST:$VM/db/" >/dev/null

echo "== 4. container"
"${SSH[@]}" "$DC up -d --remove-orphans db api martin proxy" # compose/Postgres berubah -> recreate otomatis
# berkas yang di-mount tidak memicu recreate: restart service yang berkasnya berubah
svc=()
grep -qE '^(gambut_processes\.py|simulasi_model\.py|pygeoapi-config\.yml)$' <<< "$ubah" && svc+=(api)
grep -qx 'martin.yaml' <<< "$ubah" && svc+=(martin)
if [ ${#svc[@]} -gt 0 ]; then "${SSH[@]}" "$DC up -d --force-recreate ${svc[*]}"; fi
if grep -qx 'Caddyfile' <<< "$ubah"; then "${SSH[@]}" "$DC exec -T proxy caddy reload --config /etc/caddy/Caddyfile"; fi

echo "== 5. uji asap $API_URL"
for _ in $(seq 40); do curl -sf -o /dev/null "$API_URL/" && break; sleep 3; done
SOLO_BACA=1 db/ci/smoke_api.sh "$API_URL"
kode=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/geo+json' -d '{}' "$API_URL/collections/pompa/items")
echo "$kode POST tanpa login (harus 401)"; [ "$kode" = 401 ]
kode=$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/tiles/kanal/12/2081/3344")
echo "$kode tile martin"; [ "$kode" = 200 ] || [ "$kode" = 204 ]

trap - ERR
echo "SELESAI $REV -> $API_URL"
