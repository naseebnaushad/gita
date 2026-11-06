import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/services/cli_installer.dart';

import '../features/dashboard/dashboard_screen.dart';
import '../features/doctor/doctor_screen.dart';
import '../features/profiles/profiles_screen.dart';
import '../features/rules/rules_screen.dart';
import '../features/setup/setup_wizard.dart';
import 'theme.dart';

class GitaApp extends StatelessWidget {
  const GitaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gita',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const _HomeShell(),
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _HomeShell extends ConsumerStatefulWidget {
  const _HomeShell();

  @override
  ConsumerState<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<_HomeShell> {
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    // Install or update the gita command git uses for HTTPS sign-in. Doctor
    // reports it if this didn't work, so failures are only logged here.
    ref.read(cliInstallProvider.future).then((result) {
      if (result.status == CliInstallStatus.failed) debugPrint('$result');
    }, onError: (Object e) => debugPrint('Installing the gita command failed: $e'))
        .whenComplete(_moveOldTokens)
        .whenComplete(_updateGuards)
        .whenComplete(_offerSetup);
  }

  /// On the first start, with no profiles yet, offers to scan this computer
  /// and set everything up.
  Future<void> _offerSetup() async {
    try {
      if (!await ref.read(setupActionsProvider).shouldOfferSetup()) return;
    } catch (e) {
      debugPrint('Checking for first start failed: $e');
      return;
    }
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showSetupWizard(context);
    });
  }

  /// Moves sign-ins saved by older Gita versions into the OS credential
  /// store, then rewrites the git config so pushes use them.
  Future<void> _moveOldTokens() async {
    try {
      final profiles = await ref.read(profileRepositoryProvider).getAll();
      final moved = await ref
          .read(secureTokenServiceProvider)
          .migrateLegacy(profiles.map((p) => p.id));
      if (moved > 0 && mounted) {
        await ref.read(profilesProvider.notifier).resyncGitConfig();
        ref.invalidate(doctorIssuesProvider);
      }
    } catch (e) {
      debugPrint('Moving old sign-ins failed: $e');
    }
  }

  /// Updates safety checks an older Gita put into tracked projects.
  Future<void> _updateGuards() async {
    try {
      await ref.read(trackedReposProvider.notifier).updateOutdatedGuards();
    } catch (e) {
      debugPrint('Updating safety checks failed: $e');
    }
  }

  static const _items = [
    _NavItem(Icons.dashboard_outlined, Icons.dashboard_rounded, 'Dashboard'),
    _NavItem(Icons.people_outline, Icons.people_rounded, 'Profiles'),
    _NavItem(Icons.rule_folder_outlined, Icons.rule_folder_rounded, 'Rules'),
    _NavItem(Icons.health_and_safety_outlined, Icons.health_and_safety_rounded, 'Doctor'),
  ];

  static const _screens = [
    DashboardScreen(),
    ProfilesScreen(),
    RulesScreen(),
    DoctorScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            selected: _selected,
            items: _items,
            onSelect: (i) => setState(() => _selected = i),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: child,
              ),
              child: KeyedSubtree(
                key: ValueKey(_selected),
                child: _screens[_selected],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selected,
    required this.items,
    required this.onSelect,
  });

  final int selected;
  final List<_NavItem> items;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 232,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Brand(),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  for (var i = 0; i < items.length; i++)
                    _NavTile(
                      item: items[i],
                      isSelected: selected == i,
                      onTap: () => onSelect(i),
                    ),
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _StatusFooter(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: GitaColors.blue.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset('assets/branding/icon.png', fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Gita',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 19),
                ),
                Text(
                  'git account manager',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  final _NavItem item;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: isSelected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  isSelected ? item.selectedIcon : item.icon,
                  size: 20,
                  color: isSelected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text(
                  item.label,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: isSelected ? scheme.onPrimaryContainer : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusFooter extends StatelessWidget {
  const _StatusFooter();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: GitaColors.green,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Local & private',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
