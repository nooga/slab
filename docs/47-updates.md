# 47 — Updates

Slab looks for a newer release on GitHub and, when it is installed as an
app, installs it on a restart.

Source: `src/updater.zig` (check, download, swap), `src/ui/update_dialog.zig`
(the card; the offer is the logo tile in `src/ui/transport_bar.zig`), `tools/release.sh` (publishes the checksum).

## The check

At launch a background thread asks
`api.github.com/repos/nooga/slab/releases/latest` (through `curl`) and
compares its tag with the running version, numerically (0.0.20 is newer than
0.0.9). Nothing else is sent; a failed check is silent. One request a launch.
Turn it off with the switch on the update card, or `"check_updates": false`
in settings.json. `SLAB_NO_UPDATE=1` skips it for one run.

A newer release shows an UPDATE offer in place of the SLAB logo. It
opens the card: the release notes, and buttons that fit how Slab is installed.
SKIP remembers that version (`skip_version` in settings.json) until a newer
one comes out. About's UPDATES button checks on demand.

## Installing

| Slab is | The card offers |
|---|---|
| in a Slab.app whose folder you can write | UPDATE, then RESTART NOW |
| installed with Homebrew (`Caskroom/slab` exists) | `brew upgrade --cask slab` and the release page |
| a dev build, or in a folder it can't write | the release page |

UPDATE downloads `Slab.zip` and `Slab.zip.sha256` from the release into
`~/Library/Caches/Slab/update`, checks the zip against the checksum, unpacks
it and verifies the bundle's signature. Any failure leaves the installed app
untouched and says so. RESTART NOW quits Slab (unsaved work is kept as after a
crash, docs/46) and a detached script swaps `Slab.app`, removes the quarantine
flag and reopens it; if the swap fails the old bundle is put back.

The checksum guards against a truncated or corrupt download. It lives next to
the zip, so it is not protection against a compromised release; signing
releases with a key built into the app would be.

## Testing without a release

`SLAB_UPDATE_API` points the check at any URL (`file://` works) with a
release's JSON, and its assets may then be `file://` URLs too. It also skips
the Homebrew check. That is how the install path was exercised end to end.
