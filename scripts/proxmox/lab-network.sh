#!/usr/bin/env bash
# Назначение:    создать/удалить изолированный Linux bridge vmbr-itk на узле Proxmox.
# Режимы:
#   --apply              bridge без интернета
#   --apply --with-nat   bridge + NAT через vmbr0 + REJECT (FORWARD+INPUT) для прод-сети
#   --rollback / --status / --dry-run
# Идемпотентность: безопасно запускать повторно
# Опасные операции: правит /etc/network/interfaces, делает бэкап. Откат: --rollback
# Автор: it-toolkit, 2026

set -euo pipefail

BRIDGE_NAME="${BRIDGE_NAME:-vmbr-itk}"
BRIDGE_CIDR="${BRIDGE_CIDR:-10.99.0.1/24}"
BRIDGE_NET="${BRIDGE_NET:-10.99.0.0/24}"
WAN_BRIDGE="${WAN_BRIDGE:-vmbr0}"
PROD_NET="${PROD_NET:-10.0.0.0/24}"
HOST_PROD_IP="${HOST_PROD_IP:-10.0.0.1}"

INTERFACES_FILE="/etc/network/interfaces"
BACKUP_DIR="/root/itk-backups"
MARKER="# itk-monitoring: managed bridge"
END_MARKER="# itk-monitoring: end"

usage() {
    cat <<EOF
Использование: $0 [--apply | --apply --with-nat | --rollback | --status | --dry-run [--with-nat]]

  --apply              создать $BRIDGE_NAME ($BRIDGE_CIDR), без интернета
  --apply --with-nat   то же + NAT через $WAN_BRIDGE + REJECT (FORWARD+INPUT) для $PROD_NET
  --rollback           удалить наш блок + соответствующие правила iptables
  --status             текущее состояние bridge и правил
  --dry-run            показать план без изменений (можно с --with-nat)
  --help               эта справка

Окружение:
  BRIDGE_NAME=$BRIDGE_NAME
  BRIDGE_CIDR=$BRIDGE_CIDR
  BRIDGE_NET=$BRIDGE_NET
  WAN_BRIDGE=$WAN_BRIDGE
  PROD_NET=$PROD_NET
  HOST_PROD_IP=$HOST_PROD_IP
EOF
}

require_root() { [[ $EUID -eq 0 ]] || { echo "ERROR: запускать под root" >&2; exit 1; }; }
require_proxmox() {
    command -v ifreload >/dev/null 2>&1 || { echo "ERROR: нет ifreload (ifupdown2)" >&2; exit 1; }
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

block_present() { grep -q "^$MARKER\$" "$INTERFACES_FILE" 2>/dev/null; }
bridge_up()     { ip link show "$BRIDGE_NAME" >/dev/null 2>&1; }

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
    # forwarding точечно на этом интерфейсе
    post-up sysctl -w net.ipv4.conf.\$IFACE.forwarding=1 >/dev/null
    post-down sysctl -w net.ipv4.conf.\$IFACE.forwarding=0 >/dev/null
    # NAT в интернет через $WAN_BRIDGE
    post-up iptables -t nat -C POSTROUTING -s '$BRIDGE_NET' -o $WAN_BRIDGE -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s '$BRIDGE_NET' -o $WAN_BRIDGE -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '$BRIDGE_NET' -o $WAN_BRIDGE -j MASQUERADE 2>/dev/null || true
    # ИЗОЛЯЦИЯ FORWARD: запрет маршрутизации в прод-сеть $PROD_NET
    post-up iptables -C FORWARD -s '$BRIDGE_NET' -d '$PROD_NET' -j REJECT 2>/dev/null || iptables -I FORWARD 1 -s '$BRIDGE_NET' -d '$PROD_NET' -j REJECT
    post-up iptables -C FORWARD -s '$PROD_NET' -d '$BRIDGE_NET' -j REJECT 2>/dev/null || iptables -I FORWARD 1 -s '$PROD_NET' -d '$BRIDGE_NET' -j REJECT
    post-down iptables -D FORWARD -s '$BRIDGE_NET' -d '$PROD_NET' -j REJECT 2>/dev/null || true
    post-down iptables -D FORWARD -s '$PROD_NET' -d '$BRIDGE_NET' -j REJECT 2>/dev/null || true
    # ИЗОЛЯЦИЯ INPUT: запрет доступа от $BRIDGE_NET к самому узлу через $HOST_PROD_IP
    post-up iptables -C INPUT -s '$BRIDGE_NET' -d '$HOST_PROD_IP' -j REJECT 2>/dev/null || iptables -I INPUT 1 -s '$BRIDGE_NET' -d '$HOST_PROD_IP' -j REJECT
    post-down iptables -D INPUT -s '$BRIDGE_NET' -d '$HOST_PROD_IP' -j REJECT 2>/dev/null || true
EOF
    fi
    cat <<EOF
#   Изолированный bridge для PoC автомониторинга.
$END_MARKER
EOF
}

remove_block() {
    awk -v start="$MARKER" -v end="$END_MARKER" '
        $0 == start { skip=1; next }
        skip && $0 == end { skip=0; next }
        !skip { print }
    ' "$INTERFACES_FILE" > "$INTERFACES_FILE.new"
    mv "$INTERFACES_FILE.new" "$INTERFACES_FILE"
}

cleanup_iptables() {
    iptables -t nat -D POSTROUTING -s "$BRIDGE_NET" -o "$WAN_BRIDGE" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "$BRIDGE_NET" -d "$PROD_NET" -j REJECT 2>/dev/null || true
    iptables -D FORWARD -s "$PROD_NET" -d "$BRIDGE_NET" -j REJECT 2>/dev/null || true
    iptables -D INPUT -s "$BRIDGE_NET" -d "$HOST_PROD_IP" -j REJECT 2>/dev/null || true
}

cmd_status() {
    echo "=== bridge $BRIDGE_NAME ==="
    if bridge_up; then
        ip -br a show "$BRIDGE_NAME"
        echo
        echo "=== forwarding ==="
        sysctl "net.ipv4.conf.$BRIDGE_NAME.forwarding" 2>/dev/null || echo "(не удалось прочитать)"
    else
        echo "bridge $BRIDGE_NAME НЕ существует"
    fi
    echo
    echo "=== iptables NAT ==="
    iptables -t nat -L POSTROUTING -n -v | grep -E "$BRIDGE_NET" || echo "(нет правил)"
    echo
    echo "=== iptables FORWARD ==="
    iptables -L FORWARD -n -v | grep -E "$BRIDGE_NET|$PROD_NET" | head -10 || echo "(нет правил)"
    echo
    echo "=== iptables INPUT ==="
    iptables -L INPUT -n -v | grep -E "$BRIDGE_NET.*$HOST_PROD_IP" || echo "(нет правил)"
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
        echo "Блок уже есть — переписываю"
        remove_block
        cleanup_iptables
    fi

    local backup
    backup=$(backup_interfaces)
    echo "Бэкап: $backup"

    generate_block "$with_nat" >> "$INTERFACES_FILE"
    echo "Записан блок (with_nat=$with_nat)"

    echo "Валидация..."
    if ! ifup --no-act "$BRIDGE_NAME" >/dev/null 2>&1; then
        echo "ERROR: ifup --no-act $BRIDGE_NAME упал. Откатываю." >&2
        remove_block
        exit 1
    fi
    echo "OK"

    echo "Применяю ifreload..."
    ifreload -a

    sleep 1
    if bridge_up; then
        echo "✓ bridge $BRIDGE_NAME поднят:"
        ip -br a show "$BRIDGE_NAME"
        if [[ "$with_nat" == "yes" ]]; then
            echo
            echo "Правила:"
            iptables -t nat -L POSTROUTING -n -v | grep -E "$BRIDGE_NET" | head -2
            iptables -L FORWARD -n -v | grep -E "$BRIDGE_NET|$PROD_NET" | head -4
            iptables -L INPUT -n -v | grep -E "$BRIDGE_NET.*$HOST_PROD_IP" | head -2
        fi
    else
        echo "ERROR: bridge не появился" >&2
        exit 1
    fi
}

cmd_rollback() {
    require_root
    if ! block_present && ! bridge_up; then
        echo "Нечего откатывать."
        cleanup_iptables
        exit 0
    fi
    local backup
    backup=$(backup_interfaces)
    echo "Бэкап: $backup"
    if bridge_up; then
        ifdown "$BRIDGE_NAME" 2>/dev/null || ip link set "$BRIDGE_NAME" down 2>/dev/null || true
    fi
    if block_present; then
        remove_block
        echo "Блок удалён"
    fi
    cleanup_iptables
    ifreload -a
    if bridge_up; then
        echo "WARNING: bridge ещё жив — удаляю"
        ip link delete "$BRIDGE_NAME" || true
    fi
    bridge_up && { echo "ERROR: не удалось снести" >&2; exit 1; }
    echo "✓ bridge удалён, правила очищены"
}

cmd_dry_run() {
    local with_nat="${1:-no}"
    require_root
    echo "=== план (with_nat=$with_nat) ==="
    block_present && echo "Блок уже есть — был бы переписан"
    echo "Был бы добавлен блок:"
    generate_block "$with_nat"
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
        *) echo "ERROR: неизвестный аргумент: $action" >&2; usage; exit 1 ;;
    esac
}

main "$@"
