import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common.dart';

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

  /// Why the last attempt went the way it did.
  ///
  /// `debugPrint` is useless here: a released Windows app has no console
  /// attached, so anything printed goes nowhere and there is nothing to find in
  /// a log afterwards. This is kept so the UI can show the reason directly, and
  /// it's also written next to the config so it can be sent on.
  static String lastDiagnostic = '';

  static final List<String> _steps = [];

  static void _note(String s) {
    _steps.add(s);
    debugPrint('WindowsTouchKeyboard: $s');
  }

  /// Common HRESULTs, named. A bare 0x80040154 tells you nothing at a glance.
  static String _hr(int hr) {
    final hex = '0x${(hr & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';
    switch (hr & 0xFFFFFFFF) {
      case 0x80040154:
        return '$hex REGDB_E_CLASSNOTREG (TabTip not running / class absent)';
      case 0x80070005:
        return '$hex E_ACCESSDENIED';
      case 0x800401F0:
        return '$hex CO_E_NOTINITIALIZED';
      case 0x80004002:
        return '$hex E_NOINTERFACE (ITipInvocation not supported here)';
      default:
        return hex;
    }
  }

  static void finishDiagnostic() {
    lastDiagnostic = _steps.join('\n');
    _steps.clear();
    try {
      final appData = Platform.environment['APPDATA'];
      if (appData == null) return;
      final dir = Directory('$appData\\RustDesk Touch');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File('${dir.path}\\keyboard-diagnostic.txt')
          .writeAsStringSync('$lastDiagnostic\n');
    } catch (_) {
      // Diagnostics must never be the thing that breaks the feature.
    }
  }

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
        _note('TabTip.exe not present at $_tabTipPath');
        return false;
      }
      await Process.start(_tabTipPath, const [],
          mode: ProcessStartMode.detached);
      _note('started TabTip.exe');
    } catch (e) {
      _note('could not start TabTip.exe: $e');
      return false;
    }

    for (var i = 0; i < 10; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (_tryToggle()) return true;
    }
    _note('TabTip started but Toggle never took after 2.5s');
    return false;
  }

  /// Windows' accessibility On-Screen Keyboard (Settings > Accessibility >
  /// Keyboard). A plain floating window rather than the modern touch keyboard,
  /// but it launches on every Windows version with no COM and nothing
  /// undocumented involved -- so unlike TabTip it can be relied on.
  static bool _oskShown = false;

  static bool get oskShown => _oskShown;

  static Future<bool> toggleOsk() async {
    if (!Platform.isWindows) return false;
    try {
      if (_oskShown) {
        final r = Process.runSync('taskkill', const ['/IM', 'osk.exe', '/F']);
        _oskShown = false;
        _note('taskkill osk.exe -> exit ${r.exitCode} ${r.stderr}'.trim());
        return true;
      }
      // Awaited deliberately. `Process.start` returns a Future, so an unawaited
      // call reports its failure as an unhandled async error that the try/catch
      // here never sees -- which meant a launch that failed still set _oskShown
      // and claimed success.
      //
      // System32 is spelled out rather than relying on PATH: on 64-bit Windows a
      // bare "osk.exe" is subject to WOW64 redirection, and osk.exe does not
      // exist under SysWOW64.
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final osk = '$root\\System32\\osk.exe';
      if (!File(osk).existsSync()) {
        _note('osk.exe not found at $osk');
        return false;
      }
      final p = await Process.start(osk, const [],
          mode: ProcessStartMode.detached);
      _oskShown = true;
      _note('osk.exe started, pid ${p.pid}');
      return true;
    } catch (e) {
      _note('osk.exe failed: $e');
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
        _note('CoCreateInstance(UIHostNoLaunch) -> ${_hr(hr)}');
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
        _note('ITipInvocation::Toggle -> ${_hr(toggleHr)}');
        return false;
      }
      _note('ITipInvocation::Toggle -> ok');
      return true;
    } catch (e) {
      _note('COM path threw: $e');
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
  RaisedKeyboard result;
  if (await WindowsTouchKeyboard.toggleTouchKeyboard()) {
    result = RaisedKeyboard.touch;
  } else if (await WindowsTouchKeyboard.toggleOsk()) {
    result = RaisedKeyboard.osk;
  } else {
    result = RaisedKeyboard.none;
  }
  WindowsTouchKeyboard.finishDiagnostic();
  // Say when the nice keyboard couldn't be had, rather than quietly producing a
  // different one and leaving it looking like a bug. The full reason is in
  // %APPDATA%\RustDesk Touch\keyboard-diagnostic.txt.
  if (result != RaisedKeyboard.touch) {
    showToast(result == RaisedKeyboard.osk
        ? 'Touch keyboard unavailable - using On-Screen Keyboard'
        : 'No Windows keyboard available - using the in-app one');
  }
  return result;
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
