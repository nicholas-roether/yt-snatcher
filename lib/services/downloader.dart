import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:yt_snatcher/services/download_magager.dart';

import 'background.dart';

import 'youtube.dart' as yt;
import 'files.dart' as fs;
import 'muxer.dart' as mx;

class _UnmuxedVideoDownload extends Download {
  File videoFile;
  File audioFile;

  _UnmuxedVideoDownload(DownloadMeta meta, this.videoFile, this.audioFile)
      : super(meta, videoFile);
}

abstract class _DownloadInstructions {
  final String name;
  final String metaJson;
  final String localPath;

  yt.VideoMeta getMeta() => yt.VideoMeta.fromJson(metaJson);

  _DownloadInstructions(this.name, this.metaJson, this.localPath);
}

class _VideoDownloadInstructions extends _DownloadInstructions {
  final yt.MediaInfo video;
  final String videoCodec;
  final yt.MediaInfo audio;
  final String audioCodec;

  _VideoDownloadInstructions({
    @required String name,
    @required String metaJson,
    @required this.video,
    @required this.audio,
    @required this.videoCodec,
    @required this.audioCodec,
    @required String localPath,
  }) : super(name, metaJson, localPath);
}

class _AudioDownloadInstructions extends _DownloadInstructions {
  final yt.MediaInfo media;
  final String codec;

  _AudioDownloadInstructions({
    @required String name,
    @required String metaJson,
    @required this.media,
    @required this.codec,
    @required String localPath,
  }) : super(name, metaJson, localPath);
}

Stream<List<int>> _monitoredStream(
  Stream<List<int>> stream,
  void Function(int) onProgress,
) {
  return stream.asyncMap((packet) {
    onProgress?.call(packet.length);
    return packet;
  });
}

class Downloader {
  static const _NUM_DOWNLOAD_THREADS = 5;
  fs.FileManager _fileManager;
  static final _muxer = mx.Muxer();
  final _musicDownloadTaskPool = TaskPool<_AudioDownloadInstructions, Download>(
    _musicDownloadTask,
    _NUM_DOWNLOAD_THREADS,
  );
  final _videoDownloadTaskPool =
      TaskPool<_VideoDownloadInstructions, _UnmuxedVideoDownload>(
    _videoDownloadTask,
    _NUM_DOWNLOAD_THREADS,
  );

  Downloader([String localPath]) : _fileManager = fs.FileManager(localPath);

  static void _musicDownloadTask(SendPort port) async {
    _AudioDownloadInstructions ins = await Task.getArg(port);
    final fm = fs.FileManager(ins.localPath);
    final youtube = yt.Youtube();
    var filename = "${ins.name}.${ins.codec}";
    var dl = await _createDownload(
      _downloadMusicMeta(ins.name, filename, ins.getMeta(), fm),
      _downloadMusicMedia(
        filename,
        youtube.getStreamFromInfo(ins.media),
        fm,
        (p) => port.send(Task.createEvent(p)),
      ),
    );
    port.send(dl);
  }

  static void _videoDownloadTask(SendPort port) async {
    _VideoDownloadInstructions ins = await Task.getArg(port);
    final fm = fs.FileManager(ins.localPath);
    final youtube = yt.Youtube();
    var filename = _muxedFileName(ins.name);
    var dl = await _createDownload(
      _downloadVideoMeta(ins.name, filename, ins.getMeta(), fm),
      _downloadVideoMedia(
        filename,
        youtube.getStreamFromInfo(ins.video),
        youtube.getStreamFromInfo(ins.audio),
        ins.videoCodec,
        ins.audioCodec,
        fm,
        (p) => port.send(Task.createEvent(p)),
      ),
    );
    port.send(dl);
  }

  static Future<Download> _createDownload(
      Future<File> metaFileFuture, Future<List<File>> mediaFilesFuture) async {
    var files = await Future.wait([metaFileFuture, mediaFilesFuture]);
    var metaFile = files[0] as File;
    var mediaFiles = files[1] as List<File>;
    var meta = DownloadMeta.fromJson(await metaFile.readAsString(), metaFile);
    if (mediaFiles.length == 1)
      return Download(meta, mediaFiles[0]);
    else if (mediaFiles.length == 2)
      return _UnmuxedVideoDownload(meta, mediaFiles[0], mediaFiles[1]);
    return null;
  }

  static String _metaFileName(String name) => "$name.json";
  static String _muxedFileName(String name) => "$name.mp4";

  static Future<List<File>> _downloadMusicMedia(
    String filename,
    Stream<List<int>> media,
    fs.FileManager fileManager, [
    void Function(int) onProgress,
  ]) {
    var audioStream = _monitoredStream(media, onProgress);
    return fileManager
        .streamLocalFile(
          fs.FileManager.MUSIC_PATH,
          filename,
          audioStream,
        )
        .then((f) => [f]);
  }

  static Future<List<File>> _downloadVideoMedia(
    String filename,
    Stream<List<int>> video,
    Stream<List<int>> audio,
    String videoContainer,
    String audioCodec,
    fs.FileManager fileManager, [
    void Function(int) onProgress,
  ]) async {
    var videoStream = _monitoredStream(
      video,
      (p) => onProgress(p),
    );
    var videoFileFuture = fileManager.streamTempFile(
      "video_$filename.$videoContainer",
      videoStream,
    );

    var audioStream = _monitoredStream(
      audio,
      (p) => onProgress(p),
    );
    var audioFileFuture = fileManager.streamTempFile(
      "audio_$filename.$audioCodec",
      audioStream,
    );

    var files = await Future.wait([videoFileFuture, audioFileFuture]);
    if (files.any((f) => f == null)) throw "Failed to get media files";
    return files;

    // var muxedFile = await fileManager.createLocalFile(
    //   fs.FileManager.VIDEO_PATH,
    //   filename,
    // );

    // await _muxer.mux(
    //   files[0].path,
    //   files[1].path,
    //   muxedFile.path,
    //   (p) => onProgress(p, "Processing"),
    // );
    // files.forEach((f) => f.delete());

    // return muxedFile;
  }

  static Future<File> _muxVideoFiles(
    String filename,
    String videoFile,
    String audioFile,
    Function(int) onProgress,
    fs.FileManager fileManager,
  ) async {
    var muxedFile = await fileManager.createLocalFile(
      fs.FileManager.VIDEO_PATH,
      _muxedFileName(filename),
    );

    await _muxer.mux(videoFile, audioFile, muxedFile.path, onProgress);
    File(videoFile).delete();
    File(audioFile).delete();

    return muxedFile;
  }

  static Future<File> _downloadMeta(
    String path,
    String id,
    String mediaFilename,
    yt.VideoMeta meta,
    fs.FileManager fileManager,
  ) {
    var filename = _metaFileName(id);
    var dlMeta = DownloadMeta(
      meta,
      id,
      mediaFilename,
      null,
      DownloadType.MUSIC,
    );
    return fileManager.writeLocalFile(
      path,
      filename,
      dlMeta.toJson(),
    );
  }

  static Future<File> _downloadMusicMeta(
    String id,
    String mediaFilename,
    yt.VideoMeta meta,
    fs.FileManager fileManager,
  ) =>
      _downloadMeta(
          fs.FileManager.MUSIC_META_PATH, id, mediaFilename, meta, fileManager);

  static Future<File> _downloadVideoMeta(
    String id,
    String mediaFilename,
    yt.VideoMeta meta,
    fs.FileManager fileManager,
  ) =>
      _downloadMeta(
        fs.FileManager.VIDEO_META_PATH,
        id,
        mediaFilename,
        meta,
        fileManager,
      );

  Future<Download> downloadMusic(
    String name,
    yt.VideoMeta meta,
    yt.AudioMedia media, [
    void Function(int) onProgress,
  ]) async {
    var ins = _AudioDownloadInstructions(
      codec: media.audioCodec,
      media: media.getInfo(),
      metaJson: meta.toJson(),
      name: name,
      localPath: await _fileManager.getLocalPath(),
    );
    return _musicDownloadTaskPool.doTask(ins, onProgress);
  }

  Future<Download> downloadVideo(
    String name,
    yt.VideoMeta meta,
    yt.VideoMedia video,
    yt.AudioMedia audio, [
    void Function(int, String) onProgress,
  ]) async {
    var ins = _VideoDownloadInstructions(
      audio: audio.getInfo(),
      audioCodec: audio.audioCodec,
      metaJson: meta.toJson(),
      name: name,
      video: video.getInfo(),
      videoCodec: video.container,
      localPath: await _fileManager.getLocalPath(),
    );
    var unmuxed = await _videoDownloadTaskPool
        .doTask(
          ins,
          (p) => onProgress(p, "Loading"),
        )
        .catchError((e) => throw e);
    var muxedFile = await _muxVideoFiles(
      name,
      unmuxed.videoFile.path,
      unmuxed.audioFile.path,
      (p) => onProgress(p, "Processing"),
      _fileManager,
    );
    return Download(unmuxed.meta, muxedFile);
  }
}