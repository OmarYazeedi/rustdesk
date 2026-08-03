import 'package:flutter/material.dart';

/// The line at the foot of the device list.
///
/// Deliberately almost invisible: it should read as a faint watermark to anyone
/// who isn't looking for it, and only land as a joke once someone is told what
/// the app is called. Lowercase, letter-spaced, and at an opacity where it sits
/// below the divider line in the visual hierarchy rather than beside it.
///
/// Kept non-interactive so it can never take a tap meant for the list above it.
class PortalMark extends StatelessWidget {
  const PortalMark({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return IgnorePointer(
      child: Container(
        width: double.infinity,
        alignment: Alignment.center,
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Text(
          'i hate portals',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 2.2,
            fontWeight: FontWeight.w300,
            // Against the surface colour rather than a fixed grey, so it stays
            // equally faint in light and dark themes instead of turning into a
            // legible line on one of them.
            color: onSurface.withOpacity(0.13),
          ),
        ),
      ),
    );
  }
}
