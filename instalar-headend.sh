#!/usr/bin/env bash
# =============================================================================
#  Instalador de headend: Drivers TBS6909-X + Astra (Cesbo) + OSCam
#  Probado para: Ubuntu Server 22.04 LTS (kernel 5.15 GA, sin HWE)
#
#  Uso:
#     sudo bash instalar-headend.sh            # instala todo
#     sudo bash instalar-headend.sh tbs        # solo drivers TBS
#     sudo bash instalar-headend.sh oscam      # solo OSCam
#     sudo bash instalar-headend.sh astra      # solo Astra
#     sudo bash instalar-headend.sh sistema    # solo ajustes de sistema
#
#  Al terminar REINICIA el servidor para cargar los drivers TBS.
#  Las credenciales generadas quedan en /root/credenciales-headend.txt
# =============================================================================
set -euo pipefail

# ----------------------------- AJUSTES ---------------------------------------
OSCAM_REPO="https://git.streamboard.tv/common/oscam.git"   # verificar si cambia
OSCAM_DIR="/etc/oscam"
OSCAM_LOG_DIR="/var/log/oscam"
OSCAM_WEBIF_PORT="8181"
OSCAM_NEWCAMD_PORT="11001"
OSCAM_CAID="0B00"              # Conax (tu tarjeta)
LECTOR_MHZ="357"               # 357 = switch en 3.579 MHz ; 600 = switch en 6 MHz
RED_LOCAL="192.168.0.0-192.168.255.255"   # rango con acceso a la webif

TBS_FIRMWARE_URL="http://www.tbsdtv.com/download/document/linux/tbs-tuner-firmwares_v1.0.tar.bz2"
TBS_FW_6909_URL="http://www.tbsdtv.com/download/document/linux/dvb-fe-mxl5xx.fw"
ASTRA_URL="https://cesbo.com/astra-latest"                 # verificar en docs de Cesbo

BUILD_DIR="/usr/src/headend-build"
CRED_FILE="/root/credenciales-headend.txt"
# -----------------------------------------------------------------------------

verde(){ echo -e "\e[32m[OK]\e[0m $*"; }
info(){  echo -e "\e[36m[..]\e[0m $*"; }
aviso(){ echo -e "\e[33m[!!]\e[0m $*"; }
error(){ echo -e "\e[31m[ERROR]\e[0m $*"; exit 1; }

comprobar_sistema() {
  [[ $EUID -eq 0 ]] || error "Ejecuta como root: sudo bash $0"
  . /etc/os-release
  if [[ "${VERSION_ID:-}" != "22.04" ]]; then
    aviso "Este script está pensado para Ubuntu 22.04 (detectado: ${PRETTY_NAME:-desconocido})."
    read -rp "¿Continuar de todos modos? [s/N] " r; [[ "$r" =~ ^[sS]$ ]] || exit 1
  fi
  local kmaj kmin
  kmaj=$(uname -r | cut -d. -f1); kmin=$(uname -r | cut -d. -f2)
  if (( kmaj > 6 || (kmaj == 6 && kmin > 8) )); then
    aviso "Kernel $(uname -r) es más nuevo que 6.8: el driver TBS puede no compilar."
  fi
  mkdir -p "$BUILD_DIR"
}

# =============================================================================
#  1. AJUSTES DE SISTEMA
# =============================================================================
paso_sistema() {
  info "Instalando dependencias base..."
  apt-get update
  apt-get install -y build-essential git curl wget openssl \
    "linux-headers-$(uname -r)" patchutils libproc-processtable-perl \
    libssl-dev libusb-1.0-0-dev dvb-tools

  info "Desactivando suspensión automática de USB (evita que se caiga el lector)..."
  if ! grep -q "usbcore.autosuspend=-1" /etc/default/grub; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 usbcore.autosuspend=-1"/' /etc/default/grub
    update-grub
  fi

  info "Desactivando actualizaciones automáticas (protegen el driver TBS)..."
  systemctl disable --now unattended-upgrades 2>/dev/null || true

  verde "Ajustes de sistema listos."
}

congelar_kernel() {
  info "Congelando el kernel actual ($(uname -r))..."
  apt-mark hold linux-image-generic linux-headers-generic linux-generic \
    "linux-image-$(uname -r)" "linux-headers-$(uname -r)" 2>/dev/null || true
  verde "Kernel congelado. Para liberarlo: apt-mark unhold <paquete>"
}

# =============================================================================
#  2. DRIVERS TBS (TBS6909-X)
# =============================================================================
paso_tbs() {
  info "Descargando código del driver TBS..."
  cd "$BUILD_DIR"
  rm -rf media_build media
  git clone https://github.com/tbsdtv/media_build.git
  git clone --depth=1 https://github.com/tbsdtv/linux_media.git -b latest ./media

  info "Compilando driver (tarda varios minutos)..."
  cd media_build
  make dir DIR=../media
  make allyesconfig
  make -j"$(nproc)"
  make install

  info "Instalando firmwares TBS..."
  cd "$BUILD_DIR"
  wget -q -O tbs-fw.tar.bz2 "$TBS_FIRMWARE_URL" && tar jxf tbs-fw.tar.bz2 -C /lib/firmware/ \
    || aviso "No se pudo descargar el paquete de firmwares, revísalo manualmente."
  [[ -f /lib/firmware/dvb-fe-mxl5xx.fw ]] || \
    wget -q -O /lib/firmware/dvb-fe-mxl5xx.fw "$TBS_FW_6909_URL" \
    || aviso "No se pudo descargar dvb-fe-mxl5xx.fw (firmware de la 6909)."

  congelar_kernel
  verde "Driver TBS instalado. REINICIA y verifica con: ls /dev/dvb/  (deben salir adapter0..adapter7)"
}

# =============================================================================
#  3. OSCAM
# =============================================================================
paso_oscam() {
  info "Descargando y compilando OSCam..."
  cd "$BUILD_DIR"
  rm -rf oscam-src
  git clone "$OSCAM_REPO" oscam-src || error "No se pudo clonar OSCam. Revisa la URL del repositorio."
  cd oscam-src
  ./config.sh --disable all --enable WEBIF MODULE_NEWCAMD READER_CONAX CARDREADER_PHOENIX
  make -j"$(nproc)" USE_LIBCRYPTO=1

  local bin
  bin=$(ls Distribution/oscam-* 2>/dev/null | grep -v '\.debug' | head -n1)
  [[ -n "$bin" ]] || error "No se encontró el binario compilado en Distribution/"
  install -m 755 "$bin" /usr/local/bin/oscam
  verde "OSCam instalado en /usr/local/bin/oscam"

  # --- Detectar el lector -----------------------------------------------------
  local lector
  lector=$(ls /dev/serial/by-id/* 2>/dev/null | head -n1 || true)
  if [[ -z "$lector" ]]; then
    lector="/dev/ttyUSB0"
    aviso "No se detectó el lector en /dev/serial/by-id/. Uso $lector; conéctalo y corrige oscam.server."
  else
    verde "Lector detectado: $lector"
  fi

  # --- Credenciales (se reutilizan si ya existen) ------------------------------
  local des_key webif_pwd astra_pwd
  if [[ -f "$CRED_FILE" ]]; then
    des_key=$(grep '^NEWCAMD_KEY=' "$CRED_FILE" | cut -d= -f2)
    webif_pwd=$(grep '^WEBIF_PWD=' "$CRED_FILE" | cut -d= -f2)
    astra_pwd=$(grep '^ASTRA_USER_PWD=' "$CRED_FILE" | cut -d= -f2)
  fi
  des_key=${des_key:-$(openssl rand -hex 14 | tr 'a-f' 'A-F')}
  webif_pwd=${webif_pwd:-$(openssl rand -hex 8)}
  astra_pwd=${astra_pwd:-$(openssl rand -hex 8)}

  # --- Respaldar config anterior -----------------------------------------------
  if [[ -d "$OSCAM_DIR" ]]; then
    cp -a "$OSCAM_DIR" "${OSCAM_DIR}.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  mkdir -p "$OSCAM_DIR" "$OSCAM_LOG_DIR"

  cat > "$OSCAM_DIR/oscam.conf" <<EOF
[global]
logfile                  = $OSCAM_LOG_DIR/oscam.log
maxlogsize               = 10240
clienttimeout            = 5000
fallbacktimeout          = 2500
preferlocalcards         = 1
nice                     = -1

[newcamd]
port                     = ${OSCAM_NEWCAMD_PORT}@${OSCAM_CAID}:000000
serverip                 = 127.0.0.1
key                      = $des_key
keepalive                = 1

[webif]
httpport                 = $OSCAM_WEBIF_PORT
httpuser                 = admin
httppwd                  = $webif_pwd
httpallowed              = 127.0.0.1,$RED_LOCAL
EOF

  cat > "$OSCAM_DIR/oscam.server" <<EOF
[reader]
label                    = conax_local
protocol                 = mouse
device                   = $lector
caid                     = $OSCAM_CAID
detect                   = cd
mhz                      = $LECTOR_MHZ
cardmhz                  = $LECTOR_MHZ
group                    = 1
emmcache                 = 1,3,2,0
blockemm-unknown         = 1
blockemm-g               = 1
EOF

  cat > "$OSCAM_DIR/oscam.user" <<EOF
[account]
user                     = astra
pwd                      = $astra_pwd
group                    = 1
caid                     = $OSCAM_CAID
au                       = conax_local
keepalive                = 1
EOF
  chmod 600 "$OSCAM_DIR"/oscam.*

  cat > /etc/systemd/system/oscam.service <<EOF
[Unit]
Description=OSCam
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/oscam -c $OSCAM_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # Detener NCam si existe
  systemctl disable --now ncam 2>/dev/null || true
  pkill -x ncam 2>/dev/null || true

  systemctl daemon-reload
  systemctl enable --now oscam

  cat > "$CRED_FILE" <<EOF
# Credenciales del headend - generado $(date)
WEBIF_URL=http://$(hostname -I | awk '{print $1}'):$OSCAM_WEBIF_PORT
WEBIF_USER=admin
WEBIF_PWD=$webif_pwd

# Datos para la conexion newcamd en Astra
NEWCAMD_HOST=127.0.0.1
NEWCAMD_PORT=$OSCAM_NEWCAMD_PORT
ASTRA_USER=astra
ASTRA_USER_PWD=$astra_pwd
NEWCAMD_KEY=$des_key
EOF
  chmod 600 "$CRED_FILE"

  verde "OSCam configurado y en marcha. Credenciales en $CRED_FILE"
}

# =============================================================================
#  4. ASTRA (Cesbo)
# =============================================================================
paso_astra() {
  if command -v astra >/dev/null 2>&1; then
    verde "Astra ya está instalado: $(command -v astra)"
  else
    info "Instalando Astra..."
    curl -fLo /usr/bin/astra "$ASTRA_URL" || error "No se pudo descargar Astra. Revisa la URL en la documentación de Cesbo."
    chmod +x /usr/bin/astra
    astra init || aviso "Ejecuta 'astra init' manualmente según la documentación de Cesbo."
  fi
  systemctl enable --now astra 2>/dev/null || aviso "Revisa el nombre del servicio de Astra (systemctl list-units | grep astra)."

  verde "Astra listo. Interfaz web: http://$(hostname -I | awk '{print $1}'):8000"
  aviso "Astra requiere licencia válida de Cesbo (colócala según su documentación)."
}

resumen() {
  cat <<EOF

=============================================================================
 INSTALACIÓN TERMINADA
=============================================================================
 1) REINICIA el servidor:            sudo reboot
 2) Verifica la TBS:                 ls /dev/dvb/        (adapter0..adapter7)
                                     dmesg | grep -i tbs
 3) Verifica OSCam:                  systemctl status oscam
                                     tail -f $OSCAM_LOG_DIR/oscam.log
    Webif y credenciales:            sudo cat $CRED_FILE
    En Readers la tarjeta debe estar en CARDOK.
 4) En Astra (interfaz web, puerto 8000):
    - Settings > CAS / Softcam > nuevo tipo newcamd con los datos de
      NEWCAMD_HOST / PORT / USER / PWD / KEY del archivo de credenciales.
    - Asigna ese softcam a los canales cifrados.
    - Activa el envío de EMM en UN solo canal.
    - En cada adaptador, aumenta el buffer DVR si notas cortes.
 5) Si cambias el switch del lector a 6 MHz, pon mhz/cardmhz = 600 en
    $OSCAM_DIR/oscam.server y reinicia: systemctl restart oscam
=============================================================================
EOF
}

# =============================================================================
main() {
  comprobar_sistema
  case "${1:-todo}" in
    sistema) paso_sistema ;;
    tbs)     paso_tbs ;;
    oscam)   paso_oscam ;;
    astra)   paso_astra ;;
    todo)    paso_sistema; paso_tbs; paso_oscam; paso_astra ;;
    *)       error "Opción no válida: $1 (usa: todo | sistema | tbs | oscam | astra)" ;;
  esac
  resumen
}

main "$@"
