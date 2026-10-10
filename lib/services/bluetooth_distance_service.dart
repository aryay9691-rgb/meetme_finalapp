import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:math';

class BluetoothDistanceService {
  static const String SERVICE_UUID = "0000181C-0000-1000-8000-00805F9B34FB"; // Custom service
  static const String CHAR_UUID = "00002A3D-0000-1000-8000-00805F9B34FB"; // Custom characteristic
  
  static StreamSubscription? _scanSubscription;
  static BluetoothDevice? _connectedDevice;
  
  // RSSI to distance conversion (calibrated values)
  static const double REFERENCE_RSSI = -59.0; // Should be calibrated per device
  static const double PATH_LOSS_EXPONENT = 3.0; // Indoor with obstacles
  
  // Request Bluetooth permissions
  static Future<bool> requestPermissions() async {
    if (!kIsWeb && Platform.isAndroid) {
      final statuses = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.location, // Required for BLE scanning on Android
      ].request();
      
      return statuses.values.every((status) => status.isGranted);
    }
    return true;
  }

  // Check if Bluetooth is available and on
  static Future<bool> isBluetoothAvailable() async {
    try {
      if (await FlutterBluePlus.isAvailable == false) {
        return false;
      }
      
      final state = await FlutterBluePlus.adapterState.first;
      return state == BluetoothAdapterState.on;
    } catch (e) {
      return false;
    }
  }

  // Turn on Bluetooth (Android only)
  static Future<void> turnOnBluetooth() async {
    if (!kIsWeb && Platform.isAndroid) {
      await FlutterBluePlus.turnOn();
    }
  }

  // Start advertising (Device A - being tracked)
  static Future<void> startAdvertising(String deviceId) async {
    try {
      // Note: iOS doesn't support custom BLE advertising in background
      // You'll need to use Peripheral mode with CoreBluetooth
      
      print('📡 Starting BLE advertising for device: $deviceId');
      
      // For Android, you'd use flutter_ble_peripheral package
      // For now, we'll use scanning approach on both devices
      
    } catch (e) {
      print('❌ Error starting advertising: $e');
    }
  }

  // Scan for nearby devices and get RSSI
  static Stream<Map<String, dynamic>> scanForDevice(String targetDeviceId) async* {
    try {
      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        print('❌ Bluetooth permissions not granted');
        return;
      }

      final isAvailable = await isBluetoothAvailable();
      if (!isAvailable) {
        print('❌ Bluetooth not available or turned off');
        return;
      }

      print('🔍 Scanning for device: $targetDeviceId');

      // ✅ FIXED — Continuous BLE scanning
      _startContinuousScan();

      yield* FlutterBluePlus.scanResults.asyncMap((results) async {
        for (ScanResult result in results) {
          // Check if this is our target device (by name or MAC address)
          if (result.device.platformName.contains(targetDeviceId) ||
              result.device.remoteId.str == targetDeviceId) {
            
            final rssi = result.rssi.toDouble();
            final distance = calculateDistanceFromRSSI(rssi);
            
            print('📶 RSSI: $rssi dBm → Distance: ${distance.toStringAsFixed(1)}m');
            
            return {
              'deviceId': result.device.remoteId.str,
              'deviceName': result.device.platformName,
              'rssi': rssi,
              'distance': distance,
              'timestamp': DateTime.now(),
            };
          }
        }
        
        return {
          'distance': -1.0, // Device not found
          'timestamp': DateTime.now(),
        };
      });

    } catch (e) {
      print('❌ Error scanning: $e');
      yield {
        'distance': -1.0,
        'error': e.toString(),
        'timestamp': DateTime.now(),
      };
    }
  }

  static void _startContinuousScan() async {
    while (true) {
      try {
        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 3));
        await Future.delayed(const Duration(seconds: 4));
      } catch (e) {
        // Ignore scan errors if already scanning
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }

  // RSSI sliding window for smoothing
  static final List<double> _rssiBuffer = [];
  static const int _rssiBufferSize = 8;

  // Calculate distance from RSSI using log-distance path loss model
  static double calculateDistanceFromRSSI(double rssi) {
    if (rssi >= 0) return -1.0;
    
    // Add to buffer
    _rssiBuffer.add(rssi);
    if (_rssiBuffer.length > _rssiBufferSize) {
      _rssiBuffer.removeAt(0);
    }
    
    // Use median (more robust than mean against outliers)
    final sorted = List<double>.from(_rssiBuffer)..sort();
    final medianRssi = sorted[sorted.length ~/ 2];
    
    // Log-distance path loss model
    final distance = pow(10, (REFERENCE_RSSI - medianRssi) / (10 * PATH_LOSS_EXPONENT));
    return distance.toDouble().clamp(0.1, 100.0); // Clamp to reasonable range
  }

  // Calibrate RSSI at known distance
  static double calibrateRSSI(List<double> rssiReadings) {
    // Average multiple RSSI readings at 1 meter distance
    final avgRSSI = rssiReadings.reduce((a, b) => a + b) / rssiReadings.length;
    print('📏 Calibrated RSSI at 1m: ${avgRSSI.toStringAsFixed(1)} dBm');
    return avgRSSI;
  }

  // Stop scanning
  static Future<void> stopScanning() async {
    try {
      await FlutterBluePlus.stopScan();
      print('⏹️ Stopped BLE scanning');
    } catch (e) {
      print('❌ Error stopping scan: $e');
    }
  }

  // Get distance category
  static String getDistanceCategory(double distance) {
    if (distance < 0) return 'Unknown';
    if (distance < 2) return 'Very Close';
    if (distance < 5) return 'Close';
    if (distance < 10) return 'Near';
    if (distance < 30) return 'Medium';
    if (distance < 50) return 'Far';
    return 'Very Far';
  }

  // Format distance for display
  static String formatDistance(double distance) {
    if (distance < 0) return 'Unknown';
    if (distance < 1) return '${(distance * 100).round()}cm';
    if (distance < 10) return '${distance.toStringAsFixed(1)}m';
    return '${distance.round()}m';
  }

  // Get device's Bluetooth ID (for identification)
  static Future<String?> getDeviceBluetoothId() async {
    try {
      // Get the adapter state which includes device info
      final adapterState = await FlutterBluePlus.adapterState.first;
      
      // For scanning purposes, use the adapter name
      // Note: Actual MAC address may be randomized on newer Android versions
      final deviceName = FlutterBluePlus.adapterName;
      return deviceName;
    } catch (e) {
      print('❌ Error getting Bluetooth ID: $e');
      return null;
    }
  }

  // Cleanup
  static Future<void> dispose() async {
    await stopScanning();
    _scanSubscription?.cancel();
  }
}