import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'services/attempt_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const TriviaShowdownApp());
}

class TriviaShowdownApp extends StatelessWidget {
  const TriviaShowdownApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cloud Trivia Showdown',
      theme: ThemeData(primarySwatch: Colors.deepOrange),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasError) {
            return const Scaffold(
              body: Center(child: Text('Authentication unavailable.')),
            );
          }

          return snapshot.hasData
              ? const TriviaShowdownScreen()
              : const LoginScreen();
        },
      ),
    );
  }
}

class Question {
  final String questionText;
  final String correctAnswer;
  final List<String> options;

  Question({
    required this.questionText,
    required this.correctAnswer,
    required this.options,
  });

  factory Question.fromJson(Map<String, dynamic> json) {
    final unescape = HtmlUnescape();

    if (json['category'] != 'General Knowledge' ||
        json['difficulty'] != 'easy' ||
        json['type'] != 'multiple') {
      throw const FormatException('Invalid question metadata.');
    }

    if (json['question'] is! String || json['correct_answer'] is! String) {
      throw const FormatException('Missing question or correct answer.');
    }

    final questionText = unescape.convert(json['question'] as String).trim();
    final correct = unescape.convert(json['correct_answer'] as String).trim();

    if (questionText.isEmpty || correct.isEmpty) {
      throw const FormatException('Question or correct answer is blank.');
    }

    final rawIncorrect = json['incorrect_answers'];

    if (rawIncorrect is! List || rawIncorrect.length != 3) {
      throw const FormatException('Expected three incorrect answers.');
    }

    final incorrect = <String>[];

    for (final answer in rawIncorrect) {
      if (answer is! String) {
        throw const FormatException('Invalid answer type.');
      }

      final cleaned = unescape.convert(answer).trim();

      if (cleaned.isEmpty) {
        throw const FormatException('Blank answer.');
      }

      incorrect.add(cleaned);
    }

    final allOptions = [...incorrect, correct];

    if (allOptions.toSet().length != 4) {
      throw const FormatException('Duplicate answer choices.');
    }

    allOptions.shuffle();

    return Question(
      questionText: questionText,
      correctAnswer: correct,
      options: allOptions,
    );
  }
}

class TriviaShowdownScreen extends StatefulWidget {
  const TriviaShowdownScreen({super.key});
  @override
  State<TriviaShowdownScreen> createState() => _TriviaShowdownScreenState();
}

class _TriviaShowdownScreenState extends State<TriviaShowdownScreen> {
  List<Question> _questions = [];
  bool _isLoading = true;
  String _error = '';
  int _currentIndex = 0;
  int _score = 0;
  bool _answered = false;
  String? _selectedOption;
  bool _isSynced = false;
  bool _isSyncing = false;
  int _roundId = 0;
  final List<String> _userAnswers = [];
  final AttemptService _attemptService = AttemptService();
  String? _firestoreRoundId;
  String? _roundOwnerUid;
  bool _isVerifying = false;
  String _cloudMessage = '';
  bool _saveUnknown = false;
  bool _verificationUnavailable = false;
  bool _injectLostAck = false;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _roundOwnerUid = user.uid;
      _firestoreRoundId = _attemptService.createRoundId(user.uid);
    }
    _loadTriviaData();
  }

  Future<void> _loadTriviaData() async {
    final roundId = _roundId;
    try {
      final uri = Uri.parse(
        'https://opentdb.com/api.php?amount=10&category=9&difficulty=easy&type=multiple',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data is! Map<String, dynamic> ||
            data['response_code'] != 0 ||
            data['results'] is! List ||
            (data['results'] as List).length != 10) {
          throw const FormatException('Invalid trivia API response.');
        }

        final results = data['results'] as List;

        if (!mounted || roundId != _roundId) return;

        final questions = results.map((q) {
          if (q is! Map<String, dynamic>) {
            throw const FormatException('Invalid question object.');
          }
          return Question.fromJson(q);
        }).toList();

        if (!mounted || roundId != _roundId) return;

        setState(() {
          _questions = questions;
          _isLoading = false;
        });
      } else {
        if (!mounted || roundId != _roundId) return;
        setState(() {
          _error = 'Server error: ${response.statusCode}';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted || roundId != _roundId) return;
      setState(() {
        _error = 'Connection failed: $e';
        _isLoading = false;
      });
    }
  }

  void _answerQuestion(String option) {
    if (_answered) return;

    setState(() {
      _answered = true;
      _selectedOption = option;

      _userAnswers.add(option);

      if (option == _questions[_currentIndex].correctAnswer) {
        _score++;
      }
    });
  }

  void _nextQuestion() {
    setState(() {
      if (_currentIndex < _questions.length - 1) {
        _currentIndex++;
        _answered = false;
        _selectedOption = null;
      } else {
        _currentIndex++;
      }
    });
  }

  Future<void> _syncScoreToCloud() async {
    if (_isSyncing || _isVerifying || _isSynced) return;

    final user = FirebaseAuth.instance.currentUser;
    final uid = _roundOwnerUid;
    final firestoreRoundId = _firestoreRoundId;
    final localRoundId = _roundId;
    final score = _score;

    if (user == null ||
        uid == null ||
        user.uid != uid ||
        firestoreRoundId == null) {
      setState(() {
        _cloudMessage = 'Authentication changed. Cannot submit this round.';
      });
      return;
    }

    bool stillCurrent() =>
        mounted &&
        localRoundId == _roundId &&
        FirebaseAuth.instance.currentUser?.uid == uid;

    setState(() {
      _isSyncing = true;
      _isVerifying = false;
      _cloudMessage = 'Checking cloud submission...';
    });

    try {
      if (_saveUnknown || _verificationUnavailable) {
        final ref = FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('attempts')
            .doc(firestoreRoundId);

        final snapshot = await ref.get(const GetOptions(source: Source.server));

        if (!stillCurrent()) return;

        if (snapshot.metadata.isFromCache ||
            snapshot.metadata.hasPendingWrites) {
          throw StateError('Server verification unavailable.');
        }

        if (snapshot.exists) {
          final verified = await _attemptService.verifyAttempt(
            uid: uid,
            roundId: firestoreRoundId,
            correctCount: score,
          );

          if (!stillCurrent()) return;

          setState(() {
            _isSyncing = false;
            _isSynced = verified;
            _saveUnknown = !verified;
            _verificationUnavailable = !verified;
            _cloudMessage = verified
                ? 'Cloud verified!'
                : 'Existing attempt does not match. Submission blocked.';
          });
          return;
        }

        setState(() {
          _saveUnknown = false;
          _verificationUnavailable = false;
          _cloudMessage = 'Attempt not found. Retrying original submission...';
        });
      }

      await _attemptService.submitAttempt(
        uid: uid,
        roundId: firestoreRoundId,
        correctCount: _score,
      );

      if (_injectLostAck) {
        _injectLostAck = false;

        if (!mounted || localRoundId != _roundId) return;

        setState(() {
          _isSyncing = false;
          _saveUnknown = true;
          _cloudMessage =
              'TEST: Save status unknown (acknowledgment deliberately hidden).';
        });
        return;
      }

      if (!stillCurrent()) return;

      setState(() {
        _isSyncing = false;
        _isVerifying = true;
        _cloudMessage = 'Verifying saved attempt on the server...';
      });

      final verified = await _attemptService.verifyAttempt(
        uid: uid,
        roundId: firestoreRoundId,
        correctCount: score,
      );

      if (!stillCurrent()) return;

      setState(() {
        _isVerifying = false;
        _isSynced = verified;
        _verificationUnavailable = !verified;
        _cloudMessage = verified
            ? 'Cloud verified!'
            : 'Server record did not match. Submission remains unresolved.';
      });
    } on FirebaseException catch (e) {
      if (!stillCurrent()) return;

      setState(() {
        _isSyncing = false;
        _isVerifying = false;

        if (e.code == 'permission-denied') {
          _cloudMessage = 'Permission denied.';
        } else if (e.code == 'unauthenticated') {
          _cloudMessage = 'Authentication required.';
        } else if (e.code == 'resource-exhausted') {
          _saveUnknown = true;
          _cloudMessage = 'Firestore resource limit reached. Retry later.';
        } else if (e.code == 'unavailable') {
          _saveUnknown = true;
          _cloudMessage = 'Firestore unavailable. Reconnect and retry.';
        } else {
          _saveUnknown = true;
          _cloudMessage = 'Save status unknown. Retry to check the server.';
        }
      });
    } on StateError catch (e) {
      if (!stillCurrent()) return;

      setState(() {
        _isSyncing = false;
        _isVerifying = false;
        _cloudMessage = 'Attempt collision: $e';
      });
    } catch (e) {
      if (!stillCurrent()) return;

      setState(() {
        _isSyncing = false;
        _isVerifying = false;
        _saveUnknown = true;
        _cloudMessage = 'Save status unresolved: $e';
      });
    }
  }

  void _restart() {
    if (_isSyncing ||
        _isVerifying ||
        _saveUnknown ||
        _verificationUnavailable ||
        !_isSynced) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid != _roundOwnerUid) return;

    _roundId++;

    setState(() {
      _roundOwnerUid = user.uid;
      _firestoreRoundId = _attemptService.createRoundId(user.uid);

      _isLoading = true;
      _error = '';
      _questions = [];
      _currentIndex = 0;
      _score = 0;
      _answered = false;
      _selectedOption = null;

      _isSynced = false;
      _isSyncing = false;
      _isVerifying = false;
      _saveUnknown = false;
      _verificationUnavailable = false;
      _cloudMessage = '';

      _userAnswers.clear();
    });

    _loadTriviaData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloud Trivia Showdown'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign Out',
            onPressed:
                (_isSyncing ||
                    _isVerifying ||
                    _saveUnknown ||
                    _verificationUnavailable)
                ? null
                : () async {
                    await FirebaseAuth.instance.signOut();
                  },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error.isNotEmpty
            ? Center(
                child: Text(
                  _error,
                  style: const TextStyle(color: Colors.red, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              )
            : _currentIndex >= _questions.length
            ? Column(
                children: [
                  const Text(
                    'Showdown Complete!',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Final Score: $_score / ${_questions.length}',
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 24),

                  const Text(
                    'Answer Review',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),

                  Expanded(
                    child: ListView.builder(
                      itemCount: _questions.length,
                      itemBuilder: (context, index) {
                        final question = _questions[index];
                        final selected = _userAnswers[index];
                        final isCorrect = selected == question.correctAnswer;

                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${index + 1}. ${question.questionText}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Your answer: $selected',
                                  style: TextStyle(
                                    color: isCorrect
                                        ? Colors.green.shade700
                                        : Colors.red.shade700,
                                  ),
                                ),
                                if (!isCorrect)
                                  Text(
                                    'Correct answer: ${question.correctAnswer}',
                                    style: TextStyle(
                                      color: Colors.green.shade700,
                                    ),
                                  ),
                                const SizedBox(height: 4),
                                Text(isCorrect ? 'Correct ✓' : 'Incorrect ✗'),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (!_isSynced)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepOrange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                      onPressed: (_isSyncing || _isVerifying)
                          ? null
                          : _syncScoreToCloud,
                      icon: const Icon(Icons.cloud_upload),
                      label: Text(
                        _isSyncing
                            ? 'Submitting...'
                            : _isVerifying
                            ? 'Verifying...'
                            : 'Submit to Cloud',
                      ),
                    )
                  else
                    const Text(
                      '✓ Cloud verified!',
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),

                  if (_cloudMessage.isNotEmpty)
                    Text(_cloudMessage, textAlign: TextAlign.center),

                  const SizedBox(height: 16),
                  TextButton(
                    onPressed:
                        (_isSyncing ||
                            _isVerifying ||
                            _saveUnknown ||
                            _verificationUnavailable ||
                            !_isSynced)
                        ? null
                        : _restart,
                    child: const Text('Play Again'),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(
                    value: (_currentIndex + 1) / _questions.length,
                    backgroundColor: Colors.orange.shade100,
                    color: Colors.deepOrange,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Question ${_currentIndex + 1} of ${_questions.length}',
                    style: const TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Text(
                        _questions[_currentIndex].questionText,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  ..._questions[_currentIndex].options.map((opt) {
                    Color btnColor = Colors.white;
                    if (_answered) {
                      if (opt == _questions[_currentIndex].correctAnswer) {
                        btnColor = Colors.green.shade200;
                      } else if (opt == _selectedOption) {
                        btnColor = Colors.red.shade200;
                      }
                    }
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12.0),
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: btnColor,
                          foregroundColor: Colors.black87,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onPressed: () => _answerQuestion(opt),
                        child: Text(opt, style: const TextStyle(fontSize: 16)),
                      ),
                    );
                  }),
                  const Spacer(),
                  if (_answered)
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepOrange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: _nextQuestion,
                      child: Text(
                        _currentIndex < _questions.length - 1
                            ? 'Next Question →'
                            : 'View Final Score',
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
