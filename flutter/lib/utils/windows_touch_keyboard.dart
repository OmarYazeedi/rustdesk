import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Shows and hides the real Windows touch keyboard (TabTip).
///
/// Why this rather than raising it the way a text field would: Flutter's Windows
/// embedder cannot. That's flutter#36057, open since 2019 and still reported in
/// late 2025 -- it needs UIA/TSF support Flutter doesn't have. And launching
/// `TabTip.exe` directly stopped working on Windows 11, where the process stays
/// resident so later launches are silent no-ops.
///
/// What still works is `ITipInvocation::Toggle`, which Microsoft has never
/// documented. It's the approach every app in this position ends up using.
///
/// Keystrokes from the touch keyboard are injected with `SendInput`, which might
/// look like it would leave them on the local machine. It doesn't: RustDesk
/// already installs a low-level keyboard hook (`win32_enable_lowlevel_keyboard`)
/// to capture Win, Alt+Tab and the rest, and `WH_KEYBOARD_LL` hooks fire for
/// injected input as well as physical. So they reach the peer either way.
class WindowsTouchKeyboard {
  // UIHostNoLaunch: {4CE576FA-83DC-4F88-951C-9D0782B4E376}
  static const _clsidD1 = 0x4CE576FA;
  static const _clsidD2 = 0x83DC;
  static const _clsidD3 = 0x4F88;
  static const _clsidD4 = [0x95, 0x1C, 0x9D, 0x07, 0x82, 0xB4, 0xE3, 0x76];

  // ITipInvocation: {37C994E7-432B-4834-A2F7-DCE1F13B834B}
  static const _iidD1 = 0x37C994E7;
  static const _iidD2 = 0x432B;
  static const _iidD3 = 0x4834;
  static const _iidD4 = [0xA2, 0xF7, 0xDC, 0xE1, 0xF1, 0x3B, 0x83, 0x4B];

  static const _tabTipPath =
      r'C:\Program Files\Common Files\microsoft shared\ink\TabTip.exe';

  /// Toggles the touch keyboard. Returns false if it couldn't be driven at all,
  /// so the caller can fall back to the in-app keyboard rather than leaving the
  /// user with no way to type.
  static Future<bool> toggleTouchKeyboard() async {
    if (!Platform.isWindows) return false;
    if (_tryToggle()) return true;

    // CoCreateInstance fails with REGDB_E_CLASSNOTREG until TabTip is running.
    // The first cut started TabTip and retried immediately, which cannot work --
    // process start is asynchronous and the COM class isn't registered for a
    // moment afterwards. Poll instead of guessing a single delay.
    try {
      if (!File(_tabTipPath).existsSync()) {
        debugPrint('WindowsTouchKeyboard: TabTip not found at $_tabTipPath');
        return false;
      }
      await Process.start(_tabTipPath, const [],
          mode: ProcessStartMode.detached);
    } catch (e) {
      debugPrint('WindowsTouchKeyboard: could not start TabTip: $e');
      return false;
    }

    for (var i = 0; i < 10; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (_tryToggle()) return true;
    }
    debugPrint('WindowsTouchKeyboard: TabTip started but Toggle never took');
    return false;
  }

  /// Windows' accessibility On-Screen Keyboard (Settings > Accessibility >
  /// Keyboard). A plain floating window rather than the modern touch keyboard,
  /// but it launches on every Windows version with no COM and nothing
  /// undocumented involved -- so unlike TabTip it can be relied on.
  static bool _oskShown = false;

  static bool get oskShown => _oskShown;

  static bool toggleOsk() {
    if (!Platform.isWindows) return false;
    try {
      if (_oskShown) {
        Process.runSync('taskkill', const ['/IM', 'osk.exe', '/F']);
        _oskShown = false;
      } else {
        Process.start('osk.exe', const [], mode: ProcessStartMode.detached);
        _oskShown = true;
      }
      return true;
    } catch (e) {
      debugPrint('WindowsTouchKeyboard: osk.exe failed: $e');
      return false;
    }
  }


  static bool _tryToggle() {
    final arena = Arena();
    try {
      final ole32 = DynamicLibrary.open('ole32.dll');
      final user32 = DynamicLibrary.open('user32.dll');

      final coInitializeEx = ole32.lookupFunction<
          Int32 Function(Pointer<Void>, Int32),
          int Function(Pointer<Void>, int)>('CoInitializeEx');
      final coCreateInstance = ole32.lookupFunction<
          Int32 Function(Pointer<_Guid>, Pointer<Void>, Uint32, Pointer<_Guid>,
              Pointer<Pointer<Void>>),
          int Function(Pointer<_Guid>, Pointer<Void>, int, Pointer<_Guid>,
              Pointer<Pointer<Void>>)>('CoCreateInstance');
      final getDesktopWindow = user32
          .lookupFunction<IntPtr Function(), int Function()>('GetDesktopWindow');

      // COINIT_APARTMENTTHREADED. S_FALSE (already initialised) and
      // RPC_E_CHANGED_MODE (initialised differently) are both fine to ignore --
      // either way COM is usable on this thread.
      coInitializeEx(nullptr, 0x2);

      final clsid = arena<_Guid>();
      _fillGuid(clsid.ref, _clsidD1, _clsidD2, _clsidD3, _clsidD4);
      final iid = arena<_Guid>();
      _fillGuid(iid.ref, _iidD1, _iidD2, _iidD3, _iidD4);

      final ppv = arena<Pointer<Void>>();
      // CLSCTX_INPROC_SERVER | CLSCTX_INPROC_HANDLER
      final hr = coCreateInstance(clsid, nullptr, 0x1 | 0x10, iid, ppv);
      if (hr != 0 || ppv.value == nullptr) {
        debugPrint('WindowsTouchKeyboard: CoCreateInstance failed, hr=$hr');
        return false;
      }

      final obj = ppv.value;
      // COM object layout: the first pointer-sized field is the vtable. IUnknown
      // takes slots 0..2 (QueryInterface, AddRef, Release), so ITipInvocation's
      // only method, Toggle(HWND), is slot 3.
      final vtable = Pointer<IntPtr>.fromAddress(obj.cast<IntPtr>().value);
      final toggle = Pointer<NativeFunction<Int32 Function(Pointer<Void>, IntPtr)>>
              .fromAddress(vtable[3])
          .asFunction<int Function(Pointer<Void>, int)>();
      final release =
          Pointer<NativeFunction<Uint32 Function(Pointer<Void>)>>.fromAddress(
                  vtable[2])
              .asFunction<int Function(Pointer<Void>)>();

      final toggleHr = toggle(obj, getDesktopWindow());
      release(obj);
      if (toggleHr != 0) {
        debugPrint('WindowsTouchKeyboard: Toggle failed, hr=$toggleHr');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('WindowsTouchKeyboard: $e');
      return false;
    } finally {
      arena.releaseAll();
    }
  }

  static void _fillGuid(_Guid g, int d1, int d2, int d3, List<int> d4) {
    g.d1 = d1;
    g.d2 = d2;
    g.d3 = d3;
    for (var i = 0; i < 8; i++) {
      g.d4[i] = d4[i];
    }
  }
}

/// Which keyboard actually came up, so callers can keep their UI honest about it
/// instead of assuming the one they asked for.
enum RaisedKeyboard { none, touch, osk }

/// Raises whichever keyboard this machine will actually give us, preferring the
/// modern touch keyboard. The floating button uses this -- its label is just
/// "keyboard", so either one honours it. The toolbar entries deliberately don't:
/// they name a specific keyboard and shouldn't silently raise the other.
Future<RaisedKeyboard> toggleBestWindowsKeyboard() async {
  if (await WindowsTouchKeyboard.toggleTouchKeyboard()) {
    return RaisedKeyboard.touch;
  }
  if (WindowsTouchKeyboard.toggleOsk()) return RaisedKeyboard.osk;
  return RaisedKeyboard.none;
}

final class _Guid extends Struct {
  @Uint32()
  external int d1;
  @Uint16()
  external int d2;
  @Uint16()
  external int d3;
  @Array(8)
  external Array<Uint8> d4;
}
