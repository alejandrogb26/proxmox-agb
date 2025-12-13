#!/bin/bash

# Autor: Alejandro Gómez Blanco
# Fecha: 29/11/2025

BASE_DIR="/mnt/copSeg/copSegCont"
DATE=$(date +"%Y%m%d-%H%M")
CTS=$(pct list | awk 'NR>1 {print $1}')
LOGFILE="/var/log/backup_all_cts.log"
EMAIL_TO="alejandro@alejandrogb.local"

echo "=== Iniciando backup de CTs ($DATE) ===" | tee "$LOGFILE"

for CTID in $CTS; do
    CT_DIR="${BASE_DIR}/${CTID}"
    mkdir -p "$CT_DIR"

    {
        echo "---------------------------------------------"
        echo "Procesando CT $CTID..."
    } | tee -a "$LOGFILE"

    #####################################################
    # BACKUP MARIADB DEL CONTENEDOR 102 ANTES DE APAGAR #
    #####################################################
    if [[ "$CTID" == "102" ]]; then
        BD_BASE_DIR="${CT_DIR}/backups_BD"
        mkdir -p "$BD_BASE_DIR"

        BD_DATE_DIR="backup_sql_${DATE}"
        TAR_NAME="backup_BD_${DATE}.tar.gz"
        GPG_RECIPIENT="9791CD17605E578D73E49A65C4BAFFF8F97CC1E5"

        echo "CT 102 detectado → realizando backup de MariaDB..." | tee -a "$LOGFILE"

        # 1. Crear dumps dentro del CT
        pct exec 102 -- bash -c "
            mkdir -p /tmp/${BD_DATE_DIR}
            DBLIST=\$(mysql -u root -e 'SHOW DATABASES;' | grep -v Database | grep -v information_schema | grep -v performance_schema | grep -v sys)

            for DB in \$DBLIST; do
                echo 'Exportando' \$DB '...'
                mysqldump -u root \$DB > /tmp/${BD_DATE_DIR}/\${DB}.sql
            done

            # Crear el tar
            tar -czf /tmp/${TAR_NAME} -C /tmp ${BD_DATE_DIR}

            # Borrar los SQL
            rm -rf /tmp/${BD_DATE_DIR}
        " 2>&1 | tee -a "$LOGFILE"

        # 2. Copiar TAR al host
        echo "Copiando TAR al host Proxmox..." | tee -a "$LOGFILE"
        pct pull 102 "/tmp/${TAR_NAME}" "${BD_BASE_DIR}/${TAR_NAME}" 2>&1 | tee -a "$LOGFILE"

        # 3. Borrar TAR dentro del CT
        echo "Borrando TAR sin cifrar dentro del CT..." | tee -a "$LOGFILE"
        pct exec 102 -- rm -f "/tmp/${TAR_NAME}" 2>&1 | tee -a "$LOGFILE"

        # 4. Cifrar TAR en el host
        echo "Cifrando con GPG → ${TAR_NAME}.gpg" | tee -a "$LOGFILE"
        gpg  --recipient "$GPG_RECIPIENT" \
            "${BD_BASE_DIR}/${TAR_NAME}" 2>&1 | tee -a "$LOGFILE"

        # 5. Eliminar TAR sin cifrar
        rm "${BD_BASE_DIR}/${TAR_NAME}"

        echo "Backup MariaDB cifrado guardado en: ${BD_BASE_DIR}/${TAR_NAME}.gpg" | tee -a "$LOGFILE"
    fi

    #################
    # APAGAR EL CT  #
    #################
    echo "Apagando CT $CTID..." | tee -a "$LOGFILE"
    pct shutdown $CTID --forceStop 1 2>&1 | tee -a "$LOGFILE"
    sleep 5

    ###################
    # HACER EL BACKUP #
    ###################
    echo "Realizando vzdump del CT $CTID..." | tee -a "$LOGFILE"

    vzdump $CTID \
        --dumpdir "$CT_DIR" \
        --mode stop \
        --compress zstd \
        --node $(hostname) | tee -a "$LOGFILE"

    ####################
    # ARRANCAR EL CT   #
    ####################
    echo "Arrancando CT $CTID..." | tee -a "$LOGFILE"
    pct start $CTID 2>&1 | tee -a "$LOGFILE"

    echo "Backup del CT $CTID completado." | tee -a "$LOGFILE"
done

echo "=== Backup de todos los CTs finalizado ===" | tee -a "$LOGFILE"

########################################################
#             ENVÍO DEL LOG POR SENDMAIL              #
########################################################
{
echo "To: $EMAIL_TO"
echo "Subject: [Proxmox] Informe de Backup (${DATE})"
echo "Content-Type: text/plain"
echo ""
cat "$LOGFILE"
} | sendmail -t

echo "Log enviado por correo a $EMAIL_TO"
