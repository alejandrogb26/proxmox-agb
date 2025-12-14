#!/bin/bash

# Autor: Alejandro Gómez Blanco
# Fecha: 04/11/2024

#!/bin/bash

# Nombre del servicio a verificar
SERVICE="iptables-restore-custom.service"

# Obtener últimos logs
SERVICE_LOG=$(journalctl -u "$SERVICE" -n 20 --no-pager)

# Crear mensaje
MESSAGE="Advertencia - Servicio $SERVICE NO se ha iniciado
El equipo $(hostname) aplicará un firewall mucho más restrictivo. ⚠

--- Últimos registros del servicio $SERVICE ---
$SERVICE_LOG
----------------------------------------------
"

# Enviar correo
sendmail -t <<EOF
To: alejandrogb@alejandrogb.local
Subject: [ALERTA] Fallo en $SERVICE en $(hostname)
Content-Type: text/plain; charset="UTF-8"

El servicio $SERVICE ha fallado.
Fecha: $(date)
Servidor: $(hostname)

$MESSAGE
EOF

# Aplicar reglas Iptables más restrictivas
/sbin/iptables-restore /etc/iptables/rules-restrictive.v4
