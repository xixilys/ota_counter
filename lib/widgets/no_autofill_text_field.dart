import 'package:flutter/material.dart';

class NoAutofillTextField extends StatelessWidget {
  final TextEditingController controller;
  final InputDecoration decoration;
  final TextInputType? keyboardType;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final TextInputAction? textInputAction;
  final int maxLines;

  const NoAutofillTextField({
    super.key,
    required this.controller,
    required this.decoration,
    this.keyboardType,
    this.autofocus = false,
    this.onChanged,
    this.textInputAction,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: decoration,
      keyboardType: keyboardType,
      autofocus: autofocus,
      onChanged: onChanged,
      textInputAction: textInputAction,
      maxLines: maxLines,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      autofillHints: const <String>[],
    );
  }
}
