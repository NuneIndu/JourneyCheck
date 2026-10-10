import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class CreateTripScreen extends StatefulWidget {
  const CreateTripScreen({super.key});

  @override
  State<CreateTripScreen> createState() => _CreateTripScreenState();
}

class _CreateTripScreenState extends State<CreateTripScreen> {
  final _formKey = GlobalKey<FormState>();
  final _startController = TextEditingController();
  final _destinationController = TextEditingController();
  final _phoneController = TextEditingController();

  final List<TextEditingController> _checkpointControllers = [];
  final List<DateTime?> _checkpointTimes = [];

  DateTime _arrivalTime = DateTime.now().add(const Duration(hours: 2));
  bool _saving = false;
  bool _consent = false;

  @override
  void dispose() {
    _startController.dispose();
    _destinationController.dispose();
    _phoneController.dispose();

    for (final controller in _checkpointControllers) {
      controller.dispose();
    }

    super.dispose();
  }

  void _addCheckpoint() {
    setState(() {
      _checkpointControllers.add(TextEditingController());
      _checkpointTimes.add(null);
    });
  }

  void _removeCheckpoint(int index) {
    setState(() {
      _checkpointControllers[index].dispose();
      _checkpointControllers.removeAt(index);
      _checkpointTimes.removeAt(index);
    });
  }

  Future<DateTime?> _chooseDateTime(DateTime initial) async {
    final now = DateTime.now();

    final date = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );

    if (date == null || !mounted) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );

    if (time == null || !mounted) return null;

    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _selectArrivalTime() async {
    final selected = await _chooseDateTime(_arrivalTime);
    if (selected == null) return;

    setState(() => _arrivalTime = selected);
  }

  Future<void> _selectCheckpointTime(int index) async {
    final initial =
        _checkpointTimes[index] ??
        DateTime.now().add(const Duration(minutes: 30));

    final selected = await _chooseDateTime(initial);
    if (selected == null) return;

    setState(() => _checkpointTimes[index] = selected);
  }

  String _formatTime(DateTime date) {
    return '${date.day}/${date.month}/${date.year} '
        '${TimeOfDay.fromDateTime(date).format(context)}';
  }

  Future<void> _createTrip() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_arrivalTime.isAfter(DateTime.now())) {
      _showMessage('Choose a future destination arrival time.');
      return;
    }

    for (int i = 0; i < _checkpointControllers.length; i++) {
      final name = _checkpointControllers[i].text.trim();
      final time = _checkpointTimes[i];

      if (name.isEmpty || time == null) {
        _showMessage('Enter a name and arrival time for every checkpoint.');
        return;
      }

      if (!time.isAfter(DateTime.now()) || !time.isBefore(_arrivalTime)) {
        _showMessage(
          'Checkpoint times must be in the future and before destination arrival.',
        );
        return;
      }

      if (i > 0 && !time.isAfter(_checkpointTimes[i - 1]!)) {
        _showMessage('Checkpoint times must be in chronological order.');
        return;
      }
    }

    final phone = _phoneController.text.trim();

    if (phone.isNotEmpty && !_consent) {
      _showMessage('Please confirm the trusted contact agrees to SMS alerts.');
      return;
    }

    setState(() => _saving = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Please sign in before creating a trip.');
      }

      final db = FirebaseFirestore.instance;
      final tripRef = db.collection('trips').doc();

      final batch = db.batch();

      batch.set(tripRef, {
        'ownerId': user.uid,
        'startLocation': _startController.text.trim(),
        'destination': _destinationController.text.trim(),
        'expectedArrival': Timestamp.fromDate(_arrivalTime),
        'gracePeriodMinutes': 1,
        'status': 'active',
        'createdAt': FieldValue.serverTimestamp(),
      });

      for (int i = 0; i < _checkpointControllers.length; i++) {
        final checkInRef = db.collection('checkIns').doc();

        batch.set(checkInRef, {
          'ownerId': user.uid,
          'tripId': tripRef.id,
          'label': _checkpointControllers[i].text.trim(),
          'scheduledTime': Timestamp.fromDate(_checkpointTimes[i]!),
          'status': 'pending',
          'escalationStatus': 'pending',
          'checkpoint': true,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      // Destination arrival check-in.
      final arrivalRef = db.collection('checkIns').doc();

      batch.set(arrivalRef, {
        'ownerId': user.uid,
        'tripId': tripRef.id,
        'label': 'Destination arrival',
        'scheduledTime': Timestamp.fromDate(_arrivalTime),
        'status': 'pending',
        'escalationStatus': 'pending',
        'checkpoint': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Save the trusted phone number with the trip.
      if (phone.isNotEmpty) {
        final contactRef = db.collection('trustedContacts').doc();

        batch.set(contactRef, {
          'ownerId': user.uid,
          'tripId': tripRef.id,
          'phone': phone,
          'consentStatus': 'approved',
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      if (!mounted) return;

      Navigator.pop(context, true);
    } catch (e, stackTrace) {
      debugPrint('Create trip error: $e');
      debugPrintStack(stackTrace: stackTrace);

      if (mounted) {
        _showMessage('Failed to create trip: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create a trip')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _startController,
              decoration: const InputDecoration(
                labelText: 'Starting location',
                prefixIcon: Icon(Icons.trip_origin),
              ),
              validator: (v) => v == null || v.trim().isEmpty
                  ? 'Enter starting location'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _destinationController,
              decoration: const InputDecoration(
                labelText: 'Destination',
                prefixIcon: Icon(Icons.place_outlined),
              ),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Enter destination' : null,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _saving ? null : _selectArrivalTime,
              icon: const Icon(Icons.schedule),
              label: Text('Destination arrival: ${_formatTime(_arrivalTime)}'),
            ),
            const SizedBox(height: 24),
            Text(
              'Intermediate checkpoints',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...List.generate(_checkpointControllers.length, (index) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _checkpointControllers[index],
                        decoration: InputDecoration(
                          labelText: 'Checkpoint ${index + 1}',
                          hintText: 'e.g. Juice shop, Bus stop',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _selectCheckpointTime(index),
                        icon: const Icon(Icons.schedule),
                        label: Text(
                          _checkpointTimes[index] == null
                              ? 'Choose expected arrival time'
                              : _formatTime(_checkpointTimes[index]!),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _removeCheckpoint(index),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remove checkpoint'),
                      ),
                    ],
                  ),
                ),
              );
            }),
            OutlinedButton.icon(
              onPressed: _saving ? null : _addCheckpoint,
              icon: const Icon(Icons.add_location_alt),
              label: const Text('Add checkpoint'),
            ),
            const SizedBox(height: 24),
            Text(
              'Trusted contact (optional)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile number with country code',
                hintText: '+919876543210',
                prefixIcon: Icon(Icons.phone),
              ),
              validator: (value) {
                final phone = value?.trim() ?? '';
                if (phone.isNotEmpty &&
                    !RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone)) {
                  return 'Use international format, e.g. +919876543210';
                }
                return null;
              },
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _consent,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _consent = value ?? false),
              title: const Text(
                'The trusted person agrees to receive SMS alerts.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : _createTrip,
              icon: const Icon(Icons.save),
              label: Text(_saving ? 'Saving...' : 'Create trip'),
            ),
          ],
        ),
      ),
    );
  }
}
