import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:opennutritracker/features/add_meal/data/anthropic_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_portion_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/refine_resolved_meals_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/resolve_parsed_meals_usecase.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/bulk_add_bloc.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

MealEntity food(
  String name, {
  double? kcal,
  List<MealPortionEntity> portions = const [],
  String? mealUnit,
}) => MealEntity(
  code: name,
  name: name,
  url: null,
  mealQuantity: null,
  mealUnit: mealUnit,
  servingQuantity: null,
  servingUnit: null,
  servingSize: null,
  portions: portions,
  source: MealSourceEntity.off,
  nutriments: MealNutrimentsEntity(
    energyKcal100: kcal,
    carbohydrates100: 1,
    fat100: 2,
    proteins100: 3,
    sugars100: null,
    saturatedFat100: null,
    fiber100: null,
  ),
);

ResolvedMealItem item(
  String query,
  List<MealEntity> candidates, {
  double? quantity,
  int selectedIndex = 0,
  double confidence = 0.8,
}) => ResolvedMealItem(
  parsed: ParsedMealItem(query: query, quantity: quantity),
  candidates: candidates,
  selectedIndex: selectedIndex,
  confidence: candidates.isEmpty ? 0 : confidence,
);

final eggs = item('eggs', [
  food('Egg yolk, raw', kcal: 322),
  food(
    'Egg, whole, raw',
    kcal: 143,
    portions: const [
      MealPortionEntity(label: '1 large', gramWeight: 50, localized: false),
    ],
  ),
], quantity: 2);

final toast = item('toast', [
  food('Tostada shell, corn', kcal: 474),
  food('Bread, white, toasted', kcal: 293),
], quantity: 1);

const meal = 'dos huevos revueltos y una tostada';

/// Replays one Anthropic tool call; nothing touches the network.
class _ReplyClient extends http.BaseClient {
  final List<Map<String, dynamic>> items;
  Map<String, dynamic>? sent;

  _ReplyClient(this.items);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
    final body = jsonEncode({
      'id': 'msg_1',
      'type': 'message',
      'role': 'assistant',
      'content': [
        {
          'type': 'tool_use',
          'id': 'tu_1',
          'name': 'log_meal_items',
          'input': {'items': items},
        },
      ],
    });
    return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
  }
}

void main() {
  group('buildRequest', () {
    test('shows the meal, what was stated, and every candidate', () {
      final text = RefineResolvedMealsUseCase.buildRequest(meal, [eggs, toast]);
      expect(text, contains('Meal: "$meal"'));
      expect(text, contains('Item 1: "eggs" (stated: 2)'));
      expect(text, contains('c1: Egg, whole, raw [off] | 143 kcal'));
      expect(text, contains('portions: 1 large = 50 g'));
      expect(text, contains('Item 2: "toast"'));
      expect(text, contains('c0: Tostada shell, corn'));
    });

    test('states a unit, so the clients keep the one in the answer', () {
      // The clients drop a reply unit the request never stated (#977).
      final text = RefineResolvedMealsUseCase.buildRequest(meal, [eggs]);
      expect(textStatesAUnit(text), isTrue);
    });

    test('caps the candidates but keeps the resolver pick', () {
      final many = item('apple', [
        for (var i = 0; i < 10; i++) food('Apple $i', kcal: 50),
      ], selectedIndex: 8);
      final text = RefineResolvedMealsUseCase.buildRequest('an apple', [many]);
      expect(text, contains('c5: Apple 5'));
      expect(text, isNot(contains('c6: Apple 6')));
      expect(text, contains('c8: Apple 8'));
    });
  });

  group('applyRefinement', () {
    test('a pick sets the candidate and the grams', () {
      final out = RefineResolvedMealsUseCase.applyRefinement(
        [eggs, toast],
        const [
          ParsedMealItem(query: '1:c1', quantity: 100, unit: 'g'),
          ParsedMealItem(query: '2:c1', quantity: 30, unit: 'g'),
        ],
      );
      expect(out[0].selectedIndex, 1);
      expect(out[0].parsed.quantity, 100);
      expect(out[0].parsed.unit, 'g');
      expect(out[0].parsed.query, 'eggs');
      expect(out[1].selected!.name, 'Bread, white, toasted');
      expect(out[1].isLowConfidence, isFalse);
    });

    test('"none" keeps the row but flags it for checking', () {
      final out = RefineResolvedMealsUseCase.applyRefinement(
        [toast],
        const [ParsedMealItem(query: '1:none')],
      );
      expect(out.single.selectedIndex, toast.selectedIndex);
      expect(out.single.isLowConfidence, isTrue);
    });

    test('unusable answers leave the resolver rows untouched', () {
      final out = RefineResolvedMealsUseCase.applyRefinement(
        [eggs, toast],
        const [
          ParsedMealItem(query: 'eggs', quantity: 100, unit: 'g'),
          ParsedMealItem(query: '1:c9', quantity: 100, unit: 'g'),
          ParsedMealItem(query: '2:c1', quantity: 2),
          ParsedMealItem(query: '3:c0', quantity: 10, unit: 'g'),
        ],
      );
      expect(out, [same(eggs), same(toast)]);
    });

    test('a picked row starts settled on the review screen', () {
      final out = RefineResolvedMealsUseCase.applyRefinement(
        [eggs],
        const [ParsedMealItem(query: '1:c1', quantity: 100, unit: 'g')],
      );
      final row = BulkAddRow(
        resolved: out.single,
        selectedIndex: out.single.selectedIndex,
        amountText: '100',
        unit: 'g',
      );
      expect(row.amountNeedsCheck, isFalse);
      expect(row.isLowConfidence, isFalse);
      expect(row.meal!.name, 'Egg, whole, raw');
    });
  });

  test('round trip through a real client keeps the grams', () async {
    final client = _ReplyClient([
      {'query': '1:c1', 'quantity': 100, 'unit': 'g'},
      {'query': '2:c1', 'quantity': 30, 'unit': 'g'},
    ]);
    final api = AnthropicMealItemsApi(client, () => 'test-key');
    final reply = await api.requestItems(
      content: MealTextContent(
        RefineResolvedMealsUseCase.buildRequest(meal, [eggs, toast]),
      ),
      system: RefineResolvedMealsUseCase.systemPrompt,
    );
    final out = RefineResolvedMealsUseCase.applyRefinement([
      eggs,
      toast,
    ], reply.items);

    expect(client.sent!['system'], RefineResolvedMealsUseCase.systemPrompt);
    expect(out[0].selectedIndex, 1);
    expect(out[0].parsed.quantity, 100);
    expect(out[0].parsed.unit, 'g');
    expect(out[1].parsed.quantity, 30);
  });
}
