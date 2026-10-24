#!/bin/sh
# Removes the resources FluidAudio bundles for its LuxTTS voice from the
# built app: a pronunciation lexicon derived from espeak-ng (GPL), and its
# helper file. Strobe reads aloud with Kokoro, whose English frontend never
# reads them. Runs as the Strobe target's last build phase, before Xcode
# signs the app; AcknowledgementsTests checks the app comes out without them.
set -eu

bundle="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/FluidAudio_FluidAudio.bundle"
if [ ! -d "$bundle" ]; then
    echo "error: FluidAudio's resource bundle isn't at $bundle. Update Scripts/strip-unused-fluidaudio-resources.sh for this FluidAudio." >&2
    exit 1
fi

removed=$(find "$bundle" -name 'luxtts_*' -print -exec rm -f {} +)
[ -n "$removed" ] || exit 0
echo "Removed from FluidAudio_FluidAudio.bundle:"
echo "$removed"

# Xcode may have signed the bundle when it built the package, and removing
# files breaks that seal: sign it again, or, in an unsigned build, leave it
# unsigned like the rest of the app.
for signature in "$bundle/_CodeSignature" "$bundle/Contents/_CodeSignature"; do
    [ -d "$signature" ] || continue
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$bundle"
    else
        rm -rf "$signature"
    fi
done
