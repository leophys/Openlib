// Dart imports:
import 'dart:io';

// Flutter imports:
import 'package:flutter/foundation.dart';

// Package imports:
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as webview;
import 'package:socks5_proxy/socks_client.dart' as socks;

// Project imports:
import 'package:openlib/services/database.dart' show MyLibraryDb;

MyLibraryDb dataBase = MyLibraryDb.instance;

/// Default SOCKS5 proxy address used by Orbot on Android.
const String defaultProxyHost = '127.0.0.1';
const int defaultProxyPort = 9050;

/// Holds the user-configured local SOCKS5 proxy (e.g. Orbot).
class AppProxy {
  final String host;
  final int port;

  const AppProxy({required this.host, required this.port});

  bool get enabled => host.isNotEmpty && port > 0;

  /// A proxy configuration with the proxy switched off.
  static const AppProxy disabled = AppProxy(host: '', port: 0);
}

/// Reads the proxy settings from the preferences database.
///
/// Returns a disabled [AppProxy] when the proxy is switched off or the
/// stored host/port are missing or invalid.
Future<AppProxy> loadProxyFromPreferences() async {
  try {
    final enabled = await dataBase.getPreference('useProxy') == 1;
    if (!enabled) return AppProxy.disabled;
    final host =
        (await dataBase.getPreference('proxyHost'))?.toString().trim() ?? '';
    final port = int.tryParse(
            (await dataBase.getPreference('proxyPort'))?.toString() ?? '') ??
        0;
    if (host.isEmpty || port <= 0 || port > 65535) return AppProxy.disabled;
    return AppProxy(host: host, port: port);
  } catch (_) {
    // Preferences not initialised yet; fall back to a disabled proxy.
    return AppProxy.disabled;
  }
}

/// Resolves [host] (an IP literal or a hostname like "localhost") to an
/// [InternetAddress] for the SOCKS5 client.
Future<InternetAddress> _resolveProxyAddress(String host) async {
  final InternetAddress? ip = InternetAddress.tryParse(host);
  if (ip != null) return ip;
  return (await InternetAddress.lookup(host)).first;
}

/// Configures a [Dio] instance to route all of its traffic through the given
/// SOCKS5 proxy by replacing the underlying [HttpClient]'s connection factory.
///
/// The connection factory performs the SOCKS5 handshake itself (the target
/// hostname is sent to the proxy for remote DNS resolution, like with Orbot)
/// and then layers TLS on top for https URLs, so certificate validation is
/// preserved.
void applyProxy(Dio dio, AppProxy proxy) {
  if (!proxy.enabled || kIsWeb) return;
  (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
    final client = HttpClient();
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final settings = socks.ProxySettings(
        await _resolveProxyAddress(proxy.host),
        proxy.port,
      );
      // The target host is handed to the proxy as a domain name so the proxy
      // performs the DNS resolution (the unix-type address below is a
      // placeholder that carries the hostname).
      final socksSocket = socks.SocksTCPClient.connect(
        [settings],
        InternetAddress(uri.host, type: InternetAddressType.unix),
        uri.port,
      );
      if (uri.scheme == 'https') {
        final Future<SecureSocket> secureSocket =
            (await socksSocket).secure(uri.host);
        return ConnectionTask.fromSocket(
          secureSocket,
          () => secureSocket
              .then((socket) => socket.close().ignore(), onError: (_) {})
              .ignore(),
        );
      }
      return ConnectionTask.fromSocket(
        socksSocket,
        () => socksSocket
            .then((socket) => socket.close().ignore(), onError: (_) {})
            .ignore(),
      );
    };
    return client;
  };
}

/// Applies the proxy to the Android WebView (used by the captcha page) via
/// the process-wide proxy override. Does nothing on other platforms.
Future<void> applyWebViewProxy(AppProxy proxy) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    final supported = await webview.WebViewFeature.isFeatureSupported(
        webview.WebViewFeature.PROXY_OVERRIDE);
    if (!supported) return;
    final proxyController = webview.ProxyController.instance();
    if (proxy.enabled) {
      await proxyController.setProxyOverride(
        settings: webview.ProxySettings(
          proxyRules: [webview.ProxyRule(url: '${proxy.host}:${proxy.port}')],
          bypassRules: const ['localhost', '127.0.0.1', '<local>'],
        ),
      );
    } else {
      await proxyController.clearProxyOverride();
    }
  } catch (_) {
    // Proxy override unsupported or failed; the WebView will connect directly.
  }
}
