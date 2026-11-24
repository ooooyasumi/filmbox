# Media3, Coil and OkHttp ship their own consumer rules. No broad keep-all rules:
# the release should not contain the complete Material icon catalog or test fixtures.
-keepattributes Signature,InnerClasses,EnclosingMethod

# WorkManager persists this name across application upgrades.
-keepnames class com.filmbox.app.CloudIndexWorker
-keepclassmembers class com.filmbox.app.CloudIndexWorker { public <init>(android.content.Context, androidx.work.WorkerParameters); }
