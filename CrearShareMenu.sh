#!/bin/bash

# Autor: Alejandro Gómez Blanco
# Fecha: 06/06/2025

# Verificar si el usuario es root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\e[31mEste script debe ejecutarse como root. Usa 'sudo' o inicia sesión como root.\e[0m"
    exit 1
fi

# Función para validar red (CIDR)
validar_red() {
    local ip_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$"
    [[ $1 =~ $ip_regex ]]
}

# Función para configurar NFS
configurar_nfs() {
    echo -e "\n\e[34m===== Configurando NFS =====\e[0m"

    # Pedir directorio y red
    read -p "Introduce la ruta absoluta del directorio a compartir (ej. /mnt/nfs_share): " SHARE_DIR
    while true; do
        read -p "Introduce la red permitida (CIDR, ej. 192.168.1.0/24): " RED_PERMITIDA
        validar_red "$RED_PERMITIDA" && break
        echo -e "\e[31mFormato de red incorrecto. Usa CIDR (ej. 192.168.1.0/24).\e[0m"
    done

    # Crear directorio si no existe
    mkdir -p "$SHARE_DIR"
    chown nobody:nogroup "$SHARE_DIR"
    chmod 777 "$SHARE_DIR"

    # Instalar NFS si no está instalado
    if ! dpkg -l | grep -q nfs-kernel-server; then
        apt update && apt install -y nfs-kernel-server
    fi

    # Configurar exportación
    if ! grep -q "$SHARE_DIR" /etc/exports; then
        echo "$SHARE_DIR $RED_PERMITIDA(rw,sync,no_subtree_check)" >> /etc/exports
    else
        echo -e "\e[33mAdvertencia: El directorio ya está en /etc/exports.\e[0m"
    fi

    # Aplicar cambios
    exportfs -a
    systemctl restart nfs-kernel-server

    # Mostrar resumen
    echo -e "\n\e[32m¡NFS configurado con éxito!\e[0m"
    echo -e "Directorio compartido: \e[1m$SHARE_DIR\e[0m"
    echo -e "Red permitida: \e[1m$RED_PERMITIDA\e[0m"
    echo -e "Para montar en cliente:"
    echo -e "  \e[1msudo mount -t nfs $(hostname -I | awk '{print $1}'):$SHARE_DIR /mnt/nfs_cliente\e[0m"
}

# Función para configurar Samba
configurar_samba() {
    echo -e "\n\e[34m===== Configurando Samba =====\e[0m"

    # Pedir directorio
    read -p "Introduce la ruta absoluta del directorio a compartir (ej. /mnt/samba_share): " SHARE_DIR
    read -p "Nombre público del share (ej. mis_datos): " NOMBRE_SHARE

    # Crear directorio si no existe
    mkdir -p "$SHARE_DIR"
    chmod -R 777 "$SHARE_DIR"

    # Instalar Samba si no está instalado
    if ! dpkg -l | grep -q samba; then
        apt update && apt install -y samba
    fi

    # Configurar smb.conf
    if ! grep -q "\[$NOMBRE_SHARE\]" /etc/samba/smb.conf; then
        echo -e "\n[$NOMBRE_SHARE]" >> /etc/samba/smb.conf
        echo "   path = $SHARE_DIR" >> /etc/samba/smb.conf
        echo "   browsable = yes" >> /etc/samba/smb.conf
        echo "   writable = yes" >> /etc/samba/smb.conf
        echo "   guest ok = yes" >> /etc/samba/smb.conf
        echo "   read only = no" >> /etc/samba/smb.conf
    else
        echo -e "\e[33mAdvertencia: El share '$NOMBRE_SHARE' ya existe en smb.conf.\e[0m"
    fi

    # Reiniciar Samba
    systemctl restart smbd nmbd

    # Mostrar resumen
    echo -e "\n\e[32m¡Samba configurado con éxito!\e[0m"
    echo -e "Directorio compartido: \e[1m$SHARE_DIR\e[0m"
    echo -e "Nombre del share: \e[1m$NOMBRE_SHARE\e[0m"
    echo -e "Acceso desde clientes:"
    echo -e "  Linux: \e[1msmb://$(hostname -I | awk '{print $1}')/$NOMBRE_SHARE\e[0m"
    echo -e "  Windows: \e[1m\\\\$(hostname -I | awk '{print $1}')\\$NOMBRE_SHARE\e[0m"
}

# Menú principal
while true; do
    clear
    echo -e "\e[36m=== Menú de Compartición de Archivos ===\e[0m"
    echo "1. Configurar NFS (para Linux)"
    echo "2. Configurar Samba (para Windows/Linux)"
    echo "3. Salir"
    read -p "Elige una opción (1-3): " opcion

    case $opcion in
        1) configurar_nfs ;;
        2) configurar_samba ;;
        3) echo -e "\e[35mSaliendo...\e[0m"; exit 0 ;;
        *) echo -e "\e[31mOpción no válida. Inténtalo de nuevo.\e[0m"; sleep 2 ;;
    esac

    read -p "Presiona Enter para continuar..."
done
