#!/usr/bin/env bash
# Mappe un stockage (ex: un disque 16 To) sur un ou plusieurs conteneurs LXC Proxmox.
#
# Exécution façon "ProxmoxVE community scripts" (copier/coller tel quel depuis le shell Proxmox) :
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/fasavard-org/scripts/main/map_16tb.sh)"
#
# Utilisation directe (si le script est déjà présent) :
#   ./map_16tb.sh            # demande interactivement les CTID
#   ./map_16tb.sh 101 102    # mappe sur les CTID 101 et 102
#
# Variables optionnelles :
#   HOST_PATH=/mnt/16tb          # Chemin du disque/point de montage sur l'hôte
#   HOST_DEVICE=/dev/sda         # Périphérique bloc à monter avant le mapping (NTFS)
#   CONTAINER_PATH=/mnt/16tb     # Chemin cible dans le conteneur
#   MP_INDEX=0                   # Index de mp utilisé (mp0, mp1, ...)

set -euo pipefail

HOST_PATH=${HOST_PATH:-/mnt/16tb}
HOST_DEVICE=${HOST_DEVICE:-/dev/sda}
CONTAINER_PATH=${CONTAINER_PATH:-/mnt/16tb}
MP_INDEX=${MP_INDEX:-0}

usage() {
  cat >&2 <<EOF
Usage :
  HOST_PATH=/mnt/16tb HOST_DEVICE=/dev/sda CONTAINER_PATH=/mnt/16tb MP_INDEX=0 $0 <CTID> [CTID...]
Ou :
  $0    # sans argument -> demande interactivement les CTID

Les valeurs par défaut sont :
  HOST_PATH=${HOST_PATH}
  HOST_DEVICE=${HOST_DEVICE}
  CONTAINER_PATH=${CONTAINER_PATH}
  MP_INDEX=${MP_INDEX}
EOF
}

if ! command -v pct >/dev/null 2>&1; then
  echo "Erreur : la commande 'pct' est introuvable. Lancez ce script depuis un hôte Proxmox." >&2
  exit 1
fi

# Si aucun CTID passé en argument, on passe en mode interactif
if [[ $# -lt 1 ]]; then
  echo "Aucun CTID fourni en argument."
  echo "Conteneurs LXC disponibles :"
  pct list || true
  echo
  read -rp "CTID à mapper (séparés par des espaces, ou vide pour annuler) : " ctid_input
  if [[ -z "${ctid_input// }" ]]; then
    echo "Aucun CTID fourni, abandon."
    exit 0
  fi
  # Remplace la liste des arguments par ceux entrés par l'utilisateur
  set -- ${ctid_input}
fi

ensure_ntfs3g() {
  if command -v ntfs-3g >/dev/null 2>&1 || command -v mount.ntfs >/dev/null 2>&1; then
    return
  fi

  echo "ntfs-3g non détecté, tentative d'installation via apt..."
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Impossible d'installer ntfs-3g automatiquement (apt-get introuvable)." >&2
    exit 1
  fi

  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ntfs-3g
}

mount_device_if_needed() {
  if [[ -z "${HOST_DEVICE:-}" ]]; then
    return
  fi

  if [[ ! -b "${HOST_DEVICE}" ]]; then
    echo "Avertissement : HOST_DEVICE='${HOST_DEVICE}' n'est pas un périphérique bloc, montage ignoré." >&2
    return
  fi

  mkdir -p "${HOST_PATH}"

  if mountpoint -q "${HOST_PATH}"; then
    return
  fi

  echo "Montage de ${HOST_DEVICE} sur ${HOST_PATH} (NTFS)..."
  ntfs-3g "${HOST_DEVICE}" "${HOST_PATH}"
}

ensure_ntfs3g
mount_device_if_needed

for ctid in "$@"; do
  if ! pct status "$ctid" >/dev/null 2>&1; then
    echo "Avertissement : le CTID $ctid n'existe pas ou n'est pas accessible" >&2
    continue
  fi

  mp_option="-mp${MP_INDEX}"
  mp_value="${HOST_PATH},mp=${CONTAINER_PATH},backup=0"

  echo "[${ctid}] Mapping de ${HOST_PATH} -> ${CONTAINER_PATH} (mp${MP_INDEX})"
  pct set "$ctid" "$mp_option" "$mp_value"
done

echo "Terminé. Vérifiez avec : pct config <CTID>"
