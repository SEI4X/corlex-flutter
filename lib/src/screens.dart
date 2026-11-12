import 'package:flutter/widgets.dart';

import 'client.dart';
import 'corlex.dart';
import 'limits.dart';
import 'crash/privacy.dart';

final RegExp _idSegment = RegExp(
  r'^(?:\d+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{12,})$',
  caseSensitive: false,
);

/// Supply fixed route patterns, never personal labels. Queries/fragments and known identifier,
/// contact or credential segments are removed defensively; arbitrary caller labels need review.
String screenName(String raw) {
  if (raw.length > 8192) return '[screen]';
  final uri = Uri.tryParse(raw);
  var name = uri?.hasAuthority == true ? uri!.path : raw;
  final cut = name.indexOf(RegExp(r'[?#]'));
  if (cut >= 0) name = name.substring(0, cut);
  name = name.split('/').map((s) {
    String decoded;
    try {
      decoded = Uri.decodeComponent(s);
    } on Object {
      return '[id]';
    }
    return _idSegment.hasMatch(decoded) || sensitiveLabel(decoded) ? '[id]' : s;
  }).join('/');
  return truncateBytes(name, 200);
}

/// `screen_view` events: one per change of the visible screen, with `source` and
/// `previous_screen`. Used by [CorlexNavigatorObserver] and by `Corlex.screen`.
class ScreenTracker {
  ScreenTracker(this._client);

  final CorlexClient _client;
  String? _current;

  void view(String name, {String source = 'manual'}) {
    final screen = screenName(name);
    if (screen.isEmpty || screen == _current) return;
    final previous = _current;
    _current = screen;
    _client.track('screen_view', {
      'screen': screen,
      'source': source,
      if (previous != null) 'previous_screen': previous,
    });
  }
}

/// Sends `screen_view` when a page route is shown. Add it to `MaterialApp.navigatorObservers`
/// (or go_router's `observers`). Only the route's **name** is read (`RouteSettings.name`): never its
/// arguments. Dialogs and bottom sheets are not screens and are skipped, and so are routes without
/// a name (give your pages `RouteSettings(name: ...)`; go_router fills it in).
class CorlexNavigatorObserver extends NavigatorObserver {
  CorlexNavigatorObserver({void Function(String name)? onScreen})
      : onScreen =
            onScreen ?? ((name) => Corlex.screen(name, source: 'navigator'));

  /// Where a screen name goes. By default `Corlex.screen`.
  final void Function(String name) onScreen;

  void _show(Route<dynamic>? route) {
    if (route is! PageRoute<dynamic>) return;
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) onScreen(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _show(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _show(newRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Closing a dialog or a sheet shows no new screen: only a page that goes away does.
    if (route is PageRoute<dynamic>) _show(previousRoute);
  }
}
