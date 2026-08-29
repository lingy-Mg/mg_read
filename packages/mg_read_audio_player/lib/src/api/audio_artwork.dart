/// Host-rendered artwork boundary for the audio player.
library;

import 'package:flutter/widgets.dart';

import 'audio_models.dart';

/// Builds artwork without making the package perform network or file I/O.
typedef AudioArtworkBuilder =
    Widget Function(BuildContext context, AudioTrack track);
