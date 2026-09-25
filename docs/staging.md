# Bowser Staging

Two apps live alongside each other:

- `/Applications/Bowser.app` runs production with its normal update feed.
- `/Applications/Bowser-staging.app` runs the development build with an orange **STG** badge.

Both retain the `com.foxwiseai.bowser` identity and use the same `~/.bowser`
sessions, profiles, mods and WebKit stores. Quit one before opening the other.
Use `bin/staging prod` or `bin/staging start`, or open the corresponding app in
Finder.

Staging has its own backend under `~/.bowser/staging-runtime`.
Staging ignores the shared live-runtime pointer
when starting, and its updates leave the production runtime and app intact.
Staging installation does not create another production app.

Run `bin/staging update` from the development checkout to build and prepare a
complete staging update. In staging, **Bowser → Update Staging from Dev…** does
the same thing using the checkout that built the app. This packages the current
working copy; it does not fetch or change source control revisions. Build output
from the menu action is in `~/.bowser/updates/staging-build.log`.

Keep browsing during the build. Production and staging both show **Update ready**
with **Restart Now** and **Later**. Restart Now requests normal shutdown of Bowser
and its saved apps, shows backup and installation progress in a separate window,
then reopens the updated app and previously running saved apps. It never forces
an app to quit. If an app stays open, finish its work or respond to its quit prompt;
**Stop Waiting** closes the coordinator without forcing shutdown or reopening.
Later keeps the update prepared for a normal quit; use the update menu to restart
when ready. The app also detects updates prepared from the checkout.

Both channels take a verified backup before replacing the shell/runtime pair.
Full updates do not hot-swap backend or native modules before the backup. Staging
replaces only its own pair. Production downloads from the stable feed; staging
builds from the checkout. Backup or installation failures appear in the update
window and leave the update pending. The updater reports per-stage progress in
`~/.bowser/updates/progress.json`; its log is `~/.bowser/updates/install.log`.

## Recovery

`bin/staging backups` lists snapshot manifests. Each snapshot directory includes
persistent Bowser state (sessions, profiles, settings and mods) and Bowser-scoped Library data (WebKit, cookies, HTTP storage, preferences,
application support). File contents and symbolic-link targets are
verified before activation and again before recovery. Sockets, process locks,
logs, regenerable caches, app bundles, runtimes, generated native modules, staged builds and old backups are excluded.
Existing recovery archives and WebKit's HTTP NetworkCache are also excluded;
IndexedDB, local storage, service workers and offline CacheStorage remain protected.
Snapshots use independent APFS copy-on-write files. Unchanged files reuse verified
checksums only when device, inode, size, nanosecond modification and change times
match; changed files are hashed and compared with their copies. Recovery always
hashes the entire saved payload before writing. The exclusive data lock protects
the snapshot and activation without a fixed settle delay.
The updater preserves the previous app/runtime pair separately by renaming it. Symbolic links are preserved;
files outside these roots reached through links are not copied. The macOS
Keychain is unchanged and is not part of these file backups.

Backups are private to the user and retained under `~/.bowser/backups`; they are
not pruned automatically. A failed backup leaves the current build installed and
the update pending. Ensure there is space for persistent user and website data.

To restore, quit Bowser and every saved app, then run:

```sh
bin/staging cancel                 # cancel a pending update, if any
bin/staging restore ~/.bowser/backups/1700000000-EXAMPLE
```

Choose an actual directory reported by `backups`. Recovery verifies its payload,
takes another backup of the current data, then restores the chosen data.
Data-only snapshots leave installed apps and runtimes unchanged; format-1 full
snapshots also restore their bundled executables. Changes since that snapshot are rolled back, including new
state files. Ordinary errors while replacing files roll back completed swaps.
Do not interrupt recovery; power-loss recovery is not transactional across all
Library and application directories.

To return to prod, quit staging and open `/Applications/Bowser.app`.
This keeps your current shared data. A snapshot restore is a separate recovery
operation that rewinds data to the selected backup.

`bin/install` updates the original normal installation; `bin/staging update`
updates only staging. Staging never polls the stable release feed. Both named
apps preserve the same website storage identity, so no cookie import or separate
profile is needed.
