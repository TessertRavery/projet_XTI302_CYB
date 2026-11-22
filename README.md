# Projet XTI302-CYB - Durcissement d'un serveur Debian 13 (Contexte A : Pixelia)

## 1. Contexte choisi
**Contexte A: Agence web Pixelia** :
- **Administrateurs (`admins`, `acces_ssh`)** : `mgoix`, `amartin`
- **Support (`support`, `acces_ssh`)** : `support` (délégation `sudo` restreinte à `/usr/local/sbin/analyse_logs.sh`)
- **Groupes métier (2 comptes par groupe, sans accès SSH)** :
  - `dev` : `jdupont`, `mcurie`
  - `design` : `lbernard`, `proux`
  - `commercial` : `cmorel`, `tleroy`
  - `freelance` : `npetit`, `sblanc` (expiration automatique fixée au `2027-06-30`, aucun droit `sudo`)

## 2. Structure du dépôt
- `comptes.csv` : inventaire des utilisateurs et de leurs groupes.
- `scripts/` : ensemble des scripts d'installation (`installer.sh`), de gestion des comptes (`creer_comptes.sh`), d'analyse (`analyse_logs.sh`), de sauvegarde (`sauvegarde.sh`) et d'audit (`verifier.sh`).
- `config/` : fichiers de configuration système (`sudoers.d`, `ssh/sshd_config.d`, `ssh/keys`, `fail2ban`, `journald.conf.d`, `nftables.conf`).

## 3. Prérequis
- Machine virtuelle **Debian 13 (Trixie)** minimale avec serveur SSH installé.
- Un **second disque virtuel** de 1 à 2 Go attaché à la VM (`/dev/sdb` ou `/dev/vdb`) pour les sauvegardes.
- Les clés publiques `.pub` des comptes `mgoix`, `amartin` et `support` déposées dans `config/ssh/keys/`.

## 4. Installation automatique (reconstruction depuis le snapshot vierge)
Cloner le dépôt sur la VM, puis exécuter en tant que `root` (ou via `sudo`) :

```bash
git clone <URL_DU_DEPOT> ~/projet-xti302
cd ~/projet-xti302
chmod +x scripts/*.sh
sudo ./scripts/installer.sh
