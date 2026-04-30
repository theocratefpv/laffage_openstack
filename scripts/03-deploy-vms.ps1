<#
.SYNOPSIS
    Déploie les 5 VMs du lab OpenStack à partir d'une VM template.

.DESCRIPTION
    Pour chaque VM (deployer, controller, compute01..03) :
      1. Clone la VM template (linked clone)
      2. Configure les NICs (VMnets) selon le rôle
      3. Ajoute un disque 30 Go aux computes (pour Ceph OSD)
      4. Génère un ISO cloud-init NoCloud (user-data + meta-data)
      5. Attache l'ISO et démarre la VM
      6. Au premier boot, cloud-init applique la conf réseau et la clé SSH

.PARAMETER TemplatePath
    Chemin complet vers le .vmx de la VM template (état: snapshot 'template-clean').

.PARAMETER VmsRoot
    Dossier racine où créer les clones. Default: C:\VMs\openstack-lab

.PARAMETER PublicKey
    Chemin de la clé publique SSH à injecter (default: $env:USERPROFILE\.ssh\openstack-lab.pub)

.EXAMPLE
    .\03-deploy-vms.ps1 -TemplatePath "E:\VMs\ubuntu-template\ubuntu-template.vmx"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TemplatePath,

    [string]$VmsRoot = "E:\VMs\openstack-lab",

    [string]$PublicKey = "$env:USERPROFILE\.ssh\openstack-lab.pub",

    [string]$VmrunPath = "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",

    [string]$VdiskManager = "C:\Program Files (x86)\VMware\VMware Workstation\vmware-vdiskmanager.exe"
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# Pré-requis
# ─────────────────────────────────────────────────────────────────────────────

if (-not (Test-Path $TemplatePath)) { throw "Template introuvable: $TemplatePath" }
if (-not (Test-Path $VmrunPath))    { throw "vmrun.exe introuvable: $VmrunPath" }
if (-not (Test-Path $PublicKey))    { throw "Clé publique introuvable: $PublicKey. Génère-la avec ssh-keygen." }

# Vérifier qu'on a oscdimg (pour créer l'ISO cloud-init) ou genisoimage via WSL
$mkisofs = $null
if (Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue) {
    $mkisofs = "oscdimg"
} elseif (Get-Command "wsl" -ErrorAction SilentlyContinue) {
    $mkisofs = "wsl-genisoimage"
} else {
    throw "Aucun outil pour créer l'ISO cloud-init trouvé. Installe Windows ADK (oscdimg) ou WSL avec genisoimage."
}
Write-Host "[OK] Outil ISO: $mkisofs" -ForegroundColor Green

# Charger la clé publique
$pubKeyContent = (Get-Content $PublicKey -Raw).Trim()

# Charger la clé publique deployer si elle existe (sera créée au 1er boot du deployer,
# donc pour les autres VMs on injectera une clé jetable + on la remplacera par Ansible)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cloudInitDir = Join-Path $scriptDir "cloud-init"

# ─────────────────────────────────────────────────────────────────────────────
# Inventaire des VMs
# ─────────────────────────────────────────────────────────────────────────────

$vms = @(
    # Mapping VMnets utilisateur :
    #   VMnet1 = mgmt 192.168.10.0/24 (host-only, pas de DHCP)
    #   VMnet2 = tenant 192.168.20.0/24 (host-only, pas de DHCP)
    #   VMnet3 = external 192.168.30.0/24 (NAT + DHCP)
    #   VMnet4 = storage 192.168.40.0/24 (host-only, pas connecté à l'host)
    @{ Name = "deployer";   Memory = 2048; CPUs = 1; Nics = @("VMnet1","VMnet3");                                         ExtraDisk = $false; CloudInit = "deployer.user-data.yaml" }
    @{ Name = "controller"; Memory = 8192; CPUs = 2; Nics = @("VMnet1","VMnet2","VMnet3","VMnet4");                       ExtraDisk = $false; CloudInit = "controller.user-data.yaml" }
    @{ Name = "compute01";  Memory = 6144; CPUs = 2; Nics = @("VMnet1","VMnet2","VMnet3","VMnet4");                       ExtraDisk = $true;  CloudInit = "compute01.user-data.yaml" }
    @{ Name = "compute02";  Memory = 6144; CPUs = 2; Nics = @("VMnet1","VMnet2","VMnet4");                                 ExtraDisk = $true;  CloudInit = "compute02.user-data.yaml" }
    @{ Name = "compute03";  Memory = 6144; CPUs = 2; Nics = @("VMnet1","VMnet2","VMnet4");                                 ExtraDisk = $true;  CloudInit = "compute03.user-data.yaml" }
)

# Générer les user-data des computes à partir du template
$computeTemplate = Get-Content (Join-Path $cloudInitDir "compute.user-data.tmpl") -Raw
1..3 | ForEach-Object {
    $idx = "{0:D2}" -f $_
    $hasExt = if ($_ -eq 1) { "true" } else { "false" }
    $mgmtLast = 20 + $_
    $content = $computeTemplate `
        -replace "{{INDEX}}", $idx `
        -replace "{{MGMT_LAST}}", $mgmtLast `
        -replace "{{HAS_EXT}}", $hasExt
    $outFile = Join-Path $cloudInitDir "compute$idx.user-data.yaml"
    [System.IO.File]::WriteAllText($outFile, $content, (New-Object System.Text.UTF8Encoding $false))
}

# Injecter la clé publique dans tous les user-data
Get-ChildItem $cloudInitDir -Filter "*.user-data.yaml" | ForEach-Object {
    $content = (Get-Content $_.FullName -Raw) `
        -replace 'ssh-ed25519 AAAA__REPLACE_WITH_YOUR_PUBLIC_KEY__ openstack-lab', $pubKeyContent
    [System.IO.File]::WriteAllText($_.FullName, $content, (New-Object System.Text.UTF8Encoding $false))
}

New-Item -ItemType Directory -Path $VmsRoot -Force | Out-Null

# ─────────────────────────────────────────────────────────────────────────────
# Fonctions utilitaires
# ─────────────────────────────────────────────────────────────────────────────

function New-CloudInitIso {
    param([string]$VmName, [string]$UserDataFile, [string]$OutputIso)

    $tempDir = Join-Path $env:TEMP "ci-$VmName"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    # Copier user-data en forçant UTF-8 sans BOM (cloud-init refuse le BOM devant #cloud-config)
    $ud = [System.IO.File]::ReadAllText($UserDataFile)
    [System.IO.File]::WriteAllText((Join-Path $tempDir "user-data"), $ud, (New-Object System.Text.UTF8Encoding $false))

    @"
instance-id: $VmName-001
local-hostname: $VmName
"@ | Set-Content -Path (Join-Path $tempDir "meta-data") -Encoding ASCII

    if ($script:mkisofs -eq "oscdimg") {
        & oscdimg.exe -j2 -lcidata $tempDir $OutputIso | Out-Null
    } else {
        $wslTmp = (wsl wslpath ($tempDir -replace '\\', '/')).Trim()
        $wslOut = (wsl wslpath ($OutputIso -replace '\\', '/')).Trim()
        # genisoimage écrit ses warnings sur stderr ; on les ignore
        # mais on capture le code de sortie pour détecter une vraie erreur
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & wsl genisoimage -quiet -output $wslOut -V cidata -r -J $wslTmp 2>$null | Out-Null
        $exit = $LASTEXITCODE
        $ErrorActionPreference = $oldEAP
        if ($exit -ne 0) {
            throw "genisoimage a échoué (exit $exit) pour $VmName"
        }
    }

    Remove-Item $tempDir -Recurse -Force
}

function Set-VmxConfig {
    param([string]$VmxPath, [hashtable]$Settings)

    $lines = Get-Content $VmxPath
    $kept = @()
    foreach ($line in $lines) {
        $skip = $false
        foreach ($key in $Settings.Keys) {
            if ($line -match "^\s*$([regex]::Escape($key))\s*=") { $skip = $true; break }
        }
        if (-not $skip) { $kept += $line }
    }
    foreach ($key in $Settings.Keys) {
        $kept += "$key = `"$($Settings[$key])`""
    }
    Set-Content -Path $VmxPath -Value $kept -Encoding ASCII
}

# ─────────────────────────────────────────────────────────────────────────────
# Boucle principale
# ─────────────────────────────────────────────────────────────────────────────

foreach ($vm in $vms) {
    Write-Host "`n=== $($vm.Name) ===" -ForegroundColor Cyan

    $vmDir  = Join-Path $VmsRoot $vm.Name
    $vmxOut = Join-Path $vmDir "$($vm.Name).vmx"

    # 1. Clone (linked)
    if (Test-Path $vmDir) {
        Write-Host "  VM existe déjà, skip clonage" -ForegroundColor Yellow
    } else {
        Write-Host "  Clonage linked depuis 'template-clean'..." -ForegroundColor White
        & $VmrunPath -T ws clone $TemplatePath $vmxOut linked -snapshot="template-clean" -cloneName=$vm.Name | Out-Null
    }

    # 2. Configurer mémoire / CPU / NICs / nested virt
    $vmxSettings = @{
        "memsize"       = $vm.Memory
        "numvcpus"      = $vm.CPUs
        "displayName"   = $vm.Name
        "vhv.enable"    = "FALSE"    # nested virt désactivée (Hyper-V actif sur l'hôte)
        "vpmc.enable"   = "FALSE"
    }

    # NICs
    $nicIdx = 0
    foreach ($net in $vm.Nics) {
        $vmxSettings["ethernet$nicIdx.present"]            = "TRUE"
        $vmxSettings["ethernet$nicIdx.connectionType"]     = "custom"
        $vmxSettings["ethernet$nicIdx.virtualDev"]         = "vmxnet3"
        $vmxSettings["ethernet$nicIdx.vnet"]               = $net
        $vmxSettings["ethernet$nicIdx.addressType"]        = "generated"
        $nicIdx++
    }

    Set-VmxConfig -VmxPath $vmxOut -Settings $vmxSettings

    # 3. Ajouter le 2e disque (computes uniquement, pour Ceph)
    if ($vm.ExtraDisk) {
        $extraVmdk = Join-Path $vmDir "$($vm.Name)-ceph.vmdk"
        if (-not (Test-Path $extraVmdk)) {
            Write-Host "  Création disque Ceph (30 Go thin)..." -ForegroundColor White
            & $VdiskManager -c -s 30GB -a lsilogic -t 0 $extraVmdk | Out-Null
            Add-Content -Path $vmxOut -Value @"
scsi0:1.present = "TRUE"
scsi0:1.fileName = "$($vm.Name)-ceph.vmdk"
scsi0:1.deviceType = "disk"
"@
        }
    }

    # 4. Générer l'ISO cloud-init et l'attacher
    $isoPath = Join-Path $vmDir "cloud-init.iso"
    $userData = Join-Path $cloudInitDir $vm.CloudInit
    Write-Host "  Génération cloud-init.iso..." -ForegroundColor White
    New-CloudInitIso -VmName $vm.Name -UserDataFile $userData -OutputIso $isoPath

    Set-VmxConfig -VmxPath $vmxOut -Settings @{
        "sata0.present"        = "TRUE"
        "sata0:1.present"      = "TRUE"
        "sata0:1.fileName"     = "cloud-init.iso"
        "sata0:1.deviceType"   = "cdrom-image"
        "sata0:1.startConnected" = "TRUE"
    }

    # 5. Démarrer la VM
    Write-Host "  Démarrage..." -ForegroundColor White
    & $VmrunPath -T ws start $vmxOut nogui | Out-Null
}

Write-Host "`n[OK] Les 5 VMs sont en cours de boot. Le premier cloud-init prend ~2 min." -ForegroundColor Green
Write-Host "Vérifie la joignabilité dans 3 min :" -ForegroundColor Cyan
Write-Host "  ssh ansible@192.168.10.5   # deployer" -ForegroundColor Gray
Write-Host "  ssh ansible@192.168.10.10  # controller" -ForegroundColor Gray
Write-Host "  ssh ansible@192.168.10.21  # compute01" -ForegroundColor Gray
Write-Host "  ssh ansible@192.168.10.22  # compute02" -ForegroundColor Gray
Write-Host "  ssh ansible@192.168.10.23  # compute03" -ForegroundColor Gray
