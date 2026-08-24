#!/usr/bin/env bash

# Etap konfiguracji w arch-chroot.

set -euo pipefail

ENV_FILE="/root/archinstaller.env"
INSTALL_USER="matt"
BASE_URL="https://it.mattromanow.com/downloads/arch"
KERNEL_CMDLINE_EXTRA="lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

retry_until_success() {
    local description="$1"
    shift

    until "$@"; do
        echo -e "\033[31m${description} nie powiodło się. Spróbuj ponownie albo przerwij Ctrl+C.\033[0m"
        read -r -p "Naciśnij Enter, aby ponowić próbę: "
        echo
    done
}

generate_recovery_key_output() {
    systemd-cryptenroll "$CRYPT_PART" --recovery-key > "$RECOVERY_OUTPUT_FILE" 2>&1
}

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
INSTALL_LOG_FILE="/root/${INSTALL_LOG_NAME}"
LOG_STAGE="archconfig1"

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

announce_manual_chroot_exit() {
    echo "Etap chroot został zakończony."
    echo "Teraz wpisz dokładnie: exit"
    echo "Po wyjściu wrócisz do live ISO."
    echo "Dopiero w live ISO wykonaj ręcznie:"
    echo "  umount -R /mnt"
    echo "  cryptsetup close ${CRYPT_NAME}"
    echo "  reboot"
    log_input_expected "operator ma wpisać exit, aby opuścić arch-chroot po archconfig1.sh"
}

init_install_log
printf 'META|ts=%s|stage=%s|format=archinstaller-log-v1|location=%s\n' "$(date '+%F %T')" "$LOG_STAGE" "$INSTALL_LOG_FILE" >> "$INSTALL_LOG_FILE"
log_section "Start archconfig1.sh"
log_info "Log instalacyjny: ${INSTALL_LOG_FILE}"
log_info "Profil laptopa: ${MACHINE_PROFILE_ID} (${MACHINE_LABEL})"

: "${MACHINE_PROFILE_ID:?}"
: "${MACHINE_LABEL:?}"
: "${TARGET_DISK:?}"
: "${ESP_PART:?}"
: "${CRYPT_PART:?}"
: "${CRYPT_NAME:?}"
: "${INSTALL_USER:?}"
: "${USER_HOME:?}"
: "${RECOVERY_DIR:?}"
: "${BTRFS_MOUNT_OPTIONS:?}"
: "${ROOT_SUBVOL:?}"
: "${SNAPSHOTS_SUBVOL:?}"
: "${UKI_DEFAULT_EFI:?}"
: "${UKI_FALLBACK_EFI:?}"
: "${UKI_NVRAM_PATH:?}"

echo -e "\033[36m<<<<<===== Ustawienie polskiej strefy czasowej =====>>>>>\033[0m"
ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
hwclock --systohc

echo -e "\033[36m<<<<<===== Konfiguracja języka =====>>>>>\033[0m"
sed -i -E 's/^#?(en_US.UTF-8 UTF-8)/\1/' /etc/locale.gen
sed -i -E 's/^#?(pl_PL.UTF-8 UTF-8)/\1/' /etc/locale.gen
locale-gen

echo -e "\033[36m<<<<<===== Ustawienie zmiennych locale =====>>>>>\033[0m"
cat > /etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
LC_ADDRESS=pl_PL.UTF-8
LC_IDENTIFICATION=pl_PL.UTF-8
LC_MEASUREMENT=pl_PL.UTF-8
LC_MONETARY=pl_PL.UTF-8
LC_NAME=pl_PL.UTF-8
LC_NUMERIC=pl_PL.UTF-8
LC_PAPER=pl_PL.UTF-8
LC_TELEPHONE=pl_PL.UTF-8
LC_TIME=pl_PL.UTF-8
EOF

echo -e "\033[36m<<<<<===== Ustawienie polskiej klawiatury w konsoli =====>>>>>\033[0m"
cat > /etc/vconsole.conf <<'EOF'
KEYMAP=pl
FONT=lat2-16
FONT_MAP=8859-2
EOF

echo -e "\033[36m<<<<<===== Ustawienie hosta =====>>>>>\033[0m"
echo "Teraz instalator czeka na ręczne podanie nazwy hosta."
echo "Po wpisaniu hostname zatwierdź go klawiszem Enter."
log_input_expected "operator ma podać hostname"
read -r -p "Podaj nazwę hosta: " HOST
echo
log_input_confirmed "operator podał hostname"
if [[ ! "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]]; then
    echo -e "\033[31mNiepoprawna nazwa hosta\033[0m"
    exit 1
fi
echo "$HOST" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOST}.localdomain ${HOST}
EOF

echo -e "\033[36m<<<<<===== Ustawienia dla konta root =====>>>>>\033[0m"
echo "Teraz instalator uruchomi interaktywny prompt passwd dla konta root."
echo "Wpisz hasło root i potwierdź je w standardowym promptcie."
log_input_expected "operator ma ustawić hasło konta root"
retry_until_success "Ustawienie hasła root" passwd root

echo -e "\033[36m<<<<<===== Weryfikacja LUKS2 + Argon2id =====>>>>>\033[0m"
cryptsetup luksDump "$CRYPT_PART" | grep -Eq '^Version:[[:space:]]+2$'
cryptsetup luksDump "$CRYPT_PART" | grep -Eq 'PBKDF:[[:space:]]+argon2id'

echo -e "\033[36m<<<<<===== Konfiguracja mkinitcpio i UKI =====>>>>>\033[0m"
CRYPT_UUID="$(blkid -s UUID -o value "$CRYPT_PART")"
ROOT_FLAGS="subvol=${ROOT_SUBVOL},${BTRFS_MOUNT_OPTIONS}"
mkdir -p /efi/EFI/Linux /etc/kernel

cat > /etc/kernel/cmdline <<EOF
rd.luks.name=${CRYPT_UUID}=${CRYPT_NAME} root=/dev/mapper/${CRYPT_NAME} rootfstype=btrfs rootflags=${ROOT_FLAGS} rw ${KERNEL_CMDLINE_EXTRA}
EOF
chmod 600 /etc/kernel/cmdline

cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf_backup
sed -i 's|^FILES=.*|FILES=()|g' /etc/mkinitcpio.conf
sed -i 's|^HOOKS=.*|HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems)|g' /etc/mkinitcpio.conf

cp /etc/mkinitcpio.d/linux.preset /etc/mkinitcpio.d/linux.preset_backup
cat > /etc/mkinitcpio.d/linux.preset <<'EOF'
# mkinitcpio preset file for the 'linux' package

ALL_kver="/boot/vmlinuz-linux"
ALL_cmdline="/etc/kernel/cmdline"

PRESETS=('default' 'fallback')

default_uki="/efi/EFI/Linux/arch-linux.efi"
fallback_uki="/efi/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOF

echo -e "\033[36m<<<<<===== Przygotowanie podpisywania UKI =====>>>>>\033[0m"
echo "Secure Boot pozostaje teraz wyłączony, ale klucze i podpisy są przygotowywane już na etapie instalacji."
if [[ ! -f /etc/kernel/uki.conf ]]; then
    cat > /etc/kernel/uki.conf <<'EOF'
[UKI]
SecureBootSigningTool=systemd-sbsign
EOF
    chmod 644 /etc/kernel/uki.conf
fi

echo -e "\033[36m<<<<<===== Generowanie UKI =====>>>>>\033[0m"
mkinitcpio -P

echo -e "\033[36m<<<<<===== Przygotowanie kluczy Secure Boot =====>>>>>\033[0m"
if [[ ! -f /var/lib/sbctl/keys/db/db.pem ]]; then
    sbctl create-keys
fi

echo -e "\033[36m<<<<<===== Podpisanie UKI =====>>>>>\033[0m"
if [[ -f "$UKI_DEFAULT_EFI" ]]; then
    sbctl sign -s "$UKI_DEFAULT_EFI"
fi
if [[ -f "$UKI_FALLBACK_EFI" ]]; then
    sbctl sign -s "$UKI_FALLBACK_EFI"
fi

echo -e "\033[36m<<<<<===== Rejestrowanie bezpośredniego wpisu UEFI =====>>>>>\033[0m"
echo "Domyślny boot: firmware UEFI -> UKI, bez GRUB."
if ! efibootmgr | grep -Fq "Arch Linux (UKI)"; then
    efibootmgr --create --disk "$TARGET_DISK" --part 1 --label "Arch Linux (UKI)" --loader "$UKI_NVRAM_PATH"
fi

echo -e "\033[36m<<<<<===== Remount i kontrola bezpieczeństwa ESP =====>>>>>\033[0m"
echo "Na FAT32 uprawnienia wynikają z opcji mounta. /efi ma być tylko dla roota."
echo "To jest kontrola ESP i plików UKI dla modelu bez systemd-boot."
echo "W tym workflow brak systemd-boot jest oczekiwany, bo firmware startuje bezpośrednio plik UKI."
mount -o remount /efi
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /efi || true
ls -l /efi/EFI/Linux || true
if efibootmgr | grep -Fq "Arch Linux (UKI)"; then
    echo "Wpis UEFI 'Arch Linux (UKI)' jest obecny."
else
    echo "UWAGA: nie wykryto wpisu UEFI 'Arch Linux (UKI)'."
fi
echo "Kontrola jest zakończona. Za chwilę pojawi się checkpoint audytowy."
echo "Na checkpointcie nie wpisuj żadnego tekstu, tylko naciśnij Enter, jeśli wynik wygląda poprawnie."
log_info "Kontrola ESP wykonana bez bootctl status, bo repo używa bezpośredniego bootu UKI"
audit_checkpoint "weryfikacja toru bootu UKI i bezpieczeństwa ESP"

echo -e "\033[36m<<<<<===== Instalacja sudo =====>>>>>\033[0m"
echo "Postęp instalacji pakietów będzie widoczny na ekranie."
run_logged pacman -S --needed sudo --noconfirm

echo -e "\033[36m<<<<<===== Przygotowanie konta użytkownika ${INSTALL_USER} =====>>>>>\033[0m"
useradd -m -G wheel -s /bin/bash "$INSTALL_USER"
echo "Teraz instalator uruchomi interaktywny prompt passwd dla użytkownika ${INSTALL_USER}."
echo "Wpisz hasło użytkownika ${INSTALL_USER} i potwierdź je w standardowym promptcie."
log_input_expected "operator ma ustawić hasło użytkownika ${INSTALL_USER}"
retry_until_success "Ustawienie hasła użytkownika ${INSTALL_USER}" passwd "$INSTALL_USER"
echo "${INSTALL_USER} ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/10-${INSTALL_USER}"
chmod 0440 "/etc/sudoers.d/10-${INSTALL_USER}"
visudo -cf "/etc/sudoers.d/10-${INSTALL_USER}"

echo -e "\033[36m<<<<<===== Przygotowanie recovery LUKS =====>>>>>\033[0m"
echo "To jest staging recovery na laptopie. Po pierwszym logowaniu skopiuj katalog recovery na osobny nośnik USB."
install -d -m 700 -o "${INSTALL_USER}" -g "${INSTALL_USER}" "$RECOVERY_DIR"
RECOVERY_LUKS_DIR="${RECOVERY_DIR}/luks"
RECOVERY_SECURE_BOOT_DIR="${RECOVERY_DIR}/secure-boot"
install -d -m 700 -o "${INSTALL_USER}" -g "${INSTALL_USER}" "$RECOVERY_LUKS_DIR"
install -d -m 700 -o "${INSTALL_USER}" -g "${INSTALL_USER}" "$RECOVERY_SECURE_BOOT_DIR"

RECOVERY_OUTPUT_FILE="${RECOVERY_LUKS_DIR}/cryptroot-recovery-key.txt"
retry_until_success "Dodanie recovery key do LUKS" generate_recovery_key_output
chmod 600 "$RECOVERY_OUTPUT_FILE"
chown "${INSTALL_USER}:${INSTALL_USER}" "$RECOVERY_OUTPUT_FILE"

HEADER_BACKUP_FILE="${RECOVERY_LUKS_DIR}/cryptroot-luks-header.img"
cryptsetup luksHeaderBackup "$CRYPT_PART" --header-backup-file "$HEADER_BACKUP_FILE"
chmod 600 "$HEADER_BACKUP_FILE"
chown "${INSTALL_USER}:${INSTALL_USER}" "$HEADER_BACKUP_FILE"

UUID_BACKUP_FILE="${RECOVERY_LUKS_DIR}/cryptroot-uuid.txt"
blkid -s UUID -o value "$CRYPT_PART" > "$UUID_BACKUP_FILE"
chmod 600 "$UUID_BACKUP_FILE"
chown "${INSTALL_USER}:${INSTALL_USER}" "$UUID_BACKUP_FILE"

if [[ -d /var/lib/sbctl/keys ]]; then
    SECURE_BOOT_KEYS_DIR="${RECOVERY_SECURE_BOOT_DIR}/keys"
    install -d -m 700 -o "${INSTALL_USER}" -g "${INSTALL_USER}" "$SECURE_BOOT_KEYS_DIR"
    cp -a /var/lib/sbctl/keys/. "$SECURE_BOOT_KEYS_DIR"/
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "$SECURE_BOOT_KEYS_DIR"
    chmod -R go-rwx "$SECURE_BOOT_KEYS_DIR"
fi

cat > "${RECOVERY_DIR}/README.md" <<EOF
# Recovery po instalacji

To jest staging recovery przygotowany przez instalator.
Docelowo skopiuj cały katalog na osobny nośnik USB i nie traktuj laptopa jako jedynej kopii.

## Struktura

- \`luks/\`
  - \`cryptroot-luks-header.img\` — backup nagłówka LUKS
  - \`cryptroot-recovery-key.txt\` — recovery key dodany do LUKS
  - \`cryptroot-uuid.txt\` — UUID partycji LUKS (pomoc w Scenariuszu D runbooka)
- \`secure-boot/\`
  - \`keys/\` — backup kluczy \`sbctl\` do podpisywania Secure Boot

## Co zrobić po pierwszym logowaniu

1. Skopiuj cały katalog \`${RECOVERY_DIR}\` na osobny nośnik USB.
2. Zachowaj go razem z osobną instrukcją ratunkową z repozytorium.
3. Dopiero po bezpiecznym skopiowaniu usuń z laptopa wrażliwe pliki lub cały katalog.

## Uwaga

Jeżeli zmienisz sloty LUKS, odśwież backup w \`luks/\`.
Jeżeli zrotujesz klucze \`sbctl\`, odśwież backup w \`secure-boot/keys/\`.
EOF
chmod 600 "${RECOVERY_DIR}/README.md"
chown "${INSTALL_USER}:${INSTALL_USER}" "${RECOVERY_DIR}/README.md"

echo -e "\033[36m<<<<<===== Instalacja NetworkManager =====>>>>>\033[0m"
echo "Postęp instalacji pakietów będzie widoczny na ekranie."
run_logged pacman -S --needed networkmanager --noconfirm
systemctl enable NetworkManager.service

echo -e "\033[36m<<<<<===== Konfiguracja pacman =====>>>>>\033[0m"
cp /etc/pacman.conf /etc/pacman.conf_backup
curl -fL "${BASE_URL}/pacman.conf" > /etc/pacman.conf
pacman-conf >/dev/null

echo -e "\033[36m<<<<<===== Konfiguracja Snapper =====>>>>>\033[0m"
echo "Root na Btrfs dostaje snapshoty tylko dla systemu, bez /home i danych Dockera."
if mountpoint -q /.snapshots; then
    umount /.snapshots
fi
rmdir /.snapshots
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount -o "${BTRFS_MOUNT_OPTIONS},subvol=${SNAPSHOTS_SUBVOL}" "/dev/mapper/${CRYPT_NAME}" /.snapshots
chmod 750 /.snapshots
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root
sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="no"/' /etc/snapper/configs/root
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="yes"/' /etc/snapper/configs/root
sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="5"/' /etc/snapper/configs/root
sed -i 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="3"/' /etc/snapper/configs/root
sed -i 's/^NUMBER_MIN_AGE=.*/NUMBER_MIN_AGE="1800"/' /etc/snapper/configs/root
systemctl enable snapper-cleanup.timer

echo -e "\033[36m<<<<<===== Przekazanie pliku stanu do /home/${INSTALL_USER} =====>>>>>\033[0m"
cp "$ENV_FILE" "${USER_HOME}/archinstaller.env"
chown "${INSTALL_USER}:${INSTALL_USER}" "${USER_HOME}/archinstaller.env"
chmod 600 "${USER_HOME}/archinstaller.env"

echo -e "\033[36m<<<<<===== Pobranie skryptu archconfig2.sh =====>>>>>\033[0m"
curl -fL "${BASE_URL}/archconfig2.sh" > "${USER_HOME}/archconfig2.sh"
chmod +x "${USER_HOME}/archconfig2.sh"
chown "${INSTALL_USER}:${INSTALL_USER}" "${USER_HOME}/archconfig2.sh"

echo -e "\033[36m<<<<<===== Przekazanie logu instalacyjnego do /home/${INSTALL_USER} =====>>>>>\033[0m"
cp "$INSTALL_LOG_FILE" "${USER_HOME}/${INSTALL_LOG_NAME}"
chown "${INSTALL_USER}:${INSTALL_USER}" "${USER_HOME}/${INSTALL_LOG_NAME}"
chmod 600 "${USER_HOME}/${INSTALL_LOG_NAME}"
log_info "Skopiowano log instalacyjny do ${USER_HOME}/${INSTALL_LOG_NAME}"
audit_checkpoint "zamknięcie etapu chroot po konfiguracji pacman, snapper i NetworkManager"

echo
echo -e "\033[36m<<<<<===== Etap chroot zakończony =====>>>>>\033[0m"
announce_manual_chroot_exit
