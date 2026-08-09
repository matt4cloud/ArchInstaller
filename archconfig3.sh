#!/usr/bin/env bash

# Etap finalizacji po drugim uruchomieniu.

set -euo pipefail

ENV_FILE="./archinstaller.env"
BASE_URL="https://it.mattromanow.com/downloads/arch"
USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
SWAY_CONFIG="${HOME}/.config/sway/config"
PORTAL_CONFIG="${HOME}/.config/xdg-desktop-portal/sway-portals.conf"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
KEEPASSXC_RELEASE_JSON=""
KEEPASSXC_STAGING_DIR=""

readonly SWAY_IMPORT_SYSTEMD='exec systemctl --user import-environment DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP SSH_AUTH_SOCK GNOME_KEYRING_CONTROL'
readonly SWAY_IMPORT_DBUS='exec dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP SSH_AUTH_SOCK GNOME_KEYRING_CONTROL'
readonly SWAY_START_KSECRET='exec sh -c '\''pgrep -x ksecretd >/dev/null || QT_QPA_PLATFORM=wayland /usr/bin/ksecretd'\'''
readonly KEEPASSXC_RELEASE_API="https://api.github.com/repos/keepassxreboot/keepassxc/releases/latest"
readonly KEEPASSXC_SIGNING_KEY_URL="https://keepassxc.org/keepassxc_master_signing_key.asc"
readonly KEEPASSXC_SIGNING_FINGERPRINT="BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2"
readonly KEEPASSXC_2712_PATCH_URL="https://github.com/keepassxreboot/keepassxc/commit/139c0beb46d5a44244681202b7a936c4a1dbb133.patch"

stop_sudo_keepalive() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

cleanup_runtime() {
    stop_sudo_keepalive

    if [[ -n "$KEEPASSXC_RELEASE_JSON" &&
          -f "$KEEPASSXC_RELEASE_JSON" &&
          "$KEEPASSXC_RELEASE_JSON" == /tmp/keepassxc-release.* ]]; then
        rm -f -- "$KEEPASSXC_RELEASE_JSON"
    fi

    if [[ -n "$KEEPASSXC_STAGING_DIR" &&
          -d "$KEEPASSXC_STAGING_DIR" &&
          "$KEEPASSXC_STAGING_DIR" == "${HOME}/Downloads/.keepassxc-download."* ]]; then
        rm -rf -- "$KEEPASSXC_STAGING_DIR"
    fi
}

echo -e "\033[36m<<<<<===== Etap 3: finał instalacji =====>>>>>\033[0m"

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
LOG_STAGE="archconfig3"

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

move_aside_if_needed() {
    local path="$1"

    if [[ -L "$path" ]] && [[ "$(readlink "$path" 2>/dev/null)" == "/dev/null" ]]; then
        return
    fi

    if [[ -e "$path" || -L "$path" ]]; then
        mv "$path" "${path}.disabled-${TIMESTAMP}"
    fi
}

mask_user_unit_file() {
    local unit="$1"
    local path="${USER_SYSTEMD_DIR}/${unit}"

    move_aside_if_needed "$path"
    if [[ ! -L "$path" ]]; then
        ln -s /dev/null "$path"
    fi
}

validate_dev_null_mask() {
    local unit="$1"
    local path="${USER_SYSTEMD_DIR}/${unit}"

    [[ -L "$path" ]] || return 1
    [[ "$(readlink "$path")" == "/dev/null" ]]
}

validate_sway_keyring_order() {
    local ksecretd_line
    local proton_line

    [[ -f "$SWAY_CONFIG" ]] || return 1
    grep -Fqx "$SWAY_IMPORT_SYSTEMD" "$SWAY_CONFIG"
    grep -Fqx "$SWAY_IMPORT_DBUS" "$SWAY_CONFIG"
    grep -Fqx "$SWAY_START_KSECRET" "$SWAY_CONFIG"

    ksecretd_line="$(grep -nF "$SWAY_START_KSECRET" "$SWAY_CONFIG" | awk -F: 'NR == 1 { print $1 }')"
    proton_line="$(grep -n 'protonvpn-app' "$SWAY_CONFIG" | awk -F: 'NR == 1 { print $1 }')"
    [[ -n "$proton_line" ]]
    (( ksecretd_line < proton_line ))
}

resolve_latest_keepassxc_release() {
    local release_json="$1"

    python3 - "$release_json" <<'PY'
import json
import re
import sys
from urllib.parse import urlparse


def fail(message):
    raise SystemExit(f"Nie można zaakceptować wydania KeePassXC: {message}")


try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        release = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    fail(f"niepoprawna odpowiedź JSON ({error})")

if not isinstance(release, dict):
    fail("odpowiedź JSON nie jest obiektem wydania")

if release.get("draft") is not False:
    fail("odpowiedź wskazuje draft")
if release.get("prerelease") is not False:
    fail("odpowiedź wskazuje prerelease")

version = release.get("tag_name")
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    fail("tag nie jest numerem X.Y.Z")

release_url = release.get("html_url")
parsed_release_url = urlparse(release_url if isinstance(release_url, str) else "")
if (
    parsed_release_url.scheme != "https"
    or parsed_release_url.netloc != "github.com"
    or parsed_release_url.path != f"/keepassxreboot/keepassxc/releases/tag/{version}"
):
    fail("niepoprawny adres strony wydania")

expected_names = [
    f"keepassxc-{version}-src.tar.xz",
    f"keepassxc-{version}-src.tar.xz.sig",
    f"keepassxc-{version}-src.tar.xz.DIGEST",
]
assets = release.get("assets")
if not isinstance(assets, list):
    fail("brak listy artefaktów")

resolved_urls = []
for name in expected_names:
    matching_assets = [
        asset
        for asset in assets
        if isinstance(asset, dict) and asset.get("name") == name
    ]
    if len(matching_assets) != 1:
        fail(f"oczekiwano dokładnie jednego artefaktu {name}")

    asset_url = matching_assets[0].get("browser_download_url")
    parsed_asset_url = urlparse(asset_url if isinstance(asset_url, str) else "")
    expected_path = f"/keepassxreboot/keepassxc/releases/download/{version}/{name}"
    if (
        parsed_asset_url.scheme != "https"
        or parsed_asset_url.netloc != "github.com"
        or parsed_asset_url.path != expected_path
        or parsed_asset_url.query
        or parsed_asset_url.fragment
    ):
        fail(f"niepoprawny adres artefaktu {name}")
    resolved_urls.append(asset_url)

print(version)
print(release_url)
print(*resolved_urls, sep="\n")
PY
}

discard_keepassxc_staging() {
    if [[ -n "$KEEPASSXC_RELEASE_JSON" &&
          -f "$KEEPASSXC_RELEASE_JSON" &&
          "$KEEPASSXC_RELEASE_JSON" == /tmp/keepassxc-release.* ]]; then
        rm -f -- "$KEEPASSXC_RELEASE_JSON"
    fi
    KEEPASSXC_RELEASE_JSON=""

    if [[ -n "$KEEPASSXC_STAGING_DIR" &&
          -d "$KEEPASSXC_STAGING_DIR" &&
          "$KEEPASSXC_STAGING_DIR" == "${HOME}/Downloads/.keepassxc-download."* ]]; then
        rm -rf -- "$KEEPASSXC_STAGING_DIR"
    fi
    KEEPASSXC_STAGING_DIR=""
}

download_keepassxc_release() {
    local version="$1"
    local archive_url="$2"
    local signature_url="$3"
    local digest_url="$4"
    local archive="keepassxc-${version}-src.tar.xz"
    local signature="${archive}.sig"
    local digest="${archive}.DIGEST"
    local key="keepassxc_master_signing_key.asc"
    local gnupg_home
    local actual_fingerprint
    local download_dir="${HOME}/Downloads/keepassxc"

    if ! mkdir -p "${HOME}/Downloads"; then
        echo -e "\033[31mNie udało się przygotować katalogu Downloads dla KeePassXC.\033[0m"
        return 1
    fi
    if [[ -e "$download_dir" || -L "$download_dir" ]]; then
        echo -e "\033[31mDocelowy katalog KeePassXC już istnieje: ${download_dir}\033[0m"
        return 1
    fi
    if ! KEEPASSXC_STAGING_DIR="$(mktemp -d "${HOME}/Downloads/.keepassxc-download.XXXXXX")"; then
        echo -e "\033[31mNie udało się utworzyć katalogu tymczasowego KeePassXC.\033[0m"
        return 1
    fi

    if ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "$archive_url" -o "${KEEPASSXC_STAGING_DIR}/${archive}"; then
        echo -e "\033[31mNie udało się pobrać archiwum KeePassXC.\033[0m"
        return 1
    fi
    if ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "$signature_url" -o "${KEEPASSXC_STAGING_DIR}/${signature}"; then
        echo -e "\033[31mNie udało się pobrać podpisu KeePassXC.\033[0m"
        return 1
    fi
    if ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "$digest_url" -o "${KEEPASSXC_STAGING_DIR}/${digest}"; then
        echo -e "\033[31mNie udało się pobrać digestu KeePassXC.\033[0m"
        return 1
    fi
    if ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "$KEEPASSXC_SIGNING_KEY_URL" -o "${KEEPASSXC_STAGING_DIR}/${key}"; then
        echo -e "\033[31mNie udało się pobrać klucza KeePassXC.\033[0m"
        return 1
    fi

    if ! (
        cd "$KEEPASSXC_STAGING_DIR" &&
            sha256sum -c "$digest"
    ); then
        echo -e "\033[31mSuma SHA-256 archiwum KeePassXC jest niezgodna.\033[0m"
        return 1
    fi

    gnupg_home="${KEEPASSXC_STAGING_DIR}/.gnupg"
    if ! install -d -m 0700 "$gnupg_home"; then
        echo -e "\033[31mNie udało się przygotować tymczasowego keyringu KeePassXC.\033[0m"
        return 1
    fi
    if ! actual_fingerprint="$(
        gpg --homedir "$gnupg_home" --batch --with-colons \
            --import-options show-only --import "${KEEPASSXC_STAGING_DIR}/${key}" 2>/dev/null |
            awk -F: '$1 == "fpr" { print $10; exit }'
    )"; then
        echo -e "\033[31mNie udało się odczytać fingerprintu klucza KeePassXC.\033[0m"
        return 1
    fi
    if [[ "$actual_fingerprint" != "$KEEPASSXC_SIGNING_FINGERPRINT" ]]; then
        echo -e "\033[31mFingerprint klucza KeePassXC jest niezgodny z oczekiwanym.\033[0m"
        return 1
    fi
    if ! gpg --homedir "$gnupg_home" --batch \
        --import "${KEEPASSXC_STAGING_DIR}/${key}"; then
        echo -e "\033[31mNie udało się zaimportować klucza KeePassXC do tymczasowego keyringu.\033[0m"
        return 1
    fi
    if ! gpg --homedir "$gnupg_home" --batch \
        --verify "${KEEPASSXC_STAGING_DIR}/${signature}" \
        "${KEEPASSXC_STAGING_DIR}/${archive}"; then
        echo -e "\033[31mPodpis archiwum KeePassXC jest niepoprawny.\033[0m"
        return 1
    fi
    if ! rm -rf -- "$gnupg_home"; then
        echo -e "\033[31mNie udało się usunąć tymczasowego keyringu KeePassXC.\033[0m"
        return 1
    fi

    if [[ "$version" == "2.7.12" ]]; then
        if ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
            "$KEEPASSXC_2712_PATCH_URL" -o "${KEEPASSXC_STAGING_DIR}/keepassxc-botan-3.10.patch"; then
            echo -e "\033[33mNie udało się pobrać opcjonalnego patcha Botan dla KeePassXC 2.7.12.\033[0m"
            log_line "WARN" "KEEPASSXC_PATCH_FAILED" \
                "nie pobrano opcjonalnego patcha Botan dla KeePassXC 2.7.12"
        fi
    else
        echo "Brak patcha specyficznego dla KeePassXC ${version}; stary patch 2.7.12 został pominięty."
    fi

    if ! mv -- "$KEEPASSXC_STAGING_DIR" "$download_dir"; then
        echo -e "\033[31mNie udało się zapisać zweryfikowanych plików KeePassXC.\033[0m"
        return 1
    fi
    KEEPASSXC_STAGING_DIR=""
    echo "Zweryfikowane źródła KeePassXC ${version} zapisano w ${download_dir}."
    echo "Kompilację i instalację wykonaj ręcznie po instalacji systemu."
}

offer_keepassxc_release() {
    local release_data
    local confirmation
    local version
    local release_url
    local archive_url
    local signature_url
    local digest_url
    local -a release_fields

    echo -e "\033[36m<<<<<===== Ustalenie aktualnego wydania KeePassXC =====>>>>>\033[0m"
    if ! KEEPASSXC_RELEASE_JSON="$(mktemp /tmp/keepassxc-release.XXXXXX)"; then
        echo -e "\033[31mNie udało się utworzyć pliku tymczasowego dla metadanych KeePassXC.\033[0m"
        return 1
    fi
    if ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: ArchInstaller' \
        "$KEEPASSXC_RELEASE_API" -o "$KEEPASSXC_RELEASE_JSON"; then
        echo -e "\033[31mNie udało się pobrać informacji o aktualnym wydaniu KeePassXC.\033[0m"
        return 1
    fi
    if ! release_data="$(resolve_latest_keepassxc_release "$KEEPASSXC_RELEASE_JSON")"; then
        return 1
    fi
    rm -f -- "$KEEPASSXC_RELEASE_JSON"
    KEEPASSXC_RELEASE_JSON=""

    mapfile -t release_fields <<< "$release_data"
    if (( ${#release_fields[@]} != 5 )); then
        echo -e "\033[31mNiekompletne dane wydania KeePassXC.\033[0m"
        return 1
    fi
    version="${release_fields[0]}"
    release_url="${release_fields[1]}"
    archive_url="${release_fields[2]}"
    signature_url="${release_fields[3]}"
    digest_url="${release_fields[4]}"

    echo "Aktualne stabilne wydanie KeePassXC: ${version}"
    echo "Strona wydania: ${release_url}"
    log_input_expected "operator ma zaakceptować wydanie KeePassXC ${version} dokładnym Y"
    if ! read -r -p "Pobrać i zweryfikować to wydanie? Wpisz Y, aby kontynuować: " confirmation; then
        echo
        echo -e "\033[31mNie udało się odczytać decyzji operatora dla KeePassXC.\033[0m"
        return 1
    fi
    echo
    if [[ "$confirmation" != "Y" ]]; then
        echo "Pobieranie KeePassXC pominięte przez operatora."
        return 2
    fi
    log_input_confirmed "operator zaakceptował wydanie KeePassXC ${version}"

    echo -e "\033[36m<<<<<===== Pobranie i weryfikacja KeePassXC ${version} =====>>>>>\033[0m"
    download_keepassxc_release \
        "$version" "$archive_url" "$signature_url" "$digest_url"
}

init_install_log
printf 'META|ts=%s|stage=%s|format=archinstaller-log-v1|location=%s\n' "$(date '+%F %T')" "$LOG_STAGE" "$INSTALL_LOG_FILE" >> "$INSTALL_LOG_FILE"
log_section "Start archconfig3.sh"
log_info "Log instalacyjny: ${INSTALL_LOG_FILE}"
log_info "Profil laptopa: ${MACHINE_PROFILE_ID} (${MACHINE_LABEL})"

echo -e "\033[36m<<<<<===== Błędy po etapie 2 =====>>>>>\033[0m"
journalctl -p 3 -xb || true
systemctl --failed || true
audit_checkpoint "ocena bootu po aktywacji AppArmor przed finalizacją etapu 3"

echo -e "\033[36m<<<<<===== Autoryzacja sudo dla etapu 3 =====>>>>>\033[0m"
echo "Za chwilę sudo może poprosić o hasło użytkownika matt."
echo "To jest oczekiwane i służy utrzymaniu autoryzacji na cały etap 3."
log_input_expected "operator może podać hasło sudo na początku archconfig3.sh"
sudo -v
log_input_confirmed "operator potwierdził autoryzację sudo na początku archconfig3.sh"
(
    while true; do
        sleep 60
        sudo -n true || exit
    done
) &
SUDO_KEEPALIVE_PID=$!
trap cleanup_runtime EXIT

if offer_keepassxc_release; then
    log_info "Pobrano i zweryfikowano opcjonalne źródła KeePassXC"
else
    keepassxc_result=$?
    discard_keepassxc_staging
    if (( keepassxc_result == 2 )); then
        log_line "INFO" "KEEPASSXC_SKIPPED" \
            "operator pominął opcjonalne pobieranie źródeł KeePassXC"
    else
        echo -e "\033[33mKrok KeePassXC nie powiódł się; instalator kontynuuje. Szczegóły są w logu.\033[0m"
        log_line "WARN" "KEEPASSXC_FAILED" \
            "opcjonalny krok KeePassXC nie powiódł się; etap 3 jest kontynuowany"
    fi
fi

echo -e "\033[36m<<<<<===== Włączenie firejail =====>>>>>\033[0m"
sudo apparmor_parser -r /etc/apparmor.d/firejail-default

echo -e "\033[36m<<<<<===== Minimalna konfiguracja greetd =====>>>>>\033[0m"
echo "To jest tylko start GUI: autologin matt -> sway."
sudo mkdir -p /etc/greetd
if [[ -f /etc/greetd/config.toml ]]; then
    sudo cp /etc/greetd/config.toml /etc/greetd/config.toml_backup
fi
sudo tee /etc/greetd/config.toml >/dev/null <<'EOF'
[terminal]
vt = 1

[initial_session]
command = "env XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=sway XDG_SESSION_DESKTOP=sway sway"
user = "matt"

[default_session]
command = "agreety --cmd sway"
user = "greeter"
EOF
sudo systemctl enable greetd.service

echo -e "\033[36m<<<<<===== Pobranie pakietu dotfiles =====>>>>>\033[0m"
echo "Archiwum dotfiles.tar rozpakowuje katalog /home/matt/dotfiles."
curl -fLO "${BASE_URL}/dotfiles.tar"
if [[ -e /home/matt/dotfiles ]]; then
    mv /home/matt/dotfiles "/home/matt/dotfiles_backup_$(date +%Y%m%d%H%M%S)"
fi
tar -xf dotfiles.tar -C /home/matt
chmod +x /home/matt/dotfiles/dotfiles.sh
if [[ -f /home/matt/dotfiles/Downloads/aur_po_gui.sh ]]; then
    chmod +x /home/matt/dotfiles/Downloads/aur_po_gui.sh
fi
sudo chown -R matt:matt /home/matt/dotfiles
/home/matt/dotfiles/dotfiles.sh

echo -e "\033[36m<<<<<===== Instalacja przypiętej wersji Transmission GTK =====>>>>>\033[0m"
transmission_package="/home/matt/dotfiles/_backup/transmission-gtk-4.0.6-10-x86_64.pkg.tar.zst"
transmission_signature="${transmission_package}.sig"
[[ -f "$transmission_package" ]]
[[ -f "$transmission_signature" ]]
pacman-key --verify "$transmission_signature" "$transmission_package"
run_logged sudo pacman -U --needed --noconfirm "$transmission_package"

echo -e "\033[36m<<<<<===== Konfiguracja KWallet, KSecretD i portali Sway =====>>>>>\033[0m"
command -v kwriteconfig6 >/dev/null 2>&1
command -v kreadconfig6 >/dev/null 2>&1
command -v ksecretd >/dev/null 2>&1
validate_sway_keyring_order

mkdir -p "$USER_SYSTEMD_DIR"
systemctl --user disable --now gnome-keyring-daemon.service gnome-keyring-daemon.socket 2>/dev/null || true
mask_user_unit_file gnome-keyring-daemon.service
mask_user_unit_file gnome-keyring-daemon.socket
mask_user_unit_file 'app-gnome\x2dkeyring\x2dpkcs11@autostart.service'
mask_user_unit_file 'app-gnome\x2dkeyring\x2dsecrets@autostart.service'
mask_user_unit_file 'app-gnome\x2dkeyring\x2dssh@autostart.service'

if [[ -e "${USER_SYSTEMD_DIR}/ksecretd.service" || -L "${USER_SYSTEMD_DIR}/ksecretd.service" ]]; then
    systemctl --user disable --now ksecretd.service 2>/dev/null || true
    move_aside_if_needed "${USER_SYSTEMD_DIR}/ksecretd.service"
fi
systemctl --user reset-failed ksecretd.service 2>/dev/null || true
systemctl --user daemon-reload

kwriteconfig6 --file kwalletrc --group Wallet --key Enabled true
kwriteconfig6 --file kwalletrc --group Wallet --key 'Default Wallet' login
kwriteconfig6 --file kwalletrc --group Wallet --key 'First Use' false
kwriteconfig6 --file kwalletrc --group KSecretD --key Enabled true
kwriteconfig6 --file kwalletrc --group org.freedesktop.secrets --key apiEnabled true

mkdir -p "$(dirname "$PORTAL_CONFIG")"
cat > "$PORTAL_CONFIG" <<'EOF'
[preferred]
default=gtk
org.freedesktop.impl.portal.ScreenCast=wlr
org.freedesktop.impl.portal.Screenshot=wlr
org.freedesktop.impl.portal.Inhibit=none
org.freedesktop.impl.portal.Secret=kwallet
EOF

local_dbus_secret_override="${HOME}/.local/share/dbus-1/services/org.freedesktop.secrets.service"
move_aside_if_needed "$local_dbus_secret_override"

pacman -Q kwallet kwalletmanager >/dev/null
[[ ! -e "${USER_SYSTEMD_DIR}/ksecretd.service" && ! -L "${USER_SYSTEMD_DIR}/ksecretd.service" ]]
[[ ! -e "$local_dbus_secret_override" && ! -L "$local_dbus_secret_override" ]]
validate_dev_null_mask gnome-keyring-daemon.service
validate_dev_null_mask gnome-keyring-daemon.socket
validate_dev_null_mask 'app-gnome\x2dkeyring\x2dpkcs11@autostart.service'
validate_dev_null_mask 'app-gnome\x2dkeyring\x2dsecrets@autostart.service'
validate_dev_null_mask 'app-gnome\x2dkeyring\x2dssh@autostart.service'
grep -Fqx 'default=gtk' "$PORTAL_CONFIG"
grep -Fqx 'org.freedesktop.impl.portal.ScreenCast=wlr' "$PORTAL_CONFIG"
grep -Fqx 'org.freedesktop.impl.portal.Screenshot=wlr' "$PORTAL_CONFIG"
grep -Fqx 'org.freedesktop.impl.portal.Inhibit=none' "$PORTAL_CONFIG"
grep -Fqx 'org.freedesktop.impl.portal.Secret=kwallet' "$PORTAL_CONFIG"
[[ "$(kreadconfig6 --file kwalletrc --group Wallet --key Enabled)" == "true" ]]
[[ "$(kreadconfig6 --file kwalletrc --group Wallet --key 'Default Wallet')" == "login" ]]
[[ "$(kreadconfig6 --file kwalletrc --group Wallet --key 'First Use')" == "false" ]]
[[ "$(kreadconfig6 --file kwalletrc --group KSecretD --key Enabled)" == "true" ]]
[[ "$(kreadconfig6 --file kwalletrc --group org.freedesktop.secrets --key apiEnabled)" == "true" ]]
log_info "Skonfigurowano KWallet/KSecretD, maski GNOME Keyring i portale Sway"

echo -e "\033[36m<<<<<===== Konfiguracja Oh My Zsh =====>>>>>\033[0m"
echo "To włącza zsh jako domyślną powłokę i dodaje pluginy używane w .zshrc."
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    tmp_dir="$(mktemp -d)"
    curl -fLo "${tmp_dir}/install.sh" https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "${tmp_dir}/install.sh" --unattended
    rm -rf "${tmp_dir}"
fi

zsh_custom="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"
if [[ ! -d "${zsh_custom}/plugins/zsh-autosuggestions" ]]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions "${zsh_custom}/plugins/zsh-autosuggestions"
fi
if [[ ! -d "${zsh_custom}/plugins/zsh-syntax-highlighting" ]]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting "${zsh_custom}/plugins/zsh-syntax-highlighting"
fi

sudo chsh -s /usr/bin/zsh "$(id -un)"

echo -e "\033[36m<<<<<===== Instalacja yay =====>>>>>\033[0m"
echo "yay jest obowiązkowy dla późniejszej ręcznej instalacji pakietów AUR."
if ! command -v yay >/dev/null 2>&1; then
    yay_build_dir="$(mktemp -d)"
    git clone https://aur.archlinux.org/yay.git "${yay_build_dir}/yay"
    (
        cd "${yay_build_dir}/yay"
        makepkg -si --noconfirm
    )
    rm -rf "$yay_build_dir"
fi
audit_checkpoint "weryfikacja konfiguracji środowiska po greetd, portalach, dotfiles i yay"

echo -e "\033[36m<<<<<===== Przygotowanie katalogu VirtualBox_VMs =====>>>>>\033[0m"
echo "Ten katalog ma NoCOW i nie jest częścią snapshotów, bo leży w /home."
sudo install -d -m 755 -o matt -g matt /home/matt/VirtualBox_VMs
sudo chattr +C /home/matt/VirtualBox_VMs

echo -e "\033[36m<<<<<===== Konfiguracja Dockera =====>>>>>\033[0m"
sudo usermod -aG docker "$(id -un)"
sudo systemctl enable --now docker.service

echo -e "\033[36m<<<<<===== Lokalne uprawnienia sudo/polkit =====>>>>>\033[0m"
sudo tee /etc/sudoers.d/20-matt-nopasswd >/dev/null <<'EOF'
matt ALL=(ALL) NOPASSWD: /usr/bin/cryptsetup
matt ALL=(ALL) NOPASSWD: /usr/bin/mount
matt ALL=(ALL) NOPASSWD: /usr/bin/reflector
matt ALL=(ALL) NOPASSWD: /usr/bin/rsync
matt ALL=(root) NOPASSWD: /usr/bin/tlp
EOF
sudo chmod 0440 /etc/sudoers.d/20-matt-nopasswd
sudo visudo -cf /etc/sudoers.d/20-matt-nopasswd

sudo mkdir -p /etc/polkit-1/rules.d
sudo tee /etc/polkit-1/rules.d/99-udisks.rules >/dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
         action.id == "org.freedesktop.udisks2.filesystem-mount") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF

if [[ "$ENABLE_RTS522A_PM_FIX" == "1" ]]; then
    echo -e "\033[36m<<<<<===== Konfiguracja czytnika kart Realtek RTS522A =====>>>>>\033[0m"
    [[ "$(cat /sys/bus/pci/devices/0000:04:00.0/vendor)" == "0x10ec" ]]
    [[ "$(cat /sys/bus/pci/devices/0000:04:00.0/device)" == "0x522a" ]]
    sudo tee /etc/systemd/system/rtsx-pm-fix.service >/dev/null <<'EOF'
[Unit]
Description=Disable runtime PM for Realtek RTS522A card reader
After=systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo on > /sys/bus/pci/devices/0000:04:00.0/power/control'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 0644 /etc/systemd/system/rtsx-pm-fix.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now rtsx-pm-fix.service
    sudo systemctl is-enabled --quiet rtsx-pm-fix.service
    sudo systemctl is-active --quiet rtsx-pm-fix.service
    [[ "$(cat /sys/bus/pci/devices/0000:04:00.0/power/control)" == "on" ]]
    log_info "Wyłączono runtime PM dla czytnika Realtek RTS522A 0000:04:00.0"
else
    echo -e "\033[36m<<<<<===== Pominięcie poprawki czytnika RTS522A =====>>>>>\033[0m"
    echo "Profil ${MACHINE_LABEL} nie używa czytnika PCI RTS522A z T14."
    log_info "Pominięto poprawkę RTS522A dla profilu ${MACHINE_PROFILE_ID}"
fi

echo -e "\033[36m<<<<<===== Błędy po etapie 3 =====>>>>>\033[0m"
journalctl -p 3 -xb || true
systemctl --failed || true
audit_checkpoint "ostatnia kontrola stanu przed utworzeniem snapshotu końcowego"

echo -e "\033[36m<<<<<===== Usunięcie pliku profilu z systemu bazowego =====>>>>>\033[0m"
sudo rm -f /root/archinstaller.env
log_info "Usunięto /root/archinstaller.env przed snapshotem końcowym"

echo -e "\033[36m<<<<<===== Pierwszy snapshot systemowy =====>>>>>\033[0m"
echo "To jest stan zero po instalacji, jeszcze przed pierwszym wejściem do GUI."
sudo snapper -c root create \
    --type single \
    --cleanup-algorithm number \
    --description "post-install pre-gui $(date +%F_%H-%M-%S)"

echo -e "\033[36m<<<<<===== Końcowe porządki =====>>>>>\033[0m"
echo "Automatyczne usuwanie plików instalacyjnych z /home/matt."
rm -f archconfig2.sh archconfig3.sh "$ENV_FILE" dotfiles.tar
log_info "Usunięto /home/matt/archinstaller.env i pozostałe pliki robocze"

echo -e "\033[36m<<<<<===== System przygotowany do pierwszego wejścia w GUI =====>>>>>\033[0m"
echo "Po pierwszym logowaniu skopiuj /home/matt/recovery na osobny nośnik USB."
echo "Secure Boot włączaj dopiero po potwierdzeniu, że UKI startuje poprawnie."
echo "Po pierwszym wejściu do Sway uruchom kwalletmanager5 i utwórz portfel:"
echo "  nazwa: login"
echo "  typ: Classic, blowfish encrypted file"
echo "  hasło: puste"
echo "  GPG: nie wybieraj"
echo "Ten etap nie wykonuje restartu automatycznie."
echo "Teraz wykonaj ręcznie dokładnie:"
echo "  reboot"
log_input_expected "operator ma wykonać ręczny reboot po archconfig3.sh"
