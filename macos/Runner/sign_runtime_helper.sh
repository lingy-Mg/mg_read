#!/bin/sh
# Re-signs both JavaScript runtimes after Flutter has copied their assets into
# the App bundle. The helper is executable from the macOS bundle, while the
# enclosing App.framework is re-signed after its sealed assets change.

set -eu

app_framework_path="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/App.framework"
signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
if [ ! -d "$app_framework_path" ]; then
  echo "error: Packaged App.framework is missing" >&2
  exit 1
fi
if [ "$signing_identity" = "-" ]; then
  timestamp_option="--timestamp=none"
else
  timestamp_option="--timestamp"
fi
for helper in MgReadNode MgReadBun; do
  asset_helper_path="$app_framework_path/Resources/flutter_assets/packages/mgread_plugin_runtime/assets/runtime/macos-arm64/node/$helper"
  helper_path="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/$helper"
  if [ -f "$asset_helper_path" ]; then
    /bin/mkdir -p "${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
    /bin/mv -f "$asset_helper_path" "$helper_path"
  elif [ ! -f "$helper_path" ]; then
    echo "error: Packaged $helper is missing" >&2
    exit 1
  fi
  /bin/chmod +x "$helper_path"
  /usr/bin/codesign --force --sign "$signing_identity" \
    --identifier "$PRODUCT_BUNDLE_IDENTIFIER.$helper" \
    --options runtime --entitlements "${PROJECT_DIR}/Runner/RuntimeHelper.entitlements" \
    "$timestamp_option" "$helper_path"
  /usr/bin/codesign --verify --strict "$helper_path"
done

# Moving the helper removes it from App.framework's sealed Flutter assets.
# Re-sign the enclosing framework; the Runner target subsequently signs the
# complete .app bundle as its normal final build step.
/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
  "$timestamp_option" \
  "$app_framework_path"
