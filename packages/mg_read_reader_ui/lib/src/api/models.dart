/// 阅读器公共模型唯一库入口。
///
/// 职责：按书籍、语义位置和偏好组织不可变业务模型，并保持既有公开 API。
/// 注意：宿主继续只通过 `package:novel_reader_ui/novel_reader_ui.dart` 导入。
library;

import 'package:flutter/foundation.dart';

part 'models_book.dart';
part 'models_comments.dart';
part 'models_location.dart';
part 'models_preferences.dart';
