import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../providers/a_edit_provider.dart';
import '../providers/a_login_provider.dart';

class EditField {
  String? key;
  final TextEditingController controller = TextEditingController();
}

class EditView extends StatefulWidget {
  const EditView({super.key});

  @override
  State<EditView> createState() => _EditViewState();
}

class _EditViewState extends State<EditView> {
  String? _selectedTable;
  String? _selectedAction;

  final TextEditingController _idController = TextEditingController();
  final Map<String, TextEditingController> _addFormControllers = {};
  final List<EditField> _editFields = [EditField()];
  final _formKey = GlobalKey<FormState>();

  // clear states
  void _resetState() {
    Provider.of<EditProvider>(context, listen: false).clearState();
    _idController.clear();
    
    _addFormControllers.forEach((_, controller) => controller.dispose());
    _addFormControllers.clear();

    _editFields.clear();
    _editFields.add(EditField());
    if (mounted) {
      setState(() {});
    }
  }

  // format timestamps
  String _formatValue(dynamic value) {
    if (value == null) return 'N/A';
    
    if (value is Map && value.containsKey('_seconds')) {
      try {
        final int seconds = value['_seconds'];
        final DateTime date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
        return '${date.year}-${_twoDigits(date.month)}-${_twoDigits(date.day)} ${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
      } catch (e) {
        return value.toString();
      }
    }
    
    return value.toString();
  }

  String _twoDigits(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final editProvider = Provider.of<EditProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Database'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDropdown('Select Table', ['customers', 'drivers', 'orders', 'ratings', 'admins'], _selectedTable, (value) {
                setState(() {
                  _selectedTable = value;
                  _selectedAction = null;
                  _resetState();
                });
              }),
              const SizedBox(height: 20),

              if (_selectedTable != null)
                _buildDropdown('Select Action', _getActionsForTable(_selectedTable!), _selectedAction, (value) {
                  setState(() {
                    _selectedAction = value;
                    _resetState();
                  });
                }),
              const SizedBox(height: 30),

              if (_selectedTable != null && _selectedAction != null)
                _buildDynamicContent(editProvider),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDropdown(String label, List<String> items, String? currentValue, ValueChanged<String?> onChanged) {
    return DropdownButtonFormField<String>(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      value: currentValue,
      items: items.map((String value) {
        return DropdownMenuItem<String>(
          value: value,
          child: Text(value),
        );
      }).toList(),
      onChanged: onChanged,
      validator: (value) => value == null ? 'Please make a selection' : null,
    );
  }

  List<String> _getActionsForTable(String table) {
    if (table == 'ratings') return ['delete'];
    return ['add', 'edit', 'delete'];
  }

  Widget _buildDynamicContent(EditProvider provider) {
    switch (_selectedAction) {
      case 'add':
        return _buildAddForm(provider);
      case 'edit':
        return _buildEditForm(provider);
      case 'delete':
        return _buildDeleteForm(provider);
      default:
        return const SizedBox.shrink();
    }
  }

  // add form
  Widget _buildAddForm(EditProvider provider) {
    final fields = _getFieldsForTable(_selectedTable!);
    if (_addFormControllers.isEmpty) { 
        for (var field in fields) {
          _addFormControllers[field] = TextEditingController();
        }
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Add New Record to $_selectedTable', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 20),
        ...fields.map((field) {
          if (field == 'working_time') {
            return Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: _buildWorkingTimePicker(_addFormControllers[field]!),
            );
          }
          if (field == 'pickup_location' || field == 'dropoff_location' || field == 'address') {
             return Padding(
               padding: const EdgeInsets.only(bottom: 16.0),
               child: AddressAutocompleteField(
                 controller: _addFormControllers[field]!,
                 label: field,
               ),
             );
          }
          return Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: TextFormField(
                controller: _addFormControllers[field],
                decoration: InputDecoration(labelText: field, border: const OutlineInputBorder()),
                validator: (value) => (value == null || value.isEmpty) ? 'This field cannot be empty' : null,
              ),
            );
        }),
        const SizedBox(height: 20),
        _buildConfirmButton(provider),
      ],
    );
  }

  Widget _buildWorkingTimePicker(TextEditingController controller) {
    final hours = List.generate(24, (index) => '${index.toString().padLeft(2, '0')}:00');
    
    String? currentStart;
    String? currentEnd;
    
    if (controller.text.contains(' - ')) {
      final parts = controller.text.split(' - ');
      if (parts.length == 2) {
        if (hours.contains(parts[0])) currentStart = parts[0];
        if (hours.contains(parts[1])) currentEnd = parts[1];
      }
    }

    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Working Time',
        border: OutlineInputBorder(),
      ),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                hint: const Text("Start"),
                value: currentStart,
                items: hours.map((h) => DropdownMenuItem(value: h, child: Text(h))).toList(),
                onChanged: (val) {
                  if (val == null) return;
                  final newEnd = currentEnd ?? '18:00';
                  controller.text = "$val - $newEnd";
                  setState(() {});
                },
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.0),
            child: Text("to"),
          ),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                hint: const Text("End"),
                value: currentEnd,
                items: hours.map((h) => DropdownMenuItem(value: h, child: Text(h))).toList(),
                onChanged: (val) {
                  if (val == null) return;
                  final newStart = currentStart ?? '09:00';
                  controller.text = "$newStart - $val";
                  setState(() {});
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // edit/delete forms
  Column _buildSharedIdForm(EditProvider provider, String title) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                controller: _idController,
                decoration: InputDecoration(labelText: 'Enter ID to $_selectedAction', border: const OutlineInputBorder()),
                keyboardType: TextInputType.number,
                validator: (value) => (value == null || value.isEmpty) ? 'Please enter an ID' : null,
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton(
              onPressed: provider.isLoading
                  ? null
                  : () {
                      if (_formKey.currentState!.validate()) {
                          final token = Provider.of<LoginProvider>(context, listen: false).token!;
                          provider.getRecord(_selectedTable!, int.parse(_idController.text), token);
                      }
                    },
              child: provider.isLoading ? const CircularProgressIndicator(color: Colors.white,) : const Text('Fetch Record'),
            ),
          ],
        ),
        _buildErrorState(provider),
        if (provider.fetchedRecord != null)
          _buildFetchedRecordCard(provider.fetchedRecord!),
      ],
    );
  }
  
  Widget _buildErrorState(EditProvider provider) {
    if (provider.errorMessage != null && provider.fetchedRecord == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8.0),
        child: Text(
          provider.errorMessage!,
          style: const TextStyle(color: Colors.red, fontSize: 16),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildDeleteForm(EditProvider provider) {
    return Column(
      children: [
        _buildSharedIdForm(provider, 'Delete Record from $_selectedTable'),
        if (provider.fetchedRecord != null) ...[
          const SizedBox(height: 20),
          _buildConfirmButton(provider),
        ]
      ],
    );
  }

  Widget _buildEditForm(EditProvider provider) {
    return Column(
      children: [
        _buildSharedIdForm(provider, 'Edit Record in $_selectedTable'),
        if (provider.fetchedRecord != null) ...[
          const Divider(height: 40),
          Text('Fields to Update', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 20),
          ..._buildDynamicEditFields(),
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('More Edits'),
            onPressed: () {
              setState(() {
                _editFields.add(EditField());
              });
            },
          ),
          const SizedBox(height: 20),
          _buildConfirmButton(provider),
        ]
      ],
    );
  }

  // edit form
  List<Widget> _buildDynamicEditFields() {
    final possibleFields = _getFieldsForTable(_selectedTable!, forEdit: true);
    return _editFields.map((field) {
      int index = _editFields.indexOf(field);
      
      bool isWorkingTime = field.key == 'working_time';
      bool isAddress = (field.key == 'pickup_location' || field.key == 'dropoff_location' || field.key == 'address');

      return Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: _buildDropdown('Field', possibleFields, field.key, (value) {
                setState(() {
                  field.key = value;
                  field.controller.clear(); 
                });
              }),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 3,
              child: isWorkingTime 
                ? _buildWorkingTimePicker(field.controller)
                : (isAddress 
                    ? AddressAutocompleteField(controller: field.controller, label: 'New Value')
                    : TextFormField(
                        controller: field.controller,
                        decoration: const InputDecoration(labelText: 'New Value', border: OutlineInputBorder()),
                        validator: (value) {
                           if (field.key != null && (value == null || value.isEmpty)) {
                             return 'Value cannot be empty';
                           }
                           return null;
                        },
                      )
                  ),
            ),
            if (_editFields.length > 1)
              IconButton(
                icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                onPressed: () {
                  setState(() {
                    _editFields.removeAt(index);
                  });
                },
              ),
          ],
        ),
      );
    }).toList();
  }

  Widget _buildFetchedRecordCard(Map<String, dynamic> record) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: record.entries.map((entry) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Text(
                '${entry.key}: ${_formatValue(entry.value)}',
                style: const TextStyle(fontSize: 16),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildConfirmButton(EditProvider provider) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
        child: const Text('Confirm', style: TextStyle(fontSize: 18)),
        onPressed: () {
          if (_formKey.currentState!.validate()) {
            _showConfirmationDialog(provider);
          }
        },
      ),
    );
  }

  // confirmation before changing database
  void _showConfirmationDialog(EditProvider provider) {
    Widget content;
    Map<String, dynamic> dataPayload = {};

    switch (_selectedAction) {
      case 'add':
        _addFormControllers.forEach((key, controller) {
          if (key == 'user_id') {
            dataPayload[key] = int.tryParse(controller.text) ?? controller.text;
          } else {
            dataPayload[key] = controller.text;
          }
        });
        content = _buildConfirmationContent('Add this record?', {'New Data': dataPayload});
        break;
      case 'edit':
        for (var field in _editFields) {
          if (field.key != null && field.controller.text.isNotEmpty) {
            if (field.key == 'user_id') {
              dataPayload[field.key!] = int.tryParse(field.controller.text) ?? field.controller.text;
            } else {
              dataPayload[field.key!] = field.controller.text;
            }
          }
        }
        if (dataPayload.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No changes to submit.')));
          return;
        }
        content = _buildConfirmationContent(
          'Update this record?',
          {'Old Data': provider.fetchedRecord!, 'New Data': dataPayload},
        );
        break;
      case 'delete':
        content = _buildConfirmationContent('Delete this record?', {'Record to Delete': provider.fetchedRecord!});
        break;
      default:
        return;
    }

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Are you sure?'),
          content: SingleChildScrollView(child: content),
          actions: <Widget>[
            TextButton(child: const Text('Back'), onPressed: () => Navigator.of(context).pop()),
            ElevatedButton(
              child: const Text('Yes'),
              onPressed: () {
                Navigator.of(context).pop();
                _submitData(provider, dataPayload);
              },
            ),
          ],
        );
      },
    );
  }
  
  void _submitData(EditProvider provider, Map<String, dynamic> payload) async {
    final token = Provider.of<LoginProvider>(context, listen: false).token!;
    bool success = false;

    switch (_selectedAction) {
      case 'add':
        success = await provider.addRecord(_selectedTable!, payload, token);
        break;
      case 'edit':
        success = await provider.updateRecord(_selectedTable!, int.parse(_idController.text), payload, token);
        break;
      case 'delete':
        success = await provider.deleteRecord(_selectedTable!, int.parse(_idController.text), token);
        break;
    }
    
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(success ? 'Operation successful!' : 'Operation failed: ${provider.errorMessage}')),
    );

    if (success) {
      _resetState();
    }
  }

  Widget _buildConfirmationContent(String title, Map<String, dynamic> sections) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        ...sections.entries.map((section) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 20),
            Text(section.key, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...(section.value as Map<String, dynamic>).entries.map((entry) {
                return Text('${entry.key}: ${_formatValue(entry.value)}');
            }),
          ],
        )),
      ],
    );
  }

  // database fields
  List<String> _getFieldsForTable(String table, {bool forEdit = false}) {
    switch (table) {
      case 'customers':
        return ['name', 'email', 'phone', 'address', 'username', if (!forEdit) 'password'];
      case 'admins':
        return ['name', 'username', if (!forEdit) 'password'];
      case 'drivers':
        return [
          'name', 
          'email', 
          'phone', 
          'vehicle_details', 
          'max_weight',
          'working_time', 
          'username', 
          if (!forEdit) 'password'
        ];
      case 'orders':
        if (forEdit) {
           return ['user_id'];
        } else {
           return ['user_id'];
        }
      default:
        return [];
    }
  }

  @override
  void dispose() {
    _idController.dispose();
    _addFormControllers.forEach((_, controller) => controller.dispose());
    for (var field in _editFields) {
      field.controller.dispose();
    }
    super.dispose();
  }
}

// autocomplete field
class AddressAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final String label;

  const AddressAutocompleteField({
    super.key,
    required this.controller,
    required this.label,
  });

  @override
  State<AddressAutocompleteField> createState() => _AddressAutocompleteFieldState();
}

class _AddressAutocompleteFieldState extends State<AddressAutocompleteField> {
  Timer? _debounce;
  List<Map<String, String>> _suggestions = [];
  bool _isFetching = false;
  late String _baseUrl;

  @override
  void initState() {
    super.initState();
    try {
       if (dotenv.isInitialized) {
         _baseUrl = dotenv.env['BASE_URL'] ?? 'http://localhost:8080';
       } 
    } catch (e) {
      //ignore
    }
  }

  Future<void> _fetchSuggestions(String input) async {
    if (input.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    
    // get token
    final token = Provider.of<LoginProvider>(context, listen: false).token;
    if (token == null) return;

    setState(() => _isFetching = true);

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/places/find'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'input': input}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['predictions'] != null) {
          final list = (data['predictions'] as List).map((p) => {
            'description': p['description'].toString(),
            'place_id': p['place_id'].toString()
          }).toList();
          if (mounted) setState(() => _suggestions = list);
        }
      }
    } catch (e) {
      // ignore
    } finally {
      if (mounted) setState(() => _isFetching = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: widget.controller,
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
            suffixIcon: _isFetching ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)) : null,
          ),
          validator: (value) => (value == null || value.isEmpty) ? 'Please enter a location' : null,
          onChanged: (value) {
            if (_debounce?.isActive ?? false) _debounce!.cancel();
            _debounce = Timer(const Duration(milliseconds: 500), () => _fetchSuggestions(value));
          },
        ),
        if (_suggestions.isNotEmpty)
          Container(
            height: 150,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              color: Colors.white,
            ),
            child: ListView.builder(
              itemCount: _suggestions.length,
              itemBuilder: (context, index) {
                final item = _suggestions[index];
                return ListTile(
                  dense: true,
                  title: Text(item['description']!),
                  onTap: () {
                    widget.controller.text = item['description']!;
                    setState(() => _suggestions = []);
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}
