#!/bin/bash
# scripts/verifier.sh - Verification automatique de la conformite du serveur (Projet XTI302-CYB)
# Usage : sudo ./scripts/verifier.sh [chemin_vers_comptes.csv]
# Note : pas de 'set -e' ici car le script teste des commandes qui peuvent echouer.

set -u

CHEMIN_REEL="$(readlink -f "$0")"
DOSSIER_SCRIPT="$(cd "$(dirname "$CHEMIN_REEL")" && pwd)"
DOSSIER_PROJET="$(cd "$DOSSIER_SCRIPT/.." && pwd)"
FICHIER_CSV="${1:-$DOSSIER_PROJET/comptes.csv}"

REUSSIS=0
ECHECS=0

ok() {
    echo "[OK] $1 - $2"
    REUSSIS=$((REUSSIS + 1))
}

ko() {
    echo "[KO] $1 - $2"
    ECHECS=$((ECHECS + 1))
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : ce script doit etre lance en root (sudo ./scripts/verifier.sh)." >&2
    exit 1
fi

# ==============================================================================
# COMPTES ET DROITS (C1 a C4)
# ==============================================================================

test_C1_comptes_et_groupes() {
    local erreurs=0
    if [ ! -f "$FICHIER_CSV" ]; then
        ko "C1" "Fichier $FICHIER_CSV introuvable"
        return
    fi
    while IFS=';' read -r login nom grp_princ grp_sec; do
        [ -z "$login" ] && continue
        if ! getent passwd "$login" > /dev/null; then
            erreurs=$((erreurs + 1))
            continue
        fi
        if [ "$(id -gn "$login")" != "$grp_princ" ]; then
            erreurs=$((erreurs + 1))
        fi
        if [ -n "$grp_sec" ]; then
            IFS=',' read -ra LISTE_GRP <<< "$grp_sec"
            for g in "${LISTE_GRP[@]}"; do
                if ! id -nG "$login" | grep -qw "$g"; then
                    erreurs=$((erreurs + 1))
                fi
            done
        fi
    done < <(tail -n +2 "$FICHIER_CSV")

    if [ "$erreurs" -eq 0 ]; then
        ok "C1" "Tous les comptes et groupes de comptes.csv existent et sont conformes"
    else
        ko "C1" "$erreurs erreur(s) detectee(s) par rapport a comptes.csv"
    fi
}

test_C1_expiration_freelance() {
    if chage -l npetit 2>/dev/null | grep -q "Account expires" && \
       ! chage -l npetit 2>/dev/null | grep -q "Account expires.*: never"; then
        ok "C1" "Les comptes du groupe freelance ont bien une date d'expiration"
    else
        ko "C1" "Les comptes freelance n'expirent pas automatiquement"
    fi
}

test_C2_droits_positifs_srv() {
    # dev ecrit dans /srv/projets, freelance ecrit dans /srv/projets/externe,
    # design ecrit dans /srv/maquettes, commercial ecrit dans /srv/clients
    if sudo -u jdupont test -w /srv/projets && \
       sudo -u npetit test -w /srv/projets/externe && \
       sudo -u lbernard test -w /srv/maquettes && \
       sudo -u cmorel test -w /srv/clients; then
        ok "C2" "Droits d'ecriture autorises conformes sur /srv (dev, freelance, design, commercial)"
    else
        ko "C2" "Certains groupes metier ne peuvent pas ecrire dans leurs dossiers respectifs"
    fi
}

test_C2_droits_negatifs_srv() {
    # commercial ne lit pas /srv/projets, freelance ne lit pas /srv/projets (traverse seulement),
    # dev n'ecrit pas dans /srv/maquettes, dev ne lit pas /srv/clients
    if ! sudo -u cmorel test -r /srv/projets && \
       ! sudo -u npetit test -r /srv/projets && \
       ! sudo -u jdupont test -w /srv/maquettes && \
       ! sudo -u jdupont test -r /srv/clients; then
        ok "C2" "Acces non autorises correctement refuses sur /srv"
    else
        ko "C2" "Fuite de droits : un utilisateur metier accede a un dossier interdit"
    fi
}

test_C2_acl_defaut_heritage() {
    local f_test="/srv/projets/.test_acl_$$"
    if sudo -u jdupont touch "$f_test" 2>/dev/null; then
        if sudo -u lbernard test -r "$f_test" && ! sudo -u lbernard test -w "$f_test"; then
            ok "C2" "ACL par defaut : un fichier cree par dev dans /srv/projets est lisible (sans ecriture) par design"
        else
            ko "C2" "ACL par defaut mal heritee sur un nouveau fichier dans /srv/projets"
        fi
        rm -f "$f_test"
    else
        ko "C2" "Impossible de creer un fichier de test dans /srv/projets avec jdupont"
    fi
}

test_C3_sudo_admins_et_support() {
    if sudo -l -U mgoix 2>/dev/null | grep -q "(ALL : ALL) ALL" && \
       sudo -l -U support 2>/dev/null | grep -q "/usr/local/sbin/analyse_logs.sh" && \
       ! sudo -l -U support 2>/dev/null | grep -q "(ALL : ALL)"; then
        ok "C3" "admins a tous les droits sudo et support ne peut lancer que analyse_logs.sh"
    else
        ko "C3" "Configuration sudoers incorrecte pour admins ou support"
    fi
}

test_C3_sudo_interdit_autres() {
    if sudo -l -U jdupont 2>/dev/null | grep -q "not allowed to run sudo" && \
       sudo -l -U npetit 2>/dev/null | grep -q "not allowed to run sudo"; then
        ok "C3" "Les comptes metier et freelance ne peuvent pas utiliser sudo"
    else
        ko "C3" "Un compte non autorise possede des droits sudo"
    fi
}

test_C4_root_verrouille() {
    local statut_root
    statut_root="$(passwd -S root 2>/dev/null | awk '{print $2}')"
    if [ "$statut_root" = "L" ]; then
        ok "C4" "Le compte root est verrouille (passwd -S : L)"
    else
        ko "C4" "Le compte root n'est pas verrouille (statut : $statut_root)"
    fi
}

test_C4_homes_privatifs() {
    local mauvais_homes=0
    for d in /home/*; do
        [ -d "$d" ] || continue
        # Verifier qu'aucun droit n'est accorde au groupe ou aux autres
        if [ "$(stat -c '%a' "$d")" != "700" ]; then
            mauvais_homes=$((mauvais_homes + 1))
        fi
    done
    if [ "$mauvais_homes" -eq 0 ]; then
        ok "C4" "Tous les repertoires personnels dans /home sont en mode 700"
    else
        ko "C4" "$mauvais_homes repertoire(s) dans /home sont lisibles par d'autres utilisateurs"
    fi
}

# ==============================================================================
# ACCES SSH (S1 a S5)
# ==============================================================================

test_S1_cles_uniquement() {
    if sshd -T | grep -qi '^passwordauthentication no$' && \
       sshd -T | grep -qi '^kbdinteractiveauthentication no$' && \
       sshd -T | grep -qi '^pubkeyauthentication yes$'; then
        ok "S1" "SSH : authentification par cle uniquement, mot de passe desactive"
    else
        ko "S1" "SSH : l'authentification par mot de passe est encore active"
    fi
}

test_S2_root_interdit() {
    if sshd -T | grep -qi '^permitrootlogin no$'; then
        ok "S2" "SSH : connexion root refusee (PermitRootLogin no)"
    else
        ko "S2" "SSH : PermitRootLogin n'est pas a 'no'"
    fi
}

test_S3_allowgroups() {
    if sshd -T | grep -qi '^allowgroups acces_ssh$'; then
        ok "S3" "SSH : seuls les membres de acces_ssh sont autorises (AllowGroups)"
    else
        ko "S3" "SSH : directive AllowGroups absente ou incorrecte"
    fi
}

test_S4_essais_et_inactivite() {
    local max_tries interval count_max
    max_tries="$(sshd -T | awk '/^maxauthtries / {print $2}')"
    interval="$(sshd -T | awk '/^clientaliveinterval / {print $2}')"
    count_max="$(sshd -T | awk '/^clientalivecountmax / {print $2}')"
    if [ "$max_tries" -le 4 ] && [ "$interval" -gt 0 ] && [ "$((interval * count_max))" -le 900 ]; then
        ok "S4" "SSH : MaxAuthTries=$max_tries (<=4) et timeout d'inactivite=$((interval * count_max))s (<=900s)"
    else
        ko "S4" "SSH : limites d'essais ($max_tries) ou d'inactivite non conformes"
    fi
}

test_S5_validation_sshd_config_d() {
    if [ -f /etc/ssh/sshd_config.d/10-durcissement.conf ] && sshd -t 2>/dev/null; then
        ok "S5" "Configuration placee dans /etc/ssh/sshd_config.d/ et syntaxe validee par sshd -t"
    else
        ko "S5" "Fichier sshd_config.d manquant ou erreur de syntaxe sshd -t"
    fi
}

# ==============================================================================
# JOURNAUX ET DEFENSE (J1 a J4)
# ==============================================================================

test_J1_fail2ban_actif() {
    if systemctl is-active --quiet fail2ban && \
       fail2ban-client status sshd >/dev/null 2>&1 && \
       [ "$(fail2ban-client get sshd maxretry 2>/dev/null)" = "3" ]; then
        ok "J1" "fail2ban est actif, la jail sshd tourne avec maxretry=3"
    else
        ko "J1" "fail2ban inactif ou jail sshd mal configuree"
    fi
}

test_J2_nftables_policy_drop() {
    if systemctl is-enabled --quiet nftables && \
       nft list ruleset 2>/dev/null | grep -q "hook input priority .* policy drop"; then
        ok "J2" "Pare-feu nftables actif au demarrage avec politique d'entree par defaut 'drop'"
    else
        ko "J2" "Politique par defaut du pare-feu non positionnee a 'drop' ou service non active"
    fi
}

test_J2_nftables_regles_ssh_et_established() {
    if nft list ruleset 2>/dev/null | grep -q "ct state established,related accept" && \
       nft list ruleset 2>/dev/null | grep -q "tcp dport 22 accept"; then
        ok "J2" "Pare-feu nftables autorise les connexions etablies et le port TCP 22 (SSH)"
    else
        ko "J2" "Regles SSH ou established manquantes dans nftables"
    fi
}

test_J3_journal_persistant() {
    if [ -d /var/log/journal ] && \
       grep -qi '^Storage=persistent' /etc/systemd/journald.conf.d/10-persistent.conf 2>/dev/null; then
        ok "J3" "Journal systeme configure en mode persistant sur disque (/var/log/journal)"
    else
        ko "J3" "Journal systeme non persistant"
    fi
}

test_J4_script_analyse_logs() {
    local log_tmp="/tmp/test_ssh_$$.log"
    cat > "$log_tmp" << 'EOF'
2026-10-12T03:12:01+0200 debian sshd-session[1101]: Failed password for invalid user admin from 203.0.113.5 port 40100 ssh2
2026-10-12T03:12:02+0200 debian sshd-session[1102]: Failed password for invalid user admin from 203.0.113.5 port 40101 ssh2
2026-10-12T03:12:03+0200 debian sshd-session[1103]: Failed password for invalid user admin from 203.0.113.5 port 40102 ssh2
2026-10-12T03:13:00+0200 debian sshd-session[1104]: Accepted publickey for mgoix from 192.168.56.1 port 50200 ssh2
EOF
    # Seuil 2 -> doit renvoyer code 1 ; Seuil 10 -> doit renvoyer code 0
    local code_alerte=0
    /usr/local/sbin/analyse_logs.sh -f "$log_tmp" -s 2 >/dev/null 2>&1 || code_alerte=$?
    local code_normal=0
    /usr/local/sbin/analyse_logs.sh -f "$log_tmp" -s 10 >/dev/null 2>&1 || code_normal=$?
    rm -f "$log_tmp"

    if [ "$code_alerte" -eq 1 ] && [ "$code_normal" -eq 0 ] && \
       [ "$(stat -c '%U:%a' /usr/local/sbin/analyse_logs.sh)" = "root:700" ]; then
        ok "J4" "analyse_logs.sh detecte les seuils d'alerte (exit 1/0) et appartient a root (700)"
    else
        ko "J4" "Comportement ou droits de /usr/local/sbin/analyse_logs.sh non conformes"
    fi
}

# ==============================================================================
# SAUVEGARDE (B1 a B4)
# ==============================================================================

test_B1_disque_et_versions() {
    local nb_backups
    nb_backups="$(find /mnt/sauvegardes -maxdepth 1 -type d -name "backup_*" 2>/dev/null | wc -l)"
    if mountpoint -q /mnt/sauvegardes && [ "$nb_backups" -ge 1 ] && \
       [ -d /mnt/sauvegardes/derniere/srv ] && [ -d /mnt/sauvegardes/derniere/etc ]; then
        ok "B1" "Second disque monte sur /mnt/sauvegardes avec sauvegarde versionnee de /srv et /etc"
    else
        ko "B1" "Disque non monte ou aucune sauvegarde valide de /srv et /etc dans /mnt/sauvegardes"
    fi
}

test_B1_conservation_acl() {
    if getfacl -p /mnt/sauvegardes/derniere/srv/projets 2>/dev/null | grep -q "group:dev:rwx"; then
        ok "B1" "Les ACL de /srv sont bien conservees dans la sauvegarde"
    else
        ko "B1" "Les ACL ne sont pas conservees dans la sauvegarde"
    fi
}

test_B2_planification_et_log() {
    if [ -f /etc/cron.d/sauvegarde-pixelia ] && [ -s /var/log/sauvegarde.log ]; then
        ok "B2" "Sauvegarde planifiee dans /etc/cron.d/sauvegarde-pixelia et journalisee dans /var/log/sauvegarde.log"
    else
        ko "B2" "Planification cron absente ou journal /var/log/sauvegarde.log vide"
    fi
}

test_B3_restriction_acces_sauvegardes() {
    if [ "$(stat -c '%U:%G:%a' /mnt/sauvegardes)" = "root:admins:750" ] && \
       ! sudo -u jdupont test -r /mnt/sauvegardes && \
       sudo -u mgoix test -r /mnt/sauvegardes; then
        ok "B3" "Repertoire /mnt/sauvegardes accessible uniquement aux administrateurs (root:admins 750)"
    else
        ko "B3" "Droits de /mnt/sauvegardes trop ouverts ou incorrects"
    fi
}

test_B4_test_restauration() {
    local dir_test="/tmp/test_restau_$$"
    mkdir -p "$dir_test"
    if rsync -aA /mnt/sauvegardes/derniere/etc/hostname "$dir_test/" 2>/dev/null && \
       diff -q /etc/hostname "$dir_test/hostname" >/dev/null 2>&1; then
        ok "B4" "Test de restauration d'un fichier depuis la derniere sauvegarde reussi"
    else
        ko "B4" "Echec du test de restauration depuis /mnt/sauvegardes/derniere"
    fi
    rm -rf "$dir_test"
}

# ==============================================================================
# SYSTEME (D1 a D3)
# ==============================================================================

test_D1_unattended_upgrades() {
    if dpkg -l | grep -qw unattended-upgrades && \
       systemctl is-enabled --quiet unattended-upgrades && \
       grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        ok "D1" "Mises a jour automatiques de securite (unattended-upgrades) activees"
    else
        ko "D1" "unattended-upgrades non installe ou non active"
    fi
}

test_D2_ecoute_reseau_ssh_uniquement() {
    # Recherche des ports TCP/UDP en ecoute hors loopback (127.0.0.1 / ::1) autres que :22
    local autres_ports
    autres_ports="$(ss -tuln | awk 'NR>1 {print $5}' | grep -vE '^(127\.|\[::1\]|.*:22$)' || true)"
    if [ -z "$autres_ports" ]; then
        ok "D2" "Aucun service n'ecoute sur le reseau en dehors de SSH (port 22)"
    else
        ko "D2" "Autres ports en ecoute detectes : $autres_ports"
    fi
}

test_D3_aucun_fichier_world_writable() {
    local ww_files
    ww_files="$(find / /mnt/sauvegardes -xdev \( -path /tmp -o -path /var/tmp \) -prune -o \
        -type f -perm -0002 -print 2>/dev/null | head -n 5 || true)"
    if [ -z "$ww_files" ]; then
        ok "D3" "Aucun fichier modifiable par tous (world-writable) hors /tmp et /var/tmp"
    else
        ko "D3" "Fichiers modifiables par tous detectes : $ww_files"
    fi
}

test_D3_audit_suid() {
    local nb_suid
    nb_suid="$(find / -xdev -type f -perm -4000 2>/dev/null | wc -l)"
    # Verifier qu'aucun binaire dangereux (ex: find, vim, bash, less) n'a le bit SUID
    if ! find / -xdev -type f -perm -4000 2>/dev/null | grep -qE '/(bash|sh|vim|less|find|nano|cp|mv)$'; then
        ok "D3" "$nb_suid binaires SUID standards presents, aucun binaire SUID anormal detecte"
    else
        ko "D3" "Un binaire critique possede le bit SUID !"
    fi
}

# ==============================================================================
# EXECUTION DES 28 TESTS ET BILAN
# ==============================================================================

echo "=========================================================="
echo "   VERIFICATION AUTOMATIQUE DU SERVEUR (28 TESTS)"
echo "=========================================================="

test_C1_comptes_et_groupes
test_C1_expiration_freelance
test_C2_droits_positifs_srv
test_C2_droits_negatifs_srv
test_C2_acl_defaut_heritage
test_C3_sudo_admins_et_support
test_C3_sudo_interdit_autres
test_C4_root_verrouille
test_C4_homes_privatifs
test_S1_cles_uniquement
test_S2_root_interdit
test_S3_allowgroups
test_S4_essais_et_inactivite
test_S5_validation_sshd_config_d
test_J1_fail2ban_actif
test_J2_nftables_policy_drop
test_J2_nftables_regles_ssh_et_established
test_J3_journal_persistant
test_J4_script_analyse_logs
test_B1_disque_et_versions
test_B1_conservation_acl
test_B2_planification_et_log
test_B3_restriction_acces_sauvegardes
test_B4_test_restauration
test_D1_unattended_upgrades
test_D2_ecoute_reseau_ssh_uniquement
test_D3_aucun_fichier_world_writable
test_D3_audit_suid

TOTAL=$((REUSSIS + ECHECS))
echo "=========================================================="
echo "--- $REUSSIS/$TOTAL tests reussis ($ECHECS echec(s))"
echo "=========================================================="

[ "$ECHECS" -eq 0 ]
