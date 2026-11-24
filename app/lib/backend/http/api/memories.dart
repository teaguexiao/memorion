import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/schema/memory.dart';
import 'package:memorion/env/env.dart';

/// 新建事实，**返回服务端落库后的那一条**（失败返回 null）。
///
/// 必须把服务端的 id 拿回来：id 由后端生成，调用方若自己造一个 uuid 填进列表，
/// 那条新事实在下次 loadMemories 之前所有按 id 的操作（编辑、删除）都会 404。
Future<Memory?> createMemoryServer(String content, String visibility) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/memories',
    headers: {},
    method: 'POST',
    body: json.encode({
      'content': content,
      'visibility': visibility,
    }),
  );
  if (response == null) return null;
  debugPrint('createMemory response: ${response.statusCode} ${response.body}');
  if (response.statusCode != 200) return null;
  try {
    return Memory.fromJson(json.decode(response.body));
  } catch (e) {
    debugPrint('createMemory parse error: $e');
    return null;
  }
}

Future<bool> updateMemoryVisibilityServer(String memoryId, String visibility) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/memories/$memoryId/visibility?value=$visibility',
    headers: {},
    method: 'PATCH',
    body: '',
  );
  if (response == null) return false;
  debugPrint('updateMemoryVisibility response: ${response.body}');
  return response.statusCode == 200;
}

/// 拉取事实列表。**失败返回 null，不是空列表。**
///
/// 这两种情况必须分得开：服务端确实没有事实（`[]`）和这次没拉到（网络断、非 200、
/// 解析失败）。都返回 `[]` 的话，调用方无法判断该不该用这个结果覆盖本地缓存——
/// 实测后果是反过来的那一半：复筛把噪音清掉后服务端只剩少量事实，而任何一次拉取
/// 失败都会让 provider 退回旧缓存，模拟器上于是一直显示着早已软删的
/// 「用户的团队使用 EC2」。
/// [status]：`confirmed`（默认，已确认事实，「它记住的事实」列表用）/
/// `pending`（LLM 提取、待用户在气泡卡确认）/ `all`。
Future<List<Memory>?> getMemories({int limit = 100, int offset = 0, String status = 'confirmed'}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/memories?limit=$limit&offset=$offset&status=$status',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  debugPrint('getMemories response: ${response.statusCode} ${response.body}');
  if (response.statusCode != 200) return null;
  try {
    List<dynamic> memories = json.decode(response.body);
    return memories.map((memory) => Memory.fromJson(memory)).toList();
  } catch (e) {
    debugPrint('getMemories parse error: $e');
    return null;
  }
}

Future<bool> deleteMemoryServer(String memoryId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/memories/$memoryId',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deleteMemory response: ${response.body}');
  return response.statusCode == 200 || response.statusCode == 204;
}

Future<bool> deleteAllMemoriesServer() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/memories',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deleteAllMemories response: ${response.body}');
  return response.statusCode == 200;
}

Future<bool> reviewMemoryServer(String memoryId, bool value) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/memories/$memoryId/review?value=$value',
    headers: {},
    method: 'POST',
    body: '',
  );
  if (response == null) return false;
  debugPrint('reviewMemory response: ${response.body}');
  return response.statusCode == 200;
}

Future<bool> editMemoryServer(String memoryId, String value) async {
  var response = await makeApiCall(
    // 事实正文是用户手输的，必须编码后再拼进 query：里头一个 & 或 # 就会把
    // 后面的内容（以及 makeApiCall 追加的 external_user_id）截掉。
    url: '${Env.apiBaseUrl}v1/memories/$memoryId?value=${Uri.encodeQueryComponent(value)}',
    headers: {},
    method: 'PATCH',
    body: '',
  );
  if (response == null) return false;
  debugPrint('editMemory response: ${response.body}');
  return response.statusCode == 200;
}
