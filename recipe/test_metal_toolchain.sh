#!/bin/bash
# Check when setup_metal_toolchain.sh downloads the Metal Toolchain and which
# Xcode it selects. uname, xcrun, xcodebuild and plutil are stubbed, so nothing
# is downloaded and no Xcode is needed.

SCRIPT="${SETUP_METAL_TOOLCHAIN:-${PREFIX}/bin/setup_metal_toolchain.sh}"
CI_SUPPORT_DIR="$(pwd)/.ci_support"

work=$(mktemp -d)
stubs="${work}/stubs"
mkdir -p "${stubs}"
cat > "${stubs}/uname" <<'EOF'
#!/bin/sh
echo "${FAKE_UNAME}"
EOF
# The toolchain counts as installed for an Xcode once ${FAKE_STATE}/<Xcode>.app exists
cat > "${stubs}/xcrun" <<'EOF'
#!/bin/sh
app=$(basename "${DEVELOPER_DIR%/Contents/Developer}")
[ -e "${FAKE_STATE}/${app}" ] || exit 1
echo "Apple metal version 32023.883 (${app})"
EOF
cat > "${stubs}/xcodebuild" <<'EOF'
#!/bin/sh
echo "xcodebuild $*"
touch "${FAKE_STATE}/$(basename "${DEVELOPER_DIR%/Contents/Developer}")"
EOF
cat > "${stubs}/plutil" <<'EOF'
#!/bin/sh
# plutil -extract CFBundleShortVersionString raw FILE
cat "$4" 2>/dev/null
EOF
chmod +x "${stubs}"/*

# Fake Xcode.app bundles: version.plist holds just the version for the stub
for v in 16.4 26.4.1 26.6 27.0; do
    mkdir -p "${work}/apps/Xcode_${v}.app/Contents/Developer"
    echo "${v}" > "${work}/apps/Xcode_${v}.app/Contents/version.plist"
done

failures=0

# Arguments: description, expected output substring ("!" prefix: must not
# appear), expected exit code, then NAME=VALUE environment assignments.
check_case() {
    local desc="$1" expected="$2" expected_rc="$3" out rc
    shift 3
    echo "=== ${desc} ==="
    out=$(env -u METAL_COMPILER_VERSION -u DEVELOPER_DIR \
        PATH="${stubs}:${PATH}" \
        CI_SUPPORT="${CI_SUPPORT_DIR}" \
        CONFIG= \
        FAKE_UNAME=Darwin \
        FAKE_STATE="$(mktemp -d)" \
        _CONDA_FORGE_CI_SETUP_XCODE_APPS="${work}/apps/Xcode*.app" \
        _CONDA_FORGE_CI_SETUP_METAL_TESTS=1 \
        "$@" bash -c 'set -e; source "$1"' _ "${SCRIPT}" 2>&1)
    rc=$?
    echo "${out}"
    if [[ ${rc} -ne ${expected_rc} ]]; then
        echo "FAIL: expected exit code ${expected_rc}, got ${rc}"
        failures=$((failures + 1))
    elif [[ "${expected}" == "!"* && "${out}" == *"${expected#!}"* ]]; then
        echo "FAIL: unexpected '${expected#!}' in output"
        failures=$((failures + 1))
    elif [[ "${expected}" != "!"* && "${out}" != *"${expected}"* ]]; then
        echo "FAIL: expected '${expected}' in output"
        failures=$((failures + 1))
    else
        echo "PASS"
    fi
}

installed="${work}/installed"
mkdir -p "${installed}" && touch "${installed}/Xcode_27.0.app"

check_case "not requested: nothing happens" "!xcodebuild" 0
check_case "requested in the config on Linux: error" "needs a macOS runner" 1 \
    CONFIG=test_metal_toolchain FAKE_UNAME=Linux
check_case "major only: newest Xcode 26.x, then download" \
    "xcodebuild -downloadComponent MetalToolchain
Using the Metal Toolchain:
Apple metal version 32023.883 (Xcode_26.6.app)" 0 \
    CONFIG=test_metal_toolchain
check_case "major.minor: newest patch release" "(Xcode_26.4.1.app)" 0 \
    METAL_COMPILER_VERSION=26.4
check_case "already installed: no download" "!xcodebuild" 0 \
    METAL_COMPILER_VERSION=27.0 FAKE_STATE="${installed}"
check_case "no matching Xcode: error" "no matching Xcode is installed (found: 16.4 26.4.1 26.6 27.0)" 1 \
    METAL_COMPILER_VERSION=26.5
check_case "Xcode older than 26: error" "needs Xcode 26 or newer" 1 \
    METAL_COMPILER_VERSION=16

rm -rf "${work}"
if [[ ${failures} -ne 0 ]]; then
    echo "${failures} case(s) failed"
    exit 1
fi
echo "All setup_metal_toolchain.sh tests passed."
