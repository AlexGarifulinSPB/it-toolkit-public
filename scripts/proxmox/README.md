# scripts/proxmox

Скрипты подъёма Proxmox-инфраструктуры для PoC мониторинга:
- `lab-network.sh` — создаёт изолированный bridge `vmbr-itk` (10.99.0.0/24)
- `lab-vms.sh` — поднимает VM 122-127 (zbx-lab, itk-worker, тестовые таргеты)

Запускать **на узле Proxmox** под root.
