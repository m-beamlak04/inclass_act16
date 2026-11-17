# ICA 16 – Class A Cloud Quiz

The app retrieves 10 easy General Knowledge questions from Open Trivia Database. Users sign in with Firebase Authentication, complete the quiz, review their answers, and submit their score to Cloud Firestore.

## Setup

1. Install Flutter and set up an Android emulator or device.
2. Clone the repository and open the project.
3. Install dependencies: `flutter pub get`
4. Create a Firebase project and enable:
    - Email/Password Authentication
    - Cloud Firestore (Standard edition, Native mode)
5. Create two test users in Firebase Authentication.
6. Configure the Android application using FlutterFire CLI: `flutterfire configure`
7. Publish the Firestore security rules from `firestore.rules` to the Firebase project.
8. Run the application: `flutter run`

## Usage

1. Sign in using a Firebase test account.
2. Answer the 10 multiple-choice questions.
3. Review your score and answers.
4. Tap `Submit to Cloud` to save and verify the attempt.
5. Select `Play Again` to start a new round.

An internet connection is required to retrieve questions and verify cloud submissions.

## Tools & Services

- Flutter / Dart
- Open Trivia Database API
- Firebase Authentication
- Cloud Firestore

## Notes

- Quiz attempts are stored under `users/{uid}/attempts/{roundId}`.
- Firestore transactions help prevent duplicate submissions.
- Scores are verified through a server-only Firestore read.
- Test account passwords are not included in the repository.