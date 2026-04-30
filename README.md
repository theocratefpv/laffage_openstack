# OpenStack Lab — Déploiement automatisé sur Windows

Lab OpenStack 1 controller + 3 computes hyperconvergés (Ceph) déployé sur VMware Workstation Pro via Kolla-Ansible.

## Quick start

```powershell
# 1. Créer les réseaux VMware (manuel, 5 min) — voir GUIDE.md §1
# 2. Construire la VM template Ubuntu 22.04 (manuel, 30 min) — voir GUIDE.md §2
# 3. Lancer le déploiement automatisé des 5 VMs (zéro clic)
cd scripts
.\03-deploy-vms.ps1 -TemplatePath "E:\VMs\ubuntu-template\ubuntu-template.vmx"

# 4. Sur la VM deployer, lancer Ansible
ssh ansible@192.168.10.5
cd /opt/openstack-lab/ansible
ansible-playbook -i inventory/hosts.yml site.yml
```

## Arborescence

```
openstack-lab/
├── GUIDE.md                  # Pas-à-pas illustré (commence ici)
├── scripts/                  # Bootstrap Windows → 5 VMs prêtes
│   ├── 01-network-setup.md   # Config Virtual Network Editor (manuel)
│   ├── 03-deploy-vms.ps1     # Clonage + cloud-init automatisé
│   └── cloud-init/           # Configs par VM (NoCloud)
├── ansible/                  # Tout ce que fait Ansible après
│   ├── site.yml              # Playbook maître
│   ├── inventory/hosts.yml
│   ├── group_vars/all.yml
│   └── roles/{common,ceph,kolla}/
└── docs/
    └── architecture.svg      # Schéma de l'archi
```

## Pré-requis matériel

- 32 Go RAM (28 Go alloués aux VMs, 4 Go pour Windows)
- 8 vCPU (9 alloués avec overcommit léger, OK pour un lab)
- 250 Go libres sur SSD (impératif, pas HDD)
- CPU avec VT-x + EPT activé dans le BIOS (vérifier avec `coreinfo64.exe -v`)

## Pré-requis logiciel

- Windows 10/11
- VMware Workstation Pro 17+ (gratuit usage perso depuis 2024)
- Ubuntu Server 22.04 LTS ISO
- Git + OpenSSH client (Windows)

## Durée totale

| Phase | Manuel | Automatisé |
|---|---|---|
| Réseaux VMware | 5 min | — |
| VM template | 30 min | — |
| Clonage 5 VMs + cloud-init | — | 15 min |
| Ansible site.yml | — | 90-110 min |
| **Total** | **35 min** | **~2h** |
