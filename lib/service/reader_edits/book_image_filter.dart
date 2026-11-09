import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

const maxBookImageBytes = 12 * 1024 * 1024;
const maxBookImagePixels = 12 * 1000 * 1000;

Map<String, dynamic> parseBookImageFilters(Map<String, dynamic> input) {
  const fields = {
    'preset',
    'invert',
    'brightness',
    'contrast',
    'saturation',
    'gamma',
    'hue',
    'replacements'
  };
  if (input.keys.any((key) => !fields.contains(key)))
    throw const FormatException('Unknown image adjustment');
  final result = <String, dynamic>{...input};
  if (!['custom', 'dark-paper', 'darken']
      .contains(input['preset'] ?? 'custom')) {
    throw const FormatException('Unknown image preset');
  }
  if (input['invert'] != null && input['invert'] is! bool)
    throw const FormatException('Invalid invert value');
  for (final name in ['brightness', 'contrast', 'saturation', 'gamma', 'hue']) {
    final value = input[name];
    if (value == null) continue;
    final minimum = name == 'hue'
        ? -180
        : name == 'gamma'
            ? .25
            : 0;
    final maximum = name == 'hue'
        ? 180
        : name == 'gamma'
            ? 4
            : 2;
    if (value is! num ||
        !value.isFinite ||
        value < minimum ||
        value > maximum) {
      throw FormatException('Invalid $name adjustment');
    }
  }
  final replacements = input['replacements'];
  if (replacements != null) {
    if (replacements is! List || replacements.length > 8)
      throw const FormatException('Use up to 8 color replacements');
    result['replacements'] = replacements.map((entry) {
      if (entry is! Map ||
          entry.keys.any((key) => !['from', 'to', 'tolerance'].contains(key)))
        throw const FormatException('Invalid color replacement');
      for (final key in ['from', 'to']) {
        if (entry[key] is! String ||
            !RegExp(r'^#[a-fA-F0-9]{6}$').hasMatch(entry[key]))
          throw const FormatException('Colors must use #RRGGBB');
      }
      final tolerance = entry['tolerance'] ?? 0;
      if (tolerance is! num ||
          !tolerance.isFinite ||
          tolerance < 0 ||
          tolerance > 80)
        throw const FormatException('Invalid color tolerance');
      return <String, dynamic>{
        'from': entry['from'],
        'to': entry['to'],
        'tolerance': tolerance
      };
    }).toList();
  }
  return result;
}

/// Pure local raster processing. Call in an isolate, never on the UI thread.
/// Original bytes and transparency are preserved; output is a new PNG asset.
Uint8List processBookImage(Uint8List bytes, Map<String, dynamic> input) {
  final filters = parseBookImageFilters(input);
  if (bytes.isEmpty || bytes.length > maxBookImageBytes)
    throw const FormatException('Image exceeds the 12 MB limit');
  img.Image decoded;
  try {
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > maxBookImagePixels) {
      throw const FormatException(
          'Unsupported image or image exceeds the 12 megapixel limit');
    }
    if (info.numFrames > 1)
      throw const FormatException(
          'Animated images are preserved; local editing supports still images');
    final frame = decoder!.decodeFrame(0);
    if (frame == null) throw const FormatException('Could not decode image');
    decoded = frame;
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('Could not decode image');
  }
  var image = img.bakeOrientation(decoded).convert(numChannels: 4);
  for (final replacement in (filters['replacements'] as List? ?? const [])) {
    final from =
        int.parse((replacement['from'] as String).substring(1), radix: 16);
    final to = int.parse((replacement['to'] as String).substring(1), radix: 16);
    final tolerance = replacement['tolerance'] as num;
    for (final pixel in image) {
      final distance = math.max(
          (pixel.r - ((from >> 16) & 255)).abs(),
          math.max((pixel.g - ((from >> 8) & 255)).abs(),
              (pixel.b - (from & 255)).abs()));
      if (distance <= tolerance)
        pixel.setRgb((to >> 16) & 255, (to >> 8) & 255, to & 255);
    }
  }
  final paper = filters['preset'] == 'dark-paper';
  final invert = filters['invert'] as bool? ?? paper;
  final brightness = filters['brightness'] as num? ??
      (filters['preset'] == 'darken' ? .65 : 1);
  final contrast = filters['contrast'] as num? ?? 1;
  final saturation = filters['saturation'] as num? ?? 1;
  final gamma = filters['gamma'] as num? ?? 1;
  for (final pixel in image) {
    var r = pixel.rNormalized, g = pixel.gNormalized, b = pixel.bNormalized;
    if (invert) {
      r = 1 - r;
      g = 1 - g;
      b = 1 - b;
    }
    r *= brightness;
    g *= brightness;
    b *= brightness;
    final luminance = .2126 * r + .7152 * g + .0722 * b;
    r = luminance + (r - luminance) * saturation;
    g = luminance + (g - luminance) * saturation;
    b = luminance + (b - luminance) * saturation;
    r = math.pow(((r - .5) * contrast + .5).clamp(0, 1), gamma).toDouble();
    g = math.pow(((g - .5) * contrast + .5).clamp(0, 1), gamma).toDouble();
    b = math.pow(((b - .5) * contrast + .5).clamp(0, 1), gamma).toDouble();
    pixel.setRgb((r * 255).round(), (g * 255).round(), (b * 255).round());
  }
  final hue =
      (filters['hue'] as num? ?? (paper && invert ? 180 : 0)) * math.pi / 180;
  if (hue != 0) {
    // Rotation around the neutral gray axis: every row sums to one, so paper
    // and ink retain their luminance even when preserving the source hue.
    final diagonal = (1 + 2 * math.cos(hue)) / 3;
    final left = (1 - math.cos(hue) - math.sqrt(3) * math.sin(hue)) / 3;
    final right = (1 - math.cos(hue) + math.sqrt(3) * math.sin(hue)) / 3;
    for (final pixel in image) {
      final r = pixel.r, g = pixel.g, b = pixel.b;
      pixel.setRgb(
          (r * diagonal + g * left + b * right).round().clamp(0, 255),
          (r * right + g * diagonal + b * left).round().clamp(0, 255),
          (r * left + g * right + b * diagonal).round().clamp(0, 255));
    }
  }
  final result = img.encodePng(image);
  if (result.length > maxBookImageBytes)
    throw const FormatException('Processed image exceeds the 12 MB limit');
  return Uint8List.fromList(result);
}
