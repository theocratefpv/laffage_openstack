# Configuration des réseaux VMware

> Cette étape est manuelle car Virtual Network Editor n'a pas d'API en ligne de commande fiable. 5 minutes max.

## Lancer Virtual Network Editor en admin

```
C:\Program Files (x86)\VMware\VMware Workstation\vmnetcfg.exe
```

Clic droit → "Exécuter en tant qu'administrateur".

## Créer 4 réseaux

| VMnet | Type | Subnet | DHCP | Connect host |
|---|---|---|---|---|
| **VMnet10** | Host-only | 192.168.10.0/24 | OFF | ON (mgmt) |
| **VMnet20** | Host-only | 192.168.20.0/24 | OFF | ON (tenant) |
| **VMnet30** | NAT | 192.168.30.0/24 | ON | ON (external) |
| **VMnet40** | Host-only | 192.168.40.0/24 | OFF | OFF (storage) |

## Procédure pour chaque VMnet

1. Cliquer **Add Network…** → choisir le numéro (10, 20, 30, 40)
2. Sélectionner le type (Host-only ou NAT)
3. Décocher **Use local DHCP service** sauf VMnet30
4. Définir le subnet et le netmask 255.255.255.0
5. Cocher **Connect a host virtual adapter** sauf VMnet40

Cliquer **Apply** puis **OK**.

## Vérification

Ouvrir PowerShell et taper :

```powershell
Get-NetAdapter | Where-Object { $_.Name -like "*VMware*" }
```

Tu dois voir VMnet10, VMnet20, VMnet30 listés (VMnet40 n'apparaît pas car non connecté à l'host, c'est normal).
