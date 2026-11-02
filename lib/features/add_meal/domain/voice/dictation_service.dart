// Fork (voice input).

/// A language the user can dictate in. Only the languages listed in
/// [values] are offered; adding one is a line here plus its fallback locale.
enum DictationLanguage {
  es('es', 'es_ES'),
  en('en', 'en_US');

  /// ISO 639-1 code, also what is persisted.
  final String code;

  /// Recognizer locale to use when the device does not list one for this
  /// language.
  final String fallbackLocaleId;

  const DictationLanguage(this.code, this.fallbackLocaleId);

  static DictationLanguage? fromCode(String? code) {
    for (final language in values) {
      if (language.code == code) return language;
    }
    return null;
  }
}

/// Why a dictation session could not run at all. Errors inside a running
/// session (a pause with no speech, a recognizer hiccup) are not reported
/// this way; the session simply ends with whatever was heard.
enum DictationUnavailable {
  /// Microphone or speech permission denied.
  permission,

  /// No speech recognition service on this device.
  noRecognizer,
}

class DictationUnavailableException implements Exception {
  final DictationUnavailable reason;

  const DictationUnavailableException(this.reason);

  @override
  String toString() => 'DictationUnavailableException($reason)';
}

/// One recognizer result.
class DictationResult {
  final String words;
  final bool isFinal;

  const DictationResult(this.words, {required this.isFinal});
}

/// The platform speech recognizer, reduced to what the voice button needs.
///
/// A segment is one recognizer run. The session logic that strings segments
/// together lives in the widget's controller, not here, so this stays a thin
/// adapter that a test can replace.
abstract interface class DictationService {
  /// Prepares the recognizer and asks for permission on first use. Throws
  /// [DictationUnavailableException] when dictation cannot work.
  Future<void> ensureReady();

  /// Starts one segment. [onResult] receives partial and final results;
  /// [onSegmentEnd] is called exactly once when the segment ends for any
  /// reason (silence, error, [stop]).
  Future<void> startSegment({
    required DictationLanguage language,
    required void Function(DictationResult result) onResult,
    required void Function() onSegmentEnd,
  });

  /// Ends the current segment, delivering a final result if there is one.
  Future<void> stop();

  /// Ends the current segment and discards it.
  Future<void> cancel();
}
