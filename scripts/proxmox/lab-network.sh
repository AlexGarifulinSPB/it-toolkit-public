#!/usr/bin/env bash
# Назначение:    создать/удалить изолированный Linux bridge vmbr-itk на узле Proxmox
#                для PoC автомониторинга.
# Режимы:
#   обычный (--apply)       bridge без интернета (для злых тестов изоляции)
#   --with-nat              bridge + NAT через vmbr0 + REJECT в прод-сеть 10.0.0.0/24
# Использование: см. usage() ниже
# Требования:    Proxmox VE 7+, root, ifupdown2 (ifreload), iptables
# Идемпотентность: безопасно запускать повторно, не дублирует правила
# Опасные операции: правит /etc/network/interfaces. Делает бэкап перед записью.
#                   Откат: --rollback (сносит и блок, и правила NAT/FORWARD)
# Автор: it-toolkit, 2026

set -euo pipefail

BRIDGE_NAME="${BRIDGE_NAME:-vmbr-itk}"
BRIDGE_CIDR="${BRIDGE_CIDR:-10.99.0.1/24}"
BRIDGE_NET="${BRIDGE_NET:-10.99.0.0/24}"
WAN_BRIDGE="${WAN_BRIDGE:-vmbr0}"
PROD_NET="${PROD_NET:-10.0.0.0/24}"

INTERFACES_FILE="/etc/network/interfaces"
BACKUP_DIR="/root/itk-backups"
MARKER="# itk-monitoring: managed bridge"
END_MARKER="# itk-monitoring: end"

usage() {
    cat <<EOF
Использование: $0 [--apply | --apply --with-nat | --rollback | --status | --dry-run [--with-nat]]

  --apply              создать $BRIDGE_NAME ($BRIDGE_CIDR), без интернета
  --apply --with-nat   то же + NAT через $WAN_BRIDGE + REJECT в $PROD_NET
  --rollback           удалить наш блок + соответствующие правила iptables
  --status             текущее состояние bridge и правил
  --dry-run            показать план без изменений (можно с --with-nat)
  --help               эта справка

Переменные окружения:
  BRIDGE_NAME   имя bridge (по умолчанию: vmbr-itk)
  BRIDGE_CIDR   CIDR хоста (по умолчанию: 10.99.0.1/24)
  BRIDGE_NET    подсеть (по умолчанию: 10.99.0.0/24)
  WAN_BRIDGE    bridge для NAT (по умолчанию: vmbr0)
  PROD_NET      какую сеть блокировать на forward (по умолчанию: 10.0.0.0/24)
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
        echo "ERROR: не найден ifreload — нужен ifupdown2" >&2
        exit 1
    fi
    command -v iptables >/dev/null 2>&1 || { echo "ERROR: нет iptables" >&2; exit 1; }
}

backup_interfaces() {
    mkdir -p "$BACKUP_DIR"
    local stamp dest
    stamp=$(date +%Y%m%d-%H%M%S)
    dest="$BACKUP_DIR/interfaces.$stamp"
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
    local with_nat="$1"
    cat <<EOF

$MARKER
auto $BRIDGE_NAME
iface $BRIDGE_NAME inet static
    address $BRIDGE_CIDR
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
    if [[ "$with_nat" == "yes" ]]; then
        cat <<EOF
    # forwarding точечно (по образцу vmbr2 на этом узле)
    post-up sysctl -w net.ipv4.conf.\$IFACE.forwarding=1 >/dev/null
    post-down sysctl -w net.ipv4.conf.\$IFACE.forwarding=0 >/dev/null
    # NAT в интернет через $WAN_BRIDGE (с защитой от дублей: -C перед -A)
    post-up iptables -t nat -C POSTROUTING -s '$BRIDGE_NET' -o $WAN_BRIDGE -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s '$BRIDGE_NET' -o $WAN_BRIDGE -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '$BRIDGE_NET' -o $WAN_BRIDGE -j MASQUERADE 2>/dev/null || true
    # ИЗОЛЯЦИЯ: запрет forward в прод-сеть $PROD_NET (в обе стороны)
    post-up iptables -C FORWARD -s '$BRIDGE_NET' -d '$PROD_NET' -j REJECT 2>/dev/null || iptables -I FORWARD 1 -s '$BRIDGE_NET' -d '$PROD_NET' -j REJECT
    post-up iptables -C FORWARD -s '$PROD_NET' -d '$BRIDGE_NET' -j REJECT 2>/dev/null || iptables -I FORWARD 1 -s '$PROD_NET' -d '$BRIDGE_NET' -j REJECT
    post-down iptables -D FORWARD -s '$BRIDGE_NET' -d '$PROD_NET' -j REJECT 2>/dev/null || true
    post-down iptables -D FORWARD -s '$PROD_NET' -d '$BRIDGE_NET' -j REJECT 2>/dev/null || true
EOF
    fi
    cat <<EOF
#   Изолированный bridge для PoC автомониторинга.
#   $MARKER → $END_MARKER
$END_MARKER
EOF
}

remove_block() {
    # Удаляет всё между MARKER и END_MARKER включительно
    awk -v start="$MARKER" -v end="$END_MARKER" '
        $0 == start { skip=1; next }
        skip && $0 == end { skip=0; next }
        !skip { print }
    ' "$INTERFACES_FILE" > "$INTERFACES_FILE.new"
    mv "$INTERFACES_FILE.new" "$INTERFACES_FILE"
}

cleanup_iptables() {
    # На случай если ifdown post-down не отработал — гарантированная очистка
    iptables -t nat -D POSTROUTING -s "$BRIDGE_NET" -o "$WAN_BRIDGE" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "$BRIDGE_NET" -d "$PROD_NET" -j REJECT 2>/dev/null || true
    iptables -D FORWARD -s "$PROD_NET" -d "$BRIDGE_NET" -j REJECT 2>/dev/null || true
}

cmd_status() {
    echo "=== bridge $BRIDGE_NAME ==="
    if bridge_up; then
        ip -br a show "$BRIDGE_NAME"
        echo
        echo "=== forwarding на $BRIDGE_NAME ==="
        sysctl "net.ipv4.conf.${BRIDGE_NAME//-/\/}.forwarding" 2>/dev/null \
            || sysctl "net.ipv4.conf.$BRIDGE_NAME.forwarding" 2>/dev/null \
            || echo "(не удалось прочитать)"
    else
        echo "bridge $BRIDGE_NAME НЕ существует"
    fi
    echo
    echo "=== iptables NAT для $BRIDGE_NET ==="
    iptables -t nat -L POSTROUTING -n -v | grep -E "$BRIDGE_NET" || echo "(нет правил)"
    echo
    echo "=== iptables FORWARD (изоляция от $PROD_NET) ==="
    iptables -L FORWARD -n -v | grep -E "$BRIDGE_NET|$PROD_NET" | head -10 || echo "(нет правил)"
    echo
    echo "=== запись в $INTERFACES_FILE ==="
    if block_present; then
        echo "(управляется этим скриптом)"
        awk -v start="$MARKER" -v end="$END_MARKER" '
            $0 == start { p=1 }
            p { print }
            $0 == end { exit }
        ' "$INTERFACES_FILE"
    else
        echo "(нашего блока нет)"
    fi
}

cmd_apply() {
    local with_nat="${1:-no}"
    require_root
    require_proxmox

    if block_present; then
        echo "Блок $BRIDGE_NAME уже есть в $INTERFACES_FILE — удаляю старый, пишу свежий"
        remove_block
        cleanup_iptables
    fi

    local backup
    backup=$(backup_interfaces)
    echo "Бэкап: $backup"

    generate_block "$with_nat" >> "$INTERFACES_FILE"
    echo "Записан блок (with_nat=$with_nat) в $INTERFACES_FILE"

    echo "Валидация конфига..."
    if ! ifup --no-act "$BRIDGE_NAME" >/dev/null 2>&1; then
        echo "ERROR: ifup --no-act $BRIDGE_NAME упал. Откатываю." >&2
        remove_block
        echo "Восстановите из бэкапа $backup при необходимости." >&2
        exit 1
    fi
    echo "OK: конфиг валиден"

    echo "Применяю через ifreload..."
    ifreload -a

    sleep 1
    if bridge_up; then
        echo
        echo "✓ bridge $BRIDGE_NAME поднят:"
        ip -br a show "$BRIDGE_NAME"
        if [[ "$with_nat" == "yes" ]]; then
            echo
            echo "Проверка NAT:"
            iptables -t nat -L POSTROUTING -n -v | grep -E "$BRIDGE_NET" || echo "  WARNING: NAT-правило не нашлось"
            echo
            echo "Проверка FORWARD-блокировки в $PROD_NET:"
            iptables -L FORWARD -n -v | grep -E "$BRIDGE_NET.*$PROD_NET|$PROD_NET.*$BRIDGE_NET" \
                || echo "  WARNING: FORWARD-правил не нашлось"
        fi
    else
        echo "ERROR: bridge $BRIDGE_NAME не появился" >&2
        echo "  journalctl -u networking --since '1 min ago' | tail -50" >&2
        exit 1
    fi
}

cmd_rollback() {
    require_root

    if ! block_present && ! bridge_up; then
        echo "Нашего блока нет, bridge тоже отсутствует — нечего откатывать."
        cleanup_iptables  # на всякий случай
        exit 0
    fi

    local backup
    backup=$(backup_interfaces)
    echo "Бэкап перед откатом: $backup"

    if bridge_up; then
        ifdown "$BRIDGE_NAME" 2>/dev/null || ip link set "$BRIDGE_NAME" down 2>/dev/null || true
    fi

    if block_present; then
        remove_block
        echo "Блок удалён из $INTERFACES_FILE"
    fi

    cleanup_iptables
    ifreload -a

    if bridge_up; then
        echo "WARNING: bridge $BRIDGE_NAME ещё жив — удаляю принудительно"
        ip link delete "$BRIDGE_NAME" || true
    fi

    if bridge_up; then
        echo "ERROR: не удалось снести $BRIDGE_NAME, разбирайся руками" >&2
        exit 1
    fi
    echo "✓ bridge $BRIDGE_NAME удалён, правила NAT/FORWARD очищены"
}

cmd_dry_run() {
    local with_nat="${1:-no}"
    require_root
    echo "=== что было бы сделано (with_nat=$with_nat) ==="
    if block_present; then
        echo "Блок $BRIDGE_NAME уже в $INTERFACES_FILE — был бы переписан."
    fi
    echo "Был бы добавлен блок:"
    generate_block "$with_nat"
    echo
    echo "Команды, которые были бы вызваны:"
    echo "  ifup --no-act $BRIDGE_NAME      # валидация"
    echo "  ifreload -a                     # применение"
    if [[ "$with_nat" == "yes" ]]; then
        echo "  (post-up хуки сами добавят NAT и FORWARD-правила)"
    fi
}

main() {
    local action="${1:---apply}"
    local opt="${2:-}"
    local with_nat="no"
    [[ "$opt" == "--with-nat" || "$action" == "--with-nat" ]] && with_nat="yes"
    [[ "$action" == "--with-nat" ]] && action="--apply"

    case "$action" in
        --apply)    cmd_apply "$with_nat" ;;
        --rollback) cmd_rollback ;;
        --status)   cmd_status ;;
        --dry-run)  cmd_dry_run "$with_nat" ;;
        --help|-h)  usage ;;
        *)          echo "ERROR: неизвестный аргумент: $action" >&2; usage; exit 1 ;;
    esac
}

main "$@"
