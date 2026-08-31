#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

case "${1:-}" in
  get)
    test "${2:-}" = -f
    stored="$FAKE_CDN_STORE/${3#r2p:/}"
    cp "$stored" "$4"
    exit 0
    ;;
  put)
    source_file=$2
    remote=$3
    stored="$FAKE_CDN_STORE/${remote#r2p:/}"
    mkdir -p "$(dirname -- "$stored")"
    test ! -e "$stored"
    cp "$source_file" "$stored"
    printf '%s\n' "${remote#r2p:/}" >> "$FAKE_FERY_LOG"
    exit 0
    ;;
esac

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=seiya-release.sh
# shellcheck disable=SC1091
source "$script_dir/seiya-release.sh"
repo_root=$(cd -- "$script_dir/../.." && pwd)
test "$cdn_origin" = https://fery.seiya.dev

locked_commit=0123456789abcdef0123456789abcdef01234567
moved_commit=89abcdef0123456789abcdef0123456789abcdef
validate_release_identity_values "$locked_commit" "$locked_commit" "$locked_commit"
if validate_release_identity_values "$locked_commit" "$locked_commit" "$moved_commit" \
  >/dev/null 2>&1; then
  echo '发布 tag 移动后错误接受本次运行锁定的 commit' >&2
  exit 1
fi
if validate_release_identity_values "$locked_commit" "$moved_commit" "$locked_commit" \
  >/dev/null 2>&1; then
  echo 'HEAD 偏离本次运行锁定的 commit 后错误接受' >&2
  exit 1
fi
for invalid_commit in '' 0123456789abcdef0123456789abcdef0123456 \
  0123456789abcdef0123456789abcdef0123456G; do
  if validate_release_commit "$invalid_commit"; then
    echo "非法 SEIYA_RELEASE_COMMIT 被错误接受: $invalid_commit" >&2
    exit 1
  fi
done
workflow_file="$repo_root/.github/workflows/seiya-release.yml"
# shellcheck disable=SC2016 # 这里匹配 GitHub expression 字面量。
grep -Fq 'release_commit: ${{ steps.lock.outputs.release_commit }}' "$workflow_file"
# shellcheck disable=SC2016 # 这里匹配 GitHub expression 字面量。
test "$(grep -Fc 'ref: ${{ needs.guard.outputs.release_commit }}' "$workflow_file")" -eq 2
grep -Fq 'git fetch --force --no-tags origin' "$workflow_file"
test "$(grep -Fc '.github/scripts/seiya-release.sh verify-identity' "$workflow_file")" -eq 2
# shellcheck disable=SC2016 # 这里匹配 GitHub expression 字面量。
grep -Fq "if: \${{ github.event_name == 'workflow_dispatch' && inputs.publish }}" "$workflow_file"
grep -Fq 'test "$release_commit" = "$SELECTED_COMMIT"' "$workflow_file"
grep -Fq 'EXPECTED_MANIFEST: ${{ inputs.expected_manifest_sha256 }}' "$workflow_file"
if grep -Eq '^[[:space:]]*uses: [^#]+@v[0-9]' "$workflow_file"; then
  echo '发布 workflow 含未铆钉到 commit 的 Action' >&2
  exit 1
fi

tailwind_css="$repo_root/web/src/styles/index.css"
grep -Fq "@import 'tailwindcss' source(none);" "$tailwind_css"
grep -Fq "@source '../../index.html';" "$tailwind_css"
grep -Fq "@source '../**/*.{js,jsx,ts,tsx}';" "$tailwind_css"
grep -Fq "@source not '../**/__tests__';" "$tailwind_css"
grep -Fq "@source not '../**/*.test.*';" "$tailwind_css"
if grep -Fxq "@import 'tailwindcss';" "$tailwind_css"; then
  echo 'Tailwind 自动扫描未关闭' >&2
  exit 1
fi

assert_clean_test_tree() {
  test ! -e "$script_dir/__pycache__"
  test -z "$(git -C "$repo_root" status --porcelain --untracked-files=all)"
}
assert_clean_test_tree

test_root=$(mktemp -d "$repo_root/.git/seiya-release-test.XXXXXX")
outside_root=''
trap 'rm -rf -- "$test_root"; if [ -n "${outside_root:-}" ]; then rm -rf -- "$outside_root"; fi' EXIT
export FAKE_CDN_STORE="$test_root/store"
export FAKE_FERY_LOG="$test_root/fery.log"
export cdn_origin=https://test.invalid

curl() {
  local output='' url='' write_status=false arg stored status
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      -o)
        output=$1
        shift
        ;;
      -w)
        write_status=true
        shift
        ;;
      http*) url=$arg ;;
    esac
  done
  stored="$FAKE_CDN_STORE/${url#https://test.invalid/}"
  stored=${stored%%\?*}
  status=${FAKE_CDN_STATUS:-}
  if [ -z "$status" ]; then
    if [ -f "$stored" ]; then status=200; else status=404; fi
  fi
  if [ "$write_status" = true ]; then
    if [ "$status" = 200 ]; then cp "$stored" "$output"; else : > "$output"; fi
    printf '%s' "$status"
    return 0
  fi
  test "$status" = 200 || return 22
  cp "$stored" "$output"
}

artifact="$test_root/artifact"
printf 'first\n' > "$artifact"
publish_immutable "$artifact" "seiya/sources/test/commit/test-linux-amd64" "$0" >/dev/null
test "$(wc -l < "$FAKE_FERY_LOG")" -eq 1
publish_immutable "$artifact" "seiya/sources/test/commit/test-linux-amd64" "$0" >/dev/null
test "$(wc -l < "$FAKE_FERY_LOG")" -eq 1

printf 'conflict\n' > "$artifact"
if publish_immutable "$artifact" "seiya/sources/test/commit/test-linux-amd64" "$0" >/dev/null 2>&1; then
  echo '远端冲突对象被错误接受' >&2
  exit 1
fi
test "$(wc -l < "$FAKE_FERY_LOG")" -eq 1

FAKE_CDN_STATUS=500
export FAKE_CDN_STATUS
if publish_immutable "$artifact" "seiya/sources/test/commit/other" "$0" >/dev/null 2>&1; then
  echo '远端 500 被错误识别为对象不存在' >&2
  exit 1
fi
unset FAKE_CDN_STATUS
test "$(wc -l < "$FAKE_FERY_LOG")" -eq 1

dist="$test_root/dist"
mkdir -p "$dist/new-api"
printf 'amd64\n' > "$dist/new-api/new-api-linux-amd64"
printf 'arm64\n' > "$dist/new-api/new-api-linux-arm64"
cp "$repo_root/LICENSE" "$dist/new-api/LICENSE"
cp "$repo_root/NOTICE" "$dist/new-api/NOTICE"
export release_commit
release_commit=$(git -C "$repo_root" rev-parse HEAD)
source_files_json() {
  python3 - "$repo_root" "$release_commit" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

repo = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
files = (
    ".github/scripts/seiya-release.sh",
    "common/limiter/lua/rate_limit.lua",
    "go.mod",
    "go.sum",
    "i18n/locales/en.yaml",
    "main.go",
    "relaykit/dto/audio.go",
    "relaykit/go.mod",
    "relaykit/go.sum",
    "web/bun.lock",
    "web/index.html",
    "web/rsbuild.config.ts",
    "web/src/main.tsx",
    "web/src/styles/index.css",
    "web/tsconfig.json",
)
records = {}
for relative in files:
    data = subprocess.check_output(["git", "-C", str(repo), "show", f"{commit}:{relative}"])
    records[relative] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
print(json.dumps(records, separators=(",", ":")))
PY
}
write_manifest "$dist"
python3 - "$dist/new-api/release.json" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert set(document) == {"schema_version", "name", "version", "source", "inputs", "targets"}
assert document["name"] == "new-api"
assert document["version"] == "1.0.0-rc.27-seiya.2"
assert set(document["source"]) == {"repository", "commit", "tag"}
assert set(document["inputs"]) == {
    "toolchains", "source_date_epoch", "source_files", "build", "files"
}
assert [item["filename"] for item in document["inputs"]["files"]] == ["LICENSE", "NOTICE"]
source_files = document["inputs"]["source_files"]
assert "main.go" in source_files
assert "relaykit/dto/audio.go" in source_files
assert "web/src/main.tsx" in source_files
assert "web/src/styles/index.css" in source_files
assert "i18n/locales/en.yaml" in source_files
assert "common/quota_math_test.go" not in source_files
assert "web/src/test-setup.ts" not in source_files
assert "web/src/lib/auth-session.test.ts" not in source_files
assert "web/rsbuild.config.ts" in source_files
assert "web/index.html" in source_files
assert ".github/scripts/seiya-release.sh" in source_files
build = document["inputs"]["build"]
assert build["source"] == {"kind": "git-archive", "commit": document["source"]["commit"]}
assert build["frontend"]["install"] == [
    "bun", "install", "--frozen-lockfile", "--registry", "https://registry.npmmirror.com"
]
assert build["frontend"]["environment"]["BUN_TMPDIR"] == "<repo-root>/.seiya-release-build.XXXXXX/tmp"
assert build["frontend"]["environment"]["TMPDIR"] == "<repo-root>/.seiya-release-build.XXXXXX/tmp"
assert build["frontend"]["environment"]["VITE_REACT_APP_VERSION"] == document["version"]
assert build["go"]["flags"] == ["-mod=readonly", "-trimpath", "-buildvcs=false"]
assert build["go"]["environment"]["GOFLAGS"] == ""
assert build["go"]["environment"]["GOPROXY"] == "https://goproxy.cn,direct"
assert build["go"]["environment"]["GOTOOLCHAIN"] == "local"
assert build["go"]["environment"]["TMPDIR"] == "<repo-root>/.seiya-release-build.XXXXXX/tmp"
assert build["go"]["targets"] == {"linux-amd64": "amd64", "linux-arm64": "arm64"}
assert set(document["targets"]) == {"linux-amd64", "linux-arm64"}
for target in document["targets"].values():
    assert set(target) == {"filename", "size", "sha256"}
PY

manifest_backup="$test_root/new-api-release.json"
cp "$dist/new-api/release.json" "$manifest_backup"
python3 - "$dist/new-api/release.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["inputs"]["source_files"] = {"go.sum": document["inputs"]["source_files"]["go.sum"]}
path.write_text(json.dumps(document, sort_keys=True, separators=(",", ":")), encoding="utf-8")
PY
if validate_manifest "$dist" >/dev/null 2>&1; then
  mv -- "$manifest_backup" "$dist/new-api/release.json"
  echo '不完整 source_files 被错误接受' >&2
  exit 1
fi
mv -- "$manifest_backup" "$dist/new-api/release.json"

ignored_input="$repo_root/web/.env.production.local"
test ! -e "$ignored_input"
printf 'SEIYA_UNTRACKED_INPUT=1\n' > "$ignored_input"
if ! python3 - "$script_dir/seiya-source-files.py" "$ignored_input" "$repo_root" <<'PY'
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("seiya_source_files", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
repo = pathlib.Path(sys.argv[3])
relative = pathlib.Path(sys.argv[2]).relative_to(repo).as_posix()
assert relative in module.status_paths(repo)
assert module.is_untracked_build_input(relative, set())
assert module.is_frontend_input("web/.env.production")
assert module.is_frontend_input("web/.env.development")
assert not module.is_frontend_input("docs/.env.production")
observed = {}
original_check_output = module.subprocess.check_output


def fake_check_output(arguments, **kwargs):
    assert arguments == ["go", "env", "GOVERSION"]
    assert kwargs["text"] is True
    observed.update(kwargs["env"])
    return module.EXPECTED_GO_VERSION + "\n"


module.subprocess.check_output = fake_check_output
try:
    assert module.current_go_version() == module.EXPECTED_GO_VERSION
finally:
    module.subprocess.check_output = original_check_output
assert observed["GOTOOLCHAIN"] == "local"
PY
then
  rm -f -- "$ignored_input"
  echo '被忽略但会参与构建的输入未被拒绝' >&2
  exit 1
fi
rm -f -- "$ignored_input"

load_release_identity() { release_commit=$(git -C "$repo_root" rev-parse HEAD); }
require_toolchains() { :; }
# shellcheck disable=SC2329 # build_release 在子 Shell 中按命令名调用该 fixture。
bun() {
  if [ "${1:-}" = install ]; then
    return 1
  fi
  : > "$test_root/bun-build-ran"
}
failure_dist="$test_root/failure-dist"
if build_release "$failure_dist" >/dev/null 2>&1; then
  echo 'bun install 失败后构建错误继续' >&2
  exit 1
fi
test ! -e "$test_root/bun-build-ran"
test -z "$(find "$failure_dist" -maxdepth 1 -type d -name '.build-tmp.*' -print)"
unset -f bun

fake_fery="$test_root/fery"
# shellcheck disable=SC2016 # 这里生成的脚本需要在执行时读取测试环境变量。
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'case "${1:-}" in' \
  '  --version)' \
  '    if [ -n "${FAKE_FERY_VERSION_TAMPER:-}" ]; then printf "tampered\\n" >> "$FAKE_FERY_VERSION_TAMPER"; fi' \
  '    printf "fery 0.1.1\\n"' \
  '    ;;' \
  '  get)' \
  '    test "${2:-}" = -f' \
  '    if [ -n "${FAKE_FERY_GET_LOG:-}" ]; then printf "%s\\n" "${3#r2p:/}" >> "$FAKE_FERY_GET_LOG"; fi' \
  '    cp "$FAKE_CDN_STORE/${3#r2p:/}" "$4"' \
  '    ;;' \
  '  put)' \
  '    if [ "${FAKE_FERY_PUT_MODE:-}" = fail-no-write ]; then exit 1; fi' \
  '    stored="$FAKE_CDN_STORE/${3#r2p:/}"' \
  '    mkdir -p "$(dirname -- "$stored")"' \
  '    test ! -e "$stored"' \
  '    cp "$2" "$stored"' \
  '    printf "%s\\n" "${3#r2p:/}" >> "$FAKE_FERY_LOG"' \
  '    if [ -n "${FAKE_FERY_SOURCE_LOG:-}" ]; then printf "%s\\n" "$2" >> "$FAKE_FERY_SOURCE_LOG"; fi' \
  '    if [ "${FAKE_FERY_PUT_MODE:-}" = fail-after-write ]; then exit 1; fi' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac' > "$fake_fery"
chmod 0755 "$fake_fery"
fery_manifest="$FAKE_CDN_STORE/seiya/tools/fery/0.1.1/release.json"
mkdir -p "$(dirname -- "$fery_manifest")"
python3 - "$fake_fery" "$fery_manifest" <<'PY'
import hashlib
import json
import pathlib
import sys

binary, manifest = (pathlib.Path(value) for value in sys.argv[1:])
data = binary.read_bytes()
manifest.write_text(json.dumps({
    "schema_version": 1,
    "name": "fery",
    "version": "0.1.1",
    "source": {"repository": "in64/fery", "commit": "0" * 40, "tag": "v0.1.1"},
    "inputs": {},
    "targets": {
        "linux-amd64": {
            "filename": "fery-linux-amd64",
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
    },
}), encoding="utf-8")
PY
test "$fery_linux_amd64_size" = 8591296
test "$fery_linux_amd64_sha256" = \
  954d5f8ee16c161e83349a0d82f7200e8312cdbc1463782a6b952cab888987fd
# shellcheck disable=SC2034 # 先验证未固定值必须闭锁，再换成本 fixture 的固定字节。
fery_linux_amd64_size=''
# shellcheck disable=SC2034 # 先验证未固定值必须闭锁，再换成本 fixture 的固定字节。
fery_linux_amd64_sha256=''
if read_fery_record "$fery_manifest" >/dev/null 2>&1; then
  echo '未填充固定 Fery size/SHA 时错误通过' >&2
  exit 1
fi
# shellcheck disable=SC2034 # 由 release 脚本函数动态读取。
fery_linux_amd64_size=$(file_size "$fake_fery")
# shellcheck disable=SC2034 # 由 release 脚本函数动态读取。
fery_linux_amd64_sha256=$(sha256_file "$fake_fery")
verify_fery_binary "$fake_fery"
cp "$fake_fery" "$test_root/fery-original"
printf '# changed\n' >> "$fake_fery"
if verify_fery_binary "$fake_fery" >/dev/null 2>&1; then
  echo '非固定 Fery CLI 被错误接受' >&2
  exit 1
fi
mv -- "$test_root/fery-original" "$fake_fery"
chmod 0755 "$fake_fery"

: > "$FAKE_FERY_LOG"
export FAKE_FERY_SOURCE_LOG="$test_root/fery-source.log"
: > "$FAKE_FERY_SOURCE_LOG"
rm -rf -- "$FAKE_CDN_STORE/seiya/sources"
unset FERY_SECRET_KEY
if publish_release "$dist" "$0" >/dev/null 2>&1; then
  echo '缺少 FERY_SECRET_KEY 时错误进入发布' >&2
  exit 1
fi
export FERY_SECRET_KEY=test-only
tamper_target="$dist/new-api/new-api-linux-amd64"
cp "$tamper_target" "$test_root/new-api-linux-amd64"
export FAKE_FERY_VERSION_TAMPER="$tamper_target"
tamper_size=$(file_size "$tamper_target")
"$fake_fery" --version >/dev/null
test "$(file_size "$tamper_target")" -gt "$tamper_size"
mv -- "$test_root/new-api-linux-amd64" "$tamper_target"
cp "$tamper_target" "$test_root/new-api-linux-amd64"
if publish_release "$dist" "$fake_fery" >/dev/null 2>&1; then
  echo 'Fery --version 篡改原 dist 后错误进入发布' >&2
  exit 1
fi
unset FAKE_FERY_VERSION_TAMPER
mv -- "$test_root/new-api-linux-amd64" "$tamper_target"
test ! -s "$FAKE_FERY_LOG"

export FAKE_FERY_PUT_MODE=fail-after-write
publish_release "$dist" "$fake_fery" >/dev/null
unset FAKE_FERY_PUT_MODE
test "$(wc -l < "$FAKE_FERY_LOG")" -eq 5
test "$(wc -l < "$FAKE_FERY_SOURCE_LOG")" -eq 5
while IFS= read -r source; do
  case "$source" in
    "$repo_root"/.git/seiya-release.*/release/*) ;;
    *)
      echo "发布未使用项目内快照: $source" >&2
      exit 1
      ;;
  esac
  test ! -e "$source"
done < "$FAKE_FERY_SOURCE_LOG"
test "$(tail -n 1 "$FAKE_FERY_LOG")" = \
  "seiya/sources/new-api/$release_commit/release.json"

export FAKE_FERY_GET_LOG="$test_root/fery-get.log"
: > "$FAKE_FERY_GET_LOG"
export FAKE_FERY_PUT_MODE=fail-no-write
# shellcheck disable=SC2329 # publish_immutable 在子 Shell 中按命令名调用该 fixture。
sleep() { :; }
if publish_immutable "$artifact" "seiya/sources/test/no-convergence" "$fake_fery" \
  >/dev/null 2>&1; then
  echo 'Fery put 非零且双通道未收敛时错误成功' >&2
  exit 1
fi
unset -f sleep
unset FAKE_FERY_PUT_MODE
test "$(wc -l < "$FAKE_FERY_GET_LOG")" -eq 10
test -z "$(find "$repo_root/.git" -maxdepth 1 -name 'seiya-release.*' -print)"
assert_clean_test_tree
