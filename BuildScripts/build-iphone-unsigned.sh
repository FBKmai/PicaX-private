#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/iPhoneDuo"
PROJECT="$ROOT/PicaX.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
DERIVED_DATA="$BUILD/DerivedData"
PACKAGES="$ROOT/build/SourcePackages-iPhoneDuo"
APP="$DERIVED_DATA/Build/Products/Release-iphoneos/PicaX.app"
IPA="$BUILD/PicaX-iPhoneDuo-unsigned.ipa"

cd "$ROOT"
mkdir -p "$BUILD"
BACKUP="$(mktemp "$BUILD/project.pbxproj.XXXXXX")"
cp "$PBXPROJ" "$BACKUP"
restore_project() {
  cp "$BACKUP" "$PBXPROJ"
  rm -f "$BACKUP"
}
trap restore_project EXIT

python - "$PBXPROJ" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
entries = [
    '\t\t\t\t6D9FF26B2FEEB200008AA850 /* Embed Watch Content */,\n',
    '\t\t\t\t6D9FF26D2FEEB200008AA850 /* PBXTargetDependency */,\n',
]
for entry in entries:
    if text.count(entry) != 1:
        raise SystemExit("Watch dependency changed; refusing to modify the project.")
    text = text.replace(entry, "", 1)
path.write_text(text, encoding="utf-8")
PY

xcodebuild -resolvePackageDependencies \
  -project "$PROJECT" \
  -scheme PicaX \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  -onlyUsePackageVersionsFromResolvedFile \
  2>&1 | tee "$BUILD/resolve.log"

xcodebuild test \
  -project "$PROJECT" \
  -scheme PicaX \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone Duo,OS=27.1' \
  -parallel-testing-enabled NO \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  -disableAutomaticPackageResolution \
  -resultBundlePath "$BUILD/Tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$BUILD/tests.log"

xcodebuild build \
  -project "$PROJECT" \
  -scheme PicaX \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  -disableAutomaticPackageResolution \
  TARGETED_DEVICE_FAMILY="1,2" \
  REGISTER_APP_GROUPS=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  2>&1 | tee "$BUILD/build.log"

if [[ ! -d "$APP" || -d "$APP/Watch" ]]; then
  printf '%s\n' 'Expected an iPhone app without an embedded Watch app.' >&2
  exit 1
fi
for RESOURCE in ReleaseNotes.json ReleaseNotes.md PicaXBuildEnvironment.plist; do
  if [[ ! -s "$APP/$RESOURCE" ]]; then
    printf 'Missing build resource: %s\n' "$RESOURCE" >&2
    exit 1
  fi
  ditto "$APP/$RESOURCE" "$BUILD/$RESOURCE"
done

python - "$APP/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as file:
    info = plistlib.load(file)
version = tuple(int(part) for part in info.get("DTSDKName", "").removeprefix("iphoneos").split('.'))
if version < (27, 1):
    raise SystemExit("The built app must link against iOS SDK 27.1 or newer.")
if 1 not in info.get("UIDeviceFamily", []):
    raise SystemExit("The built app does not support iPhone.")
print("Verified iPhone app SDK:", info["DTSDKName"])
PY

# Optional model integration for the personal, noncommercial build. The
# workflow stages a hash-pinned validation artifact in this directory; ordinary
# builds and tests stay model-free. Compile outside the Xcode project so the
# app's iOS 15.2 deployment minimum is unchanged and the compiler's iOS 16
# requirement is recorded explicitly.
SUPER_RESOLUTION_BUNDLE_DIR="${SUPER_RESOLUTION_BUNDLE_DIR:-}"
if [[ -n "$SUPER_RESOLUTION_BUNDLE_DIR" ]]; then
  if [[ ! -d "$SUPER_RESOLUTION_BUNDLE_DIR" ]]; then
    printf 'Staged super-resolution bundle directory is missing: %s\n' \
      "$SUPER_RESOLUTION_BUNDLE_DIR" >&2
    exit 1
  fi
  BUNDLE_DESCRIPTOR=""
  for CANDIDATE in "$SUPER_RESOLUTION_BUNDLE_DIR"/*.superresolution.json; do
    [[ -e "$CANDIDATE" ]] || continue
    if [[ -n "$BUNDLE_DESCRIPTOR" ]]; then
      printf '%s\n' 'Expected exactly one staged super-resolution descriptor.' >&2
      exit 1
    fi
    BUNDLE_DESCRIPTOR="$CANDIDATE"
  done
  if [[ -z "$BUNDLE_DESCRIPTOR" ]]; then
    printf '%s\n' 'No staged super-resolution descriptor was found.' >&2
    exit 1
  fi
  MODEL_NAME="$(python -I - "$BUNDLE_DESCRIPTOR" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    model = json.load(source)
name = model.get("resourceName")
if not isinstance(name, str) or not name:
    raise SystemExit("Staged descriptor has no resourceName.")
print(name)
PY
)"
  MODEL_PACKAGE="$SUPER_RESOLUTION_BUNDLE_DIR/$MODEL_NAME.mlpackage"
  if [[ ! -d "$MODEL_PACKAGE" ]]; then
    printf 'Staged model package is missing: %s\n' "$MODEL_PACKAGE" >&2
    exit 1
  fi
  COMPILE_DIR="$BUILD/CoreMLCompiled"
  rm -rf "$COMPILE_DIR"
  mkdir -p "$COMPILE_DIR"
  xcrun coremlc compile "$MODEL_PACKAGE" "$COMPILE_DIR" \
    --deployment-target 16.0 --platform ios 2>&1 | tee "$BUILD/coremlc.log"
  COMPILED="$COMPILE_DIR/$MODEL_NAME.mlmodelc"
  if [[ ! -d "$COMPILED" ]]; then
    printf 'Expected compiled model was not produced: %s\n' "$COMPILED" >&2
    exit 1
  fi
  ditto "$COMPILED" "$APP/$MODEL_NAME.mlmodelc"
  ditto "$BUNDLE_DESCRIPTOR" "$APP/$(basename "$BUNDLE_DESCRIPTOR")"
  if [[ -f "$SUPER_RESOLUTION_BUNDLE_DIR/SuperResolutionAttribution.txt" ]]; then
    ditto "$SUPER_RESOLUTION_BUNDLE_DIR/SuperResolutionAttribution.txt" \
      "$APP/SuperResolutionAttribution.txt"
  fi
  printf 'Bundled validated model: %s\n' "$MODEL_NAME"
fi

# The engineering build may intentionally omit weights. Label that explicitly;
# never ship an unvalidated descriptor as an apparently working AI preset.
python -I "$ROOT/BuildScripts/verify-super-resolution-bundle.py" \
  "$APP" "$BUILD/SuperResolutionModels.json"
if [[ -f "$ROOT/Docs/SuperResolution.md" ]]; then
  ditto "$ROOT/Docs/SuperResolution.md" "$BUILD/SuperResolution.md"
fi

if [[ -e "$BUILD/Payload" || -e "$IPA" ]]; then
  printf '%s\n' 'Packaging output already exists; use a clean checkout for a new build.' >&2
  exit 1
fi
mkdir -p "$BUILD/Payload"
ditto "$APP" "$BUILD/Payload/PicaX.app"
cd "$BUILD"
zip -qry "$IPA" Payload
unzip -tq "$IPA"
shasum -a 256 "$(basename "$IPA")" > SHA256SUMS.txt
printf 'Unsigned IPA: %s\n' "$IPA"
