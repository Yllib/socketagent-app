abstract interface class SpeechInput {
  Stream<String> get onResult;
  Stream<bool> get onListeningStatus;
  bool get isListening;
  Future<bool> initialize();
  Future<void> startListening({
    String existingText = '',
    bool pushToTalk = false,
  });
  Future<void> stopListening();
  void onTextFieldChanged(String currentText);
  Future<void> close();
  void dispose();
}
