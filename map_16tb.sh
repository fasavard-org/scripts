#!/usr/bin/env bash
# Mappe un stockage (ex: un disque 16 To) sur tous les conteneurs LXC d'un nœud Proxmox.
#
# Exécution façon "ProxmoxVE community scripts" (copier/coller tel quel depuis un shell Proxmox) :
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/fasavard-org/scripts/main/map_16tb.sh)"
#
# Comportement par défaut :
#   - Détecte automatiquement la partition NTFS de grande taille (ex: /dev/sdX1) si HOST_DEVICE n'est pas défini
#   - Monte cette partition sur HOST_PATH (par défaut /mnt/16tb) si besoin
#   - Récupère tous les CTID via `pct list` et applique le mapping mp${MP_INDEX} à chacun
#   - Ignore les CT déjà mappés ou ceux où mp${MP_INDEX} est déjà utilisé pour autre chose
#
# Variables optionnelles (env, seulement si tu veux override) :
#   HOST_PATH=/mnt/16tb          # Chemin du disque/point de montage sur l'hôte
#   HOST_DEVICE=/dev/sdX1        # Périphérique bloc à utiliser (si tu veux forcer)
#   CONTAINER_PATH=/mnt/16tb     # Chemin cible dans le conteneur
#   MP_INDEX=0                   # Index de mp utilisé (mp0, mp1, ...)

set -euo pipefail

HOST_PATH=${HOST_PATH:-/mnt/16tb}
HOST_DEVICE=${HOST_DEVICE:-}          # maintenant vide par défaut → auto-détection
CONTAINER_PATH=${CONTAINER_PATH:-/mnt/16tb}
MP_INDEX=${MP_INDEX:-0}

if ! command -v pct >/dev/null 2>&1; then
  echo "Erreur : la commande 'pct' est introuvable. Lance ce script depuis un hôte Proxmox." >&2
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

detect_host_device() {
  # Si l'utilisateur a défini HOST_DEVICE, on respecte
  if [[ -n "${HOST_DEVICE:-}" ]]; then
    echo "HOST_DEVICE déjà défini: ${HOST_DEVICE}"
    return
  fi

  echo "Détection automatique de la partition NTFS du 16 To…"

  # On cherche une partition (pas le disque brut) avec FSTYPE=ntfs et taille >= 1 To
  local line
  while read -r name fstype size; do
    # fstype peut être "ntfs", "ntfs3", etc. On matche juste en commençant par ntfs
    if [[ "${fstype}" == ntfs* ]] && [[ "${size}" -ge 1000000000000 ]]; then
      HOST_DEVICE="/dev/${name}"
      echo "→ Partition candidate détectée : ${HOST_DEVICE} (type=${fstype}, taille=${size} bytes)"
      return
    fi
  done < <(lsblk -bndo NAME,FSTYPE,SIZE)

  echo "Erreur : aucune partition NTFS >= 1 To détectée automatiquement." >&2
  echo "Tu peux définir manuellement HOST_DEVICE, ex. :" >&2
  echo "  HOST_DEVICE=/dev/sdX1 bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/fasavard-org/scripts/main/map_16tb.sh)\"" >&2
  exit 1
}

mount_device_if_needed() {
  mkdir -p "${HOST_PATH}"

  if mountpoint -q "${HOST_PATH}"; then
    echo "HOST_PATH ${HOST_PATH} est déjà monté, on ne touche pas."
    return
  fi

  if [[ -z "${HOST_DEVICE:-}" ]]; then
    echo "Aucun HOST_DEVICE défini après détection, abandon du montage." >&2
    exit 1
  fi

  if [[ ! -b "${HOST_DEVICE}" ]]; then
    echo "Avertissement : HOST_DEVICE='${HOST_DEVICE}' n'est pas un périphérique bloc, montage ignoré." >&2
    exit 1
  fi

  echo "Montage de ${HOST_DEVICE} sur ${HOST_PATH} (NTFS)…"
  ntfs-3g "${HOST_DEVICE}" "${HOST_PATH}"
}

get_all_ctids() {
  # récupère tous les CTID visibles
  pct list | awk 'NR>1 {print $1}'
}

ensure_ntfs3g
detect_host_device
mount_device_if_needed

ctids=("$@")
if [[ ${#ctids[@]} -eq 0 ]]; then
  echo "Aucun CTID fourni, on prend tous les conteneurs retournés par 'pct list'."
  mapfile -t ctids < <(get_all_ctids)
fi

if [[ ${#ctids[@]} -eq 0 ]]; then
  echo "Aucun CTID trouvé via 'pct list'. Rien à faire."
  exit 0
fi

echo "CTID ciblés : ${ctids[*]}"
echo "Mapping : ${HOST_PATH} -> ${CONTAINER_PATH} (mp${MP_INDEX})"

for ctid in "${ctids[@]}"; do
  if ! pct status "$ctid" >/dev/null 2>&1; then
    echo "[${ctid}] Avertissement : le CTID n'existe pas ou n'est pas accessible." >&2
    continue
  fi

  echo "[${ctid}] Vérification de la configuration existante…"
  config="$(pct config "$ctid")"

  expected="mp${MP_INDEX}: ${HOST_PATH},mp=${CONTAINER_PATH},backup=0"

  if grep -q "^${expected}\$" <<<"${config}"; then
    echo "[${ctid}] mp${MP_INDEX} existe déjà avec le bon mapping, on skip."
    continue
  fi

  if grep -q "^mp${MP_INDEX}:" <<<"${config}"; then
    echo "[${ctid}] ATTENTION : mp${MP_INDEX} est déjà utilisé pour autre chose, mapping non modifié."
    echo "  Ligne actuelle :"
    grep "^mp${MP_INDEX}:" <<<"${config}" || true
    continue
  fi

  mp_option="-mp${MP_INDEX}"
  mp_value="${HOST_PATH},mp=${CONTAINER_PATH},backup=0"

  echo "[${ctid}] Application du mapping ${HOST_PATH} -> ${CONTAINER_PATH} (mp${MP_INDEX})"
  pct set "$ctid" "$mp_option" "$mp_value"
done

echo "Terminé. Vérifie avec : pct config <CTID>"
