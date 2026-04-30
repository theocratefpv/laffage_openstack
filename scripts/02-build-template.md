# Construction de la VM template

> Étape manuelle, ~30 min. Une seule fois — toutes les autres VMs sont clonées d'ici.

## 1. Créer la VM dans Workstation

- **New Virtual Machine** → Custom (advanced)
- Compatibility : Workstation 17.x
- ISO : Ubuntu Server 22.04 LTS
- OS : Linux → Ubuntu 64-bit
- Nom : `ubuntu-template`
- Emplacement : `E:\VMs\ubuntu-template\`
- Processeurs : 1 socket × 2 cores
- RAM : 4096 Mo
- Network : VMnet10
- Disque : 30 Go, **stocké dans un seul fichier**, thin provisioned
- Avant de finir : **Customize Hardware** → cocher "Virtualize Intel VT-x/EPT" sur le CPU

## 2. Installer Ubuntu (minimal)

- Langue : English (évite les soucis de locale plus tard)
- Réseau : laisser DHCP pour l'instant
- Pas de proxy, pas de mirror custom
- LVM **désactivé** (plus simple pour un lab)
- Profile :
  - Your name : `Ansible`
  - Server name : `ubuntu-template`
  - Username : `ansible`
  - Password : `ansible` (peu importe, sera désactivé après)
- **Install OpenSSH server** : OUI
- Pas de snaps featured
- Reboot

## 3. Préparer le template

Une fois reboot, login en `ansible` / `ansible`, puis :

```bash
# Sudo NOPASSWD pour l'utilisateur ansible
echo 'ansible ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/ansible
sudo chmod 0440 /etc/sudoers.d/ansible

# Paquets nécessaires au cloud-init et à Ansible
sudo apt update
sudo apt install -y \
    cloud-init cloud-utils \
    qemu-guest-agent open-vm-tools \
    python3 python3-apt \
    chrony curl git

# Activer cloud-init avec datasource NoCloud
sudo dpkg-reconfigure cloud-init
# Décocher tous les datasources sauf NoCloud (espace pour cocher/décocher, Tab pour OK)
```

## 4. Préparer la clé SSH

Sur ta machine Windows, génère une paire de clés (PowerShell) :

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\openstack-lab -N '""'
```

Récupère le contenu de la clé publique (`openstack-lab.pub`), tu vas la coller dans les fichiers cloud-init.

## 5. Généraliser la VM

**Crucial** : sans ça, tous les clones auront le même machine-id et la même clé SSH host = collisions.

```bash
# Vider l'historique apt et le cache
sudo apt clean
sudo rm -rf /var/lib/apt/lists/*

# Reset machine-id
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id

# Reset clés SSH host (recréées au premier boot)
sudo rm -f /etc/ssh/ssh_host_*

# Reset cloud-init
sudo cloud-init clean --logs --seed

# Vider l'historique bash
history -c && sudo rm -f /home/ansible/.bash_history /root/.bash_history

# Shutdown
sudo shutdown -h now
```

## 6. Snapshot

Dans Workstation, sur la VM template arrêtée :
- **VM** → **Snapshot** → **Take Snapshot…**
- Nom : `template-clean`
- Description : "Avant tout clonage. Ne pas modifier."

C'est terminé. La VM template ne doit plus jamais être démarrée. Les linked clones partiront de ce snapshot.

## Résultat attendu

```
E:\VMs\ubuntu-template\
├── ubuntu-template.vmx
├── ubuntu-template.vmdk
├── ubuntu-template-Snapshot1.vmsn
└── ubuntu-template-000001.vmdk    ← deltas du snapshot
```
