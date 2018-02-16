// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import '../application_package.dart';
import '../base/file_system.dart';
import '../base/platform.dart';
import '../build_info.dart';
import '../commands/fuchsia_reload.dart';
import '../device.dart';
import '../vmservice.dart';
import 'fuchsia_remote_connection.dart';

class FuchsiaDevices extends PollingDeviceDiscovery {
  FuchsiaDevices() : super('Fuchsia devices');

  @override
  bool get supportsPlatform => platform.isMacOS; // .isFuchsia;

  @override
  bool get canListAnything => true; // Fix me

  @override
  Future<List<Device>> pollingGetDevices() => FuchsiaDevice.getAttachedDevices();
}

/// Read the log for a particular device.
class _FuchsiaLogReader extends DeviceLogReader {
  FuchsiaDevice _device;

  _FuchsiaLogReader(this._device);

  @override String get name => _device.name;

  Stream<String> _logLines;
  @override
  Stream<String> get logLines {
    _logLines ??= const Stream<String>.empty();
    return _logLines;
  }

  @override
  String toString() => name;
}

class FuchsiaDevice extends Device {
  FuchsiaDevice(String id, { this.name }) : super(id);

  @override
  bool get supportsHotMode => true;

  @override
  final String name;

  @override
  bool get supportsStartPaused => false;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  Future<bool> isAppInstalled(ApplicationPackage app) async => false;

  @override
  Future<bool> isLatestBuildInstalled(ApplicationPackage app) async => false;

  @override
  Future<bool> installApp(ApplicationPackage app) => new Future<bool>.value(false);

  @override
  Future<bool> uninstallApp(ApplicationPackage app) async => false;

  @override
  bool isSupported() => true;

  @override
  Future<TargetPlatform> get targetPlatform async => TargetPlatform.fuchsia;

  @override
  Future<String> get sdkNameAndVersion async => 'Fuchsia';

  _FuchsiaLogReader _logReader;
  @override
  DeviceLogReader getLogReader({ApplicationPackage app}) {
    _logReader ??= new _FuchsiaLogReader(this);
    return _logReader;
  }

  FuchsiaRemoteConnection _connection;
  int _port;
  // TODO
  //PortForwarder _portForwarder;
  @override
  DevicePortForwarder get portForwarder => null;

  @override
  void clearLogs() {
  }

  // TODO
  @override
  Future<LaunchResult> startApp(
                                ApplicationPackage app, {
                                  String mainPath,
                                  String route,
                                  DebuggingOptions debuggingOptions,
                                  Map<String, dynamic> platformArgs,
                                  bool prebuiltApplication: false,
                                  bool applicationNeedsRebuild: false,
                                  bool usesTerminalUi: false,
                                  bool ipv6: false,
                                })
  {
    print('in start app');
    final String fuchsiaRoot = platform.environment['FUCHSIA_ROOT'];
    if (fuchsiaRoot == null)
      return new Future<Null>.error('Please set the location of the Fuchsia root by setting the FUCHSIA_ROOT environment variable.');
    if (!_directoryExists(fuchsiaRoot))
      return new Future<Null>.error('Specified --fuchsia-root "$fuchsiaRoot" does not exist.');

    return new Future<LaunchResult>.value(new LaunchResult.succeeded());

    print('fuchsiaRoot = $fuchsiaRoot');

    print('installing');
    _connection.installAppAtPath(fuchsiaRoot);
    print('done');

    return new Future<LaunchResult>.value(new LaunchResult.succeeded());
  }

  // TODO
  @override
  Future<bool> stopApp(ApplicationPackage app) async {
    // Currently we don't have a way to stop an app running on Fuchsia.
    return false;
  }

  @override
  bool get supportsScreenshot => false;

  // TODO
  @override
  Future<List<DiscoveredApp>> discoverApps() =>
    new Future<List<DiscoveredApp>>.value(<DiscoveredApp>[]);

  static Future<List<FuchsiaDevice>> getAttachedDevices() async {
    final List<FuchsiaDevice> devices = <FuchsiaDevice>[];

    final FuchsiaReloadCommand reloadCommand = new FuchsiaReloadCommand();
    await reloadCommand.runCommand();

    return devices;

    final String address = '192.168.42.41';
    final String interface = '';
    // Example ssh config path for the fuchsia device after having made a local
    // build.
    final String sshConfigPath = '/Users/shrike/topaz/out/debug-x86-64/ssh-keys/ssh_config';
    final FuchsiaRemoteConnection connection =
        await FuchsiaRemoteConnection.connect(address, interface, sshConfigPath);
    print('On $address, the following Dart VM ports are active:');
    for (int port in connection.remoteServicePorts) {
      final FuchsiaDevice nextDevice = new FuchsiaDevice('$port', name: 'FuchsiaVM on port $port');
      nextDevice._connection = connection;
      nextDevice._port = port;
      devices.add(nextDevice);
      print('\t$port device name is ' + nextDevice.name);
    }

    print('');

    print('The following Isolates are running:');

    for (PortForwarder portForwarder in connection.forwardedVMServicePorts) {
      final int port = portForwarder.port;
      final int remotePort = portForwarder.remotePort;
      print('FuchsiaVM on local port $port, remote port $remotePort');

      for (FlutterView view in await connection.getFlutterViewsAtPort(portForwarder)) {
        final Isolate isolate = view.uiIsolate;

        print('\t${isolate.name ?? isolate.id}');
      }
    }

    return devices;

    /*final List<FuchsiaDevice> devices = <IOSDevice>[];
    for (String id in (await iMobileDevice.getAvailableDeviceIDs()).split('\n')) {
     id = id.trim();
     if (id.isEmpty)
     continue;

     final String deviceName = await iMobileDevice.getInfoForDevice(id, 'DeviceName');
     final String sdkVersion = await iMobileDevice.getInfoForDevice(id, 'ProductVersion');
     devices.add(new IOSDevice(id, name: deviceName, sdkVersion: sdkVersion));
    }
    return devices;*/
  }

  bool _directoryExists(String path) {
    final Directory d = fs.directory(path);
    return d.existsSync();
  }


}
