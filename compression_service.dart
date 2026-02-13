import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';

class CompressionService {
  static Uint8List compress(String text) {
    List<int> bytes = utf8.encode(text);
    List<int> compressed = GZipEncoder().encode(bytes)!;
    return Uint8List.fromList(compressed);
  }

  static String decompress(Uint8List bytes) {
    List<int> decompressed = GZipDecoder().decodeBytes(bytes);
    return utf8.decode(decompressed);
  }
}
