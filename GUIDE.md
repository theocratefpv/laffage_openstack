# Guide pas-à-pas — Lab OpenStack sur Windows

Ce document est le compte rendu d'installation. À chaque étape clé, tu trouveras un **mockup** de l'écran que tu dois voir pour valider que tu es bien sur les bons rails. Je n'ai pas pu prendre de vraies captures d'écran (je n'ai pas accès à ton Windows), mais les mockups reproduisent les éléments à vérifier.

> **Légende des mockups** — les blocs `┌─ titre ─┐` représentent une fenêtre ou un terminal. Les valeurs entre `▼` ou `[ ]` sont à choisir/cocher.

---

## Sommaire

1. [Pré-vol — vérifications matériel](#etape-0)
2. [Installation de VMware Workstation Pro](#etape-1)
3. [Configuration des 4 réseaux VMnet](#etape-2)
4. [Construction de la VM template](#etape-3)
5. [Génération de la clé SSH](#etape-4)
6. [Déploiement automatisé des 5 VMs](#etape-5)
7. [Vérification de la joignabilité](#etape-6)
8. [Lancement d'Ansible](#etape-7)
9. [Premier login Horizon](#etape-8)

---

<a id="etape-0"></a>
## Étape 0 — Pré-vol

### 0.1 Vérifier que ton CPU expose VT-x + EPT

Sans ces extensions, KVM ne tourne pas dans les VMs OpenStack.

```powershell
# Télécharger Coreinfo (Sysinternals)
Invoke-WebRequest https://download.sysinternals.com/files/Coreinfo.zip -OutFile $env:TEMP\Coreinfo.zip
Expand-Archive $env:TEMP\Coreinfo.zip -DestinationPath $env:TEMP\Coreinfo -Force
& $env:TEMP\Coreinfo\Coreinfo64.exe -v
```

**[MOCKUP — sortie attendue]**
```
┌─ PowerShell ────────────────────────────────────────────────┐
│ Coreinfo v3.6 - Dump information on system CPU and memory   │
│                                                             │
│ Intel(R) Core(TM) i7-12700H @ 2.70GHz                       │
│                                                             │
│ HYPERVISOR      *  Hypervisor is present                    │
│ VMX             *  Supports Intel hardware-assisted virt.   │
│ EPT             *  Supports Intel extended page tables      │
│ URG             *  Supports Intel unrestricted guest        │
│                                                             │
│ * = Supported (les 4 lignes doivent avoir une étoile)       │
└─────────────────────────────────────────────────────────────┘
```

Si tu vois `-` au lieu de `*`, il faut activer la virtualisation dans le BIOS (touche F2/Del au boot, chercher *Intel Virtualization Technology* ou *AMD-V* + *SVM*).

### 0.2 Vérifier l'espace disque

```powershell
Get-PSDrive C | Select-Object Used, Free
```

Tu dois avoir **au moins 250 Go libres** sur un SSD (NVMe idéalement). Sur HDD, oublie : Ceph va ramer au point de faire échouer les timeouts d'OpenStack.

---

<a id="etape-1"></a>
## Étape 1 — Installer VMware Workstation Pro

Depuis novembre 2024, Workstation Pro est gratuit pour usage personnel. Téléchargement sur le site Broadcom (compte gratuit nécessaire).

URL : https://support.broadcom.com/group/ecx/productdownloads?subfamily=VMware+Workstation+Pro

**[MOCKUP — premier lancement]**
```
┌─ VMware Workstation 17 Pro ─────────────────────────────────────────┐
│ File  Edit  View  VM  Tabs  Help                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   ┌─ WORKSTATION PRO ─┐                                             │
│   │                   │     [+] Create a New Virtual Machine        │
│   │      [Logo]       │     [📁] Open a Virtual Machine              │
│   │                   │     [🔗] Connect to a Remote Server         │
│   └───────────────────┘     [☁]  Connect to VMware Cloud            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

À ce stade, tu n'ouvres rien — on passe directement à la config réseau.

---

<a id="etape-2"></a>
## Étape 2 — Configurer les 4 réseaux VMnet

Lance **Virtual Network Editor** en admin :
- Démarrer → tape "Virtual Network Editor" → clic droit → **Exécuter en tant qu'administrateur**

**[MOCKUP — Virtual Network Editor avec les 4 VMnets configurés]**
```
┌─ Virtual Network Editor ─────────────────────────────────────────────────┐
│                                                                          │
│  Name        Type        External Connection      Host Connection  DHCP  │
│  ────────────────────────────────────────────────────────────────────    │
│  VMnet0      Bridged     Auto-bridging              -                -    │
│  VMnet1      Host-only   -                          Connected       Yes  │
│  VMnet8      NAT         NAT                        Connected       Yes  │
│ ▶VMnet10     Host-only   -                          Connected       No   │
│ ▶VMnet20     Host-only   -                          Connected       No   │
│ ▶VMnet30     NAT         NAT                        Connected       Yes  │
│ ▶VMnet40     Host-only   -                          -               No   │
│                                                                          │
│  [ Add Network… ]  [ Remove Network ]  [ Rename Network… ]               │
│                                                                          │
│  ─── VMnet Information ──────────────────────────────────────────        │
│  ◯ Bridged   ◯ NAT   ⚫ Host-only                                        │
│  Subnet IP:  192.168.10.0    Subnet mask: 255.255.255.0                  │
│  ☑ Connect a host virtual adapter to this network                        │
│  ☐ Use local DHCP service to distribute IP addresses to VMs              │
│                                                                          │
│                            [ Apply ]  [ OK ]  [ Cancel ]                 │
└──────────────────────────────────────────────────────────────────────────┘
```

Les 4 lignes marquées `▶` sont celles que tu dois ajouter. Voir [scripts/01-network-setup.md](scripts/01-network-setup.md) pour le détail.

**Vérification** :
```powershell
Get-NetAdapter | Where-Object { $_.Name -like "*VMware*" } | Format-Table Name, Status, LinkSpeed
```

```
Name                        Status   LinkSpeed
----                        ------   ---------
VMware Network Adapter VMnet1  Up    100 Mbps
VMware Network Adapter VMnet8  Up    100 Mbps
VMware Network Adapter VMnet10 Up    100 Mbps   ← attendu
VMware Network Adapter VMnet20 Up    100 Mbps   ← attendu
VMware Network Adapter VMnet30 Up    100 Mbps   ← attendu
```

VMnet40 n'apparaît pas car non connecté à l'host (volontaire — le storage est purement inter-VMs).

---

<a id="etape-3"></a>
## Étape 3 — Construire la VM template

Procédure complète dans [scripts/02-build-template.md](scripts/02-build-template.md). Voici les écrans clés.

### 3.1 Création de la VM (assistant New VM)

**[MOCKUP — étape "Hardware customization" de l'assistant]**
```
┌─ New Virtual Machine Wizard ─ Hardware ─────────────────────────────┐
│                                                                     │
│   Memory        4096 MB                                             │
│   Processors    1 socket × 2 cores       ☑ Virtualize Intel VT-x/EPT│
│   New CD/DVD    ubuntu-22.04-live-server-amd64.iso                  │
│   Network       Custom: VMnet10                                     │
│   Hard Disk     30 GB    Store as a single file    Thin provisioned │
│                                                                     │
│   [+ Add…]  [- Remove]                              [ Close ]       │
└─────────────────────────────────────────────────────────────────────┘
```

⚠️ La case **Virtualize Intel VT-x/EPT** est *cruciale* — sans elle, KVM ne pourra pas tourner dans les computes.

### 3.2 Installation Ubuntu — l'écran à valider

Pendant l'install Ubuntu, l'écran de profil utilisateur :

**[MOCKUP — Profile setup Ubuntu Server]**
```
┌─ Profile setup ─────────────────────────────────────────────────────┐
│                                                                     │
│   Your name:           [ Ansible                                  ] │
│   Your server's name:  [ ubuntu-template                          ] │
│   Pick a username:     [ ansible                                  ] │
│   Choose a password:   [ ********                                 ] │
│   Confirm password:    [ ********                                 ] │
│                                                                     │
│                                                                     │
│                                              [ Done ]               │
└─────────────────────────────────────────────────────────────────────┘
```

Et juste après, **OBLIGATOIRE** : cocher *Install OpenSSH server*.

### 3.3 Snapshot du template

Une fois la VM "généralisée" (cf. doc) et arrêtée :

**[MOCKUP — Take Snapshot]**
```
┌─ Take Snapshot ─────────────────────────────────────────────────────┐
│                                                                     │
│   Name:        [ template-clean                                   ] │
│                                                                     │
│   Description: [ Avant tout clonage. Ne pas modifier.             ] │
│                [                                                  ] │
│                                                                     │
│                                  [ Take Snapshot ]   [ Cancel ]     │
└─────────────────────────────────────────────────────────────────────┘
```

Le nom **template-clean** est important : le script PowerShell de clonage le cherche par ce nom exact.

---

<a id="etape-4"></a>
## Étape 4 — Générer la clé SSH

Sur ta machine Windows, en PowerShell :

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\openstack-lab -N '""'
```

**[MOCKUP — sortie]**
```
┌─ PowerShell ────────────────────────────────────────────────────────┐
│ Generating public/private ed25519 key pair.                         │
│ Your identification has been saved in C:\Users\you\.ssh\openstack-lab│
│ Your public key has been saved in C:\Users\you\.ssh\openstack-lab.pub│
│ The key fingerprint is:                                             │
│ SHA256:abcd…xyz you@PC                                              │
└─────────────────────────────────────────────────────────────────────┘
```

Cette clé sera **automatiquement injectée** dans toutes les VMs par le script de déploiement (lit `openstack-lab.pub`, l'inscrit dans les cloud-init).

---

<a id="etape-5"></a>
## Étape 5 — Lancer le déploiement automatisé

C'est l'étape "magique" — une seule commande clone et configure les 5 VMs.

```powershell
cd C:\path\to\openstack-lab\scripts
.\03-deploy-vms.ps1 -TemplatePath "E:\VMs\ubuntu-template\ubuntu-template.vmx"
```

**[MOCKUP — sortie pendant l'exécution]**
```
┌─ PowerShell ────────────────────────────────────────────────────────┐
│ [OK] Outil ISO: oscdimg                                             │
│                                                                     │
│ === deployer ===                                                    │
│   Clonage linked depuis 'template-clean'...                         │
│   Génération cloud-init.iso...                                      │
│   Démarrage...                                                      │
│                                                                     │
│ === controller ===                                                  │
│   Clonage linked depuis 'template-clean'...                         │
│   Génération cloud-init.iso...                                      │
│   Démarrage...                                                      │
│                                                                     │
│ === compute01 ===                                                   │
│   Clonage linked depuis 'template-clean'...                         │
│   Création disque Ceph (30 Go thin)...                              │
│   Génération cloud-init.iso...                                      │
│   Démarrage...                                                      │
│                                                                     │
│ === compute02 ===                                                   │
│   ...                                                               │
│                                                                     │
│ === compute03 ===                                                   │
│   ...                                                               │
│                                                                     │
│ [OK] Les 5 VMs sont en cours de boot. Le premier cloud-init prend ~2 min│
└─────────────────────────────────────────────────────────────────────┘
```

Pendant ce temps, dans Workstation tu vois apparaître les 5 VMs dans la library :

**[MOCKUP — Library Workstation après le script]**
```
┌─ My Computer ───────────────────┐
│ ▼ openstack-lab                 │
│   ⚡ deployer                    │  ← powered on
│   ⚡ controller                  │  ← powered on
│   ⚡ compute01                   │  ← powered on
│   ⚡ compute02                   │  ← powered on
│   ⚡ compute03                   │  ← powered on
│ ⚙ ubuntu-template (snapshot)    │  ← gardée à part, jamais démarrée
└─────────────────────────────────┘
```

### Ce que fait cloud-init au premier boot

Ouvre la console d'une VM dans Workstation pour voir le déroulement :

**[MOCKUP — boot d'une VM avec cloud-init]**
```
┌─ controller ─ Console ──────────────────────────────────────────────┐
│ [    1.234] systemd[1]: Starting Initial cloud-init job…            │
│ [    8.512] cloud-init[567]: Cloud-init v. 23.4.x running           │
│ [   12.034] cloud-init[567]: Generating public/private rsa key…     │
│ [   15.221] cloud-init[567]: Setting hostname: controller           │
│ [   18.876] cloud-init[789]: Applying netplan: 4 interfaces         │
│ [   22.443] cloud-init[789]: Network up: 192.168.10.10              │
│ [   25.117] cloud-init[789]: Authorized keys installed for ansible  │
│ [   28.991] cloud-init[789]: Cloud-init finished. Up 28.99 seconds  │
│                                                                     │
│ Ubuntu 22.04.4 LTS controller tty1                                  │
│                                                                     │
│ controller login:                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

Si tu vois `Cloud-init finished` et le prompt de login avec le bon hostname, c'est gagné.

---

<a id="etape-6"></a>
## Étape 6 — Vérifier la joignabilité

Après ~3 min (le temps que les 5 VMs aient toutes fini cloud-init) :

```powershell
foreach ($ip in 5,10,21,22,23) {
    $h = "192.168.10.$ip"
    Write-Host "→ $h" -NoNewline
    if (Test-Connection -Quiet -Count 1 $h) { Write-Host " OK" -ForegroundColor Green }
    else { Write-Host " KO" -ForegroundColor Red }
}
```

**[MOCKUP — sortie attendue]**
```
→ 192.168.10.5 OK
→ 192.168.10.10 OK
→ 192.168.10.21 OK
→ 192.168.10.22 OK
→ 192.168.10.23 OK
```

Test SSH avec ta clé :
```powershell
ssh -i $env:USERPROFILE\.ssh\openstack-lab ansible@192.168.10.5
```

**[MOCKUP — premier login deployer]**
```
┌─ ssh deployer ──────────────────────────────────────────────────────┐
│ Welcome to Ubuntu 22.04.4 LTS (GNU/Linux 5.15.0-x generic x86_64)   │
│                                                                     │
│   System load: 0.04   Memory usage: 8%   Processes: 92              │
│   Usage of /:  4.2%   Swap usage:   0%   IPv4: 192.168.10.5         │
│                                                                     │
│ Last login: never                                                   │
│ ansible@deployer:~$                                                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

<a id="etape-7"></a>
## Étape 7 — Lancer Ansible

Sur la VM deployer, en SSH :

```bash
# Cloner le repo (ou copier-coller le dossier ansible/ via scp)
cd /opt/openstack-lab
# git clone <ton-repo>  OR  scp depuis Windows :
# (depuis Windows) scp -r -i ~/.ssh/openstack-lab .\openstack-lab ansible@192.168.10.5:/opt/

# Test de joignabilité Ansible
cd ansible
ansible -i inventory/hosts.yml all -m ping
```

**[MOCKUP — sortie ansible ping]**
```
┌─ ansible@deployer ──────────────────────────────────────────────────┐
│ deployer | SUCCESS => { "ping": "pong" }                            │
│ controller | SUCCESS => { "ping": "pong" }                          │
│ compute01 | SUCCESS => { "ping": "pong" }                           │
│ compute02 | SUCCESS => { "ping": "pong" }                           │
│ compute03 | SUCCESS => { "ping": "pong" }                           │
└─────────────────────────────────────────────────────────────────────┘
```

Si tout est vert, lance le playbook complet :

```bash
ansible-playbook -i inventory/hosts.yml site.yml | tee deploy.log
```

**[MOCKUP — déroulement Ansible (résumé)]**
```
┌─ ansible-playbook site.yml ─────────────────────────────────────────┐
│ PLAY [1. Préparation OS] ─────────────────────────────────  +10 min │
│ TASK [common : APT update]              ok: [controller, compute01… │
│ TASK [common : Désactiver swap]         changed: [all]              │
│ TASK [common : Sysctl IP forwarding]    changed: [all]              │
│ ...                                                                 │
│                                                                     │
│ PLAY [3. Cluster Ceph] ───────────────────────────────────  +15 min │
│ TASK [ceph : cephadm bootstrap]         changed: [controller]       │
│ TASK [ceph : Ajouter les hôtes]         ok: [controller]            │
│ TASK [ceph : Déclarer les OSDs]         changed: [controller]       │
│ TASK [ceph : Attendre HEALTH_OK]        ok: [controller]            │
│ TASK [ceph : Créer pools images,…]      changed: [controller]       │
│                                                                     │
│ PLAY [4. OpenStack via Kolla] ───────────────────────────  +60 min  │
│ TASK [kolla : pip kolla-ansible]        changed: [deployer]         │
│ TASK [kolla : kolla-ansible bootstrap]  changed: [deployer] (5min)  │
│ TASK [kolla : kolla-ansible prechecks]  ok: [deployer]              │
│ TASK [kolla : kolla-ansible deploy]     ok: [deployer] (50min)      │
│ TASK [kolla : kolla-ansible post-deploy]ok: [deployer]              │
│                                                                     │
│ PLAY RECAP ─────────────────────────────────────────────────────────│
│ controller : ok=42 changed=18 unreachable=0 failed=0                │
│ compute01  : ok=38 changed=15 unreachable=0 failed=0                │
│ compute02  : ok=38 changed=15 unreachable=0 failed=0                │
│ compute03  : ok=38 changed=15 unreachable=0 failed=0                │
│ deployer   : ok=24 changed= 9 unreachable=0 failed=0                │
└─────────────────────────────────────────────────────────────────────┘
```

Compte ~90-110 min selon la vitesse de ton SSD et de ton réseau (téléchargement des images Docker Kolla = ~5 Go).

---

<a id="etape-8"></a>
## Étape 8 — Premier login Horizon

Récupère le mot de passe admin :
```bash
grep keystone_admin_password /etc/kolla/passwords.yml
# → keystone_admin_password: openstack-lab-admin
```

Depuis ton navigateur Windows : http://192.168.10.50

**[MOCKUP — page de login Horizon]**
```
┌─ Horizon — http://192.168.10.50 ────────────────────────────────────┐
│                                                                     │
│                          openstack                                  │
│                          ─────────                                  │
│                                                                     │
│                  ┌───────────────────────────┐                      │
│                  │ Domain:    [ default     ]│                      │
│                  │ User Name: [ admin       ]│                      │
│                  │ Password:  [ ●●●●●●●●●●● ]│                      │
│                  │                           │                      │
│                  │      [    Connect    ]    │                      │
│                  └───────────────────────────┘                      │
└─────────────────────────────────────────────────────────────────────┘
```

Une fois connecté, valide en ligne de commande sur deployer :

```bash
source ~/admin-openrc.sh
openstack service list
openstack hypervisor list
openstack volume service list
```

**[MOCKUP — services list]**
```
+----+-----------+----------------+
| ID | Name      | Type           |
+----+-----------+----------------+
| 01 | keystone  | identity       |
| 02 | glance    | image          |
| 03 | nova      | compute        |
| 04 | neutron   | network        |
| 05 | cinder    | volume         |
| 06 | cinderv3  | volumev3       |
| 07 | placement | placement      |
+----+-----------+----------------+

+----+------------+---------------------+-------+
| ID | Hypervisor | IP Address          | State |
+----+------------+---------------------+-------+
|  1 | compute01  | 192.168.10.21       | up    |
|  2 | compute02  | 192.168.10.22       | up    |
|  3 | compute03  | 192.168.10.23       | up    |
+----+------------+---------------------+-------+
```

Si tu vois 3 hypervisors **up** et tous les services Keystone+Glance+Nova+Neutron+Cinder, **le lab est opérationnel**. Tu peux créer ta première instance Cirros (image téléchargée par le post-deploy).

---

## Récapitulatif des artefacts livrés

| Fichier | Rôle |
|---|---|
| `scripts/01-network-setup.md` | Doc manuelle config VMnets |
| `scripts/02-build-template.md` | Doc manuelle template Ubuntu |
| `scripts/03-deploy-vms.ps1` | **Automatise les 5 VMs** (clone + cloud-init + boot) |
| `scripts/cloud-init/*.yaml` | Configs par VM (réseau, hostname, SSH) |
| `ansible/site.yml` | Playbook maître |
| `ansible/inventory/hosts.yml` | Inventaire 5 nœuds + IPs |
| `ansible/group_vars/all.yml` | Versions, mdp, backends Ceph |
| `ansible/roles/common/` | Prep OS (sysctl, swap, hosts, NTP) |
| `ansible/roles/ceph/` | cephadm + pools + keyrings |
| `ansible/roles/kolla/` | bootstrap + prechecks + deploy |
| `docs/architecture.svg` | Schéma global du lab |

## Si quelque chose foire

| Symptôme | Cause probable | Fix |
|---|---|---|
| `vmrun clone` échoue avec "snapshot not found" | Tu n'as pas nommé le snapshot exactement `template-clean` | Renommer dans Workstation, relancer |
| Cloud-init ne configure pas le réseau | datasource pas en NoCloud | Sur le template : `dpkg-reconfigure cloud-init` puis re-snap |
| Ansible ping KO sur une VM | Clé SSH pas injectée | Vérifier que `openstack-lab.pub` était bien le contenu remplacé dans les `*.user-data.yaml` |
| `kolla-ansible prechecks` échoue sur "VIP" | VIP `192.168.10.50` déjà utilisée ou hors subnet | Changer dans `group_vars/all.yml` |
| `nova_compute_virt_type: kvm` mais compute boot en qemu lent | Nested virt pas activée | Vérifier `vhv.enable = "TRUE"` dans le .vmx, redémarrer la VM |
| Ceph `HEALTH_ERR` sur OSDs | Disque /dev/sdb occupé | `sgdisk --zap-all /dev/sdb` puis relancer le rôle ceph |
