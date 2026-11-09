import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A reader-owned capability. Model input cannot supply a filesystem path or JS.
class ReaderEditHandlers {
  const ReaderEditHandlers({
    required this.bookId,
    required this.apply,
    required this.context,
    this.images,
  });

  final int bookId;
  final Future<Map<String, dynamic>> Function(
    Map<String, dynamic> input,
    bool Function() requestIsCurrent,
  ) apply;
  final Future<String?> Function() context;
  final Future<Map<String, dynamic>> Function(
      Map<String, dynamic>, bool Function())? images;
}

final readerEditBridgeProvider = StateProvider<ReaderEditHandlers?>(
  (ref) => null,
);
