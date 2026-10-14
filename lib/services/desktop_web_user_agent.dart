const _fallbackDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/131.0.0.0 Safari/537.36';

/// Keep Chrome compatibility on company sign-in pages without changing the
/// device's Android platform or Chromium version used to select MFA methods.
String chromeSignInWebUserAgent(String? currentUserAgent) {
  final current = currentUserAgent?.trim() ?? '';
  if (current.isEmpty || !current.contains('AppleWebKit/')) {
    return 'Mozilla/5.0 (Linux; Android 10) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/131.0.0.0 Mobile Safari/537.36';
  }
  return current
      .replaceAll(RegExp(r';\s*wv(?=\))'), '')
      .replaceAll(RegExp(r'\s+Version/[^\s]+'), '')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
}

/// One Chrome identity for SSO and desktop mail, retaining the Android platform.
/// This avoids changing the WebView user agent while sign-in is in progress.
String outlookWebUserAgent(String? currentUserAgent) =>
    chromeSignInWebUserAgent(
      currentUserAgent,
    ).replaceAll(RegExp(r'\s+Mobile(?=\s|$)'), '').trim();

/// Converts the installed WebView's current user agent into a desktop Windows
/// browser identity while retaining its real Chromium/WebKit versions.
String desktopWebUserAgent(String? currentUserAgent) {
  final current = currentUserAgent?.trim() ?? '';
  if (current.isEmpty || !current.contains('AppleWebKit/')) {
    return _fallbackDesktopUserAgent;
  }

  var desktop = current
      .replaceFirst(
        RegExp(r'\([^)]*(?:Android|Linux; U)[^)]*\)'),
        '(Windows NT 10.0; Win64; x64)',
      )
      .replaceAll(RegExp(r'\s+Version/[^\s]+'), '')
      .replaceAll(RegExp(r'\s+Mobile(?=\s|$)'), '')
      .replaceAll(RegExp(r';\s*wv(?=\))'), '')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();

  if (desktop.contains('Android') ||
      desktop.contains(' Mobile') ||
      !desktop.contains('Windows NT 10.0')) {
    return _fallbackDesktopUserAgent;
  }
  return desktop;
}
