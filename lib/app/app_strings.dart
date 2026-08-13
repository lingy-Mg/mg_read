/// Centralized Simplified Chinese copy for the initial application shell.
abstract final class AppStrings {
  static const String applicationName = 'MgRead';
  static const String libraryTitle = '我的书架';
  static const String libraryIconLabel = '书架';
  static const String bootstrapTitle = '主应用骨架已就绪';
  static const String bootstrapDescription = '书架、书源、账户与本地数据将在主应用中逐步接入。';
  static const String readerIntegrationTitle = '阅读器接入边界';
  static const String readerIntegrationDescription =
      'novel_reader_ui 已作为同级本地依赖接入。实现书源和状态存储后，即可通过 ReaderHostPage 打开阅读器。';
  static const String nextStepsTitle = '下一步';
  static const String nextStepsDescription = '建立领域模型、书架数据源和持久化实现，再将真实书籍传入阅读器。';
}
