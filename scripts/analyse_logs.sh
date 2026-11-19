#!/bin/bash
# scripts/analyse_logs.sh - Rapport d'analyse des connexions SSH (Exigence J4)
# Usage : analyse_logs.sh [-f fichier] [-s seuil]

set -euo pipefail

FICHIER=""
SEUIL=5

usage() {
    echo "Usage : $0 [-f fichier_log] [-s seuil_alerte]" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -f)
            [ "$#" -ge 2 ] || usage
            FICHIER="$2"
            shift 2
            ;;
        -s)
            [ "$#" -ge 2 ] || usage
            SEUIL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

# Verifier que le seuil est bien un entier positif
if ! echo "$SEUIL" | grep -qE '^[0-9]+$'; then
    echo "Erreur : le seuil doit etre un nombre entier positif." >&2
    exit 2
fi

lire_journal() {
    if [ -n "$FICHIER" ]; then
        if [ ! -r "$FICHIER" ]; then
            echo "Erreur : fichier $FICHIER introuvable ou illisible." >&2
            exit 2
        fi
        cat "$FICHIER"
    else
        journalctl -u ssh --no-pager 2>/dev/null || true
    fi
}

CONTENU="$(lire_journal)"
REGEX_ECHEC='Failed password for|Invalid user|not allowed because'
REGEX_IP='([0-9]{1,3}\.){3}[0-9]{1,3}'

echo "=========================================="
echo "   RAPPORT D'ANALYSE SSH ($(date +%F))"
echo "   Seuil d'alerte : $SEUIL echecs"
echo "=========================================="

echo ""
echo "--- 1. Echecs par adresse IP ---"
ECHECS_IP="$(echo "$CONTENU" | grep -E "$REGEX_ECHEC" | grep -oE "$REGEX_IP" | sort | uniq -c | sort -rn || true)"
if [ -n "$ECHECS_IP" ]; then
    echo "$ECHECS_IP"
else
    echo "Aucun echec detecte."
fi

echo ""
echo "--- 2. Comptes vises par des echecs ---"
COMPTES_VISES="$(echo "$CONTENU" | grep -E "$REGEX_ECHEC" \
    | sed -nE 's/.*(Failed password for (invalid user )?|Invalid user |User )([^ ]+).*/\3/p' \
    | sort | uniq -c | sort -rn || true)"
if [ -n "$COMPTES_VISES" ]; then
    echo "$COMPTES_VISES"
else
    echo "Aucun compte vise."
fi

echo ""
echo "--- 3. Connexions reussies ---"
REUSSITES="$(echo "$CONTENU" | grep -E 'Accepted (password|publickey) for' \
    | sed -nE 's/.*Accepted (password|publickey) for ([^ ]+) from ([0-9.]+).*/\2 from \3/p' \
    | sort | uniq -c | sort -rn || true)"
if [ -n "$REUSSITES" ]; then
    echo "$REUSSITES"
else
    echo "Aucune connexion reussie."
fi

# Verification du seuil d'alerte pour le code de sortie
MAX_ECHECS=0
if [ -n "$ECHECS_IP" ]; then
    MAX_ECHECS="$(echo "$ECHECS_IP" | head -n 1 | awk '{print $1}')"
fi

echo ""
if [ "$MAX_ECHECS" -ge "$SEUIL" ]; then
    echo "[ALERTE] Au moins une adresse IP atteint ou depasse le seuil ($MAX_ECHECS >= $SEUIL) !" >&2
    exit 1
else
    echo "[OK] Aucune adresse IP ne depasse le seuil ($MAX_ECHECS < $SEUIL)."
    exit 0
fi
