import 'package:better_player/better_player.dart';
import 'package:flutter/material.dart';
import 'package:yt_snatcher/services/download_magager.dart';
import 'package:yt_snatcher/services/youtube-dl.dart';
import 'package:yt_snatcher/services/youtube.dart';
import 'package:yt_snatcher/widgets/downloader_view.dart';

class Home extends StatefulWidget {
  @override
  State<StatefulWidget> createState() {
    return HomeState();
  }
}

class HomeState extends State<Home> with AutomaticKeepAliveClientMixin {
  final _dl = DownloadManager();
  final _ytdl = YoutubeDL();
  bool _initialized = false;
  VideoMeta _meta;
  Downloader _downloader;
  List<Download> _downloads;

  HomeState() {
    if (!_initialized) _init();
    _initialized = true;
  }

  void _init() async {
    print("downloading video...");
    var preDl = await _ytdl.prepare("fad_0eQIlVo").asVideo();
    var downloader = preDl.best();
    setState(() {
      _meta = preDl.video;
      _downloader = downloader;
    });
    var dl = await downloader.download();
    print("downloaded " + dl.meta.filename);
    var videos = await _dl.getVideos();
    var dls = await videos.getDownloads();
    setState(() => _downloads = dls);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_downloads == null) {
      return Center(
        child: DownloaderView(
          downloader: _downloader,
          meta: _meta,
          pending: _meta == null || _downloader == null,
        ),
      );
    }
    return BetterPlayer.file(_downloads[0].mediaFile.path);
  }

  @override
  bool get wantKeepAlive => true;
}
