import 'package:flutter/material.dart';

import '../features/dashboard/dashboard_screen.dart';
import '../features/doctor/doctor_screen.dart';
import '../features/profiles/profiles_screen.dart';
import '../features/rules/rules_screen.dart';
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

class _HomeShell extends StatefulWidget {
  const _HomeShell();

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _selected = 0;

  static const _destinations = [
    NavigationRailDestination(
      icon: Icon(Icons.dashboard_outlined),
      selectedIcon: Icon(Icons.dashboard),
      label: Text('Dashboard'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.people_outline),
      selectedIcon: Icon(Icons.people),
      label: Text('Profiles'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.rule_folder_outlined),
      selectedIcon: Icon(Icons.rule_folder),
      label: Text('Rules'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.health_and_safety_outlined),
      selectedIcon: Icon(Icons.health_and_safety),
      label: Text('Doctor'),
    ),
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
          NavigationRail(
            selectedIndex: _selected,
            onDestinationSelected: (i) => setState(() => _selected = i),
            labelType: NavigationRailLabelType.all,
            destinations: _destinations,
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _screens[_selected]),
        ],
      ),
    );
  }
}
