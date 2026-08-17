import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';

import 'peer_card.dart';

/// One device list instead of five tabs.
///
/// The tabs were five separate `Peers` models, each bound to its own load event
/// from the Rust side. Rather than re-plumbing that, this composes the models
/// that already exist and merges what they hold, so a device that is both a
/// favourite and recently used appears once, wearing both marks, instead of
/// twice in two lists.
///
/// What a device *is* becomes a property of the row rather than which tab you
/// happened to be looking at.
enum PeerSource { recent, favourite, lan, addressBook, group }

extension _SourceLook on PeerSource {
  IconData get icon {
    switch (this) {
      case PeerSource.recent:
        return Icons.history_rounded;
      case PeerSource.favourite:
        return Icons.star_rounded;
      case PeerSource.lan:
        return Icons.wifi_tethering_rounded;
      case PeerSource.addressBook:
        return Icons.menu_book_rounded;
      case PeerSource.group:
        return Icons.group_rounded;
    }
  }

  String get label {
    switch (this) {
      case PeerSource.recent:
        return 'Recent';
      case PeerSource.favourite:
        return 'Favorites';
      case PeerSource.lan:
        return 'Discovered';
      case PeerSource.addressBook:
        return 'Address book';
      case PeerSource.group:
        return 'Group';
    }
  }

  /// Which option key remembers whether this source is shown.
  String get optionKey => '$kOptionUnifiedShowPrefix${name}';
}

/// How the list is ranked.
enum PeerSort {
  /// Favourites, then recently used, then everything else. The default,
  /// because it matches what people reach for most.
  priority,
  name,
  online,
}

class _Entry {
  final Peer peer;
  final Set<PeerSource> sources;
  /// Position in the recent list, so "priority" can preserve recency order
  /// rather than falling back to whatever order the merge happened to produce.
  final int recentRank;
  _Entry(this.peer, this.sources, this.recentRank);

  bool get isFavourite => sources.contains(PeerSource.favourite);
  bool get isRecent => sources.contains(PeerSource.recent);
}

class UnifiedPeersView extends StatefulWidget {
  final EdgeInsets? menuPadding;
  const UnifiedPeersView({Key? key, this.menuPadding}) : super(key: key);

  @override
  State<UnifiedPeersView> createState() => _UnifiedPeersViewState();
}

class _UnifiedPeersViewState extends State<UnifiedPeersView>
    with WidgetsBindingObserver {
  late Set<PeerSource> _shown;
  late PeerSort _sort;

  // Online status is not pushed by the server; something has to ask for it.
  // Upstream's `_PeersViewState` ran this poll, and replacing that widget with
  // this one dropped it -- leaving `Peer.online` frozen at whatever it loaded
  // with, so the status dot never moved. Same cadence and the same guards as
  // upstream, deliberately: a faster poll here is paid for in battery.
  static const int _maxQueryCount = 3;
  final _curPeers = <String>{};
  var _lastQueryPeers = <String>{};
  var _lastChangeTime = DateTime.now();
  var _lastQueryTime = DateTime.now().subtract(const Duration(hours: 1));
  var _queryCount = 0;
  var _exit = false;
  var _queryInterval = const Duration(seconds: 20);

  Map<PeerSource, Peers> get _models => {
        PeerSource.recent: gFFI.recentPeersModel,
        PeerSource.favourite: gFFI.favoritePeersModel,
        PeerSource.lan: gFFI.lanPeersModel,
        PeerSource.addressBook: gFFI.abModel.peersModel,
        PeerSource.group: gFFI.groupModel.peersModel,
      };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCheckOnlines();
    // Everything on by default, and written out on first run rather than
    // inferred from absent keys -- an empty-looking list on a fresh config is
    // indistinguishable from a broken one.
    _shown = {};
    for (final s in PeerSource.values) {
      final v = bind.mainGetLocalOption(key: s.optionKey);
      if (v.isEmpty) {
        bind.mainSetLocalOption(key: s.optionKey, value: 'Y');
        _shown.add(s);
      } else if (v != 'N') {
        _shown.add(s);
      }
    }
    _sort = PeerSort.values.firstWhere(
      (s) => s.name == bind.mainGetLocalOption(key: kOptionUnifiedSort),
      orElse: () => PeerSort.priority,
    );
    // The models only populate once something asks them to. The tabs each did
    // this on the way in; with one list, all of it has to be asked for here --
    // including the address book and group, which the tab entries pulled
    // separately and which would otherwise stay permanently empty.
    bind.mainLoadRecentPeers();
    bind.mainLoadFavPeers();
    bind.mainLoadLanPeers();
    bind.mainDiscover();
    try {
      gFFI.abModel.pullAb(force: ForcePullAb.listAndCurrent, quiet: true);
      gFFI.groupModel.pull(force: false);
    } catch (_) {
      // Not signed in, or no group. Neither is an error worth surfacing here.
    }
  }

  @override
  void dispose() {
    _exit = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Coming back from the background, the dots on screen are as old as the
    // time spent away, so re-ask immediately instead of waiting out the
    // interval. While away, the skip below stops the polling entirely.
    if (state == AppLifecycleState.resumed) {
      _queryCount = 0;
      _queryOnlines(false);
    }
  }

  void _startCheckOnlines() {
    () async {
      final usingPublic = await bind.mainIsUsingPublicServer();
      if (!usingPublic) {
        // Our own server can be asked more often without being a bad citizen.
        _queryInterval = const Duration(seconds: 6);
      }
      while (!_exit) {
        final now = DateTime.now();
        if (!setEquals(_curPeers, _lastQueryPeers)) {
          if (now.difference(_lastChangeTime) > const Duration(seconds: 1)) {
            _queryOnlines(false);
          }
        } else {
          // Off the main page the list is not visible, so polling there is
          // pure battery cost. On the public server we also stop after a few
          // rounds, as upstream does, rather than poll their infrastructure
          // forever.
          final skip = (isAndroid || isIOS) && !stateGlobal.isInMainPage;
          if (!skip && (_queryCount < _maxQueryCount || !usingPublic)) {
            if (now.difference(_lastQueryTime) >= _queryInterval &&
                _curPeers.isNotEmpty) {
              bind.queryOnlines(ids: _curPeers.toList(growable: false));
              _lastQueryTime = DateTime.now();
              _queryCount += 1;
            }
          }
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }();
  }

  void _queryOnlines(bool isLoadEvent) {
    if (_curPeers.isNotEmpty) {
      bind.queryOnlines(ids: _curPeers.toList(growable: false));
      _queryCount = 0;
    }
    _lastQueryPeers = {..._curPeers};
    if (isLoadEvent) {
      _lastChangeTime = DateTime.now();
    } else {
      _lastQueryTime = DateTime.now().subtract(_queryInterval);
    }
  }

  List<_Entry> _merge() {
    final flags = <String, Set<PeerSource>>{};
    final byId = <String, Peer>{};
    final recentRank = <String, int>{};

    _models.forEach((source, model) {
      for (var i = 0; i < model.peers.length; i++) {
        final p = model.peers[i];
        if (p.id.isEmpty) continue;
        // First writer wins for the Peer object itself; the address book
        // carries aliases and tags the local lists don't, so it goes last and
        // overwrites, giving the richest record.
        byId[p.id] = p;
        (flags[p.id] ??= <PeerSource>{}).add(source);
        if (source == PeerSource.recent) recentRank[p.id] = i;
      }
    });

    final entries = byId.entries
        .map((e) => _Entry(e.value, flags[e.key]!, recentRank[e.key] ?? 1 << 30))
        .where((e) => e.sources.any(_shown.contains))
        .toList();

    switch (_sort) {
      case PeerSort.priority:
        entries.sort((a, b) {
          if (a.isFavourite != b.isFavourite) return a.isFavourite ? -1 : 1;
          if (a.isRecent != b.isRecent) return a.isRecent ? -1 : 1;
          if (a.recentRank != b.recentRank) {
            return a.recentRank.compareTo(b.recentRank);
          }
          return _name(a).compareTo(_name(b));
        });
        break;
      case PeerSort.name:
        entries.sort((a, b) =>
            _name(a).toLowerCase().compareTo(_name(b).toLowerCase()));
        break;
      case PeerSort.online:
        entries.sort((a, b) {
          if (a.peer.online != b.peer.online) return a.peer.online ? -1 : 1;
          return _name(a).compareTo(_name(b));
        });
        break;
    }
    return entries;
  }

  static String _name(_Entry e) =>
      e.peer.alias.isNotEmpty ? e.peer.alias : e.peer.id;

  void _toggleSource(PeerSource s) {
    setState(() {
      if (_shown.contains(s)) {
        _shown.remove(s);
      } else {
        _shown.add(s);
      }
    });
    bind.mainSetLocalOption(
        key: s.optionKey, value: _shown.contains(s) ? 'Y' : 'N');
  }

  void _cycleSort() {
    setState(() {
      _sort = PeerSort
          .values[(PeerSort.values.indexOf(_sort) + 1) % PeerSort.values.length];
    });
    bind.mainSetLocalOption(key: kOptionUnifiedSort, value: _sort.name);
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
        ...PeerSource.values.map((s) {
          final on = _shown.contains(s);
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              avatar: Icon(s.icon, size: 16),
              label: Text(translate(s.label)),
              selected: on,
              // Without this the selected state swaps the source icon for a
              // tick, so a row of selected chips loses the very glyphs that say
              // what each one is.
              showCheckmark: false,
              onSelected: (_) => _toggleSource(s),
              visualDensity: VisualDensity.compact,
            ),
          );
        }),
        const SizedBox(width: 4),
        Tooltip(
          message: translate('Sort by'),
          child: ActionChip(
            avatar: const Icon(Icons.sort_rounded, size: 16),
            label: Text(translate(_sortLabel)),
            onPressed: _cycleSort,
            visualDensity: VisualDensity.compact,
          ),
        ),
        ]),
      ),
    );
  }

  String get _sortLabel {
    switch (_sort) {
      case PeerSort.priority:
        return 'Priority';
      case PeerSort.name:
        return 'Name';
      case PeerSort.online:
        return 'Online';
    }
  }

  /// The marks that say what a device is. Drawn on the card rather than beside
  /// it so the answer travels with the row when the list is re-sorted.
  Widget _marks(_Entry e) {
    final colour = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: PeerSource.values
          .where(e.sources.contains)
          .map((s) => Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Icon(s.icon, size: 13, color: colour.withOpacity(0.85)),
              ))
          .toList(),
    );
  }

  /// The card type decides the right-click menu, so pick by the most specific
  /// thing the device is: an address-book entry wants "edit tags", a discovered
  /// one wants "forget", and so on.
  Widget _card(_Entry e) {
    final p = e.peer;
    final pad = widget.menuPadding;
    if (e.sources.contains(PeerSource.addressBook)) {
      return AddressBookPeerCard(peer: p, menuPadding: pad);
    }
    if (e.sources.contains(PeerSource.favourite)) {
      return FavoritePeerCard(peer: p, menuPadding: pad);
    }
    if (e.sources.contains(PeerSource.recent)) {
      return RecentPeerCard(peer: p, menuPadding: pad);
    }
    return DiscoveredPeerCard(peer: p, menuPadding: pad);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(_models.values.toList()),
      builder: (context, _) {
        final entries = _merge();
        // Whatever is on screen is what we want status for. The poll compares
        // this against the last set it asked about, so a device appearing --
        // from a fresh address-book pull, or a LAN discovery -- gets queried
        // rather than waiting out the interval showing a stale dot.
        final ids = entries.map((e) => e.peer.id).toSet();
        if (!setEquals(ids, _curPeers)) {
          _curPeers
            ..clear()
            ..addAll(ids);
          _lastChangeTime = DateTime.now();
        }
        // The multi-select bar and the toolbar actions read the current tab's
        // cached peers. With the tabs gone, this list is what they should see.
        gFFI.peerTabModel
            .setCurrentTabCachedPeers(entries.map((e) => e.peer).toList());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _controls(),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        translate('Empty'),
                        style: TextStyle(
                            color: Theme.of(context).disabledColor,
                            fontSize: 13),
                      ),
                    )
                  : SingleChildScrollView(
                      child: Wrap(
                        children: entries
                            .map((e) => Stack(children: [
                                  _card(e),
                                  Positioned(
                                    right: 8,
                                    top: 6,
                                    child: _marks(e),
                                  ),
                                ]))
                            .toList(),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
