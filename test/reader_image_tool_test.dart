import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/ai/tools/reader_image_tool.dart';
import 'package:anx_reader/service/reader_edits/book_image_generation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('missing Image API key does not start a paid generation operation',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        BookImageGenerationConfig.channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(
        BookImageGenerationConfig.channel, null));
    var started = false;
    await expectLater(
        generateBookIllustration('A historical illustration',
            beforeSend: () async {
          started = true;
        }),
        throwsException);
    expect(started, false);
  });
  test('image tools accept typed edits and anchored insertion only', () {
    final image = List.filled(64, 'a').join();
    final edit = parseReaderImageInput({
      'operationId': 'dark-1',
      'imageId': image,
      'target': 'dark',
      'filters': {'preset': 'dark-paper', 'contrast': 1.2}
    }, 'edit');
    expect(edit['action'], 'edit');
    expect(
        () => parseReaderImageInput({
              'operationId': 'x',
              'imageId': '/private/book.jpg',
              'target': 'all'
            }, 'edit'),
        throwsFormatException);
    expect(
        () => parseReaderImageInput({
              'operationId': 'x',
              'imageId': image,
              'target': 'all',
              'filters': {'contrast': 9}
            }, 'edit'),
        throwsFormatException);
    expect(
        () => parseReaderImageInput(
            {'operationId': 'x', 'imageId': 'image_$image', 'quote': 'La ira'},
            'insert'),
        throwsFormatException);
    final insertion = parseReaderImageInput({
      'operationId': 'x',
      'imageId': 'image_$image',
      'quote': 'La ira',
      'contextAfter': 'se fue.'
    }, 'insert');
    expect(insertion['action'], 'insert');
    expect(() => parseReaderImageInput({'path': 'secret'}, 'list'),
        throwsFormatException);
  });
  test('generation result must contain inline bytes, never follow provider URL',
      () {
    expect(
        parseGeneratedBookImageResponse(jsonEncode({
          'data': [
            {
              'b64_json': base64Encode([1, 2, 3])
            }
          ]
        })),
        [1, 2, 3]);
    expect(
        () => parseGeneratedBookImageResponse(jsonEncode({
              'data': [
                {'url': 'https://example.com/private'}
              ]
            })),
        throwsFormatException);
    expect(() => parseGeneratedBookImageResponse(jsonEncode({'data': []})),
        throwsFormatException);
  });
}
