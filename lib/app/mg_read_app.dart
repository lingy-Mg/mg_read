import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';

/// The root widget for the MgRead host application.
class MgReadApp extends StatelessWidget {
  /// Creates the application shell.
  const MgReadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppStrings.applicationName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const LibraryPage(),
    );
  }
}
