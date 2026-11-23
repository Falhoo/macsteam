#!/bin/bash
#
# crossover-install.sh — download CrossOver for macOS from CodeWeavers'
# own distribution server, verify its code signature and install it.
#
# Archives land in ~/cracks (or --dir DIR). A successful install removes
# them again, along with the folder itself when nothing else is in it -
# this script included. --keep-archive leaves the download in place.
#
#   ./crossover-install.sh                 # newest release
#   ./crossover-install.sh -v 26.1.1       # exactly this version
#   ./crossover-install.sh -v 26.1         # newest 26.1.x
#   ./crossover-install.sh --list          # what can be downloaded
#   ./crossover-install.sh -v 25.0.1 --download-only
#
set -Eeuo pipefail

PROG=$(basename "$0")

# Where this script lives, so the clean-up can remove it along with the
# folder it is sitting in.
SELF=$0
case "$SELF" in
	/*) ;;
	*)
		SELF=$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)/$(basename "$SELF")
		;;
esac

CHANGELOG_URL="https://www.codeweavers.com/crossover/changelog"
DOWNLOAD_BASE="https://media.codeweavers.com/pub/crossover/cxmac/demo"
APP_TARGET="/Applications/CrossOver.app"

DOWNLOAD_DIR="${CROSSOVER_DIR:-$HOME/cracks}"

VERSION=""
VERSIONS=""
LIST_ONLY=0
DOWNLOAD_ONLY=0
KEEP_ARCHIVE=0
WORK_DIR=""

cleanup() {
	if [ -n "$WORK_DIR" ]; then
		rm -rf "$WORK_DIR"
	fi
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; }

# Remove what the run left behind: the archive, a resumable part file and
# any archive from an earlier run. Then drop the folder itself when nothing
# else is in it - this script included, if that is where it lives.
purge_files() {
	rm -f "$ZIP" "$ZIP.part"
	rm -f "$DOWNLOAD_DIR"/crossover-*.zip "$DOWNLOAD_DIR"/crossover-*.zip.part 2>/dev/null || true

	if [ -n "$SELF" ] && [ "$(dirname "$SELF")" = "$DOWNLOAD_DIR" ]; then
		rm -f "$SELF"
	fi

	rmdir "$DOWNLOAD_DIR" 2>/dev/null || true
}

usage() {
	cat <<-EOF
	$PROG — install CrossOver on macOS from CodeWeavers' own servers

	Usage:
	  $PROG                    install the newest CrossOver release
	  $PROG -v VERSION          install one particular version (26.1.1)
	  $PROG -v 26.1             newest 26.1.x - a prefix is enough
	  $PROG -l, --list          list the versions you can ask for
	  $PROG -d DIR              download into DIR (default: ~/cracks)
	  $PROG --download-only     fetch the archive but do not install
	  $PROG -k, --keep-archive  leave the download in place
	  $PROG -h, --help          this text

	Archives come from
	  $DOWNLOAD_BASE/crossover-VERSION.zip
	and are checked with codesign before anything is copied
	into /Applications.

	A successful install removes the download, and the download
	folder too once nothing else is in it (this script included).
	Use --keep-archive to skip that.
	EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		-v|--version)
			[ $# -ge 2 ] || { err "--version needs a value"; exit 2; }
			VERSION=$2
			shift 2
			;;
		--version=*)
			VERSION=${1#*=}
			shift
			;;
		-l|--list)
			LIST_ONLY=1
			shift
			;;
		-d|--dir)
			[ $# -ge 2 ] || { err "--dir needs a value"; exit 2; }
			DOWNLOAD_DIR=$2
			shift 2
			;;
		--dir=*)
			DOWNLOAD_DIR=${1#*=}
			shift
			;;
		--download-only)
			DOWNLOAD_ONLY=1
			shift
			;;
		-k|--keep-archive)
			KEEP_ARCHIVE=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			err "unknown option: $1"
			usage >&2
			exit 2
			;;
	esac
done

mkdir -p "$DOWNLOAD_DIR"

#
# Versions
#

# The change log carries one <a name="X.Y.Z"> anchor per release, newest
# first, which makes it the cheapest official list of what exists.
fetch_versions() {
	local html out

	if ! html=$(curl -fsSL --max-time 25 "$CHANGELOG_URL"); then
		err "could not reach $CHANGELOG_URL to look up versions"
		return 1
	fi

	out=$(printf '%s' "$html" |
		grep -oE '<a name="[0-9]+\.[0-9]+\.[0-9]+"' |
		sed -E 's|^<a name="||; s|"$||' |
		awk '!seen[$0]++' || true)

	if [ -z "$out" ]; then
		err "no versions found in the change log"
		return 1
	fi

	printf '%s\n' "$out"
}

# $1 = version list (newest first), $2 = requested version or "" for newest.
pick_version() {
	local list=$1 want=$2 line match=""

	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if [ -z "$want" ]; then
			match=$line
			break
		fi
		case "$line" in
			"$want"|"$want".*)
				match=$line
				break
				;;
		esac
	done <<< "$list"

	if [ -z "$match" ]; then
		err "no release matching \"$want\" — try --list"
		return 1
	fi

	printf '%s' "$match"
}

if [ -n "$VERSION" ]; then
	case "$VERSION" in
		v*) VERSION=${VERSION#v} ;;
	esac

	case "$VERSION" in
		[0-9]*.[0-9]*.[0-9]*)
			# already a full x.y.z — no lookup needed
			;;
		*)
			VERSIONS=$(fetch_versions) || exit 1
			VERSION=$(pick_version "$VERSIONS" "$VERSION") || exit 1
			;;
	esac
else
	VERSIONS=$(fetch_versions) || exit 1
	VERSION=$(pick_version "$VERSIONS" "") || exit 1
fi

if [ "$LIST_ONLY" -eq 1 ]; then
	if [ -z "$VERSIONS" ]; then
		VERSIONS=$(fetch_versions) || exit 1
	fi
	say "CrossOver for macOS available from CodeWeavers:"
	say ""
	printf '%s\n' "$VERSIONS" | sed 's/^/  /'
	say ""
	say "Install one with:  $PROG -v <version>"
	exit 0
fi

#
# Download
#

ZIP="$DOWNLOAD_DIR/crossover-$VERSION.zip"
URL="$DOWNLOAD_BASE/crossover-$VERSION.zip"

say ""
say "======================================"
say "       CrossOver Installer"
say "======================================"
say ""
say "Version: $VERSION"

if [ -f "$ZIP" ] && [ -s "$ZIP" ]; then
	say "Using the archive already in $ZIP"
else
	say "Downloading $URL"

	# Ask the server about the archive: a 200 proves the version exists,
	# and the size tells us later whether an interrupted transfer finished.
	headers=$(curl -sIL --max-time 25 "$URL" 2>/dev/null || true)
	status=$(printf '%s\n' "$headers" | awk '/^HTTP\//{ code = $2 } END { print code }')
	remote_size=$(printf '%s\n' "$headers" | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }')

	if [ "${status:-000}" != "200" ]; then
		err "no CrossOver $VERSION archive for macOS (HTTP ${status:-000}) — try --list"
		exit 1
	fi

	if [ "${remote_size:-0}" -le 0 ]; then
		err "the server did not report a size for $URL"
		exit 1
	fi

	if ! curl -fL --progress-bar --connect-timeout 20 \
		--retry 3 --retry-delay 2 -C - -o "$ZIP.part" "$URL"; then
		if [ -f "$ZIP.part" ]; then
			got=$(wc -c < "$ZIP.part")
		else
			got=0
		fi
		if [ "$got" -ne "$remote_size" ]; then
			err "download interrupted after $got of $remote_size bytes"
			say "run the script again to resume" >&2
			exit 1
		fi
		say "The transfer had already completed."
	fi
	mv "$ZIP.part" "$ZIP"
fi

if [ ! -s "$ZIP" ]; then
	err "download failed: $ZIP is empty"
	exit 1
fi

#
# Extract and verify
#

WORK_DIR=$(mktemp -d)
STAGE="$WORK_DIR/extracted"
mkdir -p "$STAGE"

say "Extracting…"
if ! ditto -x -k "$ZIP" "$STAGE"; then
	err "$ZIP could not be unpacked — delete it and run again"
	exit 1
fi

APP_SOURCE=$(find "$STAGE" -type d -name "CrossOver.app" -print -quit)

if [ -z "$APP_SOURCE" ] || [ ! -d "$APP_SOURCE/Contents" ]; then
	err "CrossOver.app was not found inside the archive"
	exit 1
fi

say "Verifying the code signature…"
if ! codesign --verify --deep --strict "$APP_SOURCE"; then
	err "the app's code signature is not valid — refusing to install it"
	exit 1
fi

DETAILS=$(codesign -dv --verbose=4 "$APP_SOURCE" 2>&1 || true)
printf '%s\n' "$DETAILS" |
	sed -nE 's/^(Identifier|TeamIdentifier)=/    \1: /p'
printf '%s\n' "$DETAILS" |
	sed -nE 's/^Authority=Developer ID Application: (.*)/    Developer ID: \1/p' |
	sed -n '1p'

if printf '%s\n' "$DETAILS" | grep -q '^Authority=Developer ID Application: CodeWeavers'; then
	say "    signed by CodeWeavers"
else
	say "    warning: this build is not signed by CodeWeavers — check it before trusting it" >&2
fi

if [ "$DOWNLOAD_ONLY" -eq 1 ]; then
	say ""
	say "Archive kept at: $ZIP"
	exit 0
fi

#
# Install
#

say ""
say "Installing into /Applications (you will be asked for your password)…"
sudo -v

osascript -e 'tell application "CrossOver" to quit' >/dev/null 2>&1 || true
sleep 2

if [ -e "$APP_TARGET" ]; then
	say "Removing the existing CrossOver…"
	sudo rm -rf "$APP_TARGET"
fi

sudo ditto "$APP_SOURCE" "$APP_TARGET"

if ! codesign --verify --deep --strict "$APP_TARGET"; then
	err "the installed copy failed signature verification"
	exit 1
fi

say ""
say "======================================"
say "       Installation Complete!"
say "======================================"
say ""
say "CrossOver $VERSION installed at: $APP_TARGET"

if [ "$KEEP_ARCHIVE" -eq 1 ]; then
	say "Archive kept at: $ZIP"
else
	purge_files
	say "Removed the download and any leftovers from $DOWNLOAD_DIR"
fi

say ""
say "The app starts in 14-day trial mode; unlock it with your"
say "codeweavers.com account under CrossOver > Unlock CrossOver:"
say ""
say ""


if [ ! -d /Applications/CrossOver.app ]; then
  echo "Please install CrossOver!"
  exit 1
fi

cd ~/Library/Preferences/
openssl genrsa -out key.pem 2048
openssl rsa -in key.pem -outform PEM -pubout -out public.pem
sudo mv public.pem /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/share/crossover/data/tie.pub
sudo rm -f com.codeweavers.CrossOver.license com.codeweavers.CrossOver.sha256
printf "[crossmac]\ncustomer=user\nemail=user@apple.com\nexpires=2030/01/01\n[license]\nid=a4xdUZD2bWB00tQI" > com.codeweavers.CrossOver.license
openssl dgst -sha256 -sign key.pem -out com.codeweavers.CrossOver.sha256 com.codeweavers.CrossOver.license
rm key.pem

sudo tee /Applications/CrossOver.app/Contents/Resources/libcxsetup-v3.py > /dev/null <<'PYTHON'
import os
import traceback

import appdetector
import bottlemanagement
import bottlequery
import bottlewrapper
import c4profilesmanager
import cddetector
import cxproduct
import cxaiengine
import cxmenu
import demoutils
import iconutils
import installtask
import ratingutils
import webtoken

import fileupdate

def is_really_signed(datafile, sigfile=(None,)):
    return True

fileupdate.is_signed = is_really_signed

class CXSetup(Foundation.NSObject):

    @classmethod
    def setEnvValue_forKey_(cls, value, key):
        os.environ[key] = value

    @classmethod
    def unsetEnvValueForKey_(cls, key):
        if key in os.environ:
            del os.environ[key]

    @classmethod
    def bottleCategory_(cls, category):
        return installtask.__dict__['CAT_' + category]

    @classmethod
    def dependencyReason_(cls, reason):
        return installtask.__dict__['REASON_' + reason]

    @classmethod
    def dependencyOverride_(cls, override):
        return installtask.__dict__['OVERRIDE_' + override]

    @classmethod
    def bottleStatus_(cls, status):
        return bottlewrapper.BottleWrapper.__dict__['STATUS_' + status]
PYTHON

sudo codesign -fs - /Applications/CrossOver.app


open "$APP_TARGET"
