#!/bin/bash
# scripts/sauvegarde.sh - Sauvegarde incrementale versionnee de /srv et /etc (Exigences B1, B3)
# Usage : sudo /usr/local/sbin/sauvegarde.sh

set -euo pipefail

POINT_MONTAGE="/mnt/sauvegardes"
DATE_JOUR="$(date +%Y-%m-%d_%Hh%M%S)"
CIBLE="$POINT_MONTAGE/backup_$DATE_JOUR"
LIEN_DERNIERE="$POINT_MONTAGE/derniere"
NB_VERSIONS_GARDEES=7

erreur() {
    echo "[$(date --iso-8601=seconds)] ERREUR : $1" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    erreur "Ce script doit etre execute en root."
fi

# Verifier que le disque de sauvegarde existe et est bien monte
if ! mountpoint -q "$POINT_MONTAGE"; then
    erreur "$POINT_MONTAGE n'est pas un point de montage actif."
fi

# Exigence B3 : restreindre l'acces aux seuls administrateurs
chown root:admins "$POINT_MONTAGE"
chmod 750 "$POINT_MONTAGE"

echo "[$(date --iso-8601=seconds)] Debut de la sauvegarde vers $CIBLE"
mkdir -p "$CIBLE"

# Options rsync : -a (archive), -A (conserve les ACL), --delete
OPTIONS_RSYNC=(-aA --delete)

# Si une sauvegarde precedente existe, utiliser --link-dest pour ne pas recopier l'inchange
if [ -L "$LIEN_DERNIERE" ] && [ -d "$LIEN_DERNIERE" ]; then
    OPTIONS_RSYNC+=(--link-dest="$LIEN_DERNIERE")
fi

# Sauvegarde de /srv et /etc (sans slash final pour garder les dossiers srv/ et etc/ dans la cible)
rsync "${OPTIONS_RSYNC[@]}" /srv /etc "$CIBLE/"

# Mettre a jour le lien symbolique vers la derniere sauvegarde reussie
ln -snf "$CIBLE" "$LIEN_DERNIERE"

# Rotation : garder les 7 versions les plus recentes, supprimer les plus anciennes
TOTAL_VERSIONS="$(find "$POINT_MONTAGE" -maxdepth 1 -type d -name "backup_*" | wc -l)"
if [ "$TOTAL_VERSIONS" -gt "$NB_VERSIONS_GARDEES" ]; then
    find "$POINT_MONTAGE" -maxdepth 1 -type d -name "backup_*" | sort | head -n -"$NB_VERSIONS_GARDEES" | while read -r ANCIENNE; do
        echo "[$(date --iso-8601=seconds)] Suppression de l'ancienne version : $ANCIENNE"
        rm -rf "$ANCIENNE"
    done
fi

echo "[$(date --iso-8601=seconds)] Sauvegarde terminee avec succes : $CIBLE"
exit 0
