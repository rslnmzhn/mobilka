import 'package:hive/hive.dart';

Box<dynamic> get preferencesBox => Hive.box<dynamic>('preferences');
Box<dynamic> get modelsBox => Hive.box<dynamic>('models');
Box<dynamic> get conversationsBox => Hive.box<dynamic>('conversations');
