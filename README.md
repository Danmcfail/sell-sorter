# Sell Sorter — README

Flutter app for Samsung Galaxy (Android) and iPad (iOS). It scans the photos
on the phone, skips the family photos, and sorts the selling photos into one
main folder with a subfolder per item: `Sell/Hammer/`, `Sell/Shirt/`,
`Sell/Video game/`, and so on. Originals are never moved or changed — the app
only copies.

## What it does

1. **Pick photos** — choose a bunch by hand.
   **Pick a phone folder** — choose one album on the phone.
   **Scan all photos** — one tap runs the whole job (scan -> sort ->
   save) in the background. A notification shows live progress
   ("Scanning 1,234 / 8,000"). You can lock the phone, use other
   apps, or close the app — the scan keeps going. Open the app any
   time to see the same progress. It saves as it goes: the folders
   build up in the `Sell` folder while it scans, so if a run gets
   interrupted nothing is lost and the next run picks up where it
   stopped instead of starting over.
2. **Sort photos** — on-device ML Kit (nothing is sent anywhere):
   - Face detection + person labels: a photo with people in it is a family
     photo, not a selling photo. It is skipped and gets no folder.
   - Image labels: the top label names the folder (hammer, shirt, game...).
     Same label, clearly different colour = a second folder
     ("Shirt", "Shirt 2").
   - Too dark, blown out, or blurry shots go in a `Poor` subfolder inside
     that item's folder. Good shots come first, sharpest first.
3. Fix anything it got wrong in the app: rename a folder, tap the thumb to
   flip a photo between Good and Poor, long-press a photo to move it to
   another folder. What you set stays set.
4. **Save folders** — copies everything into the app's `Sell` folder:
   `Sell/<Item>/` for good shots, `Sell/<Item>/Poor/` for the poor ones.

## It saves as it goes — it never starts over

- Every photo the app finishes is written down in a list it keeps on
  the phone. That list is never deleted.
- The next time you tap **Scan all photos**, it reads the list and
  skips every photo already on it — the notification says how many it
  skipped ("Scanning 3,000 / 8,000 • 5,000 already sorted"), so you
  can see it is not starting over.
- As each photo is sorted, its copy goes into its Sell folder right
  away (in small batches). If the phone dies or the app stops, the
  folders it already built are still there.
- If you delete a copy out of a Sell folder, the next run puts it
  back — it does not re-scan the photo, it just copies it again.
- Photos you pick by hand (Pick photos / Pick a phone folder) use the
  same list, so a photo sorted by hand is skipped by the next full
  scan too. Reviewing first (Sort photos, then Save folders) still
  works the same way — the folders are only saved when you tap Save
  folders.

## What it cannot do (the honest limits)

- **It can only see photos ON the phone.** No app can silently scan a whole
  Google Photos cloud library — Google shut that off on March 31, 2025
  (the Library API only sees photos the app itself uploaded; the Picker
  API only returns photos you pick by hand). The same wall applies to
  iCloud, OneDrive, TeraBox, and Facebook: no app can pull those libraries
  on its own. So before you scan:
  - **Google Photos:** open Google Photos, select the photos, tap
    Download. They land on the phone, then the app can see them.
  - **Apple Photos / iCloud:** on the iPad, open Photos, and make sure
    the photos are downloaded (not cloud-only thumbnails). In Settings >
    Photos, "Download and Keep Originals" does this.
  - **OneDrive / TeraBox:** open the app, select the photos, tap
    Download, or mark the folder "Available offline."
  - **Facebook:** open the photo on Facebook, save/download it to the
    phone first. There is no way for an app to pull your Facebook photos
    directly.
- Labels are generic ("hammer" may come out as "tool"). Rename with one tap.
- Two different items that look alike (two plain shirts, same colour) may
  land in one folder. Long-press to move the odd ones out.
- Samsung phones try to kill background apps to save battery. The first
  time you tap **Scan all photos**, the app asks to run without battery
  limits — allow it. If a scan ever stops when the app is closed, check
  Settings > Apps > Sell Sorter > Battery > Unrestricted.

## How to build it — Samsung version (Codemagic, no laptop needed)

This is uncompiled code. It has to be built on a computer first. The
easiest way, since the HP Stream laptop cannot download apps, is Codemagic
— a website that builds the app on its own computers and gives you the
finished file to download.

1. Put this folder on GitHub (free): make a new repository called
   `sell-sorter`, upload everything in this folder.
2. Sign up at https://codemagic.io with GitHub. Free plan, no credit card:
   500 free build minutes a month, refilled monthly.
3. In Codemagic, add the `sell-sorter` app. It reads `codemagic.yaml` in
   this folder and shows one workflow: "Sell Sorter Android APK".
   Machine: pick **Mac mini M2** — that is the machine the free minutes
   cover. (If Codemagic rejects the `instance_type` line in
   `codemagic.yaml`, delete that line and pick the machine on the website.)
4. Press **Start new build**. One build takes about 10–20 minutes.
5. When it finishes, download **app-release.apk** from Artifacts.
6. Move it to the Samsung phone and tap it to install. (If the phone
   blocks it, allow "Install unknown apps" for the Files app, just this
   once.)
7. If the build fails, send the error back — the fix goes in this code.

Notes for whoever builds it:
- Flutter version is pinned to 3.19.6 in `codemagic.yaml`. If Codemagic
  says that version is not available, change it to the nearest version
  it offers and rebuild.
- `android/gradlew` is a small launcher that downloads Gradle 7.5 itself
  (there is no wrapper jar in this repo). It needs internet on the build
  machine, which Codemagic has.

## How to build it — Samsung version (HP Stream laptop, fallback)

Only if the laptop can install apps (it is in S mode as it stands, which
blocks installs outside the Microsoft Store; switching S mode off is
free but one-way — and Flutter still wants about 8 GB of memory while
HP Streams usually have 4 GB, so the build may fail on memory anyway).

1. Install Flutter: https://docs.flutter.dev/get-started/install/windows
2. Open a terminal and run:
   `flutter create sell_sorter`
3. Copy this folder's contents over the new project (replace
   `lib/main.dart`, `pubspec.yaml`, and the `android/` folder).
4. Add photo permission to `android/app/src/main/AndroidManifest.xml`
   (already in the manifest in this folder).
5. In the project folder run:
   `flutter pub get`
   `flutter build apk --release`
6. The finished file is at `build/app/outputs/flutter-apk/app-release.apk`.
   Move it to the Samsung phone and tap it to install.

## iPad (iOS) — needs a Mac

An iPhone/iPad app can only be built on a Mac with Xcode installed. It
cannot be built from the Windows HP Stream laptop. Codemagic's Mac
minutes can build the iOS version too, but installing it on the iPad
needs an Apple Developer account ($99/year). On a Mac:
`flutter create sell_sorter`, copy this folder's contents over it, add
this line to `ios/Runner/Info.plist` inside `<dict>`:
`<key>NSPhotoLibraryUsageDescription</key><string>Sell Sorter needs your photos to sort the ones you are selling.</string>`
Then `flutter pub get` and `flutter build ios --release`.

## For Grok

This code is plain Flutter/Dart text files — nothing here is locked to Muse.
Share the zip (or paste `main.dart` + `pubspec.yaml` + this README) into
Grok and it can read it, fix it, and build it. Grok cannot reach into Muse's
workspace on its own, so the files have to be handed to it. Things Grok may
need to adjust: the ML Kit package versions in `pubspec.yaml` (bump them if
`flutter pub get` complains), the Flutter version in `codemagic.yaml`, and
the Android/iOS permission lines above if the Flutter version it uses wants
them somewhere else.
