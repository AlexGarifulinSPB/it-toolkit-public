#!/usr/bin/env bash
# Назначение:    создать/удалить изолированный Linux bridge vmbr-itk на узле Proxmox
#                для PoC автомониторинга. Без аплинка — VM на нём НЕ видят прод-сеть.
# Использование: см. usage() ниже
# Требования:    Proxmox VE 7+, root, ifupdown2 (`ifreload`)
# Идемпотентность: безопасно запускать повторно
# Опасные операции: правит /etc/network/interfaces. Делает бэкап перед записью.
#                   Откат: `lab-network.sh --rollback` (или вручную из бэкапа).
# Автор: it-toolkit, 2026

set -euo pipefail

BRIDGE_NAME="${BRIDGE_NAME:-vmbr-itk}"
BRIDGE_CIDR="${BRIDGE_CIDR:-10.99.0.1/24}"
INTERFACES_FILE="/etc/network/interfaces"
BACKUP_DIR="/root/itk-backups"
MARKER="# itk-monitoring: managed bridge"

usage() {
    cat <<EOF
Использование: $0 [--apply | --rollback | --status | --dry-run]

  --apply      создать $BRIDGE_NAME с CIDR $BRIDGE_CIDR (по умолчанию)
  --rollback   удалить наш блок из $INTERFACES_FILE и применить откат
  --status     показать текущее состояние bridge
  --dry-run    показать, что бы скрипт сделал, но не менять систему
  --help       эта справка

Переменные окружения:
  BRIDGE_NAME  имя bridge (по умолчанию: vmbr-itk)
  BRIDGE_CIDR  CIDR (по умолчанию: 10.99.0.1/24)
EOF
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: запускать под root" >&2
        exit 1
    fi
}

require_proxmox() {
    if ! command -v ifreload >/dev/null 2>&1; then
        echo "ERROR: не найден ifreload — нужен ifupdown2 (на Proxmox идёт из коробки)" >&2
        exit 1
    fi
    if ! command -v pveversion >/dev/null 2>&1; then
        echo "WARNING: это не похоже на узел Proxmox (нет pveversion). Продолжать? [y/N]"
        read -r yn
        [[ "$yn" =~ ^[Yy]$ ]] || exit 1
    fi
}

backup_interfaces() {
    mkdir -p "$BACKUP_DIR"
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    local dest="$BACKUP_DIR/interfaces.$stamp"
    cp "$INTERFACES_FILE" "$dest"
    echo "$dest"
}

block_present() {
    grep -q "^$MARKER\$" "$INTERFACES_FILE" 2>/dev/null
}

bridge_up() {
    ip link show "$BRIDGE_NAME" >/dev/null 2>&1
}

generate_block() {
    cat <<EOF

$MARKER
auto $BRIDGE_NAME
iface $BRIDGE_NAME inet static
    address $BRIDGE_CIDR
    bridge-ports none
    bridge-stp off
    bridge-fd 0
#   Изолированный bridge для PoC автомониторинга.
#   Без аплинка: VM на нём НЕ видят прод-сеть и интернет.
EOF
}

remove_block() {
    # удаляет блок от строки с MARKER до первой пустой строки или конца файла
    awk -v marker="$MARKER" '
        $0 == marker { skip=1; next }
        skip && /^$/ { skip=0; next }
        skip && /^[a-zA-Z]/ && !/^[[:space:]]/ { skip=0 }
        !skip { print }
    ' "$INTERFACES_FILE" > "$INTERFACES_FILE.new"
    mv "$INTERFACES_FILE.new" "$INTERFACES_FILE"
}

cmd_status() {
    echo "=== bridge $BRIDGE_NAME ==="
    if bridge_up; then
        ip -br a show "$BRIDGE_NAME"
        echo
        echo "=== ports ==="
        bridge link show 2>/dev/null | grep -F "master $BRIDGE_NAME" || echo "(нет подключённых портов — это норма для изолированного bridge)"
    else
        echo "bridge $BRIDGE_NAME НЕ существует"
    fi
    echo
    echo "=== запись в $INTERFACES_FILE ==="
    if block_present; then
        echo "(управляется этим скриптом)"
        awk -v marker="$MARKER" '
            $0 == marker { p=1 }
            p && /^$/ { exit }
            p { print }
        ' "$INTERFACES_FILE"
    else
        echo "(нашего блока нет)"
    fi
}

cmd_apply() {
    require_root
    require_proxmox

    if block_present; then
        echo "Блок $BRIDGE_NAME уже есть в $INTERFACES_FILE — пропускаю запись."
    else
        local backup
        backup=$(backup_interfaces)
        echo "Бэкап: $backup"

        generate_block >> "$INTERFACES_FILE"
        echo "Записан блок в $INTERFACES_FILE"
    fi

    # валидация ДО применения: ifup --no-act парсит, но не применяет
    echo "Валидация конфига..."
    if ! ifup --no-act "$BRIDGE_NAME" >/dev/null 2>&1; then
        echo "ERROR: ifup --no-act $BRIDGE_NAME упал. Откатываю изменения." >&2
        remove_block
        echo "Запусти --status и проверь, что система в порядке." >&2
        exit 1
    fi
    echo "OK: конфиг валиден"

    # применение
    echo "Применяю через ifreload..."
    ifreload -a

    # проверка результата
    sleep 1
    if bridge_up; then
        echo
        echo "✓ bridge $BRIDGE_NAME поднят:"
        ip -br a show "$BRIDGE_NAME"
        echo
        echo "Проверка с самого узла:"
        if ping -c 1 -W 2 "${BRIDGE_CIDR%/*}" >/dev/null 2>&1; then
            echo "  ping ${BRIDGE_CIDR%/*}: OK"
        else
            echo "  ping ${BRIDGE_CIDR%/*}: FAIL (странно, но bridge поднят — проверь руками)"
        fi
    else
        echo "ERROR: bridge $BRIDGE_NAME не появился после ifreload" >&2
        echo "Смотри: journalctl -u networking --since '1 min ago' | tail -50" >&2
        exit 1
    fi
}

cmd_rollback() {
    require_root

    if ! block_present; then
        echo "Нашего блока нет в $INTERFACES_FILE — нечего откатывать."
        if bridge_up; then
            echo "WARNING: bridge $BRIDGE_NAME существует, но управляется не нами. Не трогаю."
        fi
        exit 0
    fi

    local backup
    backup=$(backup_interfaces)
    echo "Бэкап перед откатом: $backup"

    # сначала опускаем интерфейс
    if bridge_up; then
        ifdown "$BRIDGE_NAME" 2>/dev/null || ip link set "$BRIDGE_NAME" down 2>/dev/null || true
    fi

    remove_block
    echo "Блок удалён из $INTERFACES_FILE"

    ifreload -a

    if bridge_up; then
        echo "WARNING: bridge $BRIDGE_NAME ещё жив после ifreload. Удаляю принудительно."
        ip link delete "$BRIDGE_NAME" || true
    fi

    if bridge_up; then
        echo "ERROR: не удалось снести $BRIDGE_NAME, разбирайся руками" >&2
        exit 1
    fi
    echo "✓ bridge $BRIDGE_NAME удалён"
}

cmd_dry_run() {
    require_root
    echo "=== что было бы сделано ==="
    if block_present; then
        echo "Блок $BRIDGE_NAME уже в $INTERFACES_FILE — apply пропустил бы запись."
    else
        echo "Был бы добавлен блок:"
        generate_block
    fi
    echo
    echo "Команды, которые были бы вызваны:"
    echo "  ifup --no-act $BRIDGE_NAME   # валидация"
    echo "  ifreload -a                  # применение"
    echo "  ip -br a show $BRIDGE_NAME   # проверка"
}

main() {
    local action="${1:---apply}"
    case "$action" in
        --apply)    cmd_apply ;;
        --rollback) cmd_rollback ;;
        --status)   cmd_status ;;
        --dry-run)  cmd_dry_run ;;
        --help|-h)  usage ;;
        *)          echo "ERROR: неизвестный аргумент: $action" >&2; usage; exit 1 ;;
    esac
}

main "$@"
