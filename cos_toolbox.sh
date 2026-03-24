#!/usr/bin/env bash
# ============================================================
#  ColorOS 16 Auto-Porter for Xiaomi 11 Ultra/Pro
#  By tm_palaziks (TG: @tm_palaziks)
#  Version: V2.0 (BASH REWRITE)
#
#  Requirements:
#    - Java JDK 8+
#    - APKEditor.jar in tools/
#    - Unpacked ColorOS ROM partitions in working directory
#    - RES folder with all needed files
# ============================================================

set -euo pipefail

# ── Detect environment ────────────────────────────────────────
IS_ANDROID=false
if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d "/data/data/com.termux" ]]; then
    IS_ANDROID=true
fi

# ── Paths ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
RES_DIR="$SCRIPT_DIR/RES"
PORT_DIR="$SCRIPT_DIR"
TOOLS_DIR="$SCRIPT_DIR/tools"
LOG_DIR="$SCRIPT_DIR/logs"
APKEDITOR="$TOOLS_DIR/APKEditor.jar"
LOG_FILE="$LOG_DIR/palazikbox.log"

MY_PARTITIONS=(
    my_bigball my_carrier my_company my_custom
    my_engineering my_heytap my_manifest my_preload
    my_product my_region my_stock my_version
)

# ── Logging ──────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}
log_info()  { log "INFO " "$@"; }
log_error() { log "ERROR" "$@"; }
log_warn()  { log "WARN " "$@"; }

# ── Tool helpers ─────────────────────────────────────────────
check_tools() {
    echo "[*] Checking required tools..."
    mkdir -p "$TOOLS_DIR"

    # Java
    if ! java -version &>/dev/null; then
        echo "✗ Java not found!"
        if [[ "$IS_ANDROID" == true ]]; then
            echo "  → Install via Termux: pkg install openjdk-17"
        else
            echo "  → Install: sudo apt install default-jdk  OR  sudo pacman -S jdk-openjdk"
        fi
        exit 1
    fi
    echo "✓ Java found"

    # Python3
    if ! python3 --version &>/dev/null; then
        echo "✗ Python3 not found!"
        if [[ "$IS_ANDROID" == true ]]; then
            echo "  → Install via Termux: pkg install python"
        else
            echo "  → Install: sudo apt install python3  OR  sudo pacman -S python"
        fi
        exit 1
    fi
    echo "✓ Python3 found"

    # APKEditor
    if [[ ! -f "$APKEDITOR" ]]; then
        echo "✗ APKEditor.jar not found in tools/"
        echo "  → Run setup.sh to download it automatically"
        exit 1
    fi
    echo "✓ APKEditor found"
}

# ── APKEditor pack / unpack ───────────────────────────────────
apkeditor_unpack() {
    local input="$1"
    local output_dir="$2"
    if [[ ! -f "$input" ]]; then
        log_error "File not found: $input"
        return 1
    fi
    rm -rf "$output_dir"
    log_info "Unpacking: $input -> $output_dir"
    java -jar "$APKEDITOR" d -f -i "$input" -o "$output_dir" >> "$LOG_FILE" 2>&1
}

apkeditor_pack() {
    local input_dir="$1"
    local output="$2"
    if [[ ! -d "$input_dir" ]]; then
        log_error "Directory not found: $input_dir"
        return 1
    fi
    log_info "Packing: $input_dir -> $output"
    java -jar "$APKEDITOR" b -i "$input_dir" -o "$output" >> "$LOG_FILE" 2>&1
}

# ── Backup ───────────────────────────────────────────────────
backup_file() {
    local file="$1"
    local bak="${file}.bak"
    if [[ -f "$file" && ! -f "$bak" ]]; then
        cp -a "$file" "$bak"
        log_info "Backup: $(basename "$bak")"
    fi
}

# ── sed-based smali helpers ───────────────────────────────────
# Find a .smali file by class path under a decompiled directory
find_smali() {
    local work_dir="$1"
    local class_path="$2"   # e.g. com/android/server/OplusBatteryService.smali
    find "$work_dir" -type f -name "$(basename "$class_path")" \
        | grep -F "$class_path" | head -1
}

# Patch smali: replace first occurrence of pattern with replacement (sed ERE)
smali_replace() {
    local file="$1"
    local pattern="$2"   # extended regex
    local replacement="$3"
    sed -i -E "s|${pattern}|${replacement}|" "$file"
}

# Delete lines matching pattern
smali_delete_lines() {
    local file="$1"
    local pattern="$2"
    sed -i "/${pattern}/d" "$file"
}

# Insert text after first line matching pattern
smali_insert_after() {
    local file="$1"
    local pattern="$2"
    local insert="$3"
    # Use awk for multi-line inserts
    awk -v pat="$pattern" -v ins="$insert" '
        $0 ~ pat && !done { print; print ins; done=1; next }
        { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Check if string exists in file
smali_has() {
    local file="$1"
    local pattern="$2"
    grep -qF "$pattern" "$file" 2>/dev/null
}

# ── Build prop helpers ────────────────────────────────────────
prop_add_if_missing() {
    local file="$1"
    local marker="$2"   # unique string to check
    local content="$3"
    mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || touch "$file"
    if ! grep -qF "$marker" "$file"; then
        printf '%s\n' "$content" >> "$file"
        echo "  Props added to $(basename "$file")"
    else
        echo "  Props already exist in $(basename "$file")"
    fi
}

prop_delete_lines() {
    local file="$1"
    shift
    local patterns=("$@")
    if [[ ! -f "$file" ]]; then
        echo "  Warning: $file not found"
        return 0
    fi
    local deleted=0
    for p in "${patterns[@]}"; do
        local before; before=$(wc -l < "$file")
        sed -i "/^${p}/d" "$file"
        local after; after=$(wc -l < "$file")
        (( deleted += before - after )) || true
    done
    echo "  Deleted $deleted prop lines"
}

# ── Copy RES directory recursively ───────────────────────────
copy_res_dir() {
    local src="$1"
    local dst_base="$2"
    local copied=0
    local replaced=0
    if [[ ! -d "$src" ]]; then
        echo "  Warning: $src not found, skipping..."
        return 0
    fi
    while IFS= read -r -d '' f; do
        local rel="${f#${src}/}"
        local dst="$dst_base/$rel"
        mkdir -p "$(dirname "$dst")"
        if [[ -e "$dst" ]]; then (( replaced++ )) || true; else (( copied++ )) || true; fi
        cp -a "$f" "$dst"
    done < <(find "$src" -type f -print0)
    echo "  Copied: $copied new, $replaced replaced"
}

# ── STEP 1: Merge my_* partitions ────────────────────────────
step1_merge_partitions() {
    echo ""
    echo "[STEP 1] Merging my_* partitions to system..."
    local system_dir="$PORT_DIR/system"
    mkdir -p "$system_dir"
    local merged=0
    for part in "${MY_PARTITIONS[@]}"; do
        local src="$PORT_DIR/$part"
        local dst="$system_dir/$part"
        if [[ -d "$src" ]]; then
            rm -rf "$dst"
            mv "$src" "$dst"
            echo "  Moved: $part"
            (( merged++ )) || true
        fi
    done
    echo "  Merged $merged partitions"
}

# ── STEP 2: Copy RES files ────────────────────────────────────
step2_copy_res_files() {
    echo ""
    echo "[STEP 2] Copying RES files..."
    local res_res="$RES_DIR/RES"
    if [[ ! -d "$res_res" ]]; then
        echo "Error: $res_res not found!"
        return 1
    fi
    copy_res_dir "$res_res" "$PORT_DIR"
}

# ── STEP 3: Modify build.prop ─────────────────────────────────
step3_modify_build_prop() {
    echo ""
    echo "[STEP 3] Modifying build.prop..."
    local bp="$PORT_DIR/system/system/build.prop"
    mkdir -p "$(dirname "$bp")"
    [[ -f "$bp" ]] || touch "$bp"
    prop_add_if_missing "$bp" "import /my_bigball/build.prop" \
"
# My Partition Imports
import /my_bigball/build.prop
import /my_carrier/build.prop
import /my_company/build.prop
import /my_custom/build.prop
import /my_engineering/build.prop
import /my_heytap/build.prop
import /my_manifest/build.prop
import /my_preload/build.prop
import /my_product/build.prop
import /my_region/build.prop
import /my_stock/build.prop
import /my_version/build.prop"
}

# ── STEP 4: Delete screen zoom props ─────────────────────────
step4_delete_screen_zoom_props() {
    echo ""
    echo "[STEP 4] Deleting screen zoom props..."
    local bp="$PORT_DIR/system/my_product/build.prop"
    prop_delete_lines "$bp" \
        "ro.density.screenzoom.fdh=" \
        "ro.density.screenzoom.qdh=" \
        "ro.oplus.density.fhd_default=" \
        "ro.oplus.density.qhd_default=" \
        "ro.oplus.resolution.low=" \
        "ro.oplus.resolution.high=" \
        "ro.oplus.display.screenhole.positon="
}

# ── STEP 5: Add extra props ───────────────────────────────────
step5_add_extra_props() {
    echo ""
    echo "[STEP 5] Adding extra props..."
    local bp="$PORT_DIR/system/my_product/build.prop"
    prop_add_if_missing "$bp" "ro.sf.lcd_density=600" \
"
# Extra Props
ro.sf.lcd_density=600
ro.oplus.density.qhd_default=600
ro.density.screenzoom.qdh=500,560,640,680,720
ro.oplus.resolution.high=1440,3200"
}

# ── MODE 2: Fix SuperVOOC ─────────────────────────────────────
mode2_fix_supervooc() {
    echo ""
    echo "[MODE 2] Fixing SUPERVOOC charging animation..."

    # --- oplus-services.jar ---
    local jar="$PORT_DIR/system/system/framework/oplus-services.jar"
    if [[ ! -f "$jar" ]]; then echo "Error: $jar not found!"; return 1; fi

    local work="$PORT_DIR/work_supervooc"
    backup_file "$jar"
    apkeditor_unpack "$jar" "$work"

    local smali_file
    smali_file="$(find_smali "$work" "com/android/server/OplusBatteryService.smali")"
    if [[ -z "$smali_file" ]]; then
        echo "  Error: OplusBatteryService.smali not found!"
        rm -rf "$work"; return 1
    fi

    # Check getBroadcastDataFromHal exists
    if ! smali_has "$smali_file" "getBroadcastDataFromHal"; then
        echo "  Error: getBroadcastDataFromHal method not found!"
        rm -rf "$work"; return 1
    fi

    # Use awk to insert hook before last return-void of getBroadcastDataFromHal
    python3 - "$smali_file" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

hook = """
        # ADD THIS
        invoke-direct {p0}, Lcom/android/server/OplusBatteryService;->rianixiaCharge()V
        # ADD THIS"""

new_method = """
.method private rianixiaCharge()V
    .locals 5

    .line 2000
    const-string v0, "persist.sys.rianixia.charge-wattage"
    const/4 v1, 0x0
    invoke-static {v0, v1}, Landroid/os/SystemProperties;->getInt(Ljava/lang/String;I)I

    move-result v0

    if-eqz v0, :cond_1c

    const/4 v1, 0x3
    iput v1, p0, Lcom/android/server/OplusBatteryService;->mChargerTechnology:I
    const/4 v1, 0x1
    iput v1, p0, Lcom/android/server/OplusBatteryService;->mIsSupSpeedCharge:I
    iput v0, p0, Lcom/android/server/OplusBatteryService;->mChargeWattage:I
    iput v0, p0, Lcom/android/server/OplusBatteryService;->mCPAChargeWattage:I

    .line 2015
    :cond_1c
    return-void
.end method
"""

content = re.sub(
    r'(\.method.*getBroadcastDataFromHal.*?)(return-void\s+\.end method)',
    r'\1' + hook + '\n    \n    return-void\n.end method',
    content, flags=re.DOTALL
)
content = content.rstrip() + '\n\n' + new_method + '\n'
with open(path, 'w') as f:
    f.write(content)
print("  Patched: OplusBatteryService")
PYEOF

    local new_jar="${jar%.jar}.new.jar"
    apkeditor_pack "$work" "$new_jar"
    mv "$new_jar" "$jar"
    rm -rf "$work"

    # --- SystemUI.apk ---
    local systemui="$PORT_DIR/system_ext/priv-app/SystemUI/SystemUI.apk"
    if [[ ! -f "$systemui" ]]; then
        echo "  Warning: SystemUI.apk not found, skipping"
        echo "  SUPERVOOC partially fixed (oplus-services.jar only)"
        return 0
    fi

    local work2="$PORT_DIR/work_supervooc_systemui"
    backup_file "$systemui"
    apkeditor_unpack "$systemui" "$work2"

    # Use sed to find and replace isChargeVoocSpecialColorShow method
    local smali2
    smali2="$(grep -rl "isChargeVoocSpecialColorShow" "$work2" 2>/dev/null | head -1 || true)"
    if [[ -n "$smali2" ]]; then
        python3 - "$smali2" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

new_method = """.method public static isChargeVoocSpecialColorShow()Z
    .registers 1
    const/4 v0, 0x1

    .line 13
    return v0
.end method"""

content = re.sub(
    r'\.method public static isChargeVoocSpecialColorShow\(\)Z.*?\.end method',
    new_method, content, flags=re.DOTALL
)
with open(path, 'w') as f:
    f.write(content)
print("  Patched: isChargeVoocSpecialColorShow()")
PYEOF
    else
        echo "  Warning: isChargeVoocSpecialColorShow() not found in SystemUI"
    fi

    local new_apk="${systemui%.apk}.new.apk"
    apkeditor_pack "$work2" "$new_apk"
    mv "$new_apk" "$systemui"
    rm -rf "$work2"

    echo "  SUPERVOOC fixed"
}

# ── MODE 3: Fix AOD ───────────────────────────────────────────
mode3_fix_aod() {
    echo ""
    echo "[MODE 3] Fixing AOD..."

    local jar="$PORT_DIR/system/system/framework/oplus-services.jar"
    if [[ ! -f "$jar" ]]; then echo "Error: $jar not found!"; return 1; fi

    local work="$PORT_DIR/work_aod"
    backup_file "$jar"
    apkeditor_unpack "$jar" "$work"

    local smali_file
    smali_file="$(find_smali "$work" "com/android/server/power/OplusFeatureAOD.smali")"
    if [[ -z "$smali_file" ]]; then
        echo "  Error: OplusFeatureAOD.smali not found!"
        rm -rf "$work"; return 1
    fi

    python3 - "$smali_file" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

aod_fix_tmpl = """
    # Rianixia: Start AOD Doze Suspend block
    const/4 v0, 0x4
    if-ne p1, v0, :cond_{TAG}
    const/4 p1, 0x3
    :cond_{TAG}
    # Rianixia: End AOD Doze Suspend block
"""

for tag, method in [
    ("aod_fix_1", r"\.method public setDozeOverride\(II\)V.*?\.param p2.*?\n"),
    ("aod_fix_2", r"\.method public setDozeOverrideFromDreamManager\(II\)V.*?\.param p2.*?\n"),
    ("aod_fix_3", r"\.method public setDozeOverrideFromDreamManagerInternal\(II\)I.*?\.param p2.*?\n"),
]:
    fix = aod_fix_tmpl.replace("{TAG}", tag)
    content = re.sub(
        r'(' + method + r')',
        r'\1' + fix + '\n',
        content, flags=re.DOTALL
    )

with open(path, 'w') as f:
    f.write(content)
print("  Patched: OplusFeatureAOD (3 methods)")
PYEOF

    local new_jar="${jar%.jar}.new.jar"
    apkeditor_pack "$work" "$new_jar"
    mv "$new_jar" "$jar"
    rm -rf "$work"
    echo "  AOD fixed"
}

# ── MODE 4: Fix Seamless & Fullscreen AOD ────────────────────
mode4_fix_fullscreen_aod() {
    echo ""
    echo "[MODE 4] Fixing Seamless & Fullscreen AOD..."

    # ── SystemUI.apk ─────────────────────────────────────────
    local systemui="$PORT_DIR/system_ext/priv-app/SystemUI/SystemUI.apk"
    if [[ ! -f "$systemui" ]]; then echo "  Error: SystemUI.apk not found!"; return 1; fi

    local work="$PORT_DIR/work_systemui_aod"
    backup_file "$systemui"
    apkeditor_unpack "$systemui" "$work"

    local aod_feature
    aod_feature="$(find_smali "$work" "com/oplusos/systemui/common/feature/AodFeatureOption.smali")"
    if [[ -n "$aod_feature" ]]; then
        python3 - "$aod_feature" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

content = re.sub(
    r'\.method public static isSupportRamLessAod\(\)Z.*?\.end method',
    '''.method public static isSupportRamLessAod()Z
    .registers 1
    const/4 v0, 0x1
    return v0
.end method''',
    content, flags=re.DOTALL
)
content = re.sub(
    r'\.method public static isSupportLTPO1HzAOD\(\)Z.*?\.end method',
    '''.method public static isSupportLTPO1HzAOD()Z
    .registers 1
    const/4 v0, 0x1
    return v0
.end method''',
    content, flags=re.DOTALL
)
content = re.sub(
    r'\.method public static isDisableAodAlwaysOnDisplayMode\(\)Z.*?\.end method',
    '''.method public static isDisableAodAlwaysOnDisplayMode()Z
    .registers 1
    const/4 v0, 0x0
    return v0
.end method''',
    content, flags=re.DOTALL
)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("  Patched: AodFeatureOption (3 methods)")
PYEOF
    else
        echo "  Warning: AodFeatureOption.smali not found"
    fi

    local smooth
    smooth="$(find_smali "$work" "com/oplus/systemui/aod/display/SmoothTransitionController.smali")"
    if [[ -n "$smooth" ]]; then
        python3 - "$smooth" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

inject = """    const/4 v0, 0x1
    iput-boolean v0, p0, Lcom/oplus/systemui/aod/display/SmoothTransitionController;->isSupportPanoramic:Z
    iput-boolean v0, p0, Lcom/oplus/systemui/aod/display/SmoothTransitionController;->isSupportPanoramicAllDay:Z
    iput-boolean v0, p0, Lcom/oplus/systemui/aod/display/SmoothTransitionController;->isSupportSmoothTransition:Z
    iput-boolean v0, p0, Lcom/oplus/systemui/aod/display/SmoothTransitionController;->userEnablePanoramic:Z
    iput-boolean v0, p0, Lcom/oplus/systemui/aod/display/SmoothTransitionController;->userEnablePanoramicAllDay:Z"""

content = re.sub(
    r'(\.method public constructor <init>\(Landroid/content/Context;\)V.*?)(\s+return-void\s+\.end method)',
    r'\1\n' + inject + r'\2',
    content, flags=re.DOTALL
)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("  Patched: SmoothTransitionController constructor")
PYEOF
    else
        echo "  Warning: SmoothTransitionController.smali not found"
    fi

    local new_apk="${systemui%.apk}.new.apk"
    apkeditor_pack "$work" "$new_apk"
    mv "$new_apk" "$systemui"
    rm -rf "$work"
    echo "  SystemUI patched"

    # ── Aod.apk ──────────────────────────────────────────────
    local aod_apk=""
    for path_candidate in \
        "$PORT_DIR/system_ext/priv-app/Aod/Aod.apk" \
        "$PORT_DIR/system/priv-app/Aod/Aod.apk" \
        "$PORT_DIR/system/app/Aod/Aod.apk" \
        "$PORT_DIR/system/my_stock/app/Aod/Aod.apk"
    do
        if [[ -f "$path_candidate" ]]; then
            aod_apk="$path_candidate"
            break
        fi
    done

    if [[ -z "$aod_apk" ]]; then
        echo "  Warning: Aod.apk not found, skipping"
        echo "  Seamless & Fullscreen AOD partially fixed (SystemUI only)"
        return 0
    fi

    local work_aod="$PORT_DIR/work_aod_apk"
    backup_file "$aod_apk"
    apkeditor_unpack "$aod_apk" "$work_aod"

    local common_utils
    common_utils="$(find_smali "$work_aod" "com/oplus/aod/util/CommonUtils.smali")"
    if [[ -n "$common_utils" ]]; then
        python3 - "$common_utils" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

content = re.sub(
    r'\.method public static isSupportFullAod\(Landroid/content/Context;\)Z.*?\.end method',
    '''.method public static isSupportFullAod(Landroid/content/Context;)Z
    .registers 1
    const/4 v0, 0x1
    return v0
.end method''',
    content, flags=re.DOTALL
)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("  Patched: CommonUtils.isSupportFullAod()")
PYEOF
    else
        echo "  Warning: CommonUtils.smali not found in Aod.apk"
    fi

    local new_aod="${aod_apk%.apk}.new.apk"
    apkeditor_pack "$work_aod" "$new_aod"
    mv "$new_aod" "$aod_apk"
    rm -rf "$work_aod"

    echo "  Seamless & Fullscreen AOD fixed"
}

# ── MODE 5: Fix Face Unlock ───────────────────────────────────
mode5_fix_face_unlock() {
    echo ""
    echo "[MODE 5] Fixing Face Unlock..."

    # Copy face files from RES/face/system/
    local face_system="$RES_DIR/face/system"
    if [[ -d "$face_system" ]]; then
        copy_res_dir "$face_system" "$PORT_DIR/system/system"
    fi

    # Copy fingerprint.xml
    local face_xml="$RES_DIR/face/android.hardware.fingerprint.xml"
    if [[ -f "$face_xml" ]]; then
        local dst="$PORT_DIR/system/my_product/etc/permissions/android.hardware.fingerprint.xml"
        mkdir -p "$(dirname "$dst")"
        cp -a "$face_xml" "$dst"
        echo "  Copied fingerprint.xml"
    fi

    # Patch services.jar
    local face_dex="$RES_DIR/face/face.dex"
    local services="$PORT_DIR/system/system/framework/services.jar"
    if [[ -f "$face_dex" && -f "$services" ]]; then
        local work="$PORT_DIR/work_face_services"
        backup_file "$services"
        apkeditor_unpack "$services" "$work"

        # Delete old Face classes
        for cls in \
            "com/android/server/biometrics/sensors/face/FaceService.smali" \
            "com/android/server/biometrics/sensors/face/aidl/FaceProvider.smali" \
            "com/android/server/biometrics/sensors/face/aidl/TestHal.smali"
        do
            local f; f="$(find_smali "$work" "$cls")"
            if [[ -n "$f" ]]; then rm -f "$f"; echo "  Deleted: ${cls//\// .}"; fi
        done

        # Copy face.dex into unpacked dir (APKEditor handles dex injection)
        cp "$face_dex" "$work/face.dex"

        local new_jar="${services%.jar}.new.jar"
        apkeditor_pack "$work" "$new_jar"
        mv "$new_jar" "$services"
        rm -rf "$work"
        echo "  face.dex injected into services.jar"
    fi

    # Patch SystemUI.apk - isFaceAuthEnrolled
    local systemui="$PORT_DIR/system_ext/priv-app/SystemUI/SystemUI.apk"
    if [[ ! -f "$systemui" ]]; then
        echo "  Warning: SystemUI.apk not found, skipping"
        return 0
    fi

    local work2="$PORT_DIR/work_face_systemui"
    backup_file "$systemui"
    apkeditor_unpack "$systemui" "$work2"

    local smali_file
    smali_file="$(find_smali "$work2" "com/android/systemui/biometrics/AuthController.smali")"
    if [[ -n "$smali_file" ]]; then
        python3 - "$smali_file" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

new_method = """.method public isFaceAuthEnrolled(I)Z
    .registers 4

    const-string v0, "persist.sys.oplus.isFaceEnrolled"
    invoke-static {v0}, Landroid/os/SystemProperties;->get(Ljava/lang/String;)Ljava/lang/String;
    move-result-object v0

    const-string v1, "1"
    invoke-virtual {v1, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
    move-result v0

    return v0
.end method"""

content = re.sub(
    r'\.method public isFaceAuthEnrolled\(I\)Z.*?\.end method',
    new_method, content, flags=re.DOTALL
)
with open(path, 'w') as f:
    f.write(content)
print("  Patched: AuthController.isFaceAuthEnrolled()")
PYEOF
    else
        echo "  Warning: AuthController.smali not found"
    fi

    local new_apk="${systemui%.apk}.new.apk"
    apkeditor_pack "$work2" "$new_apk"
    mv "$new_apk" "$systemui"
    rm -rf "$work2"
    echo "  Face Unlock fixed"
}

# ── MODE 6: Fix FOD ───────────────────────────────────────────
mode6_fix_fod() {
    echo ""
    echo "[MODE 6] Fixing FOD (Fingerprint on Display)..."

    local fod_dex="$RES_DIR/FOD/classes8.dex"
    local systemui="$PORT_DIR/system_ext/priv-app/SystemUI/SystemUI.apk"

    if [[ ! -f "$fod_dex" ]]; then
        echo "  Error: RES/FOD/classes8.dex not found!"; return 1
    fi
    if [[ ! -f "$systemui" ]]; then
        echo "  Error: SystemUI.apk not found!"; return 1
    fi

    local work="$PORT_DIR/work_fod_systemui"
    backup_file "$systemui"
    apkeditor_unpack "$systemui" "$work"

    # Patch 1: OnScreenHighLightControl.hbmControl
    local hl_smali
    hl_smali="$(find_smali "$work" "com/oplus/systemui/biometrics/finger/udfps/OnScreenHighLightControl.smali")"
    if [[ -n "$hl_smali" ]]; then
        python3 - "$hl_smali" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

new_method = """.method public static hbmControl(Z)V
    .registers 6

    .line 1
    const-string v0, "hbmControl enable:"

    .line 3
    const-string v1, "OnScreenHighLightControl"

    .line 5
    if-nez p0, :cond_a

    invoke-static {}, Lme/palaziks/FODService;->fingerUp()V

    goto :goto_14

    :cond_a
    invoke-static {}, Lme/palaziks/FODService;->fingerDown()V

    .line 7
    const/4 v2, 0x0

    .line 8
    :try_start_e
    invoke-static {v2}, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenHighLightControl;->controlPartialUpdate(Z)V

    .line 11
    goto :goto_14

    .line 12
    :catch_12
    move-exception p0

    .line 13
    goto :goto_53

    .line 14
    :goto_14
    sget-object v2, Lcom/oplus/keyguard/utils/KeyguardUtils;->Companion:Lcom/oplus/keyguard/utils/KeyguardUtils$Companion;

    .line 16
    invoke-virtual {v2}, Lcom/oplus/keyguard/utils/KeyguardUtils$Companion;->getAidlService()Lvendor/oplus/hardware/displaypanelfeature/IDisplayPanelFeature;

    .line 19
    move-result-object v2

    .line 20
    const/16 v3, 0x16

    .line 22
    if-eqz v2, :cond_26

    .line 24
    filled-new-array {p0}, [I

    .line 27
    move-result-object v4

    .line 28
    invoke-interface {v2, v3, v4}, Lvendor/oplus/hardware/displaypanelfeature/IDisplayPanelFeature;->setDisplayPanelFeatureValue(I[I)I

    .line 31
    goto :goto_3d

    .line 32
    :cond_26
    new-instance v2, Ljava/util/ArrayList;

    .line 34
    invoke-direct {v2}, Ljava/util/ArrayList;-><init>()V

    .line 37
    invoke-static {p0}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;

    .line 40
    move-result-object v4

    .line 41
    invoke-virtual {v2, v4}, Ljava/util/ArrayList;->add(Ljava/lang/Object;)Z

    .line 44
    invoke-static {}, Lvendor/oplus/hardware/displaypanelfeature/V1_0/IDisplayPanelFeature;->getService()Lvendor/oplus/hardware/displaypanelfeature/V1_0/IDisplayPanelFeature;

    .line 47
    move-result-object v4

    .line 48
    if-eqz v4, :cond_3d

    .line 50
    check-cast v4, Lvendor/oplus/hardware/displaypanelfeature/V1_0/IDisplayPanelFeature$Proxy;

    .line 52
    invoke-virtual {v4, v2, v3}, Lvendor/oplus/hardware/displaypanelfeature/V1_0/IDisplayPanelFeature$Proxy;->setDisplayPanelFeatureValue(Ljava/util/ArrayList;I)I

    .line 55
    :cond_3d
    :goto_3d
    new-instance v2, Ljava/lang/StringBuilder;

    .line 57
    invoke-direct {v2, v0}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    .line 60
    invoke-virtual {v2, p0}, Ljava/lang/StringBuilder;->append(Z)Ljava/lang/StringBuilder;

    .line 63
    invoke-virtual {v2}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    .line 66
    move-result-object v0

    .line 67
    invoke-static {v1, v0}, Lcom/oplusos/keyguard/utils/KgdLogUtil;->i(Ljava/lang/String;Ljava/lang/String;)V

    .line 70
    if-nez p0, :cond_64

    .line 72
    const/4 p0, 0x1

    .line 73
    invoke-static {p0}, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenHighLightControl;->controlPartialUpdate(Z)V
    :try_end_52
    .catch Ljava/lang/Exception; {:try_start_e .. :try_end_52} :catch_12

    .line 76
    return-void

    .line 77
    :goto_53
    new-instance v0, Ljava/lang/StringBuilder;

    .line 79
    const-string v2, "hbmControl exception : "

    .line 81
    invoke-direct {v0, v2}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    .line 84
    invoke-virtual {v0, p0}, Ljava/lang/StringBuilder;->append(Ljava/lang/Object;)Ljava/lang/StringBuilder;

    .line 87
    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    .line 90
    move-result-object p0

    .line 91
    invoke-static {v1, p0}, Lcom/oplusos/keyguard/utils/KgdLogUtil;->e(Ljava/lang/String;Ljava/lang/String;)V

    .line 94
    :cond_64
    return-void
.end method"""

content = re.sub(
    r'\.method public static hbmControl\(Z\)V.*?\.end method',
    new_method, content, flags=re.DOTALL
)
with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("    Patched: OnScreenHighLightControl.hbmControl()")
PYEOF
    else
        echo "    Warning: OnScreenHighLightControl.smali not found"
    fi

    # Patch 2: OnScreenFingerprintUiMech.onFpTouch
    local uimech_smali
    uimech_smali="$(find_smali "$work" "com/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech.smali")"
    if [[ -n "$uimech_smali" ]]; then
        python3 - "$uimech_smali" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

new_method = """.method public final onFpTouch(Z)V
    .registers 6

    .line 1
    const-string/jumbo v0, "touchEvent isDown "

    .line 4
    monitor-enter p0

    .line 5
    :try_start_4
    iget-boolean v1, p0, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->isFingerprintIconShow:Z
    :try_end_6
    .catchall {:try_start_4 .. :try_end_6} :catchall_3e

    .line 7
    if-nez v1, :cond_a

    .line 9
    monitor-exit p0

    .line 10
    return-void

    .line 11
    :cond_a
    :try_start_a
    iget-object v1, p0, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->fpIcon:Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintIcon;
    :try_end_c
    .catchall {:try_start_a .. :try_end_c} :catchall_3e

    .line 13
    if-nez v1, :cond_10

    .line 15
    monitor-exit p0

    .line 16
    return-void

    .line 17
    :cond_10
    :try_start_10
    iget-boolean v1, p0, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->isTouchDownNow:Z

    const-class v2, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenHighLightControl;

    invoke-static {v2}, Lcom/android/systemui/Dependency;->get(Ljava/lang/Class;)Ljava/lang/Object;

    move-result-object v2

    check-cast v2, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenHighLightControl;

    invoke-virtual {v2, p1}, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenHighLightControl;->setHighlightEnable(Z)V

    .line 19
    if-eq v1, p1, :cond_4f

    .line 21
    const-string v1, "OnScreenFingerprintUiMech"

    .line 23
    new-instance v2, Ljava/lang/StringBuilder;

    .line 25
    invoke-direct {v2, v0}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    .line 28
    invoke-virtual {v2, p1}, Ljava/lang/StringBuilder;->append(Z)Ljava/lang/StringBuilder;

    .line 31
    invoke-virtual {v2}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    .line 34
    move-result-object v0

    .line 35
    invoke-static {v1, v0}, Lcom/oplusos/keyguard/utils/KgdLogUtil;->i(Ljava/lang/String;Ljava/lang/String;)V

    .line 38
    iput-boolean p1, p0, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->isTouchDownNow:Z

    .line 40
    iget-object p1, p0, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->touchRunnable:Ljava/lang/Runnable;

    .line 42
    if-eqz p1, :cond_40

    .line 44
    iget-object v0, p0, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->opticalUiUpdateHandler:Landroid/os/Handler;

    .line 46
    if-eqz v0, :cond_40

    .line 48
    invoke-virtual {v0, p1}, Landroid/os/Handler;->removeCallbacks(Ljava/lang/Runnable;)V

    .line 51
    goto :goto_40

    .line 52
    :catchall_3e
    move-exception p1

    .line 53
    goto :goto_51

    .line 54
    :cond_40
    :goto_40
    new-instance p1, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech$touchEvent$2;

    .line 56
    const/4 v0, 0x0

    .line 57
    invoke-direct {p1, p0, v0}, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech$touchEvent$2;-><init>(Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;I)V

    .line 60
    iput-object p1, p0, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->touchRunnable:Ljava/lang/Runnable;

    .line 62
    iget-object v0, p0, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->opticalUiUpdateHandler:Landroid/os/Handler;

    .line 64
    if-eqz v0, :cond_4f

    .line 66
    invoke-virtual {v0, p1}, Landroid/os/Handler;->post(Ljava/lang/Runnable;)Z
    :try_end_4f
    .catchall {:try_start_10 .. :try_end_4f} :catchall_3e

    .line 69
    :cond_4f
    monitor-exit p0

    .line 70
    return-void

    .line 71
    :goto_51
    :try_start_51
    monitor-exit p0
    :try_end_52
    .catchall {:try_start_51 .. :try_end_52} :catchall_3e

    .line 72
    throw p1
.end method"""

content = re.sub(
    r'\.method public final onFpTouch\(Z\)V.*?\.end method',
    new_method, content, flags=re.DOTALL
)
with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("    Patched: OnScreenFingerprintUiMech.onFpTouch()")
PYEOF
    else
        echo "    Warning: OnScreenFingerprintUiMech.smali not found"
    fi

    # Patch 3: KeyguardFeatureOption.isLocalHBM
    local keyguard_smali
    keyguard_smali="$(find_smali "$work" "KeyguardFeatureOption.smali")"
    if [[ -n "$keyguard_smali" ]]; then
        python3 - "$keyguard_smali" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

content = re.sub(
    r'\.method public static isLocalHBM\(\)Z.*?\.end method',
    '''.method public static isLocalHBM()Z
    .registers 1

    const/4 v0, 0x1

    return v0
.end method''',
    content, flags=re.DOTALL
)
with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("    Patched: KeyguardFeatureOption.isLocalHBM()")
PYEOF
    else
        echo "    Warning: KeyguardFeatureOption.smali not found"
    fi

    # Copy classes8.dex into unpacked SystemUI
    cp "$fod_dex" "$work/classes8.dex"
    echo "    Copied: classes8.dex"

    local new_apk="${systemui%.apk}.new.apk"
    apkeditor_pack "$work" "$new_apk"
    mv "$new_apk" "$systemui"
    rm -rf "$work"
    echo "  FOD fixed successfully"
}

# ── MODE 7: Fix FOD Animation ─────────────────────────────────
mode7_fix_fod_animation() {
    echo ""
    echo "[MODE 7] Fixing FOD animation..."

    local systemui="$PORT_DIR/system_ext/priv-app/SystemUI/SystemUI.apk"
    if [[ ! -f "$systemui" ]]; then echo "Error: $systemui not found!"; return 1; fi

    local work="$PORT_DIR/work_fod_animation"
    backup_file "$systemui"
    apkeditor_unpack "$systemui" "$work"

    local smali_file
    smali_file="$(find_smali "$work" "com/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech.smali")"
    if [[ -z "$smali_file" ]]; then
        echo "  Error: OnScreenFingerprintUiMech.smali not found!"
        rm -rf "$work"; return 1
    fi

    python3 - "$smali_file" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

fingerdown_call = """
        # FOD Animation Fix - Finger Down
        const/4 v0, 0x1
        invoke-virtual {p0, v0}, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->onFpTouch(Z)V
    """

content = re.sub(
    r'(const-string/jumbo v0, "touchEvent isDown ".*?\n.*?\.line \d+\s+monitor-enter p0)',
    r'\1' + fingerdown_call,
    content, flags=re.MULTILINE | re.DOTALL
)

lines = content.split('\n')
new_lines = []
in_method = False
for i, line in enumerate(lines):
    new_lines.append(line)
    if '.method public final onFpTouch(Z)V' in line:
        in_method = True
    if in_method and '.end method' in line:
        in_method = False
    if in_method and 'if-nez v1,' in line:
        for j in range(i+1, min(i+10, len(lines))):
            if 'monitor-exit p0' in lines[j]:
                new_lines.append("")
                new_lines.append("    # FOD Animation Fix - Finger Up")
                new_lines.append("    const/4 v0, 0x0")
                new_lines.append("    invoke-virtual {p0, v0}, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->onFpTouch(Z)V")
                break

if len(new_lines) > len(lines):
    content = '\n'.join(new_lines)

with open(path, 'w') as f:
    f.write(content)
print("  Patched: OnScreenFingerprintUiMech.onFpTouch()")
PYEOF

    # Patch FOD impl classes
    for pattern in \
        "com/oplus/systemui/biometrics/finger/udfps/OnScreenHighLightControl.smali" \
        "com/oplus/systemui/biometrics/finger/udfps/UdfpsDisplayModeManager.smali"
    do
        local f; f="$(find_smali "$work" "$pattern")"
        if [[ -n "$f" ]]; then
            python3 - "$f" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

content = re.sub(
    r'(invoke-static \{\}, Lme/palaziks/FODService;->fingerDown\(\)V)',
    r'\1\n\n    # Call FOD Animation\n    const/4 v0, 0x1\n    invoke-virtual {p0, v0}, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->onFpTouch(Z)V',
    content, flags=re.MULTILINE
)
content = re.sub(
    r'(invoke-static \{\}, Lme/palaziks/FODService;->fingerUp\(\)V)',
    r'\1\n\n    # Call FOD Animation\n    const/4 v0, 0x0\n    invoke-virtual {p0, v0}, Lcom/oplus/systemui/biometrics/finger/udfps/OnScreenFingerprintUiMech;->onFpTouch(Z)V',
    content, flags=re.MULTILINE
)
with open(path, 'w') as f:
    f.write(content)
print(f"  Patched: {path.split('/')[-1]}")
PYEOF
        fi
    done

    local new_apk="${systemui%.apk}.new.apk"
    apkeditor_pack "$work" "$new_apk"
    mv "$new_apk" "$systemui"
    rm -rf "$work"
    echo "  FOD animation fixed"
}

# ── MODE 8: Fix Video Playback ────────────────────────────────
mode8_fix_video_playback() {
    echo ""
    echo "[MODE 8] Fixing video playback..."

    local xml="$PORT_DIR/system/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml"
    if [[ ! -f "$xml" ]]; then
        echo "  Warning: XML not found, skipping..."
        return 0
    fi

    local deleted=0
    for feature in "oplus.software.video.sr_support" "oplus.software.video.sr10_support"; do
        local before; before=$(wc -l < "$xml")
        # sed: delete lines that contain both the feature name and <oplus-feature
        sed -i "/<oplus-feature.*${feature}/d" "$xml"
        local after; after=$(wc -l < "$xml")
        local diff=$(( before - after ))
        if (( diff > 0 )); then
            echo "  Deleted: $feature"
            (( deleted += diff )) || true
        fi
    done

    if (( deleted > 0 )); then
        echo "  Video playback fixed ($deleted features removed)"
    else
        echo "  No video features found to remove"
    fi
}

# ── MODE 9: Fix Brightness (MTK) ─────────────────────────────
mode9_fix_brightness_mtk() {
    echo ""
    echo "[MODE 9] Fixing brightness for MTK AMOLED..."

    copy_res_dir "$RES_DIR/brightness" "$PORT_DIR"

    prop_add_if_missing "$PORT_DIR/vendor/build.prop" "Brightness Props for AMOLED" \
"
# Brightness Props for AMOLED
persist.sys.xia.brightness.mode=0
persist.sys.tran.brightness.gammalinear.convert=1
ro.vendor.transsion.backlight_hal.optimization=1
ro.transsion.backlight.level=-1
ro.transsion.physical.backlight.optimization=1
persist.sys.rianixia.custom.devmax.brightness=4095
persist.sys.rianixia.hw_min=10
persist.sys.rianixia.oplus.lux_aod=true"

    echo "  MTK AMOLED brightness fixed"
}

# ── MODE 10: Fix OPlus Privacy / AppLock ─────────────────────
mode10_fix_privacy() {
    echo ""
    echo "[MODE 10] Fixing AppLock and Privacy..."

    # Copy files from RES/privacy/ subdirs to their matching partition dirs
    local privacy_res="$RES_DIR/privacy"
    if [[ -d "$privacy_res" ]]; then
        local copied=0
        for subdir in "$privacy_res"/*/; do
            [[ -d "$subdir" ]] || continue
            local part_name
            part_name="$(basename "$subdir")"
            local dst="$PORT_DIR/$part_name"
            mkdir -p "$dst"
            while IFS= read -r -d '' f; do
                local rel="${f#${subdir}}"
                local fdst="$dst/$rel"
                mkdir -p "$(dirname "$fdst")"
                cp -a "$f" "$fdst"
                (( copied++ )) || true
            done < <(find "$subdir" -type f -print0)
            echo "  Copied RES/privacy/$part_name/ -> $part_name/"
        done
        echo "  Total files copied: $copied"
    else
        echo "  Warning: RES/privacy/ not found"
    fi

    # Add props to odm/build.prop or odm/etc/build.prop
    local bp=""
    if [[ -f "$PORT_DIR/odm/build.prop" ]]; then
        bp="$PORT_DIR/odm/build.prop"
    elif [[ -f "$PORT_DIR/odm/etc/build.prop" ]]; then
        bp="$PORT_DIR/odm/etc/build.prop"
    elif [[ -d "$PORT_DIR/odm" ]]; then
        bp="$PORT_DIR/odm/build.prop"
        touch "$bp"
        echo "  Created: odm/build.prop"
    else
        mkdir -p "$PORT_DIR/odm/etc"
        bp="$PORT_DIR/odm/etc/build.prop"
        touch "$bp"
        echo "  Created: odm/etc/build.prop"
    fi

    prop_add_if_missing "$bp" "ro.oemports10t.cryptoeng" \
"
# Privacy / AppLock Props
ro.oemports10t.cryptoeng=true
persist.sys.oplus.cryptoeng.verbose=false"

    echo "  Privacy / AppLock fixed"
}

# ── MODE 11: Fix NAND Swap ────────────────────────────────────
mode11_fix_nandswap() {
    echo ""
    echo "[MODE 11] Fixing NAND swap..."

    prop_add_if_missing "$PORT_DIR/vendor/build.prop" "NAND Swap Props" \
"
# NAND Swap Props
persist.sys.oplus.nandswap.condition=true
persist.sys.oplus.hybridswap_app_memcg=true
persist.sys.oplus.nandswap=true
persist.sys.oplus.nandswap.swapsize=8"

    # Copy nadswap files from RES
    local nadswap_dir="$RES_DIR/nadswap"
    if [[ -d "$nadswap_dir" ]]; then
        local copied=0
        while IFS= read -r -d '' f; do
            local rel="${f#${nadswap_dir}/}"
            local dst="$PORT_DIR/$rel"
            # Skip existing unless bpf
            if [[ -e "$dst" && "$rel" != *"etc/bpf"* ]]; then continue; fi
            mkdir -p "$(dirname "$dst")"
            cp -a "$f" "$dst"
            (( copied++ )) || true
        done < <(find "$nadswap_dir" -type f -print0)
        echo "  Copied $copied NAND swap files"
    else
        echo "  Warning: RES/nadswap not found"
    fi
}

# ── MODE 12: Fix Vibration ────────────────────────────────────
mode12_fix_vibration() {
    echo ""
    echo "[MODE 12] Fixing vibration..."
    copy_res_dir "$RES_DIR/vibration" "$PORT_DIR"
    echo "  Vibration fixed"
}

# ── MODE 13: Fix Device Specs ─────────────────────────────────
mode13_fix_device_specs() {
    echo ""
    echo "[MODE 13] Fix device name & Specifications"
    echo ""
    echo "What do you want to fix?"
    echo "  1. Device name"
    echo "  2. Processor name"
    echo "  3. Camera specifications"
    echo "  4. Screen specifications"
    echo "  5. All of the above"
    echo "  0. Exit"
    read -rp $'\nEnter your choice (0-5): ' choice

    [[ "$choice" == "0" ]] && { echo "  Skipped device specs fix"; return 0; }

    # Find odm build.prop
    local odm_bp="$PORT_DIR/odm/etc/build.prop"
    [[ ! -f "$odm_bp" ]] && odm_bp="$PORT_DIR/vendor/odm/etc/build.prop"
    if [[ ! -f "$odm_bp" ]]; then
        odm_bp="$PORT_DIR/odm/etc/build.prop"
        mkdir -p "$(dirname "$odm_bp")"
        touch "$odm_bp"
        echo "  Created: $odm_bp"
    fi

    local props_content=""

    if [[ "$choice" == "1" || "$choice" == "5" ]]; then
        echo "--- Device Name ---"
        read -rp "Enter device name (e.g., Xiaomi 11 Ultra): " device_name
        read -rp "Enter device codename (e.g., star): " device_codename
        if [[ -n "$device_name" && -n "$device_codename" ]]; then
            props_content+="
# Device Name Configuration
ro.vendor.oplus.market.name=$device_name
ro.vendor.oplus.market.enname=$device_name
vendor.usb.product_string=$device_name
bluetooth.device.default_name=$device_name
ro.product.device=$device_codename
ro.product.odm.device=$device_codename
ro.product.name=$device_codename
ro.product.product.name=$device_codename
ro.product.product.device=$device_codename
ro.product.mod_device=$device_codename
ro.product.odm.name=$device_codename"
            echo "  Device name set to: $device_name ($device_codename)"
        fi
    fi

    if [[ "$choice" == "2" || "$choice" == "5" ]]; then
        echo "--- Processor Name ---"
        read -rp "Enter processor name (e.g., SM8350): " processor
        processor="${processor^^}"
        if [[ -n "$processor" ]]; then
            props_content+="
# Processor Configuration
ro.soc.manufacturer=Qualcomm
ro.build.device_family=OP${processor}
ro.product.oplus.cpuinfo=${processor}"
            echo "  Processor set to: $processor"
        fi
    fi

    if [[ "$choice" == "3" || "$choice" == "5" ]]; then
        echo "--- Camera Specifications ---"
        read -rp "Enter back camera specs (e.g., 50MP+48MP+48MP): " back_camera
        read -rp "Enter front camera specs (e.g., 20MP): " front_camera
        if [[ -n "$back_camera" || -n "$front_camera" ]]; then
            props_content+="
# Camera Configuration"
            [[ -n "$front_camera" ]] && props_content+="
ro.vendor.oplus.camera.frontCamSize=$front_camera"
            [[ -n "$back_camera" ]] && props_content+="
ro.vendor.oplus.camera.backCamSize=$back_camera"
            echo "  Camera specs set - Back: $back_camera, Front: $front_camera"
        fi
    fi

    if [[ "$choice" == "4" || "$choice" == "5" ]]; then
        echo "--- Screen Specifications ---"
        read -rp "Enter screen size in inches (e.g., 6.81): " screen_inches
        read -rp "Enter screen size in cm (e.g., 17.32): " screen_cm
        if [[ -n "$screen_inches" || -n "$screen_cm" ]]; then
            props_content+="
# Screen Configuration"
            [[ -n "$screen_inches" ]] && props_content+="
ro.oplus.display.screenSizeinches.primary=$screen_inches"
            [[ -n "$screen_cm" ]] && props_content+="
ro.oplus.display.screenSizeCentimeter.primary=$screen_cm"
            echo "  Screen specs set - $screen_inches inches ($screen_cm cm)"
        fi
    fi

    if [[ -n "$props_content" ]]; then
        printf '%s\n' "$props_content" >> "$odm_bp"
        echo "  Device specifications updated in $(basename "$odm_bp")"
    else
        echo "  No specifications were set"
    fi
}

# ── MODE 14: Fake Enforcing ───────────────────────────────────
mode14_fake_enforcing() {
    echo ""
    echo "[MODE 14] Setting up fake enforcing..."
    read -rp "Enter your phone codename (e.g. star, cupid, alioth): " codename
    codename="${codename,,}"
    if [[ -z "$codename" ]]; then echo "  Codename cannot be empty!"; return 1; fi

    local init_rc="$PORT_DIR/vendor/etc/init/init.${codename}.rc"
    mkdir -p "$(dirname "$init_rc")"
    [[ -f "$init_rc" ]] || touch "$init_rc"

    cat >> "$init_rc" <<'EOF'

on boot
    chmod 640 /sys/fs/selinux/enforce
    chmod 440 /sys/fs/selinux/policy
EOF
    echo "  Done! Patched: $(basename "$init_rc")"
}

# ── MODE 15: Spoof Bootloader ─────────────────────────────────
mode15_spoof_bootloader() {
    echo ""
    echo "[MODE 15] Modifying build.prop for bootloader spoof..."

    prop_add_if_missing "$PORT_DIR/vendor/build.prop" "Bootloader Spoof Props" \
"
# Bootloader Spoof Props
persist.sys.disable_rescue=true
ro.boot.flash.locked=1
ro.boot.vbmeta.device_state=locked
ro.boot.verifiedbootstate=green
ro.boot.veritymode=enforcing
ro.boot.selinux=enforcing
ro.boot.warranty_bit=0
ro.build.tags=release-keys
ro.build.type=user
ro.control_privapp_permissions=disable
ro.debuggable=0
ro.is_ever_orange=0
ro.secure=1
ro.vendor.boot.warranty_bit=0
ro.vendor.warranty_bit=0
ro.warranty_bit=0
vendor.boot.vbmeta.device_state=locked
vendor.boot.verifiedbootstate=green
ro.crypto.state=encrypted"
}

# ── MODE 16: Disable Signature Verification ───────────────────
mode16_disable_sig_verification() {
    echo ""
    echo "[MODE 16] Disabling Signature Verification..."

    local jar="$PORT_DIR/system/system/framework/services.jar"
    if [[ ! -f "$jar" ]]; then echo "Error: $jar not found!"; return 1; fi

    local work="$PORT_DIR/work_dsv"
    backup_file "$jar"
    apkeditor_unpack "$jar" "$work"

    python3 - "$work" <<'PYEOF'
import re, sys, os

work_dir = sys.argv[1]
patches = [
    ('com/android/server/inputmethod/AdditionalSubtypeMapRepository$WriteTask.smali', 'getSigningDetails', 'v0'),
    ('com/android/server/pm/ApexManager$ApexManagerImpl.smali', 'getSigningDetails', 'v0'),
    ('com/android/server/pm/PackageSessionVerifier.smali', 'getSigningDetails', 'v1'),
    ('com/android/server/pm/ScanPackageUtils.smali', 'assertMinSignatureSchemeIsValid', 'v0'),
]

patched = 0
for cls_path, method, reg in patches:
    for root, dirs, files in os.walk(work_dir):
        f = os.path.join(root, os.path.basename(cls_path))
        if os.path.exists(f) and cls_path.replace('/', os.sep) in f.replace('/', os.sep):
            with open(f, 'r') as fp:
                content = fp.read()
            if method in content:
                content = re.sub(
                    rf'(invoke-static.*ApkSignatureVerifier;->getMinimumSignatureSchemeVersionForTargetSdk.*?\n\s+)move-result ({reg})',
                    rf'\1const/4 {reg}, 0x0',
                    content, flags=re.MULTILINE
                )
                with open(f, 'w') as fp:
                    fp.write(content)
                print(f"  Patched: {cls_path}")
                patched += 1
            break

if patched == 0:
    print("  Warning: No signature verification methods found to patch")
else:
    print(f"  Signature Verification disabled ({patched} methods patched)")
PYEOF

    local new_jar="${jar%.jar}.new.jar"
    apkeditor_pack "$work" "$new_jar"
    mv "$new_jar" "$jar"
    rm -rf "$work"
}

# ── MODE 17: Disable Secure Flag ─────────────────────────────
mode17_disable_secure_flag() {
    echo ""
    echo "[MODE 17] Disabling Secure Flag (enable screenshots)..."

    local jar="$PORT_DIR/system/system/framework/framework.jar"
    if [[ ! -f "$jar" ]]; then echo "Error: $jar not found!"; return 1; fi

    local work="$PORT_DIR/work_secure_flag"
    backup_file "$jar"
    apkeditor_unpack "$jar" "$work"

    local smali_file
    smali_file="$(find_smali "$work" "android/view/Window.smali")"
    if [[ -z "$smali_file" ]]; then
        echo "  Error: android/view/Window.smali not found!"
        rm -rf "$work"; return 1
    fi

    python3 - "$smali_file" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

patch_code = "    and-int/lit16 p2, p2, -0x2001\n    and-int/lit16 p1, p1, -0x2001\n"

if '.method public whitelist setFlags(II)V' in content:
    content = re.sub(
        r'(\.method public whitelist setFlags\(II\)V\s+\.registers \d+)',
        r'\1\n' + patch_code, content, flags=re.MULTILINE
    )
elif '.method public setFlags(II)V' in content:
    content = re.sub(
        r'(\.method public setFlags\(II\)V\s+\.registers \d+)',
        r'\1\n' + patch_code, content, flags=re.MULTILINE
    )
else:
    print("  Error: setFlags method not found!")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("  Patched: Window.setFlags()")
PYEOF

    local new_jar="${jar%.jar}.new.jar"
    apkeditor_pack "$work" "$new_jar"
    mv "$new_jar" "$jar"
    rm -rf "$work"
    echo "  Secure Flag disabled - screenshots/screen recording enabled"
}

# ── MODE 18: Add ODM HALs ─────────────────────────────────────
mode18_add_odm_hals() {
    echo ""
    echo "[MODE 18] Adding ODM HALs..."

    local odmhals_dir="$RES_DIR/odmhals"
    if [[ -d "$odmhals_dir" ]]; then
        local copied=0 replaced=0
        while IFS= read -r -d '' f; do
            [[ "$(basename "$f")" == "file_contexts.txt" ]] && continue
            local rel="${f#${odmhals_dir}/}"
            local dst="$PORT_DIR/$rel"
            mkdir -p "$(dirname "$dst")"
            if [[ -e "$dst" ]]; then (( replaced++ )) || true; else (( copied++ )) || true; fi
            cp -a "$f" "$dst"
        done < <(find "$odmhals_dir" -type f -print0)
        echo "  ODM HALs files copied ($copied new, $replaced replaced)"
    else
        echo "  Warning: RES/odmhals/ not found"
    fi

    # Add SELinux contexts
    local ctx_src="$RES_DIR/odmhals/file_contexts.txt"
    local ctx_dst="$PORT_DIR/config/odm_file_contexts"
    if [[ -f "$ctx_src" ]]; then
        mkdir -p "$(dirname "$ctx_dst")"
        [[ -f "$ctx_dst" ]] || touch "$ctx_dst"
        local added=0 skipped=0
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == "#"* ]] && continue
            local line_path="${line%% *}"
            if ! grep -qF "$line_path" "$ctx_dst"; then
                echo "$line" >> "$ctx_dst"
                (( added++ )) || true
            else
                (( skipped++ )) || true
            fi
        done < "$ctx_src"
        echo "  Added $added SELinux contexts (skipped $skipped duplicates)"
    fi
    echo "  ODM HALs configured"
}

# ── MODE 19: Optimize ROM ─────────────────────────────────────
mode19_optimize_rom() {
    echo ""
    echo "[MODE 19] Optimizing ROM..."

    copy_res_dir "$RES_DIR/optimization" "$PORT_DIR"

    prop_add_if_missing "$PORT_DIR/odm/etc/build.prop" "import /my_bigball/build.prop" \
"
# My Partitions Imports
import /odm/build.prop
import /mnt/vendor/my_product/etc/\${ro.boot.prjname}/build.\${ro.boot.flag}.prop
import /my_bigball/build.prop
import /my_carrier/build.prop
import /my_company/build.prop
import /my_engineering/build.prop
import /my_heytap/build.prop
import /my_manifest/build.prop
import /my_preload/build.prop
import /my_product/build.prop
import /my_region/build.prop
import /my_stock/build.prop"

    echo "  ROM optimization complete"
}

# ── MODE 20: Debloat ROM ──────────────────────────────────────
mode20_debloat_rom() {
    echo ""
    echo "[MODE 20] Debloating ROM..."

    # Format: "base_path|app1 app2 app3"
    local debloat_entries=(
        "system/my_product/app|OplusCamera"
        "system/my_stock/app|BeaconLink CarLink ChildrenSpace FloatAssistant OplusOperationManual Pictorial Portrait SceneMode YMSpeechService"
        "system/my_stock/del-app|BrowserVideo FamilyGuard OPCommunity OPPOStore Shortcuts SoftsimRedteaRoaming"
        "system/my_stock/priv-app|CodeBook HeyCast OPSynergy"
    )

    local total_removed=0
    local total_size=0

    echo ""
    echo "[*] Starting debloat process..."
    echo "============================================================"

    for entry in "${debloat_entries[@]}"; do
        local base_path="${entry%%|*}"
        local apps="${entry##*|}"
        echo ""
        echo "Processing: $base_path"
        echo "------------------------------------------------------------"
        for app_name in $apps; do
            local app_path="$PORT_DIR/$base_path/$app_name"
            if [[ -e "$app_path" ]]; then
                local app_size
                app_size=$(du -sb "$app_path" 2>/dev/null | cut -f1 || echo 0)
                rm -rf "$app_path"
                printf "  ✓ Removed: %-30s (%s KB)\n" "$app_name" "$(( app_size / 1024 ))"
                (( total_removed++ )) || true
                (( total_size += app_size )) || true
            else
                echo "  ⊘ Not found: $app_name"
            fi
        done
    done

    echo ""
    echo "============================================================"
    echo "📊 DEBLOAT SUMMARY"
    echo "============================================================"
    echo "Total apps removed: $total_removed"
    echo "Space freed: $(( total_size / 1024 / 1024 )) MB"
    echo "============================================================"

    if (( total_removed > 0 )); then
        echo ""
        echo "✓ Debloat completed successfully!"
    else
        echo ""
        echo "⚠ Warning: No apps were found to remove"
    fi
}

# ── Full Port (all steps) ─────────────────────────────────────
run_full_port() {
    echo ""
    echo "============================================================"
    echo "Starting full porting process..."
    echo "============================================================"

    local steps=(
        "step1_merge_partitions:Merging partitions"
        "step2_copy_res_files:Copying RES files"
        "step3_modify_build_prop:Modifying build.prop"
        "step4_delete_screen_zoom_props:Deleting screen zoom props"
        "step5_add_extra_props:Adding extra props"
    )

    for entry in "${steps[@]}"; do
        local func="${entry%%:*}"
        local name="${entry##*:}"
        echo ""
        echo "▶ $name..."
        if ! $func; then
            echo "✗ $name failed! Check $LOG_FILE"
            return 1
        fi
    done

    echo ""
    echo "============================================================"
    echo "✓ Porting completed successfully!"
    echo "============================================================"
    echo ""
    echo "Next steps:"
    echo "1. Repack the ROM using your kitchen"
    echo "2. Flash to your device"
    echo "3. Enjoy ColorOS 16!"
}

# ── About ─────────────────────────────────────────────────────
show_about() {
    echo ""
    echo "========================================"
    echo "           palazikBox"
    echo "========================================"
    echo ""
    echo "This tool can help you with porting and"
    echo "fixing ColorOS 16 / OxygenOS 16 for Xiaomi"
    echo ""
    echo "Made by @tm_palaziks (TG: @tm_palaziks)"
    echo "palazikBox version: V2.0 BASH RELEASE"
    echo ""
    echo "Credits:"
    echo "- @trdyun (Coolapk)"
    echo "- @rianixia"
    echo "- @LazyBones"
    echo "- @Artic15th"
    echo "- @兰微塔鱼 (Coolapk)"
    echo "- gabi"
    echo "- @mi12autism"
    echo "- @lnsiv"
    echo ""
    read -rp "Press Enter to continue..."
}

# ── Porter menu ───────────────────────────────────────────────
porter_menu() {
    # Check partitions
    echo ""
    echo "[CHECKING] Checking unpacked partitions..."
    local found=0
    for part in system product system_ext "${MY_PARTITIONS[@]}"; do
        if [[ -d "$PORT_DIR/$part" ]]; then
            (( found++ )) || true
        else
            echo "  Warning: $part not found"
        fi
    done

    if (( found == 0 )); then
        echo "✗ No partitions found! Please unpack ROM first."
    fi
    echo "✓ Found $found partitions"

    while true; do
        echo ""
        echo "=================================================="
        echo " ColorOS 16 / OxygenOS 16 porter tool "
        echo "=================================================="
        echo ""
        echo "Choose mode:"
        echo " 1  - Full Port"
        echo " 2  - Fix SuperVOOC"
        echo " 3  - Fix AOD"
        echo " 4  - Fix 24H Full Screen AOD"
        echo " 5  - Fix Face Unlock"
        echo " 6  - Fix FOD"
        echo " 7  - Fix FOD Animation"
        echo " 8  - Fix Video Playback"
        echo " 9  - Fix brightness (MTK ONLY)"
        echo " 10 - Fix OPlus Privacy"
        echo " 11 - Fix NAND swap"
        echo " 12 - Fix vibration"
        echo " 13 - Fix device name & specifications"
        echo " 14 - Fake enforcing"
        echo " 15 - Spoof Bootloader"
        echo " 16 - Disable Signature Verification"
        echo " 17 - Disable Secure Flag"
        echo " 18 - Add ODM HALs"
        echo " 19 - Optimize ROM"
        echo " 20 - Debloat ROM"
        echo " 21 - About palazikBox"
        echo "  0 - Exit"

        read -rp $'\nChoose mode: ' mode

        case "$mode" in
            1)  run_full_port ;;
            2)  mode2_fix_supervooc ;;
            3)  mode3_fix_aod ;;
            4)  mode4_fix_fullscreen_aod ;;
            5)  mode5_fix_face_unlock ;;
            6)  mode6_fix_fod ;;
            7)  mode7_fix_fod_animation ;;
            8)  mode8_fix_video_playback ;;
            9)  mode9_fix_brightness_mtk ;;
            10) mode10_fix_privacy ;;
            11) mode11_fix_nandswap ;;
            12) mode12_fix_vibration ;;
            13) mode13_fix_device_specs ;;
            14) mode14_fake_enforcing ;;
            15) mode15_spoof_bootloader ;;
            16) mode16_disable_sig_verification ;;
            17) mode17_disable_secure_flag ;;
            18) mode18_add_odm_hals ;;
            19) mode19_optimize_rom ;;
            20) mode20_debloat_rom ;;
            21) show_about ;;
            0)  echo ""; echo "Bye Bye!"; break ;;
            *)  echo ""; echo "❌ Incorrect Mode! Try again." ;;
        esac
    done
}

# ── Main menu ─────────────────────────────────────────────────
main() {
    check_tools

    if [[ ! -d "$RES_DIR" ]]; then
        echo "Error: RES folder not found at $RES_DIR"
        echo "Please create RES folder with all needed files next to this script"
        exit 1
    fi

    while true; do
        echo ""
        echo "=============================="
        echo "      palazikBox V2.0"
        echo "=============================="
        echo ""
        echo "Main menu:"
        echo "1. ColorOS 16 / OxygenOS 16 Tools"
        echo "2. About palazikBox"
        echo "0. Exit"

        read -rp $'\nChoose mode: ' choice

        case "$choice" in
            1) porter_menu ;;
            2) show_about ;;
            0) echo ""; echo "Bye Bye!"; break ;;
            *) echo ""; echo "❌ Incorrect mode! Try again." ;;
        esac
    done
}

# ── Entry point ───────────────────────────────────────────────
trap 'echo ""; echo "⚠ Interrupted by user"; exit 0' INT

main "$@"
