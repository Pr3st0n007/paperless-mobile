<!-- CONTRIBUTING -->

# Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.
All bug reports or feature requests are welcome, even if you can't contribute code!

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".
Don't forget to give the project a star! Thanks again!

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'feat: Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

<!-- GETTING STARTED -->

## Getting Started

To get a local copy up and running follow these simple steps.

## Prerequisites

- Install an IDE of your choice (e.g. VSCode with the Dart/Flutter extensions)
- Install the flutter SDK (https://docs.flutter.dev/get-started/install) _or_ use the flutter git submodule pinned in this project by running `git submodule update --init` inside the project root directory.

## Develop in a Container

Install Docker (Docker Desktop with WSL integration on Windows) and the VS Code
**Dev Containers** extension. Open this repository and run **Dev Containers:
Reopen in Container** from the Command Palette.

The Linux x86-64 container includes Java 17 and `keytool`, GPG, GitHub CLI, Ruby,
Bundler, Android SDK API 36, NDK 27, and Linux desktop build dependencies. Its
first setup initializes the pinned Flutter submodule, downloads Flutter
artifacts, installs Dart and Fastlane dependencies, and runs code generation.
Android SDK licenses are accepted during the image build. Allow several GB of
free disk space and time for the initial downloads.

Use the integrated container terminal for development:

```sh
flutter doctor -v
flutter analyze
flutter test
flutter build apk --debug
```

Dart and Gradle caches persist in Docker volumes. Signing files belong in
`$SIGNING_HOME`, a separate private volume outside the repository which survives
container rebuilds. Back it up securely: deleting the volume deletes those keys.
Passwords are not generated or stored automatically.

For a new signing key, run the following in the container terminal and enter
passwords directly into the prompts:

```sh
umask 077
keytool -genkeypair -v -storetype JKS \
   -keystore "$SIGNING_HOME/paperless-release.jks" \
   -alias paperless-mobile -keyalg RSA -keysize 2048 -validity 10000

gpg --pinentry-mode loopback --armor --symmetric --cipher-algo AES256 \
   --output "$SIGNING_HOME/paperless-release.jks.asc" \
   "$SIGNING_HOME/paperless-release.jks"
```

Use `paperless-mobile` for `KEYSTORE_KEY_ALIAS`, the key and keystore passwords
for their corresponding secrets, and the GPG passphrase for
`RELEASE_KEYSTORE_PASSPHRASE`. Set `RELEASE_KEYSTORE` to the complete contents of
the encrypted file. See [GitHub Actions signing](#configure-github-actions-signing)
below. Do not generate a replacement key for an app that already has a signing
key, and do not put passwords in shell commands or commit them.

An Android emulator and USB forwarding are not included. Connect a device with
Android wireless debugging using `adb pair` and `adb connect`, or use an emulator
on the host with an explicitly configured ADB connection. iOS builds and signing
still require macOS and Xcode.

## Install dependencies and generate files

1. First, clone the repository:

```sh
git clone https://github.com/pr3st0n007/paperless-mobile.git
```

You can now run the `scripts/install_dependencies.sh` script at the root of the project, which will automatically install dependencies and generate files for both the app and local packages.

If you want to manually install dependencies and build generated files, you can also run the following commands:

### Inside the `packages/paperless_api/` folder:

2. Install the dependencies for `paperless_api`
   ```sh
   dart pub get
   ```
3. Build generated files for `paperless_api`
   ```sh
    dart pub run build_runner build --delete-conflicting-outputs
   ```

### Inside the project's root folder

4. Install the dependencies for the app
   ```sh
   dart pub get
   ```
5. Build generated files for the app
   ```sh
   dart pub run build_runner build --delete-conflicting-outputs
   ```
6. Generate the localization files for the app
   ```sh
   flutter gen-l10n
   ```

## Build release version

In order to build a release version, you have to...

1. Exchange the signing configuration in android/app/build.gradle from

```gradle
buildTypes {
    release {
        signingConfig signingConfigs.release
    }
}
```

to

```gradle
buildTypes {
    release {
        signingConfig signingConfigs.debug
    }
}
```

or use your own signing configuration as described in https://docs.flutter.dev/deployment/android#signing-the-app and leave the `build.gradle` as is.

2. Build the app with release profile (here for android):

```sh
flutter build apk
```

The --release flag is implicit for the build command. You can also run this command with --split-per-abi, which will generate three separate (smaller) binaries.

3. Install the app to your device (when omitting the `--split-per-abi` flag)

```sh
flutter install
```

or when you built with `--split-per-abi`

```sh
flutter install --use-application-binary=build/pp/outputs/flutter-apk/<apk_file_name>.apk
```

## Configure GitHub Actions signing

The Android workflows use Ubuntu 24.04, Temurin Java 17, and the pinned Flutter
submodule. All four build and release workflows require signing credentials.
Forks do not inherit repository secrets from the upstream repository.

In your repository, open **Settings > Secrets and variables > Actions** and add
the following repository secrets:

| Secret | Value |
| --- | --- |
| `KEYSTORE_KEY_ALIAS` | Alias of the signing key inside your keystore. |
| `KEYSTORE_KEY_PASSWORD` | Password of that signing key. |
| `KEYSTORE_STORE_PASSWORD` | Password of the keystore. |
| `RELEASE_KEYSTORE_PASSPHRASE` | Passphrase used to GPG-encrypt the keystore. This is separate from the keystore passwords. |
| `RELEASE_KEYSTORE` | Complete ASCII-armored GPG-encrypted keystore, including its BEGIN and END lines. Not a file path, raw keystore, or base64 encoding. |

Use your existing Android signing keystore for app updates. For a new app, create
and securely back up a signing key using the
[Android signing guide](https://developer.android.com/studio/publish/app-signing).
Encrypt the keystore locally, entering the encryption passphrase when prompted:

```sh
gpg --armor --symmetric --cipher-algo AES256 --output release-keystore.jks.asc release-keystore.jks
```

Set `RELEASE_KEYSTORE` to the contents of the resulting encrypted file and
`RELEASE_KEYSTORE_PASSPHRASE` to the passphrase you just chose. Never commit the
keystore, its passwords, or generated signing configuration.

After pushing the workflow changes, open **Actions > Build the app > Run
workflow** and select the updated branch. Re-running an old run still uses its
original workflow revision. Missing secrets and decryption failures are reported
by the **Setup signing config** step before compilation.

Publishing workflows additionally require `GH_ACCESS_TOKEN` for GitHub releases
and/or `PLAY_STORE_CREDENTIALS` containing the Google Play service-account JSON
for Play Store uploads. Neither is required by the build-only signing step.
