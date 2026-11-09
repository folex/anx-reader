import 'ai_tool_registry.dart';
import 'base_tool.dart';
import 'repository/library_content_search_repository.dart';

class LibraryContentSearchTool
    extends RepositoryTool<Map<String, dynamic>, Map<String, dynamic>> {
  LibraryContentSearchTool(this._repository)
      : super(
          name: 'library_content_search',
          description:
              'Search actual text across the local library, including closed '
              'books, without changing the open book or reading progress. Literal '
              'case-insensitive word/phrase search, not semantic search. Returns book '
              'titles, chapter/page locations, CFI anchors and excerpts. Omit bookIds '
              'to search all books, or use bookshelf_lookup to choose IDs. For a full '
              'library search, repeat with the same keyword/bookIds and returned '
              'nextAfterBookId until hasMore=false. Combine all results and report '
              'failures/partial coverage honestly. Image-only scans need OCR.',
          inputJsonSchema: const {
            'type': 'object',
            'properties': {
              'keyword': {
                'type': 'string',
                'minLength': 1,
                'maxLength': 500,
                'description':
                    'Word or literal phrase to find in the book text.'
              },
              'bookIds': {
                'type': 'array',
                'minItems': 1,
                'maxItems': 100,
                'items': {'type': 'integer', 'minimum': 1},
                'description':
                    'Optional book IDs. Omit to search the entire library.'
              },
              'afterBookId': {
                'type': 'integer',
                'minimum': 0,
                'description':
                    'Continuation: nextAfterBookId from the previous response. Default 0.'
              },
              'maxBooks': {
                'type': 'integer',
                'minimum': 1,
                'maximum': 10,
                'description':
                    'Books per call, default 5. Continue until hasMore=false.'
              },
            },
            'required': ['keyword'],
          },
        );
  final LibraryContentSearchRepository _repository;
  @override
  Map<String, dynamic> parseInput(Map<String, dynamic> json) => json;
  @override
  Future<Map<String, dynamic>> run(Map<String, dynamic> input) =>
      _repository.search(input);
}

final libraryContentSearchToolDefinition = AiToolDefinition(
  id: 'library_content_search',
  displayNameBuilder: (_) => 'Search library text',
  descriptionBuilder: (_) =>
      'Find passages across books, including closed books.',
  build: (context) => LibraryContentSearchTool(
    LibraryContentSearchRepository(
      booksRepository: context.booksRepository,
      contentRepository: context.bookContentSearchRepository,
    ),
  ).tool,
);
