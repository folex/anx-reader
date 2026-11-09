import 'dart:convert';

// Function names are application constants; arguments may contain book/user data.
String jsCall(String functionName, List<Object?> arguments) =>
    '$functionName(${arguments.map(jsonEncode).join(',')})';
