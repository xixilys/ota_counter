import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'album_format.dart';
import 'album_models.dart';
import 'album_widgets.dart';

// The landing page is one continuous scrapbook page: a compact stats header,
// the latest 場次 as a loose pile of prints, then horizontal member / session
// shelves, then the timeline. Section extents are computed by the same
// functions the page uses for its year-jump offsets, so the jump lands on the
// month the user picked instead of somewhere near it.

const _cardPrintRatio = 0.70; // width / height of a small cover print

Color _stubPaper(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFF3B3423)
    : const Color(0xFFFFF1C9);

Color _stubInk(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFFF4E9D0)
    : const Color(0xFF3C2F19);

Color _stubInkMuted(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFFCDBD9C)
    : const Color(0xFF6B5836);
const _collageStep = 0.82;
const _collageTilt = 14.0;

double albumLandingHeaderExtent(TextScaler scaler) => scaler.scale(46);

double _collagePrintWidth(double innerWidth, int count) {
  final n = count.clamp(1, 5);
  final width = (innerWidth - 8) / (1 + (n - 1) * _collageStep);
  // One or two prints get a larger cap so a sparse latest session still reads
  // as a featured print rather than a lonely thumbnail.
  final cap = n == 1 ? 148.0 : (n == 2 ? 120.0 : 104.0);
  return math.min(cap, math.max(48.0, width));
}

double _collageHeight(double innerWidth, int count) =>
    _collagePrintWidth(innerWidth, count) * 1.46 + _collageTilt;

/// Height of the 「最近一场」 section. Kept generous enough for 1.3x text:
/// the card uses a Spacer at the bottom, so a few spare pixels are invisible.
double albumFeatureExtent({
  required double viewportWidth,
  required TextScaler scaler,
  required int photoCount,
}) {
  final innerWidth = math.max(viewportWidth - 60, 180.0);
  if (photoCount < 3) {
    // Sparse latest session: photo on the left, text on the right, so the
    // member shelf stays above the fold.
    final compactWidth = math.min(150.0, innerWidth * 0.36);
    return math.max(
          _collageHeight(compactWidth, photoCount) + 24.0,
          scaler.scale(178.0),
        ) +
        6;
  }
  return _collageHeight(innerWidth, photoCount) + scaler.scale(150) + 18;
}

double albumMemberStripExtent(TextScaler scaler) =>
    scaler.scale(40) + 232 + scaler.scale(14) + 8;

double albumSessionStripExtent(TextScaler scaler) =>
    scaler.scale(40) + 124 + scaler.scale(20) + 8;

/// One compact line under the app-bar title: 張數 · 活動日 · 成員 · 場次.
class AlbumLandingHeader extends StatelessWidget {
  final AlbumData data;
  final AlbumMemberAlbum? memberAlbum;

  const AlbumLandingHeader({
    super.key,
    required this.data,
    this.memberAlbum,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final scaler = MediaQuery.textScalerOf(context);
    final member = memberAlbum?.member;
    final accent = albumSurfaceAccent(member?.colorHex ?? '', brightness);
    final stats = member == null
        ? '${data.dayCount} 个活动日 · ${data.memberCount} 位成员 · '
            '${data.sessions.length} 个场次'
        : '${albumMemberCountLabel(memberAlbum!.soloCount, memberAlbum!.groupCount)}'
            '${memberAlbum!.latestDay == null ? '' : ' · 最近 ${albumShortDay(memberAlbum!.latestDay)}'}';
    final countLabel = member == null ? data.photoCount : memberAlbum!.total;

    return SizedBox(
      height: albumLandingHeaderExtent(scaler),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Row(
          children: [
            _CountSticker(label: '$countLabel 张', accent: accent),
            const SizedBox(width: 9),
            if (member != null) ...[
              Flexible(
                child: Text(
                  member.displayGroup,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '·',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                stats,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: member == null ? 11.5 : 10.5,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The newest 場次 as a loose pile of 3–5 real prints with tape and tilt.
class AlbumRecentSessionFeature extends StatelessWidget {
  final AlbumSession session;
  final VoidCallback onOpen;

  const AlbumRecentSessionFeature({
    super.key,
    required this.session,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final scaler = MediaQuery.textScalerOf(context);
    final primary = session.members.isEmpty ? null : session.members.first;
    final rawAccent = albumRawAccent(primary?.colorHex ?? '', brightness);
    final accent = albumSurfaceAccent(primary?.colorHex ?? '', brightness);
    final photos = session.photos.take(5).toList(growable: false);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        final height = albumFeatureExtent(
          viewportWidth: viewportWidth,
          scaler: scaler,
          photoCount: photos.length,
        );
        final innerWidth = math.max(viewportWidth - 60, 180.0);
        final compact = photos.length < 3;
        return SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Semantics(
              button: true,
              label: '最近一场，${session.title}，${session.count} 张',
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: onOpen,
                  child: Ink(
                    decoration: BoxDecoration(
                      color: AppTheme.wash(
                        rawAccent,
                        scheme.surface,
                        brightness,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: rawAccent.withValues(
                          alpha: brightness == Brightness.dark ? 0.34 : 0.22,
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: brightness == Brightness.dark ? 0.28 : 0.05,
                          ),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        if (!compact)
                          Positioned(
                            top: 34,
                            right: 9,
                            child: _SparkleMark(
                              size: 16,
                              color: accent.withValues(alpha: 0.30),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                          child: compact
                              ? _CompactFeatureBody(
                                  session: session,
                                  photos:
                                      photos.take(2).toList(growable: false),
                                  innerWidth: innerWidth,
                                  rawAccent: rawAccent,
                                  accent: accent,
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        _WashiTape(
                                          width: 26,
                                          height: 10,
                                          color: accent.withValues(alpha: 0.55),
                                          angle: -0.04,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '最近一场',
                                          style: theme.textTheme.labelLarge
                                              ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                            color: accent,
                                            fontSize: 12,
                                            height: 1.1,
                                          ),
                                        ),
                                        const Spacer(),
                                        _DateStamp(
                                          day: session.day,
                                          accent: accent,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      height: _collageHeight(
                                        innerWidth,
                                        photos.length,
                                      ),
                                      child: _PhotoPile(
                                        photos: photos,
                                        accent: rawAccent,
                                        innerWidth: innerWidth,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      session.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        height: 1.18,
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      [
                                        if (session.subtitle.isNotEmpty)
                                          session.subtitle,
                                        '${session.count} 张',
                                      ].join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 5,
                                      runSpacing: 5,
                                      children: [
                                        for (final member
                                            in session.members.take(3))
                                          _MemberPill(member: member),
                                        if (session.members.length > 3)
                                          _MemberPill(
                                            label:
                                                '+${session.members.length - 3}',
                                            colorHex: primary?.colorHex ?? '',
                                          ),
                                      ],
                                    ),
                                    const Spacer(),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CompactFeatureBody extends StatelessWidget {
  final AlbumSession session;
  final List<AlbumPhoto> photos;
  final double innerWidth;
  final Color rawAccent;
  final Color accent;

  const _CompactFeatureBody({
    required this.session,
    required this.photos,
    required this.innerWidth,
    required this.rawAccent,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final leftWidth = math.min(150.0, innerWidth * 0.36);
    final pileHeight = _collageHeight(leftWidth, photos.length);
    final primary = session.members.isEmpty ? null : session.members.first;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: leftWidth,
          height: pileHeight,
          child: _PhotoPile(
            photos: photos,
            accent: rawAccent,
            innerWidth: leftWidth,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _WashiTape(
                    width: 24,
                    height: 9,
                    color: accent.withValues(alpha: 0.55),
                    angle: -0.04,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '最近一场',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: accent,
                      fontSize: 11.5,
                      height: 1.1,
                    ),
                  ),
                  const Spacer(),
                  _DateStamp(day: session.day, accent: accent),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                session.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.18,
                  fontSize: 15,
                ),
              ),
              if (session.subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  session.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 10.5,
                    height: 1.3,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  for (final member in session.members.take(3))
                    _MemberPill(member: member),
                  if (session.members.length > 3)
                    _MemberPill(
                      label: '+${session.members.length - 3}',
                      colorHex: primary?.colorHex ?? '',
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhotoPile extends StatelessWidget {
  final List<AlbumPhoto> photos;
  final Color accent;
  final double innerWidth;

  const _PhotoPile({
    required this.photos,
    required this.accent,
    required this.innerWidth,
  });

  static const _tilts = [-0.055, 0.035, -0.025, 0.06, -0.04];

  @override
  Widget build(BuildContext context) {
    final n = photos.length;
    if (n == 0) return const SizedBox.shrink();
    final printWidth = _collagePrintWidth(innerWidth, n);
    final printHeight = printWidth * 1.46;
    final step = printWidth * _collageStep;
    final totalWidth = printWidth + (n - 1) * step;
    final start = math.max(0.0, (innerWidth - totalWidth) / 2);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (var i = 0; i < n; i++)
          Positioned(
            left: start + i * step,
            top: i.isEven ? 0 : 8,
            width: printWidth,
            height: printHeight,
            child: Transform.rotate(
              angle: _tilts[i % _tilts.length],
              child: _CollagePrint(
                photo: photos[i],
                accent: accent,
                tape: i == n ~/ 2,
              ),
            ),
          ),
      ],
    );
  }
}

class _CollagePrint extends StatelessWidget {
  final AlbumPhoto photo;
  final Color accent;
  final bool tape;

  const _CollagePrint({
    required this.photo,
    required this.accent,
    this.tape = false,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          decoration: BoxDecoration(
            color: AppTheme.polaroid(brightness),
            borderRadius: BorderRadius.circular(3),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: brightness == Brightness.dark ? 0.38 : 0.16,
                ),
                blurRadius: 7,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(1.5),
                  child: SizedBox.expand(
                    child: AlbumPhotoThumb(
                      photo: photo,
                      cacheWidth: 320,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 13,
                child: Center(
                  child: Container(
                    width: 18,
                    height: 2,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (tape)
          Positioned(
            top: -4,
            left: 14,
            child: _WashiTape(
              width: 38,
              height: 11,
              color: accent.withValues(alpha: 0.55),
              angle: -0.05,
            ),
          ),
      ],
    );
  }
}

/// A horizontal shelf of one polaroid cover per member, sorted by count.
class AlbumMemberStrip extends StatelessWidget {
  final List<AlbumMemberAlbum> members;
  final ValueChanged<AlbumMemberAlbum> onOpenMember;
  final VoidCallback onViewAll;

  const AlbumMemberStrip({
    super.key,
    required this.members,
    required this.onOpenMember,
    required this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final theme = Theme.of(context);
    final accent = AppTheme.readableAccent(
      theme.colorScheme.secondary,
      theme.brightness,
    );

    return SizedBox(
      height: albumMemberStripExtent(scaler),
      child: Column(
        children: [
          _SectionHeader(
            title: '成员',
            caption: '${members.length} 位',
            accent: accent,
            actionLabel: '全部',
            actionKey: const Key('album-members-all'),
            onAction: onViewAll,
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
              physics: const BouncingScrollPhysics(),
              itemCount: members.length,
              separatorBuilder: (context, index) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final album = members[index];
                return SizedBox(
                  width: 132,
                  child: _MemberPolaroidCard(
                    album: album,
                    onTap: () => onOpenMember(album),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _MemberPolaroidCard extends StatelessWidget {
  final AlbumMemberAlbum album;
  final VoidCallback onTap;

  const _MemberPolaroidCard({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final rawAccent = albumRawAccent(album.member.colorHex, brightness);
    final accent = albumSurfaceAccent(album.member.colorHex, brightness);
    final tilt =
        (album.member.key.codeUnits.fold<int>(0, (sum, unit) => sum + unit) %
                5) -
            2;

    return Semantics(
      button: true,
      label: '${album.member.displayName}的切册，${album.total}张',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              color: AppTheme.wash(rawAccent, scheme.surface, brightness),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: rawAccent.withValues(
                  alpha: brightness == Brightness.dark ? 0.34 : 0.22,
                ),
              ),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(9, 10, 9, 8),
                  child: Column(
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, box) {
                            return Transform.rotate(
                              angle: tilt * 0.012,
                              child: _MemberCoverPrint(
                                photo: album.cover,
                                accent: accent,
                                maxWidth: box.maxWidth,
                                maxHeight: box.maxHeight,
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        album.member.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontSize: 13.5,
                          height: 1.15,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        album.member.displayGroup,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 9.5,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        albumMemberCountLabel(
                          album.soloCount,
                          album.groupCount,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: accent,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: _CountSticker(
                    label: '${album.total} 张',
                    accent: accent,
                    compact: true,
                  ),
                ),
                Positioned(
                  top: -2,
                  left: 20,
                  child: _WashiTape(
                    width: 42,
                    height: 11,
                    color: rawAccent.withValues(alpha: 0.54),
                    angle: -0.05,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemberCoverPrint extends StatelessWidget {
  final AlbumPhoto? photo;
  final Color accent;
  final double maxWidth;
  final double maxHeight;

  const _MemberCoverPrint({
    required this.photo,
    required this.accent,
    required this.maxWidth,
    required this.maxHeight,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final heightLimit = maxHeight > 0 ? maxHeight : maxWidth / _cardPrintRatio;
    final width = math.min(maxWidth, heightLimit * _cardPrintRatio);
    return Center(
      child: SizedBox(
        width: width,
        height: width / _cardPrintRatio,
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          decoration: BoxDecoration(
            color: AppTheme.polaroid(brightness),
            borderRadius: BorderRadius.circular(3),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: brightness == Brightness.dark ? 0.35 : 0.12,
                ),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(1.5),
                  child: photo == null
                      ? ColoredBox(
                          color: Color.alphaBlend(
                            accent.withValues(alpha: 0.18),
                            AppTheme.polaroid(brightness),
                          ),
                          child: Center(
                            child: Icon(
                              Icons.photo_camera_outlined,
                              size: 22,
                              color: accent.withValues(alpha: 0.65),
                            ),
                          ),
                        )
                      : SizedBox.expand(
                          child: AlbumPhotoThumb(
                            photo: photo!,
                            cacheWidth: 280,
                            fit: BoxFit.cover,
                          ),
                        ),
                ),
              ),
              SizedBox(
                height: 12,
                child: Center(
                  child: Container(
                    width: 22,
                    height: 2,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A horizontal shelf of ticket-stub session cards.
class AlbumSessionStrip extends StatelessWidget {
  final List<AlbumSession> sessions;
  final ValueChanged<AlbumSession> onOpenSession;
  final VoidCallback onViewAll;

  const AlbumSessionStrip({
    super.key,
    required this.sessions,
    required this.onOpenSession,
    required this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final theme = Theme.of(context);
    final accent = AppTheme.readableAccent(
      theme.colorScheme.secondary,
      theme.brightness,
    );

    return SizedBox(
      height: albumSessionStripExtent(scaler),
      child: Column(
        children: [
          _SectionHeader(
            title: '场次',
            caption: '${sessions.length} 场',
            accent: accent,
            actionLabel: '全部',
            actionKey: const Key('album-sessions-all'),
            onAction: onViewAll,
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
              physics: const BouncingScrollPhysics(),
              itemCount: sessions.length,
              separatorBuilder: (context, index) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final session = sessions[index];
                return SizedBox(
                  width: _SessionTicketCard._width,
                  child: _SessionTicketCard(
                    session: session,
                    onTap: () => onOpenSession(session),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SessionTicketCard extends StatelessWidget {
  final AlbumSession session;
  final VoidCallback onTap;

  const _SessionTicketCard({required this.session, required this.onTap});

  static const double _width = 232;
  static const double _stubWidth = 54;
  static const double _mainWidth = _width - 9 - 8 - 6 - _stubWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final paper = _stubPaper(brightness);
    final ink = _stubInk(brightness);
    final muted = _stubInkMuted(brightness);
    final accent = albumSurfaceAccent(
      session.members.isEmpty ? '' : session.members.first.colorHex,
      brightness,
    );
    final thumbs = session.photos.take(3).toList(growable: false);
    final day = session.day;

    return Semantics(
      button: true,
      label: '${session.title}，${day == null ? '日期不明' : albumShortDay(day)}，'
          '${session.count} 张',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              color: paper,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: brightness == Brightness.dark ? 0.30 : 0.09,
                  ),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(9, 9, 8, 9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 68,
                              child: _StubPhotoFan(photos: thumbs),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 12.5,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              session.members.isEmpty
                                  ? '同框 ${session.count} 张'
                                  : session.members
                                      .take(3)
                                      .map((member) => member.displayName)
                                      .join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: muted,
                                fontSize: 9,
                                height: 1.1,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: _stubWidth,
                        child: _StubTearOff(
                          day: day,
                          count: session.count,
                          accent: accent,
                          ink: ink,
                          muted: muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: -6,
                  right: _width - (9 + _mainWidth + 3) - 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: AppTheme.paper(brightness),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Positioned(
                  bottom: -6,
                  right: _width - (9 + _mainWidth + 3) - 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: AppTheme.paper(brightness),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Positioned(
                  top: 6,
                  bottom: 6,
                  right: _width - (9 + _mainWidth + 3) - 0.5,
                  child: SizedBox(
                    width: 1,
                    child: CustomPaint(
                      painter: _PerforationPainter(
                        color: ink.withValues(alpha: 0.30),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The photos are the hero of the stub: a small fan of portrait prints.
class _StubPhotoFan extends StatelessWidget {
  final List<AlbumPhoto> photos;

  const _StubPhotoFan({required this.photos});

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) {
      return const SizedBox.shrink();
    }
    final width = switch (photos.length) {
      1 => 90.0,
      2 => 62.0,
      _ => 49.0,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < photos.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Transform.rotate(
            angle: i.isEven ? -0.025 : 0.03,
            child: _TicketThumb(photo: photos[i], width: width),
          ),
        ],
      ],
    );
  }
}

class _StubTearOff extends StatelessWidget {
  final DateTime? day;
  final int count;
  final Color accent;
  final Color ink;
  final Color muted;

  const _StubTearOff({
    required this.day,
    required this.count,
    required this.accent,
    required this.ink,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              day == null ? '日期' : '${day!.month}月',
              maxLines: 1,
              style: theme.textTheme.labelSmall?.copyWith(
                color: muted,
                fontSize: 8.5,
                height: 1.05,
              ),
            ),
            if (day == null)
              Text(
                '不明',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  height: 1.1,
                ),
              )
            else ...[
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${day!.day}',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                    height: 1.0,
                  ),
                ),
              ),
              Text(
                albumWeekday(day!),
                maxLines: 1,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: muted,
                  fontSize: 8.5,
                  height: 1.05,
                ),
              ),
            ],
          ],
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: ink.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: ink.withValues(alpha: 0.18)),
          ),
          child: Text(
            '$count 张',
            style: theme.textTheme.labelSmall?.copyWith(
              color: ink,
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ),
      ],
    );
  }
}

class _TicketThumb extends StatelessWidget {
  final AlbumPhoto photo;
  final double width;

  const _TicketThumb({required this.photo, required this.width});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      width: width,
      height: 68,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppTheme.polaroid(brightness),
        borderRadius: BorderRadius.circular(3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: brightness == Brightness.dark ? 0.35 : 0.10,
            ),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1.5),
        child: AlbumPhotoThumb(
          photo: photo,
          cacheWidth: 200,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _PerforationPainter extends CustomPainter {
  final Color color;

  const _PerforationPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2;
    var y = 0.0;
    while (y < size.height) {
      canvas.drawLine(Offset(0, y), Offset(0, y + 4.5), paint);
      y += 8;
    }
  }

  @override
  bool shouldRepaint(covariant _PerforationPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String caption;
  final Color accent;
  final String? actionLabel;
  final Key? actionKey;
  final VoidCallback? onAction;

  const _SectionHeader({
    required this.title,
    required this.caption,
    required this.accent,
    this.actionLabel,
    this.actionKey,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 10, 4),
      child: Row(
        children: [
          _WashiTape(
            width: 24,
            height: 9,
            color: accent.withValues(alpha: 0.48),
            angle: -0.05,
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              height: 1.1,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            caption,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 10,
              height: 1.1,
            ),
          ),
          const Spacer(),
          if (actionLabel != null && onAction != null)
            TextButton(
              key: actionKey,
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: accent,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    actionLabel!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 1),
                  Icon(Icons.chevron_right_rounded, size: 15, color: accent),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CountSticker extends StatelessWidget {
  final String label;
  final Color accent;
  final bool compact;

  const _CountSticker({
    required this.label,
    required this.accent,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final onAccent =
        ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
            ? Colors.white
            : const Color(0xFF241A13);
    return Transform.rotate(
      angle: -0.018,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 8,
          vertical: compact ? 2.5 : 3.5,
        ),
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.8),
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: onAccent,
            fontSize: compact ? 8.5 : 10.5,
            fontWeight: FontWeight.w800,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

class _DateStamp extends StatelessWidget {
  final DateTime? day;
  final Color accent;

  const _DateStamp({required this.day, required this.accent});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (day == null) {
      return Text(
        '日期不明',
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontSize: 10,
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 44, minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.polaroid(theme.brightness),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: accent.withValues(alpha: 0.32)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${day!.month}月',
            style: theme.textTheme.labelSmall?.copyWith(
              color: albumPrintInk(theme.brightness),
              fontSize: 8.5,
              height: 1.05,
            ),
          ),
          Text(
            '${day!.day}',
            style: theme.textTheme.titleSmall?.copyWith(
              color: accent,
              fontWeight: FontWeight.w800,
              fontSize: 15,
              height: 1.05,
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberPill extends StatelessWidget {
  final AlbumMemberRef? member;
  final String? label;
  final String? colorHex;

  const _MemberPill({this.member, this.label, this.colorHex});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final rawAccent =
        albumRawAccent(member?.colorHex ?? colorHex ?? '', brightness);
    final textColor =
        albumSurfaceAccent(member?.colorHex ?? colorHex ?? '', brightness);
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 3, 8, 3),
      decoration: BoxDecoration(
        color: AppTheme.wash(rawAccent, theme.colorScheme.surface, brightness),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: rawAccent.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: rawAccent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            label ?? member?.displayName ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              height: 1.15,
            ),
          ),
        ],
      ),
    );
  }
}

/// Torn-end washi tape: a small rotated strip with a zigzag right edge.
class _WashiTape extends StatelessWidget {
  final double width;
  final double height;
  final Color color;
  final double angle;

  const _WashiTape({
    required this.width,
    required this.height,
    required this.color,
    this.angle = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: CustomPaint(
        size: Size(width, height),
        painter: _WashiTapePainter(color),
      ),
    );
  }
}

class _WashiTapePainter extends CustomPainter {
  final Color color;

  const _WashiTapePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const notch = 3.0;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width - notch, 0);
    for (var x = size.width - notch; x < size.width; x += notch) {
      final next = math.min(x + notch, size.width);
      path
        ..lineTo(next, size.height / 2)
        ..lineTo(x + notch, size.height);
    }
    path
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WashiTapePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _SparkleMark extends StatelessWidget {
  final double size;
  final Color color;

  const _SparkleMark({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
        size: Size.square(size), painter: _SparklePainter(color));
  }
}

class _SparklePainter extends CustomPainter {
  final Color color;

  const _SparklePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), paint);
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), paint);
    canvas.drawLine(
      Offset(c.dx - r * 0.5, c.dy - r * 0.5),
      Offset(c.dx + r * 0.5, c.dy + r * 0.5),
      paint,
    );
    canvas.drawLine(
      Offset(c.dx + r * 0.5, c.dy - r * 0.5),
      Offset(c.dx - r * 0.5, c.dy + r * 0.5),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklePainter oldDelegate) =>
      oldDelegate.color != color;
}
