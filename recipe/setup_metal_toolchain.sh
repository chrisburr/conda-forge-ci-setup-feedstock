# Make Apple's Metal Toolchain (the `metal` shader compiler, `metallib` and
# metal_stdlib) available to the build when metal_compiler_version is set in
# the CI config (or METAL_COMPILER_VERSION in the environment).
#
# Since Xcode 26 the toolchain is a separate download, and each Xcode only uses
# the toolchain build that matches it, so the Xcode version determines the
# compiler version. metal_compiler_version is therefore an Xcode version: "26.6"
# selects the newest installed Xcode 26.6.x and "26" the newest Xcode 26.x.
#
# The toolchain only runs on macOS, which is also the only platform Apple's
# licence allows it on, so osx builds cross-compiled from Linux can't use it.

metal_compiler_version=${METAL_COMPILER_VERSION:-}
if [[ -n "${CONFIG:-}" && -f "${CI_SUPPORT}/${CONFIG}.yaml" ]]; then
    metal_compiler_version=$(shyaml get-value metal_compiler_version.0 "${metal_compiler_version}" < "${CI_SUPPORT}/${CONFIG}.yaml")
fi

if [[ -n "${metal_compiler_version}" ]]; then
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "ERROR: metal_compiler_version needs a macOS runner; the Metal Toolchain doesn't run on $(uname)."
        exit 1
    fi

    # Find the newest installed Xcode whose version is metal_compiler_version
    # or starts with "metal_compiler_version."
    metal_xcode=""
    metal_xcode_version=""
    installed_xcodes=""
    for app in ${_CONDA_FORGE_CI_SETUP_XCODE_APPS:-/Applications/Xcode*.app}; do
        v=$(plutil -extract CFBundleShortVersionString raw "${app}/Contents/version.plist" 2>/dev/null) || continue
        installed_xcodes="${installed_xcodes} ${v}"
        if [[ "${v}" == "${metal_compiler_version}" || "${v}" == "${metal_compiler_version}".* ]]; then
            newest=$(printf '%s\n%s\n' "${metal_xcode_version:-0}" "${v}" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
            if [[ "${newest}" == "${v}" ]]; then
                metal_xcode=${app}
                metal_xcode_version=${v}
            fi
        fi
    done
    if [[ -z "${metal_xcode}" ]]; then
        echo "ERROR: metal_compiler_version is ${metal_compiler_version} but no matching Xcode is installed (found:${installed_xcodes:- none})."
        exit 1
    fi
    if [[ "${metal_xcode_version%%.*}" -lt 26 ]]; then
        echo "ERROR: metal_compiler_version needs Xcode 26 or newer, got ${metal_xcode_version}."
        exit 1
    fi

    echo "Selecting Xcode ${metal_xcode_version} (${metal_xcode}) for the Metal Toolchain"
    export DEVELOPER_DIR="${metal_xcode}/Contents/Developer"
    if [[ -z "${_CONDA_FORGE_CI_SETUP_METAL_TESTS:-}" ]]; then
        echo "export DEVELOPER_DIR='${DEVELOPER_DIR}'" >> "${CONDA_PREFIX}/etc/conda/activate.d/conda-forge-ci-setup-activate.sh"
    fi

    if ! xcrun metal --version >/dev/null 2>&1; then
        echo "Downloading the Metal Toolchain"
        for attempt in 1 2 3; do
            if xcodebuild -downloadComponent MetalToolchain; then
                break
            elif [[ ${attempt} -eq 3 ]]; then
                echo "ERROR: failed to download the Metal Toolchain"
                exit 1
            fi
        done
        # The toolchain is mounted in the background after the download returns
        for attempt in $(seq 60); do
            if xcrun metal --version >/dev/null 2>&1; then
                break
            elif [[ ${attempt} -eq 60 ]]; then
                echo "ERROR: the Metal Toolchain was downloaded but \`xcrun metal\` still fails:"
                xcrun metal --version
                exit 1
            fi
            sleep 1
        done
    fi
    echo "Using the Metal Toolchain:"
    xcrun metal --version
fi
