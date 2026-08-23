import 'package:hive/hive.dart';

Box<dynamic> get preferencesBox => Hive.box<dynamic>('preferences');
Box<dynamic> get modelsBox => Hive.box<dynamic>('models');
Box<dynamic> get conversationsBox => Hive.box<dynamic>('conversations');
Box<dynamic> get memoryRecoveryBox => Hive.box<dynamic>('memory_recovery');
Box<dynamic> get memoryProposalBox => Hive.box<dynamic>('memory_proposals');
Box<dynamic> get artifactsBox => Hive.box<dynamic>('artifacts');
