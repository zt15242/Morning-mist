import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_hover.dart';
import '../../ide/ide_menu.dart';
import '../../l10n/l10n.dart';
import '../../link/link_host.dart';
import '../../link/phone_downloads.dart';
import '../../link/qr_view.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

/// Settings → Mobile: whether phones may connect, how this computer stands
/// with its relays (and relays of one's own), pairing one by QR code, and the
/// phones paired, each with its path while connected.
class MobileSettingsPage extends StatefulWidget {
  const MobileSettingsPage({super.key, required this.host});

  final LinkHost host;

  @override
  State<MobileSettingsPage> createState() => _MobileSettingsPageState();
}

class _MobileSettingsPageState extends State<MobileSettingsPage> {
  bool _copied = false;
  Timer? _copiedTimer;

  /// The relays' settings shown: folded at first, as few change them.
  bool _relaysOpen = false;

  /// Custom picked to add, its address not yet given; and what is wrong
  /// with the address typed.
  bool _customPicked = false;
  String? _customError;

  /// What is wrong with the direct port typed.
  String? _portError;

  /// Ticks while a code shows, for it to say when it expired, and while
  /// phones are connected, for their round trips.
  Timer? _ticker;

  LinkHost get _host => widget.host;

  @override
  void initState() {
    super.initState();
    _host.addListener(_changed);
    unawaited(_host.refresh());
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_host.offer != null || _host.phones.any(_connected)) setState(() {});
    });
  }

  bool _connected(PairedPhone phone) => _host.isConnected(phone.id);

  @override
  void dispose() {
    _host.removeListener(_changed);
    _copiedTimer?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _copy(String link) {
    unawaited(Clipboard.setData(ClipboardData(text: link)));
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  /// A relay's URL as shown: its host (and port, when one is given).
  static String _relayName(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  String _status(AppLocalizations l10n) {
    final host = _host;
    switch (host.status) {
      case LinkHostStatus.off:
        return l10n.mobileStatusOff;
      case LinkHostStatus.starting:
        return l10n.mobileStatusStarting;
      case LinkHostStatus.failed:
        return l10n.mobileStatusFailed(host.error ?? '');
      case LinkHostStatus.listening:
        if (host.relayMode == LinkRelayMode.direct) {
          return l10n.mobileStatusDirect;
        }
        final info = host.info;
        if (info?.denied case final reason?) {
          return l10n.mobileStatusDenied(reason);
        }
        final home = info?.home.where((s) => s.connected).firstOrNull;
        if (home == null) return l10n.mobileStatusNoRelay;
        return l10n.mobileStatusOnline(_relayName(home.url));
    }
  }

  static String _path(AppLocalizations l10n, LinkPath path) => [
    switch (path.kind) {
      LinkPathKind.lan => l10n.mobilePathLan,
      LinkPathKind.direct => l10n.mobilePathDirect,
      LinkPathKind.relay => l10n.mobilePathRelay,
      LinkPathKind.none => l10n.mobilePhoneConnected,
    },
    if (path.rtt case final rtt?) l10n.mobilePathRtt(rtt.inMilliseconds),
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = _host;
    return SettingsPage(
      title: l10n.settingsSectionMobile,
      description: l10n.mobileSettingsDescription,
      children: [
        // The app first: no phone pairs without it.
        SettingsGroup(
          title: l10n.mobileGetApp,
          description: l10n.mobileGetAppDescription,
          children: const [_PhoneDownloads()],
        ),
        SettingsCard(
          children: [
            _ConnectionOverview(status: _status(l10n), kind: host.status),
            SettingsSwitchRow(
              label: l10n.mobileAllow,
              description: l10n.mobileAllowDescription,
              value: host.enabled,
              onChanged: (value) => unawaited(host.setEnabled(value)),
            ),
            SettingsSwitchRow(
              label: l10n.mobileDiscoverable,
              description: l10n.mobileDiscoverableDescription,
              value: host.discoverable,
              onChanged: host.setDiscoverable,
            ),
          ],
        ),
        SettingsFolding(
          title: l10n.mobileRelay,
          description: host.relayMode == LinkRelayMode.direct
              ? null
              : l10n.mobileRelayDescription,
          summary: _relaysSummary(l10n),
          open: _relaysOpen,
          onToggle: () => setState(() => _relaysOpen = !_relaysOpen),
          children: [
            _relayMode(l10n),
            if (host.relayMode == LinkRelayMode.pinned) ...[
              for (final (index, url) in host.relays.indexed)
                _listedRelay(l10n, index, url),
              _addRelay(l10n),
              if (_customPicked) _customRelay(l10n),
            ],
            if (host.relayMode == LinkRelayMode.direct) ...[
              _directPort(l10n),
              _directAddress(l10n),
            ],
          ],
        ),
        SettingsGroup(title: l10n.mobilePair, children: [_pairing(context)]),
        SettingsGroup(
          title: l10n.mobilePhones,
          children: [
            if (host.phones.isEmpty && host.legacyPhones.isEmpty)
              SettingsRow(label: l10n.mobilePhonesNone),
            for (final phone in host.phones)
              _PairedPhoneCard(
                name: phone.name.isEmpty ? phone.fingerprint : phone.name,
                system: phone.system,
                connected: host.isConnected(phone.id),
                detail: [
                  if (host.pathOf(phone.id) case final path?)
                    _path(l10n, path)
                  else if (host.isConnected(phone.id))
                    l10n.mobilePhoneConnected
                  else if (phone.lastSeen case final seen?)
                    l10n.mobilePhoneLastSeen(_time(seen)),
                ].join(' · '),
                removeLabel: l10n.mobilePhoneRemove,
                onRemove: () => host.unpair(phone),
              ),
            for (final phone in host.legacyPhones)
              _LegacyPhoneCard(
                name: phone.name.isEmpty ? phone.system : phone.name,
                system: phone.system,
                legacyLabel: l10n.mobileLegacyPhone,
                repairLabel: l10n.mobileLegacyRepair,
                removeLabel: l10n.mobilePhoneRemove,
                supported: host.supported,
                onRepair: () => unawaited(host.beginPairing()),
                onRemove: () => host.forgetLegacy(phone),
              ),
            SettingsRow(
              label: l10n.mobileThisComputerKey,
              description: l10n.mobileThisComputerKeyDescription,
              below: [
                SelectableText(host.fingerprint, style: SettingsText.path),
              ],
            ),
          ],
        ),
      ],
    );
  }

  static String _modeName(AppLocalizations l10n, LinkRelayMode mode) =>
      switch (mode) {
        LinkRelayMode.auto => l10n.mobileRelayModeAuto,
        LinkRelayMode.pinned => l10n.mobileRelayModePinned,
        LinkRelayMode.direct => l10n.mobileRelayModeDirect,
      };

  /// Folded, beside the heading: how they are chosen, and those listed
  /// when they are.
  String _relaysSummary(AppLocalizations l10n) {
    final host = _host;
    return [
      _modeName(l10n, host.relayMode),
      if (host.relayMode == LinkRelayMode.pinned)
        host.relays.map(_relayName).join(' → '),
    ].join(' · ');
  }

  Widget _relayMode(AppLocalizations l10n) {
    final host = _host;
    final current = host.relayMode;
    return SettingsRow(
      label: l10n.mobileRelayMode,
      description: switch (current) {
        LinkRelayMode.auto => l10n.mobileRelayModeAutoDescription,
        LinkRelayMode.pinned => l10n.mobileRelayModePinnedDescription,
        LinkRelayMode.direct => l10n.mobileRelayModeDirectDescription,
      },
      trailing: SettingsDropdown(
        current: _modeName(l10n, current),
        semanticLabel: '${l10n.mobileRelayMode}: ${_modeName(l10n, current)}',
        entries: () => [
          for (final mode in LinkRelayMode.values)
            IdeMenuAction(
              _modeName(l10n, mode),
              checked: mode == current,
              onSelected: () {
                setState(() => _customPicked = false);
                unawaited(host.setRelayMode(mode));
              },
            ),
        ],
      ),
    );
  }

  /// One of the relays listed, at [index]: moved up or down, or removed
  /// while it is not the last left.
  Widget _listedRelay(AppLocalizations l10n, int index, String url) {
    final host = _host;
    final list = host.relays;
    void move(int to) {
      final moved = [...list]..removeAt(index);
      moved.insert(to, url);
      unawaited(host.setPinnedRelays(moved));
    }

    final notes = [
      if (!defaultLinkRelays.contains(url)) l10n.mobileRelayCustom,
      if (url == host.activeRelay && host.info?.online == true)
        l10n.mobileRelayInUse,
    ];
    return SettingsRow(
      label: '${index + 1}. ${_relayName(url)}',
      description: notes.isEmpty ? null : notes.join(' · '),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IdeActionButton(
            icon: Codicons.arrowUp,
            tooltip: l10n.mobileRelayMoveUp,
            onPressed: index == 0 ? null : () => move(index - 1),
          ),
          IdeActionButton(
            icon: Codicons.arrowDown,
            tooltip: l10n.mobileRelayMoveDown,
            onPressed: index == list.length - 1 ? null : () => move(index + 1),
          ),
          IdeActionButton(
            icon: Codicons.close,
            tooltip: l10n.mobileRelayRemove,
            onPressed: list.length < 2
                ? null
                : () => unawaited(
                    host.setPinnedRelays([...list]..removeAt(index)),
                  ),
          ),
        ],
      ),
    );
  }

  /// Adds one of BaoCode's relays not listed yet, or Custom: an address
  /// typed below.
  Widget _addRelay(AppLocalizations l10n) {
    final host = _host;
    final listed = host.relays;
    final current = _customPicked
        ? l10n.mobileRelayCustom
        : l10n.mobileRelayAddPick;
    return SettingsRow(
      label: l10n.mobileRelayAdd,
      trailing: SettingsDropdown(
        current: current,
        semanticLabel: '${l10n.mobileRelayAdd}: $current',
        entries: () => [
          for (final url in defaultLinkRelays)
            if (!listed.contains(url))
              IdeMenuAction(
                _relayName(url),
                onSelected: () {
                  setState(() {
                    _customPicked = false;
                    _customError = null;
                  });
                  unawaited(host.setPinnedRelays([...listed, url]));
                },
              ),
          if (defaultLinkRelays.any((url) => !listed.contains(url)))
            const IdeMenuSeparator(),
          IdeMenuAction(
            l10n.mobileRelayCustom,
            checked: _customPicked,
            onSelected: () => setState(() => _customPicked = true),
          ),
        ],
      ),
    );
  }

  /// Custom: the address of one's own relay, listed last once it is
  /// entered.
  Widget _customRelay(AppLocalizations l10n) => SettingsRow(
    label: l10n.mobileRelayCustomAddress,
    description: _customError ?? l10n.mobileRelayCustomDescription,
    trailing: SettingsTextField(
      value: '',
      hint: 'https://relay.example.com',
      semanticLabel: l10n.mobileRelayCustomAddress,
      width: 260,
      autofocus: true,
      onSubmitted: (text) {
        final url = parseRelayUrl(text);
        setState(() {
          _customError = url == null && text.isNotEmpty
              ? l10n.mobileRelayInvalid
              : null;
          if (url != null) _customPicked = false;
        });
        if (url != null) {
          unawaited(_host.setPinnedRelays([..._host.relays, url]));
        }
      },
    ),
  );

  /// Direct-only: the UDP port phones are told, and where this computer
  /// can be reached at it.
  Widget _directPort(AppLocalizations l10n) => SettingsRow(
    label: l10n.mobileDirectPort,
    description: _portError ?? l10n.mobileDirectPortDescription,
    trailing: SettingsTextField(
      value: '${_host.linkPort}',
      hint: '$defaultLinkPort',
      semanticLabel: l10n.mobileDirectPort,
      width: 120,
      onSubmitted: (text) {
        final port = int.tryParse(text);
        if (port == null || !LinkHost.validLinkPort(port)) {
          setState(() => _portError = l10n.mobileDirectPortInvalid);
          return;
        }
        setState(() => _portError = null);
        unawaited(_host.setLinkPort(port));
      },
    ),
  );

  Widget _directAddress(AppLocalizations l10n) {
    final addrs = [
      for (final addr in _host.info?.addrs ?? const <String>[])
        if (!isLanAddress(addr)) addr,
    ];
    return SettingsRow(
      label: l10n.mobileDirectAddress,
      description: addrs.isEmpty
          ? l10n.mobileDirectAddressNone
          : l10n.mobileDirectAddressDescription,
      below: [
        if (addrs.isNotEmpty)
          SelectableText(addrs.join('\n'), style: SettingsText.path),
      ],
    );
  }

  /// The pairing card's row: a button to show a code; the code; the
  /// safety code to compare once a phone scanned it; who was paired.
  Widget _pairing(BuildContext context) {
    final l10n = context.l10n;
    final host = _host;
    final offer = host.offer;
    final pending = host.pending;
    if (pending != null) {
      final name = pending.name.isEmpty ? pending.system : pending.name;
      if (pending.needsApproval) {
        // Found nearby, with no code scanned: allowed here, or not.
        return _PairingPanel(
          icon: Codicons.personAdd,
          title: l10n.mobilePairRequestTitle(name),
          description: l10n.mobilePairRequestBody,
          content: _SafetyCode(code: pending.code),
          actions: !pending.approved
              ? SettingsButtons(
                  children: [
                    IdeButton(
                      label: l10n.mobilePairAllow,
                      icon: Codicons.check,
                      onPressed: host.approvePending,
                    ),
                    IdeButton(
                      label: l10n.mobilePairMismatch,
                      secondary: true,
                      onPressed: host.rejectPending,
                    ),
                  ],
                )
              : null,
        );
      }
      return _PairingPanel(
        icon: Codicons.shield,
        title: l10n.mobilePairVerifyTitle(name),
        description: l10n.mobilePairVerifyBody,
        content: _SafetyCode(code: pending.code),
        actions: SettingsButtons(
          children: [
            IdeButton(
              label: l10n.mobilePairMismatch,
              secondary: true,
              onPressed: host.rejectPending,
            ),
          ],
        ),
      );
    }
    if (offer != null) {
      final expired = offer.expiredAt(DateTime.now());
      final link = offer.uri;
      return _PairingPanel(
        icon: Codicons.link,
        title: l10n.mobilePair,
        description: expired
            ? l10n.mobilePairExpired
            : [
                l10n.mobilePairExpires(host.offerLifetime.inMinutes),
                if (host.advertised) l10n.mobilePairNearbyHint,
              ].join(' '),
        content: !expired
            ? Padding(
                padding: const EdgeInsets.only(top: 4),
                // Clicked, its link copied: for a phone that cannot scan
                // it (the same as Copy Link under it).
                child: Center(
                  child: IdeHover(
                    message: _copied
                        ? l10n.mobilePairCopied
                        : l10n.mobilePairQrHint,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => _copy(link),
                        child: QrView(data: link),
                      ),
                    ),
                  ),
                ),
              )
            : null,
        actions: SettingsButtons(
          children: [
            IdeButton(
              label: l10n.mobilePairNewCode,
              icon: Codicons.refresh,
              secondary: true,
              onPressed: () => unawaited(host.beginPairing()),
            ),
            if (!expired)
              IdeButton(
                label: _copied
                    ? l10n.mobilePairCopied
                    : l10n.mobilePairCopyLink,
                icon: _copied ? Codicons.check : Codicons.copy,
                secondary: true,
                onPressed: () => _copy(link),
              ),
            IdeButton(
              label: l10n.mobilePairCancel,
              secondary: true,
              onPressed: host.endPairing,
            ),
          ],
        ),
      );
    }
    final paired = host.justPaired;
    return _PairingPanel(
      icon: paired == null ? Codicons.deviceMobile : Codicons.check,
      title: l10n.mobilePair,
      description: paired == null
          ? l10n.mobilePairDescription
          : l10n.mobilePaired(paired.name),
      actions: paired == null
          ? SettingsButtons(
              children: [
                IdeButton(
                  label: l10n.mobilePairShow,
                  icon: Codicons.deviceMobile,
                  expand: true,
                  onPressed: host.supported
                      ? () => unawaited(host.beginPairing())
                      : null,
                ),
              ],
            )
          : null,
    );
  }

  static String _time(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

class _ConnectionOverview extends StatelessWidget {
  const _ConnectionOverview({required this.status, required this.kind});

  final String status;
  final LinkHostStatus kind;

  @override
  Widget build(BuildContext context) {
    final color = switch (kind) {
      LinkHostStatus.listening => AppColors.added,
      LinkHostStatus.starting => AppColors.accent,
      LinkHostStatus.failed => AppColors.caution,
      LinkHostStatus.off => SettingsColors.textQuaternary,
    };
    final icon = switch (kind) {
      LinkHostStatus.listening => Codicons.radioTower,
      LinkHostStatus.starting => Codicons.sync,
      LinkHostStatus.failed => Codicons.warning,
      LinkHostStatus.off => Codicons.plug,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 17, color: color),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  style: SettingsText.label.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          _StatusPill(label: kind.name, color: color),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );
}

class _PairingPanel extends StatelessWidget {
  const _PairingPanel({
    required this.icon,
    required this.title,
    required this.description,
    this.content,
    this.actions,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? content;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 17, color: SettingsColors.iconTertiary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: SettingsText.label.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(description, style: SettingsText.description),
                ],
              ),
            ),
          ],
        ),
        if (content case final content?) ...[
          const SizedBox(height: 14),
          content,
        ],
        if (actions case final actions?) ...[
          const SizedBox(height: 14),
          Align(alignment: AlignmentDirectional.centerEnd, child: actions),
        ],
      ],
    ),
  );
}

class _SafetyCode extends StatelessWidget {
  const _SafetyCode({required this.code});

  final List<String> code;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: SettingsColors.hover,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: SettingsColors.stroke),
    ),
    child: Text(
      code.join('  '),
      textAlign: TextAlign.center,
      style: SettingsText.path.copyWith(
        fontSize: 26,
        fontWeight: FontWeight.w600,
        letterSpacing: 2,
      ),
    ),
  );
}

class _PairedPhoneCard extends StatelessWidget {
  const _PairedPhoneCard({
    required this.name,
    required this.system,
    required this.connected,
    required this.detail,
    required this.removeLabel,
    required this.onRemove,
  });

  final String name;
  final String system;
  final bool connected;
  final String detail;
  final String removeLabel;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final stateColor = connected
        ? AppColors.added
        : SettingsColors.textTertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Codicons.deviceMobile, size: 17, color: stateColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: SettingsText.label.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (system.isNotEmpty)
                      Text(system, style: SettingsText.description),
                  ],
                ),
              ),
              if (connected)
                _StatusPill(
                  label: context.l10n.mobilePhoneConnected,
                  color: AppColors.added,
                ),
            ],
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(detail, style: SettingsText.path),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: IdeButton(
              label: removeLabel,
              icon: Codicons.trash,
              secondary: true,
              onPressed: onRemove,
            ),
          ),
        ],
      ),
    );
  }
}

class _LegacyPhoneCard extends StatelessWidget {
  const _LegacyPhoneCard({
    required this.name,
    required this.system,
    required this.legacyLabel,
    required this.repairLabel,
    required this.removeLabel,
    required this.supported,
    required this.onRepair,
    required this.onRemove,
  });

  final String name;
  final String system;
  final String legacyLabel;
  final String repairLabel;
  final String removeLabel;
  final bool supported;
  final VoidCallback onRepair;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Codicons.deviceMobile, size: 17, color: AppColors.caution),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: SettingsText.label.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    [
                      if (system.isNotEmpty && system != name) system,
                      legacyLabel,
                    ].join(' · '),
                    style: SettingsText.description,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SettingsButtons(
          children: [
            IdeButton(
              label: repairLabel,
              icon: Codicons.deviceMobile,
              onPressed: supported ? onRepair : null,
            ),
            IdeButton(
              label: removeLabel,
              icon: Codicons.trash,
              secondary: true,
              onPressed: onRemove,
            ),
          ],
        ),
      ],
    ),
  );
}

/// The phone app's downloads, as codes to scan: the site's own links
/// ([phoneDownloadTargets]), the same as its download page's, which lead to
/// the release current when scanned. Clicked, opened in the browser.
class _PhoneDownloads extends StatelessWidget {
  const _PhoneDownloads();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 24,
        runSpacing: 20,
        children: [
          _PhoneDownload(
            os: 'android',
            name: 'Android',
            detail: l10n.mobileGetAndroidDetail,
          ),
          _PhoneDownload(
            os: 'ios',
            name: l10n.mobileGetIos,
            detail: l10n.mobileGetIosDetail,
          ),
        ],
      ),
    );
  }
}

class _PhoneDownload extends StatelessWidget {
  const _PhoneDownload({
    required this.os,
    required this.name,
    required this.detail,
  });

  final String os;
  final String name;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final url = phoneDownloadUrl(os);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IdeHover(
          message: context.l10n.mobileGetOpen(url),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => unawaited(openExternal(url)),
              child: QrView(data: url, size: 148),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(name, style: SettingsText.label),
        SizedBox(
          width: 148,
          child: Text(
            detail,
            textAlign: TextAlign.center,
            style: SettingsText.description,
          ),
        ),
      ],
    );
  }
}
