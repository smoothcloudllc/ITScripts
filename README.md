# ITScripts

Coleccion de scripts de operaciones IT reutilizables (instalacion, hardening, backups) para servidores Linux.

## Politica de seguridad (obligatoria)

Este repositorio es **publico**. Todo lo que se suba es legible por cualquier persona.

- **Cero secretos en el repo**: no se suben API keys, tokens, passwords, certificados ni claves SSH.
- Usa variables de entorno, secret managers o Ansible Vault para valores sensibles.
- No publiques IPs internas, hostnames de produccion, usuarios reales ni topologia de SmoothCloud.
- Cualquier violacion detectada se debe revertir y rotar el secreto de inmediato.

## Controles automatizados

- [gitleaks](https://github.com/gitleaks/gitleaks) escanea secretos en cada commit.
  - Con el framework `pre-commit`: `pre-commit install`
  - Sin framework, el hook manual esta en `.githooks/`:
    `git config core.hooksPath .githooks`
- [Secret scanning](https://docs.github.com/en/code-security/secret-scanning) de GitHub habilitado en el repositorio.

## Estructura sugerida

```
ITScripts/
├── install/       # instalacion de software (docker, agentes, etc.)
├── hardening/     # endurecimiento de sistemas
├── backups/       # respaldos y rotacion
└── utils/         # scripts de soporte generico
```

## Instalacion de Docker (Debian)

```bash
sudo ./install/install-docker.sh
```

## Fail2ban estandar (Debian)

Script hibrido: no interactivo por defecto (automatizable) o asistente guiado con `--guide`.

```bash
sudo ./hardening/install-fail2ban.sh                    # instalacion estandar
sudo ./hardening/install-fail2ban.sh --guide           # asistente para tecnicos
sudo ./hardening/install-fail2ban.sh --bantime 4h --maxretry 3 --no-detect
```

Incluye ban incremental (reincidentes cada vez mas tiempo, tope 24h), backend systemd, `banaction` adaptado a nftables e ignora los rangos internos RFC1918 por defecto.

## Contribuir

- Revisa que tu script no contenga secretos (`gitleaks detect .`).
- Sigue la estructura de carpetas sugerida.
- Documenta el uso en un comentario al inicio del script.
