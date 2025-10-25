# ------------------------------------------------------------------------------
# Imagen base: Ubuntu 22.04 (estable y con buen soporte para Qt5 / SDL2)
# ------------------------------------------------------------------------------
FROM ubuntu:22.04

# Evita prompts interactivos durante instalaciones (tzdata, etc.)
ENV DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# Utilidades del sistema y build toolchain
# - iproute2 / net-tools: para gestionar interfaces (vcan, ip link, etc.)
# - build-essential, git, curl: compilar SavvyCAN / ICSim y utilidades
# - pkg-config: detección de librerías en builds
# - ca-certificates: para clonar repos vía https
# - xauth (opcional): útil en setups X11 que usen autenticación por cookies
# ------------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 net-tools sudo git curl ca-certificates xauth \
    pkg-config build-essential make cmake \
    kmod \                 
    # Herramientas varias de depuración (opcionales)
    nano vim less procps file \
    # Wireshark CLI (tshark) opcional para análisis no-GUI
    tshark \
 && rm -rf /var/lib/apt/lists/*
# ------------------------------------------------------------------------------
# SocketCAN (Parte I) - can-utils
# Puedes usar paquete oficial (suficiente para el taller).
# ------------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    can-utils \
 && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Dependencias Qt5 para SavvyCAN (Parte II)
# SavvyCAN utiliza Qt (qmake) y módulos de serialbus/serialport y herramientas Qt.
# También incluimos módulos declarativos (qml) y svg (algunas builds lo usan).
# ------------------------------------------------------------------------------
# --- Habilitar 'universe' y librerías Qt5 necesarias para SavvyCAN ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common gnupg \
 && add-apt-repository universe \
 && apt-get update && apt-get install -y --no-install-recommends \
    qtbase5-dev qttools5-dev qtdeclarative5-dev \
    libqt5serialbus5-dev \
    libqt5serialport5-dev \
    libqt5svg5-dev \
    libqt5opengl5-dev \
    # OpenGL / Mesa (evita 'cannot find -lGL' y similares)
    libgl1-mesa-dev libglu1-mesa-dev mesa-common-dev \
    # Herramientas extra de Qt que a veces pide qmake/proyectos
    qttools5-dev-tools qtbase5-private-dev \
 && rm -rf /var/lib/apt/lists/*


# ------------------------------------------------------------------------------
# Dependencias SDL2 para ICSim (Parte III)
# ICSim usa SDL2 y SDL2_image.
# ------------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsdl2-dev libsdl2-image-dev \
 && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Variables de entorno para X11 (renderizado GUI desde contenedor)
# - DISPLAY: el display por defecto (el host suele usar :0, pero esto se puede
#   sobreescribir al ejecutar el contenedor si fuera distinto).
# - QT_X11_NO_MITSHM=1: evita problemas de MIT-SHM con X11 en contenedores.
# ------------------------------------------------------------------------------
ENV DISPLAY=:0
ENV QT_X11_NO_MITSHM=1

# ------------------------------------------------------------------------------
# Directorios de trabajo estándar para los proyectos
# ------------------------------------------------------------------------------
WORKDIR /opt

# ------------------------------------------------------------------------------
# SavvyCAN (clonar y compilar)
# Deja los binarios en /opt/SavvyCAN/SavvyCAN
# ------------------------------------------------------------------------------
RUN git clone --depth=1 https://github.com/collin80/SavvyCAN.git && \
    cd SavvyCAN && \
    qmake && \
    make -j"$(nproc)"

# ------------------------------------------------------------------------------
# ICSim (clonar y compilar)
# Instala binarios en /opt/ICSim (icsim y controls)
# ------------------------------------------------------------------------------
RUN git clone --depth=1 https://github.com/zombieCraig/ICSim.git && \
    cd ICSim && \
    make -j"$(nproc)"

# ------------------------------------------------------------------------------
# Usuario / permisos
# Nota: Para manipular interfaces de red (crear vcan0) normalmente necesitarás
# capacidades elevadas en el contenedor (NET_ADMIN). Por simplicidad mantenemos
# usuario root dentro del contenedor. Si deseas un usuario no-root, crea uno aquí
# y dale sudo NOPASSWD, pero recuerda que igual necesitarás --cap-add=NET_ADMIN
# al ejecutar el contenedor.
# ------------------------------------------------------------------------------
# RUN useradd -ms /bin/bash canuser && echo "canuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/canuser
# USER canuser

# ------------------------------------------------------------------------------
# PATH conveniente para acceder a binarios desde cualquier lado
# ------------------------------------------------------------------------------
ENV PATH="/opt/SavvyCAN:/opt/ICSim:${PATH}"

# ------------------------------------------------------------------------------
# Limpieza final (ya hicimos limpiezas tras apt-get; aquí nada que hacer)
# Puedes añadir más limpieza si agregas herramientas extra en tu fork.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# ENTRYPOINT / CMD
# Deja el contenedor en modo interactivo por defecto. Así puedes:
#   - Parte I: usar can-utils y manejar vcan
#   - Parte II: lanzar /opt/SavvyCAN/SavvyCAN (GUI via X11)
#   - Parte III: lanzar /opt/ICSim/icsim y /opt/ICSim/controls (GUI via X11)
# ------------------------------------------------------------------------------

WORKDIR /root

# --- Bootstrap de vcan con verificación y mensajes claros ---
RUN printf '%s\n' \
'#!/usr/bin/env bash' \
'set -euo pipefail' \
'' \
'# Detecta causa del fallo para dar un mensaje útil' \
'try_create() {' \
'  local err' \
'  err=$( { ip link add dev vcan0-test type vcan; } 2>&1 >/dev/null || true )' \
'  if [[ -z "${err}" ]]; then' \
'    # Éxito: el kernel soporta vcan (módulo cargado o built-in)' \
'    ip link del dev vcan0-test >/dev/null 2>&1 || true' \
'    return 0' \
'  fi' \
'  # Mensajes específicos' \
'  if echo "$err" | grep -qi "Operation not supported"; then' \
'    echo "[Error]: vcan no cargado en el host - ejecute: sudo modprobe vcan" >&2' \
'    return 2' \
'  fi' \
'  if echo "$err" | grep -qi "Operation not permitted"; then' \
'    echo "[Error]: falta capacidad NET_ADMIN en el contenedor (use --cap-add=NET_ADMIN)" >&2' \
'    return 3' \
'  fi' \
'  echo "[Error]: no se pudo crear interfaz vcan (detalle: $err)" >&2' \
'  return 1' \
'}' \
'' \
'# Paso 1: probar soporte vcan' \
'if try_create; then' \
'  :' \
'else' \
'  exit $?' \
'fi' \
'' \
'# Paso 2: asegurar vcan0 arriba (idempotente)' \
'ip link show vcan0 >/dev/null 2>&1 || ip link add dev vcan0 type vcan' \
'ip link set vcan0 up' \
'' \
'# Paso 3: continuar con el shell por defecto' \
'exec /bin/bash' \
> /usr/local/sbin/vcan_gate.sh && chmod +x /usr/local/sbin/vcan_gate.sh

ENTRYPOINT ["/usr/local/sbin/vcan_gate.sh"]

