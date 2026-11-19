/// The shared "切奇手帐" decoration kit.
///
/// Small, theme-aware paper objects used by every page: polaroid prints, washi
/// tape, die-cut stickers, ticket notches, sparkles, section headers and the
/// dot-grid paper backdrop. All colours derive from a member's 応援色 plus the
/// current brightness, and text handed to the widgets keeps WCAG contrast.
///
/// Keep this API stable: other tracks adopt it at merge time.
library;

export 'dream_palette.dart';
export 'dream_section_header.dart';
export 'paper_background.dart';
export 'polaroid_frame.dart';
export 'segmented_strip.dart';
export 'sparkle_mark.dart';
export 'sticker_badge.dart';
export 'ticket_notch_edge.dart';
export 'washi_tape.dart';
