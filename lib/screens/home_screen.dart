import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'create_trip_screen.dart';
import 'trip_detail_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please log in to view your trips.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('JourneyCheck'),
        actions: [
          IconButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CreateTripScreen()),
          );
        },
        icon: const Icon(Icons.add_location_alt),
        label: const Text('New trip'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('trips')
            .where('ownerId', isEqualTo: user.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Could not load trips. Check your internet connection, '
                  'Firestore database, and security rules.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final trips = snapshot.data?.docs ?? [];

          if (trips.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.directions_walk,
                      size: 72,
                      color: Color(0xFF176B87),
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Welcome to JourneyCheck!',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Create your first trip to start using safety check-ins.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: trips.length,
            itemBuilder: (context, index) {
              final trip = trips[index];
              final data = trip.data();

              final destination = (data['destination'] ?? 'Untitled trip')
                  .toString();
              final startLocation = (data['startLocation'] ?? 'Not specified')
                  .toString();
              final completed = data['status'] == 'completed';

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    child: Icon(completed ? Icons.check_circle : Icons.route),
                  ),
                  title: Text(destination),
                  subtitle: Text('From: $startLocation'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TripDetailScreen(
                          trip: trip.data(),
                          tripId: trip.id,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
