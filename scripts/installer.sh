#!/bin/bash
# scripts/installer.sh - Deploiement complet et idempotent du serveur (Projet XTI302-CYB)
# Usage : sudo ./scripts/installer.sh

set -euo pipefail

CHEMIN_REEL="$(readlink -f "$0")"
DOSSIER_SCRIPT="$(cd "$(dirname "$CHEMIN_REEL")" && pwd)"
DOSSIER_PROJET="$(cd "$DOSSIER_SCRIPT/.." && pwd)"
POINT_MONTAGE="/mnt/sauvegardes"

erreur() {
    echo "Erreur : $1" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    erreur "Ce script doit etre execute en root (sudo ./scripts/installer.sh)."
fi

echo "=== 1. Installation des paquets officiels Debian ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
    acl \
    openssh-server \
    sudo \
    fail2ban \
    python3-systemd \
    nftables \
    rsync \
    cron \
    unattended-upgrades \
    parted \
    e2fsprogs

echo "=== 2. Preparation idempotente du second disque pour les sauvegardes (B1, B3) ==="
# Detection automatique du second disque (/dev/sdb ou /dev/vdb)
SECOND_DISQUE=""
for dev in /dev/sdb /dev/vdb; do
    if [ -b "$dev" ]; then
        SECOND_DISQUE="$dev"
        break
    fi
done

if [ -z "$SECOND_DISQUE" ]; then
    erreur "Aucun second disque (/dev/sdb ou /dev/vdb) detecte sur la VM."
fi

PARTITION="${SECOND_DISQUE}1"

# Si la partition n'existe pas encore, la creer
if [ ! -b "$PARTITION" ]; then
    echo "[+] Partitionnement de $SECOND_DISQUE..."
    parted -s "$SECOND_DISQUE" mklabel gpt
    parted -s "$SECOND_DISQUE" mkpart primary ext4 1MiB 100%
    partprobe "$SECOND_DISQUE" || true
    sleep 1
fi

# Piege evite : ne formater QUE si aucun systeme de fichiers ext4 n'est deja present
if ! blkid "$PARTITION" | grep -q 'TYPE="ext4"'; then
    echo "[+] Formatage initial de $PARTITION en ext4..."
    mkfs.ext4 -F "$PARTITION"
else
    echo "[=] Systeme de fichiers ext4 deja present sur $PARTITION (sauvegardes conservees)."
fi

mkdir -p "$POINT_MONTAGE"
UUID_PART="$(blkid -s UUID -o value "$PARTITION")"

if ! grep -q "$UUID_PART" /etc/fstab; then
    echo "UUID=$UUID_PART $POINT_MONTAGE ext4 defaults,nodev,nosuid,noexec 0 2" >> /etc/fstab
    echo "[+] Montage permanent ajoute dans /etc/fstab"
fi

if ! mountpoint -q "$POINT_MONTAGE"; then
    mount "$POINT_MONTAGE"
fi

echo "=== 3. Creation des comptes, groupes et ACL (C1, C2, C4) ==="
chmod +x "$DOSSIER_SCRIPT/creer_comptes.sh"
"$DOSSIER_SCRIPT/creer_comptes.sh" "$DOSSIER_PROJET/comptes.csv"

# Fixer les droits B3 sur le point de montage une fois le groupe admins cree
chown root:admins "$POINT_MONTAGE"
chmod 750 "$POINT_MONTAGE"

echo "=== 4. Installation des scripts d'administration dans /usr/local/sbin ==="
install -m 700 -o root -g root "$DOSSIER_SCRIPT/analyse_logs.sh" /usr/local/sbin/analyse_logs.sh
install -m 700 -o root -g root "$DOSSIER_SCRIPT/sauvegarde.sh" /usr/local/sbin/sauvegarde.sh
install -m 700 -o root -g root "$DOSSIER_SCRIPT/creer_comptes.sh" /usr/local/sbin/creer_comptes.sh

echo "=== 5. Configuration de sudo et nettoyage des droits par defaut (C3, C4) ==="
# Piege du sujet : vider le groupe sudo par defaut de Debian pour que seuls admins et support aient sudo
gpasswd -M "" sudo || true

# Nettoyer d'eventuels autres fichiers dans /etc/sudoers.d/
find /etc/sudoers.d/ -mindepth 1 ! -name "README" ! -name "10-pixelia" -delete
install -m 440 -o root -g root "$DOSSIER_PROJET/config/sudoers.d/10-pixelia" /etc/sudoers.d/10-pixelia
visudo -c

# Exigence C4 : verrouiller le compte root et proteger tous les dossiers /home/*
passwd -l root
for rep_home in /home/*; do
    if [ -d "$rep_home" ]; then
        chmod 700 "$rep_home"
    fi
done

echo "=== 6. Durcissement SSH (S1 a S5) ==="
install -m 644 -o root -g root \
    "$DOSSIER_PROJET/config/ssh/sshd_config.d/10-durcissement.conf" \
    /etc/ssh/sshd_config.d/10-durcissement.conf

# Validation avant rechargement (S5)
sshd -t
systemctl enable --now ssh
systemctl reload ssh

echo "=== 7. Journal persistant (J3), Pare-feu nftables (J2) et Fail2ban (J1) ==="
# J3 - Journald persistant
mkdir -p /etc/systemd/journald.conf.d /var/log/journal
install -m 644 -o root -g root \
    "$DOSSIER_PROJET/config/journald.conf.d/10-persistent.conf" \
    /etc/systemd/journald.conf.d/10-persistent.conf
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald

# J2 - Pare-feu nftables (recharge AVANT fail2ban pour que fail2ban recree ses chaines par-dessus)
install -m 600 -o root -g root "$DOSSIER_PROJET/config/nftables.conf" /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable --now nftables
systemctl reload nftables

# J1 - Fail2ban
install -m 644 -o root -g root \
    "$DOSSIER_PROJET/config/fail2ban/jail.d/sshd-pixelia.conf" \
    /etc/fail2ban/jail.d/sshd-pixelia.conf
fail2ban-client -t
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "=== 8. Mises a jour automatiques (D1) et hygiene du systeme (D3) ==="
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades

# D3 : retirer le droit d'ecriture "other" sur tout fichier ordinaire hors /tmp et /var/tmp
find / "$POINT_MONTAGE" -xdev \( -path /tmp -o -path /var/tmp \) -prune -o \
    -type f -perm -0002 -exec chmod o-w {} + 2>/dev/null || true

echo "=== 9. Planification de la sauvegarde et premiere execution (B1, B2) ==="
cat > /etc/cron.d/sauvegarde-pixelia << 'EOF'
# B2 - Sauvegarde quotidienne a 02h00 avec journalisation
0 2 * * * root /usr/local/sbin/sauvegarde.sh >> /var/log/sauvegarde.log 2>&1
EOF
chmod 644 /etc/cron.d/sauvegarde-pixelia
systemctl enable --now cron

# Lancer une premiere sauvegarde immediatement pour initialiser B1 et le log B2
/usr/local/sbin/sauvegarde.sh >> /var/log/sauvegarde.log 2>&1

echo "=========================================================="
echo "[SUCCES] Installation et durcissement termines."
echo "Lancez maintenant : sudo ./scripts/verifier.sh"
echo "=========================================================="
exit 0
