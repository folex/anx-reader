import 'package:anx_reader/service/ai/tools/input/book_content_search_input.dart';
import 'book_content_search_repository.dart';
import 'books_repository.dart';

/// Read-only, paginated full-text search using the same renderer as book search.
/// No visible book is opened, and reading positions are never written.
class LibraryContentSearchRepository {
  LibraryContentSearchRepository({
    BooksRepository? booksRepository,
    BookContentSearchRepository? contentRepository,
  })  : _books = booksRepository ?? const BooksRepository(),
        _content = contentRepository ?? BookContentSearchRepository();

  final BooksRepository _books;
  final BookContentSearchRepository _content;

  Future<Map<String, dynamic>> search(Map<String, dynamic> input) async {
    final keyword = input['keyword'];
    if (keyword is! String || keyword.trim().isEmpty || keyword.length > 500) {
      throw ArgumentError('keyword must contain 1-500 characters');
    }
    final maxBooks = _integer(input, 'maxBooks', 5, 1, 10);
    final afterId = _integer(input, 'afterBookId', 0, 0, 2147483647);
    Set<int>? requested;
    if (input.containsKey('bookIds')) {
      final ids = input['bookIds'];
      if (ids is! List ||
          ids.isEmpty ||
          ids.length > 100 ||
          ids.any((id) => id is! int || id <= 0)) {
        throw ArgumentError('bookIds must contain 1-100 positive integer IDs');
      }
      requested = ids.cast<int>().toSet();
    }

    final available = (await _books.listAvailableBooks())
        .where((book) => !book.isDeleted)
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final availableIds = available.map((book) => book.id).toSet();
    final unavailable = requested?.difference(availableIds).toList() ?? <int>[];
    unavailable.sort();
    final selected = available
        .where((book) => requested == null || requested.contains(book.id))
        .toList();
    final remaining = selected.where((book) => book.id > afterId).toList();
    final page = remaining.take(maxBooks).toList();
    final results = <Map<String, dynamic>>[];
    final failures = <Map<String, dynamic>>[];
    final searched = <int>[];
    for (final book in page) {
      try {
        final response = await _content.search(BookContentSearchInput(
          bookId: book.id,
          keyword: keyword.trim(),
          maxResults: 2,
          maxSnippets: 2,
          maxCharacters: 150,
        ));
        searched.add(book.id);
        final matches = response['results'] as List;
        if (matches.isNotEmpty) {
          results.add({
            'bookId': book.id,
            'bookTitle': book.title,
            'author': book.author,
            'results': matches,
          });
        }
        if (response['completed'] != true) {
          failures.add({
            'bookId': book.id,
            'bookTitle': book.title,
            'reason': 'Search did not finish. Retry with book_content_search.'
          });
        }
      } catch (_) {
        failures.add({
          'bookId': book.id,
          'bookTitle': book.title,
          'reason':
              'Could not search this book. Retry with book_content_search; '
                  'image-only scans require OCR.'
        });
      } finally {
        await _content.releaseBook(book.id);
      }
    }
    final hasMore = remaining.length > page.length;
    return {
      'keyword': keyword.trim(),
      'results': results,
      'searchedBookIds': searched,
      'failures': failures,
      'unavailableBookIds': unavailable,
      'totalBooks': selected.length,
      'remainingBooks': remaining.length - page.length,
      'hasMore': hasMore,
      'nextAfterBookId': hasMore ? page.last.id : null,
      'completed': !hasMore && failures.isEmpty && unavailable.isEmpty,
      'coverage': 'This response covers only searchedBookIds. Follow nextAfterBookId '
          'until hasMore=false; retain earlier results and failures. '
          'An empty result is not proof that unsearched or failed books have no matches. '
          'Only text is searched; image-only pages are not OCRed. '
          'Results are capped per book; use book_content_search for more excerpts.',
    };
  }

  int _integer(
      Map<String, dynamic> input, String key, int fallback, int min, int max) {
    final value = input[key] ?? fallback;
    if (value is! int || value < min || value > max) {
      throw ArgumentError('$key must be an integer between $min and $max');
    }
    return value;
  }
}
