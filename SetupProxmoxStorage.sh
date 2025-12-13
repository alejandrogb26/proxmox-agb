#!/bin/bash

# Autor: Alejandro Gómez Blanco
# Fecha: 05/06/2025

# Este script automatiza la configuración de almacenamiento en un servidor Proxmox
# con dos discos de 1 TB:
#  - Elimina el volumen lógico 'local-lvm' si existe.
#  - Amplía el volumen pve-root para aprovechar todo el espacio disponible.
#  - Crear un pool ZFS llamado 'datos-zfs' en el segundo disco ('/dev/nvme1n1')
#  - Configura 'storage.conf' para:
#     . Usar 'local' (disco 0) solo para ISOs y plantillas LXC.
#     . Usar 'datos-zfs' (disco 1) para discos de MV, contenedores LXC y backups.

set -e # Detiene el script si hay errores.

echo "=== Eliminando local-lvm si existe ==="
if lvdisplay pve/data &> /dev/null; then
    lvremove -y pve/data
else
    echo "local-lvm (pve/data) no existe o ya fue eliminado."
fi

echo "=== Ampliando pve-root para usar todo el espacio libre ==="
lvextend -l +100%FREE /dev/pve/root

echo "=== Redimensionando el sistema de archivos ==="
resize2fs /dev/pve/root

echo "=== Creando ZFS pool en /dev/nvme1n1 ==="
zpool create -f datos-zfs /dev/nvme1n1

echo "=== Configurando almacenamiento en /etc/pve/storage.cfg ==="
cat <<EOF > /etc/pve/storage.cfg
dir: local
    path /var/lib/vz
    content iso,vztmpl
    maxfiles 0

zfspool: datos-zfs
    pool datos-zfs
    content images,rootdir,backup
    sparse 1
EOF

echo "=== ¡Listo! Configuración completa ==="

