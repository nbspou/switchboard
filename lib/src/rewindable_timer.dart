/*
WSTalk
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

import 'dart:async';

class RewindableTimer {
  Timer _timer;
  Duration _duration;
  Function() _callback;

  ExtendableTimer(Duration duration, Function() callback) {
    _duration = duration;
    _callback = callback;
    _timer = new Timer(duration, callback);
  }

  bool rewind() {
    if (_timer?.isActive ?? false) {
      _timer.cancel();
      _timer = new Timer(_duration, _callback);
      return true;
    }
    return false;
  }

  bool cancel() {
    if (_timer?.isActive ?? false) {
      _timer.cancel();
      _timer = null;
      return true;
    }
    return false;
  }

  bool get isActive {
    return _timer?.isActive;
  }
}

/* end of file */
