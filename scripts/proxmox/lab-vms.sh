#!/usr/bin/env bash
# Назначение:    создать/удалить тестовые VM лабы PoC автомониторинга
#                на узле Proxmox.
# Что делает:
#   1. Готовит "золотой" cloud-init template VM 9000 из noble-server-cloudimg-amd64.img
#   2. Клонирует из него VM 122,123,124,127 (Linux) с заданной конфигурацией
#   3. Создаёт пустую заготовку VM 125 (Windows, без ОС — ждёт ISO)
#   4. Применяет cloud-init: пользователь itk + SSH-ключ + статический IP на vmbr-itk
#   5. Стартует VM, ждёт пока SSH поднимется (для Linux)
# Использование: см. usage()
# Требования:    Proxmox VE 7+, root, vmbr-itk поднят, /root/.ssh/id_itk_deploy.pub
# Идемпотентность: безопасно запускать повторно — пропускает существующие VM
# Опасные операции: создаёт VM с фиксированными ID 122-127.
#                   Если ID уже заняты не нашей лабой — выходит с ошибкой.
#                   Откат: --rollback (qm stop + qm destroy).
# Автор: it-toolkit, 2026

set -euo pipefail

STORAGE="${STORAGE:-nvme-fast}"
BRIDGE="${BRIDGE:-vmbr-itk}"
GATEWAY="${GATEWAY:-10.99.0.1}"
DNS="${DNS:-1.1.1.1}"
CLOUD_IMG="${CLOUD_IMG:-/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img}"
SSH_KEY="${SSH_KEY:-/root/.ssh/id_itk_deploy.pub}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
TEMPLATE_NAME="ubuntu-24.04-cloudinit-template"

# имя:VMID:RAM(MB):cores:disk(GB):IP/cidr:тип
# тип: linux | windows-stub
VMS=(
    "zbx-lab:122:2048:2:16:10.99.0.10/24:linux"
    "itk-worker:123:1024:2:8:10.99.0.11/24:linux"
    "test-linux:124:512:1:4:10.99.0.20/24:linux"
    "test-windows:125:4096:2:32:10.99.0.21/24:windows-stub"
    "test-printer:127:256:1:2:10.99.0.40/24:linux"
)

usage() {
    cat <<EOF
Использование: $0 [--apply | --rollback | --status | --dry-run] [--only=VMID]

  --apply         создать template (если нет) и все VM
  --rollback      остановить и удалить ВСЕ наши VM (не template — он остаётся)
  --status        показать состояние template и каждой VM
  --dry-run       показать план без изменений
  --only=VMID     ограничиться одной VM (с любой командой)
  --help          эта справка

Окружение:
  STORAGE         zfs/dir-pool для дисков (по умолчанию: nvme-fast)
  BRIDGE          сетевой bridge (по умолчанию: vmbr-itk)
  CLOUD_IMG       путь к cloud-image (по умолчанию: noble-server-cloudimg-amd64.img)
  SSH_KEY         публичный ключ для cloud-init (по умолчанию: /root/.ssh/id_itk_deploy.pub)
EOF
}

require_root() {
    [[ $EUID -eq 0 ]] || { echo "ERROR: запускать под root" >&2; exit 1; }
}

require_proxmox() {
    command -v qm >/dev/null 2>&1 || { echo "ERROR: нет qm — это не Proxmox-узел" >&2; exit 1; }
    command -v pvesm >/dev/null 2>&1 || { echo "ERROR: нет pvesm" >&2; exit 1; }
}

require_files() {
    [[ -f "$CLOUD_IMG" ]] || { echo "ERROR: нет $CLOUD_IMG" >&2; exit 1; }
    [[ -f "$SSH_KEY" ]] || { echo "ERROR: нет $SSH_KEY" >&2; exit 1; }
}

require_bridge() {
    ip link show "$BRIDGE" >/dev/null 2>&1 \
        || { echo "ERROR: bridge $BRIDGE не существует. Запусти lab-network.sh сначала." >&2; exit 1; }
}

vm_exists() {
    qm status "$1" >/dev/null 2>&1
}

vm_running() {
    qm status "$1" 2>/dev/null | grep -q "status: running"
}

# Возвращает 0 если VM создана нашим скриптом (по описанию), 1 иначе
vm_is_ours() {
    local vmid="$1"
    qm config "$vmid" 2>/dev/null | grep -q "description.*itk-monitoring" || return 1
}

create_template() {
    if vm_exists "$TEMPLATE_VMID"; then
        echo "Template VM $TEMPLATE_VMID уже существует — пропускаю создание"
        return 0
    fi
    echo "Создаю template VM $TEMPLATE_VMID из $CLOUD_IMG..."
    qm create "$TEMPLATE_VMID" \
        --name "$TEMPLATE_NAME" \
        --memory 1024 \
        --cores 1 \
        --net0 "virtio,bridge=$BRIDGE" \
        --description "itk-monitoring: cloud-init template, не запускать"

    qm importdisk "$TEMPLATE_VMID" "$CLOUD_IMG" "$STORAGE" --format raw

    # подключаем диск как scsi0
    qm set "$TEMPLATE_VMID" --scsihw virtio-scsi-pci \
        --scsi0 "$STORAGE:vm-$TEMPLATE_VMID-disk-0,discard=on"

    # cloud-init drive
    qm set "$TEMPLATE_VMID" --ide2 "$STORAGE:cloudinit"

    # boot order и serial console (нужно для cloud-image)
    qm set "$TEMPLATE_VMID" --boot c --bootdisk scsi0
    qm set "$TEMPLATE_VMID" --serial0 socket --vga serial0

    # делаем шаблоном (не запускается, только клонится)
    qm template "$TEMPLATE_VMID"
    echo "✓ Template $TEMPLATE_VMID создан"
}

create_vm_linux() {
    local name="$1" vmid="$2" mem="$3" cores="$4" disk="$5" ipcidr="$6"

    if vm_exists "$vmid"; then
        if vm_is_ours "$vmid"; then
            echo "  VM $vmid ($name) уже наша — пропускаю"
            return 0
        else
            echo "  ERROR: VM $vmid существует и НЕ принадлежит нам. Останавливаюсь." >&2
            qm config "$vmid" | head -5 >&2
            return 1
        fi
    fi

    echo "  Клонирую template $TEMPLATE_VMID → $vmid ($name)..."
    qm clone "$TEMPLATE_VMID" "$vmid" --name "$name" --full --storage "$STORAGE"

    # cloud-init: пользователь, ключ, IP, DNS
    local ssh_key_content
    ssh_key_content=$(cat "$SSH_KEY")

    qm set "$vmid" \
        --memory "$mem" \
        --cores "$cores" \
        --description "itk-monitoring: $name (lab PoC)" \
        --ciuser itk \
        --sshkey "$SSH_KEY" \
        --ipconfig0 "ip=$ipcidr,gw=$GATEWAY" \
        --nameserver "$DNS"

    # увеличиваем диск до нужного размера
    qm resize "$vmid" scsi0 "${disk}G" 2>/dev/null || true

    qm start "$vmid"
    echo "  ✓ VM $vmid запущен"
}

create_vm_windows_stub() {
    local name="$1" vmid="$2" mem="$3" cores="$4" disk="$5"

    if vm_exists "$vmid"; then
        if vm_is_ours "$vmid"; then
            echo "  VM $vmid ($name) уже наша — пропускаю"
            return 0
        else
            echo "  ERROR: VM $vmid существует и НЕ принадлежит нам. Останавливаюсь." >&2
            return 1
        fi
    fi

    echo "  Создаю заготовку VM $vmid ($name) для Windows (без ОС)..."
    qm create "$vmid" \
        --name "$name" \
        --memory "$mem" \
        --cores "$cores" \
        --ostype win11 \
        --scsihw virtio-scsi-pci \
        --scsi0 "$STORAGE:$disk,discard=on,iothread=1" \
        --net0 "virtio,bridge=$BRIDGE" \
        --bios ovmf \
        --machine q35 \
        --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=1" \
        --tpmstate0 "$STORAGE:1,version=v2.0" \
        --description "itk-monitoring: $name (lab PoC, ждёт ISO для установки)"
    echo "  ✓ VM $vmid создан, не запущен"
    echo "    Когда будет ISO: qm set $vmid --ide2 local:iso/<windows>.iso,media=cdrom"
    echo "                     qm set $vmid --boot order='ide2;scsi0'"
    echo "                     qm start $vmid"
}

wait_ssh() {
    local ip="$1" name="$2"
    local max=60
    echo -n "  жду SSH на $ip ($name)"
    for i in $(seq 1 $max); do
        if nc -zw 2 "$ip" 22 2>/dev/null; then
            echo " — поднялся через ${i}с"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo " — таймаут ($max сек). Проверь руками: qm console $name"
    return 1
}

cmd_apply() {
    local only="${1:-}"
    require_root
    require_proxmox
    require_files
    require_bridge

    if [[ -z "$only" ]]; then
        create_template
    fi

    for entry in "${VMS[@]}"; do
        IFS=':' read -r name vmid mem cores disk ipcidr type <<< "$entry"
        if [[ -n "$only" && "$vmid" != "$only" ]]; then
            continue
        fi
        echo
        echo ">>> $name (VMID $vmid, тип $type)"
        case "$type" in
            linux) create_vm_linux "$name" "$vmid" "$mem" "$cores" "$disk" "$ipcidr" ;;
            windows-stub) create_vm_windows_stub "$name" "$vmid" "$mem" "$cores" "$disk" ;;
            *) echo "  unknown type: $type" >&2 ;;
        esac
    done

    echo
    echo "=== ожидание SSH на Linux-VM ==="
    for entry in "${VMS[@]}"; do
        IFS=':' read -r name vmid mem cores disk ipcidr type <<< "$entry"
        if [[ -n "$only" && "$vmid" != "$only" ]]; then continue; fi
        [[ "$type" == "linux" ]] || continue
        wait_ssh "${ipcidr%/*}" "$name" || true
    done

    echo
    echo "✓ apply завершён. Запусти --status для сводки."
}

cmd_rollback() {
    local only="${1:-}"
    require_root
    require_proxmox

    for entry in "${VMS[@]}"; do
        IFS=':' read -r name vmid mem cores disk ipcidr type <<< "$entry"
        if [[ -n "$only" && "$vmid" != "$only" ]]; then continue; fi

        if ! vm_exists "$vmid"; then
            echo "  $name (VMID $vmid) — не существует, пропускаю"
            continue
        fi
        if ! vm_is_ours "$vmid"; then
            echo "  $name (VMID $vmid) — не наша, ПРОПУСКАЮ. Удаляй вручную если нужно."
            continue
        fi

        echo "  Удаляю $name (VMID $vmid)..."
        if vm_running "$vmid"; then
            qm stop "$vmid" 2>/dev/null || qm shutdown "$vmid" --timeout 10 || true
            sleep 2
        fi
        qm destroy "$vmid" --purge --destroy-unreferenced-disks 1
        echo "  ✓ $name удалён"
    done

    if [[ -z "$only" ]]; then
        echo
        echo "Template VM $TEMPLATE_VMID не трогаю. Удали вручную если нужно: qm destroy $TEMPLATE_VMID --purge"
    fi
}

cmd_status() {
    echo "=== template ==="
    if vm_exists "$TEMPLATE_VMID"; then
        qm status "$TEMPLATE_VMID"
    else
        echo "template VM $TEMPLATE_VMID не существует"
    fi
    echo
    echo "=== VM лабы ==="
    printf "%-15s %-6s %-10s %-15s %-8s %s\n" "name" "vmid" "status" "ip" "ssh?" "ours?"
    for entry in "${VMS[@]}"; do
        IFS=':' read -r name vmid mem cores disk ipcidr type <<< "$entry"
        local status="missing" ssh_ok="-" ours="-"
        if vm_exists "$vmid"; then
            status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
            vm_is_ours "$vmid" && ours="yes" || ours="no"
            if [[ "$type" == "linux" && "$status" == "running" ]]; then
                nc -zw 1 "${ipcidr%/*}" 22 2>/dev/null && ssh_ok="yes" || ssh_ok="no"
            fi
        fi
        printf "%-15s %-6s %-10s %-15s %-8s %s\n" "$name" "$vmid" "$status" "${ipcidr%/*}" "$ssh_ok" "$ours"
    done
}

cmd_dry_run() {
    require_root
    echo "=== что было бы сделано ==="
    echo "Storage: $STORAGE"
    echo "Bridge:  $BRIDGE"
    echo "Image:   $CLOUD_IMG"
    echo "SSH key: $SSH_KEY"
    echo "Template: $TEMPLATE_VMID ($TEMPLATE_NAME)"
    echo
    if vm_exists "$TEMPLATE_VMID"; then
        echo "Template VM $TEMPLATE_VMID — уже существует, пропускаю создание"
    else
        echo "Создал бы template VM $TEMPLATE_VMID из $CLOUD_IMG"
    fi
    echo
    for entry in "${VMS[@]}"; do
        IFS=':' read -r name vmid mem cores disk ipcidr type <<< "$entry"
        echo "  $name (VMID $vmid, $type): $mem МБ RAM, $cores cores, $disk ГБ disk, IP $ipcidr"
        if vm_exists "$vmid"; then
            echo "    -> существует, пропустил бы"
        fi
    done
}

main() {
    local action="${1:---help}"
    local only=""
    shift || true
    for arg in "$@"; do
        case "$arg" in
            --only=*) only="${arg#--only=}" ;;
            *) ;;
        esac
    done

    case "$action" in
        --apply)    cmd_apply "$only" ;;
        --rollback) cmd_rollback "$only" ;;
        --status)   cmd_status ;;
        --dry-run)  cmd_dry_run ;;
        --help|-h)  usage ;;
        *) echo "ERROR: неизвестный аргумент: $action" >&2; usage; exit 1 ;;
    esac
}

main "$@"
