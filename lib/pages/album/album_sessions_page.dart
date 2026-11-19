import 'package:flutter/material.dart';

import '../../widgets/app_page_background.dart';
import 'album_models.dart';
import 'album_sessions_view.dart';

/// The full 場次 list. The landing page shows a horizontal shelf of ticket
/// stubs; 「全部」 pushes this page, which reuses the existing session cards and
/// photo grids.
class AlbumSessionsPage extends StatelessWidget {
  final AlbumData data;
  final void Function(List<AlbumPhoto> photos, int index) onOpenPhoto;

  const AlbumSessionsPage({
    super.key,
    required this.data,
    required this.onOpenPhoto,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('场次')),
      body: AppPageBackground(
        child: AlbumSessionsView(
          data: data,
          onOpenPhoto: onOpenPhoto,
        ),
      ),
    );
  }
}
