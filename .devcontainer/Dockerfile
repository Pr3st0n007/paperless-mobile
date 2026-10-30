FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TARGETARCH
ARG ANDROID_COMMAND_LINE_TOOLS_VERSION=13114758

ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JAVA_HOME=/opt/java \
    PUB_CACHE=/home/vscode/.pub-cache \
    GRADLE_USER_HOME=/home/vscode/.gradle \
    SIGNING_HOME=/home/vscode/.android-signing

ENV PATH="/opt/java/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:${PATH}"

RUN [[ "$TARGETARCH" == "amd64" ]] \
    && apt-get update \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates clang cmake curl gh git gnupg \
        libglu1-mesa libgtk-3-dev liblzma-dev libsecret-1-dev \
        ninja-build openjdk-17-jdk-headless pinentry-curses pkg-config \
        ruby-dev ruby-full shellcheck unzip xz-utils zip \
    && ln -s "$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")" /opt/java \
    && gem install bundler -v 2.5.3 --no-document \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p "$ANDROID_HOME/cmdline-tools" \
    && curl --fail --location --retry 3 \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_COMMAND_LINE_TOOLS_VERSION}_latest.zip" \
        --output /tmp/android-command-line-tools.zip \
    && unzip -q /tmp/android-command-line-tools.zip -d "$ANDROID_HOME/cmdline-tools" \
    && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
    && rm /tmp/android-command-line-tools.zip \
    && printf 'y\n%.0s' {1..100} | sdkmanager --licenses > /dev/null

RUN sdkmanager \
        "platform-tools" "platforms;android-36" \
        "build-tools;35.0.0" "build-tools;36.0.0" \
        "ndk;27.0.12077973" "cmake;3.22.1" \
    && mkdir -p "$PUB_CACHE" "$GRADLE_USER_HOME" "$SIGNING_HOME" \
    && chown -R vscode:vscode "$ANDROID_HOME" "$PUB_CACHE" "$GRADLE_USER_HOME" "$SIGNING_HOME" \
    && chmod 700 "$SIGNING_HOME"

USER vscode