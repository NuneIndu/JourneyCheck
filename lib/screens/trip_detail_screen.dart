import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'checkpoints_screen.dart';

class TripDetailScreen extends StatelessWidget {
  final String tripId;
  final Map<String, dynamic> trip;

  const TripDetailScreen({super.key, required this.tripId, required this.trip});

  String _format(dynamic value) {
    if (value is! Timestamp) return 'Not available';
    return value.toDate().toLocal().toString().substring(0, 16);
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _checkIn(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      _showMessage(context, 'Please sign in again.');
      return;
    }

    try {
      final db = FirebaseFirestore.instance;
      final checkRef = db.collection('checkIns').doc(doc.id);
      final tripRef = db.collection('trips').doc(tripId);

      await db.runTransaction((transaction) async {
        final checkSnapshot = await transaction.get(checkRef);
        final tripSnapshot = await transaction.get(tripRef);

        if (!checkSnapshot.exists || !tripSnapshot.exists) {
          throw Exception('Trip or check-in no longer exists.');
        }

        final checkData = checkSnapshot.data()!;
        final tripData = tripSnapshot.data()!;

        if (checkData['ownerId'] != user.uid ||
            checkData['tripId'] != tripId ||
            tripData['ownerId'] != user.uid) {
          throw Exception('Access denied.');
        }

        if (tripData['status'] == 'completed') {
          throw Exception('This trip is already completed.');
        }

        if (checkData['status'] == 'completed') return;

        transaction.update(checkRef, {
          'status': 'completed',
          'actualTime': FieldValue.serverTimestamp(),
          'escalationStatus': 'resolved',

          // The Python worker uses this to send the arrival message.
          'arrivalNotificationStatus': 'pending',
        });

        transaction.update(tripRef, {
          'lastCheckInAt': FieldValue.serverTimestamp(),
        });
      });

      if (context.mounted) {
        _showMessage(context, "I'm OK recorded successfully!");
      }
    } catch (e) {
      debugPrint('Check-in error: $e');

      if (context.mounted) {
        _showMessage(context, 'Check-in failed: $e');
      }
    }
  }

  Future<void> _completeTrip(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      _showMessage(context, 'Please sign in again.');
      return;
    }

    try {
      final tripRef = FirebaseFirestore.instance
          .collection('trips')
          .doc(tripId);

      final snapshot = await tripRef.get();

      if (!snapshot.exists || snapshot.data()?['ownerId'] != user.uid) {
        throw Exception('Trip not found or access denied.');
      }

      await tripRef.update({
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
      });

      if (context.mounted) {
        _showMessage(context, 'Trip marked as completed.');
      }
    } catch (e) {
      if (context.mounted) {
        _showMessage(context, 'Could not complete trip: $e');
      }
    }
  }

  Future<void> _deleteTrip(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete completed trip?'),
        content: const Text(
          'This permanently deletes the trip, its checkpoints '
          'and trusted-contact records.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      _showMessage(context, 'Please sign in again.');
      return;
    }

    try {
      final db = FirebaseFirestore.instance;
      final tripRef = db.collection('trips').doc(tripId);
      final tripSnapshot = await tripRef.get();

      if (!tripSnapshot.exists || tripSnapshot.data()?['ownerId'] != user.uid) {
        throw Exception('Trip not found or access denied.');
      }

      if (tripSnapshot.data()?['status'] != 'completed') {
        throw Exception('Only completed trips can be deleted.');
      }

      final checkIns = await db
          .collection('checkIns')
          .where('ownerId', isEqualTo: user.uid)
          .where('tripId', isEqualTo: tripId)
          .get();

      final contacts = await db
          .collection('trustedContacts')
          .where('ownerId', isEqualTo: user.uid)
          .where('tripId', isEqualTo: tripId)
          .get();

      final refs = <DocumentReference<Map<String, dynamic>>>[
        ...checkIns.docs.map((d) => d.reference),
        ...contacts.docs.map((d) => d.reference),
        tripRef,
      ];

      for (var i = 0; i < refs.length; i += 450) {
        final batch = db.batch();
        final end = (i + 450 < refs.length) ? i + 450 : refs.length;

        for (final ref in refs.sublist(i, end)) {
          batch.delete(ref);
        }

        await batch.commit();
      }

      if (context.mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('Delete trip error: $e');

      if (context.mounted) {
        _showMessage(context, 'Could not delete trip: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Trip details')),
        body: const Center(child: Text('Please sign in to view your trip.')),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .doc(tripId)
          .snapshots(),
      builder: (context, tripSnapshot) {
        if (tripSnapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Trip details')),
            body: const Center(child: Text('Could not load trip details.')),
          );
        }

        final currentTrip = tripSnapshot.data?.data() ?? trip;
        final completed = currentTrip['status'] == 'completed';

        final checkIns = FirebaseFirestore.instance
            .collection('checkIns')
            .where('ownerId', isEqualTo: user.uid)
            .where('tripId', isEqualTo: tripId)
            .orderBy('scheduledTime');

        return Scaffold(
          appBar: AppBar(title: const Text('Trip details')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (currentTrip['destination'] ?? 'Trip').toString(),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Starting location: '
                        '${currentTrip['startLocation'] ?? 'Not available'}',
                      ),
                      Text(
                        'Expected arrival: '
                        '${_format(currentTrip['expectedArrival'])}',
                      ),
                      Text('Trip status: ${currentTrip['status'] ?? 'active'}'),
                      Text(
                        'Grace period: '
                        '${currentTrip['gracePeriodMinutes'] ?? 1} minutes',
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              FilledButton.icon(
                onPressed: completed
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CheckpointsScreen(
                              tripId: tripId,
                              trip: currentTrip,
                            ),
                          ),
                        );
                      },
                icon: const Icon(Icons.location_on),
                label: const Text('Manage Checkpoints'),
              ),

              const SizedBox(height: 20),

              Text('Check-ins', style: Theme.of(context).textTheme.titleMedium),

              const SizedBox(height: 8),

              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: checkIns.snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Text('Could not load check-ins: ${snapshot.error}');
                  }

                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final docs = snapshot.data?.docs ?? [];

                  if (docs.isEmpty) {
                    return const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No check-ins found for this trip.'),
                      ),
                    );
                  }

                  return Column(
                    children: docs.map((doc) {
                      final data = doc.data();
                      final checkedIn = data['status'] == 'completed';

                      return Card(
                        child: ListTile(
                          leading: Icon(
                            checkedIn ? Icons.check_circle : Icons.schedule,
                            color: checkedIn ? Colors.green : Colors.orange,
                          ),
                          title: Text((data['label'] ?? 'Check-in').toString()),
                          subtitle: Text(
                            'Scheduled: ${_format(data['scheduledTime'])}\n'
                            'Status: ${data['status'] ?? 'pending'}',
                          ),
                          isThreeLine: true,
                          trailing: checkedIn
                              ? const Icon(Icons.verified, color: Colors.green)
                              : FilledButton(
                                  onPressed: completed
                                      ? null
                                      : () => _checkIn(context, doc),
                                  child: const Text("I'm OK"),
                                ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),

              const SizedBox(height: 16),

              if (!completed)
                OutlinedButton.icon(
                  onPressed: () => _completeTrip(context),
                  icon: const Icon(Icons.flag),
                  label: const Text('Mark trip completed'),
                ),

              if (completed)
                FilledButton.icon(
                  onPressed: () => _deleteTrip(context),
                  icon: const Icon(Icons.delete),
                  label: const Text('Delete completed trip'),
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                ),
            ],
          ),
        );
      },
    );
  }
}
