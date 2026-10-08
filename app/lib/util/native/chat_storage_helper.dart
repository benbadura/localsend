import 'dart:io';

import 'package:localsend_app/util/shared_preferences/shared_preferences_portable.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> getChatDatabasePath({required bool portable}) async {
  final directory = portable ? Directory(p.dirname(SharedPreferencesPortable().getPath())) : await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return p.join(directory.path, 'messages.sqlite');
}
