#!/usr/bin/env bash
# Mappe un stockage (ex: un disque 16 To) sur plusieurs conteneurs LXC Proxmox.
# Utilisation : ./map_16tb.sh <CTID> [CTID...]
# Variables optionnelles :
#   HOST_PATH=/mnt/16tb          # Chemin du disque/point de montage sur l'hôte
#   HOST_DEVICE=/dev/sda         # Périphérique bloc à monter avant le mapping (NTFS)
#   CONTAINER_PATH=/mnt/16tb     # Chemin cible dans le conteneur
#   MP_INDEX=0                   # Index de mp utilisé (mp0, mp1, ...)
#
# Pour une configuration équivalente via l'API Proxmox (one-liner prêt à coller) :
# curl -k -b "PVEAuthCookie=$PVEAUTH" -H "CSRFPreventionToken: $PVECSRF" -X PUT "https://<hote-pve>/api2/json/nodes/<node>/lxc/<CTID>/config" -d "mp${MP_INDEX}=${HOST_PATH},mp=${CONTAINER_PATH},backup=0"

set -euo pipefail

HOST_PATH=${HOST_PATH:-/mnt/16tb}
HOST_DEVICE=${HOST_DEVICE:-/dev/sda}
CONTAINER_PATH=${CONTAINER_PATH:-/mnt/16tb}
MP_INDEX=${MP_INDEX:-0}

usage() {
  echo "Usage : HOST_PATH=/mnt/16tb HOST_DEVICE=/dev/sda CONTAINER_PATH=/mnt/16tb MP_INDEX=0 $0 <CTID> [CTID...]" >&2
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

if ! command -v pct >/dev/null 2>&1; then
  echo "Erreur : la commande 'pct' est introuvable. Lancez ce script depuis un hôte Proxmox." >&2
  exit 1
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

  if mountpoint -q "${HOST_PATH}"; then
    return
  fi

  echo "Montage de ${HOST_DEVICE} sur ${HOST_PATH} (NTFS)..."
  ntfs-3g "${HOST_DEVICE}" "${HOST_PATH}"
}

ensure_ntfs3g
mkdir -p "${HOST_PATH}"
mount_device_if_needed

for ctid in "$@"; do
  if ! pct status "$ctid" >/dev/null 2>&1; then
    echo "Avertissement : le CTID $ctid n'existe pas ou n'est pas accessible" >&2
    continue
  fi

  mp_option="-mp${MP_INDEX}"
  mp_value="${HOST_PATH},mp=${CONTAINER_PATH},backup=0"

  echo "[${ctid}] Montage de ${HOST_PATH} sur ${CONTAINER_PATH} (mp${MP_INDEX})"
  pct set "$ctid" "$mp_option" "$mp_value"

done

echo "Terminé. Vérifiez avec 'pct config <CTID>' que le mapping est en place."
