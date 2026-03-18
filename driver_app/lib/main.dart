import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import './controllers/d_order_controller.dart';
import './controllers/d_driver_controller.dart';
import './views/d_order_view.dart';
import './views/d_personal_view.dart';

Future<void> main() async {
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    print("env file missing");
  }
  
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => OrderController()),
        ChangeNotifierProvider(create: (_) => DriverController()),
      ],
      child: const DriverApp(),
    ),
  );
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Driver App',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const DriverLoginForm(),
      routes: {
        '/main': (context) => const MainScreen(),
      },
    );
  }
}

class DriverLoginForm extends StatefulWidget {
  const DriverLoginForm({super.key});

  @override
  _DriverLoginFormState createState() => _DriverLoginFormState();
}

class _DriverLoginFormState extends State<DriverLoginForm> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login(String username, String password) async {
    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter both username and password')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final baseUrl = dotenv.env['BASE_URL'] ?? 'http://10.0.2.2:8080';
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/login'), 
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'role': 'driver',
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token'];
        final driverId = data['driverId']; 

        if (token != null && driverId != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('jwt_token', token);
          await prefs.setInt('driver_id', driverId);
          
          if (!mounted) return;
          Provider.of<OrderController>(context, listen: false)
              .fetchOrders(token: token, driverId: driverId);
          Navigator.pushReplacementNamed(context, '/main');
        } else {
           throw Exception("Invalid response");
        }
      } else {
        final errorData = jsonDecode(response.body);
        final msg = errorData['message'] ?? 'Login failed';
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection Error: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Driver Login')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            _isLoading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: () => _login(_usernameController.text.trim(), _passwordController.text.trim()),
                    child: const Text('Login'),
                  ),
          ],
        ),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  Future<Map<String, dynamic>> _getDriverInfo() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'token': prefs.getString('jwt_token') ?? '',
      'driverId': prefs.getInt('driver_id') ?? 0,
    };
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _getDriverInfo(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError || !snapshot.hasData || snapshot.data!['token'].isEmpty) {
          return const Scaffold(
            body: Center(child: Text('Error: Please log in again')),
          );
        }
        final token = snapshot.data!['token'] as String;
        final driverId = snapshot.data!['driverId'] as int;

        final pages = <Widget>[
          OrdersView(driverId: driverId, token: token),
          PersonalView(driverId: driverId, token: token),
        ];

        return Scaffold(
          body: pages[_selectedIndex],
          bottomNavigationBar: BottomNavigationBar(
            items: const <BottomNavigationBarItem>[
              BottomNavigationBarItem(
                icon: Icon(Icons.list),
                label: 'Order',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.person),
                label: 'Personal',
              ),
            ],
            currentIndex: _selectedIndex,
            selectedItemColor: Colors.blue,
            onTap: (index) {
              setState(() {
                _selectedIndex = index;
              });
            },
          ),
        );
      },
    );
  }
}
