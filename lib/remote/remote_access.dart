// The tunnel needs dart:ffi. The web has its own way to the PC.
export 'remote_access_stub.dart'
    if (dart.library.ffi) 'remote_access_native.dart'
    if (dart.library.js_interop) 'remote_access_web.dart';
