# In-Class Activity 15 – API-to-Cloud Trivia Showdown

## Overview
This is a Flutter trivia app that uses the Open Trivia Database API to fetch five multiple-choice questions.

## Features
- Fetches five trivia questions from the API.
- Displays four shuffled answer choices.
- Shows correct answers in green and incorrect selections in red.
- Tracks the player's score and displays the final result.
- Allows the player to start another round.
- Displays an error message when the API request fails.
- Simulates syncing the final score.

## Setup
1. Open the project in IntelliJ or another Flutter-supported IDE.
2. Run `flutter pub get` to install dependencies.
3. Start an Android emulator.
4. Run the app using `flutter run`.

An internet connection is required to fetch new questions.

## Testing
I tested the app by loading questions, selecting answers, completing a five-question round, and checking the simulated score sync. I also tested the error handling by disabling the emulator's internet connection.
I tested turning on airplane mode during an active round and was still able to finish the questions. However, starting another round without internet displayed a connection error.
The screenshots, expected results, observed results, and critical-thinking answers are included in my testing evidence document.

## Note About Score Sync
The score sync is only a simulation provided in the starter code. It displays a confirmation message but does not actually send or save the score to an online server.