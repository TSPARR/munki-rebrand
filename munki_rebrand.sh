#!/bin/bash
# encoding: utf-8
#
# munki_rebrand.sh
#
# Script to rebrand and customise Munki's Managed Software Center
#
# Copyright (C) University of Oxford 2016-21
#     Ben Goodstein <ben.goodstein at it.ox.ac.uk>
#
# Based on an original script by Arjen van Bochoven
# Converted to bash script
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

set -euo pipefail

VERSION="5.6"
APPNAME="Managed Software Center"

get_localized_name() {
    local code="$1"
    case "$code" in
        "Base") echo "Managed Software Center" ;;
        "da") echo "Managed Software Center" ;;
        "de") echo "Geführte Softwareaktualisierung" ;;
        "en") echo "Managed Software Center" ;;
        "en-AU"|"en_AU") echo "Managed Software Centre" ;;
        "en-GB"|"en_GB") echo "Managed Software Centre" ;;
        "en-CA"|"en_CA") echo "Managed Software Centre" ;;
        "es") echo "Centro de aplicaciones" ;;
        "fi") echo "Managed Software Center" ;;
        "fr") echo "Centre de gestion des logiciels" ;;
        "it") echo "Centro Gestione Applicazioni" ;;
        "ja") echo "Managed Software Center" ;;
        "nb") echo "Managed Software Center" ;;
        "nl") echo "Managed Software Center" ;;
        "ru") echo "Центр Управления ПО" ;;
        "sv") echo "Managed Software Center" ;;
        *) echo "" ;;
    esac
}

ICON_SIZES=(
    "16:16x16"
    "32:16x16@2x"
    "32:32x32"
    "64:32x32@2x"
    "128:128x128"
    "256:128x128@2x"
    "256:256x256"
    "512:256x256@2x"
    "512:512x512"
    "1024:512x512@2x"
)

PKGBUILD="/usr/bin/pkgbuild"
PKGUTIL="/usr/sbin/pkgutil"
PRODUCTBUILD="/usr/bin/productbuild"
PRODUCTSIGN="/usr/bin/productsign"
CODESIGN="/usr/bin/codesign"
FILE="/usr/bin/file"
PLUTIL="/usr/bin/plutil"
SIPS="/usr/bin/sips"
ICONUTIL="/usr/bin/iconutil"
CURL="/usr/bin/curl"
JQ="/usr/bin/jq"
ACTOOL_PATHS=("/usr/bin/actool" "/Applications/Xcode.app/Contents/Developer/usr/bin/actool")

MUNKIURL="https://api.github.com/repos/munki/munki/releases/latest"

VERBOSE=false
TMP_DIR=""

MSC_APP_PATH="Applications/Managed Software Center.app"
MS_APP_PATH="$MSC_APP_PATH/Contents/Helpers/MunkiStatus.app"
MN_APP_PATH="$MSC_APP_PATH/Contents/Helpers/munki-notifier.app"

MUNKI_PATH="usr/local/munki"
PY_FWK="$MUNKI_PATH/Python.Framework"
PY_CUR="$PY_FWK/Versions/Current"

cleanup() {
    echo "Cleaning up..."
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    echo "Done."
}

trap cleanup EXIT

log() {
    if [[ "$VERBOSE" == true ]]; then
        echo "$@"
    fi
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

run_cmd() {
    if [[ "$VERBOSE" == true ]]; then
        echo "Running: $*" >&2
        "$@"
    else
        "$@" 2>/dev/null
    fi
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        die "Command failed with exit code $exit_code: $*"
    fi
}

run_cmd_output() {
    if [[ "$VERBOSE" == true ]]; then
        echo "Running: $*" >&2
    fi
    local output
    output=$("$@" 2>/dev/null) || die "Command failed: $*"
    echo "$output"
}

get_latest_munki_url() {
    local json_response
    json_response=$(run_cmd_output "$CURL" "$MUNKIURL")
    
    if [[ "$VERBOSE" == true ]]; then
        echo "GitHub API response preview:" >&2
        echo "$json_response" | head -5 >&2
    fi
    
    if ! echo "$json_response" | "$JQ" . > /dev/null 2>&1; then
        die "Failed to get valid JSON response from GitHub API. Response: $(echo "$json_response" | head -1)"
    fi
    
    local download_url
    download_url=$(echo "$json_response" | "$JQ" -r '.assets[0].browser_download_url' 2>/dev/null)
    
    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        die "Failed to extract download URL from GitHub API response"
    fi
    
    echo "$download_url"
}

download_pkg() {
    local url="$1"
    local output="$2"
    echo "Downloading munkitools from $url..."
    run_cmd "$CURL" --location --output "$output" "$url"
}

flatten_pkg() {
    local directory="$1"
    local pkg="$2"
    run_cmd "$PKGUTIL" --flatten-full "$directory" "$pkg"
}

expand_pkg() {
    local pkg="$1"
    local directory="$2"
    run_cmd "$PKGUTIL" --expand-full "$pkg" "$directory"
}

plist_to_xml() {
    local plist="$1"
    run_cmd "$PLUTIL" -convert xml1 "$plist"
}

plist_to_binary() {
    local plist="$1"
    run_cmd "$PLUTIL" -convert binary1 "$plist"
}

guess_encoding() {
    local file="$1"
    local enc
    enc=$(run_cmd_output "$FILE" --brief --mime-encoding "$file")
    if [[ "$enc" == *"ascii"* ]]; then
        echo "utf-8"
    else
        echo "$enc"
    fi
}

is_binary() {
    local file="$1"
    local enc
    enc=$(guess_encoding "$file")
    [[ "$enc" == "binary" ]]
}

replace_strings() {
    local strings_file="$1"
    local code="$2"
    local appname="$3"
    
    local localized
    localized=$(get_localized_name "$code")
    if [[ -z "$localized" ]]; then
        log "Unknown language code: $code, skipping..."
        return
    fi
    
    log "Replacing '$localized' in $strings_file with '$appname'..."
    
    local file_type
    file_type=$(file "$strings_file")
    
    local was_utf16=false
    local was_binary=false
    
    if echo "$file_type" | grep -q "UTF-16"; then
        was_utf16=true
        log "Converting UTF-16 file to UTF-8..."
        iconv -f utf-16 -t utf-8 "$strings_file" > "${strings_file}.utf8"
        mv "${strings_file}.utf8" "$strings_file"
    elif echo "$file_type" | grep -q "Apple binary property list" || 
         xxd -l 8 "$strings_file" 2>/dev/null | grep -q "6270 6c69 7374"; then
        was_binary=true
        log "Converting binary plist to XML format..."
        plist_to_xml "$strings_file"
    fi
    
    # Create backup and process line by line like Python script
    cp "$strings_file" "${strings_file}.bak"
    
    # Process the file line by line, only replacing on right side of = and not in comments
    while IFS= read -r line; do
        # Check if line contains = and doesn't start with /*
        if [[ "$line" == *"="* && "$line" != "/*"* ]]; then
            # Split on first = and replace only in right side
            left="${line%%=*}="
            right="${line#*=}"
            right="${right//$localized/$appname}"
            echo "${left}${right}"
        else
            echo "$line"
        fi
    done < "${strings_file}.bak" > "$strings_file"
    
    rm "${strings_file}.bak"
    
    if [[ "$was_utf16" == true ]]; then
        log "Converting back to UTF-16..."
        # Use utf-16 (not utf-16le) to include the BOM
        iconv -f utf-8 -t utf-16 "$strings_file" > "${strings_file}.utf16"
        mv "${strings_file}.utf16" "$strings_file"
    elif [[ "$was_binary" == true ]]; then
        log "Converting back to binary plist..."
        plist_to_binary "$strings_file"
    fi
}

icon_test() {
    local png="$1"
    local header
    header=$(xxd -p -l 8 "$png" 2>/dev/null | tr '[:lower:]' '[:upper:]')
    [[ "$header" == "89504E470D0A1A0A" ]]
}

convert_to_icns() {
    local png="$1"
    local output_dir="$2"
    local actool="$3"
    
    local icon_dir="$output_dir/icons"
    mkdir -p "$icon_dir"
    
    local xcassets="$icon_dir/Assets.xcassets"
    mkdir -p "$xcassets"
    
    local iconset="$xcassets/AppIcon.appiconset"
    mkdir -p "$iconset"
    
    cat > "$iconset/Contents.json" << 'EOF'
{
  "images" : [
EOF
    
    local first_item=true
    for size_info in "${ICON_SIZES[@]}"; do
        local hw="${size_info%:*}"
        local suffix="${size_info#*:}"
        local scale="1x"
        
        if [[ "$suffix" == *"@2x" ]]; then
            scale="2x"
        fi
        
        run_cmd "$SIPS" -z "$hw" "$hw" "$png" --out "$iconset/AppIcon_${suffix}.png"
        
        local display_hw="$hw"
        if [[ "$suffix" == *"@2x" ]]; then
            display_hw=$((hw / 2))
        fi
        
        if [[ "$first_item" != true ]]; then
            echo "," >> "$iconset/Contents.json"
        fi
        cat >> "$iconset/Contents.json" << EOF
    {
      "size" : "${display_hw}x${display_hw}",
      "idiom" : "mac",
      "filename" : "AppIcon_${suffix}.png",
      "scale" : "${scale}"
    }
EOF
        first_item=false
    done
    
    cat >> "$iconset/Contents.json" << 'EOF'
  ],
  "info" : {
    "version" : 1,
    "author" : "xcode"
  }
}
EOF
    
    local icnspath="$icon_dir/AppIcon.icns"
    local carpath="$icon_dir/Assets.car"
    
    if [[ -n "$actool" ]]; then
        local rebrand_dir
        rebrand_dir=$(dirname "$(realpath "$0")")
        local xc_assets_dir="$rebrand_dir/Assets.xcassets/"
        
        if [[ -d "$xc_assets_dir" ]]; then
            cp -r "$xc_assets_dir"* "$xcassets/"
        fi
        
        run_cmd "$actool" --compile "$icon_dir" --app-icon "AppIcon" \
            --minimum-deployment-target "10.11" \
            --output-partial-info-plist "$icon_dir/Info.plist" \
            --platform "macosx" --errors --warnings "$xcassets"
    else
        run_cmd "$ICONUTIL" -c icns "$iconset" -o "$icnspath"
    fi
    
    local return_icns=""
    local return_car=""
    
    if [[ -f "$icnspath" ]]; then
        return_icns="$icnspath"
    fi
    
    if [[ -f "$carpath" ]]; then
        return_car="$carpath"
    fi
    
    echo "$return_icns:$return_car"
}

sign_package() {
    local signing_id="$1"
    local pkg="$2"
    echo "Signing pkg..."
    run_cmd "$PRODUCTSIGN" --sign "$signing_id" "$pkg" "${pkg}-signed"
    echo "Moving ${pkg}-signed to ${pkg}..."
    mv "${pkg}-signed" "$pkg"
}

sign_binary() {
    local signing_id="$1"
    local binary="$2"
    local deep="$3"
    local force="$4"
    local entitlements="$5"
    
    if [[ "$VERBOSE" == true ]]; then
        echo "sign_binary called with:"
        echo "  signing_id: $signing_id"
        echo "  binary: $binary"
        echo "  deep: $deep"
        echo "  force: $force"
        echo "  entitlements: $entitlements"
    fi
    
    local cmd=("$CODESIGN" --sign "$signing_id")
    
    if [[ "$force" == true ]]; then
        cmd+=(--force)
    fi
    
    if [[ "$deep" == true ]]; then
        cmd+=(--deep)
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        cmd+=(--verbose)
    fi
    
    if [[ -n "$entitlements" ]]; then
        cmd+=(--entitlements "$entitlements")
    fi
    
    cmd+=(--options runtime)
    cmd+=("$binary")
    
    if [[ "$VERBOSE" == true ]]; then
        echo "Executing codesign command: ${cmd[*]}"
    fi
    run_cmd "${cmd[@]}"
}

is_signable_bin() {
    local path="$1"
    [[ -f "$path" && -x "$path" ]]
}

is_signable_lib() {
    local path="$1"
    [[ -f "$path" && ("$path" == *.so || "$path" == *.dylib) ]]
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Rebrands Munki's Managed Software Center - gives the app a new name in Finder,
and can also modify its icon. N.B. You will need Xcode and its command-line
tools installed to run this script successfully.

OPTIONS:
    -a, --appname NAME          Your desired app name for Managed Software Center (required)
    -k, --pkg PATH             Prebuilt munkitools pkg to rebrand
    -i, --icon-file PATH       Optional icon file (1024x1024 .png with alpha channel)
    --identifier PREFIX        Change package identifier prefix (default: com.googlecode.munki)
    -o, --output-file NAME     Base name for customized pkg output
    -p, --postinstall PATH     Optional postinstall script to include
    -r, --resource-addition PATH   Optional additional file for scripts directory
    -s, --sign-package ID      Sign package with Developer ID Installer certificate
    -S, --sign-binaries ID     Sign binaries with Developer ID Application certificate
    -v, --verbose              Be more verbose
    -x, --version              Print version and exit
    -h, --help                 Show this help

EXAMPLES:
    $0 -a "My Software Center"
    $0 -a "My Software Center" -i /path/to/icon.png -v
    $0 -a "My Software Center" -k /path/to/munkitools.pkg -o "my-munkitools"

EOF
}

main() {
    local appname=""
    local pkg=""
    local icon_file=""
    local identifier="com.googlecode.munki"
    local output_file=""
    local postinstall=""
    local resource_addition=""
    local sign_package_id=""
    local sign_binaries_id=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--appname)
                appname="$2"
                shift 2
                ;;
            -k|--pkg)
                pkg="$2"
                shift 2
                ;;
            -i|--icon-file)
                icon_file="$2"
                shift 2
                ;;
            --identifier)
                identifier="$2"
                shift 2
                ;;
            -o|--output-file)
                output_file="$2"
                shift 2
                ;;
            -p|--postinstall)
                postinstall="$2"
                shift 2
                ;;
            -r|--resource-addition)
                resource_addition="$2"
                shift 2
                ;;
            -s|--sign-package)
                sign_package_id="$2"
                shift 2
                ;;
            -S|--sign-binaries)
                sign_binaries_id="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -x|--version)
                echo "$VERSION"
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
    
    if [[ -z "$appname" ]]; then
        echo "ERROR: -a or --appname is required" >&2
        usage >&2
        exit 1
    fi
    
    if [[ $EUID -ne 0 ]]; then
        die "You must run this script as root in order to build your new munki installer pkg!"
    fi
    
    TMP_DIR=$(mktemp -d)
    
    local outfilename="${output_file:-munkitools}"
    
    local actool=""
    for tool_path in "${ACTOOL_PATHS[@]}"; do
        if [[ -f "$tool_path" ]]; then
            actool="$tool_path"
            break
        fi
    done
    
    if [[ -z "$actool" ]]; then
        echo "WARNING: actool not found. Icon file will not be replaced in Munki 3.6 and higher. See README for more info."
    fi
    
    local icns=""
    local car=""
    if [[ -n "$icon_file" && -f "$icon_file" ]]; then
        if icon_test "$icon_file"; then
            echo "Converting .png file to .icns..."
            
            local icon_result
            icon_result=$(VERBOSE=false convert_to_icns "$icon_file" "$TMP_DIR" "$actool")
            
            icns=$(echo "$icon_result" | cut -d':' -f1 | tail -1)
            car=$(echo "$icon_result" | cut -d':' -f2 | tail -1)
            
            log "Icon conversion result - ICNS: '$icns', CAR: '$car'"
        else
            die "Icon file must be a 1024x1024 .png"
        fi
    else
        log "No icon file provided or file doesn't exist: '$icon_file'"
    fi
    
    local output="$TMP_DIR/munkitools.pkg"
    
    if [[ -z "$pkg" ]]; then
        echo "Fetching latest Munki release info from GitHub..."
        local munki_url
        munki_url=$(get_latest_munki_url)
        if [[ -z "$munki_url" ]]; then
            die "Failed to get Munki download URL"
        fi
        log "Got download URL: $munki_url"
        download_pkg "$munki_url" "$output"
        pkg="$output"
    elif [[ "$pkg" == http* ]]; then
        download_pkg "$pkg" "$output"
        pkg="$output"
    fi
    
    if [[ ! -f "$pkg" ]]; then
        die "Could not find munkitools pkg $pkg"
    fi
    
    local root_dir="$TMP_DIR/root"
    expand_pkg "$pkg" "$root_dir"
    
    local app_pkg=""
    local core_pkg=""  
    local python_pkg=""
    local admin_pkg=""
    
    for pattern in "munkitools_app.pkg" "munkitools_app-*.pkg" "munkitools_admin*" "munkitools_app_usage*"; do
        local found_pkg
        found_pkg=$(find "$root_dir" -name "$pattern" -type d 2>/dev/null | head -1)
        if [[ -n "$found_pkg" ]]; then
            case "$pattern" in
                "munkitools_app.pkg"|"munkitools_app-"*)
                    if [[ -z "$app_pkg" ]]; then
                        app_pkg="$found_pkg"
                        log "Found primary app package: $app_pkg"
                    fi
                    ;;
                "munkitools_admin*")
                    admin_pkg="$found_pkg"
                    ;;
                "munkitools_app_usage*")
                    if [[ -z "$app_pkg" ]]; then
                        app_pkg="$found_pkg"
                        log "Using app_usage package as fallback: $app_pkg"
                    fi
                    ;;
            esac
        fi
    done
    
    core_pkg=$(find "$root_dir" -name "munkitools_core*" -type d 2>/dev/null | head -1)
    python_pkg=$(find "$root_dir" -name "munkitools_python*" -type d 2>/dev/null | head -1)
    if [[ -z "$python_pkg" ]]; then
        # Try alternative naming
        python_pkg=$(find "$root_dir" -name "munkitools_pythonlibs*" -type d 2>/dev/null | head -1)
    fi
    local launchd_pkg=$(find "$root_dir" -name "munkitools_launchd*" -type d 2>/dev/null | head -1)
    local app_usage_pkg=$(find "$root_dir" -name "munkitools_app_usage*" -type d 2>/dev/null | head -1)
    
    local actual_app_pkg=""
    for candidate in "$app_pkg" "$admin_pkg"; do
        if [[ -n "$candidate" && -d "$candidate" ]]; then
            local app_count
            app_count=$(find "$candidate/Payload" -name "*.app" -type d 2>/dev/null | wc -l)
            if [[ $app_count -gt 0 ]]; then
                actual_app_pkg="$candidate"
                log "Confirmed GUI apps in: $candidate ($app_count apps found)"
                break
            fi
        fi
    done
    
    if [[ -n "$actual_app_pkg" ]]; then
        app_pkg="$actual_app_pkg"
    fi
    
    if [[ -z "$app_pkg" || -z "$core_pkg" || -z "$python_pkg" ]]; then
        echo "Package components found:"
        find "$root_dir" -name "munkitools_*" -type d
        die "Could not find required package components. Found: app='$app_pkg' core='$core_pkg' python='$python_pkg'"
    fi
    
    log "Found packages: app='$app_pkg' core='$core_pkg' python='$python_pkg'"
    
    if [[ "$VERBOSE" == true ]]; then
        echo "Checking package contents to find the GUI apps:" >&2
        for pkg_dir in "$root_dir"/munkitools_*.pkg; do
            if [[ -d "$pkg_dir" ]]; then
                echo "Package: $(basename "$pkg_dir")" >&2
                echo "  Apps found:" >&2
                find "$pkg_dir/Payload" -name "*.app" -type d 2>/dev/null | head -5 >&2 || true
                echo "  Sample files:" >&2
                find "$pkg_dir/Payload" -type f 2>/dev/null | head -5 >&2 || true
                echo >&2
            fi
        done
        echo "Package inspection completed." >&2
    fi
    
    log "Proceeding with package processing..."
    
    log "About to read Distribution file..."
    local distfile="$root_dir/Distribution"
    if [[ ! -f "$distfile" ]]; then
        die "Distribution file not found: $distfile"
    fi
    
    log "Reading Distribution file: $distfile"
    
    local munki_version
    munki_version=$(grep -o "product.*id=\"$identifier\".*version=\"[^\"]*\"" "$distfile" 2>/dev/null | sed 's/.*version="\([^"]*\)".*/\1/' | head -1)
    
    if [[ -z "$munki_version" ]]; then
        munki_version=$(grep -o "product.*version=\"[^\"]*\"" "$distfile" 2>/dev/null | sed 's/.*version="\([^"]*\)".*/\1/' | head -1)
    fi
    
    if [[ -z "$munki_version" ]]; then
        munki_version="6.6.5"
        log "Could not extract version from Distribution file, using fallback: $munki_version"
    else
        log "Extracted munki version: $munki_version"
    fi
    
    log "Setting up package paths..."
    local app_scripts="$app_pkg/Scripts"
    local app_payload="$app_pkg/Payload"
    local core_payload="$core_pkg/Payload"
    local python_payload="$python_pkg/Payload"
    
    log "Package paths:"
    log "  app_scripts: $app_scripts"
    log "  app_payload: $app_payload"
    log "  core_payload: $core_payload"
    log "  python_payload: $python_payload"
    
    if [[ -n "$postinstall" && -f "$postinstall" ]]; then
        local dest="$app_scripts/postinstall"
        echo "Copying postinstall script $postinstall to $dest..."
        cp "$postinstall" "$dest"
        echo "Making $dest executable..."
        chmod 755 "$dest"
    fi
    
    if [[ -n "$resource_addition" && -f "$resource_addition" ]]; then
        echo "Adding additional resource $resource_addition to $app_scripts..."
        cp "$resource_addition" "$app_scripts/"
    fi
    
    echo "Replacing app name with $appname..."
    
    local apps=(
        "$MSC_APP_PATH"
        "$MS_APP_PATH"
        "$MN_APP_PATH"
    )
    
    for app_path in "${apps[@]}"; do
        local app_dir="$app_payload/$app_path"
        local resources_dir="$app_dir/Contents/Resources"
        
        log "Processing app: $app_path"
        log "App directory: $app_dir"
        log "Resources directory: $resources_dir"
        
        if [[ -d "$resources_dir" ]]; then
            log "Resources directory exists, processing..."
            
            if [[ "$VERBOSE" == true ]]; then
                echo "Contents of $resources_dir:" >&2
                ls -la "$resources_dir" >&2
            fi
            
            for lproj_dir in "$resources_dir"/*.lproj; do
                if [[ -d "$lproj_dir" ]]; then
                    local code
                    code=$(basename "$lproj_dir" .lproj)
                    
                    local localized_name
                    localized_name=$(get_localized_name "$code")
                    if [[ -n "$localized_name" ]]; then
                        find "$lproj_dir" -name "*.strings" -type f | while read -r strings_file; do
                            replace_strings "$strings_file" "$code" "$appname"
                        done
                    fi
                fi
            done
            
            if [[ -n "$icon_file" ]]; then
                log "Processing icon replacement for $app_path"
                log "Icon file provided: $icon_file"
                log "Generated ICNS: '$icns'"
                log "Generated CAR: '$car'"
                
                local icon_files=()
                case "$app_path" in
                    *"Managed Software Center.app")
                        icon_files=("Managed Software Center.icns" "AppIcon.icns")
                        ;;
                    *"MunkiStatus.app")
                        icon_files=("MunkiStatus.icns" "AppIcon.icns")
                        ;;
                    *"munki-notifier.app")
                        icon_files=("AppIcon.icns")
                        ;;
                esac
                
                if [[ -n "$icns" && -f "$icns" ]]; then
                    log "Looking for icon files in $resources_dir"
                    if [[ ${#icon_files[@]} -gt 0 ]]; then
                        for icon in "${icon_files[@]}"; do
                            local icon_path="$resources_dir/$icon"
                            if [[ -f "$icon_path" ]]; then
                                echo "Replacing $icon_path with custom icon..."
                                cp "$icns" "$icon_path"
                                log "Successfully replaced $icon_path"
                            else
                                log "Icon file $icon_path not found"
                            fi
                        done
                    fi
                    
                    find "$resources_dir" -name "*.icns" -type f | while read -r existing_icon; do
                        echo "Replacing additional icon: $existing_icon"
                        cp "$icns" "$existing_icon"
                    done
                else
                    log "Generated icns file not found or empty: '$icns'"
                fi
                
                if [[ -n "$car" && -f "$car" ]]; then
                    local car_path="$resources_dir/Assets.car"
                    if [[ -f "$car_path" ]]; then
                        echo "Replacing $car_path with compiled assets..."
                        cp "$car" "$car_path"
                        log "Successfully replaced Assets.car"
                    else
                        log "Assets.car not found at $car_path"
                    fi
                else
                    log "Generated Assets.car file not found or empty: '$car'"
                fi
            else
                log "No icon file provided, skipping icon replacement"
            fi
        else
            log "Resources directory does not exist: $resources_dir"
            
            if [[ "$VERBOSE" == true && -d "$app_dir" ]]; then
                echo "Contents of $app_dir:" >&2
                find "$app_dir" -type f -name "*.icns" -o -name "*.car" -o -name "Assets.car" 2>/dev/null | head -10 >&2
                echo "Directory structure:" >&2
                find "$app_dir" -type d | head -10 >&2
            fi
            
            if [[ "$VERBOSE" == true ]]; then
                echo "Checking if apps exist as archives or other formats:" >&2
                find "$app_payload" -name "*.app" -type f 2>/dev/null | head -5 >&2
                echo "All files in payload:" >&2
                find "$app_payload" -type f | head -20 >&2
            fi
        fi
    done
    
    find "$root_dir" -exec chown 0:80 {} \;
    
    if [[ -n "$sign_binaries_id" ]]; then
        echo "Signing binaries (this may take a while)..."
        
        log "Payload directories:"
        log "  app_payload: $app_payload"
        log "  core_payload: $core_payload"
        log "  python_payload: $python_payload"
        log "App path variables:"
        log "  MSC_APP_PATH: $MSC_APP_PATH"
        log "  MS_APP_PATH: $MS_APP_PATH"
        log "  MN_APP_PATH: $MN_APP_PATH"
        
        log "Checking payload contents:"
        if [[ -d "$app_payload" ]]; then
            log "Contents of app_payload ($app_payload):"
            find "$app_payload" -name "*.app" -type d | head -10 | while read -r app; do
                log "  Found app: $app"
            done
        else
            log "ERROR: app_payload directory does not exist: $app_payload"
        fi
        
        local entitlements_content='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>'
        
        local ent_file="$TMP_DIR/entitlements.plist"
        echo "$entitlements_content" > "$ent_file"
        
        # Start with an empty array and dynamically find all binaries
        local binaries=()
        
        # App package binaries (including the specific ones we know about)
        if [[ -d "$app_payload" ]]; then
            binaries+=(
                "$app_payload/$MSC_APP_PATH/Contents/PlugIns/MSCDockTilePlugin.docktileplugin"
                "$app_payload/$MSC_APP_PATH/Contents/Helpers/munki-notifier.app"
                "$app_payload/$MS_APP_PATH"
                "$app_payload/$MSC_APP_PATH"
            )
        fi
        
        # Core package binaries
        if [[ -d "$core_payload" ]]; then
            local core_binaries
            core_binaries=$(find "$core_payload" -type f -perm +111 2>/dev/null)
            while IFS= read -r binary; do
                if [[ -n "$binary" ]] && (is_signable_bin "$binary" || is_signable_lib "$binary"); then
                    binaries+=("$binary")
                fi
            done <<< "$core_binaries"
        fi
        
        # Admin package binaries
        if [[ -n "$admin_pkg" && -d "$admin_pkg/Payload" ]]; then
            local admin_binaries
            admin_binaries=$(find "$admin_pkg/Payload" -type f -perm +111 2>/dev/null)
            while IFS= read -r binary; do
                if [[ -n "$binary" ]] && (is_signable_bin "$binary" || is_signable_lib "$binary"); then
                    binaries+=("$binary")
                fi
            done <<< "$admin_binaries"
        fi
        
        # App usage package binaries
        if [[ -n "$app_usage_pkg" && -d "$app_usage_pkg/Payload" ]]; then
            local app_usage_binaries
            app_usage_binaries=$(find "$app_usage_pkg/Payload" -type f -perm +111 2>/dev/null)
            while IFS= read -r binary; do
                if [[ -n "$binary" ]] && (is_signable_bin "$binary" || is_signable_lib "$binary"); then
                    binaries+=("$binary")
                fi
            done <<< "$app_usage_binaries"
        fi
        
        # Launchd package - usually no binaries but check anyway
        if [[ -n "$launchd_pkg" && -d "$launchd_pkg/Payload" ]]; then
            local launchd_binaries
            launchd_binaries=$(find "$launchd_pkg/Payload" -type f -perm +111 2>/dev/null)
            while IFS= read -r binary; do
                if [[ -n "$binary" ]] && (is_signable_bin "$binary" || is_signable_lib "$binary"); then
                    binaries+=("$binary")
                fi
            done <<< "$launchd_binaries"
        fi
        
        if [[ "$VERBOSE" == true ]]; then
            echo "DEBUG: Constructed binary paths:"
            echo "  MSC app: $app_payload/$MSC_APP_PATH"
            echo "  MS app: $app_payload/$MS_APP_PATH"  
            echo "  MN app: $app_payload/$MN_APP_PATH"
            echo "  Plugin: $app_payload/$MSC_APP_PATH/Contents/PlugIns/MSCDockTilePlugin.docktileplugin"
            
            echo "DEBUG: Initial binaries to sign:"
            for binary in "${binaries[@]}"; do
                echo "  - $binary"
                if [[ -e "$binary" ]]; then
                    echo "    EXISTS"
                else
                    echo "    MISSING"
                    # Let's see what's actually in the parent directory
                    local parent_dir
                    parent_dir=$(dirname "$binary")
                    if [[ -d "$parent_dir" ]]; then
                        echo "    Parent directory exists: $parent_dir"
                        echo "    Contents of parent directory:"
                        ls -la "$parent_dir" 2>/dev/null | head -5 | while read -r line; do
                            echo "      $line"
                        done
                    else
                        echo "    Parent directory does not exist: $parent_dir"
                    fi
                fi
            done
        fi
        
        # Python package binaries (needs specific handling for .so/.dylib files)
        local pylib="$python_payload/$PY_CUR/lib"
        local pybin="$python_payload/$PY_CUR/bin"
        
        for pydir in "$pylib" "$pybin"; do
            if [[ -d "$pydir" ]]; then
                # Use a temporary file to avoid subshell issue
                local temp_file
                temp_file=$(mktemp)
                find "$pydir" -type f \( -perm +111 -o -name "*.so" -o -name "*.dylib" \) > "$temp_file"
                while IFS= read -r binary; do
                    if [[ -n "$binary" ]] && (is_signable_bin "$binary" || is_signable_lib "$binary"); then
                        binaries+=("$binary")
                    fi
                done < "$temp_file"
                rm -f "$temp_file"
            fi
        done
        
        # Add entitled binaries only if they exist
        local entitled_binaries=()
        local python_app="$python_payload/$PY_CUR/Resources/Python.app"
        local python3_bin="$python_payload/$PY_CUR/bin/python3"
        
        if [[ -e "$python_app" ]]; then
            entitled_binaries+=("$python_app")
        fi
        if [[ -e "$python3_bin" ]]; then
            entitled_binaries+=("$python3_bin")
        fi
        
        if [[ "$VERBOSE" == true ]]; then
            echo "Found ${#binaries[@]} binaries to sign:"
            for binary in "${binaries[@]}"; do
                echo "  - $binary"
            done
        fi
        
        for binary in "${binaries[@]}"; do
            if [[ -e "$binary" ]]; then
                if [[ "$VERBOSE" == true ]]; then
                    echo "Signing $binary..."
                    if [[ -f "$binary" ]]; then
                        echo "  File exists and is regular file: $binary"
                    elif [[ -d "$binary" ]]; then
                        echo "  File exists and is directory (app bundle): $binary"
                    fi
                fi
                sign_binary "$sign_binaries_id" "$binary" true true ""
            else
                echo "WARNING: Binary not found: $binary"
            fi
        done
        
        if [[ "$VERBOSE" == true ]]; then
            echo "Found ${#entitled_binaries[@]} entitled binaries to sign:"
            if [[ ${#entitled_binaries[@]} -gt 0 ]]; then
                for binary in "${entitled_binaries[@]}"; do
                    echo "  - $binary"
                done
            fi
        fi
        
        if [[ ${#entitled_binaries[@]} -gt 0 ]]; then
            for binary in "${entitled_binaries[@]}"; do
            if [[ -e "$binary" ]]; then
                if [[ "$VERBOSE" == true ]]; then
                    echo "Signing $binary with entitlements..."
                    if [[ -f "$binary" ]]; then
                        echo "  File exists and is regular file: $binary"
                    elif [[ -d "$binary" ]]; then
                        echo "  File exists and is directory (app bundle): $binary"
                    fi
                fi
                sign_binary "$sign_binaries_id" "$binary" true true "$ent_file"
            else
                echo "WARNING: Entitled binary not found: $binary"
            fi
            done
        fi
        
        local py_fwkpath="$python_payload/$PY_FWK"
        if [[ -d "$py_fwkpath" ]]; then
            if [[ "$VERBOSE" == true ]]; then
                echo "Signing Python framework..."
                echo "  Signing $py_fwkpath..."
            fi
            sign_binary "$sign_binaries_id" "$py_fwkpath" true true ""
        fi
    fi
    
    local final_pkg
    final_pkg="$(pwd)/${outfilename}-${munki_version}.pkg"
    echo "Building output pkg at $final_pkg..."
    flatten_pkg "$root_dir" "$final_pkg"
    
    if [[ -n "$sign_package_id" ]]; then
        sign_package "$sign_package_id" "$final_pkg"
    fi
    
    echo "Rebranding complete! Output: $final_pkg"
}

main "$@"