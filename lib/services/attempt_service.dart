import 'package:cloud_firestore/cloud_firestore.dart';

class AttemptService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String createRoundId(String uid) {
    return _db.collection('users').doc(uid).collection('attempts').doc().id;
  }

  DocumentReference<Map<String, dynamic>> _attemptRef(
    String uid,
    String roundId,
  ) {
    return _db.collection('users').doc(uid).collection('attempts').doc(roundId);
  }

  Future<void> submitAttempt({
    required String uid,
    required String roundId,
    required int correctCount,
  }) async {
    if (correctCount < 0 || correctCount > 10) {
      throw ArgumentError('Score must be between 0 and 10.');
    }

    final ref = _attemptRef(uid, roundId);

    final expected = <String, dynamic>{
      'schemaVersion': 1,
      'variant': 'A',
      'categoryId': 9,
      'questionCount': 10,
      'correctCount': correctCount,
    };

    await _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);

      if (snapshot.exists) {
        final existing = snapshot.data();

        if (existing == null ||
            existing.length != 6 ||
            expected.entries.any(
              (entry) => existing[entry.key] != entry.value,
            ) ||
            existing['submittedAt'] is! Timestamp) {
          throw StateError('Attempt ID collision.');
        }
        return;
      }

      transaction.set(ref, {
        ...expected,
        'submittedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<bool> verifyAttempt({
    required String uid,
    required String roundId,
    required int correctCount,
  }) async {
    final ref = _attemptRef(uid, roundId);

    final snapshot = await ref.get(const GetOptions(source: Source.server));

    if (!snapshot.exists || snapshot.metadata.hasPendingWrites) {
      return false;
    }

    final data = snapshot.data();

    return data != null &&
        data.length == 6 &&
        data['schemaVersion'] == 1 &&
        data['variant'] == 'A' &&
        data['categoryId'] == 9 &&
        data['questionCount'] == 10 &&
        data['correctCount'] == correctCount &&
        data['submittedAt'] is Timestamp;
  }
}
