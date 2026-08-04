#!/usr/bin/env bash
#
# Asistente de PRIMERA configuracion de UFW para Debian.
# Instala ufw si falta, establece politicas por defecto (deny incoming /
# allow outgoing) y pregunta que puertos de entrada abrir.
#
# GARANTIA DE GESTION: detecta el puerto real de sshd, permite el acceso SSH
# ANTES de activar el firewall y anade la IP de la sesion actual como
# whitelist. Al final verifica que el SSH sigue permitido.
#
# Uso: sudo ./configure-ufw.sh
# Via pipe: curl -fsSL <url> | sudo bash -s
#
set -euo pipefail

SSH_PORTS=()
EXTRA_RULES=()
CLIENT_IP=""
SSH_LIMIT=true

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

detect_ssh_ports() {
  local ports=() file line
  for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line; do
      line="${line%%#*}"
      [[ "$line" =~ ^[[:space:]]*Port[[:space:]]+([0-9]+) ]] && ports+=("${BASH_REMATCH[1]}")
    done < "$file"
  done
  [[ ${#ports[@]} -eq 0 ]] && ports+=("22")
  printf '%s\n' "${ports[@]}"
}

ensure_installed() {
  echo
  echo "${BOLD}Paso 1/4 - Estado de ufw${RESET}"
  if ! command -v ufw >/dev/null 2>&1; then
    echo "${YELLOW}ufw no esta instalado.${RESET}"
    ask_yn "¿Instalarlo ahora con apt-get?"
    if [[ "$REPLY" != "yes" ]]; then
      echo "${RED}Cancelado. ufw es necesario para configurar el firewall.${RESET}" >&2
      exit 1
    fi
    apt-get update
    apt-get install -y ufw
    if ! command -v ufw >/dev/null 2>&1; then
      echo "${RED}ERROR: ufw no se instalo correctamente.${RESET}" >&2
      exit 1
    fi
  fi
  echo "${GREEN}OK${RESET} ufw disponible."
}

collect_ssh() {
  echo
  echo "${BOLD}Paso 2/4 - Acceso SSH (garantia de gestion)${RESET}"
  mapfile -t SSH_PORTS < <(detect_ssh_ports)
  echo "  Puertos SSH detectados en sshd_config: ${SSH_PORTS[*]}"
  echo "  Sin permitir el acceso SSH el servidor quedaria sin gestion."
  ask_yn "  ¿Permitir estos puertos?" "Y"
  if [[ "$REPLY" != "yes" ]]; then
    local custom
    while :; do
      ask "  Indica el puerto SSH real: "
      custom="$REPLY"
      [[ "$custom" =~ ^[0-9]+$ ]] && break
      echo "  Introduce un numero de puerto valido." >&2
    done
    SSH_PORTS=("$custom")
  fi
  echo "  Puertos SSH a permitir: ${SSH_PORTS[*]}"
}

collect_ssh_extra_safety() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    CLIENT_IP="${SSH_CONNECTION%% *}"
    echo "  IP de tu sesion actual: ${CLIENT_IP} (se anadira como whitelist)"
  fi
}

collect_ports() {
  echo
  echo "${BOLD}Paso 3/4 - Puertos de entrada adicionales${RESET}"
  echo "  Indica que puertos abrir para entrada (TCP/UDP)."
  echo "  Formato: 80, 53/udp, 6000-6010, o Enter para ninguno."
  local entry
  while :; do
    ask "  Puerto/s adicionales (Enter para terminar): "
    entry="$REPLY"
    [[ -z "$entry" ]] && break
    if [[ "$entry" =~ ^[0-9a-zA-Z/:.-]+$ ]]; then
      EXTRA_RULES+=("$entry")
      echo "  Anadido: $entry"
    else
      echo "  ${RED}Formato no valido: $entry${RESET}" >&2
    fi
  done
  [[ ${#EXTRA_RULES[@]} -gt 0 ]] && echo "  Puertos adicionales: ${EXTRA_RULES[*]}"
}

collect_limit() {
  echo
  echo "${BOLD}Paso 4/4 - Proteccion extra en SSH${RESET}"
  echo "  ufw limit aplica rate-limiting (anti fuerza bruta) a las conexiones SSH."
  ask_yn "  ¿Activar limit en SSH?" "Y"
  if [[ "$REPLY" != "yes" ]]; then
    SSH_LIMIT=false
  fi
}

show_summary() {
  echo
  echo "${BOLD}Resumen de configuracion${RESET}"
  echo "  Politicas        : deny incoming / allow outgoing"
  echo "  SSH              : ${SSH_PORTS[*]} $([[ "$SSH_LIMIT" == true ]] && echo "(con limit anti fuerza bruta)" || echo "")"
  [[ -n "$CLIENT_IP" ]] && echo "  IP gestion       : ${CLIENT_IP} (whitelist)"
  echo "  Puertos extra    : ${EXTRA_RULES[*]:-ninguno}"
  ask_yn "  ¿Aplicar y activar UFW?" "Y"
  if [[ "$REPLY" != "yes" ]]; then
    echo "${RED}Cancelado. No se aplicaron cambios.${RESET}"
    exit 0
  fi
}

apply() {
  echo
  echo "==> Politicas por defecto..."
  ufw default deny incoming
  ufw default allow outgoing

  echo "==> Permitiendo acceso SSH..."
  for p in "${SSH_PORTS[@]}"; do
    if [[ "$SSH_LIMIT" == true ]]; then
      ufw limit "${p}/tcp" comment 'SSH gestion'
    else
      ufw allow "${p}/tcp" comment 'SSH gestion'
    fi
  done

  if [[ -n "$CLIENT_IP" ]]; then
    echo "==> Whitelist de la IP de gestion actual: ${CLIENT_IP}"
    ufw allow from "$CLIENT_IP" comment 'IP sesion actual'
  fi

  echo "==> Abriendo puertos adicionales..."
  for e in "${EXTRA_RULES[@]}"; do
    ufw allow "$e"
  done

  echo "==> Activando UFW..."
  ufw --force enable

  echo
  echo "==> Estado final:"
  ufw status verbose
}

verify_ssh() {
  echo
  local status_out
  status_out="$(ufw status)"
  local ok=true
  for p in "${SSH_PORTS[@]}"; do
    if ! grep -qE "(${p}/tcp|^${p}[[:space:]])" <<<"$status_out"; then
      ok=false
    fi
  done
  if [[ "$ok" == true ]]; then
    echo "${GREEN}OK${RESET} SSH (${SSH_PORTS[*]}) permitido. El servidor NO queda sin gestion."
  else
    echo "${RED}PROBLEMA: el puerto SSH no aparece permitido.${RESET}" >&2
    echo "${RED}Reverte inmediatamente con: sudo ufw disable${RESET}" >&2
    exit 1
  fi
}

check_root
echo
echo "=================================================================="
echo "${BOLD}  Asistente de primera configuracion de UFW${RESET}"
echo "  Politicas por defecto + puertos de entrada + garantia SSH."
echo "=================================================================="
ensure_installed
collect_ssh
collect_ssh_extra_safety
collect_ports
collect_limit
show_summary
apply
verify_ssh
echo
echo "${GREEN}UFW activo y configurado. Estado: $(ufw status | head -1)${RESET}"
