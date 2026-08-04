#!/usr/bin/env bash
#
# Instalacion y configuracion estandar de fail2ban en Debian.
# Modo hibrido: por defecto es no interactivo (automatizable); con --guide
# actua como asistente guiado para tecnicos.
#
# Uso: sudo ./install-fail2ban.sh [opciones]
#   --guide                 Modo asistente interactivo
#   --bantime DUR           Tiempo de ban inicial (default: 1h)
#   --maxretry N            Reintentos antes de banear (default: 5)
#   --findtime DUR          Ventana de deteccion (default: 10m)
#   --ignoreip "RANGOS"     IPs/rangos a ignorar (default: loopback + RFC1918)
#   --no-incremental        Desactiva el ban incremental
#   --no-detect             Desactiva la deteccion de servicios
#
set -euo pipefail

BANTIME="1h"
MAXRETRY="5"
FINDTIME="10m"
IGNOREIP="127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
INCREMENTAL=true
DETECT=true
GUIDE=false
ENABLED_JAILS=()

usage() {
  cat <<'EOF'
Uso: sudo ./install-fail2ban.sh [opciones]

  --guide                 Modo asistente interactivo
  --bantime DUR           Tiempo de ban inicial (default: 1h)
  --maxretry N            Reintentos antes de banear (default: 5)
  --findtime DUR          Ventana de deteccion (default: 10m)
  --ignoreip "RANGOS"     IPs/rangos a ignorar
  --no-incremental        Desactiva el ban incremental
  --no-detect             Desactiva la deteccion de servicios
  -h, --help              Muestra esta ayuda
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --guide) GUIDE=true; shift ;;
    --bantime) BANTIME="$2"; shift 2 ;;
    --maxretry) MAXRETRY="$2"; shift 2 ;;
    --findtime) FINDTIME="$2"; shift 2 ;;
    --ignoreip) IGNOREIP="$2"; shift 2 ;;
    --no-incremental) INCREMENTAL=false; shift ;;
    --no-detect) DETECT=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opcion desconocida: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Ejecuta como root (sudo $0)" >&2
  exit 1
fi

detect_services() {
  local services=()
  systemctl is-active --quiet ssh 2>/dev/null && services+=("sshd")
  systemctl is-active --quiet nginx 2>/dev/null && services+=("nginx-http-auth")
  systemctl is-active --quiet apache2 2>/dev/null && services+=("apache-auth")
  systemctl is-active --quiet postfix 2>/dev/null && services+=("postfix postfix-sasl")
  systemctl is-active --quiet dovecot 2>/dev/null && services+=("dovecot")
  systemctl is-active --quiet vsftpd 2>/dev/null && services+=("vsftpd")
  systemctl is-active --quiet proftpd 2>/dev/null && services+=("proftpd")
  systemctl is-active --quiet pure-ftpd 2>/dev/null && services+=("pure-ftpd")
  systemctl is-active --quiet named 2>/dev/null && services+=("named-refused-tcp")
  systemctl is-active --quiet asterisk 2>/dev/null && services+=("asterisk")
  printf '%s\n' "${services[@]}"
}

guide() {
  local ans
  echo "==> Modo asistente (Enter = default)"
  read -r -p "Tiempo de ban inicial [$BANTIME]: " ans
  [[ -n "$ans" ]] && BANTIME="$ans"
  read -r -p "Reintentos antes de banear [$MAXRETRY]: " ans
  [[ -n "$ans" ]] && MAXRETRY="$ans"
  read -r -p "Ventana de deteccion [$FINDTIME]: " ans
  [[ -n "$ans" ]] && FINDTIME="$ans"
  read -r -p "Ban incremental (reincidentes baneados cada vez mas tiempo) [Y/n]: " ans
  [[ "$ans" =~ ^[Nn]$ ]] && INCREMENTAL=false
  read -r -p "Ignorar rangos internos (10/172.16/192.168) [Y/n]: " ans
  [[ "$ans" =~ ^[Nn]$ ]] && IGNOREIP="127.0.0.1/8 ::1"
  if [[ "$DETECT" == true ]]; then
    local detected=($(detect_services))
    if [[ ${#detected[@]} -gt 0 ]]; then
      echo "Servicios detectados: ${detected[*]}"
      read -r -p "Habilitar sus jails [Y/n]: " ans
      [[ "$ans" =~ ^[Nn]$ ]] && detected=()
      ENABLED_JAILS=("${detected[@]}")
    fi
  fi
}

write_config() {
  local jailfile="/etc/fail2ban/jail.d/standard.local"
  local banaction="iptables-multiport"
  command -v nft >/dev/null 2>&1 && banaction="nftables-multiport"

  echo "==> Escribiendo configuracion en ${jailfile}"
  cat > "${jailfile}" <<EOF
[DEFAULT]
bantime   = ${BANTIME}
maxretry  = ${MAXRETRY}
findtime  = ${FINDTIME}
backend   = systemd
ignoreip  = ${IGNOREIP}
banaction = ${banaction}
EOF
  if [[ "$INCREMENTAL" == true ]]; then
    cat >> "${jailfile}" <<'EOF'

bantime.increment = true
bantime.factor    = 3
bantime.maxtime   = 24h
EOF
  fi
  cat >> "${jailfile}" <<'EOF'

[sshd]
enabled = true
EOF
  for jail in "${ENABLED_JAILS[@]}"; do
    [[ "$jail" == "sshd" ]] && continue
    cat >> "${jailfile}" <<EOF

[${jail}]
enabled = true
EOF
  done
}

if [[ "$GUIDE" == true ]]; then
  guide
elif [[ "$DETECT" == true ]]; then
  mapfile -t ENABLED_JAILS < <(detect_services)
  [[ ${#ENABLED_JAILS[@]} -gt 0 ]] && echo "==> Jails detectados: ${ENABLED_JAILS[*]}"
fi

echo "==> Instalando fail2ban..."
apt-get update
apt-get install -y fail2ban

write_config

echo "==> Habilitando y arrancando el servicio..."
systemctl enable --now fail2ban
for _ in {1..15}; do
  systemctl is-active --quiet fail2ban && break
  sleep 1
done

echo
echo "==> Estado general:"
fail2ban-client status
for jail in "${ENABLED_JAILS[@]}"; do
  fail2ban-client status "$jail" 2>/dev/null || true
done
echo
echo "fail2ban instalado. Monitorea con: fail2ban-client status sshd"
