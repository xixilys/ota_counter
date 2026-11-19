import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'album_models.dart';
import 'album_widgets.dart';

/// 人物 view: one wash-in-応援色 cover per member, then that member's album.
class AlbumMembersView extends StatelessWidget {
  final AlbumData data;
  final ValueChanged<AlbumMemberAlbum> onOpenMember;
  final VoidCallback onShowSessions;

  const AlbumMembersView({
    super.key,
    required this.data,
    required this.onOpenMember,
    required this.onShowSessions,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final accent = AppTheme.readableAccent(scheme.secondary, brightness);

    if (data.members.isEmpty) {
      return AlbumEmptyState(
        title: data.photos.isEmpty ? '还没有切图' : '还没有人物封面',
        message: data.photos.isEmpty
            ? '批量拍切，或者给流水的切图存一张照片，它们就会自动收进这里。'
            : '这些照片暂时没有归属到成员。多人切和门票场次的照片，去「场次」看更合适。',
        icon: Icons.people_outline_rounded,
        actionLabel: data.photos.isEmpty ? null : '去场次看看',
        onAction: data.photos.isEmpty ? null : onShowSessions,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 560 ? 2 : 3;
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 14, color: accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '每位成员一张封面，点开就是她的切册。',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.72,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final album = data.members[index];
                    return AlbumMemberCover(
                      album: album,
                      onTap: () => onOpenMember(album),
                    );
                  },
                  childCount: data.members.length,
                  addAutomaticKeepAlives: false,
                ),
              ),
            ),
            if (data.unattributedPhotos.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: _UnattributedNote(
                    count: data.unattributedPhotos.length,
                    onShowSessions: onShowSessions,
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 108)),
          ],
        );
      },
    );
  }
}

class _UnattributedNote extends StatelessWidget {
  final int count;
  final VoidCallback onShowSessions;

  const _UnattributedNote({
    required this.count,
    required this.onShowSessions,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.help_outline_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '还有 $count 张照片没有归属成员（多人切或没有登记成员的门票场次）。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: 11.5,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: onShowSessions,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor:
                  AppTheme.readableAccent(scheme.primary, brightness),
            ),
            child: const Text('场次'),
          ),
        ],
      ),
    );
  }
}
