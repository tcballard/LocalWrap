# LocalWrap 3.3.0

LocalWrap for macOS is now a native Swift 6 application. Windows and Linux
remain Electron applications with their existing NSIS and AppImage installers.

## macOS migration

On first native Release launch, LocalWrap validates and copies the Electron
project document from `~/Library/Application Support/localwrap/projects.json`
into `~/Library/Application Support/LocalWrapNative/store.json`. The Electron
file is never edited or deleted. To return temporarily to Electron, quit the
native app and launch the Electron build; it continues to read its original
data. Changes made only in native LocalWrap are not copied back automatically.

If native data is corrupt, LocalWrap preserves it and offers Restore Backup,
confirmed Start Fresh, or Quit before any project or autostart command loads.

The macOS download is a universal arm64/x86_64 Developer ID-signed, Apple-
notarized DMG. Verify its adjacent `.sha256` file before opening it.
