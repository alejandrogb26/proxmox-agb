#!/bin/bash

# =======================
# CONFIGURACIÓN GENERAL
# =======================

PROXMOX_PRINCIPAL="root@192.168.1.253"
NAS_IP="192.168.1.171"

declare -A NODOS_CLUSTER=(
    [pve]="192.168.1.253"
    [pve2]="192.168.1.170"
)

WAIT_SECONDS=60
LOG_FILE="./apagado_cluster.log"

# =======================
# VERIFICAR sshpass
# =======================

if ! command -v sshpass &>/dev/null; then
    echo "❌ El script requiere 'sshpass'. Instálalo con:"
    echo "    sudo apt install sshpass"
    exit 1
fi

# =======================
# SOLICITAR CONTRASEÑA UNA SOLA VEZ
# =======================

read -s -p "🔐 Ingresa la contraseña SSH común para todos los dispositivos: " SSHPASS
echo

# =======================
# FUNCIONES
# =======================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

ejecutar_ssh() {
    local host="$1"
    local cmd="$2"
    log "Ejecutando en $host: $cmd"
    sshpass -p "$SSHPASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$host" "$cmd"
    if [ $? -ne 0 ]; then
        log "⚠️  ERROR ejecutando en $host: $cmd"
    fi
}

apagar_vms() {
    log "🔻 Apagando VMs en $PROXMOX_PRINCIPAL..."
    local vms=$(sshpass -p "$SSHPASS" ssh "$PROXMOX_PRINCIPAL" "qm list | awk '\$3 == \"running\" {print \$1}'")
    if [ -z "$vms" ]; then
        log "✅ No hay VMs en ejecución."
    else
        for vmid in $vms; do
            log "→ Apagando VM ID: $vmid"
            ejecutar_ssh "$PROXMOX_PRINCIPAL" "qm shutdown $vmid"
        done
    fi
}

apagar_cts() {
    log "🔻 Apagando contenedores (CTs) en $PROXMOX_PRINCIPAL..."
    local cts=$(sshpass -p "$SSHPASS" ssh "$PROXMOX_PRINCIPAL" "pct list | awk '\$3 == \"running\" {print \$1}'")
    if [ -z "$cts" ]; then
        log "✅ No hay contenedores en ejecución."
    else
        for ctid in $cts; do
            log "→ Apagando CT ID: $ctid"
            ejecutar_ssh "$PROXMOX_PRINCIPAL" "pct shutdown $ctid"
        done
    fi
}

esperar_apagado() {
    log "⏳ Esperando $WAIT_SECONDS segundos para que VMs y CTs se apaguen..."
    sleep "$WAIT_SECONDS"
}

apagar_nas() {
    log "🔻 Apagando NAS en $NAS_IP..."
    ejecutar_ssh "root@$NAS_IP" "poweroff"
}

apagar_cluster() {
    log "🔻 Apagando nodos del cluster..."
    for nombre in "${!NODOS_CLUSTER[@]}"; do
        ip="${NODOS_CLUSTER[$nombre]}"
        log "→ Apagando nodo $nombre ($ip)..."
        ejecutar_ssh "root@$ip" "poweroff"
    done
}

# =======================
# EJECUCIÓN PRINCIPAL
# =======================

log "==============================="
log "🚦 INICIO DEL APAGADO DEL CLUSTER"
log "==============================="

apagar_vms
apagar_cts
esperar_apagado
apagar_cluster
apagar_nas

log "✅ APAGADO COMPLETO."
