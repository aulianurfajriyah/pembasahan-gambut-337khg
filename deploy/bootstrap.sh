#!/usr/bin/env bash
# Siapkan VM Ubuntu 24.04 dari penyedia mana pun (IDCloudHost, Biznet Gio, ...) agar setara hasil
# provision.sh + cloud-init.yml: Docker + compose, ufw, fail2ban, user gambut (SSH key), swap 2 GB.
# Pakai:  IP=103.x.x.x LOGIN=<user dari panel> ./deploy/bootstrap.sh
# Password login VM diminta 2x (ssh-copy-id, lalu sudo). Setelah itu login password SSH dimatikan.
set -euo pipefail
cd "$(dirname "$0")"
: "${IP:?isi IP=<IP publik VM>}"
LOGIN=${LOGIN:-root}
NAME=${NAME:-gambut-prod}
KEY=${KEY:-$HOME/.ssh/gambut_vps}

# kunci SSH khusus deploy (lokal, tanpa passphrase agar deploy.sh bisa jalan otomatis)
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C gambut-deploy -f "$KEY"
ssh-copy-id -i "$KEY.pub" -o StrictHostKeyChecking=accept-new "$LOGIN@$IP"

# skrip dikirim dulu lalu dijalankan dengan -t, agar sudo bisa meminta password
SETUP=$(mktemp)
cat > "$SETUP" <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release

echo "== paket (repo resmi Docker -> compose plugin terbaru, butuh >= 2.24.4 untuk !override)"
apt-get update -q
apt-get upgrade -yq
apt-get install -yq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -yq docker-ce docker-ce-cli containerd.io docker-compose-plugin ufw fail2ban unattended-upgrades jq rsync

echo "== user gambut"
id gambut >/dev/null 2>&1 || useradd -m -s /bin/bash -G docker,sudo gambut
echo 'gambut ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/gambut && chmod 440 /etc/sudoers.d/gambut
install -d -m 700 -o gambut -g gambut /home/gambut/.ssh
grep -qxF "$PUB" /home/gambut/.ssh/authorized_keys 2>/dev/null || echo "$PUB" >> /home/gambut/.ssh/authorized_keys
chown gambut:gambut /home/gambut/.ssh/authorized_keys && chmod 600 /home/gambut/.ssh/authorized_keys

echo "== swap 2 GB"
if ! swapon --show | grep -q /swapfile; then
  [ -f /swapfile ] || { fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; }
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "== firewall & SSH (hanya key, root dimatikan)"
ufw default deny incoming && ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable
cat > /etc/ssh/sshd_config.d/99-gambut.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
EOF
systemctl restart ssh
systemctl enable --now docker fail2ban unattended-upgrades
mkdir -p /srv/gambut /srv/backup && chown -R gambut:gambut /srv/gambut /srv/backup
EOS
scp -q -i "$KEY" "$SETUP" "$LOGIN@$IP:/tmp/gambut-setup.sh" && rm -f "$SETUP"
ssh -t -i "$KEY" "$LOGIN@$IP" "sudo PUB='$(cat "$KEY.pub")' bash /tmp/gambut-setup.sh; rm -f /tmp/gambut-setup.sh"

ssh -i "$KEY" -o ConnectTimeout=10 "gambut@$IP" 'docker compose version --short' >/dev/null
printf 'IP=%s\nNAME=%s\nKEY=%s\n' "$IP" "$NAME" "$KEY" > .state
echo "VM siap: ssh -i $KEY gambut@$IP   (disimpan di deploy/.state)"
echo "Lanjut : ./deploy/deploy.sh"
