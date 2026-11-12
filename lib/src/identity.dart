import 'limits.dart';
import 'storage.dart';

const String anonKey = 'corlex_aid';
const String userKey = 'corlex_uid';

String _newAnonymousId() => 'a_${newUuid()}';

/// Who is acting. The anonymous id is a random UUID the SDK makes itself (never an advertising or
/// vendor id); [userId] appears after identify(). Until [persist] is called (consent pending)
/// nothing is written.
class Identity {
  Identity(this._store, {required bool persisted}) : _persisted = persisted {
    anonymousId = (persisted ? _store.get(anonKey) : null) ?? _newAnonymousId();
    userId = persisted ? _store.get(userKey) : null;
    if (persisted) persist();
  }

  final KeyValueStore _store;
  bool _persisted;
  late String anonymousId;
  String? userId;

  void persist() {
    _persisted = true;
    _store.set(anonKey, anonymousId);
    final user = userId;
    if (user != null) _store.set(userKey, user);
  }

  void setUser(String id) {
    userId = truncateBytes(id, maxId);
    if (_persisted) _store.set(userKey, userId!);
  }

  /// Logout: forget the user and start a new anonymous person.
  void reset() {
    userId = null;
    anonymousId = _newAnonymousId();
    _store.remove(userKey);
    if (_persisted) persist();
  }

  /// Opt-out: remove every trace from storage.
  void wipe() {
    _store.remove(anonKey);
    _store.remove(userKey);
    _persisted = false;
  }
}
