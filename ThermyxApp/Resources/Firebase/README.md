# Firebase configuration

1. In the Firebase console for the Thermyx project, add an iOS app with the
   bundle ID `com.thermyx.app.a`, and download `GoogleService-Info.plist`.
2. Under Authentication → Sign-in method, enable **Google**.
3. Put `GoogleService-Info.plist` in this folder.
4. Copy its `REVERSED_CLIENT_ID` value into `GOOGLE_REVERSED_CLIENT_ID` in
   `project.yml`, so Google's sign-in can return to the app.
5. Run `xcodegen generate`.

Without the file the app builds and runs, but nobody can sign in.
