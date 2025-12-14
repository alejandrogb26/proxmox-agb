#!/bin/bash

# Autor: Alejandro Gómez Blanco
# Fecha: 01/11/2024

# Variables
DATE=$(date '+%Y-%m-%d_%H-%M-%S')
URL="https://www.ipdeny.com/ipblocks/data/countries/es.zone"
LOCAL_ESZONE="/root/gestIptables/es.zone"
TMP_FILE="/tmp/es.zone"
LOG_PATH="/var/log/run_ipset"
LOG_FILE="${LOG_PATH}/ipset_${DATE}.log"
IPSET_NAME="spain"

# Descargar archivo 'es.zone' temporalmente
curl -s -o "$TMP_FILE" "$URL" >> "$LOG_FILE" 2>&1

# Comparar con el archivo local
if cmp -s "$TMP_FILE" "$LOCAL_ESZONE" >> "$LOG_FILE" 2>&1; then
    echo "No hay actualizaciones" >> "$LOG_FILE"

    # Crear el conjunto 'spain' con ipset
    ipset create "$IPSET_NAME" hash:net >> "$LOG_FILE" 2>&1

    # Restaurar la configuración de ipset 'ipset.conf'
    ipset restore < /etc/ipset.conf >> "$LOG_FILE" 2>&1

else
    # Reemplazar el archivo local con el actualizado
    mv "$TMP_FILE" "$LOCAL_ESZONE" >> "$LOG_FILE" 2>&1

    # Verificar si el conjunto ya existe
    if ipset list -n | grep -q "^${IPSET_NAME}$"; then
        # Limpiar el conjunto si ya existe
        ipset flush "$IPSET_NAME" >> "$LOG_FILE" 2>&1
    else
        # Crear el conjunto si no existe
        ipset create "$IPSET_NAME" hash:net >> "$LOG_FILE" 2>&1
    fi

    # Añadir las IPs al conjunto
    while read -r ip; do
        ipset add "$IPSET_NAME" "$ip" >> "$LOG_FILE" 2>&1
    done < "$LOCAL_ESZONE"

    # Guardar configuración de ipset
    ipset save > /etc/ipset.conf

    # Eliminar la primera línea del archivo 'ipset.conf'. Evita errores.
    sed -i '1d' /etc/ipset.conf

    echo "IPs actualizadas y aplicadas al conjunto ipset" >> "$LOG_FILE"
fi

# Limpiar el archivo temporal
rm -f "$TMP_FILE" >> "$LOG_FILE" 2>&1
