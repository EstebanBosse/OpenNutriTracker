// Fork: second AI pass over the food-database matches.
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/resolve_parsed_meals_usecase.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

/// Shows the model the meal as the user said it, together with the database
/// rows the search found for each item. The model picks the right row and
/// says how many grams were eaten.
///
/// **The model still produces no nutrition.** It names a row and a weight.
/// The app takes the per-100 g values from that row and multiplies, so every
/// calorie on the review screen comes from a food database. What the model
/// adds is judgement the ranker cannot make ("tostada" is toast, not a
/// tostada shell; "café con leche" is mostly milk) and a portion estimate
/// when the user stated none.
///
/// The request goes through the same [MealItemsApi] clients and the same
/// `log_meal_items` tool as the first pass. The answer is encoded in that
/// schema: `query` carries `"<item>:c<candidate>"`, and `quantity` + `unit`
/// carry the grams or millilitres. So this pass adds no new schema and no
/// new HTTP code, and every client's failure handling and output validation
/// still apply.
///
/// Any failure returns the resolver's rows unchanged, so the second pass
/// can only improve the screen, never block it.
class RefineResolvedMealsUseCase {
  static final _log = Logger('RefineResolvedMealsUseCase');

  /// How many candidates per item the model sees. The resolver ranks them,
  /// and past the first few they are rarely the food.
  static const maxCandidates = 6;

  final AiCredentialStorage _credentials;
  final MealItemsApi Function(AiSelection selection) _apiFactory;

  RefineResolvedMealsUseCase(this._credentials, this._apiFactory);

  static const systemPrompt = '''
You match a meal the user described against food-database search results and
estimate how much was eaten. You never produce nutrition values: the app
computes them from the database row you pick.

The user message contains the meal exactly as the user said it, then
numbered items. Each item lists candidate rows as
  c<N>: name [source] | kcal, protein, fat, carbs per 100 g | portions
Each item also lists what the first reading understood (amount, unit or
portion), which may be absent.

Return exactly one entry per item, in item order, with:
- "query": "<item number>:c<N>" for the candidate that is the food the user
  ate, matching the preparation when it matters (raw vs cooked, whole vs
  skimmed, plain vs sweetened). Prefer generic foods over a specific brand
  unless the user named the brand. Use "<item number>:none" when no
  candidate is that food.
- "quantity" and "unit": how much was eaten, in grams ("g"), or in
  millilitres ("ml") for drinks. Use the amount the user stated, converted
  with the candidate's portion weights ("2 eggs" with "1 large = 50 g" gives
  100 g). When no amount was stated, estimate one typical adult serving,
  preferring the candidate's own portion weights.
- No "portion".
Never merge, split or add items.''';

  Future<List<ResolvedMealItem>> refine(
    String text,
    List<ResolvedMealItem> items,
  ) async {
    if (!items.any((item) => item.isResolved)) return items;
    final selection = await _credentials.readSelection();
    if (selection == null) return items;

    try {
      final result = await _apiFactory(selection).requestItems(
        content: MealTextContent(buildRequest(text, items)),
        system: systemPrompt,
      );
      return applyRefinement(items, result.items);
    } on MealInterpreterException catch (e) {
      // Logged without the meal text, as the first pass does.
      _log.info('Refinement unavailable, keeping the matches: ${e.reason}');
      return items;
    } catch (e, stackTrace) {
      _log.severe('Refinement failed unexpectedly', e, stackTrace);
      return items;
    }
  }

  /// The user message: the meal, then each item with its candidates.
  static String buildRequest(String text, List<ResolvedMealItem> items) {
    final out = StringBuffer('Meal: "${text.trim()}"\n');
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final parsed = item.parsed;
      out.write('\nItem ${i + 1}: "${parsed.query}"');
      final stated = [
        if (parsed.quantity != null) _number(parsed.quantity!),
        ?parsed.unit,
        if (parsed.portion != null) '(${parsed.portion})',
      ];
      out.writeln(
        stated.isEmpty
            ? ' (no amount stated)'
            : ' (stated: ${stated.join(' ')})',
      );
      final shown = _candidateIndexes(item);
      if (shown.isEmpty) out.writeln('  (no candidates)');
      for (final c in shown) {
        out.writeln('  c$c: ${_describe(item.candidates[c])}');
      }
    }
    // Also what lets the clients keep the unit in the answer: they drop a
    // unit the request never stated (#977), and this line states one.
    out.write('\nAnswer amounts like 100 g or 250 ml.');
    return out.toString();
  }

  /// The first [maxCandidates], plus the resolver's own pick if it ranked
  /// lower, so the model can always confirm it.
  static List<int> _candidateIndexes(ResolvedMealItem item) {
    final count = item.candidates.length;
    final shown = [for (var i = 0; i < count && i < maxCandidates; i++) i];
    if (item.isResolved && !shown.contains(item.selectedIndex)) {
      shown.add(item.selectedIndex);
    }
    return shown;
  }

  static String _describe(MealEntity meal) {
    final n = meal.nutriments;
    final name = [
      meal.name ?? '?',
      if (meal.brands case final brands? when brands.trim().isNotEmpty)
        '(${brands.trim()})',
    ].join(' ');
    final source = meal.backendSource ?? meal.source.name;
    String v(double? value) => value == null ? '?' : _number(value);
    final per100 =
        '${v(n.energyKcal100)} kcal, P ${v(n.proteins100)}, '
        'F ${v(n.fat100)}, C ${v(n.carbohydrates100)} '
        'per 100 ${meal.isLiquid ? 'ml' : 'g'}';
    final portions = [
      for (final p in meal.portions)
        '${p.englishLabel ?? p.label} = ${_number(p.gramWeight)} g',
      if (meal.portions.isEmpty && meal.servingQuantity != null)
        'serving = ${_number(meal.servingQuantity!)} '
            '${meal.servingUnit ?? 'g'}',
    ];
    return '$name [$source] | $per100'
        '${portions.isEmpty ? '' : ' | portions: ${portions.join('; ')}'}';
  }

  static final _answer = RegExp(
    r'^\s*(\d+)\s*:\s*(?:c\s*(\d+)|(none))\s*$',
    caseSensitive: false,
  );

  /// Applies the model's picks.
  ///
  /// A row the model matched takes that candidate and the stated weight, as
  /// if the user had said "100 g". A row the model rejected keeps the
  /// resolver's pick but drops to low confidence, so the screen asks the
  /// user to check it. A row the model skipped, or answered with something
  /// unusable, stays exactly as the resolver left it.
  static List<ResolvedMealItem> applyRefinement(
    List<ResolvedMealItem> items,
    List<ParsedMealItem> answers,
  ) {
    final refined = [...items];
    for (final answer in answers) {
      final match = _answer.firstMatch(answer.query);
      if (match == null) continue;
      final index = int.parse(match.group(1)!) - 1;
      if (index < 0 || index >= items.length) continue;
      final item = items[index];
      if (!item.isResolved) continue;

      if (match.group(3) != null) {
        refined[index] = ResolvedMealItem(
          parsed: item.parsed,
          candidates: item.candidates,
          selectedIndex: item.selectedIndex,
          confidence: 0,
        );
        continue;
      }

      final candidate = int.parse(match.group(2)!);
      final quantity = answer.quantity;
      final unit = answer.unit;
      if (candidate >= item.candidates.length ||
          quantity == null ||
          quantity <= 0 ||
          (unit != 'g' && unit != 'ml')) {
        continue;
      }
      refined[index] = ResolvedMealItem(
        parsed: ParsedMealItem(
          query: item.parsed.query,
          quantity: quantity,
          unit: unit,
        ),
        candidates: item.candidates,
        selectedIndex: candidate,
        confidence: item.confidence < kResolutionConfidenceFloor
            ? kResolutionConfidenceFloor
            : item.confidence,
      );
    }
    return refined;
  }

  static String _number(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}
