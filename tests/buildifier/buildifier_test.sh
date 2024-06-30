#!/usr/bin/env bash

# --- begin runfiles.bash initialization v3 ---
# Copy-pasted from the Bazel Bash runfiles library v3.
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

# return a unix-style path on all platforms
# workaround for https://github.com/bazelbuild/bazel/issues/22803
function rlocation_as_unix() {
  path=$(rlocation ${1})
  case "$(uname -s)" in
  CYGWIN* | MINGW32* | MSYS* | MINGW*)
    path=${path//\\//} # backslashes to forward
    path=/${path//:/}  # d:/ to /d/
    ;;
  esac
  echo $path
}

# MARK - Locate Deps

unittest_bash_location=_main/tests/unittest/unittest.bash
unittest_bash="$(rlocation_as_unix "${unittest_bash_location}")"
source ${unittest_bash} || exit 1

function create_bazelrc() {
    wsdir=$1
    cat >${wsdir}/.bazelrc << EOF
common --noenable_bzlmod
startup --windows_enable_symlinks
common --noshow_progress
EOF
}

function create_workspace_file() {
    wsdir=$1
    buildifier_dir=$2
    cat >${wsdir}/WORKSPACE << EOF
workspace(name = "simple_example")
local_repository(
    name = "buildifier_prebuilt",
    path = "$buildifier_dir",
)
load("@buildifier_prebuilt//:deps.bzl", "buildifier_prebuilt_deps")
buildifier_prebuilt_deps()
load("@bazel_skylib//:workspace.bzl", "bazel_skylib_workspace")
bazel_skylib_workspace()
load("@buildifier_prebuilt//:defs.bzl", "buildifier_prebuilt_register_toolchains")
buildifier_prebuilt_register_toolchains()
EOF
}

function create_build_file() {
    dest=$1
    cat > $dest << EOF


load("@buildifier_prebuilt//:rules.bzl", "buildifier", "buildifier_test")

buildifier(

    name = "buildifier.check",
    exclude_patterns = ["./.git/*"],
    lint_mode = "warn",
    lint_warnings = [

"-cc-native"
],
    mode = "diff",
)

buildifier(
    name = "buildifier.fix",
    exclude_patterns = ["./.git/*"],
    lint_mode = "fix",
    lint_warnings = ["-cc-native"],
    mode = "fix",
)

buildifier_test(
    name = "buildifier.test",
    srcs = [      "BUILD"      ],
    lint_mode = "warn",
)

buildifier_test(
    name = "buildifier.test.workspace",
    srcs = ["BUILD"],
    lint_mode = "warn",
    no_sandbox = True,
    workspace = "WORKSPACE",
)
EOF
}

function create_simple_workspace() {
    dirname=$1
    buildifier_dir=$2
    echo create_simple_workspace in `pwd`/${dirname}
    echo new workspace references buildifier module in $buildifier_dir
    mkdir -p ${dirname}

    create_bazelrc ${dirname}
    create_workspace_file ${dirname} $buildifier_dir
    create_build_file "${dirname}/BUILD"
}

function native_path() {
    path=$1
    case "$(uname -s)" in
    CYGWIN* | MINGW32* | MSYS* | MINGW*)
        path=$(cygpath -C ANSI -w -p "$path")
        path=${path//\\//}
        ;;
    esac
    echo $path
}

function is_windows() {
    case "$(uname -s)" in
    CYGWIN* | MINGW32* | MSYS* | MINGW*)
        return 0
        ;;
    esac
    return 1
}

function parent_source_dir() {
    # this gives the source workspace in norunfiles mode (read MANIFEST)
    parent_ws1=$(dirname $(rlocation "_main/WORKSPACE"))
    if [[ ! -f WORKSPACE ]]; then
        echo $parent_ws1
        return
    fi
    # this gives the source workspace in runfiles mode (follow symlink)
    parent_ws2=$(dirname $(native_path $(realpath WORKSPACE)))
    # pick the shorter result. Is there a canonical way to do this?
    if [[ ${#parent_ws1} -lt ${#parent_ws2} ]]; then
        parent_dir=$parent_ws1
    else
        parent_dir=$parent_ws2
    fi
    echo $parent_dir
}

function test_buildifier_is_invoked_with_runfiles() {
    buildifier_dir=$(parent_source_dir)
    wsdir=testws_${RANDOM}
    create_simple_workspace "${wsdir}" "${buildifier_dir}" >"${TEST_log}"
    cd "${wsdir}"

    # run buildifier check and ignore exit status
    bazel run \
        --enable_runfiles \
        //:buildifier.check >>"${TEST_log}" 2>&1 || true

    expect_log "Running command line: bazel-bin/buildifier\.check"
    bazel shutdown >>"${TEST_log}" 2>&1
    cd ..
    rm -rf "${wsdir}"
}

function test_buildifier_is_invoked_without_runfiles() {
    buildifier_dir=$(parent_source_dir)
    wsdir=testws_${RANDOM}
    create_simple_workspace "${wsdir}" "${buildifier_dir}" >"${TEST_log}"
    cd "${wsdir}"

    # run buildifier check and ignore exit status
    bazel run \
        --noenable_runfiles \
        //:buildifier.check >>"${TEST_log}" 2>&1 || true

    expect_log "Running command line: bazel-bin/buildifier\.check"
    bazel shutdown >>"${TEST_log}" 2>&1
    cd ..
    rm -rf "${wsdir}"
}

function test_buildifier_check_with_runfiles() {
    buildifier_dir=$(parent_source_dir)
    wsdir=testws_${RANDOM}
    create_simple_workspace "${wsdir}" "${buildifier_dir}" >"${TEST_log}"
    cd "${wsdir}"

    bazel run \
        --enable_runfiles \
        //:buildifier.check >>"${TEST_log}" 2>&1 && fail "check exited with success code but should have failed"

    # output is different on windows (***** WORKSPACE) and unix (--- ./WORKSPACE)
    if is_windows; then
        expect_log "^\*\*\*\*\* WORKSPACE" "deliberate buildifier issue in WORKSPACE not found"
    else
        expect_log "^--- ./WORKSPACE" "deliberate buildifier issue in WORKSPACE not found"
    fi
    bazel shutdown >>"${TEST_log}" 2>&1
    cd ..
    rm -rf "${wsdir}"
}

function test_buildifier_check_without_runfiles() {
    buildifier_dir=$(parent_source_dir)
    wsdir=testws_${RANDOM}
    create_simple_workspace "${wsdir}" "${buildifier_dir}" >"${TEST_log}"
    cd "${wsdir}"

    bazel run \
        --noenable_runfiles \
        //:buildifier.check >>"${TEST_log}" 2>&1 && fail "check exited with success code but should have failed"

    # output is different on windows (***** WORKSPACE) and unix (--- ./WORKSPACE)
    if is_windows; then
        expect_log "^\*\*\*\*\* WORKSPACE" "deliberate buildifier issue in WORKSPACE not found"
    else
        expect_log "^--- ./WORKSPACE" "deliberate buildifier issue in WORKSPACE not found"
    fi
    bazel shutdown >>"${TEST_log}" 2>&1
    cd ..
    rm -rf "${wsdir}"
}

function test_buildifier_fix_with_runfiles() {
    buildifier_dir=$(parent_source_dir)
    wsdir=testws_${RANDOM}
    create_simple_workspace "${wsdir}" "${buildifier_dir}" >"${TEST_log}"
    cd "${wsdir}"
    cp BUILD orig-BUILD-file

    bazel run //:buildifier.fix --enable_runfiles >>"${TEST_log}" 2>&1 || fail "fix exited with non-zero code but should have succeeded"
    bazel run //:buildifier.check --enable_runfiles >>"${TEST_log}" 2>&1 || fail "check exited with non-zero code but should have succeeded"

    expect_log "Running command line: bazel-bin/buildifier\.check"
    # output is different on windows (***** WORKSPACE) and unix (--- ./WORKSPACE)
    if is_windows; then
        grep -xq "^\*\*\*\*\* WORKSPACE" "${TEST_log}" && fail "deliberate buildifier issue in WORKSPACE should have been fixed but it still exists"
    else
        grep -xq "^--- ./WORKSPACE" "${TEST_log}" && fail "deliberate buildifier issue in WORKSPACE should have been fixed but it still exists"
    fi
    # diff returns 0 for same, 1 if differences
    diff orig-BUILD-file BUILD >/dev/null && fail "Expected BUILD to have changed from original"
    bazel shutdown >>"${TEST_log}" 2>&1
    cd ..
    rm -rf "${wsdir}"
    return 0
}

function test_buildifier_fix_without_runfiles() {
    buildifier_dir=$(parent_source_dir)
    wsdir=testws_${RANDOM}
    create_simple_workspace "${wsdir}" "${buildifier_dir}" >"${TEST_log}"
    cd "${wsdir}"
    cp BUILD orig-BUILD-file

    bazel run //:buildifier.fix --noenable_runfiles >>"${TEST_log}" 2>&1 || fail "fix exited with non-zero code but should have succeeded"
    bazel run //:buildifier.check --noenable_runfiles >>"${TEST_log}" 2>&1 || fail "check exited with non-zero code but should have succeeded"

    expect_log "Running command line: bazel-bin/buildifier\.check"
    # output is different on windows (***** WORKSPACE) and unix (--- ./WORKSPACE)
    if is_windows; then
        grep -xq "^\*\*\*\*\* WORKSPACE" "${TEST_log}" && fail "deliberate buildifier issue in WORKSPACE should have been fixed but it still exists"
    else
        grep -xq "^--- ./WORKSPACE" "${TEST_log}" && fail "deliberate buildifier issue in WORKSPACE should have been fixed but it still exists"
    fi
    # diff returns 0 for same, 1 if differences
    diff orig-BUILD-file BUILD && fail "Expected BUILD to have changed from original"
    bazel shutdown >>"${TEST_log}" 2>&1
    cd ..
    rm -rf "${wsdir}"
    return 0
}

run_suite "buildifier suite"
