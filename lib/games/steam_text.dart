import 'dart:convert';

bool validSteamInputText(String text) =>
    text.isNotEmpty &&
    text.length <= 512 &&
    utf8.encode(text).length <= 512 &&
    !RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]').hasMatch(text);
