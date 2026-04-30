# RECAP — Lab OpenStack hyperconvergé

Compte-rendu de bout en bout du déploiement, de la décision d'architecture jusqu'à la première instance Cirros qui boot. Inclut les choix techniques, la mise en place phase par phase, et une sélection des problèmes notables rencontrés (pas tous — uniquement ceux qui ont nécessité un vrai diagnostic).

---

## 1. Objectif

Monter un lab OpenStack fonctionnel sur **une seule machine Windows**, presque entièrement automatisé via Ansible :
- 1 deployer (Ansible runner)
- 1 controller (APIs OpenStack + Ceph mon)
- 3 computes hyperconvergés (Nova KVM **+** Ceph OSD colocalisé sur chaque nœud)

Contrainte forte : **32 Go de RAM** sur l'hôte, donc pas de séparation compute / storage — d'où l'hyperconvergence.

---

## 2. Décisions d'architecture

| Choix | Valeur | Raison |
|---|---|---|
| Hyperviseur | **VMware Workstation Pro 17** | Gratuit usage perso depuis nov. 2024, garde Windows en hôte, nested virt OK pour KVM. Proxmox écarté (bare-metal, écraserait Windows). |
| OS guests | Ubuntu Server 22.04 LTS | LTS, support Kolla et Ceph optimaux. |
| OpenStack | **2024.1 "Caracal"** | LTS jusqu'à 2026-04. |
| Orchestration | **Kolla-Ansible 19.0.0** | Containers Docker, plus simple à maintenir qu'OpenStack-Ansible. |
| Stockage distribué | **Ceph Reef (18.x) via cephadm** | `cephadm` > `ceph-ansible` (déprécié). |
| Topologie | **Hyperconvergée** | 32 Go RAM ne permet pas 6 VMs (3 compute + 3 storage). OSDs colocalisés. |
| User Linux | **`dio`** | Choix utilisateur lors de l'install Ubuntu, tous les configs adaptés. |

---

## 3. Plan d'allocation matérielle

| VM | RAM | vCPU | Disque sys | Disque Ceph |
|---|---|---|---|---|
| deployer | 2 Go | 1 | 30 Go (linked) | — |
| controller | 8 Go | 2 | 30 Go (linked) | — |
| compute01 | 6 Go | 2 | 30 Go (linked) | 30 Go (OSD) |
| compute02 | 6 Go | 2 | 30 Go (linked) | 30 Go (OSD) |
| compute03 | 6 Go | 2 | 30 Go (linked) | 30 Go (OSD) |
| **Total** | **28 Go** | **9** | — | — |

Overcommit léger sur CPU = OK pour un lab. RAM strictement dans les 32 Go avec 4 Go restants pour Windows.

---

## 4. Plan réseau

4 VMnets distincts (host-only sauf VMnet3 en NAT pour la sortie Internet) :

| VMnet | Type | Subnet | DHCP | Host adapter | Rôle |
|---|---|---|---|---|---|
| **VMnet1** | Host-only | 192.168.10.0/24 | OFF | ON | Management (API + SSH) |
| **VMnet2** | Host-only | 192.168.20.0/24 | OFF | ON | Tenant (VXLAN entre instances) |
| **VMnet3** | NAT | 192.168.30.0/24 | ON | ON | External (floating IP, sortie Internet) |
| **VMnet4** | Host-only | 192.168.40.0/24 | OFF | OFF | Storage (Ceph public + cluster) |

### Adressage statique (injecté par cloud-init au premier boot)

| VM | mgmt (VMnet1) | tenant (VMnet2) | ext (VMnet3) | storage (VMnet4) |
|---|---|---|---|---|
| deployer | **192.168.10.5** | — | DHCP | — |
| controller | **192.168.10.10** | 192.168.20.10 | DHCP | 192.168.40.10 |
| compute01 | **192.168.10.21** | 192.168.20.21 | DHCP | 192.168.40.21 |
| compute02 | **192.168.10.22** | 192.168.20.22 | — | 192.168.40.22 |
| compute03 | **192.168.10.23** | 192.168.20.23 | — | 192.168.40.23 |

**VIP de management OpenStack** : `192.168.10.50` (portée par keepalived sur le controller).

---

## 5. Mise en place pas-à-pas

### Phase 0 — Pré-vol

- Vérifier VT-x + EPT côté hôte (`Coreinfo64.exe -v`)
- ≥250 Go libres sur SSD (NVMe idéalement) — Ceph sur HDD = timeouts garantis
- Activer la virtualisation matérielle dans le BIOS si nécessaire

### Phase 1 — Installer VMware Workstation Pro 17

Téléchargement Broadcom (compte gratuit). Licence personnelle gratuite depuis novembre 2024.

### Phase 2 — Configurer les 4 réseaux VMnet

`Virtual Network Editor` lancé en administrateur. Création de VMnet1/2/3/4 selon le tableau ci-dessus. Vérification côté Windows :

```powershell
Get-NetAdapter | Where-Object { $_.Name -like "*VMware*" } | Format-Table Name, Status, LinkSpeed
```

VMnet4 n'apparaît pas comme adaptateur sur l'hôte (volontaire — le storage est purement inter-VMs).

### Phase 3 — Construire la VM template

1. Créer la VM `ubuntu-template` (4 Go RAM, 2 vCPU, 30 Go thin, NIC sur VMnet3 pour avoir Internet pendant l'install). **Activer `Virtualize Intel VT-x/EPT`** — sinon KVM ne tournera jamais dans les computes.
2. Installer Ubuntu Server 22.04 LTS, **cocher OpenSSH server**.
3. Préparer la VM :
   - User `dio` avec sudo NOPASSWD (`/etc/sudoers.d/dio`)
   - Paquets : `cloud-init cloud-utils qemu-guest-agent open-vm-tools python3 python3-apt chrony curl git net-tools`
   - **cloud-init forcé en mode NoCloud uniquement** :
     ```bash
     echo 'datasource_list: [ NoCloud, None ]' | sudo tee /etc/cloud/cloud.cfg.d/90_dpkg.cfg
     ```
4. Généraliser : reset machine-id, reset SSH host keys, `cloud-init clean --logs --seed`.
5. Éteindre, prendre le snapshot **`template-clean`** (nom exact requis par le script de clonage).

### Phase 4 — Générer la clé SSH côté Windows

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\openstack-lab -N '""'
```

Cette clé est lue par le script PowerShell et injectée dans tous les cloud-init des 5 VMs.

### Phase 5 — Déploiement automatisé des 5 VMs

WSL Ubuntu + `genisoimage` installés côté Windows pour la génération des ISOs cloud-init NoCloud.

```powershell
cd E:\openstack-lab\scripts
.\03-deploy-vms.ps1 -TemplatePath "E:\tps_openstack\ubuntu-template.vmx" `
                    -VmsRoot      "E:\tps_openstack\openstack-lab"
```

Ce que fait le script en une commande :
- 5 **linked clones** depuis le snapshot `template-clean` (gain de place énorme vs full clone)
- Ajout d'un disque secondaire 30 Go (Ceph OSD) sur compute01/02/03
- Génération d'ISOs cloud-init NoCloud (`user-data` + `meta-data`) propres à chaque VM
- Attachement des ISOs et démarrage des 5 VMs

cloud-init configure ensuite chaque VM en parallèle (~2 min) : hostname, netplan, user `dio`, autorisation de la clé SSH publique.

### Phase 6 — Vérification de la joignabilité

```powershell
foreach ($ip in 5,10,21,22,23) {
    Test-Connection -Quiet -Count 1 "192.168.10.$ip"
}
```

Premier SSH vers le deployer pour valider l'injection de la clé :

```powershell
ssh -i $env:USERPROFILE\.ssh\openstack-lab dio@192.168.10.5
```

### Phase 7 — Préparation du deployer

Sur le deployer :

```bash
sudo apt install -y python3-pip python3-venv git
python3 -m venv ~/venv && source ~/venv/bin/activate
pip install ansible-core==2.16.* docker
ansible-galaxy collection install community.general ansible.posix community.docker
```

Distribution de la clé SSH du deployer aux 4 autres nœuds (premier play du `site.yml`).

### Phase 8 — Déploiement OpenStack via Ansible

Lancement du playbook maître depuis le deployer :

```bash
cd /opt/openstack-lab/ansible
ansible-playbook -i inventory/hosts.yml site.yml | tee ~/deploy-$(date +%Y%m%d-%H%M%S).log
```

Quatre plays s'enchaînent :

| Play | Cibles | Tâches | Durée |
|---|---|---|---|
| 1. Préparation OS | tous | apt update, swap off, sysctl, /etc/hosts, chrony | ~10 min |
| 2. SSH trust | deployer→all | distribution de la clé du deployer | ~1 min |
| 3. Cluster Ceph | controller + computes | `cephadm bootstrap`, OSDs, pools (`images`, `volumes`, `vms`, `backups`) | ~15 min |
| 4. OpenStack via Kolla | deployer | `bootstrap-servers`, `prechecks`, `deploy` (+pull Docker ~5 Go) | ~60–80 min |

### Phase 9 — Validation post-deploy

```bash
source /etc/kolla/admin-openrc.sh
openstack service list
openstack hypervisor list
openstack network agent list
sudo ceph -s   # depuis controller : HEALTH_OK ou WARN bénin
```

Login Horizon depuis Windows : `http://192.168.10.50` (admin / `openstack-lab-admin`).

Premier test : upload Cirros + création de l'instance `test-vm` → **ACTIVE** sur compute03 (IP 10.0.0.21).

---

## 6. Persistance des fixes (avant extinction du lab)

Pour que le lab redémarre proprement après extinction sans intervention :

- **Routes par défaut** figées dans `/etc/netplan/01-net.yaml` sur les 4 nœuds OpenStack (gateway = `192.168.10.5`, le deployer faisant office de NAT).
- **NAT iptables** persisté dans `/etc/rc.local` sur le deployer (MASQUERADE de 192.168.10.0/24 vers ens34).
- **Fix OVS** persisté dans `/etc/rc.local` sur compute02/03 avec un `sleep 30` initial pour attendre que `openvswitch_vswitchd` ait démarré (cf. §7.1).
- **Fix Horizon Python 3.12** dans `/etc/kolla/horizon/horizon.conf`.
- Service `rc-local.service` activé via systemd partout.

Procédure de redémarrage : démarrer le **deployer en premier** (il porte le NAT), attendre 1-2 min, démarrer les autres, vérifier avec `openstack server list`.

---

## 7. Problèmes notables rencontrés (sélection)

> Cette section ne liste que les problèmes ayant nécessité un vrai diagnostic. Les soucis triviaux (cloud-init pas fini, oubli d'un cocher de case dans Workstation, etc.) ne sont pas listés.

### 7.1 Bug OVS sur compute02 / compute03 — `ens224` capturé dans `br-ex`

**Symptôme** : après `kolla-ansible deploy`, perte de connectivité réseau sur compute02 et compute03. Le bridge OVS `br-ex` avait avalé l'interface storage.

**Cause** : compute02 et compute03 n'avaient que **3 NICs** au lieu de 4 (vs compute01 qui en avait 4). Du coup, l'interface `ens224` correspondait au réseau **storage** (VMnet4) au lieu de l'**external** (VMnet3) comme attendu par la variable Kolla `neutron_external_interface=ens224` dans `globals.yml`. Kolla a donc placé l'interface storage dans le bridge external, coupant Ceph sur ces deux nœuds.

**Fix appliqué à chaud** :
```bash
docker exec openvswitch_vswitchd ovs-vsctl del-port br-ex ens224
```

**Persistance** : ajout du même `del-port` dans `/etc/rc.local` avec un `sleep 30` initial (sinon la commande s'exécute avant que `openvswitch_vswitchd` ne soit prêt).

**Leçon** : la convention de nommage `ensXXX` dépend du nombre de NICs présentes. Toujours valider via `ip -br link` après cloud-init avant de lancer Kolla.

### 7.2 Échecs de `kolla-ansible prechecks` (NICs / MTU)

Plusieurs cycles `bootstrap → prechecks → deploy` ont échoué avec `failed=1` sur des assertions de NICs et de MTU. La résolution a passé par une reconstruction de l'inventaire via un script auxiliaire (`rebuild_inv.py`) pour réaligner les noms d'interfaces et les MTU annoncés à Neutron.

### 7.3 Horizon cassé sur Python 3.12

**Symptôme** : Horizon répondait HTTP 500 après déploiement.

**Cause** : incompatibilités dans Horizon 2024.1 sur Python 3.12 (déprécations Django).

**Fix** : ajustements manuels dans `/etc/kolla/horizon/horizon.conf` pour rendre l'interface fonctionnelle, persistés dans le repo.

### 7.4 Pas de route par défaut sur les VMs après reboot

**Symptôme** : après le premier `apt update` qui timeoutait, on s'est rendu compte que les VMs n'avaient pas de route par défaut.

**Cause** : les netplan initiaux générés par cloud-init ne déclaraient pas de gateway sur le réseau management.

**Fix** : ajout manuel d'une route via `192.168.10.5` (le deployer faisant office de NAT) dans `/etc/netplan/01-net.yaml` sur les 4 nœuds, puis `netplan apply`. Persisté dans le netplan.

### 7.5 `dpkg-reconfigure cloud-init` n'affiche pas le formulaire

**Symptôme** : impossible de forcer le datasource cloud-init en mode NoCloud via `dpkg-reconfigure`.

**Cause** : cloud-init 25.x a une priorité debconf élevée par défaut.

**Fix** : court-circuit en écrivant directement le fichier de config :
```bash
echo 'datasource_list: [ NoCloud, None ]' | sudo tee /etc/cloud/cloud.cfg.d/90_dpkg.cfg
sudo cloud-init clean --logs --seed
```

### 7.6 PowerShell `RemoteException` sur `wsl genisoimage`

**Symptôme** : le script PowerShell de clonage plantait en plein milieu sur les appels `wsl genisoimage`.

**Cause** : `genisoimage` écrit ses warnings sur stderr ; combiné avec `$ErrorActionPreference = "Stop"`, PowerShell les voit comme des erreurs fatales.

**Fix** (déjà appliqué dans `03-deploy-vms.ps1`) : encadrer l'appel avec un changement temporaire de `$ErrorActionPreference = 'Continue'` et rediriger stderr. Le script vérifie quand même `$LASTEXITCODE` pour les vraies erreurs.

---

## 8. État final

- **5 VMs** opérationnelles sous VMware Workstation
- **Ceph Reef** : 3 OSDs UP, `HEALTH_OK`, pools `images / volumes / vms / backups` créés
- **OpenStack 2024.1 Caracal** : Keystone, Glance (backend Ceph RBD), Nova (KVM nested), Neutron, Cinder, Placement, Horizon — tous UP
- **3 hypervisors** UP côté Nova (compute01/02/03)
- **Première instance Cirros** (`test-vm`) ACTIVE sur compute03 avec IP `10.0.0.21`
- Tous les fixes runtime persistés (netplan, NAT, OVS, Horizon)
- Le lab peut être éteint / redémarré sans intervention manuelle

---

## 9. Ce qui n'est PAS dans ce repo

Les fichiers de configuration runtime (générés sur les VMs par Kolla / cephadm) ne sont volontairement pas commit ici :
- `/etc/kolla/globals.yml` (paramètres Kolla)
- `/etc/kolla/passwords.yml` (**secrets en clair**)
- `/etc/kolla/horizon/horizon.conf` (fix Python 3.12 appliqué)
- `/etc/netplan/01-net.yaml` (sur les 4 nœuds)
- `/etc/rc.local` (NAT iptables sur deployer + fix OVS sur compute02/03)

Pour les rapatrier proprement : SSH sur deployer, `scp` depuis chaque nœud, et création d'un sous-dossier `cluster-runtime/` (en filtrant `passwords.yml`).
