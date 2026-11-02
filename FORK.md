# Fork notes: voice input and offline food database

This is a fork of [simonoppowa/OpenNutriTracker](https://github.com/simonoppowa/OpenNutriTracker)
(GPL-3.0). It adds two features:

- **dictating a meal in Spanish or English**, which is then matched against the
  existing food databases and logged through upstream's normal review screen;
- an **offline food database** (see [below](#offline-food-database)): the
  generic foods the Supabase backend serves (USDA, BLS and five European
  tables), downloaded once as a SQLite file and searched on the phone.

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

The voice feature itself was submitted upstream as
[#1514](https://github.com/simonoppowa/OpenNutriTracker/pull/1514), and the
fork carries the same code byte for byte. If upstream merges it, the next
upstream merge makes those files identical and only the **fork-only** rows
below remain. Fork-only code is marked with a `// Fork` comment.

New files (no merge risk):

| File | Role |
| --- | --- |
| `lib/features/add_meal/domain/voice/dictation_service.dart` | Recognizer interface, `DictationLanguage` |
| `lib/features/add_meal/domain/voice/dictation_transcript.dart` | Joins recognizer segments (pure Dart) |
| `lib/features/add_meal/data/voice/speech_to_text_dictation_service.dart` | `speech_to_text` adapter, regional locale pick (e.g. `es_AR`) |
| `lib/features/add_meal/presentation/voice/dictation_session.dart` | Restart-on-pause loop and silence detection (idea from fud-ai, MIT) |
| `lib/features/add_meal/presentation/voice/voice_input_button.dart` | Language chip (app, device and English language) and mic, used as a `TextField.suffixIcon` |
| `test/unit_test/dictation_transcript_test.dart`, `test/features/add_meal/presentation/voice_input_button_test.dart` | Tests |
| `test/unit_test/fork_voice/english_queries_prompt_test.dart` | **Fork-only** test |
| `lib/features/add_meal/domain/usecase/refine_resolved_meals_usecase.dart` | **Fork-only**: second AI pass. The model sees the meal plus the database candidates, picks a row per item and estimates grams. Nutrition still comes from the picked row. Reuses upstream's clients and `log_meal_items` tool (`query` = `"<item>:c<N>"`, `quantity`/`unit` = grams), so it adds no schema or HTTP code |
| `test/unit_test/fork_voice/refine_resolved_meals_test.dart` | **Fork-only** test |
| `lib/features/add_meal/data/data_sources/food_rpc_client.dart` | **Fork-only**: `FoodRpcClient` seam, `SupabaseFoodRpcClient` |
| `lib/features/add_meal/data/offline_food_db/sqlite_food_rpc_client.dart` | **Fork-only**: the five RPCs in SQLite, websearch → FTS5 |
| `lib/features/add_meal/data/offline_food_db/offline_food_db.dart` | **Fork-only**: open/download/verify/remove, switches the client |
| `lib/features/settings/presentation/widgets/offline_food_db_section.dart` | **Fork-only**: the Settings section |
| `test/unit_test/fork_offline_food_db/`, `test/fixture/offline_food_db/foods_fixture.sqlite.gz` | **Fork-only** tests and their fixture (built by the backend's `build_sqlite.py`) |

Small edits to upstream files (where merge conflicts could happen):

| File | Edit |
| --- | --- |
| `pubspec.yaml` / `pubspec.lock` | `speech_to_text`; **fork-only** `sqlite3` 3.5.2 (bundles SQLite with FTS5 through build hooks; ≥3.6 needs a newer Flutter) |
| `lib/features/add_meal/data/data_sources/sp_food_data_source.dart` | **Fork-only**: `_rpcClient()`; the three `SupabaseClient` parameters become `FoodRpcClient` |
| `lib/features/add_meal/data/dto/sp/sp_const.dart` | **Fork-only**: five European codes in `settingsSelectableFoodSources` |
| `lib/core/utils/locale_units.dart` | **Fork-only**: `_forkSourceCountries` defaults in `defaultFoodSourceToggles` |
| `lib/features/settings/presentation/widgets/food_sources_screen.dart` | **Fork-only**: `OfflineFoodDbSection` below the sources |
| `test/features/onboarding/presentation/widgets/onboarding_other_options_page_body_test.dart` | **Fork-only**: source counts computed from `settingsSelectableFoodSources` instead of 5 and 6 |
| `lib/features/add_meal/presentation/widgets/add_food_methods.dart` | `suffixIcon:` on the Describe field |
| `lib/features/add_meal/presentation/screens/bulk_add_screen.dart` | `suffixIcon:` on the review-screen field |
| `lib/features/add_meal/data/model_meal_text_interpreter.dart` | **Fork-only**: `englishQueries` flag; appends one rule after upstream's prompt |
| `lib/core/utils/locator.dart` | **Fork-only**: passes `englishQueries: true`; gives `BulkAddBloc` the refiner; registers `OfflineFoodDb` as `FoodRpcClient` |
| `lib/features/add_meal/presentation/bloc/bulk_add_bloc.dart` | **Fork-only**: optional `refiner`, run after resolution for lines a model read |
| `lib/l10n/intl_en.arb` | five `voiceInput*` keys, placed after `bulkAddParseLabel`; **fork-only** `offlineFoodDb*` keys after `foodSourcesHelpText` |
| `lib/l10n/intl_es.arb` | **Fork-only**: the same keys in Spanish (upstream gets translations from Weblate) |
| `android/app/src/main/AndroidManifest.xml` | `RECORD_AUDIO`, `RecognitionService` query |
| `ios/Runner/Info.plist` | microphone and speech-recognition usage strings |

## Offline food database

The fork has no Supabase project, so without this only Open Food Facts answers.
The backend fork ([EstebanBosse/OpenNutriTracker-Backend](https://github.com/EstebanBosse/OpenNutriTracker-Backend),
`scripts/shared/build_sqlite.py`) builds `foods.sqlite` from the same CSVs the
Supabase import loads: the `food_summary` view, translations, portions and
FTS5 indexes. It is published as `foods.sqlite.gz` on that repo's releases.

```
Settings → Food databases → Offline food database → Download
  → releases/latest/download/foods.sqlite.gz (≈5 MB, ≈16 MB unpacked)
  → unpacked beside the old file, opened, checked (schema version,
    quick_check, a search) and renamed over it
  → every later search uses it — no restart
```

`SpFoodDataSource` sends all five backend calls through one interface,
`FoodRpcClient`. `SupabaseFoodRpcClient` is upstream's behaviour;
`SqliteFoodRpcClient` answers the same function names with the same row maps,
so the locale, retry, source-filter and DTO code above it is unchanged.
`OfflineFoodDb` is the registered client: SQLite while
`getApplicationSupportDirectory()/foods.sqlite` exists with
`meta.schema_version` 1, Supabase otherwise. Search ranking is identical;
what *matches* can differ slightly from Postgres text search (Porter vs
Snowball stemming, diacritics folded, hyphens) — the backend README lists every
difference. Machine-translated food names (`translate_all.py`) are not in the
file, so non-English searches find the native names (BLS German, Fineli
Finnish/Swedish, …) and fall back to English as upstream does.

The five European sources (CIQUAL, Fineli, DTU FCDB, Matvaretabellen,
Livsmedelsverket) are selectable in Settings → Food databases. Onboarding
turns each on only in its own country; for an existing profile a source it
has never seen is on, as upstream treats every new source.

To publish a new database: build it in the backend repo (README, "Offline
SQLite database"), then attach `foods.sqlite.gz` to a new GitHub release
there. Bump `SCHEMA_VERSION` there and `offlineFoodDbSchemaVersion` here
together when the tables change.

## Syncing with upstream

Remotes: `origin` = this fork, `upstream` = simonoppowa. Upstream releases land
on `main`, and feature work happens on `develop`. The fork's `main` is upstream
`main` plus the fork's changes. Upstream PRs are cut from `upstream/develop` on
their own branches (`feat/voice-input-upstream`).

```sh
git fetch upstream
git checkout main && git merge upstream/main
flutter pub get && dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n && flutter analyze && flutter test
```

If a merge conflicts:

- **`intl_es.arb`**: Weblate rewrites this file. Keep upstream's version and
  re-add the five `voiceInput*` lines and the `offlineFoodDb*` lines.
- **`sp_food_data_source.dart`**: keep upstream's version, then route its
  backend calls through `_rpcClient()` / `FoodRpcClient` again.
- **`pubspec.lock`**: take upstream's version, then run `flutter pub get`.
- **`model_meal_text_interpreter.dart`**: keep upstream's prompt, then re-add
  the `englishQueries` field and the `system:` line.

Don't run `just format` / `dart format` over the whole tree. With the pinned SDK
it reformats about 25 upstream files the fork never touched, and those changes
cause needless conflicts. Format only the fork's files.

## Building

You need Flutter 3.44.6 (`.fvmrc`). Copy `.env.example` to `.env`. With the
placeholder values the app runs, but only **Open Food Facts** is searched,
because the USDA/BLS backend is a Supabase project — until the offline food
database is downloaded in Settings → Food databases. For a Supabase backend
instead, follow `docs/supabase-self-hosting.md` and put its URL and anon key in `.env`, then
run `dart run build_runner build`.

```sh
flutter run --flavor develop        # debug on a device
flutter build apk --flavor full --release
```

On Android, speech recognition needs a recognizer service on the phone. That
is normally the Google app or "Speech Recognition & Synthesis". On iOS it
uses Apple's recognizer.
