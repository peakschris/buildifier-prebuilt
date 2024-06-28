source ./tests/unittest/unittest.bash || exit 1

function create_bazelrc() {
  cat >testws/.bazelrc << EOF
common --noenable_bzlmod
startup --windows_enable_symlinks
common --noshow_progress
EOF
}

function create_workspace_file() {
  cat >testws/WORKSPACE << EOF
workspace(name = "simple_example")
local_repository(
    name = "buildifier_prebuilt",
    path = "$escaped_dir",
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
cat > testws/BUILD << EOF
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
  buildifier_dir=$(native_path $1)
  escaped_dir=$(escape_path $buildifier_dir)
  echo create_simple_workspace in $(native_path `pwd`/simple) referencing $buildifier_dir
  mkdir -p testws

  create_bazelrc
  create_workspace_file
  create_build_file
}

function escape_path() {
    path=$1
    path=${path//\\/\\\\}
    echo $path
}

function native_path() {
    path=$1
    path=$(cygpath -C ANSI -w -p "$path")
    echo $path
}

function test_buildifier_check_without_runfiles() {
    buildifier_dir=$(dirname $(realpath WORKSPACE))
    create_simple_workspace "${buildifier_dir}" >"${TEST_log}"
    cd testws

    bazel run \
        --noenable_runfiles \
        //:buildifier.check >>"${TEST_log}" 2>&1 && fail "chebuildck succeeded but should have failed"

    expect_log "^\*\*\*\*\* WORKSPACE" "WORKSPACE issue not found"
}

function test_buildifier_check_with_runfiles() {
    buildifier_dir=$(dirname $(realpath WORKSPACE))
    create_simple_workspace "${buildifier_dir}" >"${TEST_log}"
    cd testws

    bazel run \
        --enable_runfiles \
        //:buildifier.check >>"${TEST_log}" 2>&1 && fail "check succeeded but should have failed"

    expect_log "^\*\*\*\*\* WORKSPACE" "WORKSPACE issue not found"
}

function test_buildifier_fix_with_runfiles() {
    buildifier_dir=$(dirname $(realpath WORKSPACE))
    create_simple_workspace "${buildifier_dir}" >"${TEST_log}"
    cd testws

    bazel run //:buildifier.fix --enable_runfiles >>$TEST_log 2>&1 || fail "fix should have succeeded"
    bazel run //:buildifier.check --enable_runfiles >>$TEST_log 2>&1 || fail "check should have succeeded"

    expect_log "buildifier\.exe"
    grep -xq "^\*\*\*\*\* WORKSPACE" $TEST_log && fail "found ****** WORKSPACE in log but it should not have appeared"
    return 0
}

function test_buildifier_fix_without_runfiles() {
    buildifier_dir=$(dirname $(realpath WORKSPACE))
    create_simple_workspace "${buildifier_dir}" >"${TEST_log}"
    cd testws

    bazel run //:buildifier.fix --noenable_runfiles >>$TEST_log 2>&1 || fail "fix should have succeeded"
    bazel run //:buildifier.check --noenable_runfiles >>$TEST_log 2>&1 || fail "check should have succeeded"

    expect_log "buildifier\.exe"
    grep -xq "^\*\*\*\*\* WORKSPACE" $TEST_log && fail "found ****** WORKSPACE in log but it should not have appeared"
    return 0
}

run_suite "buildifier suite"
