# Fork notes: voice input

This is a fork of [simonoppowa/OpenNutriTracker](https://github.com/simonoppowa/OpenNutriTracker)
(GPL-3.0). It adds one feature: **dictating a meal in Spanish or English**, which
is then matched against the existing food databases and logged through
upstream's normal review screen.

## How it works

```
mic (on-device speech recognition, ES or EN)
  → transcript in the "Describe" field
  → upstream AI meal reader (BYOK: Anthropic / OpenAI / OpenRouter / own server)
      fork tweak: food queries always come back in English
  → upstream resolver: Open Food Facts + Supabase backend (USDA, BLS, …)
  → upstream review screen → Log
```

The AI only names foods and quantities. Every calorie and macro still comes
from the food databases, as upstream intends. That is the main difference from
fud-ai, where the LLM estimates the nutrition itself.

### Using it

1. Settings → AI meal assistance: add a key (or point it at your own Ollama).
   Without a model, a spoken Spanish sentence falls back to upstream's
   deterministic parser. That parser only splits on punctuation and doesn't
   translate, so voice works much better with a model configured.
2. Add food → **Describe** → tap the **ES/EN** chip to pick the dictation
   language (it is remembered) → tap the **mic**.
3. Say the meal, e.g. *"dos huevos revueltos, una tostada con manteca y un café con leche"*.
4. Pause for about 2.5 s, or tap stop. The text is matched straight away. Check
   the rows and tap **Log**.

The review screen has the same mic, so you can dictate a correction and the
matches update.

## What the fork changes

Fork code is marked with a `// Fork` comment. New files (no merge risk):

| File | Role |
| --- | --- |
| `lib/features/add_meal/domain/voice/dictation_service.dart` | Recognizer interface, `DictationLanguage` (es, en) |
| `lib/features/add_meal/domain/voice/dictation_transcript.dart` | Joins recognizer segments (pure Dart) |
| `lib/features/add_meal/data/voice/speech_to_text_dictation_service.dart` | `speech_to_text` adapter, regional locale pick (e.g. `es_AR`) |
| `lib/features/add_meal/presentation/voice/dictation_session.dart` | Restart-on-pause loop and silence detection (idea from fud-ai, MIT) |
| `lib/features/add_meal/presentation/voice/voice_input_button.dart` | ES/EN chip and mic, used as a `TextField.suffixIcon` |
| `test/unit_test/fork_voice/*`, `test/features/add_meal/presentation/voice_input_button_test.dart` | Tests |

Small edits to upstream files (where merge conflicts could happen):

| File | Edit |
| --- | --- |
| `pubspec.yaml` / `pubspec.lock` | `speech_to_text` |
| `lib/features/add_meal/presentation/widgets/add_food_methods.dart` | `suffixIcon:` on the Describe field |
| `lib/features/add_meal/presentation/screens/bulk_add_screen.dart` | `suffixIcon:` on the review-screen field |
| `lib/features/add_meal/data/model_meal_text_interpreter.dart` | `englishQueries` flag; appends one rule after upstream's prompt |
| `lib/core/utils/locator.dart` | passes `englishQueries: true` |
| `lib/l10n/intl_en.arb`, `lib/l10n/intl_es.arb` | five `voiceInput*` keys, placed after `bulkAddParseLabel` |
| `android/app/src/main/AndroidManifest.xml` | `RECORD_AUDIO`, `RecognitionService` query |
| `ios/Runner/Info.plist` | microphone and speech-recognition usage strings |

## Syncing with upstream

Remotes: `origin` = this fork, `upstream` = simonoppowa. Upstream releases land
on `main`, and feature work happens on `develop`. The fork follows `main`.

```sh
git fetch upstream
git checkout main && git merge upstream/main     # keep main == upstream
git checkout feat/voice-input && git merge main  # or: git rebase main
flutter pub get && dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n && flutter analyze && flutter test
```

If a merge conflicts:

- **`intl_es.arb`**: Weblate rewrites this file. Keep upstream's version and
  re-add the five `voiceInput*` lines.
- **`pubspec.lock`**: take upstream's version, then run `flutter pub get`.
- **`model_meal_text_interpreter.dart`**: keep upstream's prompt, then re-add
  the `englishQueries` field and the `system:` line.

Don't run `just format` / `dart format` over the whole tree. With the pinned SDK
it reformats about 25 upstream files the fork never touched, and those changes
cause needless conflicts. Format only the fork's files.

## Building

You need Flutter 3.44.6 (`.fvmrc`). Copy `.env.example` to `.env`. With the
placeholder values the app runs, but only **Open Food Facts** is searched,
because the USDA/BLS backend is a Supabase project. To get it, follow
`docs/supabase-self-hosting.md` and put its URL and anon key in `.env`, then
run `dart run build_runner build`.

```sh
flutter run --flavor develop        # debug on a device
flutter build apk --flavor full --release
```

On Android, speech recognition needs a recognizer service on the phone. That
is normally the Google app or "Speech Recognition & Synthesis". On iOS it
uses Apple's recognizer.
