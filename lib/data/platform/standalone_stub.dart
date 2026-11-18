/// Not a browser: never an installed web app.
bool get runningStandalone => false;

/// The page's host, if in a browser.
String? get pageHost => null;
