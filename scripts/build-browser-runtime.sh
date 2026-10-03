#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
spec="$project_root/Packages/IntatisTools/Runtime/browser-runtime/release-spec.json"
architecture="${1:-}"
destination="${2:-}"
cache_root="${TRANSLATIS_RUNTIME_CACHE:-$project_root/.translatis/runtime-build/cache}"
work_root=""
final_destination=""
staging_destination=""

fail() {
    print -u2 -- "error: $*"
    exit 1
}

cleanup() {
    if [[ -n "${work_root:-}" && -d "$work_root" ]]; then
        /bin/rm -rf -- "$work_root"
    fi
    if [[ -n "${staging_destination:-}" \
        && -d "$staging_destination" && ! -L "$staging_destination" ]]; then
        /bin/rm -rf -- "$staging_destination"
    fi
}
trap cleanup EXIT

[[ "$architecture" == "arm64" || "$architecture" == "x86_64" ]] \
    || fail "usage: scripts/build-browser-runtime.sh <arm64|x86_64> <absolute-destination-root>"
[[ "$destination" == /* ]] || fail "destination must be an absolute path"
[[ ! -e "$destination" && ! -L "$destination" ]] \
    || fail "destination already exists: $destination"
final_destination="$destination"
staging_destination="$final_destination.building.$$"
[[ ! -e "$staging_destination" && ! -L "$staging_destination" ]] \
    || fail "staging destination already exists: $staging_destination"
destination="$staging_destination"
[[ -f "$spec" && ! -L "$spec" ]] || fail "browser runtime release spec is missing"

json_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null \
        || fail "missing JSON field $2 in ${1:t}"
}

download_artifact() {
    local key="$1"
    local filename="$2"
    local artifact="$cache_root/browser/$filename"
    local expected_sha="$(json_value "$spec" "source_artifacts.$key.sha256")"
    [[ "$expected_sha" =~ '^[0-9a-f]{64}$' ]] \
        || fail "release spec has no final SHA-256 for $key"
    if [[ ! -f "$artifact" ]]; then
        [[ -f "$artifact.partial" ]] || : > "$artifact.partial"
        while ! /usr/bin/curl --http1.1 -fL -C - \
            --connect-timeout 30 --max-time 600 \
            -o "$artifact.partial" "$(json_value "$spec" "source_artifacts.$key.url")"; do
            print -u2 -- "resuming fixed browser artifact $key"
        done
        /bin/mv "$artifact.partial" "$artifact"
    fi
    actual_sha="$(/usr/bin/shasum -a 256 "$artifact" | /usr/bin/awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] \
        || fail "browser artifact $key does not match the release spec"
    REPLY="$artifact"
}

/bin/mkdir -p "$cache_root/browser"
cache_root="$(cd "$cache_root" && pwd -P)"
if [[ "$architecture" == "arm64" ]]; then
    node_key="node_arm64"
    node_archive_name="node-v24.20.0-darwin-arm64.tar.gz"
    chromium_key="chromium_arm64"
    chromium_archive_name="playwright-chromium-1194-mac-arm64.zip"
else
    node_key="node_x86_64"
    node_archive_name="node-v24.20.0-darwin-x64.tar.gz"
    chromium_key="chromium_x86_64"
    chromium_archive_name="playwright-chromium-1194-mac-x64.zip"
fi
download_artifact "$node_key" "$node_archive_name"
node_archive="$REPLY"
download_artifact playwright playwright-1.56.1.tgz
playwright_archive="$REPLY"
download_artifact playwright_core playwright-core-1.56.1.tgz
playwright_core_archive="$REPLY"
download_artifact "$chromium_key" "$chromium_archive_name"
chromium_archive="$REPLY"
download_artifact chromium_license chromium-license.base64
chromium_license_base64="$REPLY"

    work_root="$(/usr/bin/mktemp -d /private/tmp/translatis-browser-runtime-build.XXXXXX)"
/bin/chmod 0700 "$work_root"
/bin/mkdir -p \
    "$work_root/node" \
    "$work_root/playwright" \
    "$work_root/playwright-core" \
    "$work_root/chromium"
/usr/bin/tar -xzf "$node_archive" --strip-components 1 -C "$work_root/node"
/usr/bin/tar -xzf "$playwright_archive" --strip-components 1 -C "$work_root/playwright"
/usr/bin/tar -xzf "$playwright_core_archive" --strip-components 1 -C "$work_root/playwright-core"
/usr/bin/ditto -x -k "$chromium_archive" "$work_root/chromium"
chromium_app="$(/usr/bin/find "$work_root/chromium" -type d -path '*/Chromium.app' -print -quit)"
[[ -n "$chromium_app" && -d "$chromium_app" ]] \
    || fail "Playwright Chromium archive does not contain Chromium.app"

/bin/mkdir -p \
    "$destination/bin" \
    "$destination/node_modules" \
    "$destination/chromium" \
    "$destination/ThirdPartyNotices/licenses"
/bin/cp -p "$work_root/node/bin/node" "$destination/bin/node"
/bin/chmod 0755 "$destination/bin/node"
/usr/bin/ditto "$work_root/playwright" "$destination/node_modules/playwright"
/usr/bin/ditto "$work_root/playwright-core" "$destination/node_modules/playwright-core"
/usr/bin/ditto "$chromium_app" "$destination/chromium/Chromium.app"
/bin/cp -p "$work_root/node/LICENSE" \
    "$destination/ThirdPartyNotices/licenses/Node-LICENSE.txt"
/bin/cp -p "$work_root/playwright/LICENSE" \
    "$destination/ThirdPartyNotices/licenses/Playwright-LICENSE.txt"
/usr/bin/base64 --decode \
    -i "$chromium_license_base64" \
    -o "$destination/ThirdPartyNotices/licenses/Chromium-LICENSE.txt"
actual_chromium_license_sha="$(
    /usr/bin/shasum -a 256 "$destination/ThirdPartyNotices/licenses/Chromium-LICENSE.txt" \
        | /usr/bin/awk '{print $1}'
)"
[[ "$actual_chromium_license_sha" == "$(json_value "$spec" source_artifacts.chromium_license.decoded_sha256)" ]] \
    || fail "decoded Chromium license does not match the release spec"

chromium_executable="$destination/chromium/Chromium.app/Contents/MacOS/Chromium"
[[ -x "$chromium_executable" ]] || fail "normalized Chromium executable is missing"
credits_profile="$work_root/credits-profile"
/bin/mkdir -p "$credits_profile/home" "$credits_profile/tmp"
/bin/chmod 0700 "$credits_profile/home" "$credits_profile/tmp"
credits_output="$destination/ThirdPartyNotices/licenses/Chromium-ThirdParty-Credits.html"
credits_program='const fs=require("fs"); const pw=require(process.argv[1]); (async()=>{const browser=await pw.chromium.launch({executablePath:process.argv[2],headless:true,args:["--disable-background-networking","--disable-breakpad","--disable-crash-reporter","--disable-component-update","--disable-sync","--no-first-run","--no-default-browser-check"]}); const page=await browser.newPage(); await page.goto("chrome://credits/",{waitUntil:"domcontentloaded"}); await page.waitForFunction(()=>document.title==="Credits"&&document.body.innerText.includes("Chromium software is made available as source code"),null,{timeout:30000}); const content=await page.content(); if(content.length<1000000)throw new Error("Chromium credits page is unexpectedly incomplete"); fs.writeFileSync(process.argv[3],content,{encoding:"utf8",mode:0o644}); await browser.close();})().catch(error=>{console.error(String(error));process.exit(1)})'
/usr/bin/env -i \
    HOME="$credits_profile/home" \
    TMPDIR="$credits_profile/tmp/" \
    PATH=/usr/bin:/bin \
    LANG=C LC_ALL=C \
    /usr/bin/arch -"$architecture" "$destination/bin/node" \
    -e "$credits_program" \
    "$destination/node_modules/playwright" \
    "$chromium_executable" \
    "$credits_output"
[[ -s "$credits_output" ]] \
    || fail "could not capture Chromium's exact built-in third-party credits"

{
    print -- "Node.js 24.20.0 — MIT; bundled dependency notices: licenses/Node-LICENSE.txt"
    print -- "Playwright 1.56.1 and Playwright Core 1.56.1 — Apache-2.0; licenses/Playwright-LICENSE.txt"
    print -- "Chromium 141.0.7390.37 revision 1194 — BSD-3-Clause; licenses/Chromium-LICENSE.txt"
    print -- "Chromium embedded third-party notices — licenses/Chromium-ThirdParty-Credits.html"
    print -- "Playwright optional fsevents dependency is not installed or distributed."
} > "$destination/ThirdPartyNotices/LICENSES.txt"

/usr/bin/jq -n \
    --arg architecture "$architecture" \
    --arg namespace "https://vitemis.com/spdx/translatis-browser-runtime/2026.08.27.1/$architecture" \
    '{
      spdxVersion: "SPDX-2.3",
      dataLicense: "CC0-1.0",
      SPDXID: "SPDXRef-DOCUMENT",
      name: ("Translatis Browser Runtime 2026.08.27.1 " + $architecture),
      documentNamespace: $namespace,
      creationInfo: {
        created: "2026-08-27T00:00:00Z",
        creators: ["Tool: Translatis build-browser-runtime.sh"]
      },
      packages: [
        {name:"Node.js",SPDXID:"SPDXRef-Node-js",versionInfo:"24.20.0",downloadLocation:"https://nodejs.org/dist/v24.20.0/",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"MIT",copyrightText:"NOASSERTION"},
        {name:"Playwright",SPDXID:"SPDXRef-Playwright",versionInfo:"1.56.1",downloadLocation:"https://registry.npmjs.org/playwright/-/playwright-1.56.1.tgz",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"Apache-2.0",copyrightText:"NOASSERTION"},
        {name:"Playwright-Core",SPDXID:"SPDXRef-Playwright-Core",versionInfo:"1.56.1",downloadLocation:"https://registry.npmjs.org/playwright-core/-/playwright-core-1.56.1.tgz",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"Apache-2.0",copyrightText:"NOASSERTION"},
        {name:"Chromium",SPDXID:"SPDXRef-Chromium",versionInfo:"141.0.7390.37",downloadLocation:"https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium/1194/",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"BSD-3-Clause AND LicenseRef-Chromium-ThirdParty-Credits",copyrightText:"NOASSERTION"}
      ],
      hasExtractedLicensingInfos: [{licenseId:"LicenseRef-Chromium-ThirdParty-Credits",name:"Chromium generated third-party credits",extractedText:"See ThirdPartyNotices/licenses/Chromium-ThirdParty-Credits.html in this runtime root."}]
    }' > "$destination/ThirdPartyNotices/runtime.spdx.json"

/usr/bin/jq \
    --arg architecture "$architecture" \
    '. + {architecture: $architecture}' \
    "$spec" > "$destination/runtime-manifest.json"
(
    cd "$destination"
    /usr/bin/find . -type f ! -path './SHA256SUMS.txt' \
        -exec /usr/bin/shasum -a 256 {} + \
        | LC_ALL=C /usr/bin/sort \
        > SHA256SUMS.txt
)

"$project_root/scripts/validate-browser-runtime.sh" \
    "$destination" "$architecture" "" static
/bin/mv "$destination" "$final_destination"
staging_destination=""
print -- "Built fixed browser runtime $architecture at $final_destination"
