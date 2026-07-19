#!/bin/zsh
set -e # Exit if one of commands exit with non-zero exit code
set -u # Treat unset variables and parameters other than the special parameters ‘@’ or ‘*’ as an error
set -o pipefail # Any command failed in the pipe fails the whole pipe
# set -x # Print shell commands as they are executed (or you can try -v which is less verbose)

# The build system is zsh-only (zsh ships with macOS — no bash 5 / Homebrew bash required)
if /bin/test -z "${ZSH_VERSION:-}"; then
    echo "The build scripts must run under zsh (macOS's default shell). Run them directly, e.g. ./build-debug.sh" > /dev/stderr
    exit 1
fi
setopt no_nomatch # bash-like globbing: pass unmatched globs through instead of erroring
setopt no_equals  # never treat a word starting with '=' as =cmd expansion

add-optional-dep-to-bin() {
    if /usr/bin/which "$1" &> /dev/null; then
        /bin/cat > ".deps/bin/${2:-$1}" <<EOF
#!/bin/sh
exec '$(/usr/bin/which "$1")' "\$@"
EOF
    fi
}

if /bin/test -z "${NUKE_PATH:-}"; then
    /bin/rm -rf .deps/bin
    /bin/mkdir -p .deps/bin

    add-optional-dep-to-bin bash # only to syntax-check the generated bash completion artifact (build-shell-completion.sh)
    add-optional-dep-to-bin fish # build-shell-completion.sh
    add-optional-dep-to-bin rustc # build-shell-completion.sh
    add-optional-dep-to-bin cargo # build-shell-completion.sh
    add-optional-dep-to-bin brew # install-from-sources.sh
    add-optional-dep-to-bin bundle # build-docs.sh
    add-optional-dep-to-bin bundler # build-docs.sh
    add-optional-dep-to-bin xcbeautify # build-release.sh
    add-optional-dep-to-bin git
    add-optional-dep-to-bin swift
    add-optional-dep-to-bin swiftly

    export PATH="${PWD}/.deps/bin:/bin:/usr/bin"
    chmod +x .deps/bin/*
    export NUKE_PATH=1
fi

swift() {
    # Use swiftly only if it's installed AND initialized; a merely-installed swiftly errors out
    # ("Could not load swiftly's configuration file"). Probe once per process.
    if /bin/test -z "${_aero_use_swiftly:-}"; then
        if /usr/bin/which swiftly &> /dev/null && swiftly run swift --version &> /dev/null; then
            _aero_use_swiftly=1
        else
            _aero_use_swiftly=0
            echo "warning: swiftly is not installed or not initialized. Fallback to plain swift. Swift compilation might not be reproducible" > /dev/stderr
        fi
    fi
    if /bin/test "$_aero_use_swiftly" = 1; then
        swiftly run swift "$@"
    else
        /usr/bin/env swift "$@"
    fi
}

xcodebuild-pretty() {
    log_file="$1"
    shift
    # Mute stderr
    # 2024-02-12 23:48:11.713 xcodebuild[60777:7403664] [MT] DVTAssertions: Warning in /System/Volumes/Data/SWE/Apps/DT/BuildRoots/BuildRoot11/ActiveBuildRoot/Library/Caches/com.apple.xbs/Sources/IDEFrameworks/IDEFrameworks-22269/IDEFoundation/Provisioning/Capabilities Infrastructure/IDECapabilityQuerySelection.swift:103
    # Details:  createItemModels creation requirements should not create capability item model for a capability item model that already exists.
    # Function: createItemModels(for:itemModelSource:)
    # Thread:   <_NSMainThread: 0x6000037202c0>{number = 1, name = main}
    # Please file a bug at https://feedbackassistant.apple.com with this warning message and any useful information you can provide.
    if /usr/bin/which xcbeautify &> /dev/null; then
        /usr/bin/xcrun xcodebuild "$@" 2>&1 | tee "$log_file" | xcbeautify --quiet # Only print tasks that have warnings or errors
        echo "The full unmodified xcodebuild log is saved to $log_file"
    else
        /usr/bin/xcrun xcodebuild "$@" 2>&1 | tee "$log_file"
    fi
}
