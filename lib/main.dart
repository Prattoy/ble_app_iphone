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
  int currentLED = 0;
  String sensorStatus = "Initializing...";

  StreamSubscription<List<ScanResult>>? scanSubscription;
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;
  StreamSubscription<AccelerometerEvent>? accelerometerSubscription;
  StreamSubscription<UserAccelerometerEvent>? userAccelerometerSubscription;
  StreamSubscription<GyroscopeEvent>? gyroscopeSubscription;

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
    print("Checking Bluetooth permissions...");

    if (Theme.of(context).platform == TargetPlatform.iOS) {
      // For iOS, we only need bluetooth permission
      PermissionStatus bluetoothStatus = await Permission.bluetooth.request();
      print("iOS Bluetooth permission: $bluetoothStatus");

      if (!bluetoothStatus.isGranted) {
        setState(() {
          connectionStatus = "Bluetooth permission denied";
        });
      }
    } else {
      // Android permissions
      await Permission.bluetoothConnect.request();
      await Permission.bluetoothScan.request();
      await Permission.location.request();
    }
  }

  Future<bool> _checkSensorPermissions() async {
    print("Checking sensor permissions...");

    if (Theme.of(context).platform == TargetPlatform.iOS) {
      // For iOS, location permission is required for compass
      PermissionStatus locationStatus = await Permission.locationWhenInUse.status;
      print("Current location permission status: $locationStatus");

      // If permission was never requested or denied, request it
      if (locationStatus == PermissionStatus.denied) {
        locationStatus = await Permission.locationWhenInUse.request();
        print("Location permission after request: $locationStatus");
      }

      // Check if permanently denied
      if (locationStatus == PermissionStatus.permanentlyDenied) {
        setState(() {
          sensorStatus = "Location permission permanently denied";
        });
        return false;
      }

      // For motion sensors on iOS, they don't require explicit permission in most cases
      // The sensors should work if the app is in foreground
      if (locationStatus.isGranted) {
        return true;
      } else {
        setState(() {
          sensorStatus = "Location permission required for compass";
        });
        return false;
      }
    } else {
      // Android - check location permission
      PermissionStatus locationStatus = await Permission.location.request();
      return locationStatus.isGranted;
    }
  }

  void _initSensors() async {
    print("Initializing sensors...");

    // Cancel existing subscriptions first
    accelerometerSubscription?.cancel();
    userAccelerometerSubscription?.cancel();
    gyroscopeSubscription?.cancel();

    setState(() {
      sensorStatus = "Initializing sensors...";
    });

    // For iOS, try to initialize sensors without explicit permission check
    // Motion sensors on iOS don't require permission in most cases
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      await _initializeiOSSensors();
    } else {
      // For Android, check permissions first
      if (!await _checkSensorPermissions()) {
        print("Location permissions denied");
        setState(() {
          sensorStatus = "Location permission denied";
        });
        return;
      }
      await _initializeAndroidSensors();
    }
  }

  Future<void> _initializeiOSSensors() async {
    try {
      // Try compass first (requires location permission)
      bool hasLocationPermission = await _checkSensorPermissions();

      if (hasLocationPermission) {
        // Initialize compass
        FlutterCompass.events?.listen((event) {
          if (mounted && event.heading != null) {
            setState(() {
              heading = event.heading;
            });
          }
        }).onError((error) {
          print("Compass error: $error");
        });
      }

      // Try motion sensors (usually work without explicit permission on iOS)
      print("Testing iOS motion sensors...");

      // Try regular accelerometer first (more reliable on iOS)
      try {
        print("Testing regular accelerometer on iOS...");

        // Create a stream subscription without awaiting first event to avoid the sampling period issue
        accelerometerSubscription = accelerometerEvents.listen((event) {
          if (mounted) {
            _processAccelerometerData(event.x, event.y, event.z, "regular");
            // Set status on first successful event
            if (sensorStatus.contains("Testing")) {
              setState(() {
                sensorStatus = hasLocationPermission
                    ? "Accelerometer + compass active"
                    : "Accelerometer active (no compass)";
              });
            }
          }
        }, onError: (error) {
          print("Regular accelerometer error: $error");
          accelerometerSubscription?.cancel();
          _tryUserAccelerometer(hasLocationPermission);
        });

        // Wait a bit to see if we get data
        await Future.delayed(Duration(seconds: 2));

        // If we haven't gotten data yet, try user accelerometer
        if (sensorStatus.contains("Testing")) {
          accelerometerSubscription?.cancel();
          _tryUserAccelerometer(hasLocationPermission);
        }

      } catch (e) {
        print("Regular accelerometer setup failed: $e");
        _tryUserAccelerometer(hasLocationPermission);
      }

    } catch (e) {
      print("iOS sensor initialization error: $e");
      setState(() {
        sensorStatus = "iOS sensor error: $e";
      });
    }
  }

  Future<void> _tryUserAccelerometer(bool hasLocationPermission) async {
    try {
      print("Trying user accelerometer on iOS...");

      userAccelerometerSubscription = userAccelerometerEvents.listen((event) {
        if (mounted) {
          _processAccelerometerData(event.x, event.y, event.z, "user");
          // Set status on first successful event
          if (sensorStatus.contains("Testing")) {
            setState(() {
              sensorStatus = hasLocationPermission
                  ? "User accelerometer + compass active"
                  : "User accelerometer active (no compass)";
            });
          }
        }
      }, onError: (error) {
        print("User accelerometer error: $error");
        userAccelerometerSubscription?.cancel();
        _tryGyroscope(hasLocationPermission);
      });

      // Wait a bit to see if we get data
      await Future.delayed(Duration(seconds: 2));

      // If we haven't gotten data yet, try gyroscope
      if (sensorStatus.contains("Testing")) {
        userAccelerometerSubscription?.cancel();
        _tryGyroscope(hasLocationPermission);
      }

    } catch (e) {
      print("User accelerometer setup failed: $e");
      _tryGyroscope(hasLocationPermission);
    }
  }

  Future<void> _tryGyroscope(bool hasLocationPermission) async {
    try {
      print("Trying gyroscope on iOS...");

      gyroscopeSubscription = gyroscopeEvents.listen((event) {
        if (mounted) {
          double rotationSpeed = (event.x.abs() + event.y.abs() + event.z.abs());
          _processGyroscopeData(rotationSpeed);
          // Set status on first successful event
          if (sensorStatus.contains("Testing")) {
            setState(() {
              sensorStatus = hasLocationPermission
                  ? "Gyroscope + compass active"
                  : "Gyroscope active (no compass)";
            });
          }
        }
      }, onError: (error) {
        print("Gyroscope error: $error");
        gyroscopeSubscription?.cancel();
        _allSensorsFailed(hasLocationPermission);
      });

      // Wait a bit to see if we get data
      await Future.delayed(Duration(seconds: 2));

      // If we haven't gotten data yet, all sensors failed
      if (sensorStatus.contains("Testing")) {
        gyroscopeSubscription?.cancel();
        _allSensorsFailed(hasLocationPermission);
      }

    } catch (e) {
      print("Gyroscope setup failed: $e");
      _allSensorsFailed(hasLocationPermission);
    }
  }

  void _allSensorsFailed(bool hasLocationPermission) {
    print("All iOS sensors failed");
    setState(() {
      sensorStatus = hasLocationPermission
          ? "Motion sensors unavailable (compass only)"
          : "All sensors unavailable";
      currentAcceleration = -1;
    });
  }

  Future<void> _initializeAndroidSensors() async {
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

      print("Attempting to initialize Android sensors...");
      setState(() {
        sensorStatus = "Testing sensors...";
      });

      // Try regular accelerometer first
      try {
        print("Testing regular accelerometer...");
        AccelerometerEvent? testEvent = await accelerometerEvents.first.timeout(
          Duration(seconds: 2),
        );
        print("Regular accelerometer works: x=${testEvent.x}, y=${testEvent.y}, z=${testEvent.z}");

        accelerometerSubscription = accelerometerEvents.listen((event) {
          _processAccelerometerData(event.x, event.y, event.z, "regular");
        });

        setState(() {
          sensorStatus = "Regular accelerometer active";
        });
      } catch (e) {
        print("Regular accelerometer failed: $e");

        // Try user accelerometer
        try {
          print("Testing user accelerometer...");
          UserAccelerometerEvent? testUserEvent = await userAccelerometerEvents.first.timeout(
            Duration(seconds: 2),
          );
          print("User accelerometer works: x=${testUserEvent.x}, y=${testUserEvent.y}, z=${testUserEvent.z}");

          userAccelerometerSubscription = userAccelerometerEvents.listen((event) {
            _processAccelerometerData(event.x, event.y, event.z, "user");
          });

          setState(() {
            sensorStatus = "User accelerometer active";
          });
        } catch (e2) {
          print("User accelerometer failed: $e2");

          // Try gyroscope as last resort
          try {
            print("Testing gyroscope...");
            GyroscopeEvent? testGyroEvent = await gyroscopeEvents.first.timeout(
              Duration(seconds: 2),
            );
            print("Gyroscope works: x=${testGyroEvent.x}, y=${testGyroEvent.y}, z=${testGyroEvent.z}");

            gyroscopeSubscription = gyroscopeEvents.listen((event) {
              double rotationSpeed = (event.x.abs() + event.y.abs() + event.z.abs());
              _processGyroscopeData(rotationSpeed);
            });

            setState(() {
              sensorStatus = "Gyroscope active";
            });
          } catch (e3) {
            print("All sensors failed: $e3");
            setState(() {
              sensorStatus = "No sensors available";
              currentAcceleration = -1;
            });
          }
        }
      }
    } catch (e) {
      print("Android sensor initialization error: $e");
      setState(() {
        sensorStatus = "Android sensor error: $e";
      });
    }
  }

  // Add this helper method to manually request location permission
  Future<void> _requestLocationPermission() async {
    print("Manually requesting location permission...");

    try {
      PermissionStatus status = await Permission.locationWhenInUse.status;
      print("Current location permission status: $status");

      if (status == PermissionStatus.permanentlyDenied) {
        // Show dialog to go to settings
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text("Location Permission Required"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Location permission is needed for compass functionality. To enable:"),
                  SizedBox(height: 10),
                  Text("1. Go to iPhone Settings"),
                  Text("2. Privacy & Security → Location Services"),
                  Text("3. Find this app and select 'While Using App'"),
                  SizedBox(height: 10),
                  Text("Motion sensors should still work for flick detection."),
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
                    openAppSettings();
                  },
                  child: Text("Open Settings"),
                ),
              ],
            ),
          );
        }
      } else if (status == PermissionStatus.denied) {
        // Request permission
        status = await Permission.locationWhenInUse.request();
        print("Location permission request result: $status");

        if (status.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Location permission granted! Compass should work now.")),
            );
          }
          // Reinitialize compass specifically
          _initializeCompass();
        } else if (status == PermissionStatus.permanentlyDenied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Permission permanently denied. Motion sensors still work.")),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Location permission denied. Motion sensors still work.")),
            );
          }
        }
      } else if (status.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Permission already granted! Compass should work.")),
          );
        }
        _initializeCompass();
      }
    } catch (e) {
      print("Permission request error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Permission error: $e")),
        );
      }
    }
  }

  void _initializeCompass() {
    try {
      FlutterCompass.events?.listen((event) {
        if (mounted && event.heading != null) {
          setState(() {
            heading = event.heading;
          });
        }
      }).onError((error) {
        print("Compass error: $error");
      });
    } catch (e) {
      print("Compass initialization error: $e");
    }
  }

  void _processAccelerometerData(double x, double y, double z, String type) {
    double magnitude = (x * x + y * y + z * z).abs();

    if (mounted) {
      setState(() {
        currentAcceleration = magnitude;
      });
    }

    // Different thresholds for different sensor types
    double threshold = type == "user" ? 20.0 : 150.0;

    if (magnitude > threshold && (lastFlickTime == null ||
        DateTime.now().difference(lastFlickTime!) > Duration(milliseconds: 800))) {
      lastFlickTime = DateTime.now();
      print("FLICK DETECTED ($type)! Magnitude: $magnitude");
      _handleFlick();
    }
  }

  void _processGyroscopeData(double rotationSpeed) {
    if (mounted) {
      setState(() {
        currentAcceleration = rotationSpeed * 100; // Scale for display
      });
    }

    if (rotationSpeed > 3.0 && (lastFlickTime == null ||
        DateTime.now().difference(lastFlickTime!) > Duration(milliseconds: 800))) {
      lastFlickTime = DateTime.now();
      print("GYRO FLICK DETECTED! Speed: $rotationSpeed");
      _handleFlick();
    }
  }

  void _handleFlick() {
    if (!isConnected) return;

    if (heading == null) {
      // Compass not available - cycle through LEDs
      List<String> pins = ['G32', 'G27', 'G25'];
      String pin = pins[currentLED];
      bool newState = !_getCurrentPinState(pin);

      toggleLED(pin, newState);
      setState(() {
        if (pin == 'G32') led32 = newState;
        if (pin == 'G27') led27 = newState;
        if (pin == 'G25') led25 = newState;
      });

      currentLED = (currentLED + 1) % 3;
      print("Flick detected (no compass) - toggled $pin to ${newState ? 'ON' : 'OFF'}");
      return;
    }

    // Compass-based direction logic
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

  String _getSensorStatusText() {
    if (currentAcceleration == -1) {
      return "❌ All sensors failed";
    } else if (currentAcceleration == 0) {
      return "⏳ Waiting for sensor data...";
    } else if (currentAcceleration > 0 && currentAcceleration < 50) {
      return "✅ Sensors working (user accelerometer)";
    } else if (currentAcceleration >= 50) {
      return "✅ Sensors working (regular accelerometer/gyroscope)";
    }
    return "🔄 $sensorStatus";
  }

  Future<void> startScan() async {
    if (isScanning) return;

    setState(() {
      isScanning = true;
      devicesList.clear();
      connectionStatus = "Scanning for devices...";
    });

    try {
      if (await FlutterBluePlus.isSupported == false) {
        setState(() {
          connectionStatus = "Bluetooth not supported";
          isScanning = false;
        });
        return;
      }

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
    scanSubscription?.cancel();
    connectionSubscription?.cancel();
    accelerometerSubscription?.cancel();
    userAccelerometerSubscription?.cancel();
    gyroscopeSubscription?.cancel();
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
                        onPressed: _requestLocationPermission,
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

            // Sensor Debug Info
            if (isConnected)
              Card(
                color: Colors.blue.shade50,
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Text(
                        "Sensor Debug Info",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 10),
                      Text(_getSensorStatusText()),
                      SizedBox(height: 10),
                      Text("Current Value: ${currentAcceleration.toStringAsFixed(2)}"),
                      Text("Regular Accel Threshold: 150"),
                      Text("User Accel Threshold: 20"),
                      Text("Gyroscope Threshold: 3.0"),
                      SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton(
                            onPressed: () {
                              print("Manual flick test triggered");
                              _handleFlick();
                            },
                            child: Text("Test Flick"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              print("Reinitializing sensors...");
                              _initSensors();
                            },
                            child: Text("Retry Sensors"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 10),
                      ElevatedButton(
                        onPressed: () async {
                          print("Requesting all permissions...");
                          await _requestLocationPermission();
                        },
                        child: Text("Request Permissions"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Instructions
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