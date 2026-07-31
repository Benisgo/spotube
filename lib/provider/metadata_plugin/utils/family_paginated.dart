import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';
import 'package:spotube/services/logger/logger.dart';

bool _isRecoverablePaginationError(Object error) {
  if (error is DioException) {
    return error.response?.statusCode == 401 ||
        error.response?.statusCode == 429;
  }

  final message = error.toString();
  return message.contains("401") || message.contains("429");
}

abstract class FamilyPaginatedAsyncNotifier<K, A>
    extends FamilyAsyncNotifier<SpotubePaginationResponseObject<K>, A>
    with MetadataPluginMixin<K> {
  Future<SpotubePaginationResponseObject<K>> fetch(int offset, int limit);

  Future<void> fetchMore() async {
    if (state.value == null || !state.value!.hasMore) return;

    final oldState = state.value;

    try {
      state = AsyncLoadingNext(state.asData!.value);

      final newState = await fetch(
        state.value!.nextOffset!,
        state.value!.limit,
      );

      final oldItems =
          state.value!.items.isEmpty ? <K>[] : state.value!.items.cast<K>();
      final items = newState.items.isEmpty ? <K>[] : newState.items.cast<K>();

      state = AsyncData(newState.copyWith(items: <K>[...oldItems, ...items]));
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      // Stop the InfiniteList from auto-retrying in a tight loop (a 429/network
      // error previously kept hasMore=true → refetch → 429 → flood + freeze).
      state = AsyncData(oldState!.copyWith(hasMore: false));
    }
  }

  Future<List<K>> fetchAll() async {
    if (state.value == null) return [];
    if (!state.value!.hasMore) return state.value!.items.cast<K>();

    bool hasMore = true;
    while (hasMore) {
      final nextOffset = state.value!.nextOffset!;
      final limit = state.value!.limit;

      Future<SpotubePaginationResponseObject<K>> retry(
        int retryLimit, {
        bool delayed = false,
      }) async {
        if (delayed) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
        return fetch(nextOffset, retryLimit);
      }

      final newState = await fetch(nextOffset, max(limit, 100)).catchError((e) {
        if (_isRecoverablePaginationError(e)) throw e;
        return retry(max(limit, 50));
      }).catchError((e) {
        if (_isRecoverablePaginationError(e)) throw e;
        return retry(limit);
      }).catchError((e) {
        if (_isRecoverablePaginationError(e)) throw e;
        return retry(limit, delayed: true);
      });

      hasMore = newState.hasMore;

      final oldItems =
          state.value!.items.isEmpty ? <K>[] : state.value!.items.cast<K>();
      final items = newState.items.isEmpty ? <K>[] : newState.items.cast<K>();

      state = AsyncData(
        newState.copyWith(items: [...oldItems, ...items]),
      );
    }

    return state.value!.items.cast<K>();
  }
}

abstract class AutoDisposeFamilyPaginatedAsyncNotifier<K, A>
    extends AutoDisposeFamilyAsyncNotifier<SpotubePaginationResponseObject<K>,
        A> with MetadataPluginMixin<K> {
  Future<SpotubePaginationResponseObject<K>> fetch(int offset, int limit);

  Future<void> fetchMore() async {
    if (state.value == null || !state.value!.hasMore) return;
    final oldState = state.value;

    try {
      state = AsyncLoadingNext(state.value!);

      final newState = await fetch(
        state.value!.nextOffset!,
        state.value!.limit,
      );

      state = AsyncData(
        newState.copyWith(items: [
          ...state.value!.items.cast<K>(),
          ...newState.items.cast<K>(),
        ]),
      );
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      // Stop the InfiniteList from auto-retrying in a tight loop (a 429/network
      // error previously kept hasMore=true → refetch → 429 → flood + freeze).
      state = AsyncData(oldState!.copyWith(hasMore: false));
    }
  }

  Future<List<K>> fetchAll() async {
    if (state.value == null) return [];
    if (!state.value!.hasMore) return state.value!.items.cast<K>();

    bool hasMore = true;
    while (hasMore) {
      final nextOffset = state.value!.nextOffset!;
      final limit = state.value!.limit;

      Future<SpotubePaginationResponseObject<K>> retry(
        int retryLimit, {
        bool delayed = false,
      }) async {
        if (delayed) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
        return fetch(nextOffset, retryLimit);
      }

      final newState = await fetch(nextOffset, max(limit, 100)).catchError((e) {
        if (_isRecoverablePaginationError(e)) throw e;
        return retry(max(limit, 50));
      }).catchError((e) {
        if (_isRecoverablePaginationError(e)) throw e;
        return retry(limit);
      }).catchError((e) {
        if (_isRecoverablePaginationError(e)) throw e;
        return retry(limit, delayed: true);
      });

      hasMore = newState.hasMore;

      final oldItems =
          state.value!.items.isEmpty ? <K>[] : state.value!.items.cast<K>();
      final items = newState.items.isEmpty ? <K>[] : newState.items.cast<K>();

      state = AsyncData(
        newState.copyWith(items: [...oldItems, ...items]),
      );
    }

    return state.value!.items.cast<K>();
  }
}
