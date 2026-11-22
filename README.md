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

- Machine virtuelle **Debian 13** minimale avec serveur SSH installé.

- Un **second disque virtuel** de 2 Go attaché à la VM (`/dev/sdb` ou `/dev/vdb`) pour les sauvegardes.

- Les clés publiques `.pub` des comptes `mgoix`, `amartin` et `support` déposées dans `config/ssh/keys/`.

- Pour la préparation des clés SSH de test, exécutez les commandes suivantes (sur le poste hôte) :

```bash
mkdir -p config/ssh/keys
ssh-keygen -t ed25519 -C "mgoix@pixelia" -f /tmp/id_mgoix -N "PassphraseSolide1!"
ssh-keygen -t ed25519 -C "amartin@pixelia" -f /tmp/id_amartin -N "PassphraseSolide2!"
ssh-keygen -t ed25519 -C "support@pixelia" -f /tmp/id_support -N "PassphraseSupport!"
cp /tmp/id_mgoix.pub config/ssh/keys/mgoix.pub
cp /tmp/id_amartin.pub config/ssh/keys/amartin.pub
cp /tmp/id_support.pub config/ssh/keys/support.pub
```

## 4. Installation automatique (reconstruction depuis le snapshot vierge)

Cloner le dépôt sur la VM, puis exécuter en tant que `root` (ou via `sudo`) :

```bash
git clone https://github.com/TessertRavery/projet_XTI302_CYB.git ~/projet-xti302
cd ~/projet-xti302
chmod +x scripts/*.sh
sudo ./scripts/installer.sh
```
