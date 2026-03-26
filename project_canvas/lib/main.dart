import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';

void main() {
  runApp(const CanvasApp());
}

class CanvasApp extends StatelessWidget {
  const CanvasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Canvas Line Sender',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const CanvasHomePage(),
    );
  }
}

class CanvasHomePage extends StatefulWidget {
  const CanvasHomePage({super.key});

  @override
  State<CanvasHomePage> createState() => _CanvasHomePageState();
}

class _CanvasHomePageState extends State<CanvasHomePage> {
  // ===== 기본 설정값 =====
  // 샘플 간격(px), mm/px 비율, 소켓 기본 연결 정보.
  static const double _defaultStepPx = 10.0;
  static const double _defaultMmPerPx = 1.0;
  static const String _defaultHost = '127.0.0.1';
  static const int _defaultPort = 9000;

  // ===== 그리기 입력 상태 =====
  // 포인터 시작/끝점, 펜 원본 점들, 현재 그리는 중인지 여부.
  Offset? _p0;
  Offset? _p1;
  List<Offset> _rawPoints = <Offset>[];
  bool _isDrawing = false;

  // ===== 변환/샘플링 설정 =====
  // stepPx: 샘플 간격(px), mmPerPx: px -> mm 변환 비율.
  double _stepPx = _defaultStepPx;
  double _mmPerPx = _defaultMmPerPx;

  // ===== 현재 포인트 캐시 =====
  // _pointsPx: 캔버스 좌표, _pointsImage: 이미지 좌표, _pointsMm: 실측(mm) 좌표.
  List<Offset> _pointsPx = <Offset>[];
  List<Offset> _pointsMm = <Offset>[];
  List<Offset> _deltasMm = <Offset>[];
  List<Offset> _pointsImage = <Offset>[];

  // ===== Z (Current) =====
  // ===== Z (현재 선/도형용) =====
  // _pointsMm와 길이를 동기화하여 인덱스로 바로 접근 가능하게 한다.
  List<double> _currentZValues = <double>[]; // _pointsMm와 길이 동기화

  // ===== 스트로크(여러 선) 관리 =====
  // pen/line 등으로 완성된 선들을 모아두는 리스트.
  final List<Stroke> _strokes = <Stroke>[];
  int? _dragStrokeIndex;
  Offset? _dragLast;
  bool _isMoving = false;

  // ===== 선택/이어그리기 상태 =====
  int? _selectedStrokeIndex;

  bool _appendPen = false;
  int? _appendStrokeIndex;

  // ===== 드래그 박스 선택 =====
  bool _selectMode = false;
  bool _isSelecting = false;
  Offset? _selectStart;
  Rect? _selectRect;

  // ===== 스무딩(이동 평균) =====
  int _smoothingWindow = 5;
  int? _smoothingBaseStrokeIndex;

  // ===== 점 편집(Shift+드래그) =====
  bool _isEditingPoint = false;
  int? _editStrokeIndex;
  int? _editSampleIndex;
  int? _editPathIndex;

  // ===== 현재 그리기 모드 =====
  DrawMode _mode = DrawMode.line;

  // ===== 배경 이미지/프레임 =====
  File? _imageFile;
  Size? _imageSize;
  Size? _userFrameMmSize;
  Size? _userFramePxSize;
  double _userFrameScale = 2.3;
  bool _useUserFrameOverride = true;
  Rect? _frameRect;
  final ImagePicker _imagePicker = ImagePicker();

  // ===== UI 입력 컨트롤러 =====
  final TextEditingController _hostController =
      TextEditingController(text: _defaultHost);
  final TextEditingController _portController =
      TextEditingController(text: _defaultPort.toString());
  final TextEditingController _zController = TextEditingController(text: '0.0');
  final TextEditingController _pointCountController =
      TextEditingController(text: '0');
  final TextEditingController _mmPerPxController =
      TextEditingController(text: _defaultMmPerPx.toStringAsFixed(3));
  final TextEditingController _bgWidthController = TextEditingController();
  final TextEditingController _bgHeightController = TextEditingController();

  // ===== 소켓 상태 =====
  Socket? _socket;
  String? _connectedHost;
  int? _connectedPort;
  String _status = 'Ready';

  @override
  void initState() {
    super.initState();
    // 기본 프레임을 A2로 잡아서 박스가 너무 작아 보이지 않게 함.
    // 현재 스케일 기준으로 mm_per_px를 초기화해 길이 표시가 안정적이도록 함.
    _bgWidthController.text = '594.0';
    _bgHeightController.text = '420.0';
    _userFrameMmSize = const Size(594.0, 420.0);
    _userFramePxSize = const Size(594.0, 420.0);
    _mmPerPx = 1.0 / _userFrameScale;
    _mmPerPxController.text = _mmPerPx.toStringAsFixed(3);
    _syncPointCountController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _zController.dispose();
    _pointCountController.dispose();
    _mmPerPxController.dispose();
    _bgWidthController.dispose();
    _bgHeightController.dispose();
    _socket?.destroy();
    super.dispose();
  }

  void _applyMmPerPx() {
    // 사용자가 mm/px 값을 직접 입력해서 적용.
    final value = double.tryParse(_mmPerPxController.text.trim());
    if (value == null || value <= 0) {
      setState(() {
        _status = 'mm_per_px invalid';
      });
      return;
    }
    setState(() {
      _mmPerPx = value;
      _status = 'mm_per_px applied';
    });
  }

  void _applyZToAll() {
    final value = double.tryParse(_zController.text.trim());
    if (value == null) {
      setState(() {
        _status = 'Z invalid';
      });
      return;
    }

    setState(() {
      if (_strokes.isNotEmpty) {
        if (_selectedStrokeIndex != null &&
            _selectedStrokeIndex! >= 0 &&
            _selectedStrokeIndex! < _strokes.length) {
          final stroke = _strokes[_selectedStrokeIndex!];
          stroke.zValues = List<double>.filled(stroke.samples.length, value);
          _status = 'Applied Z to S$_selectedStrokeIndex';
        } else {
          for (final stroke in _strokes) {
            stroke.zValues = List<double>.filled(stroke.samples.length, value);
          }
          _status = 'Applied Z to all strokes';
        }
      } else {
        _currentZValues = List<double>.filled(_pointsMm.length, value);
        _status = 'Applied Z to current points';
      }
    });
  }

  void _applyPointCount() {
    final value = int.tryParse(_pointCountController.text.trim());
    if (value == null || value <= 0) {
      setState(() {
        _status = 'Point count invalid';
      });
      return;
    }

    setState(() {
      if (_selectedStrokeIndex != null &&
          _selectedStrokeIndex! >= 0 &&
          _selectedStrokeIndex! < _strokes.length) {
        _replaceStrokeWithPointCount(_selectedStrokeIndex!, value);
        _status = 'Applied point count to S$_selectedStrokeIndex';
      } else if (_strokes.isNotEmpty) {
        _replaceStrokeWithPointCount(_strokes.length - 1, value);
        _selectedStrokeIndex = _strokes.length - 1;
        _status = 'Applied point count to last stroke';
      } else if (_pointsPx.isNotEmpty) {
        if (_pointsImage.isNotEmpty) {
          _pointsImage = _resamplePolylineByCount(_pointsImage, value);
          _pointsPx = _imagePointsToCanvas(_pointsImage);
        } else {
          _pointsPx = _resamplePolylineByCount(_pointsPx, value);
          _pointsImage =
              _pointsPx.map(_canvasToImageClamped).toList(growable: false);
        }
        _pointsMm = _applyTransform(_pointsImage, _mmPerPx);
        _deltasMm = _buildDeltas(_pointsMm);
        _currentZValues = _syncZList(_currentZValues, _pointsMm.length);
        _status = 'Applied point count to current points';
      } else {
        _status = 'No points to resample';
      }

      _syncPointCountController();
    });
  }

  void _replaceStrokeWithPointCount(int strokeIndex, int pointCount) {
    final stroke = _strokes[strokeIndex];
    final shouldResamplePath = stroke.path.length == stroke.samples.length;
    final nextPath = shouldResamplePath
        ? _resamplePolylineByCount(stroke.path, pointCount)
        : List<Offset>.from(stroke.path);
    final nextSamples = _resamplePolylineByCount(
      shouldResamplePath ? nextPath : stroke.path,
      pointCount,
    );

    final replacement = Stroke(
      path: nextPath,
      samples: nextSamples,
      zValues: _syncZList(stroke.zValues, nextSamples.length),
    )
      ..basePath = List<Offset>.from(nextPath)
      ..baseSamples = List<Offset>.from(nextSamples);

    _strokes[strokeIndex] = replacement;
    if (_smoothingBaseStrokeIndex == strokeIndex) {
      _smoothingBaseStrokeIndex = strokeIndex;
    }
  }

  void _applyBackgroundSize() {
    // 사용자가 입력한 실제 크기(mm)로 프레임 기준을 설정한다.
    // 프레임 확대/축소는 별도의 Frame Scale로 제어.
    if (_frameRect == null) {
      setState(() {
        _status = 'Background size: no frame yet';
      });
      return;
    }
    final widthMm = double.tryParse(_bgWidthController.text.trim());
    final heightMm = double.tryParse(_bgHeightController.text.trim());
    if ((widthMm == null || widthMm <= 0) &&
        (heightMm == null || heightMm <= 0)) {
      setState(() {
        _status = 'Background size: invalid mm';
      });
      return;
    }
    final frame = _frameRect!;
    double? mmPerPx;
    if (widthMm != null && widthMm > 0) {
      mmPerPx = widthMm / frame.width;
    }
    if (heightMm != null && heightMm > 0) {
      final heightMmPerPx = heightMm / frame.height;
      mmPerPx =
          mmPerPx == null ? heightMmPerPx : math.min(mmPerPx, heightMmPerPx);
    }
    if (mmPerPx == null) return;
    setState(() {
      if (widthMm != null &&
          widthMm > 0 &&
          heightMm != null &&
          heightMm > 0) {
        // mm 크기를 그대로 px 기준으로 저장(1:1), 확대/축소는 스케일로 처리.
        _userFrameMmSize = Size(widthMm, heightMm);
        _userFramePxSize = Size(widthMm, heightMm);
      }
      // 스케일 변경 시에도 mm 길이가 안정적으로 보이도록 보정.
      _mmPerPx = 1.0 / _userFrameScale;
      _mmPerPxController.text = _mmPerPx.toStringAsFixed(3);
      _useUserFrameOverride = true;
      _status = 'Background size applied';
    });
  }

  void _setPresetSize(double widthMm, double heightMm) {
    // 표준 용지 프리셋(A/B 시리즈).
    setState(() {
      _bgWidthController.text = widthMm.toStringAsFixed(1);
      _bgHeightController.text = heightMm.toStringAsFixed(1);
    });
    _applyBackgroundSize();
  }

  // ===== 포인터 입력 처리 =====
  // 좌클릭: 그리기, 우클릭: 스트로크 이동, Shift+클릭: 샘플 점 편집.
  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons & kSecondaryMouseButton != 0) {
      _beginMove(event.localPosition);
      return;
    }
    if (_mode == DrawMode.pen && _isShiftPressed()) {
      if (_beginEditPoint(event.localPosition)) {
        return;
      }
    }
    if (_selectMode) {
      setState(() {
        _clearActiveDrawing();
        _isSelecting = true;
        _selectStart = event.localPosition;
        _selectRect = Rect.fromPoints(event.localPosition, event.localPosition);
      });
      return;
    }

    setState(() {
      _isDrawing = true;

      if (_mode == DrawMode.line) {
        final startPos = _clampToFrame(event.localPosition);
        if (_appendPen && _strokes.isNotEmpty) {
          _appendStrokeIndex = _strokes.length - 1;
          final last =
              _strokes.last.path.isNotEmpty ? _strokes.last.path.last : null;
          _p0 = last ?? startPos;
          _p1 = startPos;
        } else {
          _appendStrokeIndex = null;
          _p0 = startPos;
          _p1 = startPos;
        }
      } else {
        if (_mode == DrawMode.pen && _appendPen && _strokes.isNotEmpty) {
          _appendStrokeIndex = _strokes.length - 1;
          final last =
              _strokes.last.path.isNotEmpty ? _strokes.last.path.last : null;
          if (last != null) {
            _rawPoints = <Offset>[last, _clampToFrame(event.localPosition)];
            _p0 = last;
          } else {
            final pos = _clampToFrame(event.localPosition);
            _rawPoints = <Offset>[pos];
            _p0 = pos;
          }
        } else {
          _appendStrokeIndex = null;
          final pos = _clampToFrame(event.localPosition);
          _rawPoints = <Offset>[pos];
          _p0 = pos;
        }
        _p1 = _clampToFrame(event.localPosition);
      }

      _rebuildPoints();
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    // 이동/선택/그리기 상태에 따라 분기 처리.
    if (_isMoving) {
      _updateMove(event.localPosition);
      return;
    }
    if (_isEditingPoint) {
      _updateEditPoint(event.localPosition);
      return;
    }
    if (_isSelecting) {
      setState(() {
        _selectRect = Rect.fromPoints(_selectStart!, event.localPosition);
      });
      return;
    }
    if (!_isDrawing) return;
    setState(() {
      if (_mode == DrawMode.line) {
        _p1 = _clampToFrame(event.localPosition);
      } else {
        final pos = _clampToFrame(event.localPosition);
        _rawPoints.add(pos);
        _p1 = pos;
      }
      _rebuildPoints();
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    // 그리기 종료 시 스트로크 확정 및 Z 리스트 동기화.
    if (_isMoving) {
      _endMove();
      return;
    }
    if (_isEditingPoint) {
      _endEditPoint();
      return;
    }
    if (_isSelecting) {
      final rect = _selectRect;
      setState(() {
        _isSelecting = false;
        _selectStart = null;
        _selectRect = null;
      });
      if (rect != null) {
        _selectStrokeByRect(rect);
      }
      return;
    }
    if (!_isDrawing) return;

    setState(() {
      _isDrawing = false;
      if (_mode == DrawMode.line) {
        _p1 = _clampToFrame(event.localPosition);
      } else {
        final pos = _clampToFrame(event.localPosition);
        _rawPoints.add(pos);
        _p1 = pos;
      }

      _rebuildPoints();

      if (_pointsPx.isNotEmpty) {
        final path = _mode == DrawMode.pen
            ? List<Offset>.from(_rawPoints)
            : List<Offset>.from(_pointsPx);
        final samples = List<Offset>.from(_pointsPx);

        if ((_mode == DrawMode.pen || _mode == DrawMode.line) &&
            _appendPen &&
            _appendStrokeIndex != null) {
          final stroke = _strokes[_appendStrokeIndex!];

          if (stroke.path.isNotEmpty &&
              path.isNotEmpty &&
              stroke.path.last == path.first) {
            path.removeAt(0);
          }
          if (stroke.samples.isNotEmpty &&
              samples.isNotEmpty &&
              stroke.samples.last == samples.first) {
            samples.removeAt(0);
          }

          // ===== Z append: 새로 추가되는 샘플 길이만큼 0.0 채움 =====
          stroke.path.addAll(path);
          stroke.samples.addAll(samples);
          stroke.zValues.addAll(List<double>.filled(samples.length, 0.0));
          _selectedStrokeIndex = _appendStrokeIndex;
        } else {
          _strokes.add(
            Stroke(
              path: path,
              samples: samples,
              zValues: List<double>.filled(samples.length, 0.0),
            ),
          );
          _selectedStrokeIndex = _strokes.length - 1;
        }
        _clearActiveDrawing();
      }
      _appendStrokeIndex = null;
    });
  }

  void _reset() {
    // 전체 상태 초기화(그림/선택/이미지/좌표 모두 리셋).
    setState(() {
      _p0 = null;
      _p1 = null;
      _rawPoints = <Offset>[];
      _pointsPx = <Offset>[];
      _pointsImage = <Offset>[];
      _strokes.clear();
      _dragStrokeIndex = null;
      _dragLast = null;
      _isMoving = false;
      _selectedStrokeIndex = null;
      _appendStrokeIndex = null;
      _isSelecting = false;
      _selectStart = null;
      _selectRect = null;
      _pointsMm = <Offset>[];
      _deltasMm = <Offset>[];
      _currentZValues = <double>[];
      _status = 'Reset';
      _syncPointCountController();
    });
  }

  void _clearCurrentDrawing() {
    setState(() {
      _p0 = null;
      _p1 = null;
      _rawPoints = <Offset>[];
      _pointsPx = <Offset>[];
      _pointsImage = <Offset>[];
      _pointsMm = <Offset>[];
      _deltasMm = <Offset>[];
      _currentZValues = <double>[];
      _appendStrokeIndex = null;
      _isDrawing = false;
      _syncPointCountController();
    });
  }

  void _deleteSelectedOrLast() {
    setState(() {
      if (_strokes.isEmpty) return;
      if (_selectedStrokeIndex != null &&
          _selectedStrokeIndex! >= 0 &&
          _selectedStrokeIndex! < _strokes.length) {
        _strokes.removeAt(_selectedStrokeIndex!);
        if (_strokes.isEmpty) {
          _selectedStrokeIndex = null;
        } else if (_selectedStrokeIndex! >= _strokes.length) {
          _selectedStrokeIndex = _strokes.length - 1;
        }
      } else {
        _strokes.removeLast();
      }
      _clearCurrentDrawing();
      _syncPointCountController();
    });
  }

  Future<void> _pickImage() async {
    // 갤러리에서 이미지 선택 후 배경으로 로드.
    final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    setState(() {
      _imageFile = File(picked.path);
      _imageSize = Size(
        decoded.width.toDouble(),
        decoded.height.toDouble(),
      );
      final name = picked.path.split(Platform.pathSeparator).last;
      _status = 'Image loaded: $name';
    });
  }

  Future<void> _ensureConnected() async {
    // 소켓 연결(호스트/포트 변경 시 재연결).
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (host.isEmpty || port == null) {
      setState(() {
        _status = 'Invalid host or port';
      });
      throw Exception('Invalid host or port');
    }

    if (_socket != null &&
        _connectedHost == host &&
        _connectedPort == port) {
      return;
    }
    if (_socket != null) {
      _socket?.destroy();
      _socket = null;
      _connectedHost = null;
      _connectedPort = null;
    }
    try {
      _status = 'Connecting to $host:$port...';
      setState(() {});
      final socket = await Socket.connect(host, port);
      socket.listen(
        (data) {
          final text = utf8.decode(data).trim();
          if (text.isNotEmpty) {
            setState(() {
              _status = 'Server: $text';
            });
          }
        },
        onError: (error) {
          setState(() {
            _status = 'Socket error: $error';
          });
        },
        onDone: () {
          setState(() {
            _status = 'Disconnected';
            _socket = null;
          });
        },
      );
      _socket = socket;
      _connectedHost = host;
      _connectedPort = port;
      setState(() {
        _status = 'Connected to $host:$port';
      });
    } catch (error) {
      setState(() {
        _status = 'Connect failed: $error';
      });
      rethrow;
    }
  }

//////////////////////////////////////////////////////////////////////////////////////////////////
  Future<void> _sendJson() async {
    // 현재 그려진 포인트(또는 스트로크)를 JSON으로 직렬화해서 소켓 전송.
    if (_strokes.isEmpty) {
      if ((_mode == DrawMode.line ||
              _mode == DrawMode.circle ||
              _mode == DrawMode.rect) &&
          (_p0 == null || _p1 == null)) {
        setState(() {
          _status = 'No line to send';
        });
        return;
      }
      if (_mode == DrawMode.pen && _rawPoints.length < 2) {
        setState(() {
          _status = 'No stroke to send';
        });
        return;
      }
    }
    try {
      await _ensureConnected();
      final payload = _buildPayload();
      final jsonText = jsonEncode(payload);
      _socket?.write('$jsonText\n');
      await _socket?.flush();
      setState(() {
        _status = 'Sent ${_payloadPointCount()} points';
      });
    } catch (error) {
      setState(() {
        _status = 'Send failed: $error';
      });
    }
  }

///////////////////////////////////////////Json////////////////////////////////////////////////////////////////////////
  // ✅ payload는 "표에 선택된 대상(Current 또는 Stroke)" 기준으로 보냄
  //    points: [[x,y,z], ...]
  Map<String, dynamic> _buildPayload() {
    // Stroke가 있으면 각 스트로크를 이어서 보내고,
    // 스트로크 끝에 ["000"] 마커를 추가한다.
    final allPoints = <List<dynamic>>[];

    if (_strokes.isEmpty) {
      final zList = _syncZList(_currentZValues, _pointsMm.length);
      for (var i = 0; i < _pointsMm.length; i++) {
        final p = _pointsMm[i];
        final z = zList[i];
        allPoints.add(<double>[
          double.parse(p.dx.toStringAsFixed(2)),
          double.parse(p.dy.toStringAsFixed(2)),
          double.parse(z.toStringAsFixed(2)),
        ]);
      }
      return <String, dynamic>{'points': allPoints};
    }

    for (final stroke in _strokes) {
      final imagePoints =
          stroke.samples.map(_canvasToImageClamped).toList(growable: false);
      final pointsMm = _applyTransform(imagePoints, _mmPerPx);
      stroke.zValues = _syncZList(stroke.zValues, pointsMm.length);
      for (var i = 0; i < pointsMm.length; i++) {
        final p = pointsMm[i];
        final z = stroke.zValues[i];
        allPoints.add(<dynamic>[
          double.parse(p.dx.toStringAsFixed(2)),
          double.parse(p.dy.toStringAsFixed(2)),
          double.parse(z.toStringAsFixed(2)),
        ]);
      }
      // 스트로크 끝 마커: "000"
      allPoints.add(<dynamic>["000"]);
    }

    return <String, dynamic>{'points': allPoints};
  }

  int _payloadPointCount() {
    // 전송될 포인트 개수 계산(스트로크 끝 마커 포함).
    if (_strokes.isEmpty) return _pointsMm.length;
    var count = 0;
    for (final stroke in _strokes) {
      count += stroke.samples.length;
      count += 1; // 스트로크 끝 마커 ["000"]
    }
    return count;
  }

  Map<String, double> _pointToMap(Offset p) {
    return <String, double>{'x': p.dx, 'y': p.dy};
  }

  Map<String, double> _deltaToMap(Offset d) {
    return <String, double>{'dx': d.dx, 'dy': d.dy};
  }

  // Z 리스트 길이 동기화(부족하면 0 채움)
  List<double> _syncZList(List<double> source, int length) {
    // Z 리스트 길이 동기화(부족하면 0.0으로 채움).
    final list = List<double>.from(source);
    if (list.length < length) {
      list.addAll(List<double>.filled(length - list.length, 0.0));
    } else if (list.length > length) {
      list.removeRange(length, list.length);
    }
    return list;
  }

  List<Offset> _resamplePolylineByCount(List<Offset> input, int pointCount) {
    if (input.isEmpty) return <Offset>[];
    if (pointCount <= 1) return <Offset>[input.first];
    if (input.length == 1) {
      return List<Offset>.filled(pointCount, input.first);
    }

    final cumulative = <double>[0.0];
    var total = 0.0;
    for (var i = 1; i < input.length; i++) {
      total += (input[i] - input[i - 1]).distance;
      cumulative.add(total);
    }

    if (total == 0.0) {
      return List<Offset>.filled(pointCount, input.first);
    }

    final result = <Offset>[];
    var segmentIndex = 1;

    for (var i = 0; i < pointCount; i++) {
      final target = total * i / (pointCount - 1);
      while (segmentIndex < cumulative.length - 1 &&
          cumulative[segmentIndex] < target) {
        segmentIndex++;
      }

      final start = input[segmentIndex - 1];
      final end = input[segmentIndex];
      final startDistance = cumulative[segmentIndex - 1];
      final endDistance = cumulative[segmentIndex];
      final segmentLength = endDistance - startDistance;

      if (segmentLength == 0.0) {
        result.add(start);
        continue;
      }

      final t = (target - startDistance) / segmentLength;
      result.add(Offset(
        start.dx + (end.dx - start.dx) * t,
        start.dy + (end.dy - start.dy) * t,
      ));
    }

    return result;
  }

  void _syncPointCountController() {
    int count = 0;
    if (_selectedStrokeIndex != null &&
        _selectedStrokeIndex! >= 0 &&
        _selectedStrokeIndex! < _strokes.length) {
      count = _strokes[_selectedStrokeIndex!].samples.length;
    } else if (_pointsPx.isNotEmpty) {
      count = _pointsPx.length;
    } else if (_strokes.isNotEmpty) {
      count = _strokes.last.samples.length;
    }

    final text = count.toString();
    if (_pointCountController.text == text) return;
    _pointCountController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  int _displayPointCount() {
    if (_selectedStrokeIndex != null &&
        _selectedStrokeIndex! >= 0 &&
        _selectedStrokeIndex! < _strokes.length) {
      return _strokes[_selectedStrokeIndex!].samples.length;
    }
    return _pointsPx.length;
  }

/////////////////////////////////////////////////////////////////////////////////////////////////////
  void _rebuildPoints() {
    // 현재 모드에 맞는 포인트를 다시 생성하고
    // 이미지 좌표 -> 캔버스 좌표 -> mm 좌표까지 동기화한다.
    if ((_mode == DrawMode.line ||
            _mode == DrawMode.circle ||
            _mode == DrawMode.rect) &&
        (_p0 == null || _p1 == null)) {
      _pointsPx = <Offset>[];
      _pointsImage = <Offset>[];
      _pointsMm = <Offset>[];
      _deltasMm = <Offset>[];
      _currentZValues = <double>[];
      _syncPointCountController();
      return;
    }

    List<Offset> points;
    List<Offset> pointsImage;

    if (_mode == DrawMode.line) {
      final p0 = _p0!;
      final p1 = _p1!;
      final p0Image = _canvasToImageClamped(p0);
      final p1Image = _canvasToImageClamped(p1);
      final length = (p1Image - p0Image).distance;
      final n = length == 0 ? 0 : (length / _stepPx).ceil();

      final linePointsImage = <Offset>[];
      for (var i = 0; i <= n; i++) {
        final t = n == 0 ? 0.0 : i / n;
        linePointsImage.add(Offset(
          p0Image.dx + t * (p1Image.dx - p0Image.dx),
          p0Image.dy + t * (p1Image.dy - p0Image.dy),
        ));
      }
      pointsImage = linePointsImage;
      points = _imagePointsToCanvas(pointsImage);
    } else if (_mode == DrawMode.circle) {
      final p0Image = _canvasToImageClamped(_p0!);
      final p1Image = _canvasToImageClamped(_p1!);
      pointsImage = _circlePoints(p0Image, p1Image, _stepPx);
      points = _imagePointsToCanvas(pointsImage);
    } else if (_mode == DrawMode.rect) {
      final p0Image = _canvasToImageClamped(_p0!);
      final p1Image = _canvasToImageClamped(_p1!);
      pointsImage = _rectPoints(p0Image, p1Image, _stepPx);
      points = _imagePointsToCanvas(pointsImage);
    } else {
      final rawImage =
          _rawPoints.map(_canvasToImageClamped).toList(growable: false);
      pointsImage = _resamplePolyline(rawImage, _stepPx);
      points = _imagePointsToCanvas(pointsImage);
    }

    _pointsPx = points;
    _pointsImage = pointsImage;

    if (pointsImage.isEmpty) {
      _pointsMm = <Offset>[];
      _deltasMm = <Offset>[];
      _currentZValues = <double>[];
      _syncPointCountController();
      return;
    }

    _pointsMm = _applyTransform(pointsImage, _mmPerPx);
    _deltasMm = _buildDeltas(_pointsMm);

    // ✅ Current Z 길이 동기화(기본 0)
    _currentZValues = _syncZList(_currentZValues, _pointsMm.length);
    _syncPointCountController();
  }

  List<Offset> _toRelativePoints(List<Offset> points, Offset origin) {
    return points
        .map((p) => Offset(p.dx - origin.dx, p.dy - origin.dy))
        .toList();
  }

  List<Offset> _applyTransform(List<Offset> points, double scale) {
    // mm 스케일 적용 + (필요 시) Y 플립/회전.
    const bool yFlip = false;
    const double rotationDeg = 0.0;

    final theta = rotationDeg * math.pi / 180.0;
    final cosT = math.cos(theta);
    final sinT = math.sin(theta);

    return points.map((p) {
      var x = p.dx * scale;
      var y = p.dy * scale;
      if (yFlip) {
        y = -y;
      }
      if (rotationDeg != 0.0) {
        final rx = x * cosT - y * sinT;
        final ry = x * sinT + y * cosT;
        x = rx;
        y = ry;
      }
      return Offset(x, y);
    }).toList();
  }

  List<Offset> _buildDeltas(List<Offset> points) {
    // 인접 포인트 간 델타 벡터 계산.
    final deltas = <Offset>[];
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i];
      final b = points[i + 1];
      deltas.add(Offset(b.dx - a.dx, b.dy - a.dy));
    }
    return deltas;
  }

  List<Offset> _resamplePolyline(List<Offset> input, double stepPx) {
    // 선분 길이를 일정 간격(stepPx)으로 재샘플링.
    if (input.isEmpty) return <Offset>[];
    if (input.length == 1 || stepPx <= 0) return <Offset>[input.first];

    final result = <Offset>[input.first];
    var carry = 0.0;

    for (var i = 1; i < input.length; i++) {
      var a = input[i - 1];
      final b = input[i];
      var seg = (b - a).distance;
      if (seg == 0) continue;

      while (carry + seg >= stepPx) {
        final t = (stepPx - carry) / seg;
        final nx = a.dx + t * (b.dx - a.dx);
        final ny = a.dy + t * (b.dy - a.dy);
        final p = Offset(nx, ny);
        result.add(p);
        a = p;
        seg = (b - a).distance;
        carry = 0.0;
      }
      carry += seg;
    }

    if (result.last != input.last) {
      result.add(input.last);
    }
    return result;
  }

  List<Offset> _circlePoints(Offset center, Offset edge, double stepPx) {
    // 원의 둘레를 일정 간격으로 샘플링.
    final radius = (edge - center).distance;
    if (radius == 0) return <Offset>[center];
    final circumference = 2 * math.pi * radius;
    final n = math.max(36, (circumference / stepPx).ceil());
    if (n <= 1) return <Offset>[center + Offset(radius, 0)];
    final points = <Offset>[];
    for (var i = 0; i <= n; i++) {
      final t = i / n;
      final angle = t * 2 * math.pi;
      points.add(Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      ));
    }
    return points;
  }

  List<Offset> _rectPoints(Offset a, Offset b, double stepPx) {
    // 사각형 외곽선을 일정 간격으로 샘플링.
    final left = math.min(a.dx, b.dx);
    final right = math.max(a.dx, b.dx);
    final top = math.min(a.dy, b.dy);
    final bottom = math.max(a.dy, b.dy);

    final w = right - left;
    final h = bottom - top;
    if (w == 0 && h == 0) return <Offset>[Offset(left, top)];
    if (stepPx <= 0) {
      return <Offset>[
        Offset(left, top),
        Offset(right, top),
        Offset(right, bottom),
        Offset(left, bottom),
        Offset(left, top),
      ];
    }

    final corners = <Offset>[
      Offset(left, top),
      Offset(right, top),
      Offset(right, bottom),
      Offset(left, bottom),
      Offset(left, top),
    ];

    final points = <Offset>[];
    for (var i = 0; i < corners.length - 1; i++) {
      final segment = _sampleSegment(corners[i], corners[i + 1], stepPx);
      if (i > 0 && segment.isNotEmpty) {
        segment.removeAt(0);
      }
      points.addAll(segment);
    }
    return points;
  }

  List<Offset> _sampleSegment(Offset a, Offset b, double stepPx) {
    final length = (b - a).distance;
    if (length == 0) return <Offset>[a];
    final n = (length / stepPx).ceil();
    final points = <Offset>[];
    for (var i = 0; i <= n; i++) {
      final t = n == 0 ? 0.0 : i / n;
      points.add(Offset(
        a.dx + t * (b.dx - a.dx),
        a.dy + t * (b.dy - a.dy),
      ));
    }
    return points;
  }

  @override
  Widget build(BuildContext context) {
    // ===== 화면 구성 =====
    // 상단: 캔버스/배경 + 드로잉, 하단: 상태/테이블/컨트롤 패널.
    final lengthPx = _lengthForMode();
    final strokeItems = <DropdownMenuItem<int?>>[
      const DropdownMenuItem<int?>(
        value: null,
        child: Text('Current'),
      ),
      ...List<DropdownMenuItem<int?>>.generate(
        _strokes.length,
        (index) => DropdownMenuItem<int?>(
          value: index,
          child: Text('S$index'),
        ),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Canvas Line Sender'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.white,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 프레임 크기 결정 우선순위:
                  // 1) 사용자 입력(mm) + 스케일, 2) 이미지 비율, 3) 화면 여백 내 최대.
                  final maxWidth = constraints.maxWidth * 0.9;
                  final maxHeight = constraints.maxHeight * 0.9;
                  final frameSize = _useUserFrameOverride && _userFramePxSize != null
                      ? Size(
                          math.min(
                              _userFramePxSize!.width * _userFrameScale, maxWidth),
                          math.min(
                              _userFramePxSize!.height * _userFrameScale, maxHeight),
                        )
                      : (_imageSize != null
                          ? _fitFrameSize(_imageSize!, maxWidth, maxHeight)
                          : Size(maxWidth, maxHeight));
                  // 화면 중앙 정렬.
                  final frameLeft =
                      (constraints.maxWidth - frameSize.width) / 2;
                  final frameTop =
                      (constraints.maxHeight - frameSize.height) / 2;
                  _frameRect = Rect.fromLTWH(
                    frameLeft,
                    frameTop,
                    frameSize.width,
                    frameSize.height,
                  );

                  return Stack(
                    children: [
                      Center(
                        child: Container(
                          width: frameSize.width,
                          height: frameSize.height,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            border: Border.all(
                              color: Colors.grey.shade400,
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.06),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: _imageFile == null
                              ? const Center(child: Text('No Image'))
                              : ClipRect(
                                  child: Image.file(
                                    _imageFile!,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                        ),
                      ),
                      // 포인터 이벤트를 받아 그리기를 수행.
                      Listener(
                        onPointerDown: _onPointerDown,
                        onPointerMove: _onPointerMove,
                        onPointerUp: _onPointerUp,
                        child: CustomPaint(
                          painter: LinePainter(
                            p0: _p0,
                            p1: _p1,
                            points: _pointsPx,
                            rawPoints: _rawPoints,
                            mode: _mode,
                            strokes: _strokes,
                            selectRect: _selectRect,
                            selectedStrokeIndex: _selectedStrokeIndex,
                            frameRect: _frameRect,
                          ),
                          size: Size.infinite,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              border: Border(top: BorderSide(color: Colors.grey.shade400)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 240,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Start: ${_formatPointImage(_p0)}'),
                          Text('End: ${_formatPointImage(_p1)}'),
                          Text('Length(img px): ${lengthPx.toStringAsFixed(2)}'),
                          Text('Points: ${_displayPointCount()}'),
                          Text('Status: $_status'),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),

                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'Points Table',
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                  const SizedBox(width: 12),
                                  DropdownButton<int?>(
                                    value: _selectedStrokeIndex,
                                    items: strokeItems,
                                    onChanged: (value) {
                                      setState(() {
                                        _selectedStrokeIndex = value;
                                        _syncPointCountController();
                                      });
                                    },
                                    isDense: true,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              SizedBox(
                                height: 170,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    border: Border.all(color: Colors.grey.shade400),
                                  ),
                                  child: Scrollbar(
                                    child: SingleChildScrollView(
                                      child: DataTable(
                                        headingRowHeight: 32,
                                        dataRowHeight: 30,
                                        columns: const [
                                          DataColumn(label: Text('S')),
                                          DataColumn(label: Text('X')),
                                          DataColumn(label: Text('Y')),
                                          DataColumn(label: Text('Z')),
                                        ],
                                        rows: _buildPointRowsForAndroidZ(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 16),

                    SizedBox(
                      width: 240,
                      child: Column(
                        children: [
                          TextField(
                            controller: _hostController,
                            decoration: const InputDecoration(
                              labelText: 'Host',
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _portController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _zController,
                            keyboardType: const TextInputType.numberWithOptions(
                              signed: true,
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Z All',
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton(
                            onPressed: _applyZToAll,
                            child: const Text('Apply Z All'),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _pointCountController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Point Count',
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton(
                            onPressed: _applyPointCount,
                            child: const Text('Apply Points'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 10),

                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ElevatedButton(onPressed: _reset, child: const Text('Reset')),
                    ElevatedButton(onPressed: _sendJson, child: const Text('Send')),
                    ElevatedButton(onPressed: _deleteSelectedOrLast, child: const Text('Delete')),
                    ElevatedButton(onPressed: _pickImage, child: const Text('Upload')),
                    ElevatedButton(onPressed: _openOnshapeViewer, child: const Text('Onshape')),

                    const SizedBox(width: 6),
                    ToggleButtons(
                      isSelected: [
                        _mode == DrawMode.line,
                        _mode == DrawMode.pen,
                        _mode == DrawMode.circle,
                        _mode == DrawMode.rect,
                      ],
                      onPressed: (index) {
                        setState(() {
                          _mode = DrawMode.values[index];
                          _clearCurrentDrawing();
                        });
                      },
                      children: const [
                        Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text('Line')),
                        Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text('Pen')),
                        Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text('Circle')),
                        Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text('Rect')),
                      ],
                    ),
                    FilterChip(
                      label: const Text('Continue'),
                      selected: _appendPen,
                      onSelected: (value) {
                        setState(() {
                          _appendPen = value;
                        });
                      },
                    ),
                    FilterChip(
                      label: const Text('Select'),
                      selected: _selectMode,
                      onSelected: (value) {
                        setState(() {
                          _selectMode = value;
                          _isSelecting = false;
                          _selectStart = null;
                          _selectRect = null;
                        });
                      },
                    ),
                    const Text('Smooth'),
                    SizedBox(
                      width: 160,
                      child: Slider(
                        min: 1,
                        max: 21,
                        divisions: 10,
                        label: _smoothingWindow.toString(),
                        value: _smoothingWindow.toDouble(),
                        onChanged: (value) {
                          setState(() {
                            var v = value.round();
                            if (v.isEven) v += 1;
                            _smoothingWindow = v.clamp(1, 21);
                          });
                          _applySmoothingToSelected();
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text('BG Size (mm)'),
                    FilterChip(
                      label: const Text('A4'),
                      selected: false,
                      onSelected: (_) => _setPresetSize(297.0, 210.0),
                    ),
                    FilterChip(
                      label: const Text('A2'),
                      selected: false,
                      onSelected: (_) => _setPresetSize(594.0, 420.0),
                    ),
                    FilterChip(
                      label: const Text('B4'),
                      selected: false,
                      onSelected: (_) => _setPresetSize(353.0, 250.0),
                    ),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _bgWidthController,
                        decoration: const InputDecoration(
                          labelText: 'W',
                          isDense: true,
                        ),
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                      ),
                    ),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _bgHeightController,
                        decoration: const InputDecoration(
                          labelText: 'H',
                          isDense: true,
                        ),
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _applyBackgroundSize,
                      child: const Text('Apply Size'),
                    ),
                    const Text('Frame Scale'),
                    SizedBox(
                      width: 140,
                      child: Slider(
                        min: 0.5,
                        max: 3.0,
                        divisions: 25,
                        label: _userFrameScale.toStringAsFixed(2),
                        value: _userFrameScale,
                        onChanged: (value) {
                          setState(() {
                            _userFrameScale = value;
                            if (_userFrameMmSize != null) {
                              _mmPerPx = 1.0 / _userFrameScale;
                              _mmPerPxController.text =
                                  _mmPerPx.toStringAsFixed(3);
                            }
                          });
                        },
                      ),
                    ),
                    const Text('mm/px'),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _mmPerPxController,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'mm_per_px',
                        ),
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _applyMmPerPx,
                      child: const Text('Apply mm/px'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatPointImage(Offset? p) {
    if (p == null) return '-';
    final mappedP = _canvasToImageClamped(p);
    return '(${mappedP.dx.toStringAsFixed(1)}, ${mappedP.dy.toStringAsFixed(1)})';
  }

  void _openStepViewer() {
    // STEP 뷰어 사이트 열기.
    _openWebViewer('STEP Viewer', 'https://3dviewer.net');
  }

  void _openOnshapeViewer() {
    // Onshape 웹 열기.
    _openWebViewer('Onshape', 'https://cad.onshape.com');
  }

  void _openWebViewer(String title, String url) {
    // 플랫폼에 따라 앱 내부 WebView 또는 외부 브라우저로 열기.
    if (Platform.isWindows ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => WebViewerPage(title: title, url: url),
        ),
      );
      return;
    }
    _launchExternalUrl(url);
  }

  Future<void> _launchExternalUrl(String url) async {
    // 외부 브라우저로 URL 열기.
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('????? ? ? ????.')),
      );
    }
  }

// ===== Point Table Rows (X,Y,Z 편집 가능) =====
  List<DataRow> _buildPointRows() {
    // 포인트 테이블 UI용 행 생성 (X,Y는 표시, Z는 편집 가능).
    final source = _pointsForTable();
    final zValues = _zValuesForTable(source.length);

    if (source.isEmpty) return const <DataRow>[];

    return List<DataRow>.generate(source.length, (index) {
      final p = source[index];
      final z = zValues[index];

      return DataRow(
        cells: [
          DataCell(Text('S$index')),
          DataCell(Text(p.dx.toStringAsFixed(2))),
          DataCell(Text(p.dy.toStringAsFixed(2))),
          DataCell(
            SizedBox(
              width: 70,
              child: TextFormField(
                key: ValueKey<String>(
                    'z-${_selectedStrokeIndex ?? -1}-$index'),
                initialValue: z.toStringAsFixed(2),
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                ),
                onChanged: (value) {
                  final parsed = double.tryParse(value.trim());
                  if (parsed == null) return;
                  setState(() {
                    zValues[index] = parsed;
                  });
                },
              ),
            ),
          ),
        ],
      );
    });
  }

  // ===== Table 대상 점들(Current 또는 선택 Stroke) =====
  List<Offset> _pointsForTable() {
    // 테이블 표시 대상 포인트: 선택된 스트로크가 있으면 그 스트로크, 없으면 Current.
    if (_selectedStrokeIndex != null &&
        _selectedStrokeIndex! >= 0 &&
        _selectedStrokeIndex! < _strokes.length) {
      final stroke = _strokes[_selectedStrokeIndex!];
      final imagePoints = stroke.samples
          .map(_canvasToImageClamped)
          .toList(growable: false);
      return _applyTransform(imagePoints, _mmPerPx);
    }
    if (_pointsMm.isNotEmpty) return _pointsMm;
    if (_pointsImage.isNotEmpty) return _pointsImage;
    return _pointsPx;
  }

  // ===== Table 대상 Z(Current 또는 선택 Stroke) =====
  List<double> _zValuesForTable(int length) {
    // 테이블 표시 대상 Z 리스트: 선택된 스트로크 우선, 아니면 Current.
    if (_selectedStrokeIndex != null &&
        _selectedStrokeIndex! >= 0 &&
        _selectedStrokeIndex! < _strokes.length) {
      final stroke = _strokes[_selectedStrokeIndex!];
      stroke.zValues = _syncZList(stroke.zValues, length);
      return stroke.zValues;
    }
    _currentZValues = _syncZList(_currentZValues, length);
    return _currentZValues;
  }

  List<DataRow> _buildPointRowsForAndroidZ() {
    final rows = _tableRowsForAndroidZ();

    if (rows.isEmpty) return const <DataRow>[];

    return List<DataRow>.generate(rows.length, (index) {
      final row = rows[index];

      return DataRow(
        cells: [
          DataCell(Text(row.label)),
          DataCell(Text(row.point.dx.toStringAsFixed(2))),
          DataCell(Text(row.point.dy.toStringAsFixed(2))),
          DataCell(
            SizedBox(
              width: 70,
              child: TextFormField(
                key: ValueKey<String>(
                    'z-${row.label}-${row.z.toStringAsFixed(2)}'),
                initialValue: row.z.toStringAsFixed(2),
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                ),
                onChanged: (value) {
                  final parsed = double.tryParse(value.trim());
                  if (parsed == null) return;
                  setState(() {
                    if (row.strokeIndex != null) {
                      final stroke = _strokes[row.strokeIndex!];
                      stroke.zValues = _syncZList(
                        stroke.zValues,
                        stroke.samples.length,
                      );
                      stroke.zValues[row.pointIndex] = parsed;
                    } else {
                      _currentZValues =
                          _syncZList(_currentZValues, _pointsMm.length);
                      _currentZValues[row.pointIndex] = parsed;
                    }
                  });
                },
              ),
            ),
          ),
        ],
      );
    });
  }

  List<_TablePointRow> _tableRowsForAndroidZ() {
    if (_selectedStrokeIndex != null &&
        _selectedStrokeIndex! >= 0 &&
        _selectedStrokeIndex! < _strokes.length) {
      final stroke = _strokes[_selectedStrokeIndex!];
      final imagePoints = stroke.samples
          .map(_canvasToImageClamped)
          .toList(growable: false);
      final points = _applyTransform(imagePoints, _mmPerPx);
      stroke.zValues = _syncZList(stroke.zValues, points.length);
      return List<_TablePointRow>.generate(points.length, (index) {
        return _TablePointRow(
          label: 'S${_selectedStrokeIndex!}-$index',
          point: points[index],
          z: stroke.zValues[index],
          pointIndex: index,
          strokeIndex: _selectedStrokeIndex,
        );
      });
    }

    if (_strokes.isNotEmpty) {
      final rows = <_TablePointRow>[];
      for (var strokeIndex = 0; strokeIndex < _strokes.length; strokeIndex++) {
        final stroke = _strokes[strokeIndex];
        final imagePoints = stroke.samples
            .map(_canvasToImageClamped)
            .toList(growable: false);
        final points = _applyTransform(imagePoints, _mmPerPx);
        stroke.zValues = _syncZList(stroke.zValues, points.length);
        for (var pointIndex = 0; pointIndex < points.length; pointIndex++) {
          rows.add(
            _TablePointRow(
              label: 'S$strokeIndex-$pointIndex',
              point: points[pointIndex],
              z: stroke.zValues[pointIndex],
              pointIndex: pointIndex,
              strokeIndex: strokeIndex,
            ),
          );
          _selectedStrokeIndex = _strokes.length - 1;
        }
        _syncPointCountController();
      }
      return rows;
    }

    final points = _pointsMm.isNotEmpty
        ? _pointsMm
        : (_pointsImage.isNotEmpty ? _pointsImage : _pointsPx);
    _currentZValues = _syncZList(_currentZValues, points.length);
    return List<_TablePointRow>.generate(points.length, (index) {
      return _TablePointRow(
        label: 'C$index',
        point: points[index],
        z: _currentZValues[index],
        pointIndex: index,
      );
    });
  }

  double _polylineLength(List<Offset> points) {
    if (points.length < 2) return 0.0;
    var sum = 0.0;
    for (var i = 1; i < points.length; i++) {
      sum += (points[i] - points[i - 1]).distance;
    }
    return sum;
  }

  double _lengthForMode() {
    // 현재 모드의 길이(이미지 좌표 기준) 계산.
    if (_mode == DrawMode.line && _p0 != null && _p1 != null) {
      final p0Image = _canvasToImageClamped(_p0!);
      final p1Image = _canvasToImageClamped(_p1!);
      return (p1Image - p0Image).distance;
    }
    if (_mode == DrawMode.circle && _p0 != null && _p1 != null) {
      final p0Image = _canvasToImageClamped(_p0!);
      final p1Image = _canvasToImageClamped(_p1!);
      final r = (p1Image - p0Image).distance;
      return 2 * math.pi * r;
    }
    if (_mode == DrawMode.rect && _p0 != null && _p1 != null) {
      final p0Image = _canvasToImageClamped(_p0!);
      final p1Image = _canvasToImageClamped(_p1!);
      final w = (p1Image.dx - p0Image.dx).abs();
      final h = (p1Image.dy - p0Image.dy).abs();
      return 2 * (w + h);
    }
    if (_mode == DrawMode.pen) {
      if (_pointsImage.isNotEmpty) {
        return _polylineLength(_pointsImage);
      }
      final rawImage =
          _rawPoints.map(_canvasToImageClamped).toList(growable: false);
      return _polylineLength(rawImage);
    }
    return 0.0;
  }

  Size _fitFrameSize(Size imageSize, double maxWidth, double maxHeight) {
    // 이미지 비율 유지하면서 프레임 내에 맞추기.
    final aspect = imageSize.width / imageSize.height;
    var width = maxWidth;
    var height = maxHeight;
    if (width / height > aspect) {
      width = height * aspect;
    } else {
      height = width / aspect;
    }
    return Size(width, height);
  }

  Offset _canvasToImageClamped(Offset p) {
    // 캔버스 좌표 -> 프레임 로컬 좌표(좌상단이 0,0)로 변환 후 클램프.
    if (_frameRect == null) {
      return p;
    }
    final rect = _frameRect!;
    if (_userFrameMmSize != null || _imageSize == null) {
      final x = (p.dx - rect.left).clamp(0.0, rect.width);
      final y = (p.dy - rect.top).clamp(0.0, rect.height);
      return Offset(x.toDouble(), y.toDouble());
    }
    final sx = _imageSize!.width / rect.width;
    final sy = _imageSize!.height / rect.height;
    final x = (p.dx - rect.left) * sx;
    final y = (p.dy - rect.top) * sy;
    final clampedX = x.clamp(0.0, _imageSize!.width);
    final clampedY = y.clamp(0.0, _imageSize!.height);
    return Offset(clampedX, clampedY);
  }

  Offset _imageToCanvas(Offset p) {
    // 프레임 로컬 좌표 -> 캔버스 좌표로 역변환.
    if (_frameRect == null) {
      return p;
    }
    final rect = _frameRect!;
    if (_userFrameMmSize != null || _imageSize == null) {
      return Offset(rect.left + p.dx, rect.top + p.dy);
    }
    final sx = rect.width / _imageSize!.width;
    final sy = rect.height / _imageSize!.height;
    return Offset(rect.left + p.dx * sx, rect.top + p.dy * sy);
  }

  List<Offset> _imagePointsToCanvas(List<Offset> points) {
    // 프레임 로컬 좌표 리스트를 캔버스 좌표로 변환.
    if (_frameRect == null) {
      return points;
    }
    return points.map(_imageToCanvas).toList(growable: false);
  }

  void _beginMove(Offset position) {
    // 우클릭 이동 시작: 가장 가까운 스트로크를 잡는다.
    final index = _hitTestStroke(position);
    if (index == null) return;
    setState(() {
      _clearActiveDrawing();
      _dragStrokeIndex = index;
      _dragLast = position;
      _isMoving = true;
    });
  }

  void _updateMove(Offset position) {
    // 이동 중: 델타만큼 스트로크 전체 이동.
    if (_dragStrokeIndex == null || _dragLast == null) return;
    final delta = position - _dragLast!;
    setState(() {
      _translateStroke(_strokes[_dragStrokeIndex!], delta);
      _dragLast = position;
    });
  }

  void _endMove() {
    // 이동 종료.
    setState(() {
      _dragStrokeIndex = null;
      _dragLast = null;
      _isMoving = false;
    });
  }

  // Shift 키 상태 체크(샘플 점 편집 모드 진입용).
  bool _isShiftPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  // 샘플 점 편집 시작: 가장 가까운 샘플을 선택한다.
  bool _beginEditPoint(Offset position) {
    final hit = _hitTestPoint(position);
    if (hit == null) return false;
    setState(() {
      _isEditingPoint = true;
      _editStrokeIndex = hit.strokeIndex;
      _editSampleIndex = hit.sampleIndex;
      _editPathIndex = hit.pathIndex;
    });
    return true;
  }

  // 샘플 점 편집 중: 선택된 점을 이동.
  void _updateEditPoint(Offset position) {
    if (_editStrokeIndex == null) return;
    final stroke = _strokes[_editStrokeIndex!];
    setState(() {
      if (_editSampleIndex != null &&
          _editSampleIndex! >= 0 &&
          _editSampleIndex! < stroke.samples.length) {
        stroke.samples[_editSampleIndex!] = position;
      }
      if (_editPathIndex != null &&
          _editPathIndex! >= 0 &&
          _editPathIndex! < stroke.path.length) {
        stroke.path[_editPathIndex!] = position;
      }
    });
  }

  // 샘플 점 편집 종료.
  void _endEditPoint() {
    setState(() {
      _isEditingPoint = false;
      _editStrokeIndex = null;
      _editSampleIndex = null;
      _editPathIndex = null;
    });
  }

  _PointHit? _hitTestPoint(Offset position) {
    const threshold = 10.0;
    double best = double.infinity;
    _PointHit? bestHit;
    for (var i = 0; i < _strokes.length; i++) {
      final stroke = _strokes[i];
      for (var s = 0; s < stroke.samples.length; s++) {
        final d = (stroke.samples[s] - position).distance;
        if (d < best) {
          best = d;
          bestHit = _PointHit(
            strokeIndex: i,
            sampleIndex: s,
            pathIndex: _nearestPathIndex(stroke.path, position),
          );
        }
      }
    }
    if (best <= threshold) return bestHit;
    return null;
  }

  int? _nearestPathIndex(List<Offset> path, Offset position) {
    if (path.isEmpty) return null;
    var best = double.infinity;
    var bestIndex = 0;
    for (var i = 0; i < path.length; i++) {
      final d = (path[i] - position).distance;
      if (d < best) {
        best = d;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  // 스트로크(선)과의 최소 거리로 선택 대상 찾기.
  int? _hitTestStroke(Offset position) {
    const threshold = 12.0;
    double best = double.infinity;
    int? bestIndex;
    for (var i = 0; i < _strokes.length; i++) {
      final distance = _minDistanceToPath(_strokes[i].path, position);
      if (distance < best) {
        best = distance;
        bestIndex = i;
      }
    }
    if (best <= threshold) return bestIndex;
    return null;
  }

  // 점과 폴리라인 사이 최소 거리 계산.
  double _minDistanceToPath(List<Offset> path, Offset p) {
    if (path.isEmpty) return double.infinity;
    if (path.length == 1) return (p - path.first).distance;
    var min = double.infinity;
    for (var i = 0; i + 1 < path.length; i++) {
      final d = _distanceToSegment(p, path[i], path[i + 1]);
      if (d < min) min = d;
    }
    return min;
  }

  // 점과 선분 사이 최소 거리 계산.
  double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final ap = p - a;
    final ab2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (ab2 == 0) return (p - a).distance;
    var t = (ap.dx * ab.dx + ap.dy * ab.dy) / ab2;
    t = t.clamp(0.0, 1.0);
    final closest = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - closest).distance;
  }

  // 스트로크 전체를 이동(드래그 이동).
  void _translateStroke(Stroke stroke, Offset delta) {
    for (var i = 0; i < stroke.path.length; i++) {
      stroke.path[i] = stroke.path[i] + delta;
    }
    for (var i = 0; i < stroke.samples.length; i++) {
      stroke.samples[i] = stroke.samples[i] + delta;
    }
  }

  // 현재 그리기 중인 임시 상태를 초기화.
  void _clearActiveDrawing() {
    _p0 = null;
    _p1 = null;
    _rawPoints = <Offset>[];
    _pointsPx = <Offset>[];
    _pointsImage = <Offset>[];
    _pointsMm = <Offset>[];
    _deltasMm = <Offset>[];
    _currentZValues = <double>[];
    _syncPointCountController();
  }

  Offset _clampToFrame(Offset position) {
    // 프레임 밖으로 나가지 않도록 강제 클램프.
    final rect = _frameRect;
    if (rect == null) return position;
    final x = position.dx.clamp(rect.left, rect.right).toDouble();
    final y = position.dy.clamp(rect.top, rect.bottom).toDouble();
    return Offset(x, y);
  }

  void _selectStrokeByRect(Rect rect) {
    // 드래그 박스로 겹치는 스트로크 중 가장 가까운 것을 선택.
    int? bestIndex;
    double bestScore = double.infinity;
    for (var i = 0; i < _strokes.length; i++) {
      if (_strokeIntersectsRect(_strokes[i], rect)) {
        final center = rect.center;
        final distance = _minDistanceToPath(_strokes[i].path, center);
        if (distance < bestScore) {
          bestScore = distance;
          bestIndex = i;
        }
      }
    }
    setState(() {
      _selectedStrokeIndex = bestIndex;
      _syncPointCountController();
      if (bestIndex != null) {
        final stroke = _strokes[bestIndex];
        stroke.basePath = List<Offset>.from(stroke.path);
        stroke.baseSamples = List<Offset>.from(stroke.samples);
        _smoothingBaseStrokeIndex = bestIndex;
      } else {
        _smoothingBaseStrokeIndex = null;
      }
    });
  }

  bool _strokeIntersectsRect(Stroke stroke, Rect rect) {
    // 스트로크가 선택 사각형과 교차하는지 검사.
    for (final p in stroke.path) {
      if (rect.contains(p)) return true;
    }
    for (var i = 0; i + 1 < stroke.path.length; i++) {
      if (_segmentIntersectsRect(stroke.path[i], stroke.path[i + 1], rect)) {
        return true;
      }
    }
    return false;
  }

  bool _segmentIntersectsRect(Offset a, Offset b, Rect rect) {
    // 선분과 사각형 교차 여부.
    if (rect.contains(a) || rect.contains(b)) return true;
    final tl = rect.topLeft;
    final tr = rect.topRight;
    final bl = rect.bottomLeft;
    final br = rect.bottomRight;
    return _segmentsIntersect(a, b, tl, tr) ||
        _segmentsIntersect(a, b, tr, br) ||
        _segmentsIntersect(a, b, br, bl) ||
        _segmentsIntersect(a, b, bl, tl);
  }

  bool _segmentsIntersect(Offset p1, Offset p2, Offset q1, Offset q2) {
    // 두 선분 교차 여부(벡터 외적 기반).
    double cross(Offset a, Offset b, Offset c) {
      return (b.dx - a.dx) * (c.dy - a.dy) -
          (b.dy - a.dy) * (c.dx - a.dx);
    }

    final d1 = cross(p1, p2, q1);
    final d2 = cross(p1, p2, q2);
    final d3 = cross(q1, q2, p1);
    final d4 = cross(q1, q2, p2);
    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
      return true;
    }
    return false;
  }

  void _applySmoothingToSelected() {
    // 선택한 스트로크에 이동 평균 스무딩 적용.
    if (_selectedStrokeIndex == null ||
        _selectedStrokeIndex! < 0 ||
        _selectedStrokeIndex! >= _strokes.length ||
        _smoothingWindow < 1) {
      return;
    }
    setState(() {
      final stroke = _strokes[_selectedStrokeIndex!];
      if (_smoothingBaseStrokeIndex != _selectedStrokeIndex ||
          stroke.basePath == null ||
          stroke.baseSamples == null) {
        stroke.basePath = List<Offset>.from(stroke.path);
        stroke.baseSamples = List<Offset>.from(stroke.samples);
        _smoothingBaseStrokeIndex = _selectedStrokeIndex;
      }
      stroke.path = _smoothPoints(stroke.basePath!);
      stroke.samples = _smoothPoints(stroke.baseSamples!);
      _rebuildPoints();
    });
  }

  List<Offset> _smoothPoints(List<Offset> points) {
    // ??? ?? ?? ???.
    if (points.length < 3) return points;
    final window =
        _smoothingWindow.isOdd ? _smoothingWindow : _smoothingWindow + 1;
    final half = window ~/ 2;
    final original = List<Offset>.from(points);
    final result = List<Offset>.from(points);
    for (var i = 0; i < points.length; i++) {
      var sumX = 0.0;
      var sumY = 0.0;
      var count = 0;
      final start = math.max(0, i - half);
      final end = math.min(points.length - 1, i + half);
      for (var j = start; j <= end; j++) {
        sumX += original[j].dx;
        sumY += original[j].dy;
        count++;
      }
      if (count > 0) {
        result[i] = Offset(sumX / count, sumY / count);
      }
    }
    return result;
  }
}

// 캔버스에 선/점/선택 사각형을 그리는 페인터.
class LinePainter extends CustomPainter {
  LinePainter({
    required this.p0,
    required this.p1,
    required this.points,
    required this.rawPoints,
    required this.mode,
    required this.strokes,
    required this.selectRect,
    required this.selectedStrokeIndex,
    required this.frameRect,
  });

  final Offset? p0;
  final Offset? p1;
  final List<Offset> points;
  final List<Offset> rawPoints;
  final DrawMode mode;
  final List<Stroke> strokes;
  final Rect? selectRect;
  final int? selectedStrokeIndex;
  final Rect? frameRect;

  @override
  void paint(Canvas canvas, Size size) {
    // 프레임 영역 내에서 스트로크/포인트를 그린다.
    if (frameRect != null) {
      canvas.save();
      canvas.clipRect(frameRect!);
    }
    final linePaint = Paint()
      ..color = Colors.blueGrey
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pointPaint = Paint()..color = Colors.redAccent;
    const pointLabelStyle = TextStyle(
      color: Colors.black,
      fontSize: 10,
    );
    const strokeLabelStyle = TextStyle(
      color: Colors.blue,
      fontSize: 14,
    );

    for (var i = 0; i < strokes.length; i++) {
      final stroke = strokes[i];
      final isSelected = selectedStrokeIndex == i;
      final paint = isSelected
          ? (Paint()
            ..color = Colors.orange
            ..strokeWidth = 3
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round)
          : linePaint;

      _drawStrokeIndex(canvas, size, stroke, i, strokeLabelStyle);
      final pathPoints = stroke.path;
      if (pathPoints.length < 2) continue;
      final path = Path()..moveTo(pathPoints.first.dx, pathPoints.first.dy);
      for (var j = 1; j < pathPoints.length; j++) {
        path.lineTo(pathPoints[j].dx, pathPoints[j].dy);
      }
      canvas.drawPath(path, paint);
    }

    for (var i = 0; i < strokes.length; i++) {
      final stroke = strokes[i];
      final isSelected = selectedStrokeIndex == i;
      final pPaint =
          isSelected ? (Paint()..color = Colors.orangeAccent) : pointPaint;
      for (final p in stroke.samples) {
        canvas.drawCircle(p, 3, pPaint);
      }
      _drawPointIndices(canvas, stroke.samples, pointLabelStyle);
    }

    if (mode == DrawMode.line && p0 != null && p1 != null) {
      canvas.drawLine(p0!, p1!, linePaint);
    }

    if (mode == DrawMode.pen && rawPoints.length >= 2) {
      final path = Path()..moveTo(rawPoints.first.dx, rawPoints.first.dy);
      for (var i = 1; i < rawPoints.length; i++) {
        path.lineTo(rawPoints[i].dx, rawPoints[i].dy);
      }
      canvas.drawPath(path, linePaint);
    }

    if (mode == DrawMode.circle && p0 != null && p1 != null) {
      final radius = (p1! - p0!).distance;
      canvas.drawCircle(p0!, radius, linePaint);
    }

    if (mode == DrawMode.rect && p0 != null && p1 != null) {
      final rect = Rect.fromPoints(p0!, p1!);
      canvas.drawRect(rect, linePaint);
    }

    for (final p in points) {
      canvas.drawCircle(p, 3, pointPaint);
    }
    _drawPointIndices(canvas, points, pointLabelStyle);

    if (selectRect != null) {
      final selPaint = Paint()
        ..color = Colors.blueGrey.withOpacity(0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawRect(selectRect!, selPaint);
    }
    if (frameRect != null) {
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant LinePainter oldDelegate) {
    return true;
  }

  void _drawPointIndices(Canvas canvas, List<Offset> points, TextStyle style) {
    for (var i = 0; i < points.length; i++) {
      final textPainter = TextPainter(
        text: TextSpan(text: i.toString(), style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final pos = points[i] + const Offset(4, -4);
      textPainter.paint(canvas, pos);
    }
  }

  void _drawStrokeIndex(
    Canvas canvas,
    Size size,
    Stroke stroke,
    int index,
    TextStyle style,
  ) {
    if (stroke.path.isEmpty) return;
    final first = stroke.path.first;
    final textPainter = TextPainter(
      text: TextSpan(text: 'S$index', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final x = first.dx.clamp(0.0, size.width - textPainter.width);
    final y = (first.dy - textPainter.height - 2)
        .clamp(0.0, size.height - textPainter.height);
    textPainter.paint(canvas, Offset(x, y));
  }
}

// 그리기 모드 종류.
enum DrawMode { line, pen, circle, rect }

class Stroke {
  // 하나의 스트로크(선/펜)를 구성하는 데이터.
  Stroke({required this.path, required this.samples, required this.zValues});

  List<Offset> path;
  List<Offset> samples;

  // ✅ stroke별 Z (samples 길이와 동일 유지)
  List<double> zValues;

  List<Offset>? basePath;
  List<Offset>? baseSamples;
}

class _PointHit {
  _PointHit({
    required this.strokeIndex,
    required this.sampleIndex,
    required this.pathIndex,
  });

  final int strokeIndex;
  final int sampleIndex;
  final int? pathIndex;
}

class _TablePointRow {
  _TablePointRow({
    required this.label,
    required this.point,
    required this.z,
    required this.pointIndex,
    this.strokeIndex,
  });

  final String label;
  final Offset point;
  final double z;
  final int pointIndex;
  final int? strokeIndex;
}

class WebViewerPage extends StatefulWidget {
  // 외부 웹 페이지를 앱 내부에서 보여주는 간단한 뷰어.
  const WebViewerPage({super.key, required this.title, required this.url});

  final String title;
  final String url;

  @override
  State<WebViewerPage> createState() => _WebViewerPageState();
}

class _WebViewerPageState extends State<WebViewerPage> {
  // 플랫폼별 WebView 컨트롤러.
  WebViewController? _mobileController;
  final WebviewController _windowsController = WebviewController();
  bool _windowsReady = false;
  String? _windowsError;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _initWindowsWebView();
    } else {
      _mobileController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..loadRequest(Uri.parse(widget.url));
    }
  }

  Future<void> _initWindowsWebView() async {
    // Windows WebView 초기화 및 URL 로드.
    try {
      await _windowsController.initialize();
      await _windowsController.loadUrl(widget.url);
      if (!mounted) return;
      setState(() {
        _windowsReady = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _windowsError = error.toString();
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      _windowsController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Windows / 모바일 플랫폼에 따라 WebView 구현을 분기한다.
    Widget body;
    if (Platform.isWindows) {
      if (_windowsError != null) {
        body = Center(child: Text('WebView error: $_windowsError'));
      } else if (!_windowsReady) {
        body = const Center(child: CircularProgressIndicator());
      } else {
        body = Webview(_windowsController);
      }
    } else {
      body = WebViewWidget(controller: _mobileController!);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: body,
    );
  }
}
