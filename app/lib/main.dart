import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; 
import './controllers/order_controller.dart';
import './controllers/driver_controller.dart';
import './controllers/user_controller.dart';
import 'views/tracking_view.dart';
import 'views/register_view.dart';

Future<void> main() async { 
  await dotenv.load(fileName: ".env");
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => OrderController()),
        ChangeNotifierProvider(create: (_) => DriverController()),
        ChangeNotifierProvider(create: (_) => UserController()),
      ],
      child: MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Order Tracking App',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: LoginForm(),
    );
  }
}

class LoginForm extends StatefulWidget {
  @override
  _LoginFormState createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoggedIn = false;
  int? _userId;
  String? _token;
  Timer? _timer;

  final String baseUrl = dotenv.env['BASE_URL'] ?? 'http://10.0.2.2:8080';

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _login(String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/login'), 
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'role': 'user',
        }),
      );

      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('jwt_token', data['token']);
        await prefs.setInt('user_id', data['userId']);
        setState(() {
          _isLoggedIn = true;
          _userId = data['userId'];
          _token = data['token'];
        });
        final orderController = Provider.of<OrderController>(context, listen: false);
        await orderController.fetchOrders(token: _token!, userId: _userId!);
        _startRoutePolling();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login failed: ${response.body}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _startRoutePolling() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: 15), (timer) async {
      final orderController = Provider.of<OrderController>(context, listen: false);
      await orderController.fetchOrders(token: _token!, userId: _userId!);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _isLoggedIn
        ? TrackingView(userId: _userId!, token: _token!)
        : Scaffold(
            appBar: AppBar(title: Text('Login'), backgroundColor: Colors.white),
            backgroundColor: Colors.white,
            body: Padding(
              padding: EdgeInsets.all(16.0),
              child: Column(
                children: [
                  TextField(
                    controller: _usernameController,
                    decoration: InputDecoration(labelText: 'Username'),
                  ),
                  TextField(
                    controller: _passwordController,
                    decoration: InputDecoration(labelText: 'Password'),
                    obscureText: true,
                  ),
                  SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => _login(
                      _usernameController.text.trim(),
                      _passwordController.text.trim(),
                    ),
                    child: Text('Login'),
                  ),
                  SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => RegisterView()),
                      );
                    },
                    child: Text('Register'),
                  ),
                ],
              ),
            ),
          );
  }
}
