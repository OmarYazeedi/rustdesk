import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/windows_touch_keyboard.dart';

/// A translucent keyboard button that floats over the remote screen, draggable
/// anywhere the user wants it.
///
/// The toolbar entries work, but reaching a keyboard through a menu every time
/// you want to type is a lot of taps. This sits where you left it.
///
/// "Pinned" means put away: the button disappears and the toolbar entries are
/// how you reach a keyboard. That's the toggle in the toolbar, so there's always
/// a way to bring it back once it's gone.
///
/// Position is stored as a fraction of the viewport rather than in pixels, so
/// resizing the window or moving to another display leaves it where it looks
/// like it should be instead of off-screen.
class FloatingKeyboardButton extends StatefulWidget {
  final FFI ffi;

  const FloatingKeyboardButton({Key? key, required this.ffi}) : super(key: key);

  @override
  State<FloatingKeyboardButton> createState() => _FloatingKeyboardButtonState();
}

class _FloatingKeyboardButtonState extends State<FloatingKeyboardButton> {
  static const double _size = 56;
  // Idle it stays out of the way; under a finger it comes forward so you can see
  // what you're dragging.
  static const double _idleOpacity = 0.38;
  static const double _activeOpacity = 0.92;

  // Fractions of the viewport, not pixels. Defaults to low on the right, near a
  // thumb and clear of the toolbar, which docks to the top by default.
  double _fx = 0.92;
  double _fy = 0.78;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    final x = double.tryParse(
        bind.mainGetLocalOption(key: kOptionFloatingKeyboardBtnX));
    final y = double.tryParse(
        bind.mainGetLocalOption(key: kOptionFloatingKeyboardBtnY));
    if (x != null) _fx = x.clamp(0.0, 1.0);
    if (y != null) _fy = y.clamp(0.0, 1.0);
  }

  void _persist() {
    bind.mainSetLocalOption(
        key: kOptionFloatingKeyboardBtnX, value: _fx.toStringAsFixed(4));
    bind.mainSetLocalOption(
        key: kOptionFloatingKeyboardBtnY, value: _fy.toStringAsFixed(4));
  }

  Future<void> _onTap() async {
    final raised = await toggleBestWindowsKeyboard();
    final ffiModel = widget.ffi.ffiModel;
    switch (raised) {
      case RaisedKeyboard.touch:
        ffiModel.windowsKeyboardShown.value =
            !ffiModel.windowsKeyboardShown.value;
        break;
      case RaisedKeyboard.osk:
        ffiModel.oskShown.value = WindowsTouchKeyboard.oskShown;
        break;
      case RaisedKeyboard.none:
        // Neither Windows keyboard would come up; fall back to the in-app one so
        // the button always does something, and say why on screen.
        showToast(
            'Windows keyboard unavailable — using the in-app one.\n'
            '${WindowsTouchKeyboard.lastDiagnostic}',
            timeout: const Duration(seconds: 8));
        ffiModel.softKeyboardVisible.value =
            !ffiModel.softKeyboardVisible.value;
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final maxX = (constraints.maxWidth - _size).clamp(0.0, double.infinity);
      final maxY = (constraints.maxHeight - _size).clamp(0.0, double.infinity);
      return Stack(children: [
        Positioned(
          left: maxX * _fx,
          top: maxY * _fy,
          child: GestureDetector(
            onTap: _onTap,
            onPanStart: (_) => setState(() => _dragging = true),
            onPanUpdate: (d) {
              if (maxX <= 0 || maxY <= 0) return;
              setState(() {
                _fx = (_fx + d.delta.dx / maxX).clamp(0.0, 1.0);
                _fy = (_fy + d.delta.dy / maxY).clamp(0.0, 1.0);
              });
            },
            onPanEnd: (_) {
              setState(() => _dragging = false);
              _persist();
            },
            onPanCancel: () {
              setState(() => _dragging = false);
              _persist();
            },
            child: Opacity(
              opacity: _dragging ? _activeOpacity : _idleOpacity,
              child: Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  color: Colors.black87,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 1),
                  boxShadow: const [
                    BoxShadow(color: Colors.black45, blurRadius: 6),
                  ],
                ),
                child: const Icon(Icons.keyboard,
                    color: Colors.white, size: 28),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}
