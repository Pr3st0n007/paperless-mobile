#!/usr/bin/env bash
set -Eeuo pipefail

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$script_directory/.."

git submodule update --init --recursive flutter
export FLUTTER_ROOT="$PWD/flutter/bin"
export PATH="$FLUTTER_ROOT:$PATH"

flutter config --no-analytics --android-sdk "$ANDROID_HOME"
dart --disable-analytics
flutter precache --android --linux --web
bash scripts/install_dependencies.sh

bundle config set --global path "$HOME/.local/share/paperless-mobile/bundle"
BUNDLE_GEMFILE="$PWD/android/Gemfile" bundle install

mkdir -p "$SIGNING_HOME"
chmod 700 "$SIGNING_HOME"
flutter doctor -v