import 'package:flutter/material.dart';

class NoAutofillTextField extends StatelessWidget {
  final TextEditingController controller;
  final InputDecoration decoration;
  final TextInputType? keyboardType;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;
  final int maxLines;
  final bool autocorrect;
  final bool enableSuggestions;
  final bool enableImePersonalizedLearning;
  final Iterable<String>? autofillHints;

  const NoAutofillTextField({
    super.key,
    required this.controller,
    required this.decoration,
    this.keyboardType,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
    this.maxLines = 1,
    this.autocorrect = false,
    this.enableSuggestions = true,
    this.enableImePersonalizedLearning = true,
    this.autofillHints,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: decoration,
      keyboardType: keyboardType,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: textInputAction,
      maxLines: maxLines,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      enableIMEPersonalizedLearning: enableImePersonalizedLearning,
      autofillHints: autofillHints,
    );
  }
}
