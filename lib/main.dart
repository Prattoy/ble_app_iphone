import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LED Control BLE',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: LEDControlPage(),
    );
  }
}

class LEDControlPage extends StatefulWidget {
  @override
  _LEDControlPageState createState() => _LEDControlPageState();
}

class _LEDControlPageState extends State<LEDControlPage> {
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? writeCharacteristic;
  bool isConnected = false;
  bool isScanning = false;
  String connectionStatus = "Disconnected";
  List<BluetoothDevice> devicesList = [];

  bool led32 = false;
  bool led27 = false;
  bool led25 = false;

  // Sensor variables
  double? heading;
  double lastAcceleration = 0;
  double currentAcceleration = 0;
  double lastDelta = 0;
  DateTime? lastFlickTime;
  int currentLED = 0; // Moved static variable to instance variable
  late StreamSubscription<List<ScanResult>> scanSubscription;
  late StreamSubscription<BluetoothConnectionState> connectionSubscription;

  // BLE Service and Characteristic UUIDs (must match ESP32)
  static const String SERVICE_UUID = "12345678-1234-1234-1234-123456789abc";
  static const String CHARACTERISTIC_UUID = "87654321-4321-4321-4321-cba987654321";

  // Light sectors (pin: [start_angle, end_angle])
  final Map<String, List<int>> lightSectors = {
    'G32': [300, 60],    // Right sector
    'G27': [60, 120],    // Middle sector
    'G25': [120, 300],   // Left sector
  };

  @override
  void initState() {
    super.initState();
    _checkBluetoothPermissions();
    _initSensors();
  }

  Future<void> _checkBluetoothPermissions() async {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      // iOS permissions
      await Permission.bluetooth.request();
    } else {
      // Android permissions
      await Permission.bluetoothConnect.request();
      await Permission.bluetoothScan.request();
      await Permission.location.request();
    }
  }

  Future<bool> _checkSensorPermissions() async {
    // Check both location (for compass) and motion (for accelerometer)
    PermissionStatus locationStatus = await Permission.locationWhenInUse.request();

    // For iOS motion/sensor access
    bool motionAvailable = true;
    try {
      // Test if accelerometer is available by checking if we can get a reading
      await accelerometerEvents.take(1).timeout(Duration(seconds: 2));
      print("Accelerometer is available");
    } catch (e) {
      print("Accelerometer not available: $e");
      motionAvailable = false;
    }

    print("Location permission: $locationStatus");
    print("Motion available: $motionAvailable");

    return locationStatus.isGranted;
  }

  void _initSensors() async {
    if (!await _checkSensorPermissions()) {
      print("Location permissions denied");
      return;
    }

    try {
      // Compass listener
      FlutterCompass.events?.listen((event) {
        if (mounted && event.heading != null) {
          setState(() {
            heading = event.heading;
          });
        }
      }).onError((error) {
        print("Compass error: $error");
      });

      // Accelerometer listener - SIMPLIFIED approach
      accelerometerEvents.listen((AccelerometerEvent event) {
        print("Accelerometer event received: x=${event.x}, y=${event.y}, z=${event.z}");
        try {
          // Simple total acceleration (gravity is ~9.8, so movement adds to this)
          double totalAcceleration = (event.x * event.x + event.y * event.y + event.z * event.z).abs();

          // Update display
          if (mounted) {
            setState(() {
              currentAcceleration = totalAcceleration;
              lastDelta = totalAcceleration; // Just show total for debugging
            });
          }

          // Much simpler: if total acceleration exceeds gravity + movement threshold
          if (totalAcceleration > 150 && (lastFlickTime == null ||
              DateTime.now().difference(lastFlickTime!) > Duration(milliseconds: 800))) {
            lastFlickTime = DateTime.now();
            print("FLICK DETECTED! Total acceleration: $totalAcceleration");
            _handleFlick();
          }
        } catch (e) {
          print("Accelerometer error: $e");
        }
      });

      // Try gyroscope as alternative to accelerometer
      try {
        gyroscopeEvents.listen((GyroscopeEvent event) {
          double rotationSpeed = (event.x.abs() + event.y.abs() + event.z.abs());
          print("Gyroscope: ${rotationSpeed.toStringAsFixed(2)}");

          if (mounted) {
            setState(() {
              currentAcceleration = rotationSpeed * 100; // Scale for display
            });
          }

          // Detect quick rotation as "flick"
          if (rotationSpeed > 3.0 && (lastFlickTime == null ||
              DateTime.now().difference(lastFlickTime!) > Duration(milliseconds: 800))) {
            lastFlickTime = DateTime.now();
            print("ROTATION FLICK DETECTED! Speed: $rotationSpeed");
            _handleFlick();
          }
        });
        print("Using gyroscope for flick detection");
      } catch (e) {
        print("Gyroscope also failed: $e");
      }
    } catch (e) {
      print("Sensor initialization error: $e");
    }
  }

  void _handleFlick() {
    if (!isConnected) return;

    if (heading == null) {
      // Compass not available - cycle through LEDs instead
      List<String> pins = ['G32', 'G27', 'G25'];

      String pin = pins[currentLED];
      bool newState = !_getCurrentPinState(pin);

      toggleLED(pin, newState);
      setState(() {
        if (pin == 'G32') led32 = newState;
        if (pin == 'G27') led27 = newState;
        if (pin == 'G25') led25 = newState;
      });

      // Move to next LED for next flick
      currentLED = (currentLED + 1) % 3;

      print("Flick detected (no compass) - toggled $pin to ${newState ? 'ON' : 'OFF'}");
      return;
    }

    // Original compass-based direction logic
    for (var entry in lightSectors.entries) {
      int start = entry.value[0];
      int end = entry.value[1];

      bool inSector = (start < end)
          ? (heading! >= start && heading! <= end)
          : (heading! >= start || heading! <= end);

      if (inSector) {
        String pin = entry.key;
        bool newState = !_getCurrentPinState(pin);
        toggleLED(pin, newState);
        setState(() {
          if (pin == 'G32') led32 = newState;
          if (pin == 'G27') led27 = newState;
          if (pin == 'G25') led25 = newState;
        });
        break;
      }
    }
  }

  bool _getCurrentPinState(String pin) {
    switch (pin) {
      case 'G32': return led32;
      case 'G27': return led27;
      case 'G25': return led25;
      default: return false;
    }
  }

  Future<void> startScan() async {
    if (isScanning) return;

    setState(() {
      isScanning = true;
      devicesList.clear();
      connectionStatus = "Scanning for devices...";
    });

    try {
      // Check if Bluetooth is on
      if (await FlutterBluePlus.isSupported == false) {
        setState(() {
          connectionStatus = "Bluetooth not supported";
          isScanning = false;
        });
        return;
      }

      // Start scanning
      await FlutterBluePlus.startScan(timeout: Duration(seconds: 10));

      scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          if (result.device.platformName.isNotEmpty &&
              result.device.platformName.contains("ESP32")) {
            if (!devicesList.any((device) => device.remoteId == result.device.remoteId)) {
              setState(() {
                devicesList.add(result.device);
              });
            }
          }
        }
      });

      // Stop scanning after timeout
      await Future.delayed(Duration(seconds: 10));
      await FlutterBluePlus.stopScan();

      setState(() {
        isScanning = false;
        if (devicesList.isEmpty) {
          connectionStatus = "No ESP32 devices found";
        } else {
          connectionStatus = "Found ${devicesList.length} device(s)";
        }
      });

    } catch (e) {
      print("Error during scan: $e");
      setState(() {
        isScanning = false;
        connectionStatus = "Scan error: ${e.toString()}";
      });
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      setState(() {
        connectionStatus = "Connecting to ${device.platformName}...";
      });

      await device.connect();
      connectedDevice = device;

      // Listen to connection state
      connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            isConnected = false;
            connectionStatus = "Disconnected";
            connectedDevice = null;
            writeCharacteristic = null;
          });
        }
      });

      // Discover services
      List<BluetoothService> services = await device.discoverServices();

      for (BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase()) {
          for (BluetoothCharacteristic characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toLowerCase() == CHARACTERISTIC_UUID.toLowerCase()) {
              writeCharacteristic = characteristic;
              break;
            }
          }
        }
      }

      if (writeCharacteristic != null) {
        setState(() {
          isConnected = true;
          connectionStatus = "Connected to ${device.platformName}";
        });
      } else {
        await device.disconnect();
        setState(() {
          connectionStatus = "Service/Characteristic not found";
        });
      }

    } catch (e) {
      print("Connection error: $e");
      setState(() {
        connectionStatus = "Connection failed: ${e.toString()}";
      });
    }
  }

  Future<void> toggleLED(String pin, bool state) async {
    if (!isConnected || writeCharacteristic == null) {
      print("Cannot send command - not connected");
      return;
    }

    try {
      String command = pin + (state ? "_ON" : "_OFF");
      List<int> bytes = utf8.encode(command);

      await writeCharacteristic!.write(bytes);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("${pin} turned ${state ? 'ON' : 'OFF'}")),
        );
      }

      print("Command sent: $command");
    } catch (e) {
      print("Error sending command: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to send command")),
        );
      }
    }
  }

  Future<void> disconnect() async {
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
    }
  }

  @override
  void dispose() {
    scanSubscription.cancel();
    connectionSubscription.cancel();
    disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('LED Control BLE'),
        actions: [
          if (isConnected)
            IconButton(
              icon: Icon(Icons.bluetooth_disabled),
              onPressed: disconnect,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Connection Status
            Card(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(
                      connectionStatus,
                      style: TextStyle(
                        color: isConnected ? Colors.green : Colors.red,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 10),
                    if (!isConnected && !isScanning)
                      ElevatedButton(
                        onPressed: startScan,
                        child: Text("Scan for ESP32"),
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size(double.infinity, 45),
                        ),
                      ),
                    if (isScanning)
                      Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 10),
                          Text("Scanning..."),
                        ],
                      ),
                  ],
                ),
              ),
            ),

            // Device List
            if (devicesList.isNotEmpty && !isConnected)
              Card(
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        "Available Devices",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    ...devicesList.map((device) => ListTile(
                      title: Text(device.platformName.isNotEmpty
                          ? device.platformName
                          : "Unknown Device"),
                      subtitle: Text(device.remoteId.toString()),
                      trailing: ElevatedButton(
                        onPressed: () => connectToDevice(device),
                        child: Text("Connect"),
                      ),
                    )).toList(),
                  ],
                ),
              ),

            // Compass Info
            if (isConnected)
              Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    heading != null
                        ? 'Compass: ${heading!.toStringAsFixed(1)}°'
                        : 'Compass not available',
                    style: TextStyle(fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

            // LED Controls
            if (isConnected)
              Card(
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        "LED Controls",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    SwitchListTile(
                      title: Text("LED on G32 (West-North)"),
                      subtitle: Text("Pin 32"),
                      value: led32,
                      onChanged: (val) {
                        setState(() => led32 = val);
                        toggleLED("G32", val);
                      },
                    ),
                    Divider(),
                    SwitchListTile(
                      title: Text("LED on G27 (North-East)"),
                      subtitle: Text("Pin 27"),
                      value: led27,
                      onChanged: (val) {
                        setState(() => led27 = val);
                        toggleLED("G27", val);
                      },
                    ),
                    Divider(),
                    SwitchListTile(
                      title: Text("LED on G25 (East-South)"),
                      subtitle: Text("Pin 25"),
                      value: led25,
                      onChanged: (val) {
                        setState(() => led25 = val);
                        toggleLED("G25", val);
                      },
                    ),
                  ],
                ),
              ),

            // Compass Permission Card
            if (isConnected && heading == null)
              Card(
                color: Colors.orange.shade50,
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Icon(Icons.location_off, size: 48, color: Colors.orange),
                      SizedBox(height: 10),
                      Text(
                        "Compass not available",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 10),
                      Text(
                        "Location permission is needed for compass and flick detection",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14),
                      ),
                      SizedBox(height: 10),
                      ElevatedButton(
                        onPressed: () async {
                          PermissionStatus status = await Permission.locationWhenInUse.status;

                          if (status.isPermanentlyDenied) {
                            // Show dialog to go to settings
                            showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text("Location Permission Required"),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text("Location permission was permanently denied. To enable compass and flick detection:"),
                                    SizedBox(height: 10),
                                    Text("1. Go to iPhone Settings"),
                                    Text("2. Privacy & Security → Location Services"),
                                    Text("3. Find this app and select 'While Using App'"),
                                  ],
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: Text("Cancel"),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      Navigator.pop(context);
                                      openAppSettings(); // Opens app settings
                                    },
                                    child: Text("Open Settings"),
                                  ),
                                ],
                              ),
                            );
                          } else {
                            // Try to request permission
                            status = await Permission.locationWhenInUse.request();
                            print("Location permission status: $status");

                            if (status.isGranted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Location permission granted! Compass should work now.")),
                              );
                              _initSensors(); // Reinitialize sensors
                            } else if (status.isPermanentlyDenied) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Permission permanently denied. Check app settings.")),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Location permission denied. Flick detection won't work.")),
                              );
                            }
                          }
                        },
                        child: Text("Enable Location Permission"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Test button for flick detection
            if (isConnected)
              Card(
                color: Colors.blue.shade50,
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Text(
                        "Flick Detection Debug",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 10),
                      Text("Total Acceleration: ${currentAcceleration.toStringAsFixed(2)}"),
                      Text("Threshold: 150 (need > this for flick)"),
                      Text("Normal resting: ~100, Movement: 150+"),
                      SizedBox(height: 10),
                      ElevatedButton(
                        onPressed: () {
                          print("Manual flick test triggered");
                          _handleFlick();
                        },
                        child: Text("Simulate Flick"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Card(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Icon(Icons.smartphone, size: 48, color: Colors.blue),
                    SizedBox(height: 10),
                    Text(
                      heading != null
                          ? "Flick your phone towards a direction to toggle the corresponding light"
                          : "Manual toggle only - enable location permission for flick detection",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        fontSize: 14,
                        color: heading != null ? Colors.black : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}