#!/bin/bash
# creer_comptes.sh - Creation idempotente des comptes, groupes, cles SSH et ACL (/srv)
# Usage : sudo ./creer_comptes.sh [chemin_vers_comptes.csv]

set -euo pipefail

DOSSIER_SCRIPT="$(cd "$(dirname "$0")" && pwd)"
FICHIER_CSV="${1:-$DOSSIER_SCRIPT/comptes.csv}"
DOSSIER_CLES="$DOSSIER_SCRIPT/config/keys"
DATE_EXPIRATION_FREELANCE="2027-06-30"

usage() {
    echo "Usage : $0 [chemin_vers_comptes.csv]" >&2
    exit 1
}

erreur() {
    echo "Erreur : $1" >&2
    exit 2
}

# Verification des droits root
if [ "$(id -u)" -ne 0 ]; then
    erreur "Ce script doit etre lance en root."
fi

if [ ! -f "$FICHIER_CSV" ]; then
    usage
fi

creer_groupe_si_absent() {
    local groupe="$1"
    if [ -z "$groupe" ]; then
        return 0
    fi
    if ! getent group "$groupe" > /dev/null; then
        groupadd "$groupe"
        echo "[+] Groupe cree : $groupe"
    fi
}

echo "=== 1. Lecture de $FICHIER_CSV et creation des comptes (C1, C4) ==="

# Lecture ligne a ligne en ignorant l'en-tete
tail -n +2 "$FICHIER_CSV" | while IFS=';' read -r login nom grp_princ grp_sec; do
    # Ignorer les lignes vides
    [ -z "$login" ] && continue

    # 1. Creer le groupe principal s'il n'existe pas
    creer_groupe_si_absent "$grp_princ"

    # 2. Creer les groupes secondaires s'ils n'existent pas
    if [ -n "$grp_sec" ]; then
        IFS=',' read -ra LISTE_GRP <<< "$grp_sec"
        for g in "${LISTE_GRP[@]}"; do
            creer_groupe_si_absent "$g"
        done
    fi

    # 3. Creer l'utilisateur ou mettre a jour ses groupes (idempotence)
    if ! getent passwd "$login" > /dev/null; then
        useradd -m -s /bin/bash -c "$nom" -g "$grp_princ" -p '*' "$login"
        echo "[+] Compte cree : $login ($nom)"
    else
        usermod -c "$nom" -g "$grp_princ" "$login"
        echo "[=] Compte deja existant mis a jour : $login"
    fi

    # 4. Ajouter aux groupes secondaires
    if [ -n "$grp_sec" ]; then
        usermod -aG "$grp_sec" "$login"
    fi

    # 5. Exigence C4 : repertoire personnel non lisible par les autres (700)
    if [ -d "/home/$login" ]; then
        chown "$login:$grp_princ" "/home/$login"
        chmod 700 "/home/$login"
    fi

    # 6. Particularite Contexte A : expiration des comptes freelance
    if [ "$grp_princ" = "freelance" ]; then
        chage -E "$DATE_EXPIRATION_FREELANCE" "$login"
    fi

    # 7. Installation des cles publiques pour les membres de acces_ssh
    if id -nG "$login" | grep -qw "acces_ssh"; then
        install -d -m 700 -o "$login" -g "$grp_princ" "/home/$login/.ssh"
        if [ -f "$DOSSIER_CLES/${login}.pub" ]; then
            install -m 600 -o "$login" -g "$grp_princ" \
                "$DOSSIER_CLES/${login}.pub" "/home/$login/.ssh/authorized_keys"
            echo "[+] Cle SSH installee pour $login"
        else
            echo "[!] Attention : fichier $DOSSIER_CLES/${login}.pub absent" >&2
        fi
    fi
done

echo "=== 2. Configuration de l'arborescence /srv et des ACL (C2) ==="

# S'assurer que tous les groupes metier existent
for g in dev design commercial freelance; do
    creer_groupe_si_absent "$g"
done

mkdir -p /srv/projets/externe /srv/maquettes /srv/clients

# Base saine : proprietaire root:root, aucun droit pour "other" (700)
for d in /srv/projets /srv/projets/externe /srv/maquettes /srv/clients; do
    chown root:root "$d"
    setfacl -b "$d"
    chmod 700 "$d"
done

# 1) /srv/projets : dev (rw), design (r), freelance (x uniquement pour traverser vers externe)
setfacl -m g:dev:rwX,g:design:rX,g:freelance:x /srv/projets
setfacl -d -m u::rwx,g::---,g:dev:rwX,g:design:rX,o::--- /srv/projets

# 2) /srv/projets/externe : dev (rw), design (r), freelance (rw)
setfacl -m g:dev:rwX,g:design:rX,g:freelance:rwX /srv/projets/externe
setfacl -d -m u::rwx,g::---,g:dev:rwX,g:design:rX,g:freelance:rwX,o::--- /srv/projets/externe

# 3) /srv/maquettes : dev (r), design (rw), commercial (r)
setfacl -m g:dev:rX,g:design:rwX,g:commercial:rX /srv/maquettes
setfacl -d -m u::rwx,g::---,g:dev:rX,g:design:rwX,g:commercial:rX,o::--- /srv/maquettes

# 4) /srv/clients : commercial (rw)
setfacl -m g:commercial:rwX /srv/clients
setfacl -d -m u::rwx,g::---,g:commercial:rwX,o::--- /srv/clients

# Appliquer recursivement les droits aux fichiers deja presents dans chaque dossier
setfacl -R -m g:dev:rwX,g:design:rX /srv/projets
# Retablir specifiquement /srv/projets et /srv/projets/externe apres le -R
setfacl -m g:freelance:x /srv/projets
setfacl -R -m g:dev:rwX,g:design:rX,g:freelance:rwX /srv/projets/externe
setfacl -R -m g:dev:rX,g:design:rwX,g:commercial:rX /srv/maquettes
setfacl -R -m g:commercial:rwX /srv/clients

echo "[OK] Configuration des comptes et des droits /srv terminee."
exit 0
