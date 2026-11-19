import 'package:flutter/material.dart';

import '../../widgets/app_page_background.dart';
import 'album_models.dart';
import 'album_timeline_layout.dart';
import 'album_viewer_page.dart';
import 'album_widgets.dart';

/// One 場次 opened from the landing page's feature card or a ticket stub.
class AlbumSessionPage extends StatelessWidget {
  final AlbumSession session;

  const AlbumSessionPage({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final photos = session.photos;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: AppPageBackground(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final layout = AlbumTimelineLayout(
              viewportWidth: constraints.maxWidth,
            );
            return CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 4)),
                SliverToBoxAdapter(
                  child: AlbumSessionHeader(session: session),
                ),
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
                        return AlbumPhotoTile(
                          photo: photos[index],
                          onTap: () => _open(
                            context,
                            photos,
                            index,
                          ),
                        );
                      },
                      childCount: photos.length,
                      addAutomaticKeepAlives: false,
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 108)),
              ],
            );
          },
        ),
      ),
    );
  }

  void _open(BuildContext context, List<AlbumPhoto> photos, int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AlbumViewerPage(
          photos: photos,
          initialIndex: index,
        ),
      ),
    );
  }
}
