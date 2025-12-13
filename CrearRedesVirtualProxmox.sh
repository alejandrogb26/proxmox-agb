#!/bin/bash

# Autor: Alejandro Gómez Blanco
# Fecha: 05/06/2025

INTERFACES_FILE="/etc/network/interfaces"
BACKUP_DIR="/etc/network/backups"
LOG_FILE="/var/log/proxmox_network_setup.log"

# Colores para la salida
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Función para registrar actividades
function log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# Función para validar direcciones IP
function validate_ip() {
    local ip=$1
    local stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && \
           ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# Función para validar máscara de red
function validate_mask() {
    local mask=$1
    validate_ip $mask && [[ $mask =~ ^(254|252|248|240|224|192|128|0)\.0\.0\.0$|^255\.(254|252|248|240|224|192|128|0)\.0\.0$|^255\.255\.(254|252|248|240|224|192|128|0)\.0$|^255\.255\.255\.(254|252|248|240|224|192|128|0)$ ]]
    return $?
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

# Función para crear bridge interno con manejo de servicios
function crear_bridge_virtual() {
    log "Iniciando creación de bridge interno..."

    while true; do
        read -p "Nombre del bridge (ej: vmbr1): " BRIDGE
        if [[ -z "$BRIDGE" ]]; then
            echo -e "${RED}Error: El nombre del bridge no puede estar vacío.${NC}"
            continue
        fi
        if grep -q "^auto $BRIDGE$" "$INTERFACES_FILE"; then
            echo -e "${RED}Error: El bridge $BRIDGE ya existe.${NC}"
            return 1
        fi
        break
    done

    while true; do
        read -p "IP del host para esta red (ej: 192.168.100.1): " IP
        if validate_ip "$IP"; then
            break
        else
            echo -e "${RED}Error: Dirección IP no válida.${NC}"
        fi
    done

    while true; do
        read -p "Máscara (ej: 255.255.255.0): " MASK
        if validate_mask "$MASK"; then
            break
        else
            echo -e "${RED}Error: Máscara de red no válida.${NC}"
        fi
    done

    backup_config

    log "Creando bridge interno $BRIDGE en $INTERFACES_FILE..."
    cat <<EOF >> $INTERFACES_FILE

# Bridge interno creado automáticamente $(date)
auto $BRIDGE
iface $BRIDGE inet static
    address $IP
    netmask $MASK
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF

    if [ $? -ne 0 ]; then
        log "${RED}Error al crear el bridge $BRIDGE.${NC}"
        return 1
    fi

    log "${GREEN}Bridge $BRIDGE creado exitosamente.${NC}"

    # Preguntar si se desea aplicar los cambios inmediatamente
    read -p "¿Deseas aplicar los cambios ahora? [s/n]: " APPLY_NOW
    if [[ "$APPLY_NOW" =~ ^[sS]$ ]]; then
        aplicar_cambios_red "$BRIDGE"
    else
        echo -e "${YELLOW}Los cambios se aplicarán en el próximo reinicio del servicio de red o del sistema.${NC}"
        echo -e "${YELLOW}Para aplicar manualmente, ejecuta: systemctl restart networking${NC}"
    fi

    return 0
}

# Función para aplicar cambios de red
function aplicar_cambios_red() {
    local bridge="$1"
    log "Aplicando cambios de configuración de red..."

    # Intentar diferentes métodos según la distribución
    if systemctl is-active --quiet networking; then
        # Para sistemas con systemd (Debian/Ubuntu)
        log "Reiniciando servicio networking..."
        if systemctl restart networking; then
            log "${GREEN}Servicio networking reiniciado con éxito.${NC}"
        else
            log "${YELLOW}No se pudo reiniciar networking, intentando con netplan..."
            aplicar_cambios_netplan
        fi
    elif systemctl is-active --quiet NetworkManager; then
        # Para sistemas con NetworkManager
        log "Recargando configuraciones de NetworkManager..."
        nmcli connection reload
        if nmcli device status | grep -q "$bridge"; then
            nmcli connection up "$bridge"
        fi
    elif which netplan >/dev/null 2>&1; then
        # Para sistemas con netplan (Ubuntu moderno)
        aplicar_cambios_netplan
    else
        # Método tradicional
        log "Reiniciando red con ifdown/ifup..."
        ifdown "$bridge" 2>/dev/null
        ifup "$bridge"
    fi

    # Verificar si el bridge se creó correctamente
    if ip link show "$bridge" >/dev/null 2>&1; then
        log "${GREEN}Bridge $bridge creado y activado correctamente.${NC}"
    else
        log "${YELLOW}El bridge $bridge no está activo. Puede requerir reinicio del sistema.${NC}"
    fi
}

# Función específica para netplan
function aplicar_cambios_netplan() {
    log "Aplicando configuración netplan..."
    if which netplan >/dev/null 2>&1; then
        netplan apply
        if [ $? -eq 0 ]; then
            log "${GREEN}Configuración netplan aplicada con éxito.${NC}"
        else
            log "${RED}Error al aplicar netplan.${NC}"
        fi
    else
        log "${YELLOW}Netplan no está instalado en este sistema.${NC}"
    fi
}


# Función para configurar NAT
function configurar_nat() {
    log "Iniciando configuración de NAT..."

    if ! crear_bridge_virtual; then
        return 1
    fi

    while true; do
        read -p "Interfaz de salida a internet (ej: vmbr0 o eth0): " OUT_IF
        if ip link show "$OUT_IF" >/dev/null 2>&1; then
            break
        else
            echo -e "${RED}Error: La interfaz $OUT_IF no existe.${NC}"
        fi
    done

    log "Habilitando reenvío de paquetes..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
    if ! grep -q "net.ipv4.ip_forward" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null

    log "Configurando NAT con iptables..."
    NETWORK="${IP%.*}.0/24"
    iptables -t nat -A POSTROUTING -s $NETWORK -o $OUT_IF -j MASQUERADE

    while true; do
        read -p "¿Quieres instalar y configurar dnsmasq para DHCP? [s/n]: " DHCP_CHOICE
        case "$DHCP_CHOICE" in
            [sS]*)
                log "Instalando dnsmasq..."
                if ! apt update >/dev/null 2>&1; then
                    log "${RED}Error al actualizar los repositorios.${NC}"
                    break
                fi

                if ! apt install -y dnsmasq >/dev/null 2>&1; then
                    log "${RED}Error al instalar dnsmasq.${NC}"
                    break
                fi

                local dnsmasq_conf="/etc/dnsmasq.d/$BRIDGE.conf"
                cat <<EOF > $dnsmasq_conf
# Configuración DHCP para $BRIDGE - generado $(date)
interface=$BRIDGE
bind-interfaces
dhcp-range=${IP%.*}.100,${IP%.*}.200,12h
dhcp-option=3,$IP
dhcp-option=6,8.8.8.8,8.8.4.4
EOF

                systemctl restart dnsmasq
                if systemctl is-active --quiet dnsmasq; then
                    log "${GREEN}dnsmasq configurado exitosamente en $BRIDGE.${NC}"
                else
                    log "${RED}Error al iniciar dnsmasq.${NC}"
                fi
                break
                ;;
            [nN]*)
                break
                ;;
            *)
                echo "Por favor ingresa 's' o 'n'."
                ;;
        esac
    done

    log "Guardando reglas iptables..."
    if ! command -v iptables-persistent >/dev/null 2>&1; then
        apt install -y iptables-persistent >/dev/null 2>&1
    fi
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6

    log "${GREEN}Configuración NAT completada para $BRIDGE.${NC}"
}

# Función para crear bridge externo
function crear_bridge_externo() {
    log "Iniciando creación de bridge externo..."

    while true; do
        read -p "Nombre del nuevo bridge (ej: vmbr1): " BRIDGE
        if [[ -z "$BRIDGE" ]]; then
            echo -e "${RED}Error: El nombre del bridge no puede estar vacío.${NC}"
            continue
        fi
        if grep -q "^auto $BRIDGE$" "$INTERFACES_FILE"; then
            echo -e "${RED}Error: El bridge $BRIDGE ya existe.${NC}"
            return 1
        fi
        break
    done

    while true; do
        read -p "Nombre de la interfaz física (ej: enp3s0): " PHYS
        if ip link show "$PHYS" >/dev/null 2>&1; then
            break
        else
            echo -e "${RED}Error: La interfaz física $PHYS no existe.${NC}"
        fi
    done

    backup_config

    log "Creando bridge externo $BRIDGE en $INTERFACES_FILE..."
    cat <<EOF >> $INTERFACES_FILE

# Bridge externo creado automáticamente $(date)
auto $BRIDGE
iface $BRIDGE inet dhcp
    bridge_ports $PHYS
    bridge_stp off
    bridge_fd 0
EOF

    if [ $? -eq 0 ]; then
        log "${GREEN}Bridge externo $BRIDGE creado exitosamente.${NC}"
        echo -e "${YELLOW}Reinicia el servicio de red o reinicia el sistema para aplicar los cambios.${NC}"
        return 0
    else
        log "${RED}Error al crear el bridge externo $BRIDGE.${NC}"
        return 1
    fi
}

# Función para mostrar el menú
function menu() {
    clear
    echo -e "${GREEN}--------------------------------${NC}"
    echo -e "${GREEN}   Crear Red Virtual en Proxmox${NC}"
    echo -e "${GREEN}--------------------------------${NC}"
    echo -e "1) Red NAT (salida a Internet, IPs automáticas opcionales)"
    echo -e "2) Red Interna (solo entre VMs)"
    echo -e "3) Red Host-only (VMs y host, sin internet)"
    echo -e "4) Red Bridge externa (como adaptador puente)"
    echo -e "5) Ver estado de bridges existentes"
    echo -e "q) Salir"
    echo -e "${GREEN}--------------------------------${NC}"

    while true; do
        read -p "Selecciona una opción: " CHOICE
        case "$CHOICE" in
            1) configurar_nat; break ;;
            2) crear_bridge_virtual; break ;;
            3) crear_bridge_virtual; break ;;  # Host-only es igual sin NAT ni dnsmasq
            4) crear_bridge_externo; break ;;
            5)
                echo -e "\n${YELLOW}Bridges configurados:${NC}"
                ip -br link show type bridge
                echo -e "\n${YELLOW}Configuración actual:${NC}"
                grep -A5 "auto vmbr" $INTERFACES_FILE || echo "No se encontraron bridges configurados."
                read -p "Presiona Enter para continuar..."
                menu
                break
                ;;
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

# Ejecutar menú principal
while true; do
    menu
    read -p "¿Deseas realizar otra operación? [s/n]: " CONTINUE
    [[ "$CONTINUE" =~ ^[nN]$ ]] && break
done

log "Script completado."
exit 0
