import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class CheckpointsScreen extends StatefulWidget {
  final String tripId;
  final Map<String, dynamic> trip;

  const CheckpointsScreen({
    super.key,
    required this.tripId,
    required this.trip,
  });

  @override
  State<CheckpointsScreen> createState() => _CheckpointsScreenState();
}

class _CheckpointsScreenState extends State<CheckpointsScreen> {
  final _checkpointController = TextEditingController();
  final _phoneController = TextEditingController();

  DateTime? _scheduledTime;
  bool _contactConsented = false;
  bool _saving = false;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String get _ownerId => FirebaseAuth.instance.currentUser!.uid;

  CollectionReference<Map<String, dynamic>> get _checkIns =>
      _db.collection('checkIns');

  CollectionReference<Map<String, dynamic>> get _contacts =>
      _db.collection('trustedContacts');

  @override
  void dispose() {
    _checkpointController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _chooseTime() async {
    final now = DateTime.now();

    final date = await showDatePicker(
      context: context,
      initialDate: _scheduledTime ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );

    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_scheduledTime ?? now),
    );

    if (time == null || !mounted) return;

    setState(() {
      _scheduledTime = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _addCheckpoint() async {
    final label = _checkpointController.text.trim();

    if (label.isEmpty) {
      _showMessage('Enter a checkpoint name.');
      return;
    }

    if (_scheduledTime == null) {
      _showMessage('Choose the expected arrival time.');
      return;
    }

    if (_scheduledTime!.isBefore(DateTime.now())) {
      _showMessage('Choose a future time for this checkpoint.');
      return;
    }

    setState(() => _saving = true);

    try {
      await _checkIns.add({
        'ownerId': _ownerId,
        'tripId': widget.tripId,
        'label': label,
        'scheduledTime': Timestamp.fromDate(_scheduledTime!),
        'status': 'pending',
        'escalationStatus': 'pending',
        'checkpoint': true,
        'createdAt': FieldValue.serverTimestamp(),
      });

      _checkpointController.clear();

      if (!mounted) return;

      setState(() => _scheduledTime = null);
      _showMessage('Checkpoint added successfully.');
    } catch (e) {
      _showMessage('Could not add checkpoint: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveTrustedContact() async {
    final phone = _phoneController.text.trim();

    if (phone.isEmpty) {
      _showMessage('Enter the trusted contact phone number.');
      return;
    }

    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone)) {
      _showMessage('Use international format, for example +919876543210.');
      return;
    }

    if (!_contactConsented) {
      _showMessage(
        'Confirm that the trusted person has agreed to receive SMS alerts.',
      );
      return;
    }

    setState(() => _saving = true);

    try {
      // Keep the existing trustedContacts collection and fields.
      // Reuse a contact document for this trip if one already exists.
      final existing = await _contacts
          .where('ownerId', isEqualTo: _ownerId)
          .where('tripId', isEqualTo: widget.tripId)
          .limit(1)
          .get();

      final data = <String, dynamic>{
        'ownerId': _ownerId,
        'tripId': widget.tripId,
        'phone': phone,
        'consentStatus': 'approved',
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (existing.docs.isEmpty) {
        await _contacts.add({
          ...data,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        await existing.docs.first.reference.set(data, SetOptions(merge: true));
      }

      if (!mounted) return;

      _phoneController.clear();
      setState(() => _contactConsented = false);
      _showMessage('Trusted contact saved.');
    } catch (e) {
      _showMessage('Could not save trusted contact: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _checkIn(
    DocumentReference<Map<String, dynamic>> reference,
  ) async {
    try {
      await _db.runTransaction((transaction) async {
        final snapshot = await transaction.get(reference);

        if (!snapshot.exists) {
          throw Exception('Checkpoint no longer exists.');
        }

        final data = snapshot.data()!;

        if (data['ownerId'] != _ownerId || data['tripId'] != widget.tripId) {
          throw Exception('You cannot check in to this checkpoint.');
        }

        if (data['status'] != 'pending') {
          throw Exception('This checkpoint is already completed.');
        }

        transaction.update(reference, {
          'status': 'completed',
          'actualTime': FieldValue.serverTimestamp(),
          'escalationStatus': 'resolved',
        });

        transaction.update(_db.collection('trips').doc(widget.tripId), {
          'lastCheckInAt': FieldValue.serverTimestamp(),
        });
      });

      if (mounted) {
        _showMessage('Check-in completed. You are marked as safe.');
      }
    } catch (e) {
      _showMessage('Check-in failed: $e');
    }
  }

  Future<void> _deleteCheckpoint(
    DocumentReference<Map<String, dynamic>> reference,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete checkpoint?'),
        content: const Text('This removes the checkpoint from the trip.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final snapshot = await reference.get();

      if (!snapshot.exists ||
          snapshot.data()?['ownerId'] != _ownerId ||
          snapshot.data()?['tripId'] != widget.tripId) {
        throw Exception('Checkpoint not found.');
      }

      if (snapshot.data()?['status'] == 'completed') {
        throw Exception('Completed checkpoints cannot be deleted.');
      }

      await reference.delete();

      if (mounted) _showMessage('Checkpoint deleted.');
    } catch (e) {
      _showMessage('Could not delete checkpoint: $e');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDate(dynamic value) {
    if (value is! Timestamp) return 'Time unavailable';

    final date = value.toDate().toLocal();

    String twoDigits(int number) => number.toString().padLeft(2, '0');

    return '${twoDigits(date.day)}/${twoDigits(date.month)}/${date.year} '
        '${twoDigits(date.hour)}:${twoDigits(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final destination = widget.trip['destination']?.toString() ?? 'Destination';

    return Scaffold(
      appBar: AppBar(title: const Text('Trip Checkpoints')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _checkIns
            .where('ownerId', isEqualTo: _ownerId)
            .where('tripId', isEqualTo: widget.tripId)
            .orderBy('scheduledTime')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load checkpoints.\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final documents = snapshot.data?.docs ?? [];

          final checkpoints = documents.where((document) {
            final data = document.data();
            return data['checkpoint'] == true;
          }).toList();

          final completed = checkpoints
              .where((document) => document.data()['status'] == 'completed')
              .length;

          final progress = checkpoints.isEmpty
              ? 0.0
              : completed / checkpoints.length;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Destination: $destination',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 8),
                      Text(
                        '$completed of ${checkpoints.length} checkpoints completed',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Add a checkpoint',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _checkpointController,
                decoration: const InputDecoration(
                  labelText: 'Checkpoint name',
                  hintText: 'e.g. Juice shop, bus stop',
                  prefixIcon: Icon(Icons.place_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _chooseTime,
                icon: const Icon(Icons.schedule),
                label: Text(
                  _scheduledTime == null
                      ? 'Choose expected arrival time'
                      : 'Expected: ${_scheduledTime!.day}/${_scheduledTime!.month} '
                            '${_scheduledTime!.hour.toString().padLeft(2, '0')}:'
                            '${_scheduledTime!.minute.toString().padLeft(2, '0')}',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _saving ? null : _addCheckpoint,
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Add checkpoint'),
              ),
              const SizedBox(height: 24),
              Text(
                'Trusted contact',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Mobile number with country code',
                  hintText: '+919876543210',
                  prefixIcon: Icon(Icons.phone),
                  border: OutlineInputBorder(),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _contactConsented,
                onChanged: (value) {
                  setState(() => _contactConsented = value ?? false);
                },
                title: const Text(
                  'The trusted person agrees to receive SMS alerts.',
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              FilledButton.tonal(
                onPressed: _saving ? null : _saveTrustedContact,
                child: const Text('Save trusted contact'),
              ),
              const SizedBox(height: 24),
              Text(
                'Your checkpoints',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              if (checkpoints.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                      'No checkpoints yet. Add the places you will pass on your journey.',
                    ),
                  ),
                ),
              ...checkpoints.map((document) {
                final data = document.data();
                final isCompleted = data['status'] == 'completed';

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isCompleted
                          ? Colors.green.withValues(alpha: 0.12)
                          : null,
                      child: Icon(
                        isCompleted ? Icons.check_circle : Icons.location_on,
                        color: isCompleted ? Colors.green : null,
                      ),
                    ),
                    title: Text(data['label']?.toString() ?? 'Checkpoint'),
                    subtitle: Text(
                      '${_formatDate(data['scheduledTime'])}\n'
                      'Status: ${isCompleted ? 'Completed' : 'Pending'}',
                    ),
                    isThreeLine: true,
                    trailing: isCompleted
                        ? const Icon(Icons.verified, color: Colors.green)
                        : PopupMenuButton<String>(
                            onSelected: (action) {
                              if (action == 'checkin') {
                                _checkIn(document.reference);
                              } else if (action == 'delete') {
                                _deleteCheckpoint(document.reference);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'checkin',
                                child: Text('Check in — I am safe'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete checkpoint'),
                              ),
                            ],
                          ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}
