import 'package:flutter/material.dart';

import 'album_models.dart';
import 'album_timeline_layout.dart';
import 'album_widgets.dart';

/// 場次 view: one ticket-like card per event / venue / session, then the
/// photos from that 场次 with the members appearing in them.
class AlbumSessionsView extends StatelessWidget {
  final AlbumData data;
  final void Function(List<AlbumPhoto> photos, int index) onOpenPhoto;

  const AlbumSessionsView({
    super.key,
    required this.data,
    required this.onOpenPhoto,
  });

  @override
  Widget build(BuildContext context) {
    if (data.sessions.isEmpty) {
      return const AlbumEmptyState(
        title: '还没有场次',
        message: '记一笔带有公演、场馆或场次信息的流水，照片就会按场次收好。',
        icon: Icons.confirmation_number_outlined,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = AlbumTimelineLayout(viewportWidth: constraints.maxWidth);
        return CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 4)),
            for (final session in data.sessions)
              ..._sessionSlivers(session, layout),
            const SliverToBoxAdapter(child: SizedBox(height: 108)),
          ],
        );
      },
    );
  }

  List<Widget> _sessionSlivers(
    AlbumSession session,
    AlbumTimelineLayout layout,
  ) {
    return [
      SliverToBoxAdapter(child: AlbumSessionHeader(session: session)),
      SliverPadding(
        padding: const EdgeInsets.symmetric(
          horizontal: AlbumTimelineLayout.horizontalPadding,
        ),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: layout.columns,
            mainAxisSpacing: AlbumTimelineLayout.gridSpacing,
            crossAxisSpacing: AlbumTimelineLayout.gridSpacing,
            childAspectRatio: AlbumTimelineLayout.tileAspectRatio,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final photo = session.photos[index];
              return AlbumPhotoTile(
                photo: photo,
                onTap: () => onOpenPhoto(session.photos, index),
              );
            },
            childCount: session.photos.length,
            addAutomaticKeepAlives: false,
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
    ];
  }
}
