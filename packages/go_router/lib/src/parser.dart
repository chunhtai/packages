// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'configuration.dart';
import 'information_provider.dart';
import 'logging.dart';
import 'match.dart';
import 'route.dart';
import 'router.dart';

/// The function signature of [GoRouteInformationParser.onParserException].
///
/// The `routeMatchList` parameter contains the exception explains the issue
/// occurred.
///
/// The returned [RouteMatchList] is used as parsed result for the
/// [GoRouterDelegate].
typedef ParserExceptionHandler = RouteMatchList Function(
  BuildContext context,
  RouteMatchList routeMatchList,
);

/// Converts between incoming URLs and a [RouteMatchList] using [RouteMatcher].
/// Also performs redirection using [RouteRedirector].
class GoRouteInformationParser extends RouteInformationParser<RouteMatchList> {
  /// Creates a [GoRouteInformationParser].
  GoRouteInformationParser({
    required this.configuration,
    required this.onParserException,
  });

  /// The route configuration used for parsing [RouteInformation]s.
  final RouteConfiguration configuration;

  /// The exception handler that is called when parser can't handle the incoming
  /// uri.
  ///
  /// This method must return a [RouteMatchList] for the parsed result.
  final ParserExceptionHandler? onParserException;

  final Random _random = Random();

  /// The future of current route parsing.
  ///
  /// This is used for testing asynchronous redirection.
  @visibleForTesting
  Future<RouteMatchList>? debugParserFuture;

  /// Called by the [Router]. The
  @override
  Future<RouteMatchList> parseRouteInformationWithDependencies(
    RouteInformation routeInformation,
    BuildContext context,
  ) {
    assert(routeInformation.state != null);
    final Object state = routeInformation.state!;
    final RouteInformationState<Object?> routeInformationState;
    if (state is RouteMatchList) {
      // This is a result of browser backward/forward button or state
      // restoration.
      routeInformationState = RouteInformationState<void>(
        type: NavigatingType.restore,
        extra: state.extra,
        baseRouteMatchList: state,
      );
      return debugParserFuture = _redirect(context, state)
          .then<RouteMatchList>((RouteMatchList value) {
        if (value.isError && onParserException != null) {
          return onParserException!(context, value);
        }
        return value;
      });
    } else {
      routeInformationState = state as RouteInformationState<Object?>;
    }

    late final RouteMatchList initialMatches;
    initialMatches =
        // TODO(chunhtai): remove this ignore and migrate the code
        // https://github.com/flutter/flutter/issues/124045.
        // ignore: deprecated_member_use, unnecessary_non_null_assertion
        configuration.findMatch(routeInformation.location!,
            extra: routeInformationState.extra);
    if (initialMatches.isError) {
      // TODO(chunhtai): remove this ignore and migrate the code
      // https://github.com/flutter/flutter/issues/124045.
      // ignore: deprecated_member_use
      log('No initial matches: ${routeInformation.location}');
    }

    return debugParserFuture = _redirect(
      context,
      initialMatches,
    ).then<RouteMatchList>((RouteMatchList matchList) {
      if (matchList.isError && onParserException != null) {
        return onParserException!(context, matchList);
      }

      assert(() {
        if (matchList.isNotEmpty) {
          assert(!(matchList.last.route as GoRoute).redirectOnly,
              'A redirect-only route must redirect to location different from itself.\n The offending route: ${matchList.last.route}');
        }
        return true;
      }());
      return _updateRouteMatchList(
        matchList,
        baseRouteMatchList: routeInformationState.baseRouteMatchList,
        completer: routeInformationState.completer,
        type: routeInformationState.type,
      );
    });
  }

  @override
  Future<RouteMatchList> parseRouteInformation(
      RouteInformation routeInformation) {
    throw UnimplementedError(
        'use parseRouteInformationWithDependencies instead');
  }

  /// for use by the Router architecture as part of the RouteInformationParser
  @override
  RouteInformation? restoreRouteInformation(RouteMatchList configuration) {
    if (configuration.isEmpty) {
      return null;
    }
    final String location;
    if (GoRouter.optionURLReflectsImperativeAPIs &&
        configuration.matches.last is ImperativeRouteMatch) {
      location = (configuration.matches.last as ImperativeRouteMatch)
          .matches
          .uri
          .toString();
    } else {
      location = configuration.uri.toString();
    }
    return RouteInformation(
      // TODO(chunhtai): remove this ignore and migrate the code
      // https://github.com/flutter/flutter/issues/124045.
      // ignore: deprecated_member_use
      location: location,
      state: configuration,
    );
  }

  Future<RouteMatchList> _redirect(
      BuildContext context, RouteMatchList routeMatch) {
    final FutureOr<RouteMatchList> redirectedFuture = configuration
        .redirect(context, routeMatch, redirectHistory: <RouteMatchList>[]);
    if (redirectedFuture is RouteMatchList) {
      return SynchronousFuture<RouteMatchList>(redirectedFuture);
    }
    return redirectedFuture;
  }

  RouteMatchList _updateRouteMatchList(
    RouteMatchList newMatchList, {
    required RouteMatchList? baseRouteMatchList,
    required Completer<Object?>? completer,
    required NavigatingType type,
  }) {
    switch (type) {
      case NavigatingType.push:
        return baseRouteMatchList!.push(
          ImperativeRouteMatch(
            pageKey: _getUniqueValueKey(),
            completer: completer!,
            matches: newMatchList,
          ),
        );
      case NavigatingType.pushReplacement:
        final RouteMatch routeMatch = baseRouteMatchList!.last;
        return baseRouteMatchList.remove(routeMatch).push(
              ImperativeRouteMatch(
                pageKey: _getUniqueValueKey(),
                completer: completer!,
                matches: newMatchList,
              ),
            );
      case NavigatingType.replace:
        final RouteMatch routeMatch = baseRouteMatchList!.last;
        return baseRouteMatchList.remove(routeMatch).push(
              ImperativeRouteMatch(
                pageKey: routeMatch.pageKey,
                completer: completer!,
                matches: newMatchList,
              ),
            );
      case NavigatingType.go:
        return newMatchList;
      case NavigatingType.restore:
        // Still need to consider redirection.
        return baseRouteMatchList!.uri.toString() != newMatchList.uri.toString()
            ? newMatchList
            : baseRouteMatchList;
    }
  }

  ValueKey<String> _getUniqueValueKey() {
    return ValueKey<String>(String.fromCharCodes(
        List<int>.generate(32, (_) => _random.nextInt(33) + 89)));
  }
}
