#!/usr/bin/env bash
# Buat VM Hetzner untuk Gambut (idempoten: aman dijalankan ulang).
# Prasyarat (dilakukan pemilik akun): hcloud context create gambut   <- tempel API token Read & Write
# Pakai:  ./deploy/provision.sh            (default: cpx22 di Singapura, tanpa backup — mode demo)
#         BACKUP=1 ./deploy/provision.sh   (produksi: backup Hetzner harian, +20% biaya)
#         TYPE=cx43 LOC=nbg1 ./deploy/provision.sh   (opsi lebih murah di Jerman)
set -euo pipefail
cd "$(dirname "$0")"
NAME=${NAME:-gambut-prod}
TYPE=${TYPE:-cpx22}
LOC=${LOC:-sin}
IMAGE=${IMAGE:-ubuntu-24.04}
KEY=${KEY:-$HOME/.ssh/gambut_hetzner}

command -v hcloud >/dev/null || { echo "hcloud belum terpasang: brew install hcloud"; exit 1; }
hcloud server-type list -o noheader >/dev/null 2>&1 || {
  echo "Belum login ke Hetzner. Jalankan sendiri:  hcloud context create gambut   (tempel API token)"; exit 1; }

# kunci SSH khusus deploy (lokal, tanpa passphrase agar skrip bisa jalan otomatis)
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C gambut-deploy -f "$KEY"
hcloud ssh-key describe gambut-deploy >/dev/null 2>&1 ||
  hcloud ssh-key create --name gambut-deploy --public-key-from-file "$KEY.pub" >/dev/null

# tipe server harus tersedia di lokasi; tampilkan harga resmi dari API Hetzner
PRICE=$(hcloud server-type describe "$TYPE" -o json |
  jq -r --arg l "$LOC" '.prices[] | select(.location == $l) | "\(.price_monthly.gross) € /bulan (termasuk pajak), \(.price_hourly.gross) € /jam"')
AVAIL=$(hcloud server-type describe "$TYPE" -o json |
  jq -r --arg l "$LOC" '[.locations[]? | select(.name == $l and .deprecation == null)] | length')
if [ -z "$PRICE" ] || [ "$AVAIL" = 0 ]; then   # harga bisa masih tercantum walau tipe sudah tak bisa dipesan
  echo "Tipe $TYPE tidak bisa dipesan di $LOC. Yang tersedia:"
  hcloud server-type list -o json | jq -r --arg l "$LOC" '.[] | select(any(.locations[]?; .name == $l and .deprecation == null))
    | "  \(.name)\t\(.cores) vCPU\t\(.memory) GB\t\(.disk) GB"'
  exit 1
fi
SPEC=$(hcloud server-type describe "$TYPE" -o json | jq -r '"\(.cores) vCPU, \(.memory) GB RAM, \(.disk) GB disk, \(.architecture)"')
echo "Server : $NAME  ($TYPE di $LOC: $SPEC)"
echo "Harga  : $PRICE$([ "${BACKUP:-0}" = 1 ] && echo " + backup 20%") + IPv4"

hcloud firewall describe gambut-fw >/dev/null 2>&1 ||
  hcloud firewall create --name gambut-fw --rules-file firewall.json >/dev/null

if ! hcloud server describe "$NAME" >/dev/null 2>&1; then
  if [ "${YES:-}" != "1" ]; then
    read -r -p "Buat server ini (menimbulkan tagihan)? ketik 'ya': " ok
    [ "$ok" = "ya" ] || { echo "dibatalkan"; exit 1; }
  fi
  UD=$(mktemp); sed "s|\${SSH_PUBKEY}|$(cat "$KEY.pub")|" cloud-init.yml > "$UD"
  # shellcheck disable=SC2046  # flag opsional: kosong bila BACKUP=0
  hcloud server create --name "$NAME" --type "$TYPE" --location "$LOC" --image "$IMAGE" \
    --ssh-key gambut-deploy --firewall gambut-fw --user-data-from-file "$UD" \
    --label app=gambut $([ "${BACKUP:-0}" = 1 ] && echo --enable-backup)
  rm -f "$UD"
fi

IP=$(hcloud server ip "$NAME")
printf 'IP=%s\nNAME=%s\nKEY=%s\n' "$IP" "$NAME" "$KEY" > .state
echo "IP     : $IP  (disimpan di deploy/.state)"
echo "Lanjut : ./deploy/deploy.sh"
