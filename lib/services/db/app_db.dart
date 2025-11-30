import 'package:comunifi/services/db/db.dart';
import 'package:sqflite_common/sqflite.dart';

/// App database service
class AppDBService extends DBService {
  @override
  Future<Database> openDB(String path) async {
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        // Tables will be created individually
      },
    );
  }
}

