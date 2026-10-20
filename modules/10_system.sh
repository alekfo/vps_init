# modules/10_system.sh — базовая настройка системы.
# Базовые пакеты, обновление, часовой пояс, синхронизация времени, имя хоста,
# swap (по ENABLE_SWAP) и автообновления безопасности (по ENABLE_AUTO_UPGRADES).

MODULE_DESC="Система: пакеты, обновления, время, hostname, swap, автообновления"

# Нужны почти всем следующим модулям: скачивание, ключи репозиториев, распаковка, sudo
# (на минимальных образах Debian sudo может не быть).
BASE_PACKAGES=(ca-certificates curl wget gnupg unzip sudo)

module_run() {
  install_base_packages
  upgrade_packages
  setup_timezone
  setup_ntp
  setup_hostname
  setup_swap
  setup_auto_upgrades
  check_reboot_required
}

install_base_packages() {
  apt_update
  apt_install "${BASE_PACKAGES[@]}"
}

upgrade_packages() {
  if [[ "$APT_UPGRADE" != true ]]; then
    log_skip "Обновление пакетов отключено (APT_UPGRADE=false)"
    return 0
  fi
  # Пробный прогон (-s) ничего не меняет, только показывает, что будет установлено.
  # LC_ALL=C — чтобы вывод apt не зависел от языка системы.
  local count
  count="$(LC_ALL=C apt_get -s upgrade --with-new-pkgs | grep -c '^Inst ' || true)"
  if (( count == 0 )); then
    log_skip "Все пакеты уже обновлены"
    return 0
  fi
  # --with-new-pkgs: разрешает ставить новые зависимости (например, новое ядро),
  # но, в отличие от full-upgrade, никогда не удаляет установленные пакеты.
  run "Обновление пакетов ($count шт.)" apt_get upgrade -y --with-new-pkgs
}

setup_timezone() {
  if [[ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    log_warn "Неизвестный часовой пояс '$TIMEZONE' (список: timedatectl list-timezones)"
    return 0
  fi
  local current
  current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [[ "$current" == "$TIMEZONE" ]]; then
    log_skip "Часовой пояс уже $TIMEZONE"
    return 0
  fi
  run "Часовой пояс: ${current:-?} -> $TIMEZONE" timedatectl set-timezone "$TIMEZONE"
}

# Синхронизация часов по NTP. Обычно это делает systemd-timesyncd; если стоит chrony —
# он справляется сам, ничего не трогаем.
setup_ntp() {
  if pkg_installed chrony; then
    log_skip "Время синхронизирует chrony"
    return 0
  fi
  if [[ "$(timedatectl show -p NTP --value 2>/dev/null || true)" == yes ]]; then
    log_skip "Синхронизация времени (NTP) уже включена"
    return 0
  fi
  apt_install systemd-timesyncd
  run "Включение синхронизации времени (NTP)" timedatectl set-ntp true
}

setup_hostname() {
  if [[ -z "$NEW_HOSTNAME" ]]; then
    log_skip "Имя хоста не меняется (NEW_HOSTNAME пусто), сейчас: $(hostname)"
    return 0
  fi

  if [[ "$(hostname)" == "$NEW_HOSTNAME" ]]; then
    log_skip "Имя хоста уже $NEW_HOSTNAME"
  else
    run "Имя хоста: $(hostname) -> $NEW_HOSTNAME" hostnamectl set-hostname "$NEW_HOSTNAME"
  fi

  # Имя хоста должно резолвиться локально, иначе sudo пишет
  # "unable to resolve host ..." и тормозит. В Debian/Ubuntu для этого строка 127.0.1.1.
  local short="${NEW_HOSTNAME%%.*}" hosts_line
  if [[ "$short" == "$NEW_HOSTNAME" ]]; then
    hosts_line="127.0.1.1 $NEW_HOSTNAME"
  else
    hosts_line="127.0.1.1 $NEW_HOSTNAME $short"
  fi
  if grep -qxF "$hosts_line" /etc/hosts; then
    log_skip "/etc/hosts уже содержит $hosts_line"
  else
    backup_file /etc/hosts
    if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1[[:space:]].*/$hosts_line/" /etc/hosts
    else
      printf '%s\n' "$hosts_line" >>/etc/hosts
    fi
    log_ok "/etc/hosts: $hosts_line"
  fi

  # На облачных VPS cloud-init при каждой загрузке выставляет имя из панели хостинга
  # и перезаписывает /etc/hosts. Просим его больше этого не делать.
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    write_file /etc/cloud/cloud.cfg.d/99-vps-init-hostname.cfg <<'EOF'
# vps_init: имя хоста задано вручную, cloud-init не должен его менять.
preserve_hostname: true
manage_etc_hosts: false
EOF
  fi
}

setup_swap() {
  if [[ "$ENABLE_SWAP" != true ]]; then
    log_skip "Swap не настраивается (ENABLE_SWAP=false)"
    return 0
  fi

  local swap_mb
  swap_mb="$(awk '/^SwapTotal:/ { print int($2 / 1024) }' /proc/meminfo)"
  if (( swap_mb > 0 )); then
    log_skip "Swap уже есть: ${swap_mb} МБ"
  else
    create_swapfile /swapfile
  fi

  # swappiness — насколько охотно ядро выгружает память в swap (0–100, по умолчанию 60).
  # На сервере лучше держать данные в RAM и использовать swap только при нехватке.
  write_file /etc/sysctl.d/99-vps-init-swap.conf <<'EOF'
# vps_init: использовать swap только при реальной нехватке памяти.
vm.swappiness = 10
EOF
  if (( FILE_CHANGED )); then
    run "Применение vm.swappiness=10" sysctl -p /etc/sysctl.d/99-vps-init-swap.conf
  fi
}

create_swapfile() {
  local file="$1" size_mb free_mb
  size_mb="$(size_to_mb "$SWAP_SIZE")"
  free_mb="$(df -Pm / | awk 'NR == 2 { print $4 }')"
  if (( free_mb - size_mb < 1024 )); then
    log_warn "Swap $SWAP_SIZE не создан: на диске свободно только ${free_mb} МБ"
    return 0
  fi

  if [[ -e "$file" ]]; then
    log_warn "$file уже существует, но не подключён — проверьте вручную (swapon $file)"
    return 0
  fi

  # fallocate мгновенный, но работает не на всех файловых системах — тогда dd.
  if ! run "Создание $file ($SWAP_SIZE)" fallocate -l "${size_mb}M" "$file"; then
    rm -f "$file"
    run "Создание $file через dd ($SWAP_SIZE)" dd if=/dev/zero of="$file" bs=1M count="$size_mb"
  fi
  chmod 600 "$file"
  run "Разметка swap" mkswap "$file"
  run "Подключение swap" swapon "$file"
  ensure_line /etc/fstab "$file none swap sw 0 0"
  log_ok "Swap $file подключится и после перезагрузки (/etc/fstab)"
}

# "2G" -> 2048, "512M" -> 512
size_to_mb() {
  local num="${1%[MmGg]}"
  case "$1" in
    *[Gg]) echo $((num * 1024)) ;;
    *) echo "$num" ;;
  esac
}

# unattended-upgrades — ежедневная автоматическая установка обновлений безопасности.
setup_auto_upgrades() {
  if [[ "$ENABLE_AUTO_UPGRADES" != true ]]; then
    # Выключать не будем: на Ubuntu они включены с завода, и это хорошо.
    if pkg_installed unattended-upgrades; then
      log_skip "Автообновления не настраиваются (ENABLE_AUTO_UPGRADES=false); unattended-upgrades уже установлен системой"
    else
      log_skip "Автообновления не настраиваются (ENABLE_AUTO_UPGRADES=false)"
    fi
    return 0
  fi

  apt_install unattended-upgrades
  # Что именно обновлять (только security) — в 50unattended-upgrades из пакета, его не трогаем.
  # Автоматическая перезагрузка там выключена по умолчанию.
  write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// vps_init: ежедневно обновлять списки пакетов и ставить обновления безопасности.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
}

check_reboot_required() {
  if [[ -f /var/run/reboot-required ]]; then
    log_warn "После обновления нужна перезагрузка (новое ядро или системные библиотеки)"
    log_note "Перезагрузите сервер, когда закончите проверку: sudo reboot"
  fi
}
