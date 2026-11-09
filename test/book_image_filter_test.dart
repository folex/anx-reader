import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:anx_reader/service/reader_edits/book_image_filter.dart';

void main() {
  Uint8List picture() {
    final image = img.Image(width: 2, height: 1, numChannels: 4);
    image.setPixelRgba(0, 0, 255, 255, 255, 255);
    image.setPixelRgba(1, 0, 0, 0, 0, 128);
    return Uint8List.fromList(img.encodePng(image));
  }

  test('dark paper locally swaps paper and ink and keeps alpha', () {
    final source = picture();
    final before = Uint8List.fromList(source);
    final filtered =
        img.decodePng(processBookImage(source, {'preset': 'dark-paper'}))!;
    expect(filtered.getPixel(0, 0).r, lessThan(10));
    expect(filtered.getPixel(1, 0).r, greaterThan(245));
    expect(filtered.getPixel(1, 0).a, 128);
    expect(source, before);
  });
  test('exact replacement changes only chosen color, reset is original pixels',
      () {
    final source = picture();
    final result = img.decodePng(processBookImage(source, {
      'replacements': [
        {'from': '#ffffff', 'to': '#202124', 'tolerance': 0}
      ]
    }))!;
    expect(result.getPixel(0, 0).r, 32);
    expect(result.getPixel(0, 0).g, 33);
    expect(result.getPixel(1, 0).r, 0);
    final original = img.decodePng(processBookImage(source, {}))!;
    expect(original.getPixel(0, 0).r, 255);
    expect(original.getPixel(1, 0).a, 128);
  });
  test('malformed settings and unsupported bytes never produce an asset', () {
    expect(() => processBookImage(picture(), {'contrast': -1}),
        throwsFormatException);
    expect(
        () => processBookImage(picture(), {
              'replacements': [
                {'from': 'red', 'to': '#ffffff'}
              ]
            }),
        throwsFormatException);
    expect(() => processBookImage(Uint8List.fromList([1, 2, 3]), {}),
        throwsFormatException);
  });
}
