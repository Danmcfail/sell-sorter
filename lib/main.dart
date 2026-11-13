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
//    while it runs. Keep the app open until it finishes.
//  - This is uncompiled code. It has to be built on a computer first
//    (see README.md). The first build is the test — send any build
//    error back and it can be fixed.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

void main() => runApp(const SellSorterApp());

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

  // ---------- picking ----------

  Future<void> _pickPhotos() async {
    final files = await ImagePicker().pickMultipleImages();
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
              child: Text('${a.name} (${a.assetCount})'),
            ),
        ],
      ),
    );
    if (album == null) return;
    await _loadAlbum(album);
  }

  /// Loads every photo on the phone (the All Photos / Recents album).
  Future<void> _scanAll() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      setState(() => _status = 'Photo permission not given. Allow it and try again.');
      return;
    }
    final albums = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.image,
    );
    if (albums.isEmpty || !mounted) return;
    await _loadAlbum(albums.first);
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

  // ---------- analysis ----------

  /// Brightness, blur and average colour of a photo, from a small copy.
  ({double brightness, double blur, List<int> color}) _analyze(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return (brightness: 128, blur: 9999, color: [128, 128, 128]);
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
    // Laplacian variance: low values mean a blurry photo.
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
    final variance = lapCount == 0
        ? 0.0
        : (lapSqSum / lapCount) - mean * mean;
    return (
      brightness: count == 0 ? 128 : (0.299 * rSum + 0.587 * gSum + 0.114 * bSum) / count,
      blur: variance,
      color: count == 0
          ? [128, 128, 128]
          : [rSum ~/ count, gSum ~/ count, bSum ~/ count],
    );
  }

  double _colorDistance(List<int> a, List<int> b) {
    final dr = (a[0] - b[0]).toDouble();
    final dg = (a[1] - b[1]).toDouble();
    final db = (a[2] - b[2]).toDouble();
    return math.sqrt(dr * dr + dg * dg + db * db);
  }

  String _title(String label) {
    if (label.isEmpty) return 'Unsorted';
    return label[0].toUpperCase() + label.substring(1);
  }

  /// Labels that mean "there are people in this photo" — not selling.
  static const _peopleWords = {
    'person', 'people', 'face', 'selfie', 'portrait',
    'man', 'woman', 'boy', 'girl', 'baby', 'child', 'family',
  };

  bool _isPeoplePhoto(List<ImageLabel> labels) {
    for (final l in labels) {
      if (l.confidence < 0.5) continue;
      final word = l.label.toLowerCase();
      if (_peopleWords.contains(word)) return true;
    }
    return false;
  }

  Future<void> _groupPhotos() async {
    if (_picked.isEmpty) {
      setState(() => _status = 'No photos picked yet.');
      return;
    }
    setState(() {
      _working = true;
      _done = 0;
      _skipped = 0;
      _total = _picked.length;
      _status = 'Sorting ${_picked.length} photos...';
    });
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
    // label -> list of colour-split subgroups.
    final Map<String, List<ItemGroup>> byLabel = {};
    try {
      for (final file in _picked) {
        // Step 1: is there a person in this photo? If yes, skip it —
        // family photos are not selling photos, and no folder is made.
        bool hasPerson = false;
        List<ImageLabel> labels = [];
        try {
          final input = InputImage.fromFilePath(file.path);
          final faces = await faceDetector.processImage(input);
          if (faces.isNotEmpty) hasPerson = true;
          labels = await labeler.processImage(input);
          if (_isPeoplePhoto(labels)) hasPerson = true;
        } catch (_) {
          // If detection fails, fall through and label it normally.
        }
        if (hasPerson) {
          _skipped++;
          if (mounted) setState(() => _done++);
          continue;
        }
        String label = 'Unsorted';
        if (labels.isNotEmpty) {
          labels.sort((a, b) => b.confidence.compareTo(a.confidence));
          label = labels.first.label;
        }
        final bytes = await file.readAsBytes();
        final info = _analyze(bytes);
        final photo = PhotoItem(
          file: file,
          label: label,
          brightness: info.brightness,
          blur: info.blur,
          color: info.color,
        );
        // Poor shots: too dark, blown out, or blurry.
        photo.poor = info.brightness < 35 || info.brightness > 245 || info.blur < 30;
        final subs = byLabel.putIfAbsent(label, () => []);
        ItemGroup? target;
        for (final g in subs) {
          final ref = g.good.isNotEmpty
              ? g.good.first
              : (g.poor.isNotEmpty ? g.poor.first : null);
          if (ref != null && _colorDistance(ref.color, photo.color) < 70) {
            target = g;
            break;
          }
        }
        target ??= ItemGroup(_title(label));
        if (!subs.contains(target)) subs.add(target);
        if (photo.poor) {
          target.poor.add(photo);
        } else {
          target.good.add(photo);
        }
        if (mounted) setState(() => _done++);
      }
    } finally {
      labeler.close();
      faceDetector.close();
    }
    // Flatten, number duplicate names, sharpest good shots first.
    final List<ItemGroup> groups = [];
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
    groups.sort((a, b) => (b.good.length + b.poor.length)
        .compareTo(a.good.length + a.poor.length));
    setState(() {
      _groups = groups;
      _working = false;
      _status = '${groups.length} selling folders, $_skipped family photos skipped. '
          'Check names, fix anything wrong, then Save folders.';
    });
  }

  // ---------- saving ----------

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

  Future<void> _saveFolders() async {
    if (_groups.isEmpty) {
      setState(() => _status = 'Nothing sorted yet.');
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
                  onPressed: _working ? null : _scanAll,
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
