#!/usr/bin/env bash
# =============================================================================
#  n8n auto-hébergé sur Google Cloud — installation en une commande
#  À coller dans Google Cloud Shell (le terminal intégré à la console GCP).
#
#  Crée, dans le projet GCP actif :
#    - une VM e2-micro (offre gratuite à vie) dans us-central1, Debian 12, 30 Go
#    - une adresse IP fixe (≈ 3,65 $/mois, la seule partie payante)
#    - une règle de pare-feu qui ouvre le web (80/443)
#  Puis, sur la VM : 2 Go de swap, Docker, n8n et Caddy (HTTPS automatique).
#
#  Adresse obtenue : https://<ip-avec-des-tirets>.sslip.io
#  (sslip.io transforme l'IP en nom de domaine, Let's Encrypt fournit le certificat)
#
#  Relancer le script ne casse rien : ce qui existe déjà est conservé.
# =============================================================================
set -euo pipefail

REGION="us-central1"            # une des 3 régions de l'offre gratuite
ZONE="us-central1-a"
VM="n8n"
IP_NAME="n8n-ip"
TAG="n8n-web"

PROJECT="$(gcloud config get-value project 2>/dev/null)"
if [[ -z "${PROJECT}" || "${PROJECT}" == "(unset)" ]]; then
  echo "Aucun projet actif. Lance d'abord :  gcloud config set project TON_ID_DE_PROJET"
  exit 1
fi
echo "Projet : ${PROJECT}"

echo "1/5  Activation de Compute Engine (peut prendre une minute la première fois)…"
gcloud services enable compute.googleapis.com --quiet

echo "2/5  Adresse IP fixe…"
if ! gcloud compute addresses describe "${IP_NAME}" --region="${REGION}" >/dev/null 2>&1; then
  gcloud compute addresses create "${IP_NAME}" --region="${REGION}" --quiet
fi
IP="$(gcloud compute addresses describe "${IP_NAME}" --region="${REGION}" --format='value(address)')"
HOST="${IP//./-}.sslip.io"
echo "     IP ${IP}  →  https://${HOST}"

echo "3/5  Pare-feu (ports 80 et 443)…"
if ! gcloud compute firewall-rules describe allow-n8n-web >/dev/null 2>&1; then
  gcloud compute firewall-rules create allow-n8n-web \
    --allow=tcp:80,tcp:443 --target-tags="${TAG}" --direction=INGRESS --quiet
fi

echo "4/5  Script de démarrage de la VM…"
STARTUP="$(mktemp)"
cat > "${STARTUP}" <<'BOOT'
#!/usr/bin/env bash
# Exécuté à chaque démarrage de la VM. Idempotent.
set -euo pipefail
exec >>/var/log/n8n-setup.log 2>&1
echo "=== démarrage $(date -Is) ==="

HOST="$(curl -s -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/n8n-host)"

# 2 Go de swap : la e2-micro n'a qu'1 Go de RAM
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
swapon -a || true
sysctl -w vm.swappiness=10 >/dev/null

# Docker
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

mkdir -p /opt/n8n
cd /opt/n8n

# Clé de chiffrement des identifiants n8n : générée une seule fois, à sauvegarder
if [ ! -f .encryption_key ]; then
  openssl rand -hex 32 > .encryption_key && chmod 600 .encryption_key
fi

cat > .env <<ENV
N8N_HOST=${HOST}
N8N_ENCRYPTION_KEY=$(cat .encryption_key)
ENV

cat > docker-compose.yml <<'YML'
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: unless-stopped
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${N8N_HOST}/
      - N8N_PROXY_HOPS=1
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - GENERIC_TIMEZONE=Europe/Paris
      - TZ=Europe/Paris
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - N8N_DIAGNOSTICS_ENABLED=false
      - NODE_OPTIONS=--max-old-space-size=640
    volumes:
      - n8n_data:/home/node/.n8n
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - n8n
volumes:
  n8n_data:
  caddy_data:
  caddy_config:
YML

cat > Caddyfile <<CADDY
${HOST} {
  encode gzip
  reverse_proxy n8n:5678
}
CADDY

docker compose pull -q
docker compose up -d
echo "=== n8n lancé sur https://${HOST} ==="
BOOT

echo "5/5  Création de la VM…"
if ! gcloud compute instances describe "${VM}" --zone="${ZONE}" >/dev/null 2>&1; then
  gcloud compute instances create "${VM}" \
    --zone="${ZONE}" \
    --machine-type=e2-micro \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size=30GB --boot-disk-type=pd-standard \
    --address="${IP}" \
    --tags="${TAG}" \
    --metadata=n8n-host="${HOST}" \
    --metadata-from-file=startup-script="${STARTUP}" \
    --quiet
else
  gcloud compute instances add-metadata "${VM}" --zone="${ZONE}" \
    --metadata=n8n-host="${HOST}" --metadata-from-file=startup-script="${STARTUP}" --quiet
  gcloud compute instances reset "${VM}" --zone="${ZONE}" --quiet
fi
rm -f "${STARTUP}"

echo
echo "Installation lancée. La VM installe Docker et n8n : compte 5 à 8 minutes."
echo "Pour suivre :"
echo "  gcloud compute ssh ${VM} --zone=${ZONE} --command='sudo tail -f /var/log/n8n-setup.log'"
echo
echo "Ensuite, ouvre :   https://${HOST}"
echo "Ton adresse de webhooks pour l'app :   https://${HOST}/webhook"
