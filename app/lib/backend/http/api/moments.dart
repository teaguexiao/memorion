import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/env/env.dart';

/// Fetches moments (day summaries) from the server.
///
/// Returns a list of ServerMessage objects with type 'day_summary'.
/// Results are ordered by created_at descending (newest first).
Future<List<ServerMessage>> getMomentsFromServer({
  int limit = 20,
  int offset = 0,
}) async {
  var url = '${Env.apiBaseUrl}v1/moments?limit=$limit&offset=$offset';

  var response = await makeApiCall(
    url: url,
    headers: {},
    method: 'GET',
    body: '',
  );

  if (response == null) return [];
  if (response.statusCode == 200) {
    var body = utf8.decode(response.bodyBytes);
    var decodedBody = jsonDecode(body) as List<dynamic>;
    if (decodedBody.isEmpty) {
      return [];
    }
    var moments = decodedBody.map((moment) => ServerMessage.fromJson(moment)).toList();
    debugPrint('getMomentsFromServer: fetched ${moments.length} moments');
    return moments;
  }

  debugPrint('getMomentsFromServer failed with status: ${response.statusCode}');
  return [];
}
