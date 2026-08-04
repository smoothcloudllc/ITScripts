#!/usr/bin/env bash
#
# Instalacion automatizada de Docker Engine + Compose plugin en Debian.
# Uso: sudo ./install-docker.sh
# Requisitos: Debian 11 (bullseye) o 12 (bookworm), ejecutar como root.
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecuta como root (sudo $0)" >&2
  exit 1
fi

echo "==> Actualizando apt y requisitos..."
apt-get update
apt-get install -y ca-certificates curl gnupg

echo "==> Añadiendo clave GPG oficial de Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "==> Añadiendo repositorio de Docker..."
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

echo "==> Instalando Docker Engine..."
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Habilitando y arrancando el servicio..."
systemctl enable --now docker

if [ -n "${SUDO_USER:-}" ]; then
  echo "==> Añadiendo $SUDO_USER al grupo docker..."
  usermod -aG docker "$SUDO_USER"
fi

docker --version
docker compose version
echo
echo "Docker instalado. Cierra y abre sesión para usar docker sin sudo."
