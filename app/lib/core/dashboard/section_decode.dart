/// Decodes a dashboard [Section] once per section instance.
library;

import 'package:yams_models/yams_models.dart';

final Expando<Object> _decoded = Expando<Object>('decodedSection');

/// [Section.decode] with [f], remembered for this section instance: a card
/// that rebuilds (theme change, a parent rebuild) does not parse its JSON
/// again, and an unchanged section keeps its identity across refreshes (see
/// `reuseSection`). Null when there is no data; a [FormatException] from [f]
/// propagates and is not remembered.
T? decodeCached<T extends Object>(Section section, T Function(JsonMap) f) {
  final data = section.data;
  if (data == null) return null;
  final hit = _decoded[section];
  if (hit is T) return hit;
  final value = f(data);
  _decoded[section] = value;
  return value;
}
