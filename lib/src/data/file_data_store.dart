// Conditional re-export: the import point for FileDataStore. Resolves to the native
// (dart:io) implementation on phones and desktops and to a throwing stub on web.

export 'file_data_store_stub.dart'
    if (dart.library.io) 'file_data_store_native.dart';
