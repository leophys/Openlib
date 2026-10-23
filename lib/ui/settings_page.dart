// Dart imports:
import 'dart:io';

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:openlib/services/files.dart';
import 'package:permission_handler/permission_handler.dart';

// Project imports:
import 'package:openlib/services/annas_archieve.dart' show AnnasArchieve;
import 'package:openlib/services/database.dart';
import 'package:openlib/services/proxy.dart';
import 'package:openlib/ui/about_page.dart';
import 'package:openlib/ui/components/page_title_widget.dart';

import 'package:openlib/state/state.dart'
    show
        themeModeProvider,
        openPdfWithExternalAppProvider,
        openEpubWithExternalAppProvider,
        archiveBaseUrlProvider,
        useProxyProvider,
        proxyHostProvider,
        proxyPortProvider,
        appProxyProvider,
        searchProvider,
        bookInfoProvider;

Future<void> requestStoragePermission() async {
  bool permissionGranted = false;
  // Check whether the device is running Android 11 or higher
  DeviceInfoPlugin plugin = DeviceInfoPlugin();
  AndroidDeviceInfo android = await plugin.androidInfo;
  // Android < 11
  if (android.version.sdkInt < 33) {
    if (await Permission.storage.request().isGranted) {
      permissionGranted = true;
    } else if (await Permission.storage.request().isPermanentlyDenied) {
      await openAppSettings();
    }
  }
  // Android > 11
  else {
    if (await Permission.manageExternalStorage.request().isGranted) {
      permissionGranted = true;
    } else if (await Permission.manageExternalStorage
        .request()
        .isPermanentlyDenied) {
      await openAppSettings();
    } else if (await Permission.manageExternalStorage.request().isDenied) {
      permissionGranted = false;
    }
  }
  print("Storage permission status: $permissionGranted");
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final TextEditingController _archiveUrlController = TextEditingController();
  final TextEditingController _proxyHostController = TextEditingController();
  final TextEditingController _proxyPortController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _archiveUrlController.text = ref.read(archiveBaseUrlProvider);
    _proxyHostController.text = ref.read(proxyHostProvider);
    _proxyPortController.text = ref.read(proxyPortProvider).toString();
  }

  @override
  void dispose() {
    _archiveUrlController.dispose();
    _proxyHostController.dispose();
    _proxyPortController.dispose();
    super.dispose();
  }

  Future<void> _saveArchiveBaseUrl(String value) async {
    MyLibraryDb dataBase = MyLibraryDb.instance;
    String url = value.trim();
    if (url.isEmpty) {
      url = AnnasArchieve.defaultBaseUrl;
    } else if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    ref.read(archiveBaseUrlProvider.notifier).state = url;
    await dataBase.savePreference('archiveBaseUrl', url);
    // Drop cached results so the new mirror is used immediately.
    ref.invalidate(searchProvider);
    ref.invalidate(bookInfoProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Archive address updated')),
      );
    }
  }

  Future<void> _saveProxySettings() async {
    MyLibraryDb dataBase = MyLibraryDb.instance;
    final bool useProxy = ref.read(useProxyProvider);
    final String host = ref.read(proxyHostProvider);
    final int port = ref.read(proxyPortProvider);
    await dataBase.savePreference('useProxy', useProxy);
    await dataBase.savePreference('proxyHost', host);
    await dataBase.savePreference('proxyPort', port);
    await applyWebViewProxy(ref.read(appProxyProvider));
  }

  @override
  Widget build(BuildContext context) {
    MyLibraryDb dataBase = MyLibraryDb.instance;
    final textStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.bold,
      color: Theme.of(context).colorScheme.tertiary,
    );
    return Padding(
      padding: const EdgeInsets.only(left: 5, right: 5, top: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TitleText("Settings"),
            _PaddedContainer(
              children: [
                Text("Dark Mode", style: textStyle),
                Switch(
                  // This bool value toggles the switch.
                  value: ref.watch(themeModeProvider) == ThemeMode.dark,
                  activeColor: Colors.red,
                  onChanged: (bool value) {
                    ref.read(themeModeProvider.notifier).state =
                        value == true ? ThemeMode.dark : ThemeMode.light;
                    dataBase.savePreference('darkMode', value);
                    if (Platform.isAndroid) {
                      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
                          systemNavigationBarColor:
                              value ? Colors.black : Colors.grey.shade200));
                    }
                  },
                )
              ],
            ),
            _PaddedContainer(
              children: [
                Text("Open PDF with External Reader", style: textStyle),
                Switch(
                  // This bool value toggles the switch.
                  value: ref.watch(openPdfWithExternalAppProvider),
                  activeColor: Colors.red,
                  onChanged: (bool value) {
                    ref.read(openPdfWithExternalAppProvider.notifier).state =
                        value;
                    dataBase.savePreference('openPdfwithExternalApp', value);
                  },
                )
              ],
            ),
            _PaddedContainer(
              children: [
                Text("Open Epub with External Reader", style: textStyle),
                Switch(
                  // This bool value toggles the switch.
                  value: ref.watch(
                    openEpubWithExternalAppProvider,
                  ),
                  activeColor: Colors.red,
                  onChanged: (bool value) {
                    ref.read(openEpubWithExternalAppProvider.notifier).state =
                        value;
                    dataBase.savePreference('openEpubwithExternalApp', value);
                  },
                )
              ],
            ),
            _PaddedContainer(
                onClick: () async {
                  final currentDirectory =
                      await dataBase.getPreference('bookStorageDirectory');
                  String? pickedDirectory =
                      await FilePicker.platform.getDirectoryPath();
                  if (pickedDirectory == null) {
                    return;
                  }
                  await requestStoragePermission();
                  // Attempt moving existing books to the new directory
                  moveFolderContents(currentDirectory, pickedDirectory);
                  dataBase.savePreference(
                      'bookStorageDirectory', pickedDirectory);
                },
                children: [
                  Text("Change storage path", style: textStyle),
                  Icon(Icons.folder),
                ]),
            _SettingsTextField(
              label: "Archive address",
              hint: AnnasArchieve.defaultBaseUrl,
              controller: _archiveUrlController,
              keyboardType: TextInputType.url,
              onSubmitted: _saveArchiveBaseUrl,
            ),
            _PaddedContainer(
              children: [
                Expanded(
                  child: Text(
                    "Use local SOCKS5 proxy (e.g. Orbot)",
                    style: textStyle,
                  ),
                ),
                Switch(
                  value: ref.watch(useProxyProvider),
                  activeColor: Colors.red,
                  onChanged: (bool value) {
                    ref.read(useProxyProvider.notifier).state = value;
                    _saveProxySettings();
                  },
                )
              ],
            ),
            if (ref.watch(useProxyProvider)) ...[
              _SettingsTextField(
                label: "Proxy host",
                hint: defaultProxyHost,
                controller: _proxyHostController,
                keyboardType: TextInputType.text,
                onSubmitted: (value) {
                  ref.read(proxyHostProvider.notifier).state = value.trim();
                  _saveProxySettings();
                },
              ),
              _SettingsTextField(
                label: "Proxy port",
                hint: defaultProxyPort.toString(),
                controller: _proxyPortController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (value) {
                  final int? port = int.tryParse(value.trim());
                  if (port != null && port > 0 && port <= 65535) {
                    ref.read(proxyPortProvider.notifier).state = port;
                  } else {
                    _proxyPortController.text =
                        ref.read(proxyPortProvider).toString();
                  }
                  _saveProxySettings();
                },
              ),
            ],
            _PaddedContainer(
              onClick: () {
                Navigator.push(context,
                    MaterialPageRoute(builder: (BuildContext context) {
                  return const AboutPage();
                }));
              },
              children: [
                Text("About", style: textStyle),
              ],
            )
          ],
        ),
      ),
    );
  }
}

class _PaddedContainer extends StatelessWidget {
  const _PaddedContainer({this.onClick, required this.children});

  final VoidCallback? onClick;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 5, right: 5, top: 10),
      child: InkWell(
        onTap: onClick,
        child: Container(
          height: 61,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            color: Theme.of(context).colorScheme.tertiaryContainer,
          ),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsTextField extends StatelessWidget {
  const _SettingsTextField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.keyboardType,
    required this.onSubmitted,
    this.inputFormatters,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final TextInputType keyboardType;
  final void Function(String value) onSubmitted;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 5, right: 5, top: 10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          color: Theme.of(context).colorScheme.tertiaryContainer,
        ),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ),
              TextField(
                controller: controller,
                keyboardType: keyboardType,
                inputFormatters: inputFormatters,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onTertiaryContainer,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: hint,
                  border: InputBorder.none,
                ),
                onSubmitted: onSubmitted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
