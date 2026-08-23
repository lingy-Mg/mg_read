# Javet's native bootstrap resolves Java binding classes by their binary names
# from JNI. R8 cannot infer those lookups from the native library, so shrinking
# or renaming this package makes libjavet-node-android abort during JNI_OnLoad.
-keep class com.caoccao.javet.** { *; }
