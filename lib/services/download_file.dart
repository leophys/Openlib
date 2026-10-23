// Dart imports:
import 'dart:io';

// Package imports:
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

// Project imports:
import 'package:openlib/services/database.dart' show MyLibraryDb;
import 'package:openlib/services/proxy.dart';

MyLibraryDb dataBase = MyLibraryDb.instance;

Future<String> _getFilePath(String fileName) async {
  String bookStorageDirectory =
      await dataBase.getPreference('bookStorageDirectory');
  return '$bookStorageDirectory/$fileName';
}

/// Hosts that serve the book pages themselves (not download mirrors). Mirrors
/// pointing at these hosts are dropped because the download would just fetch
/// the HTML page instead of the book file.
Future<List<String>> _excludedMirrorPrefixes() async {
  final prefixes = <String>[
    'https://annas-archive.se',
    'https://1lib.sk',
  ];
  try {
    final baseUrl = (await dataBase.getPreference('archiveBaseUrl'))
        ?.toString()
        .trim();
    if (baseUrl != null &&
        baseUrl.isNotEmpty &&
        !prefixes.contains(baseUrl)) {
      prefixes.add(baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl);
    }
  } catch (_) {
    // Preference not initialised yet; only the built-in hosts are excluded.
  }
  return prefixes;
}

Future<List<String>> _reorderMirrors(List<String> mirrors) async {
  List<String> ipfsMirrors = [];
  List<String> httpsMirrors = [];

  final excludedPrefixes = await _excludedMirrorPrefixes();

  for (var element in mirrors) {
    if (element.contains('ipfs') == true) {
      ipfsMirrors.add(element);
    } else {
      final bool isExcluded = excludedPrefixes
          .any((prefix) => element.startsWith(prefix) == true);
      if (!isExcluded) {
        httpsMirrors.add(element);
      }
    }
  }
  return [...ipfsMirrors, ...httpsMirrors];
}

Future<String?> _getAliveMirror(List<String> mirrors, AppProxy proxy) async {
  Dio dio = Dio();
  applyProxy(dio, proxy);
  const timeOut = 15;
  if (mirrors.length == 1) {
    await Future.delayed(const Duration(seconds: 2));
    return mirrors[0];
  }
  for (var url in mirrors) {
    try {
      final response = await dio.head(url,
          options: Options(receiveTimeout: const Duration(seconds: timeOut)));
      if (response.statusCode == 200) {
        dio.close();
        return url;
      }
    } catch (_) {}
  }
  return null;
}

Future<void> downloadFile(
    {required List<String> mirrors,
    required String md5,
    required String format,
    required Function onStart,
    required Function onProgress,
    required Function cancelDownlaod,
    required Function mirrorStatus,
    required Function onDownlaodFailed}) async {
  if (mirrors.isEmpty) {
    onDownlaodFailed('No mirrors available!');
  } else {
    Dio dio = Dio();
    final AppProxy proxy = await loadProxyFromPreferences();
    applyProxy(dio, proxy);

    String path = await _getFilePath('$md5.$format');
    List<String> orderedMirrors = await _reorderMirrors(mirrors);

    String? workingMirror = await _getAliveMirror(orderedMirrors, proxy);

    // print(workingMirror);
    // print(path);
    // print(orderedMirrors);
    // print(orderedMirrors[0]);

    if (workingMirror != null) {
      onStart();
      try {
        CancelToken cancelToken = CancelToken();
        dio.download(
          workingMirror,
          path,
          options: Options(headers: {
            'Connection': 'Keep-Alive',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/75.0.3770.100 Safari/537.36'
          }),
          onReceiveProgress: (rcv, total) {
            if (!(rcv.isNaN || rcv.isInfinite) &&
                !(total.isNaN || total.isInfinite)) {
              onProgress(rcv, total);
            }
          },
          deleteOnError: true,
          cancelToken: cancelToken,
        ).catchError((err) {
          if (err.type != DioExceptionType.cancel) {
            onDownlaodFailed('downloaded Failed! try again...');
          }
          throw err;
        });

        mirrorStatus(true);

        cancelDownlaod(cancelToken);
      } catch (_) {
        onDownlaodFailed('downloaded Failed! try again...');
      }
    } else {
      onDownlaodFailed('No working mirrors available to download book!');
    }
  }
}

Future<bool> verifyFileCheckSum(
    {required String md5Hash, required String format}) async {
  try {
    final bookStorageDirectory =
        await dataBase.getPreference('bookStorageDirectory');
    final filePath = '$bookStorageDirectory/$md5Hash.$format';
    final file = File(filePath);
    final stream = file.openRead();
    final hash = await md5.bind(stream).first;
    if (md5Hash == hash.toString()) {
      return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}
