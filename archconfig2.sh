#!/usr/bin/env bash

# Etap instalacji pakietów po pierwszym uruchomieniu.

set -euo pipefail

ENV_FILE="./archinstaller.env"
BASE_URL="https://it.mattromanow.com/downloads/arch"

echo -e "\033[36m<<<<<===== Etap 2: pakiety systemu roboczego =====>>>>>\033[0m"

if [[ "$(id -un)" != "matt" ]]; then
    echo -e "\033[31mTen etap uruchom jako użytkownik matt\033[0m"
    exit 1
fi

if [[ "$(pwd)" != "/home/matt" ]]; then
    echo -e "\033[31mTen etap uruchom z katalogu /home/matt\033[0m"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "\033[31mBrak pliku stanu: ${ENV_FILE}\033[0m"
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

require_env_variable() {
    local variable_name="$1"

    if [[ ! -v "$variable_name" ]]; then
        echo -e "\033[31mBrak wymaganej zmiennej ${variable_name} w ${ENV_FILE}\033[0m"
        exit 1
    fi
}

validate_runtime_profile() {
    local package_value
    local variable_name

    for variable_name in \
        ARCHINSTALLER_ENV_VERSION \
        MACHINE_PROFILE_SCHEMA_VERSION \
        MACHINE_PROFILE_ID \
        MACHINE_LABEL \
        DMI_PRODUCT_PREFIX \
        CPU_VENDOR_ID \
        CPU_MODEL_MATCH \
        TARGET_DISK \
        TARGET_DISK_MODEL \
        TARGET_DISK_TRANSPORT \
        ESP_PART \
        CRYPT_PART \
        CPU_UCODE_PACKAGE \
        STORAGE_TOOL_PACKAGE \
        VULKAN_PACKAGE \
        VIDEO_ACCEL_PACKAGE \
        ENABLE_RTS522A_PM_FIX; do
        require_env_variable "$variable_name"
    done

    if [[ "$ARCHINSTALLER_ENV_VERSION" != "2" ||
          "$MACHINE_PROFILE_SCHEMA_VERSION" != "1" ||
          ! "$MACHINE_PROFILE_ID" =~ ^[a-z0-9][a-z0-9_]*$ ||
          -z "$MACHINE_LABEL" ||
          -z "$DMI_PRODUCT_PREFIX" ||
          -z "$CPU_VENDOR_ID" ||
          -z "$CPU_MODEL_MATCH" ||
          "$TARGET_DISK" != /dev/* ||
          -z "$TARGET_DISK_MODEL" ||
          ! "$TARGET_DISK_TRANSPORT" =~ ^[a-z0-9_-]+$ ||
          "$ESP_PART" != "$TARGET_DISK"* ||
          "$CRYPT_PART" != "$TARGET_DISK"* ||
          "$ESP_PART" == "$CRYPT_PART" ||
          ! "$ENABLE_RTS522A_PM_FIX" =~ ^[01]$ ]]; then
        echo -e "\033[31mNiespójny kontrakt profilu w ${ENV_FILE}\033[0m"
        exit 1
    fi

    for package_value in \
        "$CPU_UCODE_PACKAGE" \
        "$STORAGE_TOOL_PACKAGE" \
        "$VULKAN_PACKAGE" \
        "$VIDEO_ACCEL_PACKAGE"; do
        if [[ -n "$package_value" && ! "$package_value" =~ ^[a-z0-9@._+-]+$ ]]; then
            echo -e "\033[31mNiepoprawna nazwa pakietu w ${ENV_FILE}: ${package_value}\033[0m"
            exit 1
        fi
    done
    if [[ -z "$CPU_UCODE_PACKAGE" || -z "$VULKAN_PACKAGE" ]]; then
        echo -e "\033[31mProfil nie zawiera wymaganego mikrocode lub sterownika Vulkan.\033[0m"
        exit 1
    fi

    readonly ARCHINSTALLER_ENV_VERSION MACHINE_PROFILE_SCHEMA_VERSION
    readonly MACHINE_PROFILE_ID MACHINE_LABEL DMI_PRODUCT_PREFIX
    readonly CPU_VENDOR_ID CPU_MODEL_MATCH TARGET_DISK TARGET_DISK_MODEL
    readonly TARGET_DISK_TRANSPORT ESP_PART CRYPT_PART CPU_UCODE_PACKAGE
    readonly STORAGE_TOOL_PACKAGE VULKAN_PACKAGE VIDEO_ACCEL_PACKAGE
    readonly ENABLE_RTS522A_PM_FIX
}

validate_runtime_profile

INSTALL_LOG_NAME="${INSTALL_LOG_NAME:-archinstaller-install.log}"
INSTALL_LOG_FILE="${HOME}/${INSTALL_LOG_NAME}"
LOG_STAGE="archconfig2"

init_install_log() {
    mkdir -p "$(dirname "$INSTALL_LOG_FILE")"
    touch "$INSTALL_LOG_FILE"
    chmod 600 "$INSTALL_LOG_FILE"
    exec 3>&1
    exec > >(process_log_stream) 2>&1
}

sanitize_log_value() {
    local value="${1:-}"
    value=${value//$'\n'/ }
    value=${value//$'\r'/ }
    value=${value//$'\t'/ }
    value=${value//|/-}
    printf '%s' "$value"
}

format_log_record() {
    local kind="$1"
    local event="$2"
    local message="${3:-}"
    printf 'LOG|ts=%s|stage=%s|kind=%s|event=%s|msg=%s' \
        "$(date '+%F %T')" \
        "$LOG_STAGE" \
        "$(sanitize_log_value "$kind")" \
        "$(sanitize_log_value "$event")" \
        "$(sanitize_log_value "$message")"
}

format_stream_record() {
    local message="${1:-}"
    printf 'STREAM|ts=%s|stage=%s|msg=%s' \
        "$(date '+%F %T')" \
        "$LOG_STAGE" \
        "$(sanitize_log_value "$message")"
}

process_log_stream() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line" >&3
        printf '%s\n' "$(format_stream_record "$line")" >> "$INSTALL_LOG_FILE"
    done
}

run_with_visible_output_and_log() {
    local stream_log
    local cmd_string
    local rc

    stream_log="$(mktemp)"
    printf -v cmd_string '%q ' "$@"
    if script -qefc "$cmd_string" /dev/null | tee >(tr '\r' '\n' > "$stream_log") >&3; then
        rc=0
    else
        rc=${PIPESTATUS[0]}
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        printf '%s\n' "$(format_stream_record "$line")" >> "$INSTALL_LOG_FILE"
    done < "$stream_log"

    rm -f "$stream_log"
    return "$rc"
}

log_line() {
    local kind="$1"
    local event="$2"
    local message="${3:-}"
    printf '%s\n' "$(format_log_record "$kind" "$event" "$message")" >> "$INSTALL_LOG_FILE"
}

log_section() {
    log_line "SECTION" "SECTION_START" "$1"
}

log_info() {
    log_line "INFO" "INFO" "$1"
}

log_input_expected() {
    local message="$1"
    log_line "INPUT" "INPUT_EXPECTED" "$message"
}

log_input_confirmed() {
    local message="$1"
    log_line "INPUT" "INPUT_CONFIRMED" "$message"
}

press_enter_to_continue() {
    local expectation="$1"
    local prompt_label="$2"
    log_input_expected "$expectation"
    read -r -p "$prompt_label" _
    echo
    log_input_confirmed "$expectation"
}

audit_checkpoint() {
    local checkpoint_name="$1"
    echo
    echo "----- Checkpoint -----"
    echo "${checkpoint_name}"
    echo "Jeśli wszystko wygląda poprawnie, naciśnij Enter."
    log_line "CHECKPOINT" "CHECKPOINT_REACHED" "$checkpoint_name"
    press_enter_to_continue \
        "operator ma zatwierdzić checkpoint enterem: ${checkpoint_name}" \
        "Naciśnij Enter, aby kontynuować: "
    log_line "CHECKPOINT" "CHECKPOINT_CONFIRMED" "$checkpoint_name"
}

run_logged() {
    log_line "CMD" "CMD_START" "$*"
    if run_with_visible_output_and_log "$@"; then
        log_line "CMD" "CMD_OK" "$1"
    else
        local rc=$?
        log_line "CMD" "CMD_FAIL" "$1 rc=${rc}"
        return "$rc"
    fi
}

announce_sudo_pacman_transaction() {
    local description="$1"
    echo "Za chwilę rozpocznie się: ${description}"
    echo "Sudo może najpierw poprosić o hasło użytkownika matt. To jest oczekiwane."
    echo "Jeśli zobaczysz ':: Proceed with installation? [Y/n]', naciśnij Enter, aby kontynuować."
    echo "Gdy pojawi się ':: Retrieving packages...' albo lista pobieranych pakietów, nic już nie wpisuj."
    log_input_expected "operator może podać hasło sudo i zatwierdzić prompt pacman enterem podczas: ${description}"
}

retry_logged_until_success() {
    local description="$1"
    shift

    until run_logged "$@"; do
        local rc=$?
        log_line "RETRY" "RETRY_FAIL" "${description} rc=${rc}"
        echo -e "\033[31m${description} nie powiodła się. Spróbuj ponownie albo przerwij Ctrl+C.\033[0m"
        press_enter_to_continue \
            "operator ma zatwierdzić ponowną próbę po błędzie: ${description}" \
            "Naciśnij Enter, aby ponowić próbę: "
    done
}

install_pacman_group() {
    local description="$1"
    shift

    echo -e "\033[36m<<<<<===== ${description} =====>>>>>\033[0m"
    announce_sudo_pacman_transaction "$description"
    echo "Postęp pobierania i instalacji pakietów będzie widoczny na ekranie."
    retry_logged_until_success "$description" \
        sudo pacman -Syu --needed "$@"
}

init_install_log
printf 'META|ts=%s|stage=%s|format=archinstaller-log-v1|location=%s\n' "$(date '+%F %T')" "$LOG_STAGE" "$INSTALL_LOG_FILE" >> "$INSTALL_LOG_FILE"
log_section "Start archconfig2.sh"
log_info "Log instalacyjny: ${INSTALL_LOG_FILE}"
log_info "Profil laptopa: ${MACHINE_PROFILE_ID} (${MACHINE_LABEL})"

echo -e "\033[36m<<<<<===== Błędy po pierwszym uruchomieniu =====>>>>>\033[0m"
journalctl -p 3 -xb || true
systemctl --failed || true
audit_checkpoint "ocena pierwszego bootu przed instalacją pakietów etapu 2"

SYSTEM_HARDWARE_PACKAGES=(
    acpi apparmor brightnessctl cameractrls clamav firejail fprintd fwupd
    gptfdisk linux-headers sof-firmware tlp udisks2 ufw upower
)
if [[ -n "$STORAGE_TOOL_PACKAGE" ]]; then
    SYSTEM_HARDWARE_PACKAGES+=("$STORAGE_TOOL_PACKAGE")
fi

WAYLAND_PACKAGES=(
    adwaita-icon-theme cantarell-fonts dunst fontconfig gnu-free-fonts greetd
    grim kitty kwallet kwalletmanager libnotify libsecret mesa noto-fonts
    noto-fonts-emoji otf-font-awesome polkit-gnome powerline-fonts qt5-tools
    qt6-wayland rofi slurp swappy sway swaybg swayidle swaylock
    ttf-jetbrains-mono waybar ttf-jetbrains-mono-nerd wayland-protocols
    wdisplays wev wl-clipboard xdg-desktop-portal xdg-desktop-portal-gtk
    xdg-desktop-portal-wlr xorg-xwayland
    "$VULKAN_PACKAGE"
)
if [[ -n "$VIDEO_ACCEL_PACKAGE" ]]; then
    WAYLAND_PACKAGES+=("$VIDEO_ACCEL_PACKAGE")
fi

install_pacman_group "System, sprzęt i bezpieczeństwo" \
    "${SYSTEM_HARDWARE_PACKAGES[@]}"

install_pacman_group "Sieć, Bluetooth i audio" \
    alsa-ucm-conf alsa-utils blueman bluez bluez-utils network-manager-applet \
    networkmanager-openvpn nm-connection-editor openssh openvpn pavucontrol \
    pipewire pipewire-alsa pipewire-audio pipewire-jack pipewire-pulse rtkit wireplumber

install_pacman_group "Wayland, Sway, portale i keyring" \
    "${WAYLAND_PACKAGES[@]}"

install_pacman_group "Narzędzia CLI, administracja i development" \
    android-tools ansible asciidoctor atftp cmake direnv fastfetch fd fnm git glow go htop \
    hunspell hunspell-pl man-db man-pages nmap npm perl-image-exiftool python-pip \
    python-qdarkstyle qrencode reflector ripgrep rsync shellcheck speedtest-cli task \
    terraform tigervnc tmux tor unzip wget yt-dlp zip zsh

install_pacman_group "Aplikacje użytkowe, biurowe i multimedialne" \
    android-file-transfer baobab calibre chromium darktable drawio-desktop electrum \
    filezilla firefox font-manager galculator gimp imagemagick imv inkscape \
    libreoffice-fresh mermaid-cli monero-gui mpv ntfs-3g ntfsprogs obs-studio openslide \
    pdfarranger phototonic proton-vpn-gtk-app python-adblock qt6-multimedia-ffmpeg qutebrowser \
    ranger rpi-imager seahorse shotcut \
    signal-desktop thunderbird thunar vlc xdg-user-dirs xed zathura-pdf-poppler

install_pacman_group "Usługi, synchronizacja i wirtualizacja" \
    docker ollama syncthing virtualbox virtualbox-host-dkms

echo -e "\033[36m<<<<<===== Włączenie AppArmor =====>>>>>\033[0m"
sudo systemctl enable apparmor.service

echo -e "\033[36m<<<<<===== Włączenie usług systemowych =====>>>>>\033[0m"
sudo systemctl enable --now bluetooth.service

if systemctl list-unit-files --no-legend power-profiles-daemon.service 2>/dev/null | grep -q '^power-profiles-daemon\.service'; then
    sudo systemctl disable --now power-profiles-daemon.service || true
fi

echo -e "\033[36m<<<<<===== UFW =====>>>>>\033[0m"
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo systemctl enable --now ufw.service
sudo ufw status verbose

echo -e "\033[36m<<<<<===== Pobranie skryptu archconfig3.sh =====>>>>>\033[0m"
curl -fLO "${BASE_URL}/archconfig3.sh"
chmod +x archconfig3.sh
rm -f ./archconfig2.sh
log_info "Przygotowano archconfig3.sh i zaktualizowano log instalacyjny"
audit_checkpoint "zamknięcie etapu 2 po AppArmor, usługach i pakietach przed rebootem"

echo
echo -e "\033[36m<<<<<===== Etap 2 zakończony =====>>>>>\033[0m"
echo "Po restarcie zaloguj się w TUI jako matt i uruchom: ./archconfig3.sh"
echo "Ten etap nie wykonuje restartu automatycznie."
echo "Teraz wykonaj ręcznie dokładnie:"
echo "  reboot"
log_input_expected "operator ma wykonać ręczny reboot po archconfig2.sh"
