import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../models/mask_region.dart';
import '../services/history_service.dart';
import '../services/sse_service.dart';

/// 설치 모드 — 카메라는 문에 고정 부착되어 화각이 거의 안 바뀌므로, 이웃집 문을
/// 가릴 영역을 설치 시 한 번 지정해두고 계속 재사용하는 방식(설계 원칙, 상단 문서 참고).
///
/// 실제 픽셀 블러 처리는 이 화면이 아니라 ESP32가 촬영 시점에 수행한다
/// (docs/mask-regions-contract.md). 이 화면은 좌표를 지정해 서버에 저장하는
/// 역할까지만 담당한다.
///
/// 향후 초점 조절 등 다른 설치 단계가 추가될 걸 염두에 두고 단계(step) 기반으로
/// 구성했다 — 지금은 마스킹 캘리브레이션 단계만 있다.
class InstallModeScreen extends StatefulWidget {
  final SSEService sseService;
  final HistoryService historyService;

  const InstallModeScreen({
    super.key,
    required this.sseService,
    required this.historyService,
  });

  @override
  State<InstallModeScreen> createState() => _InstallModeScreenState();
}

enum _Step { intro, draw, preview, done }

class _InstallModeScreenState extends State<InstallModeScreen> {
  static const int _maxRegions = 4;
  static const double _minRegionSize = 0.03;

  _Step _step = _Step.intro;

  bool _loadingImage = true;
  Uint8List? _baseImageBytes;
  double? _imageAspectRatio;

  final List<MaskRegion> _regions = [];
  Rect? _dragRect;
  Offset? _dragStart;

  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _loadBaseImage();
    _loadExistingRegions();
  }

  /// 이력에서 이미지가 있는 가장 최근 이벤트를 찾아 스냅샷을 받아온다.
  /// (이 앱엔 실시간 카메라 프리뷰가 없으므로 "최근 스냅샷"으로 대체 — 안내 문서 참고)
  Future<void> _loadBaseImage() async {
    setState(() {
      _loadingImage = true;
      _baseImageBytes = null;
      _imageAspectRatio = null;
    });

    final history = await widget.historyService.load();
    String? imageFilename;
    for (final e in history) {
      if (e.image != null) {
        imageFilename = e.image;
        break;
      }
    }

    if (imageFilename == null) {
      if (mounted) setState(() => _loadingImage = false);
      return;
    }

    final bytes = await widget.sseService.downloadSnapshot(imageFilename);
    if (bytes == null) {
      if (mounted) setState(() => _loadingImage = false);
      return;
    }

    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final aspectRatio = frame.image.width / frame.image.height;
    frame.image.dispose();

    if (!mounted) return;
    setState(() {
      _baseImageBytes = bytes;
      _imageAspectRatio = aspectRatio;
      _loadingImage = false;
    });
  }

  /// 재설정 진입 시 기존에 저장된 좌표를 불러와 편집할 수 있게 한다.
  Future<void> _loadExistingRegions() async {
    final existing = await widget.sseService.getMaskRegions();
    if (!mounted || existing.isEmpty) return;
    setState(() => _regions.addAll(existing));
  }

  void _goTo(_Step step) {
    setState(() {
      _step = step;
      _saveError = null;
    });
  }

  // ── 영역 드래그 ──────────────────────────────────────────────

  void _onPanStart(DragStartDetails details, Size canvasSize) {
    if (_regions.length >= _maxRegions) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('최대 $_maxRegions개까지 설정할 수 있어요. 기존 영역을 지우고 다시 그려주세요.'),
          backgroundColor: const Color(0xFF3B82F6),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }
    setState(() {
      _dragStart = details.localPosition;
      _dragRect = Rect.fromPoints(details.localPosition, details.localPosition);
    });
  }

  void _onPanUpdate(DragUpdateDetails details, Size canvasSize) {
    if (_dragStart == null) return;
    final clamped = Offset(
      details.localPosition.dx.clamp(0.0, canvasSize.width),
      details.localPosition.dy.clamp(0.0, canvasSize.height),
    );
    setState(() => _dragRect = Rect.fromPoints(_dragStart!, clamped));
  }

  void _onPanEnd(DragEndDetails details, Size canvasSize) {
    final rect = _dragRect;
    _dragStart = null;
    if (rect == null || canvasSize.width == 0 || canvasSize.height == 0) {
      setState(() => _dragRect = null);
      return;
    }

    final region = MaskRegion(
      x: rect.left / canvasSize.width,
      y: rect.top / canvasSize.height,
      width: rect.width / canvasSize.width,
      height: rect.height / canvasSize.height,
    );

    setState(() {
      _dragRect = null;
      if (region.width >= _minRegionSize && region.height >= _minRegionSize) {
        _regions.add(region);
      }
    });
  }

  void _removeRegion(int index) {
    setState(() => _regions.removeAt(index));
  }

  /// 방문자가 서 있을 만한 중앙 영역까지 과도하게 가려졌는지 대략적으로 판단한다.
  /// (실제 방문자 위치를 알 방법이 없으니 화면 중앙부를 대략적인 기준으로 삼는다)
  bool _hasCoverageWarning() {
    const centerZone = Rect.fromLTWH(0.30, 0.15, 0.40, 0.70);
    final centerZoneArea = centerZone.width * centerZone.height;
    double totalArea = 0;
    double centerOverlapArea = 0;

    for (final r in _regions) {
      final rect = Rect.fromLTWH(r.x, r.y, r.width, r.height);
      totalArea += r.width * r.height;
      final overlap = rect.intersect(centerZone);
      if (!overlap.isEmpty) {
        centerOverlapArea += overlap.width * overlap.height;
      }
    }

    final centerCoverage = centerZoneArea == 0 ? 0 : centerOverlapArea / centerZoneArea;
    return centerCoverage > 0.3 || totalArea > 0.5;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final ok = await widget.sseService.saveMaskRegions(_regions);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      _goTo(_Step.done);
    } else {
      setState(() => _saveError = '저장에 실패했어요. 서버 연결을 확인하고 다시 시도해주세요.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A14),
        elevation: 0,
        title: const Text('설치 모드', style: TextStyle(color: Color(0xFFE2E8F0))),
        iconTheme: const IconThemeData(color: Color(0xFFE2E8F0)),
      ),
      body: SafeArea(
        child: switch (_step) {
          _Step.intro => _buildIntroStep(),
          _Step.draw => _buildDrawStep(),
          _Step.preview => _buildPreviewStep(),
          _Step.done => _buildDoneStep(),
        },
      ),
    );
  }

  // ── 1단계: 안내 ──────────────────────────────────────────────

  Widget _buildIntroStep() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.privacy_tip_outlined, size: 48, color: Color(0xFF3B82F6)),
          const SizedBox(height: 20),
          const Text(
            '마주 보는 이웃집 문이 있나요?',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFFE2E8F0)),
          ),
          const SizedBox(height: 12),
          const Text(
            '복도형 구조에서는 카메라 화각에 이웃집 현관이 함께 찍힐 수 있습니다. '
            '이웃의 사생활 보호를 위해 해당 부분을 가리는 것을 권장드립니다. '
            '(법적 의무는 아닙니다)',
            style: TextStyle(fontSize: 15, color: Color(0xFF9CA3AF), height: 1.5),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => _goTo(_Step.draw),
              child: const Text(
                '설정하기',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('건너뛰기', style: TextStyle(fontSize: 16, color: Color(0xFF6B7280))),
            ),
          ),
        ],
      ),
    );
  }

  // ── 2단계: 격자 + 영역 지정 ──────────────────────────────────

  Widget _buildDrawStep() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  '가릴 영역을 드래그해서 선택하세요',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE2E8F0)),
                ),
              ),
              IconButton(
                onPressed: _loadingImage ? null : _loadBaseImage,
                icon: const Icon(Icons.refresh, color: Color(0xFF9CA3AF)),
                tooltip: '최근 스냅샷 다시 불러오기',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '마주 보는 문이 여러 개면 영역을 여러 번 그릴 수 있어요 (최대 $_maxRegions개).',
            style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 16),
          Expanded(child: Center(child: _buildCanvas())),
          const SizedBox(height: 12),
          if (_regions.isNotEmpty) _buildRegionChips(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _goTo(_Step.intro),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: Color(0xFF2A2A3D)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('뒤로', style: TextStyle(color: Color(0xFF9CA3AF))),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF3B82F6),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _baseImageBytes == null ? null : () => _goTo(_Step.preview),
                  child: Text(
                    _regions.isEmpty ? '가릴 영역 없이 계속' : '다음',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    if (_loadingImage) {
      return const CircularProgressIndicator(color: Color(0xFF3B82F6));
    }
    if (_baseImageBytes == null || _imageAspectRatio == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined, size: 40, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            const Text(
              '최근 스냅샷이 없습니다.\n문 앞에서 이벤트가 한 번 감지된 후 다시 시도해주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: _loadBaseImage, child: const Text('다시 불러오기')),
          ],
        ),
      );
    }

    return AspectRatio(
      aspectRatio: _imageAspectRatio!,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
            return GestureDetector(
              onPanStart: (d) => _onPanStart(d, canvasSize),
              onPanUpdate: (d) => _onPanUpdate(d, canvasSize),
              onPanEnd: (d) => _onPanEnd(d, canvasSize),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(_baseImageBytes!, fit: BoxFit.fill),
                  CustomPaint(painter: _GridPainter(), size: Size.infinite),
                  for (final r in _regions)
                    Positioned(
                      left: r.x * canvasSize.width,
                      top: r.y * canvasSize.height,
                      width: r.width * canvasSize.width,
                      height: r.height * canvasSize.height,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF3B82F6).withValues(alpha: 0.25),
                          border: Border.all(color: const Color(0xFF3B82F6), width: 2),
                        ),
                      ),
                    ),
                  if (_dragRect != null)
                    Positioned.fromRect(
                      rect: _dragRect!,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF3B82F6).withValues(alpha: 0.35),
                          border: Border.all(color: const Color(0xFF3B82F6), width: 2),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildRegionChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < _regions.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2535),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2A2A3D)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('영역 ${i + 1}', style: const TextStyle(fontSize: 13, color: Color(0xFFE2E8F0))),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _removeRegion(i),
                  child: const Icon(Icons.close, size: 16, color: Color(0xFF6B7280)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── 3단계: 미리보기 ──────────────────────────────────────────

  Widget _buildPreviewStep() {
    final warning = _hasCoverageWarning();
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '이렇게 가려집니다',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE2E8F0)),
          ),
          const SizedBox(height: 4),
          const Text(
            '실제 기기에서는 촬영 시점에 이 영역이 블러 처리됩니다.',
            style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 16),
          Expanded(child: Center(child: _buildBlurredPreview())),
          if (warning) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFACC15).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFACC15).withValues(alpha: 0.3)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFFACC15)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '선택한 영역이 너무 넓습니다. 방문자 확인이 어려워질 수 있습니다.',
                      style: TextStyle(fontSize: 13, color: Color(0xFFFACC15)),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_saveError != null) ...[
            const SizedBox(height: 12),
            Text(_saveError!, style: const TextStyle(fontSize: 13, color: Color(0xFFEF4444))),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : () => _goTo(_Step.draw),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: Color(0xFF2A2A3D)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('다시 선택', style: TextStyle(color: Color(0xFF9CA3AF))),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF3B82F6),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text(
                          '확인',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBlurredPreview() {
    if (_baseImageBytes == null || _imageAspectRatio == null) {
      return const SizedBox.shrink();
    }
    return AspectRatio(
      aspectRatio: _imageAspectRatio!,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(_baseImageBytes!, fit: BoxFit.fill),
                for (final r in _regions)
                  Positioned(
                    left: r.x * canvasSize.width,
                    top: r.y * canvasSize.height,
                    width: r.width * canvasSize.width,
                    height: r.height * canvasSize.height,
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: Container(color: Colors.black.withValues(alpha: 0.25)),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── 4단계: 완료 ──────────────────────────────────────────────

  Widget _buildDoneStep() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle, size: 56, color: Color(0xFF4ADE80)),
          const SizedBox(height: 20),
          const Text(
            '저장되었습니다',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFFE2E8F0)),
          ),
          const SizedBox(height: 8),
          Text(
            _regions.isEmpty
                ? '가릴 영역 없이 설정을 마쳤습니다.'
                : '${_regions.length}개 영역이 마스킹 설정에 저장됐어요.',
            style: const TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(
                '닫기',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 영역 선택을 돕는 격자 오버레이 (6x4, 순수 시각적 가이드).
class _GridPainter extends CustomPainter {
  static const int _cols = 6;
  static const int _rows = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1;

    for (var i = 1; i < _cols; i++) {
      final x = size.width * i / _cols;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var i = 1; i < _rows; i++) {
      final y = size.height * i / _rows;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
