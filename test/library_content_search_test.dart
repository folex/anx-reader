import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';
import 'package:anx_reader/service/ai/tools/input/book_content_search_input.dart';
import 'package:anx_reader/service/ai/tools/library_content_search_tool.dart';
import 'package:anx_reader/service/ai/tools/repository/book_content_search_repository.dart';
import 'package:anx_reader/service/ai/tools/repository/books_repository.dart';
import 'package:anx_reader/service/ai/tools/repository/library_content_search_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class Shelf extends BooksRepository {
  Shelf(this.books);
  final List<Book> books;
  @override
  Future<List<Book>> listAvailableBooks() async => books;
}

class Contents extends BookContentSearchRepository {
  final searched = <int>[];
  final released = <int>[];
  final broken = <int>{};
  @override
  Future<Map<String, dynamic>> search(BookContentSearchInput input) async {
    searched.add(input.bookId);
    if (broken.contains(input.bookId)) throw StateError('Unreadable book');
    return {
      'results': input.bookId.isEven
          ? []
          : [
              {
                'chapterTitle': 'Chapter 1',
                'chapterCfi': 'epubcfi(/6/2)',
                'matches': [
                  {
                    'cfi': 'epubcfi(/6/2!/4/2)',
                    'pre': 'La',
                    'match': input.keyword,
                    'post': 'era intensa.'
                  }
                ]
              },
            ],
      'completed': true,
    };
  }

  @override
  Future<void> releaseBook(int bookId) async => released.add(bookId);
}

Book book(int id, {bool deleted = false}) => Book.mock().copyWith(
    id: id, title: 'Book $id', author: 'Author $id', isDeleted: deleted);

void main() {
  test('searches closed books and returns real book and passage locations',
      () async {
    final contents = Contents();
    final repo = LibraryContentSearchRepository(
      booksRepository:
          Shelf([book(3), book(1), book(2), book(4, deleted: true)]),
      contentRepository: contents,
    );
    final result = await repo.search({'keyword': 'ira'});
    expect(contents.searched, [1, 2, 3]);
    expect(contents.released, [1, 2, 3]);
    expect(result['searchedBookIds'], [1, 2, 3]);
    expect(result['completed'], true);
    expect(result['hasMore'], false);
    final hits = result['results'] as List;
    expect(hits.map((x) => x['bookId']), [1, 3]);
    expect(hits.first['bookTitle'], 'Book 1');
    expect(hits.first['results'][0]['matches'][0]['cfi'], 'epubcfi(/6/2!/4/2)');
    expect(result.toString(), isNot(contains('filePath')));
  });

  test(
      'continuation is explicit and never claims unsearched books have no hits',
      () async {
    final contents = Contents();
    final repo = LibraryContentSearchRepository(
      booksRepository: Shelf([book(7), book(1), book(3)]),
      contentRepository: contents,
    );
    final first = await repo.search({'keyword': 'ira', 'maxBooks': 2});
    expect(first['hasMore'], true);
    expect(first['completed'], false);
    expect(first['nextAfterBookId'], 3);
    expect(first['remainingBooks'], 1);
    final second = await repo.search({
      'keyword': 'ira',
      'maxBooks': 2,
      'afterBookId': first['nextAfterBookId'],
    });
    expect(second['searchedBookIds'], [7]);
    expect(second['completed'], true);
    expect(contents.searched, [1, 3, 7]);
  });

  test('a failed book does not discard other matches or masquerade as no match',
      () async {
    final contents = Contents()..broken.add(2);
    final repo = LibraryContentSearchRepository(
      booksRepository: Shelf([book(1), book(2), book(3)]),
      contentRepository: contents,
    );
    final result = await repo.search({'keyword': 'ira'});
    expect(result['completed'], false);
    expect((result['failures'] as List).single['bookId'], 2);
    expect((result['results'] as List).length, 2);
    expect(contents.released, [1, 2, 3]);
  });

  test('restricts searches to requested IDs and reports unavailable books',
      () async {
    final contents = Contents();
    final repo = LibraryContentSearchRepository(
      booksRepository: Shelf([book(1), book(2), book(3, deleted: true)]),
      contentRepository: contents,
    );
    final result = await repo.search({
      'keyword': 'ira',
      'bookIds': [2, 2, 3, 9]
    });
    expect(contents.searched, [2]);
    expect(result['unavailableBookIds'], [3, 9]);
    expect(result['completed'], false);
  });

  test('rejects invalid input before starting any searches', () async {
    final contents = Contents();
    final repo = LibraryContentSearchRepository(
      booksRepository: Shelf([book(1)]),
      contentRepository: contents,
    );
    for (final input in [
      {'keyword': ' '},
      {'keyword': 'ira', 'maxBooks': 0},
      {'keyword': 'ira', 'afterBookId': -1},
      {'keyword': 'ira', 'bookIds': []},
      {
        'keyword': 'ira',
        'bookIds': [1.2]
      },
    ]) {
      await expectLater(repo.search(input), throwsArgumentError);
    }
    expect(contents.searched, isEmpty);
  });

  test('library tools are available in the book assistant, separate from edits',
      () {
    expect(
        bookAssistantToolIds,
        containsAll([
          'library_content_search',
          'book_content_search',
          'bookshelf_lookup',
        ]));
    expect(readerBookToolIds, isNot(contains('library_content_search')));
    expect(AiToolRegistry.byId('library_content_search'), isNotNull);
    final tool = LibraryContentSearchTool(LibraryContentSearchRepository());
    expect(tool.inputJsonSchema['required'], ['keyword']);
  });
}
