#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
cdn_origin=https://fery.seiya.dev
repository=in64/new-api
release_tag=v1.0.0-rc.27-seiya.3
service_version=1.0.0-rc.27-seiya.3
go_version=1.25.1
go_proxy=https://goproxy.cn,direct
bun_version=1.4.0
npm_registry=https://registry.npmmirror.com
fery_version=0.1.1
fery_linux_amd64_size=8591296
fery_linux_amd64_sha256=954d5f8ee16c161e83349a0d82f7200e8312cdbc1463782a6b952cab888987fd

usage() {
  echo '用法: seiya-release.sh build <dist-dir>' >&2
  echo '      seiya-release.sh verify-local <dist-dir>' >&2
  echo '      seiya-release.sh verify-identity' >&2
  echo '      seiya-release.sh install-fery <destination>' >&2
  echo '      seiya-release.sh publish <dist-dir> <fery>' >&2
  echo '      seiya-release.sh verify-remote <dist-dir>' >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_size() {
  if stat -c %s "$1" >/dev/null 2>&1; then
    stat -c %s "$1"
  else
    stat -f %z "$1"
  fi
}

project_temp_file() {
  mktemp "$repo_root/.git/seiya-release.XXXXXX"
}

project_temp_dir() {
  mktemp -d "$repo_root/.git/seiya-release.XXXXXX"
}

source_files_json() {
  python3 "$script_dir/seiya-source-files.py" \
    --repo "$repo_root" --commit "$release_commit"
}

validate_release_commit() {
  local commit
  commit=$1
  test "${#commit}" -eq 40 || return 1
  case "$commit" in
    *[!0-9a-f]*) return 1 ;;
  esac
}

validate_release_identity_values() {
  local expected head tag_commit
  expected=$1
  head=$2
  tag_commit=$3
  validate_release_commit "$expected" || {
    echo 'SEIYA_RELEASE_COMMIT 必须是 40 位小写十六进制 commit' >&2
    return 1
  }
  test "$head" = "$expected" || {
    echo "当前 HEAD 与本次运行锁定的 commit 不一致: $head" >&2
    return 1
  }
  test "$tag_commit" = "$expected" || {
    echo "发布 tag $release_tag 已移动: $tag_commit" >&2
    return 1
  }
}

load_release_identity() {
  local dirty expected tag_commit
  expected=${SEIYA_RELEASE_COMMIT:-}
  release_commit=$(git -C "$repo_root" rev-parse HEAD) || return
  tag_commit=$(git -C "$repo_root" rev-parse "refs/tags/$release_tag^{commit}") || return
  validate_release_identity_values "$expected" "$release_commit" "$tag_commit" || return
  dirty=$(git -C "$repo_root" status --porcelain --untracked-files=all)
  test -z "$dirty" || {
    echo '发布源码工作树不干净' >&2
    return 1
  }
  source_files_json >/dev/null
}

require_toolchains() {
  local current_go
  command -v go >/dev/null || return
  command -v bun >/dev/null || return
  command -v tar >/dev/null || return
  current_go=$(GOTOOLCHAIN=local go env GOVERSION) || return
  test "$current_go" = "go$go_version" || {
    echo "需要 Go $go_version，当前为 $current_go" >&2
    return 1
  }
  test "$(bun --version)" = "$bun_version" || {
    echo "需要 Bun $bun_version，当前为 $(bun --version)" >&2
    return 1
  }
}

manifest_json() {
  local service_dir source_epoch source_file
  service_dir=$1
  source_epoch=$(git -C "$repo_root" show -s --format=%ct "$release_commit") || return
  source_file=$(project_temp_file) || return
  if ! source_files_json > "$source_file"; then
    rm -f -- "$source_file"
    return 1
  fi
  if ! \
  SEIYA_MANIFEST_REPO_ROOT=$repo_root \
  SEIYA_MANIFEST_SERVICE_DIR=$service_dir \
  SEIYA_MANIFEST_SOURCE_FILE=$source_file \
  SEIYA_MANIFEST_NAME=new-api \
  SEIYA_MANIFEST_VERSION=$service_version \
  SEIYA_MANIFEST_REPOSITORY=$repository \
  SEIYA_MANIFEST_COMMIT=$release_commit \
  SEIYA_MANIFEST_TAG=$release_tag \
  SEIYA_MANIFEST_GO=$go_version \
  SEIYA_MANIFEST_GO_PROXY=$go_proxy \
  SEIYA_MANIFEST_BUN=$bun_version \
  SEIYA_MANIFEST_NPM_REGISTRY=$npm_registry \
  SEIYA_MANIFEST_SOURCE_EPOCH=$source_epoch \
    python3 - <<'PY'
import hashlib
import json
import os
import pathlib

repo = pathlib.Path(os.environ["SEIYA_MANIFEST_REPO_ROOT"])
dist = pathlib.Path(os.environ["SEIYA_MANIFEST_SERVICE_DIR"])
name = os.environ["SEIYA_MANIFEST_NAME"]


def file_record(path: pathlib.Path, filename: str | None = None) -> dict:
    if not path.is_file() or path.stat().st_size <= 0:
        raise SystemExit(f"发布输入不存在或为空: {path}")
    return {
        "filename": filename or path.name,
        "size": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


source_files = json.loads(pathlib.Path(os.environ["SEIYA_MANIFEST_SOURCE_FILE"]).read_text(encoding="utf-8"))

targets = {}
for target in ("linux-amd64", "linux-arm64"):
    filename = f"{name}-{target}"
    targets[target] = file_record(dist / filename, filename)

document = {
    "schema_version": 1,
    "name": name,
    "version": os.environ["SEIYA_MANIFEST_VERSION"],
    "source": {
        "repository": os.environ["SEIYA_MANIFEST_REPOSITORY"],
        "commit": os.environ["SEIYA_MANIFEST_COMMIT"],
        "tag": os.environ["SEIYA_MANIFEST_TAG"],
    },
    "inputs": {
        "toolchains": {
            "go": os.environ["SEIYA_MANIFEST_GO"],
            "bun": os.environ["SEIYA_MANIFEST_BUN"],
        },
        "source_date_epoch": int(os.environ["SEIYA_MANIFEST_SOURCE_EPOCH"]),
        "source_files": source_files,
        "build": {
            "source": {
                "kind": "git-archive",
                "commit": os.environ["SEIYA_MANIFEST_COMMIT"],
            },
            "frontend": {
                "working_directory": "web",
                "install": [
                    "bun", "install", "--frozen-lockfile", "--registry",
                    os.environ["SEIYA_MANIFEST_NPM_REGISTRY"],
                ],
                "command": ["bun", "run", "build"],
                "environment": {
                    "BUN_TMPDIR": "<repo-root>/.seiya-release-build.XXXXXX/tmp",
                    "CI": "",
                    "DISABLE_ESLINT_PLUGIN": "true",
                    "TMPDIR": "<repo-root>/.seiya-release-build.XXXXXX/tmp",
                    "VITE_REACT_APP_VERSION": os.environ["SEIYA_MANIFEST_VERSION"],
                },
            },
            "go": {
                "command": ["go", "build"],
                "flags": ["-mod=readonly", "-trimpath", "-buildvcs=false"],
                "environment": {
                    "CGO_ENABLED": "0",
                    "GOFLAGS": "",
                    "GOOS": "linux",
                    "GOPROXY": os.environ["SEIYA_MANIFEST_GO_PROXY"],
                    "GOTOOLCHAIN": "local",
                    "GOWORK": "off",
                    "SOURCE_DATE_EPOCH": os.environ["SEIYA_MANIFEST_SOURCE_EPOCH"],
                    "TMPDIR": "<repo-root>/.seiya-release-build.XXXXXX/tmp",
                },
                "ldflags": [
                    "-s",
                    "-w",
                    "-buildid=",
                    f"-X github.com/QuantumNous/new-api/common.Version={os.environ['SEIYA_MANIFEST_VERSION']}",
                ],
                "package": ".",
                "targets": {"linux-amd64": "amd64", "linux-arm64": "arm64"},
            },
        },
        "files": [
            file_record(dist / "LICENSE", "LICENSE"),
            file_record(dist / "NOTICE", "NOTICE"),
        ],
    },
    "targets": targets,
}
print(json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
PY
  then
    rm -f -- "$source_file"
    return 1
  fi
  rm -f -- "$source_file"
}

write_manifest() {
  local dist_dir
  dist_dir=$1
  manifest_json "$dist_dir/new-api" > "$dist_dir/new-api/release.json" || return
}

validate_manifest() {
  local dist_dir expected
  dist_dir=$1
  expected=$(project_temp_file) || return
  if ! manifest_json "$dist_dir/new-api" > "$expected"; then
    rm -f -- "$expected"
    return 1
  fi
  cmp -s "$expected" "$dist_dir/new-api/release.json" || {
    rm -f -- "$expected"
    echo 'release.json 与源码或本地产物不一致: new-api' >&2
    return 1
  }
  rm -f -- "$expected"
}

verify_local() {
  local dist_dir
  dist_dir=$1
  load_release_identity || return
  validate_manifest "$dist_dir" || return
}

build_release() (
  local dist_dir build_tmp build_source build_work_tmp build_epoch arch output ldflags
  dist_dir=$1
  load_release_identity || return
  require_toolchains || return
  mkdir -p "$dist_dir/new-api" || return
  dist_dir=$(cd -- "$dist_dir" && pwd) || return
  rm -f -- \
    "$dist_dir/new-api/new-api-linux-amd64" \
    "$dist_dir/new-api/new-api-linux-arm64" \
    "$dist_dir/new-api/release.json" || return
  build_epoch=$(git -C "$repo_root" show -s --format=%ct HEAD) || return
  ldflags="-s -w -buildid= -X github.com/QuantumNous/new-api/common.Version=$service_version"
  build_tmp=$(mktemp -d "$repo_root/.seiya-release-build.XXXXXX") || return
  case "$build_tmp" in
    "$repo_root"/.seiya-release-build.*) ;;
    *)
      echo "构建临时目录越过项目边界: $build_tmp" >&2
      return 1
      ;;
  esac
  trap 'rm -rf -- "$build_tmp"' EXIT
  build_source=$build_tmp/source
  build_work_tmp=$build_tmp/tmp
  mkdir -p "$build_source" "$build_work_tmp" || return
  if ! git -C "$repo_root" archive --format=tar "$release_commit" \
    | tar -xf - -C "$build_source"; then
    return 1
  fi

  if ! (
    cd "$build_source/web" \
      && export BUN_TMPDIR=$build_work_tmp CI='' TMPDIR=$build_work_tmp \
      && bun install --frozen-lockfile --registry "$npm_registry" \
      && CI='' DISABLE_ESLINT_PLUGIN=true VITE_REACT_APP_VERSION=$service_version bun run build
  ); then
    return 1
  fi

  for arch in amd64 arm64; do
    output="$dist_dir/new-api/new-api-linux-$arch"
    if ! (
      cd "$build_source" \
        && CGO_ENABLED=0 GOFLAGS='' GOOS=linux GOARCH=$arch GOPROXY=$go_proxy \
          GOTOOLCHAIN=local GOWORK=off \
          SOURCE_DATE_EPOCH=$build_epoch TMPDIR=$build_work_tmp \
          go build -mod=readonly -trimpath -buildvcs=false -ldflags "$ldflags" -o "$output" .
    ); then
      return 1
    fi
    chmod 0755 "$output" || return
  done
  if ! install -m 0644 "$build_source/LICENSE" "$dist_dir/new-api/LICENSE" \
    || ! install -m 0644 "$build_source/NOTICE" "$dist_dir/new-api/NOTICE" \
    || ! write_manifest "$dist_dir" \
    || ! verify_local "$dist_dir"; then
    return 1
  fi
)

verify_cdn() {
  local file relative expected temporary attempt
  file=$1
  relative=$2
  expected=$(sha256_file "$file") || return
  temporary=$(project_temp_file) || return
  attempt=1
  while :; do
    if curl -fsSL \
      "$cdn_origin/$relative?seiya_verify=${expected:0:16}" -o "$temporary" \
      && test "$(file_size "$temporary")" = "$(file_size "$file")" \
      && test "$(sha256_file "$temporary")" = "$expected"; then
      break
    fi
    test "$attempt" -lt 5 || {
      rm -f -- "$temporary"
      echo "CDN 逐字节回读失败: $relative" >&2
      return 1
    }
    attempt=$((attempt + 1))
    sleep $((attempt * 2))
  done
  rm -f -- "$temporary"
  echo "CDN 逐字节回读通过: $relative"
}

publish_immutable() (
  local file relative fery expected cdn_file fery_file status put_failed
  file=$1
  relative=$2
  fery=$3
  expected=$(sha256_file "$file") || return
  cdn_file=$(project_temp_file) || return
  fery_file=$(project_temp_file) || {
    rm -f -- "$cdn_file"
    return 1
  }
  trap 'rm -f -- "$cdn_file" "$fery_file"' EXIT
  if ! status=$(curl -sS -L -o "$cdn_file" -w '%{http_code}' \
    "$cdn_origin/$relative?seiya_preflight=${expected:0:16}"); then
    echo "远端预检请求失败: $relative" >&2
    return 1
  fi
  case "$status" in
    200)
      if ! cmp -s "$file" "$cdn_file"; then
        echo "远端不可变对象与本地产物冲突: $relative" >&2
        return 1
      fi
      echo "远端不可变对象已存在且一致: $relative"
      ;;
    404)
      put_failed=false
      if ! "$fery" put "$file" "r2p:/$relative"; then
        put_failed=true
      fi
      ;;
    *)
      echo "远端预检失败: $relative HTTP $status" >&2
      return 1
      ;;
  esac
  if ! wait_for_dual_readback "$file" "$relative" "$fery" "$fery_file" "$cdn_file"; then
    if [ "${put_failed:-false}" = true ]; then
      echo "Fery put 非零且对象未按同字节收敛: $relative" >&2
    fi
    return 1
  fi
  echo "Fery get 与 CDN 双通道回读通过: $relative"
)

wait_for_dual_readback() {
  local file relative fery fery_file cdn_file attempt status fery_same cdn_same expected
  file=$1
  relative=$2
  fery=$3
  fery_file=$4
  cdn_file=$5
  expected=$(sha256_file "$file") || return
  attempt=1
  while [ "$attempt" -le 10 ]; do
    fery_same=false
    cdn_same=false
    if "$fery" get -f "r2p:/$relative" "$fery_file" >/dev/null 2>&1; then
      if ! cmp -s "$file" "$fery_file"; then
        echo "Fery get 回读字节冲突: $relative" >&2
        return 1
      fi
      fery_same=true
    fi
    if ! status=$(curl -sS -L -o "$cdn_file" -w '%{http_code}' \
      "$cdn_origin/$relative?seiya_dual_readback=${expected:0:16}-$attempt"); then
      status=000
    fi
    if [ "$status" = 200 ]; then
      if ! cmp -s "$file" "$cdn_file"; then
        echo "CDN 回读字节冲突: $relative" >&2
        return 1
      fi
      cdn_same=true
    fi
    if [ "$fery_same" = true ] && [ "$cdn_same" = true ]; then
      return 0
    fi
    if [ "$attempt" -lt 10 ]; then
      sleep 2
    fi
    attempt=$((attempt + 1))
  done
  echo "对象未在 10 轮内完成 Fery get 与 CDN 双通道收敛: $relative" >&2
  return 1
}

read_fery_record() {
  python3 - "$1" "$fery_version" "$fery_linux_amd64_size" "$fery_linux_amd64_sha256" <<'PY'
import json
import pathlib
import re
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if (
    document.get("schema_version") != 1
    or document.get("name") != "fery"
    or document.get("version") != sys.argv[2]
):
    raise SystemExit("Fery release manifest 名称或版本不匹配")
if not sys.argv[3].isdigit() or int(sys.argv[3]) <= 0:
    raise SystemExit("Fery linux-amd64 固定 size 尚未填充")
if not re.fullmatch(r"[0-9a-f]{64}", sys.argv[4]):
    raise SystemExit("Fery linux-amd64 固定 SHA256 尚未填充")
target = document.get("targets", {}).get("linux-amd64", {})
expected = {"filename", "size", "sha256"}
if set(target) != expected or target.get("filename") != "fery-linux-amd64":
    raise SystemExit("Fery release manifest 缺少 linux-amd64")
if type(target.get("size")) is not int or target["size"] <= 0:
    raise SystemExit("Fery linux-amd64 size 无效")
if not re.fullmatch(r"[0-9a-f]{64}", target.get("sha256", "")):
    raise SystemExit("Fery linux-amd64 SHA256 无效")
if target["size"] != int(sys.argv[3]) or target["sha256"] != sys.argv[4]:
    raise SystemExit("Fery release manifest 与 producer 固定 size/SHA256 不一致")
print(target["filename"], target["size"], target["sha256"])
PY
}

verify_fery_binary() {
  local binary manifest _filename size sha
  binary=$1
  test -x "$binary" || {
    echo "Fery CLI 不可执行: $binary" >&2
    return 1
  }
  manifest=$(project_temp_file) || return
  if ! curl -fsSL "$cdn_origin/seiya/tools/fery/$fery_version/release.json" -o "$manifest"; then
    rm -f -- "$manifest"
    return 1
  fi
  if ! read -r _filename size sha < <(read_fery_record "$manifest"); then
    rm -f -- "$manifest"
    return 1
  fi
  rm -f -- "$manifest"
  test "$(file_size "$binary")" = "$size" \
    && test "$(sha256_file "$binary")" = "$sha" || {
      echo "Fery CLI 与固定 release 不一致: $binary" >&2
      return 1
    }
  test "$("$binary" --version)" = "fery $fery_version" || {
    echo "Fery CLI 自报版本不匹配: $binary" >&2
    return 1
  }
}

install_fery() {
  local destination temporary filename size sha
  destination=$1
  temporary=$(project_temp_dir) || return
  if ! curl -fsSL "$cdn_origin/seiya/tools/fery/$fery_version/release.json" \
    -o "$temporary/release.json"; then
    rm -rf -- "$temporary"
    return 1
  fi
  if ! read -r filename size sha < <(read_fery_record "$temporary/release.json"); then
    rm -rf -- "$temporary"
    return 1
  fi
  if ! curl -fsSL "$cdn_origin/seiya/tools/fery/$fery_version/$filename" \
    -o "$temporary/fery"; then
    rm -rf -- "$temporary"
    return 1
  fi
  test "$(file_size "$temporary/fery")" = "$size" \
    && test "$(sha256_file "$temporary/fery")" = "$sha" || {
      rm -rf -- "$temporary"
      echo 'Fery 下载字节与固定 release 不一致' >&2
      return 1
    }
  if ! chmod 0755 "$temporary/fery"; then
    rm -rf -- "$temporary"
    return 1
  fi
  test "$("$temporary/fery" --version)" = "fery $fery_version" || {
    rm -rf -- "$temporary"
    echo 'Fery 下载文件自报版本不匹配' >&2
    return 1
  }
  if ! mkdir -p "$(dirname -- "$destination")" \
    || ! mv -- "$temporary/fery" "$destination"; then
    rm -rf -- "$temporary"
    return 1
  fi
  rm -rf -- "$temporary"
}

publish_release() (
  local dist_dir fery snapshot_root snapshot_dir name prefix
  dist_dir=$1
  fery=$2
  test -n "${FERY_SECRET_KEY:-}" || {
    echo 'FERY_SECRET_KEY 未设置' >&2
    return 1
  }
  # 先执行外部 CLI 的版本检查，再验原 dist，阻断 --version 篡改后进入快照。
  verify_fery_binary "$fery" || return
  verify_local "$dist_dir" || return
  snapshot_root=$(project_temp_dir) || return
  trap 'rm -rf -- "$snapshot_root"' EXIT
  snapshot_dir=$snapshot_root/release
  mkdir -m 0700 "$snapshot_dir" || return
  cp -R "$dist_dir/." "$snapshot_dir/" || return
  # 从这里起只读取重验后的完整私有快照。
  verify_local "$snapshot_dir" || return
  prefix="seiya/sources/new-api/$release_commit"
  for name in new-api-linux-amd64 new-api-linux-arm64 LICENSE NOTICE; do
    publish_immutable "$snapshot_dir/new-api/$name" "$prefix/$name" "$fery" || return
  done
  # manifest 是完成标记，必须在全部 payload 完成 CDN 回读之后发布。
  publish_immutable "$snapshot_dir/new-api/release.json" "$prefix/release.json" "$fery" || return
)

verify_remote() {
  local dist_dir name prefix
  dist_dir=$1
  verify_local "$dist_dir" || return
  prefix="seiya/sources/new-api/$release_commit"
  for name in new-api-linux-amd64 new-api-linux-arm64 LICENSE NOTICE release.json; do
    verify_cdn "$dist_dir/new-api/$name" "$prefix/$name" || return
  done
}

main() {
  case "${1:-}" in
    build)
      test "$#" -eq 2 || usage
      build_release "$2"
      ;;
    verify-local)
      test "$#" -eq 2 || usage
      verify_local "$2"
      ;;
    verify-identity)
      test "$#" -eq 1 || usage
      load_release_identity
      ;;
    install-fery)
      test "$#" -eq 2 || usage
      install_fery "$2"
      ;;
    publish)
      test "$#" -eq 3 || usage
      publish_release "$2" "$3"
      ;;
    verify-remote)
      test "$#" -eq 2 || usage
      verify_remote "$2"
      ;;
    *) usage ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
