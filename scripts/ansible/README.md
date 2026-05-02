# scripts/ansible

Роли установки Zabbix-агентов:
- `roles/zabbix_agent_linux/` — Debian/Ubuntu/RHEL
- `roles/zabbix_agent_windows/` — Win10/11/Server (через WinRM)
- `playbooks/onboard-linux.yml`, `playbooks/onboard-windows.yml`

Inventory `scripts/ansible/inventory/auto.yml` генерируется
скриптом `scripts/bash/itk-discover.sh` из whitelist'а.
