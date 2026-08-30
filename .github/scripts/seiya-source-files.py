#!/usr/bin/env python3
"""枚举 new-api Linux 双架构发布实际使用的 tracked 源文件。"""

import argparse
import hashlib
import json
import os
import pathlib
import stat
import subprocess
import tarfile
import tempfile


EXPECTED_GO_VERSION = "go1.25.1"
SOURCE_FIELDS = (
    "GoFiles",
    "CgoFiles",
    "CFiles",
    "CXXFiles",
    "MFiles",
    "HFiles",
    "FFiles",
    "SFiles",
    "SwigFiles",
    "SwigCXXFiles",
    "SysoFiles",
    "EmbedFiles",
)
GO_SOURCE_SUFFIXES = {
    ".go",
    ".c",
    ".cc",
    ".cpp",
    ".cxx",
    ".m",
    ".h",
    ".hh",
    ".hpp",
    ".f",
    ".for",
    ".f90",
    ".s",
    ".S",
    ".syso",
    ".swig",
    ".swigcxx",
}
EXPLICIT_FILES = {
    ".github/scripts/seiya-release.sh",
    ".github/scripts/seiya-source-files.py",
    ".github/scripts/test-seiya-release.sh",
    ".github/workflows/seiya-release.yml",
    ".gitignore",
    "go.mod",
    "go.sum",
    "relaykit/go.mod",
    "relaykit/go.sum",
    "web/.gitignore",
}
GENERATED_PREFIXES = ("dist/", "web/dist/", "web/node_modules/")


def git(repo: pathlib.Path, *arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(repo), *arguments])


def current_go_version() -> str:
    environment = os.environ.copy()
    environment["GOTOOLCHAIN"] = "local"
    return subprocess.check_output(
        ["go", "env", "GOVERSION"], env=environment, text=True
    ).strip()


def decode_json_stream(output: str) -> list[dict]:
    decoder = json.JSONDecoder()
    position = 0
    values = []
    while position < len(output):
        while position < len(output) and output[position].isspace():
            position += 1
        if position == len(output):
            break
        value, position = decoder.raw_decode(output, position)
        if not isinstance(value, dict):
            raise SystemExit("go list 返回了非 object 值")
        values.append(value)
    return values


def is_frontend_input(relative: str) -> bool:
    # Tailwind v4 会扫描整个前端项目树；测试、配置和维护脚本也可能改变候选类集合。
    return relative.startswith("web/")


def selected_go_files(root: pathlib.Path, goarch: str) -> tuple[set[str], set[str]]:
    generated = root / "web/dist"
    generated.mkdir(parents=True, exist_ok=True)
    (generated / "index.html").write_bytes(b"seiya source provenance\n")
    environment = os.environ.copy()
    environment.update(
        {
            "CGO_ENABLED": "0",
            "GOARCH": goarch,
            "GOFLAGS": "",
            "GOOS": "linux",
            "GOPROXY": "https://goproxy.cn,direct",
            "GOTOOLCHAIN": "local",
            "GOWORK": "off",
        }
    )
    output = subprocess.check_output(
        ["go", "list", "-mod=readonly", "-deps", "-json", "."],
        cwd=root,
        env=environment,
        text=True,
    )
    selected = set()
    package_directories = set()
    for package in decode_json_stream(output):
        directory = pathlib.Path(package.get("Dir", ""))
        try:
            package_directory = directory.relative_to(root).as_posix()
        except ValueError:
            continue
        package_directories.add(package_directory)
        for field in SOURCE_FIELDS:
            for filename in package.get(field, []):
                path = directory / filename
                try:
                    selected.add(path.relative_to(root).as_posix())
                except ValueError:
                    continue
    return selected, package_directories


def status_paths(repo: pathlib.Path) -> list[str]:
    output = git(
        repo,
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--ignored=matching",
    )
    paths = []
    for record in output.split(b"\0"):
        if len(record) < 4 or record[:3] not in {b"?? ", b"!! "}:
            continue
        paths.append(os.fsdecode(record[3:]))
    return paths


def is_generated(relative: str) -> bool:
    return relative.startswith(GENERATED_PREFIXES)


def is_untracked_build_input(relative: str, package_directories: set[str]) -> bool:
    if is_generated(relative):
        return False
    if (
        relative in EXPLICIT_FILES
        or relative.startswith(("web/src/", "web/public/"))
        or is_frontend_input(relative)
    ):
        return True
    path = pathlib.PurePosixPath(relative.rstrip("/"))
    parent = path.parent.as_posix()
    if path.suffix in GO_SOURCE_SUFFIXES and parent in package_directories:
        return True
    return (
        relative.startswith("i18n/locales/") and path.suffix == ".yaml"
    ) or relative == "common/limiter/lua/rate_limit.lua"


def reject_untracked_build_inputs(repo: pathlib.Path, package_directories: set[str]) -> None:
    unexpected = sorted(
        relative
        for relative in status_paths(repo)
        if is_untracked_build_input(relative, package_directories)
    )
    if unexpected:
        raise SystemExit("构建树含未跟踪输入: " + ", ".join(unexpected))


def enumerate_source_files(repo: pathlib.Path, commit: str) -> dict[str, dict]:
    tracked = {
        os.fsdecode(value)
        for value in git(repo, "ls-tree", "-rz", "--name-only", commit).split(b"\0")
        if value
    }
    missing = EXPLICIT_FILES - tracked
    if missing:
        raise SystemExit(f"release 输入不在 commit 中: {sorted(missing)}")

    git_dir = repo / ".git"
    with tempfile.TemporaryDirectory(prefix="seiya-source-files-", dir=git_dir) as temporary:
        root = pathlib.Path(temporary).resolve()
        archive = root / "source.tar"
        with archive.open("wb") as output:
            subprocess.run(
                ["git", "-C", str(repo), "archive", "--format=tar", commit],
                check=True,
                stdout=output,
            )
        with tarfile.open(archive) as source:
            source.extractall(root)
        archive.unlink()

        selected = set(EXPLICIT_FILES)
        selected.update(path for path in tracked if is_frontend_input(path))
        package_directories = set()
        for goarch in ("amd64", "arm64"):
            go_files, directories = selected_go_files(root, goarch)
            selected.update(go_files)
            package_directories.update(directories)
        selected &= tracked
        reject_untracked_build_inputs(repo, package_directories)

        records = {}
        for relative in sorted(selected):
            path = root / relative
            metadata = path.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                raise SystemExit(f"构建源码不是普通文件: {relative}")
            data = path.read_bytes()
            records[relative] = {
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
    return records


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=pathlib.Path, required=True)
    parser.add_argument("--commit", required=True)
    arguments = parser.parse_args()
    repo = arguments.repo.resolve()
    commit = git(repo, "rev-parse", f"{arguments.commit}^{{commit}}").decode().strip()
    if commit != arguments.commit:
        raise SystemExit("source commit 必须是完整 commit ID")
    go_version = current_go_version()
    if go_version != EXPECTED_GO_VERSION:
        raise SystemExit(f"source 枚举必须使用 {EXPECTED_GO_VERSION}，当前为 {go_version}")
    print(json.dumps(enumerate_source_files(repo, commit), separators=(",", ":")))


if __name__ == "__main__":
    main()
