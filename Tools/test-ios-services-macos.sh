#!/usr/bin/env bash
# Runs only local file import, permission mapping, streaming budget and cancellation tests.
# No Photos library queries, authorization prompts, Simulator, or UI process are invoked.
set -euo pipefail

kaka_repository_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
kaka_services_workspace=$(mktemp -d "${TMPDIR:-/tmp}/kaka-services-tests.XXXXXX")
cleanup() { rm -rf -- "$kaka_services_workspace"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 - "$kaka_repository_root" "$kaka_services_workspace" <<'PY'
import json
from pathlib import Path
import sys

repository = Path(sys.argv[1])
workspace = Path(sys.argv[2])
sources = workspace / 'Sources' / 'Kaka'
tests = workspace / 'Tests' / 'KakaTests'
sources.mkdir(parents=True)
tests.mkdir(parents=True)
for name in ['CancellableContinuation.swift', 'ImageImporter.swift', 'PhotoLibraryService.swift', 'ExportShareItem.swift']:
    (sources / name).symlink_to(repository / 'Kaka' / 'Services' / name)
for name in ['CancellableContinuationTests.swift', 'ImageImporterTests.swift']:
    (tests / name).symlink_to(repository / 'KakaTests' / name)
dependency = json.dumps(str(repository / 'StitchCore'), ensure_ascii=False)
manifest = f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "KakaServiceTests",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: {dependency})],
    targets: [
        .target(name: "Kaka", dependencies: [
            .product(name: "StitchCore", package: "StitchCore"),
            .product(name: "StitchWorkflow", package: "StitchCore")
        ], swiftSettings: [
            .defaultIsolation(MainActor.self),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ]),
        .testTarget(name: "KakaTests", dependencies: ["Kaka"])
    ],
    swiftLanguageModes: [.v6]
)
'''
(workspace / 'Package.swift').write_text(manifest, encoding='utf-8')
PY

swift test --package-path "$kaka_services_workspace"
