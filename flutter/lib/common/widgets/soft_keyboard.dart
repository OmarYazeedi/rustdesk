import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// An in-app touch keyboard, for controlling a remote desktop from a touchscreen
/// desktop (tablet mode) where no physical keyboard is attached.
///
/// Windows' own touch keyboard was not a workable option:
///
///  * Flutter's Windows embedder cannot raise it on text-field focus. That's
///    flutter#36057, open since 2019 and still reported in late 2025; the fix
///    needs UIA/TSF support Flutter doesn't have.
///  * Driving it by hand means either `TabTip.exe`, which stopped responding to
///    repeat invocations on Windows 11 (the process stays resident and later
///    launches are no-ops), or the undocumented `ITipInvocation` COM interface.
///
/// The deciding argument is correctness rather than convenience. The system
/// keyboard injects keystrokes with `SendInput`, so they land on the *local*
/// machine first, and Windows swallows the reserved combinations -- Win, Alt+Tab,
/// Ctrl+Esc, Ctrl+Alt+Del -- which are exactly the ones worth having in a remote
/// session. Going through [InputModel.inputKey] sends them straight to the peer
/// and never touches the local OS. It also costs nothing on Linux and macOS.
///
/// Key names are the `VK_*` labels from [physicalKeyMap], which is what a real
/// keyboard produces in RustDesk's map mode, so the peer sees ordinary typing.
class SoftKeyboard extends StatefulWidget {
  final FFI ffi;
  final VoidCallback onClose;

  const SoftKeyboard({Key? key, required this.ffi, required this.onClose})
      : super(key: key);

  @override
  State<SoftKeyboard> createState() => _SoftKeyboardState();
}

/// One key. [name] is the `VK_*` label sent to the peer; [width] is a flex
/// weight, so a row always fills its width whatever the screen size.
class _Key {
  final String label;
  final String name;
  final int width;
  const _Key(this.label, this.name, {this.width = 2});
}

class _SoftKeyboardState extends State<SoftKeyboard> {
  bool _showFnRow = false;

  InputModel get inputModel => widget.ffi.inputModel;

  // Backtick and backslash have no entry in `physicalKeyMap`, so they go as
  // literal characters -- `inputKey` accepts those too, which is how the mobile
  // soft keyboard sends everything.
  static const _row1 = <_Key>[
    _Key('`', '`'),
    _Key('1', 'VK_1'),
    _Key('2', 'VK_2'),
    _Key('3', 'VK_3'),
    _Key('4', 'VK_4'),
    _Key('5', 'VK_5'),
    _Key('6', 'VK_6'),
    _Key('7', 'VK_7'),
    _Key('8', 'VK_8'),
    _Key('9', 'VK_9'),
    _Key('0', 'VK_0'),
    _Key('-', 'VK_MINUS'),
    _Key('=', 'VK_PLUS'),
    _Key('⌫', 'VK_BACK', width: 3),
  ];

  static const _row2 = <_Key>[
    _Key('Tab', 'VK_TAB', width: 3),
    _Key('Q', 'VK_Q'),
    _Key('W', 'VK_W'),
    _Key('E', 'VK_E'),
    _Key('R', 'VK_R'),
    _Key('T', 'VK_T'),
    _Key('Y', 'VK_Y'),
    _Key('U', 'VK_U'),
    _Key('I', 'VK_I'),
    _Key('O', 'VK_O'),
    _Key('P', 'VK_P'),
    _Key('[', 'VK_LBRACKET'),
    _Key(']', 'VK_RBRACKET'),
    _Key('\\', '\\'),
  ];

  static const _row3 = <_Key>[
    _Key('Caps', 'VK_CAPITAL', width: 3),
    _Key('A', 'VK_A'),
    _Key('S', 'VK_S'),
    _Key('D', 'VK_D'),
    _Key('F', 'VK_F'),
    _Key('G', 'VK_G'),
    _Key('H', 'VK_H'),
    _Key('J', 'VK_J'),
    _Key('K', 'VK_K'),
    _Key('L', 'VK_L'),
    _Key(';', 'VK_SEMICOLON'),
    _Key("'", 'VK_QUOTE'),
    _Key('Enter', 'VK_ENTER', width: 4),
  ];

  static const _row4 = <_Key>[
    _Key('Z', 'VK_Z'),
    _Key('X', 'VK_X'),
    _Key('C', 'VK_C'),
    _Key('V', 'VK_V'),
    _Key('B', 'VK_B'),
    _Key('N', 'VK_N'),
    _Key('M', 'VK_M'),
    _Key(',', 'VK_COMMA'),
    // Not VK_DECIMAL -- that's the numpad separator. The main-row period has no
    // `physicalKeyMap` entry, so it goes as a literal character.
    _Key('.', '.'),
    _Key('/', 'VK_SLASH'),
  ];

  static const _fnRow = <_Key>[
    _Key('Esc', 'VK_ESCAPE', width: 3),
    _Key('F1', 'VK_F1'),
    _Key('F2', 'VK_F2'),
    _Key('F3', 'VK_F3'),
    _Key('F4', 'VK_F4'),
    _Key('F5', 'VK_F5'),
    _Key('F6', 'VK_F6'),
    _Key('F7', 'VK_F7'),
    _Key('F8', 'VK_F8'),
    _Key('F9', 'VK_F9'),
    _Key('F10', 'VK_F10'),
    _Key('F11', 'VK_F11'),
    _Key('F12', 'VK_F12'),
  ];

  static const _navRow = <_Key>[
    _Key('Ins', 'VK_INSERT', width: 3),
    _Key('Del', 'VK_DELETE', width: 3),
    _Key('Home', 'VK_HOME', width: 3),
    _Key('End', 'VK_END', width: 3),
    _Key('PgUp', 'VK_PRIOR', width: 3),
    _Key('PgDn', 'VK_NEXT', width: 3),
    _Key('PrtSc', 'VK_PRINT', width: 3),
  ];

  void _send(String name) {
    if (!inputModel.keyboardInputAllowed) return;
    inputModel.inputKey(name);
    // Shift is a one-shot, the way every touch keyboard behaves: it applies to
    // the next key and releases. Ctrl/Alt/Win stay latched, because chords like
    // Ctrl+C then Ctrl+V are the whole point of having them.
    if (inputModel.shift) {
      setState(() => inputModel.shift = false);
    }
  }

  Widget _keyButton(_Key k) {
    return Expanded(
      flex: k.width,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Material(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => _send(k.name),
            // 44 high: a finger target, not a mouse target.
            child: Container(
              height: 44,
              alignment: Alignment.center,
              child: Text(
                k.label,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A latching modifier. Stays lit until tapped off (or, for Shift, until the
  /// next key consumes it).
  Widget _modifierButton(String label, bool active, VoidCallback onTap,
      {int width = 3}) {
    return Expanded(
      flex: width,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Material(
          color: active ? Colors.blueAccent : Colors.white10,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onTap,
            child: Container(
              height: 44,
              alignment: Alignment.center,
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(List<Widget> children) => Row(children: children);

  @override
  Widget build(BuildContext context) {
    final isMac = widget.ffi.ffiModel.pi.platform == kPeerPlatformMacOS;
    return Material(
      color: Colors.black.withOpacity(0.85),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Utility strip: Fn/nav toggle, and a way out.
              _row([
                _modifierButton('Fn', _showFnRow,
                    () => setState(() => _showFnRow = !_showFnRow)),
                _modifierButton(
                    'Ctrl+Alt+Del', false, () => _sendCtrlAltDel(), width: 6),
                const Spacer(flex: 8),
                _modifierButton('Hide ⌄', false, widget.onClose, width: 4),
              ]),
              if (_showFnRow) _row(_fnRow.map(_keyButton).toList()),
              if (_showFnRow) _row(_navRow.map(_keyButton).toList()),
              _row(_row1.map(_keyButton).toList()),
              _row(_row2.map(_keyButton).toList()),
              _row(_row3.map(_keyButton).toList()),
              _row([
                _modifierButton('Shift', inputModel.shift,
                    () => setState(() => inputModel.shift = !inputModel.shift),
                    width: 4),
                ..._row4.map(_keyButton),
                _keyButton(const _Key('↑', 'VK_UP')),
                _modifierButton('Shift', inputModel.shift,
                    () => setState(() => inputModel.shift = !inputModel.shift),
                    width: 4),
              ]),
              _row([
                _modifierButton('Ctrl', inputModel.ctrl,
                    () => setState(() => inputModel.ctrl = !inputModel.ctrl)),
                _modifierButton(
                    isMac ? 'Cmd' : 'Win',
                    inputModel.command,
                    () => setState(
                        () => inputModel.command = !inputModel.command)),
                _modifierButton('Alt', inputModel.alt,
                    () => setState(() => inputModel.alt = !inputModel.alt)),
                _keyButton(const _Key('Space', 'VK_SPACE', width: 14)),
                _keyButton(const _Key('←', 'VK_LEFT')),
                _keyButton(const _Key('↓', 'VK_DOWN')),
                _keyButton(const _Key('→', 'VK_RIGHT')),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  /// Ctrl+Alt+Del can't be sent as a chord from the latched modifiers -- the
  /// local OS would intercept it if it ever reached the system. It goes to the
  /// peer as an explicit request instead.
  void _sendCtrlAltDel() {
    if (!inputModel.keyboardInputAllowed) return;
    bind.sessionCtrlAltDel(sessionId: widget.ffi.sessionId);
  }
}
