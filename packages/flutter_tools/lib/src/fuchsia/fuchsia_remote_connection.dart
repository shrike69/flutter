// Copyright 2018 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:process/process.dart';

import '../base/logger.dart';
import '../vmservice.dart';
//import 'common/network.dart';
//import 'dart_vm.dart';
import 'ssh_command_runner.dart';

final String _ipv4Loopback = InternetAddress.LOOPBACK_IP_V4.address;

final String _ipv6Loopback = InternetAddress.LOOPBACK_IP_V6.address;

final ProcessManager _processManager = const LocalProcessManager();

final StdoutLogger _log = new StdoutLogger();

/// A function for forwarding ports on the local machine to a remote device.
///
/// Takes a remote `address`, the target device's port, and an optional
/// `interface` and `configFile`. The config file is used primarily for the
/// default SSH port forwarding configuration.
typedef Future<PortForwarder> PortForwardingFunction(
    String address, int remotePort,
    [String interface, String configFile]);

/// The function for forwarding the local machine's ports to a remote Fuchsia
/// device.
///
/// Can be overwritten in the event that a different method is required.
/// Defaults to using SSH port forwarding.
PortForwardingFunction fuchsiaPortForwardingFunction = _SshPortForwarder.start;

/// Sets `fuchsiaPortForwardingFunction` back to the default SSH port forwarding
/// implementation.
void restoreFuchsiaPortForwardingFunction() {
  fuchsiaPortForwardingFunction = _SshPortForwarder.start;
}

/// Manages a remote connection to a Fuchsia Device.
///
/// Provides affordances to observe and connect to Flutter views, isolates, and
/// perform actions on the Fuchsia device's various VM services.
///
/// Note that this class can be connected to several instances of the Fuchsia
/// device's Dart VM at any given time.
class FuchsiaRemoteConnection {
  final List<int> remoteServicePorts = <int>[];
  final List<PortForwarder> forwardedVMServicePorts = <PortForwarder>[];
  final SshCommandRunner _sshCommandRunner;
  final bool _useIpV6Loopback;

  /// VM service cache to avoid repeating handshakes across function
  /// calls. Keys a forwarded port to a DartVm connection instance.
  final Map<int, VMService> _dartVMCache = <int, VMService>{};

  FuchsiaRemoteConnection._(this._useIpV6Loopback, this._sshCommandRunner);

  /// Same as `FuchsiaRemoteConnection.connect` albeit with a provided
  /// `SshCommandRunner` instance.
  @visibleForTesting
  static Future<FuchsiaRemoteConnection> connectWithSshCommandRunner(
      SshCommandRunner commandRunner) async {
    final FuchsiaRemoteConnection connection = new FuchsiaRemoteConnection._(
        isIpV6Address(commandRunner.address), commandRunner);
    await connection._forwardLocalPortsToDeviceServicePorts();
    return connection;
  }

  /// Opens a connection to a Fuchsia device.
  ///
  /// Accepts an `address` to a Fuchsia device, and requires a root
  /// directory in which the Fuchsia Device was built (along with the
  /// `buildType`) in order to open the associated ssh_config for port
  /// forwarding. Will throw an `ArgumentError` if the address is malformed.
  ///
  /// Once this function is called, the instance of `FuchsiaRemoteConnection`
  /// returned will keep all associated DartVM connections opened over the
  /// lifetime of the object.
  ///
  /// At its current state Dart VM connections will not be added or removed over
  /// the lifetime of this object.
  ///
  /// Throws an `ArgumentError` if the supplied `address` is not valid IPv6 or
  /// IPv4.
  ///
  /// Note that if `address` is ipv6 link local (usually starts with fe80::),
  /// then `interface` will probably need to be set in order to connect
  /// successfully (that being the outgoing interface of your machine, not the
  /// interface on the target machine).
  static Future<FuchsiaRemoteConnection> connect(String address,
      [String interface = '', String sshConfigPath]) async {
    return await FuchsiaRemoteConnection.connectWithSshCommandRunner(
        new SshCommandRunner(
            address: address,
            interface: interface,
            sshConfigPath: sshConfigPath));
  }

  /// Closes all open connections.
  ///
  /// Any objects that this class returns (including any child objects from
  /// those objects) will subsequently have its connection closed as well, so
  /// behavior for them will be undefined.
  Future<Null> stop() async {
    for (PortForwarder fp in forwardedVMServicePorts) {
      // Closes VM service first to ensure that the connection is closed cleanly
      // on the target before shutting down the forwarding itself.
      final VMService vmService = _dartVMCache[fp.remotePort];
      _dartVMCache[fp.remotePort] = null;
      await vmService?.done;
      await fp.stop();
    }
    _dartVMCache.clear();
    forwardedVMServicePorts.clear();
  }

  Future<List<FlutterView>> getFlutterViewsAtPort(PortForwarder portForwarder) async {
    final List<FlutterView> views = <FlutterView>[];

    if (portForwarder != null) {
      final VMService vmService = await _getDartVM(portForwarder);
      await vmService.vm.refreshViews();
      views.addAll(vmService.vm.views);
    }

    return views;
  }


  /// Returns a list of `FlutterView` objects.
  ///
  /// This is run across all connected DartVM connections that this class is
  /// managing.
  Future<List<FlutterView>> getFlutterViews() async {
    final List<FlutterView> views = <FlutterView>[];
    if (forwardedVMServicePorts.isEmpty) {
      return views;
    }
    for (PortForwarder fp in forwardedVMServicePorts) {
      final VMService vmService = await _getDartVM(fp);
      await vmService.vm.refreshViews();
      views.addAll(vmService.vm.views);
    }
    return views;
  }

  Future<VMService> getVMAtPort(PortForwarder portForwarder) async {
    return await _getDartVM(portForwarder);
  }

  Future<VMService> _getDartVM(PortForwarder portForwarder) async {
    final int localPort = portForwarder.port;
    if (!_dartVMCache.containsKey(localPort)) {
      // While the IPv4 loopback can be used for the initial port forwarding
      // (see `PortForwarder.start`), the address is actually bound to the IPv6
      // loopback device, so connecting to the IPv4 loopback would fail when the
      // target address is IPv6 link-local.
      final String addr = _useIpV6Loopback
          ? 'http://\[$_ipv6Loopback\]:$localPort'
          : 'http://$_ipv4Loopback:$localPort';
      final Uri uri = Uri.parse(addr);
      final VMService dartVM = await VMService.connect(uri);
      _dartVMCache[localPort] = dartVM;
    }
    return _dartVMCache[localPort];
  }

  /// Forwards a series of local device ports to the `deviceIpv4Address` using
  /// SSH port forwarding.
  ///
  /// When this function is run, all existing forwarded ports and connections
  /// are reset, similar to running `stop`.
  Future<Null> _forwardLocalPortsToDeviceServicePorts() async {
    await stop();
    remoteServicePorts.addAll(await getDeviceServicePorts());
    forwardedVMServicePorts
        .addAll(await Future.wait(remoteServicePorts.map((int deviceServicePort) {
      return fuchsiaPortForwardingFunction(
          _sshCommandRunner.address,
          deviceServicePort,
          _sshCommandRunner.interface,
          _sshCommandRunner.sshConfigPath);
    })));
  }

  /// Gets the open Dart VM service ports on a remote Fuchsia device.
  ///
  /// The method attempts to get service ports through an SSH connection. Upon
  /// successfully getting the VM service ports, returns them as a list of
  /// integers. If an empty list is returned, then no Dart VM instances could be
  /// found. An exception is thrown in the event of an actual error when
  /// attempting to acquire the ports.
  Future<List<int>> getDeviceServicePorts() async {
    final List<String> lsOutput =
        await _sshCommandRunner.run('ls /tmp/dart.services');
    final List<int> ports = <int>[];

    // The output of lsOutput is a list of available ports as the Fuchsia dart
    // service advertises. An example lsOutput would look like:
    //
    // [ '31782\n', '1234\n', '11967' ]
    for (String s in lsOutput) {
      final String trimmed = s.trim();
      final int lastSpace = trimmed.lastIndexOf(' ');
      final String lastWord = trimmed.substring(lastSpace + 1);
      if ((lastWord != '.') && (lastWord != '..')) {
        final int value = int.parse(lastWord, onError: (_) => null);
        if (value != null) {
          ports.add(value);
        }
      }
    }
    return ports;
  }

  Future<bool> installAppAtPath(String path) async {
    final List<String> scpOutput =
        await _sshCommandRunner.scp('/Users/shrike/topaz/topaz/examples/ui/hello_material', '/tmp');

    print('results: $scpOutput');
    return true;
  }
}

/// Defines a `PortForwarder` interface.
///
/// When a PortForwarder is initialized, it is intended to save a port through
/// which a connection is persisted along the lifetime of this object.
///
/// When a PortForwarder is shut down it must use its `stop` function to clean
/// up.
abstract class PortForwarder {
  /// Determines the port which is being forwarded from the local machine.
  int get port;

  /// The destination port on the other end of the port forwarding tunnel.
  int get remotePort;

  /// Shuts down and cleans up port forwarding.
  Future<Null> stop();
}

/// Instances of this class represent a running ssh tunnel.
///
/// The SSH tunnel is from the host to a VM service running on a Fuchsia device.
/// `process` is the ssh process running the tunnel and `port` is the local
/// port.
class _SshPortForwarder extends PortForwarder {
  final String _remoteAddress;
  final int _remotePort;
  final int _localPort;
  final Process _process;
  final String _sshConfigPath;
  final String _interface;
  final bool _ipV6;

  _SshPortForwarder._(
    this._remoteAddress,
    this._remotePort,
    this._localPort,
    this._process,
    this._interface,
    this._sshConfigPath,
    this._ipV6,
  );

  @override
  int get port => _localPort;

  @override
  int get remotePort => _remotePort;

  /// Starts SSH forwarding through a subprocess, and returns an instance of
  /// `_SshPortForwarder`.
  static Future<_SshPortForwarder> start(String address, int remotePort,
      [String interface, String sshConfigPath]) async {
    final int localPort = await _potentiallyAvailablePort();
    final bool isIpV6 = isIpV6Address(address);
    if (localPort == 0) {
      _log.printStatus('FuchsiaRemoteConnection - warning - _SshPortForwarder failed to find a local port for '
          '$address:$remotePort');
      return null;
    }
    // TODO: The square-bracket enclosure for using the IPv6 loopback didn't
    // appear to work, but when assigning to the IPv4 loopback device, netstat
    // shows that the local port is actually being used on the IPv6 loopback
    // (::1). While this can be used for forwarding to the destination IPv6
    // interface, it cannot be used to connect to a websocket.
    final String formattedForwardingUrl =
        '$localPort:$_ipv4Loopback:$remotePort';
    final List<String> command = <String>['ssh'];
    if (isIpV6) {
      command.add('-6');
    }
    if (sshConfigPath != null) {
      command.addAll(<String>['-F', sshConfigPath]);
    }
    final String targetAddress =
        isIpV6 && interface.isNotEmpty ? '$address%$interface' : address;
    command.addAll(<String>[
      '-nNT',
      '-L',
      formattedForwardingUrl,
      targetAddress,
    ]);
//    _log.printStatus("FuchsiaRemoteConnection: _SshPortForwarder running '${command.join(' ')}'");
    final Process process = await _processManager.start(command);
    process.exitCode.then((int c) {
      _log.printStatus("FuchsiaRemoteConnection: '${command.join(' ')}' exited with exit code $c");
    });
//    _log.printStatus('FuchsiaRemoteConnection:  Set up forwarding from $localPort to $address port $remotePort');
    return new _SshPortForwarder._(address, remotePort, localPort, process,
        interface, sshConfigPath, isIpV6);
  }

  /// Kills the SSH forwarding command, then to ensure no ports are forwarded,
  /// runs the ssh 'cancel' command to shut down port forwarding completely.
  @override
  Future<Null> stop() async {
    // Kill the original ssh process if it is still around.
    _process?.kill();
    // Cancel the forwarding request. See `start` for commentary about why this
    // uses the IPv4 loopback.
    final String formattedForwardingUrl =
        '$_localPort:$_ipv4Loopback:$_remotePort';
    final List<String> command = <String>['ssh'];
    final String targetAddress = _ipV6 && _interface.isNotEmpty
        ? '$_remoteAddress%$_interface'
        : _remoteAddress;
    if (_sshConfigPath != null) {
      command.addAll(<String>['-F', _sshConfigPath]);
    }
    command.addAll(<String>[
      '-O',
      'cancel',
      '-L',
      formattedForwardingUrl,
      targetAddress,
    ]);
    final ProcessResult result = await _processManager.run(command);
    _log.printStatus(command.join(' '));
    if (result.exitCode != 0) {
      _log.printStatus(
          'FuchsiaRemoteConnection - warning - Command failed:\nstdout: ${result.stdout}\nstderr: ${result.stderr}');
    }
  }

  static Future<int> _potentiallyAvailablePort() async {
    int port = 0;
    ServerSocket s;
    try {
      s = await ServerSocket.bind(_ipv4Loopback, 0);
      port = s.port;
    } catch (e) {
      // Failures are signaled by a return value of 0 from this function.
      _log.printStatus('FuchsiaRemoteConnection - wanring - _potentiallyAvailablePort failed: $e');
    }
    await s?.close();
    return port;
  }
}
