# HANDOFF — Lab OpenStack sur Windows + VMware Workstation

**À l'attention de Claude Code** : ce document est une passation complète. L'utilisateur a démarré ce projet avec une autre instance de Claude (Cowork), et te le confie pour la suite. Lis tout avant d'agir.

---

## 0. TL;DR — Où on en est

L'utilisateur **kilian** (login Windows: `dionys`) déploie un lab OpenStack en hyperconvergé sur VMware Workstation Pro 17, sur Windows. À l'instant où ce document est écrit :

✅ La VM template Ubuntu 22.04 est créée, généralisée, snapshotée (`template-clean`)
✅ Le script PowerShell `03-deploy-vms.ps1` vient de s'exécuter avec succès
✅ Les 5 VMs (deployer, controller, compute01, compute02, compute03) sont en train de booter
✅ cloud-init est en train de les configurer (IPs statiques, user `dio`, clé SSH)

⏳ **Prochaine étape immédiate** : vérifier que les 5 VMs sont joignables en ping, puis SSH sur le deployer, puis lancer le déploiement Ansible (Ceph + Kolla-Ansible → OpenStack).

⏸️ **Estimé pour finir** : ~90-110 min de déploiement Ansible automatique + 15 min de vérifications post-deploy.

---

## 1. Contexte du projet

### 1.1 Objectif

Monter un lab OpenStack fonctionnel (1 controller + 3 computes hyperconvergés avec Ceph colocalisé) sur une seule machine Windows, presque entièrement automatisé via Ansible.

### 1.2 Décisions d'architecture (déjà tranchées)

| Choix | Valeur | Raison |
|---|---|---|
| Hyperviseur | **VMware Workstation Pro 17** | Gratuit perso depuis 2024, garde Windows, nested virt OK pour KVM. Proxmox écarté (bare-metal, écraserait Windows) |
| Distribution Linux | Ubuntu Server 22.04 LTS | LTS, support Kolla et Ceph optimaux |
| OpenStack | 2024.1 "Caracal" | LTS jusqu'à 2026-04 |
| Orchestration | Kolla-Ansible 19.0.0 | Containers Docker, simple à maintenir |
| Stockage distribué | **Ceph Reef (18.x)** via cephadm | Choix communautaire imposé. cephadm > ceph-ansible (déprécié) |
| Topologie | **Hyperconvergée** | 32 Go RAM ne permet pas 6 VMs (3 compute + 3 storage), donc Ceph OSD colocalisé sur chaque compute |
| User Linux | **`dio`** (pas `ansible`) | Choix utilisateur lors de l'install Ubuntu, tous les configs adaptés |

### 1.3 Plan d'allocation matérielle

| VM | RAM | vCPU | Disque sys | Disque Ceph |
|---|---|---|---|---|
| deployer | 2 Go | 1 | 30 Go (linked) | — |
| controller | 8 Go | 2 | 30 Go (linked) | — |
| compute01 | 6 Go | 2 | 30 Go (linked) | 30 Go (OSD) |
| compute02 | 6 Go | 2 | 30 Go (linked) | 30 Go (OSD) |
| compute03 | 6 Go | 2 | 30 Go (linked) | 30 Go (OSD) |
| **Total** | **28 Go** | **9** | — | — |

(Overcommit léger sur CPU = OK pour un lab, RAM strictement dans les 32 Go avec 4 Go restants pour Windows.)

### 1.4 Plan réseau

⚠️ **Important** : l'utilisateur a créé **VMnet1/2/3/4** (pas VMnet10/20/30/40 comme initialement prévu). Le script PowerShell a été adapté en conséquence. Les IPs et subnets restent les mêmes.

| VMnet | Type | Subnet | DHCP | Host adapter | Rôle |
|---|---|---|---|---|---|
| **VMnet1** | Host-only | 192.168.10.0/24 | OFF | ON | Management (API + SSH) |
| **VMnet2** | Host-only | 192.168.20.0/24 | OFF | ON | Tenant (VXLAN entre instances) |
| **VMnet3** | NAT | 192.168.30.0/24 | ON | ON | External (floating IP, sortie Internet) |
| **VMnet4** | Host-only | 192.168.40.0/24 | OFF | OFF | Storage (Ceph public + cluster) |

### 1.5 Plan d'adressage des VMs

Toutes les IPs sont **statiques** (injectées par cloud-init au premier boot, pas DHCP). Le DHCP n'existe que sur VMnet3 et n'est utilisé que pour donner Internet aux instances OpenStack via leurs floating IPs.

| VM | mgmt (VMnet1) | tenant (VMnet2) | ext (VMnet3) | storage (VMnet4) |
|---|---|---|---|---|
| deployer | **192.168.10.5** | — | DHCP | — |
| controller | **192.168.10.10** | 192.168.20.10 | DHCP | 192.168.40.10 |
| compute01 | **192.168.10.21** | 192.168.20.21 | DHCP | 192.168.40.21 |
| compute02 | **192.168.10.22** | 192.168.20.22 | — | 192.168.40.22 |
| compute03 | **192.168.10.23** | 192.168.20.23 | — | 192.168.40.23 |

VIP de management OpenStack : `192.168.10.50` (sera portée par keepalived sur le controller).

---

## 2. Topographie disque (où sont les fichiers)

### 2.1 Sur le système Windows

```
E:\
├── openstack-lab\                    ← le repo Ansible/scripts (à utiliser)
│   ├── README.md
│   ├── GUIDE.md                      ← guide pas-à-pas illustré
│   ├── ansible\
│   │   ├── ansible.cfg
│   │   ├── site.yml                  ← playbook maître
│   │   ├── inventory\hosts.yml
│   │   ├── group_vars\all.yml
│   │   └── roles\
│   │       ├── common\tasks\main.yml
│   │       ├── ceph\tasks\main.yml
│   │       └── kolla\tasks\main.yml
│   ├── docs\architecture.svg
│   └── scripts\
│       ├── 01-network-setup.md
│       ├── 02-build-template.md
│       ├── 03-deploy-vms.ps1         ← script PowerShell de clonage
│       └── cloud-init\
│           ├── deployer.user-data.yaml
│           ├── controller.user-data.yaml
│           ├── compute.user-data.tmpl
│           ├── compute01.user-data.yaml  ← générés par le script
│           ├── compute02.user-data.yaml
│           └── compute03.user-data.yaml
│
└── tps_openstack\                    ← les VMs
    ├── ubuntu-template.vmx           ← template (POWERED OFF, ne pas allumer)
    ├── ubuntu-template.vmdk
    ├── ubuntu-template-Snapshot1.vmsn  ← snapshot 'template-clean'
    └── openstack-lab\                ← les 5 VMs déployées
        ├── deployer\
        │   ├── deployer.vmx
        │   ├── deployer-000001.vmdk  (linked clone)
        │   └── cloud-init.iso
        ├── controller\
        ├── compute01\
        │   ├── compute01.vmx
        │   ├── compute01-000001.vmdk
        │   ├── compute01-ceph.vmdk   ← le 2e disque pour Ceph OSD
        │   └── cloud-init.iso
        ├── compute02\
        └── compute03\
```

### 2.2 Clé SSH

```
C:\Users\dionys\.ssh\
├── openstack-lab          ← clé privée (utilisée pour SSH vers les VMs)
└── openstack-lab.pub      ← clé publique (déjà injectée dans cloud-init)
```

Empreinte de la clé publique : `SHA256:0wm0KxsKMqvRQW+tLEwkBfbSqnRDerXstLUZkkkdFyM`

### 2.3 Outillage Windows

- VMware Workstation Pro 17.x : `C:\Program Files (x86)\VMware\VMware Workstation\`
- WSL Ubuntu (avec `genisoimage`) : pour la création des ISOs cloud-init NoCloud

---

## 3. État précis à l'instant T (état que tu hérites)

### 3.1 Ce qui a été fait

1. ✅ VMware Workstation Pro installé sur Windows
2. ✅ Les 4 VMnets créés via Virtual Network Editor (admin) — VMnet1, 2, 3, 4
3. ✅ VM `ubuntu-template` créée dans Workstation, Ubuntu Server 22.04 installé, OpenSSH inclus
4. ✅ Template préparé :
   - User `dio` avec sudo NOPASSWD (`/etc/sudoers.d/dio`)
   - Paquets installés : `cloud-init cloud-utils qemu-guest-agent open-vm-tools python3 python3-apt chrony curl git net-tools`
   - cloud-init forcé en mode NoCloud uniquement (`/etc/cloud/cloud.cfg.d/90_dpkg.cfg = datasource_list: [ NoCloud, None ]`)
5. ✅ Template généralisé (machine-id reset, SSH host keys reset, cloud-init clean)
6. ✅ Snapshot `template-clean` pris (VM éteinte, ne plus l'allumer)
7. ✅ Clé SSH `openstack-lab` générée côté Windows
8. ✅ WSL Ubuntu installé avec `genisoimage`
9. ✅ Script `03-deploy-vms.ps1` exécuté avec succès :
   - 5 linked clones créés depuis le snapshot
   - Disques Ceph 30 Go ajoutés aux 3 computes
   - ISOs cloud-init NoCloud générés et attachés
   - VMs démarrées
10. ⏳ cloud-init est en train de tourner sur les 5 VMs (~2 min chacune, en parallèle)

### 3.2 Ce qu'il reste à faire — ROADMAP

```
PHASE 3 : Vérification post-clonage (5 min)
├─ 3.1 Test-Connection sur les 5 IPs
├─ 3.2 Premier SSH vers deployer
└─ 3.3 Vérification cloud-init sur chaque VM

PHASE 4 : Préparer le deployer (10 min)
├─ 4.1 Copier le repo openstack-lab sur le deployer
├─ 4.2 Installer ansible sur le deployer
├─ 4.3 Test de joignabilité Ansible (ansible all -m ping)
└─ 4.4 Distribuer la clé SSH du deployer aux 4 autres nœuds

PHASE 5 : Déploiement OpenStack (90-110 min)
├─ 5.1 Lancer site.yml depuis le deployer
├─ 5.2 Surveiller le déroulement (3 plays : common, ceph, kolla)
└─ 5.3 Récupérer admin-openrc.sh

PHASE 6 : Vérification post-deploy (10 min)
├─ 6.1 Login Horizon via http://192.168.10.50
├─ 6.2 openstack service list / hypervisor list
└─ 6.3 Lancement d'une instance Cirros de test
```

---

## 4. Phase 3 — Vérification du clonage (À FAIRE MAINTENANT)

### 4.1 Attendre 3 min après l'exécution du script PowerShell

cloud-init prend ~2 min par VM, en parallèle, donc 3 min suffisent.

### 4.2 Test de joignabilité

```powershell
foreach ($ip in 5,10,21,22,23) {
    $h = "192.168.10.$ip"
    Write-Host -NoNewline "→ $h "
    if (Test-Connection -Quiet -Count 1 $h) { Write-Host "OK" -ForegroundColor Green }
    else { Write-Host "KO" -ForegroundColor Red }
}
```

**Attendu** :
```
→ 192.168.10.5 OK
→ 192.168.10.10 OK
→ 192.168.10.21 OK
→ 192.168.10.22 OK
→ 192.168.10.23 OK
```

**Si une VM ne répond pas** :
- Ouvre sa console dans Workstation et vérifie l'état de cloud-init :
  ```bash
  sudo cloud-init status
  # Attendu : status: done
  # Si "running" : attendre encore 1-2 min
  # Si "error" :
  sudo cloud-init status --long
  sudo journalctl -u cloud-init -b
  ```
- Si erreur netplan : vérifier `/etc/netplan/01-net.yaml`, y a-t-il les bonnes IPs ? Faire `sudo netplan apply`
- Si erreur de SSH key : vérifier `/home/dio/.ssh/authorized_keys`, contient-il la clé publique ?

### 4.3 Premier SSH vers le deployer

```powershell
ssh -i $env:USERPROFILE\.ssh\openstack-lab dio@192.168.10.5
```

À la première connexion, accepter le fingerprint (`yes`). Tu dois arriver sur le prompt :
```
dio@deployer:~$
```

### 4.4 Vérifier la config réseau du deployer

```bash
ip -br addr
# ens33 doit avoir 192.168.10.5
# ens34 doit avoir une IP DHCP en 192.168.30.x

ping -c 2 8.8.8.8
# Doit répondre (sortie Internet via VMnet3)

ping -c 2 192.168.10.10
# Doit répondre (controller joignable)
```

### 4.5 Faire pareil sur les 4 autres VMs (rapide)

```powershell
foreach ($host in @{
    "controller" = "192.168.10.10";
    "compute01"  = "192.168.10.21";
    "compute02"  = "192.168.10.22";
    "compute03"  = "192.168.10.23";
}.GetEnumerator()) {
    Write-Host "`n=== $($host.Key) ===" -ForegroundColor Cyan
    ssh -i $env:USERPROFILE\.ssh\openstack-lab -o StrictHostKeyChecking=no dio@$($host.Value) "hostname && ip -br addr show | grep -v lo"
}
```

Chaque VM doit afficher son hostname + ses interfaces avec les bonnes IPs.

---

## 5. Phase 4 — Préparer le deployer

### 5.1 Copier le repo openstack-lab vers le deployer

Depuis Windows :

```powershell
scp -i $env:USERPROFILE\.ssh\openstack-lab -r E:\openstack-lab dio@192.168.10.5:/tmp/
ssh -i $env:USERPROFILE\.ssh\openstack-lab dio@192.168.10.5 "sudo mv /tmp/openstack-lab /opt/ && sudo chown -R dio:dio /opt/openstack-lab"
```

### 5.2 Sur le deployer, installer ansible

Depuis SSH sur le deployer :

```bash
ssh -i ~/.ssh/openstack-lab dio@192.168.10.5

# Une fois sur le deployer :
sudo apt update
sudo apt install -y python3-pip python3-venv git
python3 -m venv ~/venv
source ~/venv/bin/activate
pip install --upgrade pip
pip install ansible-core==2.16.* docker

# Collections Ansible
ansible-galaxy collection install community.general ansible.posix community.docker
```

### 5.3 Test de joignabilité Ansible

```bash
cd /opt/openstack-lab/ansible
ansible-inventory -i inventory/hosts.yml --list  # vérifier que l'inventaire est valide
ansible -i inventory/hosts.yml all -m ping
```

**Attendu** :
```
deployer | SUCCESS => { "ping": "pong" }
controller | SUCCESS => { "ping": "pong" }
compute01 | SUCCESS => { "ping": "pong" }
compute02 | SUCCESS => { "ping": "pong" }
compute03 | SUCCESS => { "ping": "pong" }
```

**Si KO** : la clé SSH du deployer (générée par cloud-init dans `/home/dio/.ssh/id_ed25519`) n'est pas encore distribuée aux 4 autres nœuds. C'est normal — c'est la première chose que fait `site.yml`. Pour tester en attendant, utilise la clé `openstack-lab` :

```bash
# Copier la clé openstack-lab depuis Windows vers /home/dio/.ssh/openstack-lab
scp C:\Users\dionys\.ssh\openstack-lab dio@192.168.10.5:/home/dio/.ssh/

# Sur le deployer
chmod 600 ~/.ssh/openstack-lab
# Tester :
ansible -i inventory/hosts.yml all -m ping --private-key=~/.ssh/openstack-lab
```

---

## 6. Phase 5 — Déploiement OpenStack via Ansible

### 6.1 Lancement

Depuis le deployer (SSH actif) :

```bash
cd /opt/openstack-lab/ansible
source ~/venv/bin/activate
ansible-playbook -i inventory/hosts.yml site.yml | tee ~/deploy-$(date +%Y%m%d-%H%M%S).log
```

### 6.2 Déroulement attendu

Le playbook `site.yml` exécute 4 plays :

| Play | Cibles | Tâches | Durée |
|---|---|---|---|
| 1. Préparation OS | tous OpenStack | apt update, swap off, sysctl, /etc/hosts, chrony | 10 min |
| 2. SSH trust deployer→all | tous | distribue la clé du deployer | 1 min |
| 3. Cluster Ceph | controller + computes | cephadm bootstrap, OSDs, pools | 15 min |
| 4. OpenStack via Kolla | deployer | bootstrap-servers, prechecks, deploy (+pull docker) | 60-80 min |

### 6.3 Surveiller

Dans une autre fenêtre PowerShell, ouvre un second SSH :

```bash
ssh -i $env:USERPROFILE\.ssh\openstack-lab dio@192.168.10.5
tail -f ~/deploy-*.log
```

Ou pour suivre l'état Ceph en temps réel pendant la phase 3 :
```bash
ssh -i $env:USERPROFILE\.ssh\openstack-lab dio@192.168.10.10
sudo ceph -s -w
```

### 6.4 Variables clés (déjà fixées dans `group_vars/all.yml`)

```yaml
openstack_release: "2024.1"
kolla_ansible_version: "19.0.0"
kolla_internal_vip_address: "192.168.10.50"   # VIP des API OpenStack
kolla_external_vip_address: "192.168.30.50"
kolla_admin_password: "openstack-lab-admin"   # mot de passe admin Horizon
glance_backend_ceph: "yes"
cinder_backend_ceph: "yes"
nova_backend_ceph: "yes"
```

---

## 7. Phase 6 — Vérification post-deploy

### 7.1 Récupérer admin-openrc.sh

Sur le deployer, à la fin du playbook :

```bash
ls -la /etc/kolla/admin-openrc.sh
source /etc/kolla/admin-openrc.sh
```

### 7.2 Vérifier les services

```bash
openstack service list
openstack endpoint list
openstack hypervisor list
openstack compute service list
openstack network agent list
openstack volume service list
```

**Attendu** :
- 5+ services (keystone, glance, nova, neutron, cinder, placement, ...)
- 3 hypervisors UP (compute01, compute02, compute03)
- L3-agent, DHCP-agent, Metadata-agent UP sur le controller
- cinder-volume + cinder-scheduler UP

### 7.3 Vérifier Ceph

```bash
ssh dio@192.168.10.10
sudo ceph -s
# HEALTH_OK ou HEALTH_WARN (avec warning bénin sur le nb d'OSDs) attendu

sudo ceph osd pool ls
# Doit lister : images, volumes, vms, backups (+ les pools Ceph internes)
```

### 7.4 Login Horizon

Depuis Windows : http://192.168.10.50

- Domain : `default`
- User : `admin`
- Password : `openstack-lab-admin`

### 7.5 Premier test : lancer une instance Cirros

```bash
# Sur le deployer, source admin-openrc
openstack image list
# Doit contenir cirros-0.6.x (téléchargée par post-deploy)

# Créer un réseau et un sous-réseau
openstack network create demo-net
openstack subnet create --network demo-net --subnet-range 10.0.0.0/24 demo-subnet

# Créer un keypair
openstack keypair create --public-key ~/.ssh/id_ed25519.pub demo-key

# Créer une VM
openstack server create \
    --image cirros-0.6.2-x86_64-disk \
    --flavor m1.tiny \
    --network demo-net \
    --key-name demo-key \
    test-vm

# Vérifier
openstack server list
# Status doit passer de BUILD → ACTIVE en ~30s
```

---

## 8. Inventaire des fichiers de configuration importants

### 8.1 `/opt/openstack-lab/ansible/inventory/hosts.yml`

Inventaire des 5 nœuds avec leurs IPs et groupes (`controllers`, `computes`, `ceph_mons`, `ceph_osds`, `openstack`).

Variables importantes :
- `ansible_user: dio`
- `ceph_osd_device: /dev/sdb` (sur les computes uniquement)

### 8.2 `/opt/openstack-lab/ansible/group_vars/all.yml`

Variables globales : versions, VIPs, interfaces réseau, mots de passe Kolla, services activés/désactivés, pools Ceph.

⚠️ Le mot de passe admin est en clair (`openstack-lab-admin`). C'est un lab. Ne pas pusher ce fichier sur un repo public.

### 8.3 `/opt/openstack-lab/ansible/site.yml`

Playbook maître. Exécute dans l'ordre :
1. Play `common` sur tous les nœuds OpenStack
2. Play "SSH trust" qui distribue la clé du deployer
3. Play `ceph` sur controller + computes
4. Play `kolla` sur le deployer

### 8.4 Cloud-init configs (référence)

- `scripts/cloud-init/deployer.user-data.yaml` : netplan ens33=192.168.10.5, génère la clé SSH du deployer
- `scripts/cloud-init/controller.user-data.yaml` : netplan 4 interfaces avec routes
- `scripts/cloud-init/compute.user-data.tmpl` : template paramétré, généré en compute01/02/03 par le script PowerShell

Tous référencent **`name: dio`** comme user (pas ansible).

---

## 9. Commandes de référence (cheat sheet)

### 9.1 Re-clonage propre (si on doit recommencer la phase 3)

```powershell
# Détruire les VMs existantes
& "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe" stop "E:\tps_openstack\openstack-lab\deployer\deployer.vmx" hard 2>$null
# (idem pour controller, compute01, 02, 03)

Remove-Item E:\tps_openstack\openstack-lab -Recurse -Force

# Relancer
cd E:\openstack-lab\scripts
.\03-deploy-vms.ps1 `
    -TemplatePath "E:\tps_openstack\ubuntu-template.vmx" `
    -VmsRoot "E:\tps_openstack\openstack-lab"
```

### 9.2 Re-déploiement Ansible (si phase 5 plante au milieu)

Ansible est idempotent — on peut relancer le même playbook :
```bash
ansible-playbook -i inventory/hosts.yml site.yml
```

Ou cibler une étape précise avec les tags :
```bash
ansible-playbook -i inventory/hosts.yml site.yml --tags ceph    # Ceph seul
ansible-playbook -i inventory/hosts.yml site.yml --tags kolla   # OpenStack seul
ansible-playbook -i inventory/hosts.yml site.yml --start-at-task "kolla-ansible deploy"
```

### 9.3 Reset Kolla (sans tout re-cloner)

Sur le deployer :
```bash
source ~/venv/bin/activate
kolla-ansible -i /etc/kolla/multinode destroy --yes-i-really-really-mean-it
# Puis relancer
kolla-ansible -i /etc/kolla/multinode bootstrap-servers
kolla-ansible -i /etc/kolla/multinode prechecks
kolla-ansible -i /etc/kolla/multinode deploy
```

---

## 10. Troubleshooting — playbook des 12 problèmes les plus probables

| # | Symptôme | Cause | Fix |
|---|---|---|---|
| 1 | `Test-Connection` KO sur une VM | cloud-init pas fini | Attendre, ouvrir console et `sudo cloud-init status` |
| 2 | cloud-init `error` sur une VM | netplan invalide | Console → `sudo cat /etc/netplan/01-net.yaml` → corriger → `sudo netplan apply` |
| 3 | SSH refuse la clé | clé publique pas injectée | Vérifier `/home/dio/.ssh/authorized_keys` ; à la pire ressaisir mdp `dio` à la console et coller la clé manuellement |
| 4 | `ansible all -m ping` timeout | Pas de SSH trust deployer → autres | Lancer le play 2 (SSH trust) seul : `ansible-playbook site.yml --tags ssh` |
| 5 | Ceph `cephadm bootstrap` échoue | `/dev/sdb` déjà utilisé | `sudo sgdisk --zap-all /dev/sdb` sur le compute concerné |
| 6 | Ceph `HEALTH_WARN: too few PGs` | Bénin | OK, peut être ignoré pour le lab |
| 7 | Kolla prechecks "VIP not in subnet" | VIP `192.168.10.50` mal configurée ou hors subnet mgmt | Vérifier `kolla_internal_vip_address` dans `group_vars/all.yml` |
| 8 | Kolla deploy bloqué sur `pulling images` | Réseau lent ou Docker hub down | `docker pull quay.io/openstack.kolla/...` manuel + retry |
| 9 | nova-compute "qemu:qemu" instead of "kvm:kvm" | Nested virt pas activée dans VMware | Vérifier `vhv.enable = "TRUE"` dans `compute*.vmx`, hard reboot la VM |
| 10 | Horizon ne répond pas sur `:80` | HAProxy pas démarré | `docker ps -a | grep haproxy` ; `docker logs haproxy_xxxxx` |
| 11 | `openstack server create` BUILD bloqué | Network ML2 pas configuré | `openstack network agent list` → tous UP ? Sinon redéployer Neutron : `kolla-ansible deploy --tags neutron` |
| 12 | Disque plein (templates Docker pèsent) | Disque deployer/controller saturé | `docker system prune -af` ; à terme déplacer `/var/lib/docker` |

---

## 11. Erreurs déjà rencontrées et leurs solutions

L'utilisateur a déjà galéré sur ces points pendant la phase de préparation. À ne pas refaire :

### 11.1 Réseau VMware → "autoconfiguration failed" puis "not connected"

**Cause** : VM était sur VMnet3 (NAT) mais le DHCP n'a pas répondu, puis le câble virtuel s'est déconnecté en changeant les paramètres à chaud.

**Fix** : Power off complet, vérifier que `Connected` ET `Connect at power on` sont cochés dans Settings → Network Adapter, et que c'est bien `Custom: VMnet3 (NAT)`. Pour le template build, Internet est nécessaire : VMnet3 OK ; les clones eux n'ont pas besoin de DHCP, leurs IPs sont statiques.

### 11.2 dpkg interruption pendant `apt upgrade`

**Cause** : Install Ubuntu interrompue.

**Fix** : `sudo dpkg --configure -a` puis `sudo apt update && sudo apt upgrade -y`.

### 11.3 `dpkg-reconfigure cloud-init` sort sans afficher le formulaire

**Cause** : cloud-init 25.x a une priorité debconf élevée par défaut.

**Fix** : Écrire directement le fichier de config :
```bash
echo 'datasource_list: [ NoCloud, None ]' | sudo tee /etc/cloud/cloud.cfg.d/90_dpkg.cfg
sudo cloud-init clean --logs --seed
```

### 11.4 PowerShell `RemoteException` sur `wsl genisoimage`

**Cause** : `genisoimage` écrit ses warnings sur stderr ; combiné avec `$ErrorActionPreference = "Stop"`, PowerShell les voit comme des erreurs.

**Fix** (déjà appliqué dans le script) : encadrer l'appel avec un changement temporaire de `$ErrorActionPreference = 'Continue'` et rediriger stderr vers `$null`. Le script vérifie quand même `$LASTEXITCODE` pour les vraies erreurs.

### 11.5 oscdimg.exe et WSL absents

**Cause** : Aucun outil ISO disponible côté Windows par défaut.

**Fix** : `wsl --install -d Ubuntu` puis `sudo apt install -y genisoimage` dans WSL. (Pas besoin de reboot Windows sur les versions récentes.)

### 11.6 VMnet1/2/3/4 au lieu de VMnet10/20/30/40

**Cause** : L'utilisateur a supprimé les VMnets par défaut puis créé les nouveaux en partant de 1.

**Fix** : Le script PowerShell a été adapté (pas besoin de toucher). Les configs Ansible ne sont pas concernées (elles ne référencent que des IPs).

---

## 12. Choses à NE PAS faire

- ❌ Ne pas allumer la VM `ubuntu-template` : si elle boot, elle se génère un nouveau machine-id et le snapshot devient inconsistant
- ❌ Ne pas committer `group_vars/all.yml` en l'état sur un repo public (mots de passe en clair)
- ❌ Ne pas modifier les VMnets pendant que des VMs y sont attachées (déconnexions à chaud problématiques)
- ❌ Ne pas désactiver la nested virt (`vhv.enable = "TRUE"`) sur les computes : KVM en a besoin
- ❌ Ne pas mettre Ceph sur HDD : timeouts garantis. SSD obligatoire.

---

## 13. Versions et liens de référence

- VMware Workstation Pro 17 — https://www.vmware.com/go/getworkstation-win
- Ubuntu Server 22.04.5 LTS — https://releases.ubuntu.com/22.04/
- OpenStack 2024.1 (Caracal) — https://releases.openstack.org/caracal/
- Kolla-Ansible — https://docs.openstack.org/kolla-ansible/2024.1/
- Ceph Reef — https://docs.ceph.com/en/reef/
- cephadm — https://docs.ceph.com/en/reef/cephadm/

---

## 14. Si Claude Code doit me redémarrer le projet

Si pour une raison X tout doit recommencer (disque cassé, machine changée), voici l'ordre :

1. Installer VMware Workstation Pro 17 + activer la licence gratuite perso
2. Créer 4 VMnets via Virtual Network Editor (admin) — VMnet1=mgmt host-only, VMnet2=tenant host-only, VMnet3=NAT+DHCP, VMnet4=storage host-only sans host adapter
3. Télécharger Ubuntu 22.04 ISO sur `E:\VMs\iso\`
4. Créer la VM template avec NIC sur **VMnet3** (pour avoir Internet pendant l'install) — voir `02-build-template.md`
5. Préparer + généraliser + snapshot `template-clean` — voir GUIDE.md §3
6. Sur Windows : `ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\openstack-lab -N '""'`
7. Installer WSL Ubuntu + genisoimage : `wsl --install -d Ubuntu` puis dans WSL `sudo apt install -y genisoimage`
8. Lancer le script de déploiement :
   ```powershell
   cd E:\openstack-lab\scripts
   .\03-deploy-vms.ps1 -TemplatePath "<chemin-template>.vmx" -VmsRoot "E:\tps_openstack\openstack-lab"
   ```
9. Suivre les phases 4 → 5 → 6 ci-dessus

---

## 15. Style de communication souhaité par l'utilisateur

L'utilisateur kilian a apprécié pendant cette session :
- Réponses techniques directes, pas de blabla
- Mockups ASCII des écrans (Virtual Network Editor, install Ubuntu, console Linux) — il n'avait pas accès à de vraies captures
- Tableaux de troubleshooting
- Justifier les choix (ex: pourquoi VMware vs Proxmox, pourquoi `.2` comme gateway NAT)
- Donner les commandes prêtes à copier-coller, avec la sortie attendue
- Niveau technique : sait Linux/réseau de base, mais découvre OpenStack et Kolla — ne pas surestimer ni sous-estimer

Il a aussi commis quelques étourderies normales (oublier de cocher "Connect at power on", choisir `dio` au lieu d'`ansible`, créer VMnet1-4 au lieu de 10-40) — il faut s'adapter et ne pas refuser. À chaque erreur, donner le fix puis continuer.

---

**Fin du handoff.** Toutes les infos nécessaires sont là. Continue à partir de la Phase 3 (vérif joignabilité), et bon courage pour les ~2 h de Kolla deploy !
