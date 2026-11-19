import 'package:flutter/material.dart';

import '../../widgets/app_page_background.dart';
import 'album_members_view.dart';
import 'album_models.dart';

/// The full 人物 grid. The landing page only shows a horizontal shelf; 「全部」
/// pushes this page, which reuses the existing cover grid unchanged.
class AlbumMembersPage extends StatelessWidget {
  final AlbumData data;
  final ValueChanged<AlbumMemberAlbum> onOpenMember;
  final VoidCallback onOpenSessions;

  const AlbumMembersPage({
    super.key,
    required this.data,
    required this.onOpenMember,
    required this.onOpenSessions,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('成员')),
      body: AppPageBackground(
        child: AlbumMembersView(
          data: data,
          onOpenMember: onOpenMember,
          onShowSessions: onOpenSessions,
        ),
      ),
    );
  }
}
