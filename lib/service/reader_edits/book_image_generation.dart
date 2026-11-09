import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:anx_reader/service/chatgpt/secure_transport.dart';
import 'epub_edit_store.dart';

class BookImageGenerationConfig {
  const BookImageGenerationConfig(
      {this.apiKey = '', this.model = 'gpt-image-2.5-flare'});
  final String apiKey, model;
  static const channel =
      MethodChannel('com.anxcye.anx_reader/image_generation');
  static Future<BookImageGenerationConfig> read() async {
    final raw = await channel.invokeMethod<String>('read');
    if (raw == null) return const BookImageGenerationConfig();
    final value = jsonDecode(raw) as Map;
    return BookImageGenerationConfig(
        apiKey: value['apiKey'] as String? ?? '',
        model: value['model'] as String? ?? 'gpt-image-2.5-flare');
  }

  Future<void> save() async {
    if (apiKey.length > 2048 ||
        apiKey.contains(RegExp(r'[\r\n]')) ||
        !RegExp(r'^[A-Za-z0-9._-]{1,100}$').hasMatch(model))
      throw const FormatException('Invalid image API configuration');
    if (apiKey.isEmpty) {
      await channel.invokeMethod<void>('clear');
      return;
    }
    await channel.invokeMethod<void>('write', {
      'value': jsonEncode({'apiKey': apiKey, 'model': model})
    });
  }
}

/// Separate Image API key, never the ChatGPT OAuth token. No automatic retries.
Future<Uint8List> generateBookIllustration(String prompt,
    {Future<void> Function()? beforeSend}) async {
  final config = await BookImageGenerationConfig.read();
  if (config.apiKey.isEmpty)
    throw const EpubEditException(
        'Image generation needs a separate API key. Open Assistant menu > Illustrations > Image generation. ChatGPT sign-in does not include image generation.');
  if (prompt.trim().isEmpty || prompt.length > 4000)
    throw const FormatException('Invalid illustration prompt');
  await beforeSend?.call();
  final client = createChatGptHttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  Future<Uint8List> request() async {
    final req = await client
        .postUrl(Uri.https('api.openai.com', '/v1/images/generations'));
    req.followRedirects = false;
    req.headers.contentType = ContentType.json;
    req.headers.set('Authorization', 'Bearer ${config.apiKey}');
    req.write(jsonEncode({
      'model': config.model,
      'prompt': prompt,
      'n': 1,
      'size': '1024x1024',
      'quality': 'medium',
      'output_format': 'png'
    }));
    final response = await req.close();
    final buffer = BytesBuilder(copy: false);
    await for (final part in response) {
      if (buffer.length + part.length > 24 * 1024 * 1024)
        throw const EpubEditException(
            'Generated image response exceeds the size limit.');
      buffer.add(part);
    }
    if (response.statusCode != 200) {
      // Provider error bodies can echo prompts or account details. Keep them private.
      throw EpubEditException(
          'Image API request failed (HTTP ${response.statusCode}). Check its key, model, credits, and permissions. No automatic retry was sent.');
    }
    return parseGeneratedBookImageResponse(utf8.decode(buffer.takeBytes()));
  }

  try {
    return await request().timeout(const Duration(minutes: 3));
  } on EpubEditException {
    rethrow;
  } catch (_) {
    throw const EpubEditException(
        'Image generation was interrupted. Check API usage before retrying; a request may already have been processed.');
  } finally {
    client.close(force: true);
  }
}

Uint8List parseGeneratedBookImageResponse(String raw) {
  if (raw.length > 24 * 1024 * 1024)
    throw const FormatException('Generated image response is too large');
  final json = jsonDecode(raw);
  final data = json is Map ? json['data'] : null;
  if (data is! List ||
      data.length != 1 ||
      data.single is! Map ||
      data.single['b64_json'] is! String)
    throw const FormatException('Image API did not return one inline image');
  final encoded = data.single['b64_json'] as String;
  if (encoded.length > 16 * 1024 * 1024)
    throw const FormatException('Generated image is too large');
  final bytes = base64Decode(encoded);
  if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024)
    throw const FormatException('Generated image is empty or too large');
  return bytes;
}
