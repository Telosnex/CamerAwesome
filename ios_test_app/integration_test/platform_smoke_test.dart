// Runs on a device: the native side of the image analysis path, which the
// fork changes on iOS (analysis output as JPEG).

import 'dart:typed_data';

import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('iOS analysis options can select JPEG output', () {
    expect(
      const CupertinoAnalysisOptions.jpeg().outputFormat,
      InputAnalysisImageFormat.jpeg,
    );
  });

  test('native bgra8888 to JPEG conversion returns a JPEG', () async {
    const width = 2;
    const height = 2;
    const bytesPerRow = width * 4;
    final pixels =
        Uint8List.fromList(List<int>.filled(width * height * 4, 0x80));
    final image = AnalysisImageWrapper(
      format: AnalysisImageFormat.bgra8888,
      bytes: pixels,
      width: width,
      height: height,
      planes: [
        PlaneWrapper(
          bytes: pixels,
          bytesPerRow: bytesPerRow,
          bytesPerPixel: 4,
          width: width,
          height: height,
        ),
      ],
    );

    final result = await AnalysisImageUtils().bgra8888toJpeg(image, 90);

    expect(result.format, AnalysisImageFormat.jpeg);
    final bytes = result.bytes!;
    // JPEG files start with the SOI marker FF D8.
    expect(bytes.length, greaterThan(4));
    expect(bytes[0], 0xFF);
    expect(bytes[1], 0xD8);
  });
}
