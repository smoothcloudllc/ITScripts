#!/usr/bin/env bash
#
# Asistente guiado de configuracion de fail2ban para Debian.
# Instala fail2ban si no esta presente y aplica una configuracion estandar.
#
# Uso: sudo ./configure-fail2ban.sh
# Ejecutar via pipe: curl -fsSL <url> | sudo bash -s
#
set -euo pipefail

BANTIME="1h"
MAXRETRY="5"
FINDTIME="10m"
INCREMENTAL=true
WHITELIST=true
ENABLED_JAILS=()

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

ask() {
  local msg="$1"
  REPLY=""
  if [[ -t 0 ]]; then
    read -r -p "$msg" REPLY || true
  elif [[ -r /dev/tty ]]; then
    printf '%s' "$msg" >&2
    read -r REPLY < /dev/tty 2>/dev/null || true
  fi
}

ask_yn() {
  local msg="$1" default="${2:-Y}" answer
  while :; do
    ask "$msg [Y/n]: "
    answer="${REPLY:-$default}"
    case "$answer" in
      Y|y|S|s) REPLY="yes"; return 0 ;;
      N|n) REPLY="no"; return 0 ;;
      *) echo "  Responde si (Y) o no (N)." >&2 ;;
    esac
  done
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "${RED}Ejecuta como root (sudo $0)${RESET}" >&2
    exit 1
  fi
}

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

ensure_installed() {
  echo
  echo "${BOLD}Paso 1/6 - Estado de fail2ban${RESET}"
  if command -v fail2ban-client >/dev/null 2>&1; then
    echo "${GREEN}OK${RESET} fail2ban ya esta instalado: $(fail2ban-client --version 2>/dev/null || echo 'version desconocida')"
    return
  fi
  echo "${YELLOW}fail2ban no esta instalado.${RESET}"
  ask_yn "¿Instalarlo ahora con apt-get?"
  if [[ "$REPLY" != "yes" ]]; then
    echo "${RED}Cancelado. No se puede configurar sin fail2ban.${RESET}" >&2
    exit 1
  fi
  echo "==> Instalando fail2ban..."
  apt-get update
  apt-get install -y fail2ban
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    echo "${RED}ERROR: fail2ban no se instalo correctamente. Revisa la salida de apt-get.${RESET}" >&2
    exit 1
  fi
  echo "${GREEN}OK${RESET} fail2ban instalado."
}

collect_options() {
  echo
  echo "${BOLD}Paso 2/6 - Tiempo de ban inicial${RESET}"
  echo "  Tiempo que una IP queda bloqueada al primer ban (sufijo s/m/h/d)."
  ask "  Tiempo de ban [${BANTIME}]: "
  [[ -n "$REPLY" ]] && BANTIME="$REPLY"

  echo
  echo "${BOLD}Paso 3/6 - Intentos fallidos${RESET}"
  echo "  Reintentos y ventana de deteccion en la que cuentan."
  ask "  Reintentos antes de banear [${MAXRETRY}]: "
  [[ -n "$REPLY" ]] && MAXRETRY="$REPLY"
  ask "  Ventana de deteccion [${FINDTIME}]: "
  [[ -n "$REPLY" ]] && FINDTIME="$REPLY"

  echo
  echo "${BOLD}Paso 4/6 - Ban incremental${RESET}"
  echo "  Cada reincidencia multiplica el ban (factor 3, tope 24h)."
  ask_yn "  ¿Activar ban incremental?" "Y"
  if [[ "$REPLY" != "yes" ]]; then
    INCREMENTAL=false
  fi

  echo
  echo "${BOLD}Paso 5/6 - Whitelist de red interna${RESET}"
  echo "  Evita banear a tecnicos desde rangos privados (10/172.16/192.168)."
  ask_yn "  ¿Ignorar rangos internos RFC1918?" "Y"
  if [[ "$REPLY" != "yes" ]]; then
    WHITELIST=false
  fi
}

choose_jails() {
  local detected=($(detect_services))
  echo
  echo "${BOLD}Paso 6/6 - Servicios detectados${RESET}"
  if [[ ${#detected[@]} -eq 0 ]]; then
    echo "  No se detectaron servicios activos. Se activa solo la jail sshd."
    ENABLED_JAILS=("sshd")
    return
  fi
  echo "  Servicios activos detectados:"
  for s in "${detected[@]}"; do
    echo "    - ${s}"
  done
  ask_yn "  ¿Habilitar jails para estos servicios?" "Y"
  if [[ "$REPLY" == "yes" ]]; then
    ENABLED_JAILS=("${detected[@]}")
  else
    ENABLED_JAILS=("sshd")
  fi
}

show_summary() {
  local banaction="iptables-multiport"
  command -v nft >/dev/null 2>&1 && banaction="nftables-multiport"

  echo
  echo "${BOLD}Resumen de configuracion${RESET}"
  echo "  Tiempo de ban     : ${BANTIME}"
  echo "  Reintentos        : ${MAXRETRY} en ${FINDTIME}"
  echo "  Ban incremental   : $([[ "$INCREMENTAL" == true ]] && echo "si (factor 3, tope 24h)" || echo "no")"
  echo "  Whitelist interna : $([[ "$WHITELIST" == true ]] && echo "si" || echo "no")"
  echo "  Banaction         : ${banaction}"
  echo "  Jails activas     : ${ENABLED_JAILS[*]}"
  ask_yn "  ¿Aplicar y activar?" "Y"
  if [[ "$REPLY" != "yes" ]]; then
    echo "${RED}Cancelado. No se aplicaron cambios.${RESET}"
    exit 0
  fi
}

write_config() {
  local jailfile="/etc/fail2ban/jail.d/standard.local"
  local banaction="iptables-multiport"
  command -v nft >/dev/null 2>&1 && banaction="nftables-multiport"
  local ignoreip="127.0.0.1/8 ::1"
  [[ "$WHITELIST" == true ]] && ignoreip="${ignoreip} 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"

  install -d /etc/fail2ban/jail.d
  echo "==> Escribiendo configuracion en ${jailfile}"
  cat > "${jailfile}" <<EOF
[DEFAULT]
bantime   = ${BANTIME}
maxretry  = ${MAXRETRY}
findtime  = ${FINDTIME}
backend   = systemd
ignoreip  = ${ignoreip}
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

apply() {
  echo
  echo "==> Reiniciando fail2ban con la nueva config..."
  systemctl daemon-reload
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  for _ in {1..15}; do
    systemctl is-active --quiet fail2ban && break
    sleep 1
  done
  if ! systemctl is-active --quiet fail2ban; then
    echo "${RED}ERROR: fail2ban no arranco. Revisa: journalctl -u fail2ban${RESET}" >&2
    exit 1
  fi
  echo "${GREEN}OK${RESET} fail2ban activo."
  echo
  echo "==> Estado:"
  fail2ban-client status
  for jail in "${ENABLED_JAILS[@]}"; do
    fail2ban-client status "$jail" 2>/dev/null || true
  done
}

check_root
echo
echo "=================================================================="
echo "${BOLD}  Asistente de configuracion de fail2ban${RESET}"
echo "  Establece una configuracion estandar en este servidor."
echo "=================================================================="
ensure_installed
collect_options
choose_jails
show_summary
write_config
apply
echo
echo "${GREEN}Configuracion aplicada. Monitorea con: fail2ban-client status sshd${RESET}"
