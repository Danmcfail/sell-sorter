// Sell Sorter — sorts photos of things to sell into one folder per item.
//
// What it does:
//  1. You give it photos: pick a bunch at once, pick a phone folder, or
//     tap "Scan all photos" and it loads every photo on the phone.
//  2. It looks at every photo on the phone itself (ML Kit, no photos
//     sent anywhere) and works out whether it is something to sell.
//     Photos with people in them (faces found, or a "person" label)
//     are family photos, not selling photos — they are skipped, and
//     NO folder is made for them. Only selling photos get folders.
//  3. Selling photos are grouped by what they show: all the hammers
//     together, all the video games together, all 20 shots of one
//     shirt together. Same label but a clearly different colour splits
//     into a second folder ("Shirt", "Shirt 2") so a red shirt and a
//     blue shirt do not land together.
//  4. It judges each photo: too dark, blown out, or blurry shots go in
//     a "Poor" subfolder inside that item's folder. Good shots stay
//     in the main folder, sharpest first, numbered 01, 02, 03...
//  5. You fix anything it got wrong in the app: rename a folder, flip
//     a photo between Good and Poor, or long-press a photo to move it
//     to another folder. What you set stays set.
//  6. "Save folders" copies (never moves) everything into one main
//     folder: Sell/<Item>/ for good shots, Sell/<Item>/Poor/ for the
//     poor ones. Originals are never touched.
//
// "Scan all photos" runs the whole pipeline (scan -> sort -> save) in
// the background, in a foreground service with a progress notification
// ("Scanning 1,234 / 8,000"). You can lock the phone, use other apps,
// or close the app — the scan keeps going. Open the app any time to
// see the same progress. If the phone is a Samsung and the scan stops
// when the app is closed, allow Sell Sorter to run without battery
// limits (Settings > Apps > Sell Sorter > Battery > Unrestricted).
// A run that gets interrupted resumes where it stopped instead of
// starting over.
//
// Honest limits (read this before you build):
//  - The app can only see photos ON the phone. It cannot reach into
//    Google Photos cloud, iCloud, OneDrive, or Facebook on its own.
//    Google shut off whole-library cloud access on Mar 31, 2025.
//    Download cloud photos onto the phone first, then scan them here.
//    Facebook photos: download them from Facebook to the phone first.
//  - Labels are generic ("hammer" may come out as "tool"). Rename the
//    folder with one tap and the name sticks.
//  - Two different items that look alike (two plain shirts the same
//    colour) may land in one folder. Split them with a long-press move.
//  - 1,000-2,000 photos take a few minutes. A progress count shows
//    while it runs.
//  - This is uncompiled code. It has to be built on a computer first
//    (see README.md). The first build is the test — send any build
//    error back and it can be fixed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

void main() {
  // Lets the background scan talk to the app screen.
  FlutterForegroundTask.initCommunicationPort();
  runApp(const SellSorterApp());
}

/// Entry point for the background scan. Runs in the service's own
/// isolate — that is what keeps the scan going when the app is closed,
/// the screen is off, or the app is swiped away from recents.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(SellSorterTaskHandler());
}

class SellSorterApp extends StatelessWidget {
  const SellSorterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sell Sorter',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const HomePage(),
    );
  }
}

/// One analyzed photo, as plain data (safe to send between isolates).
class AnalyzedPhoto {
  AnalyzedPhoto({
    required this.path,
    this.label = 'Unsorted',
    this.brightness = 128,
    this.blur = 9999,
    this.color = const [128, 128, 128],
    this.poor = false,
    this.skipped = false,
  });

  final String path;
  final String label; // ML Kit top label, or 'Unsorted'.
  final double brightness; // Mean luminance, 0-255.
  final double blur; // Laplacian variance; low = blurry.
  final List<int> color; // Average red, green, blue.
  final bool poor;
  final bool skipped; // True when a person is in the photo.

  Map<String, dynamic> toJson() => {
        'path': path,
        'label': label,
        'brightness': brightness,
        'blur': blur,
        'color': color,
        'poor': poor,
        'skipped': skipped,
      };

  factory AnalyzedPhoto.fromJson(Map<String, dynamic> j) => AnalyzedPhoto(
        path: j['path'] as String,
        label: j['label'] as String? ?? 'Unsorted',
        brightness: (j['brightness'] as num?)?.toDouble() ?? 128,
        blur: (j['blur'] as num?)?.toDouble() ?? 9999,
        color: (j['color'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [128, 128, 128],
        poor: j['poor'] as bool? ?? false,
        skipped: j['skipped'] as bool? ?? false,
      );
}

/// One item's folder, as plain data (safe to send between isolates).
class GroupData {
  GroupData(this.name, this.good, this.poor);

  String name;
  final List<AnalyzedPhoto> good;
  final List<AnalyzedPhoto> poor;

  Map<String, dynamic> toJson() => {
        'name': name,
        'good': good.map((p) => p.toJson()).toList(),
        'poor': poor.map((p) => p.toJson()).toList(),
      };

  factory GroupData.fromJson(Map<String, dynamic> j) => GroupData(
        j['name'] as String? ?? 'Unsorted',
        ((j['good'] as List?) ?? [])
            .map((e) =>
                AnalyzedPhoto.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        ((j['poor'] as List?) ?? [])
            .map((e) =>
                AnalyzedPhoto.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

String _title(String label) {
  if (label.isEmpty) return 'Unsorted';
  return label[0].toUpperCase() + label.substring(1);
}

double _colorDistance(List<int> a, List<int> b) {
  final dr = (a[0] - b[0]).toDouble();
  final dg = (a[1] - b[1]).toDouble();
  final db = (a[2] - b[2]).toDouble();
  return math.sqrt(dr * dr + dg * dg + db * db);
}

String _slug(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return slug.isEmpty ? 'item' : slug;
}

String _ext(String path) {
  final parts = path.split('.');
  final ext = parts.length > 1 ? parts.last.toLowerCase() : 'jpg';
  return ['jpg', 'jpeg', 'png', 'webp', 'heic'].contains(ext) ? ext : 'jpg';
}

/// Labels that mean "there are people in this photo" — not selling.
const _peopleWords = {
  'person',
  'people',
  'face',
  'selfie',
  'portrait',
  'man',
  'woman',
  'boy',
  'girl',
  'baby',
  'child',
  'family',
};

bool _isPeoplePhoto(List<ImageLabel> labels) {
  for (final l in labels) {
    if (l.confidence < 0.5) continue;
    final word = l.label.toLowerCase();
    if (_peopleWords.contains(word)) return true;
  }
  return false;
}

// ---------- analysis ----------

/// Brightness, blur and average colour from raw RGBA bytes of a small
/// (256 px wide) copy. Same maths as the old image-package path below.
({double brightness, double blur, List<int> color}) _statsFromRgba(
    Uint8List rgba, int w, int h) {
  var rSum = 0, gSum = 0, bSum = 0, count = 0;
  final gray = List<List<double>>.generate(
    h,
    (_) => List<double>.filled(w, 0),
  );
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final r = rgba[i].toDouble();
      final g = rgba[i + 1].toDouble();
      final b = rgba[i + 2].toDouble();
      rSum += r.toInt();
      gSum += g.toInt();
      bSum += b.toInt();
      count++;
      gray[y][x] = 0.299 * r + 0.587 * g + 0.114 * b;
    }
  }
  // Laplacian variance: low values mean a blurry photo.
  var lapSum = 0.0, lapSqSum = 0.0, lapCount = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final lap = gray[y - 1][x] +
          gray[y + 1][x] +
          gray[y][x - 1] +
          gray[y][x + 1] -
          4 * gray[y][x];
      lapSum += lap;
      lapSqSum += lap * lap;
      lapCount++;
    }
  }
  final mean = lapCount == 0 ? 0.0 : lapSum / lapCount;
  final variance =
      lapCount == 0 ? 0.0 : (lapSqSum / lapCount) - mean * mean;
  return (
    brightness: count == 0
        ? 128
        : (0.299 * rSum + 0.587 * gSum + 0.114 * bSum) / count,
    blur: variance,
    color: count == 0
        ? [128, 128, 128]
        : [rSum ~/ count, gSum ~/ count, bSum ~/ count],
  );
}

/// Fallback analysis with the pure-Dart image package, used only when
/// the platform image codec is not available (for example in a
/// background isolate on some devices). Same numbers, slower.
({double brightness, double blur, List<int> color}) _analyzeWithImagePackage(
    Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return (brightness: 128, blur: 9999, color: [128, 128, 128]);
  }
  final small = img.copyResize(decoded, width: 256);
  var rSum = 0, gSum = 0, bSum = 0, count = 0;
  final gray = List<List<double>>.generate(
    small.height,
    (_) => List<double>.filled(small.width, 0),
  );
  for (var y = 0; y < small.height; y++) {
    for (var x = 0; x < small.width; x++) {
      final px = small.getPixel(x, y);
      final r = px.r.toDouble(), g = px.g.toDouble(), b = px.b.toDouble();
      rSum += r.toInt();
      gSum += g.toInt();
      bSum += b.toInt();
      count++;
      gray[y][x] = 0.299 * r + 0.587 * g + 0.114 * b;
    }
  }
  var lapSum = 0.0, lapSqSum = 0.0, lapCount = 0;
  for (var y = 1; y < small.height - 1; y++) {
    for (var x = 1; x < small.width - 1; x++) {
      final lap = gray[y - 1][x] +
          gray[y + 1][x] +
          gray[y][x - 1] +
          gray[y][x + 1] -
          4 * gray[y][x];
      lapSum += lap;
      lapSqSum += lap * lap;
      lapCount++;
    }
  }
  final mean = lapCount == 0 ? 0.0 : lapSum / lapCount;
  final variance =
      lapCount == 0 ? 0.0 : (lapSqSum / lapCount) - mean * mean;
  return (
    brightness: count == 0
        ? 128
        : (0.299 * rSum + 0.587 * gSum + 0.114 * bSum) / count,
    blur: variance,
    color: count == 0
        ? [128, 128, 128]
        : [rSum ~/ count, gSum ~/ count, bSum ~/ count],
  );
}

/// Brightness, blur and average colour of a photo, from a small copy.
/// Fast path: the platform image codec decodes straight to 256 px wide
/// instead of decoding the whole 12-megapixel photo in Dart first.
/// That was the slowest part of the old scan.
Future<({double brightness, double blur, List<int> color})> _analyzeBytes(
    Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 256);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData != null) {
        return _statsFromRgba(
          byteData.buffer.asUint8List(),
          image.width,
          image.height,
        );
      }
    } finally {
      image.dispose();
    }
  } catch (_) {
    // Fall through to the pure-Dart decoder below.
  }
  return _analyzeWithImagePackage(bytes);
}

/// Works out one photo: person in it (skip), ML Kit label, and quality.
/// If face detection already found a person, image labeling is skipped
/// — that saves one ML Kit pass on every family photo.
Future<AnalyzedPhoto> _analyzeOne(
  String path,
  ImageLabeler labeler,
  FaceDetector faceDetector,
) async {
  bool hasPerson = false;
  List<ImageLabel> labels = [];
  try {
    final input = InputImage.fromFilePath(path);
    final faces = await faceDetector.processImage(input);
    if (faces.isNotEmpty) hasPerson = true;
    if (!hasPerson) {
      labels = await labeler.processImage(input);
      if (_isPeoplePhoto(labels)) hasPerson = true;
    }
  } catch (_) {
    // If detection fails, fall through and label it normally.
  }
  if (hasPerson) return AnalyzedPhoto(path: path, skipped: true);
  String label = 'Unsorted';
  if (labels.isNotEmpty) {
    labels.sort((a, b) => b.confidence.compareTo(a.confidence));
    label = labels.first.label;
  }
  final bytes = await File(path).readAsBytes();
  final info = await _analyzeBytes(bytes);
  // Poor shots: too dark, blown out, or blurry.
  final poor =
      info.brightness < 35 || info.brightness > 245 || info.blur < 30;
  return AnalyzedPhoto(
    path: path,
    label: label,
    brightness: info.brightness,
    blur: info.blur,
    color: info.color,
    poor: poor,
  );
}

/// Groups analyzed photos into per-item folders: same label, and a
/// clearly different colour splits into a second folder. Same rules as
/// the original foreground sort — nothing about grouping changed.
List<GroupData> _buildGroups(List<AnalyzedPhoto> photos) {
  // label -> list of colour-split subgroups.
  final Map<String, List<GroupData>> byLabel = {};
  for (final photo in photos) {
    if (photo.skipped) continue;
    final subs = byLabel.putIfAbsent(photo.label, () => []);
    GroupData? target;
    for (final g in subs) {
      final ref = g.good.isNotEmpty
          ? g.good.first
          : (g.poor.isNotEmpty ? g.poor.first : null);
      if (ref != null && _colorDistance(ref.color, photo.color) < 70) {
        target = g;
        break;
      }
    }
    target ??= GroupData(_title(photo.label), [], []);
    if (!subs.contains(target)) subs.add(target);
    if (photo.poor) {
      target.poor.add(photo);
    } else {
      target.good.add(photo);
    }
  }
  // Flatten, number duplicate names, sharpest good shots first.
  final List<GroupData> groups = [];
  final usedNames = <String>{};
  for (final subs in byLabel.values) {
    for (final g in subs) {
      var name = g.name;
      var n = 2;
      while (usedNames.contains(name)) {
        name = '${g.name} $n';
        n++;
      }
      usedNames.add(name);
      g.name = name;
      g.good.sort((a, b) => b.blur.compareTo(a.blur));
      g.poor.sort((a, b) => b.blur.compareTo(a.blur));
      groups.add(g);
    }
  }
  groups.sort((a, b) =>
      (b.good.length + b.poor.length).compareTo(a.good.length + a.poor.length));
  return groups;
}

/// Copies grouped photos into Sell/<Item>/ and Sell/<Item>/Poor/.
/// Copies only — originals are never touched. Returns the Sell folder.
Future<String> _saveGroups(List<GroupData> groups, Directory docs) async {
  final root = Directory('${docs.path}/Sell');
  for (final g in groups) {
    final dir = Directory('${root.path}/${g.name}');
    final poorDir = Directory('${dir.path}/Poor');
    await dir.create(recursive: true);
    if (g.poor.isNotEmpty) await poorDir.create(recursive: true);
    final slug = _slug(g.name);
    for (var i = 0; i < g.good.length; i++) {
      final dest = File(
        '${dir.path}/${slug}_${(i + 1).toString().padLeft(2, '0')}.${_ext(g.good[i].path)}',
      );
      if (await dest.exists()) await dest.delete();
      await File(g.good[i].path).copy(dest.path);
    }
    for (var i = 0; i < g.poor.length; i++) {
      final dest = File(
        '${poorDir.path}/${slug}_${(i + 1).toString().padLeft(2, '0')}.${_ext(g.poor[i].path)}',
      );
      if (await dest.exists()) await dest.delete();
      await File(g.poor[i].path).copy(dest.path);
    }
  }
  return root.path;
}

/// The whole sort, usable from the app screen and from the background
/// service alike: analyzes [paths], groups them, and (unless [save] is
/// false) saves the folders.
///
/// A run that gets interrupted leaves a checkpoint file behind, so the
/// next run skips the photos it already analyzed instead of starting
/// over. The checkpoint is deleted only after a successful save.
Future<({List<GroupData> groups, int skipped, String savePath})>
    runSortPipeline({
  required List<String> paths,
  required Future<void> Function(int done, int total, int skipped)
      onProgress,
  bool save = true,
}) async {
  final docs = await getApplicationDocumentsDirectory();
  final checkpoint = File('${docs.path}/sell_sorter_checkpoint.jsonl');
  final Map<String, AnalyzedPhoto> done = {};
  if (await checkpoint.exists()) {
    try {
      for (final line in await checkpoint.readAsLines()) {
        if (line.trim().isEmpty) continue;
        final photo = AnalyzedPhoto.fromJson(
            (jsonDecode(line) as Map).cast<String, dynamic>());
        done[photo.path] = photo;
      }
    } catch (_) {
      // A damaged checkpoint is ignored — the run just starts over.
      done.clear();
    }
  }
  // Only records for photos in this run count.
  final wanted = paths.toSet();
  done.removeWhere((path, _) => !wanted.contains(path));

  var skipped = done.values.where((p) => p.skipped).length;
  var processed = done.length;
  await onProgress(processed, paths.length, skipped);

  if (processed < paths.length) {
    final labeler = ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.5),
    );
    final faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: false,
        enableTracking: false,
        minFaceSize: 0.1,
      ),
    );
    final sink = checkpoint.openWrite(mode: FileMode.append);
    var sinceFlush = 0;
    try {
      for (final path in paths) {
        if (done.containsKey(path)) continue;
        AnalyzedPhoto? photo;
        try {
          photo = await _analyzeOne(path, labeler, faceDetector);
        } catch (_) {
          photo = null; // Unreadable photo — skip it, keep going.
        }
        if (photo != null) {
          done[path] = photo;
          if (photo.skipped) skipped++;
          sink.writeln(jsonEncode(photo.toJson()));
          if (++sinceFlush >= 50) {
            await sink.flush();
            sinceFlush = 0;
          }
        }
        processed++;
        await onProgress(processed, paths.length, skipped);
      }
    } finally {
      await sink.flush();
      await sink.close();
      labeler.close();
      faceDetector.close();
    }
  }

  final groups = _buildGroups(done.values.toList());
  var savePath = '';
  if (save) {
    savePath = await _saveGroups(groups, docs);
    if (await checkpoint.exists()) await checkpoint.delete();
  }
  return (groups: groups, skipped: skipped, savePath: savePath);
}

// ---------- background service ----------

/// The scan that runs in the foreground service. It lives in its own
/// isolate, so it keeps going when the app is closed, the screen is
/// off, or the app is swiped away from recents.
class SellSorterTaskHandler extends TaskHandler {
  Completer<Map<String, dynamic>>? _command;
  bool _stopped = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _command = Completer<Map<String, dynamic>>();
    Map<String, dynamic>? cmd;
    try {
      cmd = await _command!.future.timeout(const Duration(seconds: 120));
    } catch (_) {
      cmd = null;
    }
    if (cmd == null || cmd['command'] != 'scan_all') {
      // No job arrived from the app — stop the service again.
      await _stopFromTask();
      return;
    }
    await _runBackgroundScan();
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map<String, dynamic> &&
        _command != null &&
        !_command!.isCompleted) {
      _command!.complete(data);
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // The scan reports its own progress; nothing to repeat.
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationDismissed() {}

  Future<void> _stopFromTask() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }

  Future<void> _sendAndStop(Map<String, dynamic> data) async {
    try {
      FlutterForegroundTask.sendDataToMain(data);
    } catch (_) {}
    await _stopFromTask();
  }

  Future<void> _runBackgroundScan() async {
    try {
      final albums = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.image,
      );
      if (albums.isEmpty) {
        await _sendAndStop({
          'status': 'error',
          'message': 'No photo albums found on this phone.',
        });
        return;
      }
      // Every photo on the phone (the All Photos / Recents album).
      final album = albums.first;
      final paths = <String>[];
      final seen = <String>{};
      var page = 0;
      while (true) {
        final assets = await album.getAssetListPaged(page: page, size: 300);
        if (assets.isEmpty) break;
        for (final a in assets) {
          final f = await a.file;
          if (f != null && seen.add(f.path)) paths.add(f.path);
        }
        page++;
      }

      var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
      final result = await runSortPipeline(
        paths: paths,
        save: true,
        onProgress: (done, total, skipped) async {
          final now = DateTime.now();
          if (done == total ||
              now.difference(lastNotify).inMilliseconds >= 1000) {
            lastNotify = now;
            final text =
                'Scanning ${_withCommas(done)} / ${_withCommas(total)}';
            try {
              await FlutterForegroundTask.updateService(
                notificationTitle: 'Sell Sorter',
                notificationText: text,
              );
            } catch (_) {}
            try {
              FlutterForegroundTask.sendDataToMain({
                'status': 'progress',
                'done': done,
                'total': total,
                'skipped': skipped,
              });
            } catch (_) {}
          }
        },
      );
      await _sendAndStop({
        'status': 'done',
        'groups': result.groups.map((g) => g.toJson()).toList(),
        'skipped': result.skipped,
        'savePath': result.savePath,
        'total': paths.length,
      });
    } catch (e) {
      await _sendAndStop({
        'status': 'error',
        'message': 'Background scan stopped: $e',
      });
    }
  }
}

String _withCommas(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

// ---------- UI ----------

/// One photo, plus what the app worked out about it.
class PhotoItem {
  PhotoItem({
    required this.file,
    required this.label,
    required this.brightness,
    required this.blur,
    required this.color,
  });

  final File file;
  final String label; // ML Kit top label, or 'Unsorted'.
  final double brightness; // Mean luminance, 0-255.
  final double blur; // Laplacian variance; low = blurry.
  final List<int> color; // Average red, green, blue.
  bool poor = false;
}

/// One item's folder: good shots plus a Poor subfolder.
class ItemGroup {
  ItemGroup(this.name);

  String name;
  final List<PhotoItem> good = [];
  final List<PhotoItem> poor = [];
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<File> _picked = [];
  List<ItemGroup> _groups = [];
  bool _working = false;
  String _status = 'Pick photos, a phone folder, or scan all photos.';
  int _done = 0;
  int _total = 0;
  int _skipped = 0; // Photos with people in them — not selling.

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _initService();
      await _loadSavedFolders();
      if (await FlutterForegroundTask.isRunningService) {
        if (mounted) {
          setState(() => _status =
              'A background scan is running — progress will show here.');
        }
      }
    });
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    super.dispose();
  }

  void _initService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sell_sorter_scan',
        channelName: 'Sell Sorter scan',
        channelDescription:
            'Shows scan progress while Sell Sorter sorts photos in the background.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Progress and results sent by the background scan.
  void _onReceiveTaskData(Object data) {
    final Map<String, dynamic> map;
    if (data is Map<String, dynamic>) {
      map = data;
    } else if (data is Map) {
      map = data.cast<String, dynamic>();
    } else {
      return;
    }
    final status = map['status'] as String?;
    if (status == 'progress') {
      final done = (map['done'] as num?)?.toInt() ?? 0;
      final total = (map['total'] as num?)?.toInt() ?? 0;
      final skipped = (map['skipped'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      setState(() {
        _working = true;
        _done = done;
        _total = total;
        _skipped = skipped;
        _status =
            'Scanning in the background: ${_withCommas(done)} / ${_withCommas(total)}…';
      });
      return;
    }
    if (status == 'done') {
      final groups = ((map['groups'] as List?) ?? [])
          .map((g) => GroupData.fromJson((g as Map).cast<String, dynamic>()))
          .toList();
      final skipped = (map['skipped'] as num?)?.toInt() ?? 0;
      final savePath = map['savePath'] as String? ?? '';
      if (!mounted) return;
      setState(() {
        _groups = groups.map(_groupDataToItemGroup).toList();
        _working = false;
        _status =
            '${_groups.length} selling folders, $skipped family photos skipped. '
            'Saved to $savePath. Check names, then tap Save folders again if you changed any.';
      });
      return;
    }
    if (status == 'error') {
      if (!mounted) return;
      setState(() {
        _working = false;
        _status =
            '${map['message'] as String? ?? 'Background scan stopped.'} '
            'Use Sort photos instead.';
      });
    }
  }

  ItemGroup _groupDataToItemGroup(GroupData g) {
    final group = ItemGroup(g.name);
    for (final p in g.good) {
      group.good.add(PhotoItem(
        file: File(p.path),
        label: p.label,
        brightness: p.brightness,
        blur: p.blur,
        color: p.color,
      ));
    }
    for (final p in g.poor) {
      group.poor.add(PhotoItem(
        file: File(p.path),
        label: p.label,
        brightness: p.brightness,
        blur: p.blur,
        color: p.color,
      )..poor = true);
    }
    return group;
  }

  /// Folders already saved by an earlier run, so the app shows them
  /// again even if it was closed while the background scan finished.
  Future<void> _loadSavedFolders() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = Directory('${docs.path}/Sell');
      if (!await root.exists()) return;
      final groups = <ItemGroup>[];
      await for (final e in root.list()) {
        if (e is! Directory) continue;
        final name = e.path.split('/').last;
        final g = ItemGroup(name);
        await for (final f in e.list()) {
          if (f is Directory && f.path.split('/').last == 'Poor') {
            await for (final pf in f.list()) {
              if (pf is File) {
                g.poor.add(PhotoItem(
                  file: pf,
                  label: name,
                  brightness: 128,
                  blur: 9999,
                  color: const [128, 128, 128],
                )..poor = true);
              }
            }
          } else if (f is File) {
            g.good.add(PhotoItem(
              file: f,
              label: name,
              brightness: 128,
              blur: 9999,
              color: const [128, 128, 128],
            ));
          }
        }
        if (g.good.isNotEmpty || g.poor.isNotEmpty) groups.add(g);
      }
      if (groups.isNotEmpty && mounted) {
        setState(() {
          _groups = groups;
          _status =
              '${groups.length} saved folders from a previous run. Tap Scan all photos to sort the rest.';
        });
      }
    } catch (_) {}
  }

  // ---------- picking ----------

  Future<void> _pickPhotos() async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty) return;
    setState(() {
      for (final f in files) {
        final file = File(f.path);
        if (!_picked.any((p) => p.path == file.path)) _picked.add(file);
      }
      _status = '${_picked.length} photos ready. Tap Sort photos.';
    });
  }

  Future<void> _pickAlbum() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      setState(() => _status = 'Photo permission not given. Allow it and try again.');
      return;
    }
    final albums = await PhotoManager.getAssetPathList(
      onlyAll: false,
      type: RequestType.image,
    );
    if (albums.isEmpty || !mounted) return;
    final AssetPathEntity? album = await showDialog<AssetPathEntity>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Pick a phone folder'),
        children: [
          for (final a in albums)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, a),
              child: FutureBuilder<int>(
                future: a.assetCountAsync,
                builder: (context, snapshot) {
                  final count = snapshot.data;
                  return Text(count == null ? a.name : '${a.name} ($count)');
                },
              ),
            ),
        ],
      ),
    );
    if (album == null) return;
    await _loadAlbum(album);
  }

  /// One tap: the whole pipeline (scan -> sort -> save) runs in the
  /// background service. Lock the phone, use other apps, or close the
  /// app — the scan keeps going, with its progress in a notification.
  Future<void> _scanAllInBackground() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      setState(() => _status = 'Photo permission not given. Allow it and try again.');
      return;
    }
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (await FlutterForegroundTask.isRunningService) {
      setState(() => _status = 'Restarting the background scan…');
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Sell Sorter',
      notificationText: 'Starting scan…',
      notificationInitialRoute: '/',
      callback: startCallback,
    );
    // Give the background engine a moment to boot before sending the job.
    await Future.delayed(const Duration(milliseconds: 1500));
    FlutterForegroundTask.sendDataToTask({'command': 'scan_all'});
    if (!await FlutterForegroundTask.isRunningService) {
      if (mounted) {
        setState(() => _status =
            'The background scan could not start. Keep the app open and use Sort photos instead.');
      }
      return;
    }
    if (mounted) {
      setState(() {
        _working = true;
        _done = 0;
        _total = 0;
        _status =
            'Scan running in the background — you can lock the phone or use other apps. Open the app any time to see progress.';
      });
    }
    // Samsung and other makers kill background apps to save battery.
    // Ask once to leave Sell Sorter alone (the scan keeps going either way).
    try {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {}
  }

  Future<void> _loadAlbum(AssetPathEntity album) async {
    setState(() {
      _working = true;
      _total = 0;
      _status = 'Loading ${album.name}...';
    });
    final List<File> files = [];
    var page = 0;
    while (true) {
      final assets = await album.getAssetListPaged(page: page, size: 300);
      if (assets.isEmpty) break;
      for (final a in assets) {
        final f = await a.file;
        if (f != null && !files.any((p) => p.path == f.path)) files.add(f);
      }
      page++;
    }
    setState(() {
      _picked.addAll(
        files.where((f) => !_picked.any((p) => p.path == f.path)),
      );
      _working = false;
      _status = '${_picked.length} photos ready from ${album.name}. Tap Sort photos.';
    });
  }

  // ---------- sorting (foreground, for picked photos) ----------

  Future<void> _groupPhotos() async {
    if (_picked.isEmpty) {
      setState(() => _status = 'No photos picked yet.');
      return;
    }
    if (await FlutterForegroundTask.isRunningService) {
      setState(() => _status =
          'A background scan is already running — wait for it to finish, then check the folders.');
      return;
    }
    setState(() {
      _working = true;
      _done = 0;
      _skipped = 0;
      _total = _picked.length;
      _status = 'Sorting ${_picked.length} photos...';
    });
    var lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    final result = await runSortPipeline(
      paths: _picked.map((f) => f.path).toList(),
      save: false,
      onProgress: (done, total, skipped) async {
        final now = DateTime.now();
        if (done == total ||
            now.difference(lastUiUpdate).inMilliseconds >= 500) {
          lastUiUpdate = now;
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
              _skipped = skipped;
            });
          }
        }
      },
    );
    if (!mounted) return;
    setState(() {
      _groups = result.groups.map(_groupDataToItemGroup).toList();
      _working = false;
      _status = '${_groups.length} selling folders, ${result.skipped} family photos skipped. '
          'Check names, fix anything wrong, then Save folders.';
    });
  }

  // ---------- saving ----------

  Future<void> _saveFolders() async {
    if (_groups.isEmpty) {
      setState(() => _status = 'Nothing sorted yet.');
      return;
    }
    if (await FlutterForegroundTask.isRunningService) {
      setState(() => _status =
          'A background scan is already running — wait for it to finish, then check the folders.');
      return;
    }
    setState(() {
      _working = true;
      _total = 0;
      _status = 'Saving folders...';
    });
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/Sell');
    var goodCount = 0, poorCount = 0;
    for (final g in _groups) {
      final dir = Directory('${root.path}/${g.name}');
      final poorDir = Directory('${dir.path}/Poor');
      await dir.create(recursive: true);
      if (g.poor.isNotEmpty) await poorDir.create(recursive: true);
      final slug = _slug(g.name);
      for (var i = 0; i < g.good.length; i++) {
        final dest = File(
          '${dir.path}/${slug}_${(i + 1).toString().padLeft(2, '0')}.${_ext(g.good[i].file.path)}',
        );
        if (await dest.exists()) await dest.delete();
        await g.good[i].file.copy(dest.path);
        goodCount++;
      }
      for (var i = 0; i < g.poor.length; i++) {
        final dest = File(
          '${poorDir.path}/${slug}_${(i + 1).toString().padLeft(2, '0')}.${_ext(g.poor[i].file.path)}',
        );
        if (await dest.exists()) await dest.delete();
        await g.poor[i].file.copy(dest.path);
        poorCount++;
      }
    }
    setState(() {
      _working = false;
      _status = 'Saved to ${root.path}: $goodCount good shots, $poorCount poor shots. Originals untouched.';
    });
  }

  // ---------- folder fixes ----------

  Future<void> _rename(ItemGroup g) async {
    final controller = TextEditingController(text: g.name);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename folder'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (next != null && next.isNotEmpty) {
      setState(() => g.name = next);
    }
  }

  void _deleteGroup(ItemGroup g) {
    setState(() {
      _groups.remove(g);
      final unsorted = _groups.firstWhere(
        (x) => x.name == 'Unsorted',
        orElse: () {
          final u = ItemGroup('Unsorted');
          _groups.add(u);
          return u;
        },
      );
      unsorted.good.addAll(g.good);
      unsorted.poor.addAll(g.poor);
    });
  }

  Future<void> _movePhoto(ItemGroup from, PhotoItem photo, bool fromPoor) async {
    final others = _groups.where((g) => g != from).toList();
    if (others.isEmpty) return;
    final ItemGroup? to = await showDialog<ItemGroup>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Move photo to'),
        children: [
          for (final g in others)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g),
              child: Text(g.name),
            ),
        ],
      ),
    );
    if (to == null) return;
    setState(() {
      if (fromPoor) {
        from.poor.remove(photo);
        to.poor.add(photo);
      } else {
        from.good.remove(photo);
        to.good.add(photo);
      }
    });
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sell Sorter')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _working ? null : _pickPhotos,
                  child: const Text('Pick photos'),
                ),
                ElevatedButton(
                  onPressed: _working ? null : _pickAlbum,
                  child: const Text('Pick a phone folder'),
                ),
                ElevatedButton(
                  onPressed: _working ? null : _scanAllInBackground,
                  child: const Text('Scan all photos'),
                ),
                ElevatedButton(
                  onPressed: _working ? null : _groupPhotos,
                  child: const Text('Sort photos'),
                ),
                ElevatedButton(
                  onPressed: _working ? null : _saveFolders,
                  child: const Text('Save folders'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_status),
          ),
          if (_working && _total > 0)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  LinearProgressIndicator(value: _done / _total),
                  const SizedBox(height: 4),
                  Text('$_done / $_total'),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: _groups.length,
              itemBuilder: (ctx, i) {
                final g = _groups[i];
                return Card(
                  child: ListTile(
                    title: Text(g.name),
                    subtitle: Text(
                      '${g.good.length} good · ${g.poor.length} poor',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit),
                          onPressed: () => _rename(g),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () => _deleteGroup(g),
                        ),
                      ],
                    ),
                    onTap: () => Navigator.push(
                      ctx,
                      MaterialPageRoute(
                        builder: (_) => GroupPage(
                          group: g,
                          onChanged: () => setState(() {}),
                          onMove: (photo, fromPoor) =>
                              _movePhoto(g, photo, fromPoor),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class GroupPage extends StatefulWidget {
  const GroupPage({
    super.key,
    required this.group,
    required this.onChanged,
    required this.onMove,
  });

  final ItemGroup group;
  final VoidCallback onChanged;
  final void Function(PhotoItem photo, bool fromPoor) onMove;

  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  Widget _tile(PhotoItem photo, bool fromPoor) {
    return Stack(
      children: [
        GestureDetector(
          onLongPress: () => widget.onMove(photo, fromPoor),
          child: Image.file(photo.file, fit: BoxFit.cover),
        ),
        Positioned(
          right: 2,
          bottom: 2,
          child: CircleAvatar(
            radius: 14,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 16,
              icon: Icon(fromPoor ? Icons.thumb_up : Icons.thumb_down),
              onPressed: () {
                setState(() {
                  if (fromPoor) {
                    widget.group.poor.remove(photo);
                    widget.group.good.add(photo);
                  } else {
                    widget.group.good.remove(photo);
                    widget.group.poor.add(photo);
                  }
                });
                widget.onChanged();
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    return Scaffold(
      appBar: AppBar(title: Text(g.name)),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Tap the thumb to flip a photo between Good and Poor. '
                'Long-press a photo to move it to another folder.',
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('Good', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
              ),
              itemCount: g.good.length,
              itemBuilder: (ctx, i) => _tile(g.good[i], false),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Poor', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
              ),
              itemCount: g.poor.length,
              itemBuilder: (ctx, i) => _tile(g.poor[i], true),
            ),
          ],
        ),
      ),
    );
  }
}
