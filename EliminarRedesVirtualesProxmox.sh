#!/bin/bash

# Autor: Alejandro Gómez Blanco
# Fecha: 05/06/2025

# Script para eliminar configuraciones de red en Proxmox
# Permite eliminar bridges, configuraciones de NAT y DHCP asociadas

INTERFACES_FILE="/etc/network/interfaces"
DNSMASQ_DIR="/etc/dnsmasq.d"
BACKUP_DIR="/etc/network/backups"
LOG_FILE="/var/log/proxmox_network_cleanup.log"

# Colores para la salida
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Función para registrar actividades
function log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# Función para hacer backup de configuraciones
function backup_config() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
    fi

    local timestamp=$(date +%Y%m%d%H%M%S)
    cp "$INTERFACES_FILE" "${BACKUP_DIR}/interfaces.${timestamp}.bak"
    log "Backup creado: ${BACKUP_DIR}/interfaces.${timestamp}.bak"
}

# Función para listar bridges configurados
function listar_bridges() {
    echo -e "\n${YELLOW}Bridges configurados:${NC}"

    # Bridges definidos en interfaces
    local defined_bridges=$(grep -A1 "^auto vmbr" $INTERFACES_FILE | grep -v "^--" | awk '/auto/ {print $2}')

    # Bridges activos en el sistema
    local active_bridges=$(ip -br link show type bridge | awk '{print $1}')

    if [ -z "$defined_bridges" ] && [ -z "$active_bridges" ]; then
        echo -e "${RED}No se encontraron bridges configurados.${NC}"
        return 1
    fi

    echo -e "\n${GREEN}Definidos en $INTERFACES_FILE:${NC}"
    for bridge in $defined_bridges; do
        if ip link show "$bridge" >/dev/null 2>&1; then
            echo -e "  $bridge ${GREEN}(activo)${NC}"
        else
            echo -e "  $bridge ${RED}(inactivo)${NC}"
        fi
    done

    echo -e "\n${GREEN}Estado actual:${NC}"
    ip -br link show type bridge

    return 0
}

# Función para eliminar bridge
function eliminar_bridge() {
    listar_bridges || return 1

    while true; do
        read -p "Ingresa el nombre del bridge a eliminar (ej: vmbr1) o 'q' para salir: " BRIDGE

        [[ "$BRIDGE" == "q" ]] && return 0

        if ! grep -q "^auto $BRIDGE$" "$INTERFACES_FILE"; then
            echo -e "${RED}Error: El bridge $BRIDGE no existe en $INTERFACES_FILE.${NC}"
            continue
        fi

        break
    done

    # Obtener información de la configuración
    local bridge_config=$(sed -n "/^auto $BRIDGE$/,/^auto/p" "$INTERFACES_FILE" | sed '/^auto/d')
    local bridge_ip=$(echo "$bridge_config" | awk '/address/ {print $2}')

    backup_config

    # Eliminar configuración del bridge
    log "Eliminando configuración de $BRIDGE de $INTERFACES_FILE..."
    sed -i "/^auto $BRIDGE$/,/^auto/d" "$INTERFACES_FILE"
    sed -i "/^# Bridge.*$BRIDGE/,/^$/d" "$INTERFACES_FILE"

    # Eliminar bridge si existe
    if ip link show "$BRIDGE" >/dev/null 2>&1; then
        log "Desactivando bridge $BRIDGE..."
        ip link set "$BRIDGE" down
        brctl delbr "$BRIDGE"
    fi

    # Eliminar reglas NAT asociadas
    if [[ -n "$bridge_ip" ]]; then
        local network="${bridge_ip%.*}.0/24"
        log "Eliminando reglas NAT para $network..."
        iptables -t nat -S | grep "$network" | sed 's/^-A/iptables -t nat -D/' | while read rule; do
            eval "$rule"
        done

        # Guardar reglas iptables
        if command -v iptables-persistent >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4
            ip6tables-save > /etc/iptables/rules.v6
        fi
    fi

    # Eliminar configuración de dnsmasq si existe
    local dnsmasq_conf="${DNSMASQ_DIR}/${BRIDGE}.conf"
    if [ -f "$dnsmasq_conf" ]; then
        log "Eliminando configuración DHCP para $BRIDGE..."
        rm -f "$dnsmasq_conf"

        if systemctl is-active --quiet dnsmasq; then
            systemctl restart dnsmasq
        fi
    fi

    log "${GREEN}Configuración de $BRIDGE eliminada exitosamente.${NC}"
    echo -e "${YELLOW}Reinicia el servicio de red o reinicia el sistema para completar los cambios.${NC}"

    return 0
}

# Función para limpiar configuraciones obsoletas
function limpiar_obsoletas() {
    log "Buscando configuraciones obsoletas..."

    # Bridges definidos pero no activos
    local defined_bridges=$(grep -A1 "^auto vmbr" $INTERFACES_FILE | grep -v "^--" | awk '/auto/ {print $2}')
    local cleaned=0

    for bridge in $defined_bridges; do
        if ! ip link show "$bridge" >/dev/null 2>&1; then
            log "Encontrada configuración obsoleta para $bridge (no existe en el sistema)"
            read -p "¿Eliminar configuración de $bridge? [s/n]: " choice
            if [[ "$choice" =~ ^[sS]$ ]]; then
                sed -i "/^auto $bridge$/,/^auto/d" "$INTERFACES_FILE"
                local dnsmasq_conf="${DNSMASQ_DIR}/${bridge}.conf"
                [ -f "$dnsmasq_conf" ] && rm -f "$dnsmasq_conf"
                ((cleaned++))
                log "Configuración de $bridge eliminada."
            fi
        fi
    done

    # Archivos dnsmasq sin bridge correspondiente
    for conf in "${DNSMASQ_DIR}"/*.conf; do
        [ -f "$conf" ] || continue
        local bridge=$(basename "$conf" .conf)
        if ! grep -q "^auto $bridge$" "$INTERFACES_FILE"; then
            log "Encontrado archivo dnsmasq obsoleto: $conf"
            read -p "¿Eliminar $conf? [s/n]: " choice
            if [[ "$choice" =~ ^[sS]$ ]]; then
                rm -f "$conf"
                ((cleaned++))
                log "Archivo $conf eliminado."
            fi
        fi
    done

    if [ $cleaned -eq 0 ]; then
        log "No se encontraron configuraciones obsoletas."
    else
        log "${GREEN}Limpieza completada. Se eliminaron $cleaned configuraciones obsoletas.${NC}"
        if systemctl is-active --quiet dnsmasq; then
            systemctl restart dnsmasq
        fi
    fi
}

# Función para mostrar el menú
function menu() {
    clear
    echo -e "${GREEN}--------------------------------${NC}"
    echo -e "${GREEN}  Eliminar Configuraciones de Red${NC}"
    echo -e "${GREEN}--------------------------------${NC}"
    echo -e "1) Eliminar un bridge específico"
    echo -e "2) Listar bridges configurados"
    echo -e "3) Limpiar configuraciones obsoletas"
    echo -e "q) Salir"
    echo -e "${GREEN}--------------------------------${NC}"

    while true; do
        read -p "Selecciona una opción: " CHOICE
        case "$CHOICE" in
            1) eliminar_bridge; break ;;
            2) listar_bridges;
               read -p "Presiona Enter para continuar...";
               menu;
               break ;;
            3) limpiar_obsoletas; break ;;
            [qQ]) exit 0 ;;
            *) echo -e "${RED}Opción inválida. Intenta nuevamente.${NC}" ;;
        esac
    done
}

# Verificar si el usuario es root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Este script debe ejecutarse como root.${NC}" >&2
    exit 1
fi

# Verificar sistema Proxmox/Debian
if [ ! -f /etc/debian_version ]; then
    echo -e "${RED}Este script está diseñado para Debian/Proxmox.${NC}" >&2
    exit 1
fi

# Crear directorio de logs si no existe
[ -d "$(dirname "$LOG_FILE")" ] || mkdir -p "$(dirname "$LOG_FILE")"

# Ejecutar menú principal
while true; do
    menu
    read -p "¿Deseas realizar otra operación? [s/n]: " CONTINUE
    [[ "$CONTINUE" =~ ^[nN]$ ]] && break
done

log "Script completado."
exit 0
