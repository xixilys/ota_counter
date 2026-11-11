# onnxruntime (on-device face recognition) looks up its Java classes, fields
# and methods by name from native code. R8 renames or strips them in release
# builds otherwise, and OrtSession.run aborts with "java_class == null".
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
