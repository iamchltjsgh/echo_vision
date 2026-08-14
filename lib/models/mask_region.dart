/// 이웃 프라이버시 마스킹 영역 하나. 이미지 전체를 0.0~1.0으로 정규화한 비율
/// 좌표계를 쓴다 — 실제 촬영 해상도가 바뀌어도 좌표가 그대로 유효하도록.
/// (ESP32가 촬영 시점에 이 좌표를 픽셀 좌표로 환산해 블러 처리한다.
/// docs/mask-regions-contract.md 참고)
class MaskRegion {
  final double x;
  final double y;
  final double width;
  final double height;

  const MaskRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory MaskRegion.fromJson(Map<String, dynamic> json) {
    return MaskRegion(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
}

/// GET /device/mask-regions/status 응답. 설정 화면에서 현재 마스킹 설정 상태를
/// 보여주는 데 쓴다.
class MaskRegionsStatus {
  final bool configured;
  final int regionCount;
  final String? updatedAt;

  const MaskRegionsStatus({
    required this.configured,
    required this.regionCount,
    this.updatedAt,
  });

  factory MaskRegionsStatus.fromJson(Map<String, dynamic> json) {
    return MaskRegionsStatus(
      configured: json['configured'] as bool? ?? false,
      regionCount: (json['region_count'] as num?)?.toInt() ?? 0,
      updatedAt: json['updated_at'] as String?,
    );
  }
}
