import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yt_snatcher/services/files.dart' as fs;
import 'package:yt_snatcher/services/muxer.dart' as mx;
import 'package:yt_snatcher/services/youtube.dart' as yt;

// var download =

class AlreadyExistsException implements Exception {
  String name;

  @override
  String toString() {
    return "The download $name already exists";
  }
}

enum DownloadType { VIDEO, MUSIC }

class DownloadMeta {
  final yt.VideoMeta videoMeta;
  final String id;
  final String filename;
  final File metaFile;
  DownloadType type;
  DateTime downloadDate;
  DateTime watchDate;

  DownloadMeta(
    this.videoMeta,
    this.id,
    this.filename,
    this.metaFile,
    this.type, [
    this.downloadDate,
    this.watchDate,
  ]) {
    if (downloadDate == null) downloadDate = DateTime.now();
    if (watchDate == null) watchDate = downloadDate;
  }

  String toJson() {
    return jsonEncode({
      "videoMeta": videoMeta.toJson(),
      "id": id,
      "filename": filename,
      "type": type.index,
      "downloadDate": downloadDate.millisecondsSinceEpoch,
      "watchDate": watchDate.millisecondsSinceEpoch
    });
  }

  void delete() {
    metaFile?.delete();
  }

  factory DownloadMeta.fromJson(String json, File file) {
    var data = jsonDecode(json);
    return DownloadMeta(
      data["videoMeta"] != null
          ? yt.VideoMeta.fromJson(data["videoMeta"])
          : null,
      data["id"],
      data["filename"],
      file,
      data["type"] != null ? DownloadType.values[data["type"]] : null,
      data["downloadDate"] != null
          ? DateTime.fromMicrosecondsSinceEpoch(data["downloadDate"])
          : null,
      data["watchDate"] != null
          ? DateTime.fromMicrosecondsSinceEpoch(data["watchDate"])
          : null,
    );
  }
}

class Download {
  final DownloadMeta meta;
  final File mediaFile;

  Download(this.meta, this.mediaFile);

  Future<Uint8List> getMedia() async {
    var data = await mediaFile.readAsBytes();
    return data;
  }

  void delete() {
    meta?.delete();
    mediaFile?.delete();
  }
}

class UnknownDownloadException {
  final String id;

  UnknownDownloadException(this.id);

  @override
  String toString() => "The download with id $id does not exist in this set.";
}

abstract class DownloadSet {
  final fs.FileManager _fileManager;
  final List<DownloadMeta> _meta;
  DownloadSet(this._meta, this._fileManager);

  List<String> get ids => _meta.map((e) => e.id).toList();

  Future<Download> getDownload(String id) async {
    var meta = _meta.firstWhere((e) => e.id == id);
    if (meta == null) throw UnknownDownloadException(id);
    var media = await _getMedia(meta.filename);
    return Download(meta, media);
  }

  bool _validateDownload(Download d) =>
      d.mediaFile == null ||
      d.meta == null ||
      d.meta.videoMeta == null ||
      (d.meta.type == DownloadType.VIDEO && !d.mediaFile.path.endsWith(".mp4"));

  Future<List<Download>> getDownloads() async {
    return (await Future.wait(_meta.map((meta) async {
      return Download(meta, await _getMedia(meta.filename));
    }).toList()))
        .where((d) {
      var valid = _validateDownload(d);
      if (valid) d.delete();
      return !valid;
    }).toList();
  }

  Future<File> _getMedia(String filename);
}

class VideoDownloadSet extends DownloadSet {
  VideoDownloadSet(List<DownloadMeta> meta, fs.FileManager fileManager)
      : super(meta, fileManager);

  @override
  Future<File> _getMedia(String filename) async {
    if (filename == null) return null;
    return _fileManager.getVideoFile(filename);
  }
}

class MusicDownloadSet extends DownloadSet {
  MusicDownloadSet(List<DownloadMeta> meta, fs.FileManager fileManager)
      : super(meta, fileManager);

  @override
  Future<File> _getMedia(String filename) {
    if (filename == null) return null;
    return _fileManager.getMusicFile(filename);
  }
}

class DownloadManager {
  var _fileManager = fs.FileManager();
  var _muxer = mx.Muxer();

  static String getFilename(String name, yt.Media media) =>
      "$name.${media.container}";

  void _monitorStreamProgress(
    Stream<List<int>> stream,
    void Function(int) onProgress,
  ) {
    stream.listen((packet) => onProgress?.call(packet.length));
  }

  String _metaFileName(String name) => "$name.json";
  String _muxedFileName(String name) => "$name.mp4";

  Future<File> _downloadMusicMedia(
    String filename,
    yt.AudioMedia media, [
    void Function(int) onProgress,
  ]) {
    var audioStream = media.getStream();
    _monitorStreamProgress(audioStream, onProgress);
    return _fileManager.streamMusicFile(filename, media.getStream());
  }

  Future<File> _downloadVideoMedia(
    String filename,
    yt.VideoMedia video,
    yt.AudioMedia audio, [
    void Function(int) onProgress,
  ]) async {
    var videoStream = video.getStream();
    _monitorStreamProgress(videoStream, onProgress);
    var videoFileFuture = _fileManager.streamTempFile(
        "video_$filename.${video.container}", videoStream);

    var audioStream = audio.getStream();
    _monitorStreamProgress(audioStream, onProgress);
    var audioFileFuture = _fileManager.streamTempFile(
        "audio_$filename.${audio.container}", audioStream);

    var files = await Future.wait([videoFileFuture, audioFileFuture]);

    var muxedFile = await _fileManager.createVideoFile(filename);

    await _muxer.mux(
      files[0].path,
      files[1].path,
      muxedFile.path,
    );

    files.forEach((f) => f.delete());

    return muxedFile;
  }

  Future<File> _downloadMusicMeta(
      String id, String mediaFilename, yt.VideoMeta meta) {
    var filename = _metaFileName(id);
    var dlMeta =
        DownloadMeta(meta, id, mediaFilename, null, DownloadType.MUSIC);
    return _fileManager.writeMusicMetaFile(filename, dlMeta.toJson());
  }

  Future<File> _downloadVideoMeta(
      String id, String mediaFilename, yt.VideoMeta meta) {
    var filename = _metaFileName(id);
    var dlMeta =
        DownloadMeta(meta, id, mediaFilename, null, DownloadType.VIDEO);
    return _fileManager.writeVideoMetaFile(filename, dlMeta.toJson());
  }

  Future<File> _getMusicMeta(String name) =>
      _fileManager.getMusicMetaFile(_metaFileName(name));

  Future<File> _getVideoMeta(String name) =>
      _fileManager.getVideoMetaFile(_metaFileName(name));

  Future<Download> downloadMusic(
    String name,
    yt.VideoMeta meta,
    yt.AudioMedia media, [
    void Function(int) onProgress,
  ]) {
    var filename = "$name.${media.container}";
    return _getDownload(
      _downloadMusicMeta(name, filename, meta),
      _downloadMusicMedia(filename, media, onProgress),
    );
  }

  Future<Download> downloadVideo(
    String name,
    yt.VideoMeta meta,
    yt.VideoMedia video,
    yt.AudioMedia audio, [
    void Function(int) onProgress,
  ]) {
    var filename = _muxedFileName(name);
    return _getDownload(
      _downloadVideoMeta(name, filename, meta),
      _downloadVideoMedia(filename, video, audio, onProgress),
    );
  }

  Future<Download> _getDownload(
    Future<File> metaFileFuture,
    Future<File> mediaFileFuture,
  ) async {
    var files = await Future.wait([metaFileFuture, mediaFileFuture]);
    var meta = DownloadMeta.fromJson(await files[0].readAsString(), files[0]);
    return Download(meta, files[1]);
  }

  Future<List<DownloadMeta>> _getMetaData(List<File> metaFiles) {
    return Future.wait(metaFiles
        .map((e) async => DownloadMeta.fromJson(await e.readAsString(), e))
        .toList());
  }

  Future<VideoDownloadSet> getVideos() async {
    var metaFiles = await _fileManager.getVideoMetaFiles();
    var meta = await _getMetaData(metaFiles);
    return VideoDownloadSet(meta, _fileManager);
  }

  Future<MusicDownloadSet> getMusic() async {
    var metaFiles = await _fileManager.getVideoMetaFiles();
    var meta = await _getMetaData(metaFiles);
    return MusicDownloadSet(meta, _fileManager);
  }
}
