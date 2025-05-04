import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';


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

  // Add this to your _LEDControlPageState class
  Future<bool> _checkBluetoothPermissions() async {
    if (await Permission.bluetoothConnect.request().isGranted &&
        await Permission.bluetoothScan.request().isGranted) {
      return true;
    }
    return false;
  }

  void toggleLED(String pin, bool state) {
    if (connection != null && isConnected) {
      String command = pin + (state ? "_ON" : "_OFF") + '\n';
      print("Sending command: $command"); // Print the command being sent
      connection!.output.add(Uint8List.fromList(command.codeUnits));
      connection!.output.allSent.then((_) {
        print("Command sent successfully");
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

        // Listen for disconnection
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

  @override
  void initState() {
    super.initState();
    connectToESP32();
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
            SizedBox(height: 30),
            Card(
              margin: EdgeInsets.symmetric(vertical: 10, horizontal: 20),
              child: Column(
                children: [
                  SwitchListTile(
                    title: Text("LED on G32"),
                    value: led32,
                    onChanged: (val) {
                      setState(() => led32 = val);
                      toggleLED("G32", val);
                    },
                  ),
                  Divider(),
                  SwitchListTile(
                    title: Text("LED on G27"),
                    value: led27,
                    onChanged: (val) {
                      setState(() => led27 = val);
                      toggleLED("G27", val);
                    },
                  ),
                  Divider(),
                  SwitchListTile(
                    title: Text("LED on G25"),
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