import 'package:flutter/cupertino.dart';
import 'package:yt_snatcher/services/youtube.dart';
import 'package:yt_snatcher/widgets/screen.dart';
import 'package:yt_snatcher/widgets/yt-video-info.dart';

class VideoInfoScreen extends StatelessWidget {
  static const ROUTENAME = "/videoInfo";

  @override
  Widget build(BuildContext context) {
    YoutubeVideoMeta video = ModalRoute.of(context).settings.arguments;
    return Screen(
      title: Text("Video Information"),
      content: YTVideoInfo(video),
      showSettings: false,
    );
  }
}