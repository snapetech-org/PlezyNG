import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../media/lyrics.dart';
import 'karaoke_formats.dart';
import 'karaoke_midi.dart';
import 'karaoke_models.dart';
import 'karaoke_store.dart';

class KaraokeImportResult {
  final KaraokeTrack track;
  final List<String> warnings;
  const KaraokeImportResult(this.track, this.warnings);
}

/// Staging + digest verification precede publication. Imports never overwrite an
/// existing rendition, even when supplied manifests reuse a package identifier.
class KaraokePackages {
  KaraokePackages(this.store);
  final KaraokeStore store;
  int quotaBytes = 8 * 1024 * 1024 * 1024;
  static const maxPackageBytes = 2 * 1024 * 1024 * 1024;
  static const maxFileBytes = 1024 * 1024 * 1024;
  Future<void> _serial = Future.value();

  Future<KaraokeImportResult> importFiles(List<String> paths) {
    final result = _serial.then((_) => _import(paths));
    _serial = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  Future<KaraokeImportResult> _import(List<String> paths) async {
    if (paths.isEmpty || paths.length > 256) throw const FormatException('Select 1–256 package files');
    final root = await store.directory;
    final stage = await Directory(p.join(root.path, 'staging', const Uuid().v4())).create(recursive: true);
    try {
      if (paths.length == 1 && {'.zip','.plezykaraoke','.plezytake'}.contains(p.extension(paths.first).toLowerCase())) {
        final source = paths.first, target = stage.path;
        await Isolate.run(() => _extract(source, target));
      } else {
        var total = 0;
        final names = <String>{};
        for (final source in paths) {
          final file = File(source), name = _safePath(p.basename(source));
          if (!names.add(name.toLowerCase())) throw const FormatException('Duplicate filename');
          final size = await file.length();
          total += size;
          if (size > maxFileBytes || total > maxPackageBytes) throw const FormatException('Package size limit exceeded');
          await file.copy(p.join(stage.path, name));
        }
      }
      final manifest = File(p.join(stage.path, 'manifest.json'));
      final warnings = <String>[];
      KaraokeTrack track;
      if (await manifest.exists()) {
        if (await manifest.length() > 8 * 1024 * 1024) throw const FormatException('Manifest too large');
        track = KaraokeTrack.fromJson(jsonDecode(await manifest.readAsString()) as Map<String,dynamic>);
        // A portable package cannot inject server identity or credentials.
        if (track.media != null || track.providerId != null) throw const FormatException('Portable packages must contain local assets');
        if (track.chartReviewed) warnings.add('Imported chart review status requires local confirmation');
        track = KaraokeTrack.fromJson(track.toJson()..['chartReviewed'] = false);
      } else {
        final files = await stage.list(recursive: true, followLinks: false).where((f) => f is File).cast<File>().toList();
        final audio = files.where((f) => {'.mp3','.wav','.ogg','.flac','.m4a','.opus','.mp4','.mkv','.webm','.mid','.midi','.kar'}.contains(p.extension(f.path).toLowerCase())).toList();
        if (audio.length != 1) throw const FormatException('Choose one backing audio/video file, or supply a manifest for stems');
        final text = files.where((f) => {'.lrc','.vtt','.ttml','.txt'}.contains(p.extension(f.path).toLowerCase())).toList();
        if (text.length > 1) throw const FormatException('Choose one lyric source, or supply a manifest');
        KaraokeTextImport? parsed;
        if (text.isNotEmpty) {
          if (await text.first.length() > 8 * 1024 * 1024) throw const FormatException('Lyrics too large');
          parsed = KaraokeFormats.parse(await text.first.readAsString(), p.extension(text.first.path));
          warnings.addAll(parsed.warnings);
        }
        if({'.mid','.midi','.kar'}.contains(p.extension(audio.first.path).toLowerCase())) {
          if(await audio.first.length()>16*1024*1024)throw const FormatException('MIDI exceeds 16 MiB');
          parsed=parseKaraokeMidi(await audio.first.readAsBytes());warnings.addAll(parsed.warnings);
        }
        final assets = <KaraokeAsset>[];
        for (final file in files) {
          final ext = p.extension(file.path).toLowerCase();
          final kind = switch (ext) {
            '.mid' || '.midi' || '.kar' => KaraokeAssetKind.midi,
            '.cdg' => KaraokeAssetKind.cdg,
            '.ass' || '.ssa' => KaraokeAssetKind.subtitle,
            '.ttf' || '.otf' => KaraokeAssetKind.font,
            '.mp4' || '.mkv' || '.webm' => KaraokeAssetKind.video,
            '.mp3' || '.wav' || '.ogg' || '.flac' || '.m4a' || '.opus' => KaraokeAssetKind.audio,
            _ => KaraokeAssetKind.original,
          };
          assets.add(KaraokeAsset(path: p.relative(file.path, from: stage.path).split(p.separator).join('/'),
            sha256: (await sha256.bind(file.openRead()).first).toString(), bytes: await file.length(), kind: kind));
        }
        final id = const Uuid().v4();
        final rawYear=parsed?.metadata['YEAR']?.trim() ?? '',year=int.tryParse(rawYear);
        final rawDifficulty=parsed?.metadata['DIFFICULTY']?.trim() ?? '',difficulty=int.tryParse(rawDifficulty);
        if(rawYear.isNotEmpty && (year==null || year<1800 || year>2200))warnings.add('Ignored unsupported year metadata');
        if(rawDifficulty.isNotEmpty && (difficulty==null || difficulty<1 || difficulty>5))warnings.add('Ignored difficulty metadata outside the 1–5 scale');
        track = KaraokeTrack(id: id, songId: id, title: parsed?.metadata['TITLE'] ?? p.basenameWithoutExtension(audio.first.path),
          artist: parsed?.metadata['ARTIST'] ?? '', language: parsed?.metadata['LANGUAGE'] ?? '',
          genre: parsed?.metadata['GENRE'] ?? '', year: year!=null && year>=1800 && year<=2200 ? year : null,
          difficulty: difficulty!=null && difficulty>=1 && difficulty<=5 ? difficulty : null,
          lyrics: parsed?.lyrics ?? const Lyrics(synced: false, lines: []), notes: parsed?.notes ?? const [], assets: assets);
      }
      var total = 0;
      final names = <String>{};
      for (final asset in track.assets) {
        final name = _safePath(asset.path);
        if (!names.add(name.toLowerCase()) || name.toLowerCase() == 'manifest.json') throw const FormatException('Duplicate/reserved package asset');
        final file = File(p.joinAll([stage.path, ...name.split('/')]));
        if (!await file.exists() || await file.length() != asset.bytes ||
            (await sha256.bind(file.openRead()).first).toString() != asset.sha256) throw FormatException('Incomplete or corrupt asset: $name');
        total += asset.bytes;
      }
      // Unlisted archive files cannot consume hidden disk quota or become media.
      await for (final file in stage.list(recursive: true, followLinks: false)) {
        if (file is File && file.path != manifest.path && !names.contains(p.relative(file.path, from: stage.path).split(p.separator).join('/').toLowerCase())) {
          throw const FormatException('Every file must be declared in the package manifest');
        }
      }
      if (total > maxPackageBytes || await diskUsage() + total > quotaBytes) throw const FileSystemException('Karaoke storage quota exceeded');
      if (!track.assets.any((a) => {KaraokeAssetKind.audio,KaraokeAssetKind.instrumental,KaraokeAssetKind.video,KaraokeAssetKind.midi}.contains(a.kind))) {
        throw const FormatException('Package has no backing media');
      }
      final destination = Directory(p.join(root.path, 'packages', track.id));
      if (await destination.exists()) throw const FormatException('Rendition already exists; import an edited rendition with a new ID');
      await manifest.writeAsString(jsonEncode(track.toJson()), flush: true);
      await destination.parent.create(recursive: true);
      await stage.rename(destination.path);
      return KaraokeImportResult(track, warnings);
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  Future<int> diskUsage() async {
    final dir = Directory(p.join((await store.directory).path, 'packages'));
    var total = 0;
    if (await dir.exists()) { await for (final file in dir.list(recursive: true, followLinks: false)) { if (file is File) total += await file.length(); } }
    return total;
  }
  Future<List<String>> verify(KaraokeTrack track) async {
    final failures = <String>[];
    for (final asset in track.assets) {
      final file = await store.asset(track.id, asset.path);
      if (!await file.exists() || await file.length() != asset.bytes || (await sha256.bind(file.openRead()).first).toString() != asset.sha256) failures.add(asset.path);
    }
    return failures;
  }
  Future<void> export(KaraokeTrack track, String destination) async {
    if (track.media != null || track.providerId != null) throw const FormatException('Only local packages can be exported');
    if ((await verify(track)).isNotEmpty) throw const FormatException('Repair missing/corrupt assets before export');
    final manifest = utf8.encode(jsonEncode(track.toJson()));
    final encoder = ZipFileEncoder()..create('$destination.pending');
    try {
      encoder.addArchiveFile(ArchiveFile('manifest.json', manifest.length, manifest));
      for (final a in track.assets) { await encoder.addFile(await store.asset(track.id, a.path), a.path); }
    } finally { await encoder.close(); }
    await File('$destination.pending').rename(destination);
  }
  Future<void> evict(String id, {required Set<String> pinned}) async {
    if (pinned.contains(id)) throw StateError('This rendition is in the current set or performance');
    final manifest = await store.asset(id, 'manifest.json');
    if (await manifest.parent.exists()) await manifest.parent.delete(recursive: true);
  }

  static String _safePath(String name) {
    if (name.length > 512 || name.contains('\\') || name.contains(':') || name.contains('\u0000') || name.startsWith('/') ||
        name.split('/').any((s) => s.isEmpty || s == '.' || s == '..' || s.endsWith('.') || s.endsWith(' ') || RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])($|\.)', caseSensitive: false).hasMatch(s))) {
      throw const FormatException('Unsafe package path');
    }
    return name;
  }
  static void _extract(String source, String destination) {
    if (File(source).lengthSync() > maxPackageBytes) throw const FormatException('Archive too large');
    final input = InputFileStream(source);
    try {
      final directory = ZipDirectory()..read(input);
      if (directory.fileHeaders.length > 512) throw const FormatException('Too many package entries');
      var total = 0;
      final names = <String>{}, spellings = <String,String>{};
      for (final h in directory.fileHeaders) {
        final file = h.file!;
        String normalize(String n) => _safePath(n.endsWith('/') ? n.substring(0,n.length-1) : n);
        final name = normalize(file.filename);
        if (name != normalize(h.filename) || !names.add(name.toLowerCase()) || file.uncompressedSize < 0 || file.uncompressedSize > maxFileBytes ||
            ((h.externalFileAttributes >> 16) & 0xf000) == 0xa000) throw const FormatException('Invalid ZIP entry');
        final parts = name.split('/');
        for (var i=1; i<=parts.length; i++) {
          final prefix=parts.take(i).join('/');
          if (spellings.putIfAbsent(prefix.toLowerCase(), () => prefix) != prefix) throw const FormatException('Conflicting path casing');
        }
        total += file.uncompressedSize;
        if (total > maxPackageBytes) throw const FormatException('Expanded package too large');
      }
      final archive = ZipDecoder().decodeStream(input);
      for (final entry in archive) {
        if (!entry.isFile) continue;
        if (entry.isSymbolicLink) throw const FormatException('Package links are forbidden');
        final file = File(p.joinAll([destination,..._safePath(entry.name).split('/')]));
        file.parent.createSync(recursive: true);
        final output = _PackageOutput(OutputFileStream(file.path), entry.size);
        try { entry.writeContent(output); if(output.length != entry.size) throw const FormatException('Truncated ZIP entry'); }
        finally { output.closeSync(); }
      }
    } finally { input.closeSync(); }
  }
}

class _PackageOutput extends OutputStream {
  _PackageOutput(this.output,this.limit) : super(byteOrder: ByteOrder.littleEndian);
  final OutputFileStream output;
  final int limit;
  @override int get length => output.length;
  @override bool get isOpen => output.isOpen;
  @override void clear() => closeSync();
  @override void flush() => output.flush();
  @override Uint8List subset(int start,[int? end]) => output.subset(start,end);
  @override void writeBytes(List<int> bytes,{int? length}) {
    final count=length ?? bytes.length;
    if(count<0 || count>bytes.length || this.length+count>limit) throw const FormatException('ZIP expansion limit exceeded');
    output.writeBytes(bytes,length:count);
  }
  @override void writeByte(int value) { if(length>=limit) throw const FormatException('ZIP expansion limit exceeded'); output.writeByte(value); }
  @override void writeStream(InputStream stream) {
    while(!stream.isEOS) { final remaining=limit-length; final bytes=stream.readBytes(remaining<65536 ? remaining+1 : 65536).toUint8List(); if(bytes.isEmpty) break; writeBytes(bytes); }
  }
  @override void closeSync() => output.closeSync();
  @override Future<void> close() => output.close();
}
