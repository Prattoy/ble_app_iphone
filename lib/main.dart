import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LED Control',
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
  BluetoothConnection? connection;
  bool isConnected = false;
  String connectionStatus = "Disconnected";

  bool led32 = false;
  bool led27 = false;
  bool led25 = false;

  // Sensor variables
  double? heading;
  double lastAcceleration = 0;
  DateTime? lastFlickTime;

  // Light sectors (pin: [start_angle, end_angle])
  final Map<String, List<int>> lightSectors = {
    'G32': [300, 60],    // Right sector (30° left of East to 30° right of East)
    'G27': [60, 120],    // Middle sector (East to Southeast)
    'G25': [120, 300],   // Left sector (Southeast all around to 30° left of East)
  };

  Future<bool> _checkBluetoothPermissions() async {
    if (await Permission.bluetoothConnect.request().isGranted &&
        await Permission.bluetoothScan.request().isGranted) {
      return true;
    }
    return false;
  }

  Future<bool> _checkSensorPermissions() async {
    if (await Permission.locationWhenInUse.request().isGranted) {
      return true;
    }
    return false;
  }

  void toggleLED(String pin, bool state) {
    if (connection != null && isConnected) {
      String command = pin + (state ? "_ON" : "_OFF") + '\n';
      print("Sending command: $command");
      connection!.output.add(Uint8List.fromList(command.codeUnits));
      connection!.output.allSent.then((_) {
        print("Command sent successfully");
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("${pin} turned ${state ? 'ON' : 'OFF'}")),
        );
      }).catchError((error) {
        print("Error sending command: $error");
      });
    } else {
      print("Cannot send command - not connected to ESP32");
    }
  }

  void connectToESP32() async {
    try {
      bool hasPermission = await _checkBluetoothPermissions();
      if (!hasPermission) {
        setState(() {
          connectionStatus = "Bluetooth permissions denied";
        });
        return;
      }

      BluetoothDevice? selectedDevice =
      await FlutterBluetoothSerial.instance.getBondedDevices().then((devices) => devices.firstWhere(
            (device) => device.name == "ESP32_BT_Control",
        orElse: () => throw Exception("ESP32_BT_Control not found"),
      ));

      setState(() {
        connectionStatus = "Connecting...";
      });

      await BluetoothConnection.toAddress(selectedDevice!.address).then((conn) {
        print('Connected to ESP32');
        connection = conn;
        isConnected = true;
        setState(() {
          connectionStatus = "Connected to ${selectedDevice.name}";
        });

        connection!.input!.listen(null, onDone: () {
          print('Disconnected from ESP32');
          setState(() {
            isConnected = false;
            connectionStatus = "Disconnected";
          });
        });

      }).catchError((error) {
        print('Cannot connect: $error');
        setState(() {
          connectionStatus = "Connection failed";
        });
      });
    } catch (e) {
      print('Error: $e');
      setState(() {
        connectionStatus = "Error: ${e.toString()}";
      });
    }
  }

  void _initSensors() async {
    if (!await _checkSensorPermissions()) {
      print("Location permissions denied");
      return;
    }

    // Compass listener
    FlutterCompass.events?.listen((event) {
      setState(() {
        heading = event.heading;
      });
    });

    // Accelerometer listener for flick detection
    accelerometerEvents.listen((AccelerometerEvent event) {
      double acceleration = (event.x.abs() + event.y.abs() + event.z.abs());
      double delta = acceleration - lastAcceleration;
      lastAcceleration = acceleration;

      // Detect flick (sudden movement with cooldown)
      if (delta > 15 && (lastFlickTime == null ||
          DateTime.now().difference(lastFlickTime!) > Duration(milliseconds: 500))) {
        lastFlickTime = DateTime.now();
        _handleFlick();
      }
    });
  }

  void _handleFlick() {
    if (heading == null || !isConnected) return;

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

  @override
  void initState() {
    super.initState();
    connectToESP32();
    _initSensors();
  }

  @override
  void dispose() {
    connection?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('LED Control')),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              connectionStatus,
              style: TextStyle(
                color: isConnected ? Colors.green : Colors.red,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 10),
            Text(
              heading != null ? 'Heading: ${heading!.toStringAsFixed(1)}°' : 'Compass not available',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 30),
            Card(
              margin: EdgeInsets.symmetric(vertical: 10, horizontal: 20),
              child: Column(
                children: [
                  SwitchListTile(
                    title: Text("LED on G32 (West-North)"),
                    value: led32,
                    onChanged: (val) {
                      setState(() => led32 = val);
                      toggleLED("G32", val);
                    },
                  ),
                  Divider(),
                  SwitchListTile(
                    title: Text("LED on G27 (North-East)"),
                    value: led27,
                    onChanged: (val) {
                      setState(() => led27 = val);
                      toggleLED("G27", val);
                    },
                  ),
                  Divider(),
                  SwitchListTile(
                    title: Text("LED on G25 (East-South)"),
                    value: led25,
                    onChanged: (val) {
                      setState(() => led25 = val);
                      toggleLED("G25", val);
                    },
                  ),
                ],
              ),
            ),
            SizedBox(height: 20),
            Text(
              "Flick your phone towards a direction to toggle the corresponding light",
              textAlign: TextAlign.center,
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            SizedBox(height: 20),
            if (!isConnected)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: ElevatedButton(
                  onPressed: connectToESP32,
                  child: Text("Reconnect"),
                  style: ElevatedButton.styleFrom(
                    minimumSize: Size(double.infinity, 50),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}