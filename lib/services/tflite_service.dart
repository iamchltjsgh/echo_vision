import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../models/event_model.dart';

/// TFLite Vision AI 서비스
/// 스냅샷 이미지를 분석하여 사람/택배/빈화면을 분류합니다.
class TFLiteService {
  bool _isModelLoaded = false;

  /// 모델 로드 여부
  bool get isModelLoaded => _isModelLoaded;

  /// 모델 초기화
  Future<void> init() async {
    try {
      // 실제 모델 파일이 있을 때 활성화
      // _interpreter = await Interpreter.fromAsset('model.tflite');
      _isModelLoaded = false; // 플레이스홀더 모델이므로 false
      debugPrint('TFLite 모델 초기화 (플레이스홀더 모드)');
    } catch (e) {
      debugPrint('TFLite 모델 로드 오류: $e');
      _isModelLoaded = false;
    }
  }

  /// 이미지 분석
  /// 입력: 스냅샷 이미지 바이트
  /// 출력: VisionResult (PERSON / PACKAGE / EMPTY)
  Future<VisionResult> analyzeImage(List<int> imageBytes) async {
    if (!_isModelLoaded) {
      // 모델이 로드되지 않은 경우 기본값 반환
      return VisionResult.person;
    }

    try {
      // 1. 이미지 디코딩
      final image = img.decodeImage(Uint8List.fromList(imageBytes));
      if (image == null) return VisionResult.empty;

      // 2. 224x224 리사이즈
      final resized = img.copyResize(image, width: 224, height: 224);

      // 3. 0~1 정규화 → Float32 배열
      final input = Float32List(224 * 224 * 3);
      int idx = 0;
      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          final pixel = resized.getPixel(x, y);
          input[idx++] = pixel.r / 255.0;
          input[idx++] = pixel.g / 255.0;
          input[idx++] = pixel.b / 255.0;
        }
      }

      // 4. TFLite 추론
      // final output = List.filled(3, 0.0).reshape([1, 3]);
      // _interpreter!.run(input.reshape([1, 224, 224, 3]), output);
      // final results = output[0] as List<double>;

      // 플레이스홀더: 항상 PERSON 반환
      final results = [0.8, 0.1, 0.1]; // [사람, 택배, 빈화면]

      // 5. 결과 해석
      return _interpretResults(results);
    } catch (e) {
      debugPrint('이미지 분석 오류: $e');
      return VisionResult.empty;
    }
  }

  /// 추론 결과 해석
  /// [사람확률, 택배확률, 빈화면확률]
  VisionResult _interpretResults(List<double> results) {
    if (results[0] > 0.7) return VisionResult.person;
    if (results[1] > 0.7) return VisionResult.package;
    return VisionResult.empty;
  }

  /// 리소스 해제
  void dispose() {
    // _interpreter?.close();
  }
}
