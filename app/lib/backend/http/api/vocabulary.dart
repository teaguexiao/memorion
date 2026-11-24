import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/schema/vocabulary_word.dart';
import 'package:memorion/env/env.dart';

/// 拉取词库失败。**必须抛出、不能返回空列表**，见 [getAllVocabulary]。
class VocabularyFetchException implements Exception {
  final String reason;

  VocabularyFetchException(this.reason);

  @override
  String toString() => 'VocabularyFetchException($reason)';
}

/// 拉取用户词库（后端按 created_at DESC 返回）。任意一页失败都抛
/// [VocabularyFetchException]，绝不返回空/截断的列表。
///
/// ⚠️ **失败时 `return []` 会被调用方当成「这个用户没有词条」。** `makeApiCall` 把任何
/// throw 都变成 `return null`（iOS 一锁屏/切后台就挂起网络，而它不设超时），于是一次
/// 超时在界面上就是干净的空态「还没有添加词条」——用户分不清是自己没加过还是没拉到。
/// 更糟的是 `VocabularyProvider` 是 App 根上的全局单例：空列表一旦被当成成功，
/// `_hasLoaded` 就置位了，退出页面重进也不再发请求，只能杀掉 App。
///
/// ⚠️ **一页拉不完要继续翻。** 后端单页硬上限 500（`limit: le=500`），此前这里只取
/// 第一页就当成全部——第 501 个词起静默消失，用户看到的是「我加过的词条不见了」。
Future<List<VocabularyWord>> getAllVocabulary() async {
  const int pageSize = 500;
  // 安全上限：后端若忽略 offset（每次都回满页）也不会把这个循环转死。
  // 20 页 = 1 万条，远超任何真实词库。
  const int maxPages = 20;
  final List<VocabularyWord> words = [];
  int offset = 0;
  for (int page = 0; page < maxPages; page++) {
    var response = await makeApiCall(
      url: '${Env.apiBaseUrl}v1/vocabulary?limit=$pageSize&offset=$offset',
      headers: {},
      method: 'GET',
      body: '',
    );
    // i18n-ignore: 异常原因串只进 debugPrint，永不出现在界面上
    if (response == null) throw VocabularyFetchException('network error at offset $offset');
    // i18n-ignore: 同上
    if (response.statusCode != 200) throw VocabularyFetchException('HTTP ${response.statusCode} at offset $offset');
    final List<dynamic> json = jsonDecode(response.body);
    words.addAll(json.map((e) => VocabularyWord.fromJson(e)));
    if (json.length < pageSize) break;
    offset += pageSize;
  }
  return words;
}

/// 新增词条。后端对同名 term 去重（已存在则返回已有条目）。
Future<VocabularyWord?> createVocabulary(String term) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/vocabulary',
    headers: {},
    method: 'POST',
    body: jsonEncode({'term': term, 'external_user_id': getExternalUserId()}),
  );
  if (response == null) return null;
  debugPrint('createVocabulary response: ${response.body}');
  if (response.statusCode == 201 || response.statusCode == 200) {
    return VocabularyWord.fromJson(jsonDecode(response.body));
  }
  return null;
}

/// 删除词条（后端返回 204）。
Future<bool> deleteVocabulary(String entryId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/vocabulary/$entryId',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deleteVocabulary response: ${response.statusCode}');
  return response.statusCode == 204;
}
