import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/data/model_meal_text_interpreter.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';

class _CapturingApi implements MealItemsApi {
  String? system;

  @override
  Future<MealTextParseResult> requestItems({
    required MealContent content,
    required String system,
  }) async {
    this.system = system;
    return const MealTextParseResult(items: [], errors: []);
  }
}

void main() {
  test('upstream behaviour is unchanged by default', () async {
    final api = _CapturingApi();
    await ModelMealTextInterpreter(api).interpret('dos huevos');
    expect(api.system, isNot(contains('always write "query" in English')));
  });

  test('englishQueries appends the override after the app language', () async {
    final api = _CapturingApi();
    await ModelMealTextInterpreter(
      api,
      englishQueries: true,
    ).interpret('dos huevos', localeCode: 'es');
    final system = api.system!;
    expect(system, contains('always write "query" in English'));
    expect(
      system.indexOf('app language is "es"'),
      lessThan(system.indexOf('always write "query" in English')),
    );
  });
}
