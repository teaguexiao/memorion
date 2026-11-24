import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/models/subscription.dart';
import 'package:memorion/models/user_usage.dart';

Future<bool> deleteAccount() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/delete-account',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deleteAccount response: ${response.body}');
  return response.statusCode == 200;
}

Future<bool> setRecordingPermission(bool value) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/store-recording-permission?value=$value',
    headers: {},
    method: 'POST',
    body: '',
  );
  if (response == null) return false;
  debugPrint('storeRecordingPermission response: ${response.body}');
  return response.statusCode == 200;
}

Future<bool?> getStoreRecordingPermission() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/store-recording-permission',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  debugPrint('getStoreRecordingPermission response: ${response.body}');
  if (response.statusCode == 200) {
    var jsonResponse = jsonDecode(response.body);
    return jsonResponse['store_recording_permission'] as bool?;
  }
  return null;
}

Future<bool> deletePermissionAndRecordings() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/store-recording-permission',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deletePermissionAndRecordings response: ${response.body}');
  return response.statusCode == 200;
}

/**/

Future<Person?> createPerson(String name) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/people',
    headers: {},
    method: 'POST',
    body: jsonEncode({'name': name, 'external_user_id': getExternalUserId()}),
  );
  if (response == null) return null;
  debugPrint('createPerson response: ${response.body}');
  // Developer API returns 201 for successful creation
  if (response.statusCode == 201 || response.statusCode == 200) {
    return Person.fromJson(jsonDecode(response.body));
  }
  return null;
}

Future<Person?> getSinglePerson(String personId, {bool includeSpeechSamples = false}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/people/$personId?include_speech_samples=$includeSpeechSamples',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  debugPrint('getSinglePerson response: ${response.body}');
  if (response.statusCode == 200) {
    return Person.fromJson(jsonDecode(response.body));
  }
  return null;
}

/// 拉取人物列表失败。**必须抛出、不能返回短列表**，见 [getAllPeople]。
class PeopleFetchException implements Exception {
  final String reason;

  PeopleFetchException(this.reason);

  @override
  String toString() => 'PeopleFetchException($reason)';
}

/// 全部人物，**不含语音样本 URL**。任意一页失败都抛 [PeopleFetchException]，绝不返回
/// 截断的结果。
///
/// ⚠️ **别把 `include_speech_samples=true` 加回来。** 后端要为每个人各列一次 GCS 并
/// 逐 blob 签名：833 人的账号上单页实测 15.65s（vs 2.38s），全量两页 27 秒——而这段
/// 时间里只要锁屏或切到别的 App，iOS 就挂起网络、请求失败。列表页要的只是「N 段样本」
/// 这个数字，后端已经在 `speech_samples_count` 里给了（一次整体前缀列举算出）；URL 由
/// `PeopleProvider.loadPersonSamples` 在打开详情时按人拉。
///
/// ⚠️ **失败时返回「已经拿到的那部分」会把本地缓存冲掉。** 调用方分不清「这个用户
/// 只有 3 个人」和「第一页就超时了」，于是把空列表当成真相写进 `cachedPeople`——
/// 人物页和「标记说话人」卡片同时变空，而且再进来还是空的（缓存已经没了，只能等
/// 一次完整成功的拉取）。
Future<List<Person>> getAllPeople() async {
  // The backend caps each request at limit=500, but a user can have far more
  // people than that (e.g. 800+). Page through with limit+offset until a short
  // page comes back, otherwise the speaker-tagging list silently drops everyone
  // past the first page.
  const int pageSize = 500;
  // Safety cap so a backend that ignores `offset` (always returning a full
  // page) can't spin this loop forever. 20 pages = 10k people, well beyond any
  // realistic contact list.
  const int maxPages = 20;
  final List<Person> people = [];
  int offset = 0;
  for (int page = 0; page < maxPages; page++) {
    var response = await makeApiCall(
      url: '${Env.apiBaseUrl}v1/people'
          '?include_speech_samples=false&limit=$pageSize&offset=$offset',
      headers: {},
      method: 'GET',
      body: '',
    );
    // i18n-ignore: 异常原因串只进 debugPrint，永不出现在界面上
    if (response == null) throw PeopleFetchException('network error at offset $offset');
    if (response.statusCode != 200) throw PeopleFetchException('HTTP ${response.statusCode} at offset $offset');
    final List<dynamic> peopleJson = jsonDecode(response.body);
    for (final json in peopleJson) {
      json['color_idx'] = people.length % speakerColors.length;
      people.add(Person.fromJson(json));
    }
    if (peopleJson.length < pageSize) break;
    offset += pageSize;
  }
  // sort by name
  people.sort((a, b) => a.name.compareTo(b.name));
  return people;
}

Future<bool> updatePersonName(String personId, String newName) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/people/$personId',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({'name': newName}),
  );
  if (response == null) return false;
  debugPrint('updatePersonName response: ${response.body}');
  return response.statusCode == 200;
}

Future<bool> deletePerson(String personId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/people/$personId',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deletePerson response: ${response.body}');
  return response.statusCode == 204;
}

Future<bool> deletePersonSpeechSample(String personId, String sampleId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/people/$personId/speech-samples/$sampleId',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deletePersonSpeechSample response: ${response.statusCode}');
  return response.statusCode == 204;
}

Future<String> getFollowUpQuestion({String conversationId = '0'}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/joan/$conversationId/followup-question',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return '';
  debugPrint('getFollowUpQuestion response: ${response.body}');
  if (response.statusCode == 200) {
    var jsonResponse = jsonDecode(response.body);
    return jsonResponse['result'] as String? ?? '';
  }
  return '';
}

/*Analytics*/

Future<bool> setConversationSummaryRating(String conversationId, int value, {String? reason}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/analytics/memory_summary?memory_id=$conversationId&value=$value&reason=$reason',
    headers: {},
    method: 'POST',
    body: '',
  );
  if (response == null) return false;
  debugPrint('setConversationSummaryRating response: ${response.body}');
  return response.statusCode == 200;
}

Future<bool> setMessageResponseRating(String messageId, int value) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/analytics/chat_message?message_id=$messageId&value=$value',
    headers: {},
    method: 'POST',
    body: '',
  );
  if (response == null) return false;
  debugPrint('setMessageResponseRating response: ${response.body}');
  return response.statusCode == 200;
}

Future<bool> getHasConversationSummaryRating(String conversationId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/analytics/memory_summary?memory_id=$conversationId',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return false;
  debugPrint('getHasConversationSummaryRating response: ${response.body}');

  try {
    var jsonResponse = jsonDecode(response.body);
    return jsonResponse['has_rating'] as bool? ?? false;
  } catch (e) {
    return false;
  }
}

// User birthday API calls
Future<bool> setUserBirthday(String birthday) async {
  // birthday: 'YYYY-MM-DD'
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/birthday',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({'birthday': birthday}),
  );
  if (response == null) return false;
  debugPrint('setUserBirthday response: ${response.body}');
  return response.statusCode == 200;
}

// User display name API calls
Future<bool> setUserDisplayName(String name) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/name',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({'name': name}),
  );
  if (response == null) return false;
  debugPrint('setUserDisplayName response: ${response.body}');
  return response.statusCode == 200;
}

// User language preference API calls
Future<String?> getUserPrimaryLanguage() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/user/language',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  debugPrint('getUserPrimaryLanguage response: ${response.body}');

  try {
    var jsonResponse = jsonDecode(response.body);
    // Return null if language is null or empty
    if (jsonResponse['language'] == null || jsonResponse['language'] == '') {
      return null;
    }
    return jsonResponse['language'] as String?;
  } catch (e) {
    debugPrint('Error parsing getUserPrimaryLanguage response: $e');
    return null;
  }
}

Future<bool> setUserPrimaryLanguage(String languageCode) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/user/language',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({'language': languageCode}),
  );
  if (response == null) return false;
  debugPrint('setUserPrimaryLanguage response: ${response.body}');
  return response.statusCode == 200;
}

// User timezone preference API calls
Future<String?> getUserTimezone() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/user/timezone',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  debugPrint('getUserTimezone response: ${response.body}');

  try {
    var jsonResponse = jsonDecode(response.body);
    // Return null if timezone is null or empty
    if (jsonResponse['timezone'] == null || jsonResponse['timezone'] == '') {
      return null;
    }
    return jsonResponse['timezone'] as String?;
  } catch (e) {
    debugPrint('Error parsing getUserTimezone response: $e');
    return null;
  }
}

Future<bool> setUserTimezone(String timezone) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/user/timezone',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({'timezone': timezone}),
  );
  if (response == null) return false;
  debugPrint('setUserTimezone response: ${response.body}');
  return response.statusCode == 200;
}

// 记录内容偏好（O-03 onboarding 标签）。存在服务端 user profile 的
// `recording_categories`，与语言/时区同一份 preferences 文档。
Future<List<String>?> getRecordingCategories() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/user/preferences',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  debugPrint('getRecordingCategories response: ${response.body}');

  try {
    var jsonResponse = jsonDecode(response.body);
    var categories = jsonResponse['recording_categories'];
    if (categories is! List) return null;
    return categories.map((e) => e.toString()).toList();
  } catch (e) {
    debugPrint('Error parsing getRecordingCategories response: $e');
    return null;
  }
}

Future<bool> setRecordingCategories(List<String> categories) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/user/preferences',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({'recording_categories': categories}),
  );
  if (response == null) return false;
  debugPrint('setRecordingCategories response: ${response.body}');
  return response.statusCode == 200;
}

Future<bool> setPreferredSummarizationAppServer(String appId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/user/preferences/app?app_id=$appId',
    headers: {},
    method: 'PUT',
    body: '',
  );
  if (response == null) return false;
  debugPrint('setPreferredSummarizationAppServer response: ${response.body}');
  return response.statusCode == 200;
}

Future<UserUsageResponse?> getUserUsage({required String period}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/me/usage?period=$period',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  debugPrint('getUserUsage response: ${response.body}');
  if (response.statusCode == 200) {
    return UserUsageResponse.fromJson(jsonDecode(response.body));
  }
  return null;
}

Future<UserSubscriptionResponse?> getUserSubscription() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/me/subscription',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  debugPrint('getUserSubscription response: ${response.body}');
  if (response.statusCode == 200) {
    return UserSubscriptionResponse.fromJson(jsonDecode(response.body));
  }
  return null;
}

Future<UserSubscriptionResponse?> verifyAppleSubscription({
  required String transactionId,
  required String productId,
  required String signedTransaction,
}) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/me/subscription/apple/verify',
    headers: {},
    method: 'POST',
    body: jsonEncode({
      'transaction_id': transactionId,
      'product_id': productId,
      'signed_transaction': signedTransaction,
    }),
  );
  if (response == null) return null;
  debugPrint('verifyAppleSubscription status: ${response.statusCode}');
  if (response.statusCode == 200) {
    return UserSubscriptionResponse.fromJson(jsonDecode(response.body));
  }
  return null;
}

/// Sync local user preferences (name, language, timezone) to Memorion API backend.
/// Called after onboarding completes or on first login in Memorion app.
Future<void> syncUserProfileToBackend() async {
  debugPrint('Syncing user profile to Memorion API backend...');

  // Sync display name from SharedPreferences
  final name = SharedPreferencesUtil().fullName;
  if (name.isNotEmpty) {
    final success = await setUserDisplayName(name);
    debugPrint('Sync display name ($name): ${success ? "OK" : "FAILED"}');
  }

  // Sync language from SharedPreferences
  final language = SharedPreferencesUtil().userPrimaryLanguage;
  if (language.isNotEmpty) {
    final success = await setUserPrimaryLanguage(language);
    debugPrint('Sync language (\$language): \${success ? "OK" : "FAILED"}');
  }

  // Sync timezone from SharedPreferences
  final timezone = SharedPreferencesUtil().userTimezone;
  if (timezone.isNotEmpty) {
    final success = await setUserTimezone(timezone);
    debugPrint('Sync timezone (\$timezone): \${success ? "OK" : "FAILED"}');
  }

  // Sync birthday from SharedPreferences (stored as ISO8601, backend expects YYYY-MM-DD)
  final birthday = SharedPreferencesUtil().fortuneBirthDate;
  if (birthday.isNotEmpty) {
    final d = DateTime.tryParse(birthday);
    if (d != null) {
      final success = await setUserBirthday(DateFormat('yyyy-MM-dd').format(d));
      debugPrint('Sync birthday: ${success ? "OK" : "FAILED"}');
    }
  }
}
