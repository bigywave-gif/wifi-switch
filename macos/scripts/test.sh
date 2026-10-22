#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .build/module-cache .build/clang-cache
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
# Command Line Tools ships Swift Testing outside the default module search path.
TEST_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
swift test --disable-xctest --enable-swift-testing --disable-sandbox --cache-path "$PROJECT_ROOT/.build/cache" \
    --config-path "$PROJECT_ROOT/.build/config" --security-path "$PROJECT_ROOT/.build/security" \
    -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" \
    -Xlinker -F -Xlinker "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib"
