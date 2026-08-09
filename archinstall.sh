#!/usr/bin/env bash

# Część zmiennych jest serializowana pośrednio do archinstaller.env, a katalog
# profili jest wczytywany dynamicznie z machine_profiles.sh.
# shellcheck disable=SC2034,SC2153

# Główny plik instalatora.
# Model: dwa jawne profile ThinkPad, UEFI, ESP + LUKS2 root, Btrfs, UKI.

set -euo pipefail

CRYPT_NAME="cryptroot"
INSTALL_USER="matt"
USER_HOME="/home/${INSTALL_USER}"
RECOVERY_DIR="${USER_HOME}/recovery"
BASE_URL="https://it.mattromanow.com/downloads/arch"
MACHINE_PROFILES_URL="${BASE_URL}/machine_profiles.sh"
MACHINE_PROFILES_FILE="/tmp/archinstaller-machine_profiles.sh"
ARCHINSTALLER_ENV_VERSION="2"
INSTALL_LOG_NAME="archinstaller-install.log"
LOG_STAGE="archinstall"
BTRFS_MOUNT_OPTIONS="compress=zstd,noatime"
ROOT_SUBVOL="@"
HOME_SUBVOL="@home"
SNAPSHOTS_SUBVOL="@snapshots"
VAR_LOG_SUBVOL="@var_log"
PACMAN_CACHE_SUBVOL="@var_cache_pacman_pkg"
DOCKER_SUBVOL="@var_lib_docker"
UKI_DEFAULT_EFI="/efi/EFI/Linux/arch-linux.efi"
UKI_FALLBACK_EFI="/efi/EFI/Linux/arch-linux-fallback.efi"
UKI_NVRAM_PATH='\EFI\Linux\arch-linux.efi'
ESP_MOUNT="/efi"
INSTALL_STATE_FILE=".archinstaller-stage"
LIVE_LOG_TMP="/tmp/${INSTALL_LOG_NAME}"
LIVE_LOG_TARGET="/mnt/root/${INSTALL_LOG_NAME}"
PACSTRAP_PACKAGES=(
    base
    base-devel
    linux
    linux-firmware
    neovim
    curl
    reflector
    cryptsetup
    efibootmgr
    dosfstools
    btrfs-progs
    snapper
    sbctl
    systemd-ukify
    iptables
    mkinitcpio
)
MACHINE_PROFILE_REQUIRED_FIELDS=(
    label
    menu_description
    dmi_product_prefix
    cpu_vendor_id
    cpu_model_match
    target_disk
    target_disk_model
    target_disk_transport
    esp_part
    crypt_part
    cpu_ucode_package
    storage_tool_package
    vulkan_package
    video_accel_package
    enable_rts522a_pm_fix
)

download_machine_profiles() {
    local download_file="${MACHINE_PROFILES_FILE}.download"

    echo -e "\033[36m<<<<<===== Pobranie katalogu profili laptopów =====>>>>>\033[0m"
    rm -f "$download_file"
    if ! curl -fL "$MACHINE_PROFILES_URL" -o "$download_file"; then
        rm -f "$download_file"
        if [[ -f "$MACHINE_PROFILES_FILE" ]] && bash -n "$MACHINE_PROFILES_FILE"; then
            echo -e "\033[33mPobranie nie powiodło się. Używam zwalidowanej składniowo kopii z bieżącej sesji live ISO.\033[0m"
            return
        fi
        echo -e "\033[31mNie udało się pobrać ${MACHINE_PROFILES_URL}\033[0m"
        exit 1
    fi
    if ! bash -n "$download_file"; then
        rm -f "$download_file"
        echo -e "\033[31mPobrany katalog profili ma niepoprawną składnię Bash.\033[0m"
        exit 1
    fi
    mv "$download_file" "$MACHINE_PROFILES_FILE"
    chmod 600 "$MACHINE_PROFILES_FILE"
}

profile_id_exists() {
    local expected_id="$1"
    local profile_id

    for profile_id in "${MACHINE_PROFILE_IDS[@]}"; do
        [[ "$profile_id" == "$expected_id" ]] && return 0
    done
    return 1
}

profile_field_exists() {
    local expected_field="$1"
    local field

    for field in "${MACHINE_PROFILE_REQUIRED_FIELDS[@]}"; do
        [[ "$field" == "$expected_field" ]] && return 0
    done
    return 1
}

validate_machine_profile_catalog() {
    local field
    local key
    local profile_id
    local value
    local -A seen_disks=()
    local -A seen_ids=()

    if [[ "${MACHINE_PROFILE_SCHEMA_VERSION:-}" != "1" ]]; then
        echo -e "\033[31mNieobsługiwana wersja katalogu profili: ${MACHINE_PROFILE_SCHEMA_VERSION:-brak}\033[0m"
        exit 1
    fi
    if ! declare -p MACHINE_PROFILE_IDS 2>/dev/null | grep -q '^declare -a'; then
        echo -e "\033[31mKatalog nie zawiera tablicy MACHINE_PROFILE_IDS.\033[0m"
        exit 1
    fi
    if ! declare -p MACHINE_PROFILE_DATA 2>/dev/null | grep -q '^declare -A'; then
        echo -e "\033[31mKatalog nie zawiera tablicy asocjacyjnej MACHINE_PROFILE_DATA.\033[0m"
        exit 1
    fi
    if ((${#MACHINE_PROFILE_IDS[@]} == 0)); then
        echo -e "\033[31mKatalog profili jest pusty.\033[0m"
        exit 1
    fi

    for profile_id in "${MACHINE_PROFILE_IDS[@]}"; do
        if [[ ! "$profile_id" =~ ^[a-z0-9][a-z0-9_]*$ ]]; then
            echo -e "\033[31mNiepoprawny identyfikator profilu: ${profile_id}\033[0m"
            exit 1
        fi
        if [[ -n "${seen_ids[$profile_id]:-}" ]]; then
            echo -e "\033[31mPowtórzony identyfikator profilu: ${profile_id}\033[0m"
            exit 1
        fi
        seen_ids["$profile_id"]="1"

        for field in "${MACHINE_PROFILE_REQUIRED_FIELDS[@]}"; do
            key="${profile_id}.${field}"
            if [[ ! -v "MACHINE_PROFILE_DATA[$key]" ]]; then
                echo -e "\033[31mProfil ${profile_id} nie zawiera pola ${field}.\033[0m"
                exit 1
            fi
            value="${MACHINE_PROFILE_DATA[$key]}"
            case "$field" in
                storage_tool_package | video_accel_package)
                    ;;
                *)
                    if [[ -z "$value" ]]; then
                        echo -e "\033[31mPole ${key} nie może być puste.\033[0m"
                        exit 1
                    fi
                    ;;
            esac
        done

        value="${MACHINE_PROFILE_DATA["${profile_id}.target_disk"]}"
        if [[ "$value" != /dev/* ]]; then
            echo -e "\033[31mNiepoprawna ścieżka dysku w profilu ${profile_id}: ${value}\033[0m"
            exit 1
        fi
        if [[ -n "${seen_disks[$value]:-}" ]]; then
            echo -e "\033[31mDysk ${value} jest przypisany do więcej niż jednego profilu.\033[0m"
            exit 1
        fi
        seen_disks["$value"]="$profile_id"
        if [[ "${MACHINE_PROFILE_DATA["${profile_id}.esp_part"]}" != "$value"* ||
              "${MACHINE_PROFILE_DATA["${profile_id}.crypt_part"]}" != "$value"* ||
              "${MACHINE_PROFILE_DATA["${profile_id}.esp_part"]}" == "${MACHINE_PROFILE_DATA["${profile_id}.crypt_part"]}" ]]; then
            echo -e "\033[31mNiespójne partycje w profilu ${profile_id}.\033[0m"
            exit 1
        fi
        if [[ ! "${MACHINE_PROFILE_DATA["${profile_id}.enable_rts522a_pm_fix"]}" =~ ^[01]$ ]]; then
            echo -e "\033[31mPole enable_rts522a_pm_fix profilu ${profile_id} musi mieć wartość 0 albo 1.\033[0m"
            exit 1
        fi
        for field in cpu_ucode_package storage_tool_package vulkan_package video_accel_package; do
            value="${MACHINE_PROFILE_DATA["${profile_id}.${field}"]}"
            if [[ -n "$value" && ! "$value" =~ ^[a-z0-9@._+-]+$ ]]; then
                echo -e "\033[31mNiepoprawna nazwa pakietu w polu ${profile_id}.${field}: ${value}\033[0m"
                exit 1
            fi
        done
    done

    for key in "${!MACHINE_PROFILE_DATA[@]}"; do
        if [[ "$key" != *.* ]]; then
            echo -e "\033[31mNiepoprawny klucz katalogu profili: ${key}\033[0m"
            exit 1
        fi
        profile_id="${key%%.*}"
        field="${key#*.}"
        if ! profile_id_exists "$profile_id"; then
            echo -e "\033[31mDane istnieją dla profilu nieobecnego w MACHINE_PROFILE_IDS: ${profile_id}\033[0m"
            exit 1
        fi
        if ! profile_field_exists "$field"; then
            echo -e "\033[31mNieznane pole profilu: ${key}\033[0m"
            exit 1
        fi
    done
}

apply_machine_profile() {
    local profile_id="$1"

    MACHINE_PROFILE_ID="$profile_id"
    MACHINE_LABEL="${MACHINE_PROFILE_DATA["${profile_id}.label"]}"
    DMI_PRODUCT_PREFIX="${MACHINE_PROFILE_DATA["${profile_id}.dmi_product_prefix"]}"
    CPU_VENDOR_ID="${MACHINE_PROFILE_DATA["${profile_id}.cpu_vendor_id"]}"
    CPU_MODEL_MATCH="${MACHINE_PROFILE_DATA["${profile_id}.cpu_model_match"]}"
    TARGET_DISK="${MACHINE_PROFILE_DATA["${profile_id}.target_disk"]}"
    TARGET_DISK_MODEL="${MACHINE_PROFILE_DATA["${profile_id}.target_disk_model"]}"
    TARGET_DISK_TRANSPORT="${MACHINE_PROFILE_DATA["${profile_id}.target_disk_transport"]}"
    ESP_PART="${MACHINE_PROFILE_DATA["${profile_id}.esp_part"]}"
    CRYPT_PART="${MACHINE_PROFILE_DATA["${profile_id}.crypt_part"]}"
    CPU_UCODE_PACKAGE="${MACHINE_PROFILE_DATA["${profile_id}.cpu_ucode_package"]}"
    STORAGE_TOOL_PACKAGE="${MACHINE_PROFILE_DATA["${profile_id}.storage_tool_package"]}"
    VULKAN_PACKAGE="${MACHINE_PROFILE_DATA["${profile_id}.vulkan_package"]}"
    VIDEO_ACCEL_PACKAGE="${MACHINE_PROFILE_DATA["${profile_id}.video_accel_package"]}"
    ENABLE_RTS522A_PM_FIX="${MACHINE_PROFILE_DATA["${profile_id}.enable_rts522a_pm_fix"]}"
    PACSTRAP_PACKAGES+=("$CPU_UCODE_PACKAGE")
}

select_machine_profile() {
    local choice
    local choice_number
    local confirmation
    local index
    local profile_id

    while true; do
        echo -e "\033[36m<<<<<===== Wybór laptopa =====>>>>>\033[0m"
        index=1
        for profile_id in "${MACHINE_PROFILE_IDS[@]}"; do
            echo "${index}) ${MACHINE_PROFILE_DATA["${profile_id}.label"]} — ${MACHINE_PROFILE_DATA["${profile_id}.menu_description"]}"
            ((index += 1))
        done
        read -r -p "Wybierz profil [1-${#MACHINE_PROFILE_IDS[@]}]: " choice
        echo

        if [[ ! "$choice" =~ ^[1-9][0-9]{0,2}$ ]]; then
            echo -e "\033[31mNiepoprawny wybór.\033[0m"
            echo
            continue
        fi
        choice_number=$((10#$choice))
        if ((choice_number > ${#MACHINE_PROFILE_IDS[@]})); then
            echo -e "\033[31mNiepoprawny wybór.\033[0m"
            echo
            continue
        fi

        profile_id="${MACHINE_PROFILE_IDS[$((choice_number - 1))]}"
        apply_machine_profile "$profile_id"
        echo "Wybrany profil: ${MACHINE_LABEL} (${MACHINE_PROFILE_ID})"
        echo "Dysk przeznaczony do instalacji: ${TARGET_DISK} (${TARGET_DISK_MODEL})"
        read -r -p "Wpisz 'tak', aby zatwierdzić ten profil: " confirmation
        echo
        if [[ "$confirmation" == "tak" ]]; then
            break
        fi

        PACSTRAP_PACKAGES=("${PACSTRAP_PACKAGES[@]:0:${#PACSTRAP_PACKAGES[@]}-1}")
        echo "Profil nie został zatwierdzony. Wybierz ponownie."
        echo
    done
}

validate_selected_hardware() {
    local actual_cpu_model
    local actual_cpu_vendor
    local actual_disk_model
    local actual_disk_transport
    local actual_dmi_product
    local disk_name

    actual_dmi_product="$(tr -d '\n' < /sys/class/dmi/id/product_name 2>/dev/null || true)"
    actual_cpu_vendor="$(lscpu | awk -F: '/^Vendor ID:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')"
    actual_cpu_model="$(lscpu | awk -F: '/^Model name:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')"

    if [[ "$actual_dmi_product" != "${DMI_PRODUCT_PREFIX}"* ]]; then
        echo -e "\033[31mWybrany profil nie pasuje do DMI laptopa.\033[0m"
        echo "Oczekiwany prefiks: ${DMI_PRODUCT_PREFIX}; wykryto: ${actual_dmi_product:-brak}"
        exit 1
    fi
    if [[ "$actual_cpu_vendor" != "$CPU_VENDOR_ID" || "$actual_cpu_model" != *"$CPU_MODEL_MATCH"* ]]; then
        echo -e "\033[31mWybrany profil nie pasuje do procesora laptopa.\033[0m"
        echo "Wykryto: ${actual_cpu_vendor:-brak}, ${actual_cpu_model:-brak}"
        exit 1
    fi
    if [[ ! -b "$TARGET_DISK" ]]; then
        echo -e "\033[31mDysk ${TARGET_DISK} nie istnieje.\033[0m"
        exit 1
    fi

    actual_disk_model="$(lsblk -dn -o MODEL "$TARGET_DISK" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    actual_disk_transport="$(lsblk -dn -o TRAN "$TARGET_DISK" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    disk_name="${TARGET_DISK##*/}"
    if [[ "$actual_disk_model" != *"$TARGET_DISK_MODEL"* || "$actual_disk_transport" != "$TARGET_DISK_TRANSPORT" ]]; then
        echo -e "\033[31mDysk profilu nie odpowiada wykrytemu urządzeniu ${TARGET_DISK}.\033[0m"
        echo "Oczekiwano: ${TARGET_DISK_MODEL}, ${TARGET_DISK_TRANSPORT}"
        echo "Wykryto: ${actual_disk_model:-brak}, ${actual_disk_transport:-brak}"
        exit 1
    fi
    if [[ "$(cat "/sys/block/${disk_name}/queue/rotational")" != "0" ]]; then
        echo -e "\033[31mDysk ${TARGET_DISK} nie jest raportowany jako SSD.\033[0m"
        exit 1
    fi
}

write_installer_env() {
    local destination="$1"
    local variable_name

    mkdir -p "$(dirname "$destination")"
    {
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
            ENABLE_RTS522A_PM_FIX \
            CRYPT_NAME \
            INSTALL_USER \
            USER_HOME \
            RECOVERY_DIR \
            ESP_MOUNT \
            BTRFS_MOUNT_OPTIONS \
            ROOT_SUBVOL \
            HOME_SUBVOL \
            SNAPSHOTS_SUBVOL \
            VAR_LOG_SUBVOL \
            PACMAN_CACHE_SUBVOL \
            DOCKER_SUBVOL \
            UKI_DEFAULT_EFI \
            UKI_FALLBACK_EFI \
            UKI_NVRAM_PATH \
            INSTALL_LOG_NAME; do
            printf '%s=%q\n' "$variable_name" "${!variable_name}"
        done
    } > "$destination"
    chmod 600 "$destination"
}

validate_saved_profile() {
    local saved_env="$1"
    local expected_disk="$TARGET_DISK"
    local expected_profile="$MACHINE_PROFILE_ID"
    local saved_disk
    local saved_profile
    local saved_state

    [[ -f "$saved_env" ]] || return 0

    if ! saved_state="$(
        bash -c '
            set -euo pipefail
            source "$1"
            printf "%s|%s" "${MACHINE_PROFILE_ID:-}" "${TARGET_DISK:-}"
        ' _ "$saved_env"
    )"; then
        echo -e "\033[31mNie udało się odczytać zapisanego stanu instalacji.\033[0m"
        exit 1
    fi
    saved_profile="${saved_state%%|*}"
    saved_disk="${saved_state#*|}"

    if [[ "$saved_profile" != "$expected_profile" || "$saved_disk" != "$expected_disk" ]]; then
        echo -e "\033[31mZapisany stan instalacji należy do innego profilu lub dysku.\033[0m"
        echo "Przerwano resume bez zmieniania dysku."
        exit 1
    fi
}

ensure_live_log_file() {
    local logfile="$1"
    mkdir -p "$(dirname "$logfile")"
    touch "$logfile"
    chmod 600 "$logfile" 2>/dev/null || true
}

sanitize_log_value() {
    local value="${1:-}"
    value=${value//$'\n'/ }
    value=${value//$'\r'/ }
    value=${value//$'\t'/ }
    value=${value//|/-}
    printf '%s' "$value"
}

append_line_to_live_logs() {
    local line="$1"
    ensure_live_log_file "$LIVE_LOG_TMP"
    printf '%s\n' "$line" >> "$LIVE_LOG_TMP"

    if [[ -f "$LIVE_LOG_TARGET" ]]; then
        ensure_live_log_file "$LIVE_LOG_TARGET"
        printf '%s\n' "$line" >> "$LIVE_LOG_TARGET"
    fi
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

write_log_stream() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"
        append_line_to_live_logs "$(format_stream_record "$line")"
    done
}

run_with_live_output_and_log() {
    local stream_log
    local cmd_string
    local rc

    stream_log="$(mktemp)"
    printf -v cmd_string '%q ' "$@"
    if script -qefc "$cmd_string" /dev/null | tee >(tr '\r' '\n' > "$stream_log"); then
        rc=0
    else
        rc=${PIPESTATUS[0]}
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        append_line_to_live_logs "$(format_stream_record "$line")"
    done < "$stream_log"

    rm -f "$stream_log"
    return "$rc"
}

sync_live_log_to_target() {
    ensure_live_log_file "$LIVE_LOG_TARGET"
    cp "$LIVE_LOG_TMP" "$LIVE_LOG_TARGET"
    chmod 600 "$LIVE_LOG_TARGET" 2>/dev/null || true
}

log_line() {
    local kind="$1"
    local event="$2"
    local message="${3:-}"
    append_line_to_live_logs "$(format_log_record "$kind" "$event" "$message")"
}

log_section() {
    log_line "SECTION" "SECTION_START" "$1"
}

log_info() {
    log_line "INFO" "INFO" "$1"
}

log_warn() {
    log_line "WARN" "WARN" "$1"
}

log_input_expected() {
    log_line "INPUT" "INPUT_EXPECTED" "$1"
}

log_input_confirmed() {
    log_line "INPUT" "INPUT_CONFIRMED" "$1"
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

announce_pacman_interaction() {
    local description="$1"
    echo "Za chwilę rozpocznie się: ${description}"
    echo "Jeśli zobaczysz 'Enter a number (default=1):', naciśnij Enter, aby przyjąć domyślny wybór."
    echo "Jeśli zobaczysz ':: Proceed with installation? [Y/n]', naciśnij Enter, aby kontynuować."
    echo "Gdy pojawi się ':: Retrieving packages...' albo lista pobieranych pakietów, nic już nie wpisuj."
    log_input_expected "operator może zatwierdzić prompty pacman/pacstrap enterem podczas: ${description}"
}

announce_chroot_entry() {
    echo "Za chwilę instalator otworzy interaktywną powłokę arch-chroot."
    echo "W chroot uruchom dokładnie: /archconfig1.sh"
    echo "Po zakończeniu pracy w chroot wpisz dokładnie: exit"
    echo "Dopiero wtedy wrócisz do live ISO."
    press_enter_to_continue \
        "operator ma nacisnąć Enter, aby wejść do arch-chroot" \
        "Naciśnij Enter, aby wejść do arch-chroot: "
}

show_live_iso_finish_instructions() {
    echo "Powłoka arch-chroot została zamknięta. Jeżeli etap chroot zakończył się poprawnie, jesteś znowu w live ISO."
    echo "Teraz wykonaj ręcznie, w tej kolejności:"
    echo "  umount -R /mnt"
    echo "  cryptsetup close ${CRYPT_NAME}"
    echo "  reboot"
}

run_logged() {
    log_line "CMD" "CMD_START" "$*"
    if run_with_live_output_and_log "$@"; then
        log_line "CMD" "CMD_OK" "$1"
    else
        local rc=$?
        log_line "CMD" "CMD_FAIL" "$1 rc=${rc}"
        return "$rc"
    fi
}

retry_until_success() {
    local description="$1"
    shift

    until run_with_live_output_and_log "$@"; do
        local rc=$?
        log_line "RETRY" "RETRY_FAIL" "${description} rc=${rc}"
        echo -e "\033[31m${description} nie powiodło się. Spróbuj ponownie albo przerwij Ctrl+C.\033[0m"
        press_enter_to_continue \
            "operator ma zatwierdzić ponowną próbę po błędzie: ${description}" \
            "Naciśnij Enter, aby ponowić próbę: "
    done
}

cleanup_mounts() {
    umount -R /mnt 2>/dev/null || true
}

is_resume_ready_with_active_mounts() {
    local crypt_source
    local esp_source

    [[ -e "/dev/mapper/${CRYPT_NAME}" ]] || return 1
    mountpoint -q /mnt || return 1
    mountpoint -q /mnt/efi || return 1
    esp_source="$(findmnt -nro SOURCE --target /mnt/efi)"
    crypt_source="$(cryptsetup status "$CRYPT_NAME" | awk '$1 == "device:" {print $2; exit}')"
    [[ "$(readlink -f "$esp_source")" == "$(readlink -f "$ESP_PART")" ]] || return 1
    [[ "$(readlink -f "$crypt_source")" == "$(readlink -f "$CRYPT_PART")" ]] || return 1
}

is_existing_layout_ready_for_resume() {
    [[ -b "$ESP_PART" ]] || return 1
    [[ -b "$CRYPT_PART" ]] || return 1
    [[ "$(blkid -s TYPE -o value "$ESP_PART" 2>/dev/null)" == "vfat" ]] || return 1
    cryptsetup isLuks "$CRYPT_PART" >/dev/null 2>&1 || return 1
}

open_existing_luks() {
    if [[ ! -e "/dev/mapper/${CRYPT_NAME}" ]]; then
        cryptsetup open "$CRYPT_PART" "$CRYPT_NAME"
    fi
}

create_btrfs_layout() {
    mount "/dev/mapper/${CRYPT_NAME}" /mnt
    btrfs subvolume create "/mnt/${ROOT_SUBVOL}"
    btrfs subvolume create "/mnt/${HOME_SUBVOL}"
    btrfs subvolume create "/mnt/${SNAPSHOTS_SUBVOL}"
    btrfs subvolume create "/mnt/${VAR_LOG_SUBVOL}"
    install -d /mnt/var/cache/pacman /mnt/var/lib
    btrfs subvolume create "/mnt/${PACMAN_CACHE_SUBVOL}"
    btrfs subvolume create "/mnt/${DOCKER_SUBVOL}"
    umount /mnt
}

mount_btrfs_layout() {
    cleanup_mounts
    mount -o "${BTRFS_MOUNT_OPTIONS},subvol=${ROOT_SUBVOL}" "/dev/mapper/${CRYPT_NAME}" /mnt
    install -d /mnt/home /mnt/.snapshots /mnt/var/log /mnt/var/cache/pacman/pkg /mnt/var/lib/docker
    mount -o "${BTRFS_MOUNT_OPTIONS},subvol=${HOME_SUBVOL}" "/dev/mapper/${CRYPT_NAME}" /mnt/home
    mount -o "${BTRFS_MOUNT_OPTIONS},subvol=${SNAPSHOTS_SUBVOL}" "/dev/mapper/${CRYPT_NAME}" /mnt/.snapshots
    mount -o "${BTRFS_MOUNT_OPTIONS},subvol=${VAR_LOG_SUBVOL}" "/dev/mapper/${CRYPT_NAME}" /mnt/var/log
    mount -o "${BTRFS_MOUNT_OPTIONS},subvol=${PACMAN_CACHE_SUBVOL}" "/dev/mapper/${CRYPT_NAME}" /mnt/var/cache/pacman/pkg
    mount -o "${BTRFS_MOUNT_OPTIONS},subvol=${DOCKER_SUBVOL}" "/dev/mapper/${CRYPT_NAME}" /mnt/var/lib/docker
    mount --mkdir "$ESP_PART" /mnt/efi
}

seed_target_vconsole_conf() {
    install -d /mnt/etc
    cat > /mnt/etc/vconsole.conf <<'EOF'
KEYMAP=pl
FONT=lat2-16
FONT_MAP=8859-2
EOF
    chmod 644 /mnt/etc/vconsole.conf
}

mark_install_stage() {
    local stage="$1"
    printf '%s\n' "$stage" > "/mnt/${INSTALL_STATE_FILE}"
    chmod 600 "/mnt/${INSTALL_STATE_FILE}"
}

download_machine_profiles
# shellcheck source=/dev/null
source "$MACHINE_PROFILES_FILE"
validate_machine_profile_catalog
select_machine_profile
ensure_live_log_file "$LIVE_LOG_TMP"
append_line_to_live_logs "META|ts=$(date '+%F %T')|stage=${LOG_STAGE}|format=archinstaller-log-v1|location=${LIVE_LOG_TMP}"
log_section "Start archinstall.sh"
log_info "Model instalacji: UEFI + LUKS2 + Btrfs + UKI"
log_info "Profil laptopa: ${MACHINE_PROFILE_ID} (${MACHINE_LABEL})"
log_info "Dysk docelowy: ${TARGET_DISK}"

echo -e "\033[36m<<<<<===== Kontrola trybu uruchomienia UEFI =====>>>>>\033[0m"
log_section "Kontrola trybu uruchomienia UEFI"
if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo -e "\033[31mInstalator wymaga uruchomienia live ISO w trybie UEFI\033[0m"
    log_warn "Brak /sys/firmware/efi/efivars"
    exit 1
fi
log_info "Live ISO uruchomione w trybie UEFI"

echo -e "\033[36m<<<<<===== Weryfikacja wybranego laptopa i dysku =====>>>>>\033[0m"
log_section "Weryfikacja wybranego profilu sprzętowego"
validate_selected_hardware
log_info "Profil ${MACHINE_PROFILE_ID} jest zgodny z DMI, CPU i dyskiem ${TARGET_DISK}"

echo -e "\033[36m<<<<<===== Kontrola czasu systemowego =====>>>>>\033[0m"
log_section "Kontrola czasu systemowego"
run_logged timedatectl set-ntp true
run_logged timedatectl

echo -e "\033[36m<<<<<===== Aktualizacja mirrorów =====>>>>>\033[0m"
log_section "Aktualizacja mirrorów"
if ! command -v reflector >/dev/null 2>&1; then
    echo -e "\033[31mBrak reflector w live ISO. Przerwano przed zmianami na dysku.\033[0m"
    log_warn "Brak pakietu reflector w live ISO"
    exit 1
fi
run_logged reflector --verbose --latest 20 --protocol https --ipv4 --sort rate --save /etc/pacman.d/mirrorlist
run_logged pacman -Sy

echo -e "\033[36m<<<<<===== Dysk wybranego profilu =====>>>>>\033[0m"
log_section "Kontrola dysku docelowego"
echo "Laptop: ${MACHINE_LABEL}"
echo "Dysk instalacyjny: ${TARGET_DISK}"
echo "Układ partycji:"
echo "  ${ESP_PART}   ESP FAT32 1G"
echo "  ${CRYPT_PART} LUKS2 root -> Btrfs"
if is_resume_ready_with_active_mounts; then
    echo -e "\033[33mWykryto aktywny stan po przerwanym pacstrap: /mnt i /mnt/efi są już zamontowane.\033[0m"
    log_info "Wykryto resume z aktywnymi mountami"
    read -r -p "Wpisać 'resume' aby wznowić od pacstrap bez ruszania dysku i mountów, albo Enter aby przejść dalej standardowo: " mounted_resume_choice
    if [[ "$mounted_resume_choice" == "resume" ]]; then
        validate_saved_profile "/mnt/root/archinstaller.env"
        write_installer_env "/mnt/root/archinstaller.env"
        if [[ -f "/mnt/${INSTALL_STATE_FILE}" ]]; then
            echo "Wykryty stan instalacji: $(cat "/mnt/${INSTALL_STATE_FILE}")"
        else
            echo "Brak znacznika stanu. Zakładam wznowienie od pacstrap."
        fi

        echo -e "\033[36m<<<<<===== Instalacja podstawowego systemu =====>>>>>\033[0m"
        echo "Wznowienie po przerwaniu pobierania pakietów. Bez unmount, bez ponownego otwierania LUKS."
        echo "Postęp pacstrap powinien być widoczny na ekranie podczas pobierania i instalacji pakietów."
        seed_target_vconsole_conf
        announce_pacman_interaction "pacstrap w trybie resume z aktywnymi mountami"
        log_section "Resume: instalacja podstawowego systemu"
        retry_until_success "Instalacja podstawowego systemu" \
            pacstrap -K /mnt "${PACSTRAP_PACKAGES[@]}"
        sync_live_log_to_target
        mark_install_stage "pacstrap-complete"

        echo -e "\033[36m<<<<<===== Fstab =====>>>>>\033[0m"
        log_section "Resume: generowanie fstab"
        genfstab -U /mnt > /mnt/etc/fstab
        log_info "Wygenerowano /mnt/etc/fstab"

        echo -e "\033[36m<<<<<===== Uszczelnienie mountu ESP =====>>>>>\033[0m"
        echo "ESP pod /efi dostaje restrykcyjne opcje mounta, aby bootctl nie zgłaszał world-accessible security hole."
        log_section "Resume: uszczelnienie mountu ESP"
        sed -i -E 's|^([^#[:space:]]+[[:space:]]+/efi[[:space:]]+vfat[[:space:]]+)[^[:space:]]+|\1rw,umask=0077,noatime|' /mnt/etc/fstab

        echo -e "\033[36m<<<<<===== Plik stanu instalatora =====>>>>>\033[0m"
        log_section "Resume: zapis pliku stanu"
        write_installer_env "/mnt/root/archinstaller.env"
        mark_install_stage "env-written"

        echo -e "\033[36m<<<<<===== Pobranie skryptu archconfig1.sh =====>>>>>\033[0m"
        log_section "Resume: pobranie archconfig1.sh"
        curl -fL "${BASE_URL}/archconfig1.sh" > /mnt/archconfig1.sh
        chmod +x /mnt/archconfig1.sh
        mark_install_stage "archconfig1-ready"

        echo -e "\033[36m<<<<<===== Przejście na chroot =====>>>>>\033[0m"
        log_section "Resume: wejście do arch-chroot"
        announce_chroot_entry
        arch-chroot /mnt

        echo
        echo -e "\033[36m<<<<<===== Etap live ISO zakończony =====>>>>>\033[0m"
        log_info "Etap live ISO zakończony po resume z aktywnymi mountami"
        show_live_iso_finish_instructions
        exit 0
    fi
fi

if is_existing_layout_ready_for_resume; then
    echo -e "\033[33mWykryto istniejący układ ESP + LUKS na ${TARGET_DISK}.\033[0m"
    echo "Możesz wznowić instalację po utracie mountów albo wyczyścić dysk od nowa."
    log_info "Wykryto istniejący układ ESP + LUKS gotowy do resume"
    read -r -p "Wpisać 'resume' aby wznowić, albo Enter aby wykonać pełne czyszczenie: " resume_choice
    if [[ "$resume_choice" == "resume" ]]; then
        echo -e "\033[36m<<<<<===== Wznowienie instalacji =====>>>>>\033[0m"
        echo "Instalator spróbuje otworzyć istniejący LUKS i ponownie zamontować subvolume."
        log_section "Resume po utracie mountów"
        open_existing_luks
        mount_btrfs_layout
        validate_saved_profile "/mnt/root/archinstaller.env"
        write_installer_env "/mnt/root/archinstaller.env"
        if [[ -f "/mnt/${INSTALL_STATE_FILE}" ]]; then
            echo "Wykryty stan instalacji: $(cat "/mnt/${INSTALL_STATE_FILE}")"
        else
            echo "Brak znacznika stanu. Zakładam, że trzeba wznowić od pacstrap i dalszych kroków."
        fi
        echo -e "\033[36m<<<<<===== Instalacja podstawowego systemu =====>>>>>\033[0m"
        echo "Wznowienie po przerwaniu pobierania pakietów. Pacstrap zostanie ponowiony bez niszczenia dysku."
        echo "Postęp pacstrap powinien być widoczny na ekranie podczas pobierania i instalacji pakietów."
        seed_target_vconsole_conf
        announce_pacman_interaction "pacstrap w trybie resume po utracie mountów"
        log_section "Resume: instalacja podstawowego systemu"
        retry_until_success "Instalacja podstawowego systemu" \
            pacstrap -K /mnt "${PACSTRAP_PACKAGES[@]}"
        sync_live_log_to_target
        mark_install_stage "pacstrap-complete"

        echo -e "\033[36m<<<<<===== Fstab =====>>>>>\033[0m"
        log_section "Resume: generowanie fstab"
        genfstab -U /mnt > /mnt/etc/fstab
        log_info "Wygenerowano /mnt/etc/fstab"

        echo -e "\033[36m<<<<<===== Uszczelnienie mountu ESP =====>>>>>\033[0m"
        echo "ESP pod /efi dostaje restrykcyjne opcje mounta, aby bootctl nie zgłaszał world-accessible security hole."
        log_section "Resume: uszczelnienie mountu ESP"
        sed -i -E 's|^([^#[:space:]]+[[:space:]]+/efi[[:space:]]+vfat[[:space:]]+)[^[:space:]]+|\1rw,umask=0077,noatime|' /mnt/etc/fstab

        echo -e "\033[36m<<<<<===== Plik stanu instalatora =====>>>>>\033[0m"
        log_section "Resume: zapis pliku stanu"
        write_installer_env "/mnt/root/archinstaller.env"
        mark_install_stage "env-written"

        echo -e "\033[36m<<<<<===== Pobranie skryptu archconfig1.sh =====>>>>>\033[0m"
        log_section "Resume: pobranie archconfig1.sh"
        curl -fL "${BASE_URL}/archconfig1.sh" > /mnt/archconfig1.sh
        chmod +x /mnt/archconfig1.sh
        mark_install_stage "archconfig1-ready"

        echo -e "\033[36m<<<<<===== Przejście na chroot =====>>>>>\033[0m"
        log_section "Resume: wejście do arch-chroot"
        announce_chroot_entry
        arch-chroot /mnt

        echo
        echo -e "\033[36m<<<<<===== Etap live ISO zakończony =====>>>>>\033[0m"
        log_info "Etap live ISO zakończony po resume z istniejącego układu"
        show_live_iso_finish_instructions
        exit 0
    fi
fi

echo -e "\033[36m<<<<<===== Automatyczne przygotowanie dysku GPT =====>>>>>\033[0m"
echo -e "\033[31mUWAGA: to usunie całą zawartość dysku ${TARGET_DISK}\033[0m"
log_section "Automatyczne przygotowanie dysku GPT"
audit_checkpoint "potwierdzenie operacji destrukcyjnej na dysku docelowym"
cleanup_mounts
if [[ -e "/dev/mapper/${CRYPT_NAME}" ]]; then
    cryptsetup close "${CRYPT_NAME}" 2>/dev/null || true
fi
run_logged wipefs --all --force "$TARGET_DISK"
run_logged sgdisk --zap-all "$TARGET_DISK"
run_logged sgdisk --clear \
    --new=1:0:+1G \
    --typecode=1:EF00 \
    --change-name=1:"EFI system partition" \
    --new=2:0:0 \
    --typecode=2:8309 \
    --change-name=2:"Linux LUKS root" \
    "$TARGET_DISK"
run_logged partprobe "$TARGET_DISK"
run_logged udevadm settle

echo -e "\033[36m<<<<<===== Formatowanie ESP =====>>>>>\033[0m"
log_section "Formatowanie ESP"
run_logged mkfs.fat -F 32 "$ESP_PART"

echo -e "\033[36m<<<<<===== Szyfrowanie LUKS2 root =====>>>>>\033[0m"
echo "Hasło będzie wpisywane ręcznie przy starcie systemu."
log_section "Szyfrowanie LUKS2 root"
log_info "Dane hasła LUKS nie są zapisywane w logu"
retry_until_success "Ustawienie hasła LUKS" \
    cryptsetup -v luksFormat --batch-mode --type luks2 --pbkdf argon2id --verify-passphrase "$CRYPT_PART"
log_info "Zakończono luksFormat partycji root"

echo -e "\033[36m<<<<<===== Otwieranie LUKS root =====>>>>>\033[0m"
log_section "Otwieranie LUKS root"
cryptsetup open "$CRYPT_PART" "$CRYPT_NAME"
log_info "Otwarto mapper ${CRYPT_NAME}"

echo -e "\033[36m<<<<<===== Formatowanie systemu plików root =====>>>>>\033[0m"
log_section "Formatowanie systemu plików root"
run_logged mkfs.btrfs -f "/dev/mapper/${CRYPT_NAME}"

echo -e "\033[36m<<<<<===== Montowanie systemu plików =====>>>>>\033[0m"
log_section "Montowanie systemu plików"
create_btrfs_layout
mount_btrfs_layout
write_installer_env "/mnt/root/archinstaller.env"
mark_install_stage "layout-mounted"
log_info "Utworzono i zamontowano layout Btrfs"
audit_checkpoint "weryfikacja layoutu dysku, LUKS i mountów przed pacstrap"

echo -e "\033[36m<<<<<===== Instalacja podstawowego systemu =====>>>>>\033[0m"
echo "Postęp pacstrap powinien być widoczny na ekranie podczas pobierania i instalacji pakietów."
seed_target_vconsole_conf
announce_pacman_interaction "pacstrap etapu live ISO"
log_section "Instalacja podstawowego systemu"
retry_until_success "Instalacja podstawowego systemu" \
    pacstrap -K /mnt "${PACSTRAP_PACKAGES[@]}"
sync_live_log_to_target
mark_install_stage "pacstrap-complete"

echo -e "\033[36m<<<<<===== Fstab =====>>>>>\033[0m"
log_section "Generowanie fstab"
genfstab -U /mnt > /mnt/etc/fstab
log_info "Wygenerowano /mnt/etc/fstab"

echo -e "\033[36m<<<<<===== Uszczelnienie mountu ESP =====>>>>>\033[0m"
echo "ESP pod /efi dostaje restrykcyjne opcje mounta, aby bootctl nie zgłaszał world-accessible security hole."
log_section "Uszczelnienie mountu ESP"
sed -i -E 's|^([^#[:space:]]+[[:space:]]+/efi[[:space:]]+vfat[[:space:]]+)[^[:space:]]+|\1rw,umask=0077,noatime|' /mnt/etc/fstab

echo -e "\033[36m<<<<<===== Plik stanu instalatora =====>>>>>\033[0m"
log_section "Zapis pliku stanu instalatora"
write_installer_env "/mnt/root/archinstaller.env"
mark_install_stage "env-written"
log_info "Zapisano /mnt/root/archinstaller.env"

echo -e "\033[36m<<<<<===== Pobranie skryptu archconfig1.sh =====>>>>>\033[0m"
log_section "Pobranie archconfig1.sh"
curl -fL "${BASE_URL}/archconfig1.sh" > /mnt/archconfig1.sh
chmod +x /mnt/archconfig1.sh
mark_install_stage "archconfig1-ready"
log_info "Pobrano archconfig1.sh do /mnt/archconfig1.sh"

echo -e "\033[36m<<<<<===== Przejście na chroot =====>>>>>\033[0m"
log_section "Wejście do arch-chroot"
announce_chroot_entry
arch-chroot /mnt

echo
echo -e "\033[36m<<<<<===== Etap live ISO zakończony =====>>>>>\033[0m"
log_info "Etap live ISO zakończony"
show_live_iso_finish_instructions
