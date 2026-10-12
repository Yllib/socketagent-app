import 'dart:convert';

import 'package:app/services/google_auth_desktop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PKCE challenge matches the RFC 7636 example', () {
    expect(
      pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });

  test('random values are unpadded base64url of the asked size', () {
    final value = randomUrlSafe(32);
    expect(value, hasLength(43));
    expect(value, isNot(contains('=')));
    expect(value, isNot(contains('+')));
    expect(randomUrlSafe(32), isNot(value));
  });

  test('the email comes from the ID token payload', () {
    String part(Object json) =>
        base64UrlEncode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    final token =
        '${part({'alg': 'RS256'})}.${part({'email': 'a@b.c', 'sub': '1'})}.sig';
    expect(emailFromIdToken(token), 'a@b.c');
    expect(() => emailFromIdToken('x.y'), throwsFormatException);
    expect(
      () => emailFromIdToken('${part({})}.${part({'sub': '1'})}.sig'),
      throwsFormatException,
    );
  });
}
