#!/bin/bash

# Autor: Alejandro Gómez Blanco
# Fecha: 29/11/2025

LOGFILE="/var/log/update_cts.log"
EMAIL_TO="alejandrogb@alejandrogb.local"
HOSTNAME=$(hostname)
DATE=$(date +"%Y-%m-%d %H:%M:%S")

# Cabecera del log
echo "=== Inicio actualización en $HOSTNAME ($DATE) ===" | tee "$LOGFILE"

# Obtener lista de CTs
CTS=$(pct list | awk 'NR>1 {print $1}')

for CTID in $CTS; do
    echo "--- Actualizando CT $CTID ---" | tee -a "$LOGFILE"

    pct exec $CTID -- bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt full-upgrade -y --allow-downgrades --allow-remove-essential --allow-change-held-packages
        apt autoremove -y
        apt autoclean -y
    ' >> "$LOGFILE" 2>&1

    if [[ $? -eq 0 ]]; then
        echo "CT $CTID actualizado correctamente." | tee -a "$LOGFILE"
    else
        echo "ERROR actualizando CT $CTID" | tee -a "$LOGFILE"
    fi
done

echo "=== Fin del proceso ===" | tee -a "$LOGFILE"


###############################################
#        ENVÍO DEL LOG POR CORREO             #
###############################################

{
echo "To: $EMAIL_TO"
echo "Subject: [Proxmox] Informe de actualización de CTs en $HOSTNAME"
echo "Content-Type: text/plain"
echo ""
cat "$LOGFILE"
} | sendmail -t

echo "Log enviado por correo a $EMAIL_TO"
