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
    cat >testws/.bazelrc << EOF
common --noenable_bzlmod
startup --windows_enable_symlinks
common --noshow_progress
EOF
}

function create_workspace_file() {
    buildifier_dir=$1
    cat >testws/WORKSPACE << EOF
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
    lint_warnings = ["-cc-native"],
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
    srcs = ["BUILD"],
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
    buildifier_dir=$1
    echo create_simple_workspace in `pwd`/testws referencing $buildifier_dir
    mkdir -p testws

    create_bazelrc
    create_workspace_file $buildifier_dir
    create_build_file "testws/BUILD"
}

function test_buildifier_check_without_runfiles() {
    buildifier_dir=$(dirname $(rlocation _main/WORKSPACE))
    create_simple_workspace "${buildifier_dir}" >"${TEST_log}"
    cd testws

    bazel run \
        --noenable_runfiles \
        //:buildifier.check >>"${TEST_log}" 2>&1 && fail "chebuildck succeeded but should have failed"

    expect_log "^\*\*\*\*\* WORKSPACE" "WORKSPACE issue not found"
}

function test_buildifier_check_with_runfiles() {
    buildifier_dir=$(dirname $(rlocation _main/WORKSPACE))
    create_simple_workspace "${buildifier_dir}" >"${TEST_log}"
    cd testws

    bazel run \
        --enable_runfiles \
        //:buildifier.check >>"${TEST_log}" 2>&1 && fail "check succeeded but should have failed"

    expect_log "^\*\*\*\*\* WORKSPACE" "WORKSPACE issue not found"
}

function test_buildifier_fix_with_runfiles() {
    buildifier_dir=$(dirname $(rlocation _main/WORKSPACE))
    create_simple_workspace "${buildifier_dir}" >"${TEST_log}"
    cd testws
    cp BUILD orig-BUILD-file

    bazel run //:buildifier.fix --enable_runfiles >>$TEST_log 2>&1 || fail "fix should have succeeded"
    bazel run //:buildifier.check --enable_runfiles >>$TEST_log 2>&1 || fail "check should have succeeded"

    expect_log "Running command line: bazel-bin/buildifier\.check\.bat"
    grep -xq "^\*\*\*\*\* WORKSPACE" $TEST_log && fail "found ****** WORKSPACE in log but it should not have appeared"
    # diff returns 0 for same, 1 if differences
    diff orig-BUILD-file BUILD && fail "Expected BUILD to have changed from original"
    return 0
}

function test_buildifier_fix_without_runfiles() {
    buildifier_dir=$(dirname $(rlocation _main/WORKSPACE))
    create_simple_workspace "${buildifier_dir}" >"${TEST_log}"
    cd testws
    cp BUILD orig-BUILD-file

    bazel run //:buildifier.fix --noenable_runfiles >>$TEST_log 2>&1 || fail "fix should have succeeded"
    bazel run //:buildifier.check --noenable_runfiles >>$TEST_log 2>&1 || fail "check should have succeeded"

    expect_log "Running command line: bazel-bin/buildifier\.check\.bat"
    grep -xq "^\*\*\*\*\* WORKSPACE" $TEST_log && fail "found ****** WORKSPACE in log but it should not have appeared"
    # diff returns 0 for same, 1 if differences
    diff orig-BUILD-file BUILD && fail "Expected BUILD to have changed from original"
    return 0
}

run_suite "buildifier suite"
